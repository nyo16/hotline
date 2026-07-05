defmodule Hotline.ChatRegistry do
  @moduledoc """
  Tracks known chats using ETS (fast reads) backed by DETS (persistence).

  Automatically subscribes to PubSub and records chats from incoming updates.
  Survives restarts via DETS.

  ## Data at rest

  Tracked chats are personal data (names, usernames) persisted **unencrypted**
  in the DETS file. On init the registry locks its directory to `0700` **before**
  creating the file — closing the brief world-readable window `:dets.open_file`
  would otherwise leave on the freshly created file — and then restricts the file
  itself to `0600` (best effort — skipped with a warning on filesystems without
  POSIX modes). Operators are responsible for:

    * storing `:dets_path` in a **private, app-owned subdirectory** — not the
      shared default `priv/`. Because the registry locks the *containing
      directory* to `0700`, pointing it at bare `priv/` over-broadly restricts
      every other `priv/` asset; give it a dedicated dir (e.g.
      `priv/hotline/chats.dets` or an external data dir), which also keeps chat
      PII out of anything published in a release or Hex package, and
    * applying disk-level encryption if the data warrants it.

  ## Usage

  Add to your supervision tree (after PubSub):

      {Hotline.ChatRegistry, dets_path: "priv/chats.dets"}

  Then query:

      Hotline.ChatRegistry.list()
      Hotline.ChatRegistry.get(7644580464)
      Hotline.ChatRegistry.count()
  """

  use GenServer

  require Logger

  @default_dets_path "priv/hotline_chats.dets"

  # --- Public API (read from ETS, no GenServer bottleneck) ---

  @doc "List all known chats."
  def list(name \\ __MODULE__) do
    ets_table(name)
    |> :ets.tab2list()
    |> Enum.map(fn {_id, chat} -> chat end)
  end

  @doc "Get a chat by ID."
  def get(chat_id, name \\ __MODULE__) do
    case :ets.lookup(ets_table(name), chat_id) do
      [{_id, chat}] -> chat
      [] -> nil
    end
  end

  @doc "Count known chats."
  def count(name \\ __MODULE__) do
    :ets.info(ets_table(name), :size)
  end

  @doc "Manually track a chat."
  def track(chat, name \\ __MODULE__) do
    GenServer.cast(name, {:track, chat})
  end

  defp ets_table(name), do: :"#{name}.ETS"
  defp dets_table(name), do: :"#{name}.DETS"

  # --- GenServer ---

  def start_link(opts \\ []) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    name = opts[:name] || __MODULE__

    dets_path =
      opts[:dets_path] ||
        Application.get_env(:hotline, :chat_registry_path) ||
        @default_dets_path

    dir = Path.dirname(dets_path)
    File.mkdir_p!(dir)

    ets = ets_table(name)
    dets = dets_table(name)

    :ets.new(ets, [:named_table, :set, :public, read_concurrency: true])

    # Lock the directory to owner-only BEFORE opening the file: :dets.open_file
    # creates the file at the default umask (a brief world-readable window), and a
    # 0700 dir makes that new file unreachable by other users during that window.
    restrict_dir_permissions(dir)

    {:ok, ^dets} = :dets.open_file(dets, file: String.to_charlist(dets_path))

    # Then tighten the file itself — chat PII is persisted unencrypted.
    restrict_file_permissions(dets_path)

    # Restore from DETS into ETS
    :dets.traverse(dets, fn entry ->
      :ets.insert(ets, entry)
      :continue
    end)

    Phoenix.PubSub.subscribe(Hotline.PubSub, "hotline:updates")
    {:ok, %{ets: ets, dets: dets}}
  end

  @impl true
  def handle_cast({:track, chat}, state) do
    do_track(chat, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:hotline_update, update}, state) do
    chat = extract_chat(update)
    if chat, do: do_track(chat, state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{dets: dets}) do
    :dets.close(dets)
  end

  # --- Internal ---

  # Restrict the DETS directory to owner-only rwx (before the file is created).
  defp restrict_dir_permissions(dir), do: chmod_best_effort(dir, 0o700)

  # Restrict the DETS file to owner-only rw (after :dets.open_file creates it).
  defp restrict_file_permissions(dets_path), do: chmod_best_effort(dets_path, 0o600)

  # Best effort: File.chmod returns {:error, :enotsup} on filesystems without
  # POSIX modes (e.g. Windows); warn rather than crash the registry there.
  defp chmod_best_effort(path, mode) do
    case File.chmod(path, mode) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ChatRegistry could not restrict permissions on #{path} (#{inspect(reason)}); " <>
            "ensure it is stored in a private, app-owned directory."
        )
    end
  end

  # Handles both %Hotline.Types.Chat{} structs (atom keys) and raw maps
  # (atom- or string-keyed) via get_field/2, so there is a single entry shape
  # and one insert path.
  defp do_track(chat, %{ets: ets, dets: dets}) when is_map(chat) do
    id = get_field(chat, :id)

    if id do
      entry = %{
        id: id,
        type: get_field(chat, :type),
        title: get_field(chat, :title),
        first_name: get_field(chat, :first_name),
        last_name: get_field(chat, :last_name),
        username: get_field(chat, :username),
        last_seen: System.system_time(:second)
      }

      :ets.insert(ets, {id, entry})
      :dets.insert(dets, {id, entry})
      # Flush to disk on every write: terminate/2 only runs on a clean stop, so
      # without this a SIGKILL/power loss would drop writes the moduledoc
      # promises survive restarts. Safe for this low-write registry.
      :dets.sync(dets)
    end
  end

  # Prefer the atom key, fall back to the string key. Uses Map.get/3's default
  # (which triggers only on an ABSENT key) rather than `||`, so a future field
  # whose legitimate value is `false`/`nil` isn't mistaken for "missing".
  defp get_field(chat, key), do: Map.get(chat, key, Map.get(chat, Atom.to_string(key)))

  defp extract_chat(%{message: %{chat: chat}}) when not is_nil(chat), do: chat
  defp extract_chat(%{edited_message: %{chat: chat}}) when not is_nil(chat), do: chat
  defp extract_chat(%{channel_post: %{chat: chat}}) when not is_nil(chat), do: chat
  defp extract_chat(%{callback_query: %{message: %{chat: chat}}}) when not is_nil(chat), do: chat
  defp extract_chat(_), do: nil
end
