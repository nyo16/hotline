defmodule Hotline.ChatRegistry do
  @moduledoc """
  Tracks known chats using an in-memory ETS read cache backed by a pluggable
  durable `Hotline.Store`.

  Automatically subscribes to PubSub and records chats from incoming updates.
  Survives restarts via the configured store.

  ## Architecture

  Reads (`list/1`, `get/2`, `count/1`) are served from a per-registry **ETS cache**
  with no GenServer round-trip, so read latency never depends on the backend. The
  GenServer owns the write path: every tracked chat is written through to the ETS
  cache **and** the durable `Store`. At boot the cache is warmed from the store.

      updates ─► ChatRegistry ─┬─► ETS cache   (hot reads)
                               └─► Store        (durable: DETS | RocksDB | …)

  ## Persistence & durability

  The durable backend is pluggable via the `:store` option — see `Hotline.Store`.
  The default is `Hotline.Store.DETS` (disk-backed, zero-dep). Durability semantics
  (when writes are flushed to disk, crash behavior) are the store's responsibility;
  for the default DETS store, flushing is debounced onto a timer, so a clean stop is
  always durable but a hard kill can drop writes newer than one sync interval. See
  `Hotline.Store.DETS` for details and the data-at-rest security notes.

  ## Usage

  Add to your supervision tree (after PubSub):

      # Default: DETS
      {Hotline.ChatRegistry, dets_path: "priv/hotline/chats.dets"}

      # Or choose a backend explicitly:
      {Hotline.ChatRegistry, store: {Hotline.Store.RocksDB, path: "priv/hotline/chats.db"}}

  Then query:

      Hotline.ChatRegistry.list()
      Hotline.ChatRegistry.get(7644580464)
      Hotline.ChatRegistry.count()

  ## Options

    * `:store` — `{module, opts}` selecting the durable backend (default:
      `{Hotline.Store.DETS, ...}` built from the legacy options below).
    * `:dets_path` — path for the default DETS store (also `:chat_registry_path`
      app env). Ignored if `:store` is given.
    * `:sync_interval` — flush interval for the default DETS store (also
      `:chat_registry_sync_interval` app env). Ignored if `:store` is given.
    * `:name` — process name (defaults to the module name).
  """

  use GenServer

  @default_dets_path "priv/hotline_chats.dets"
  @default_sync_interval 5_000
  @collection :chats

  # --- Public API (read from the ETS cache, no GenServer bottleneck) ---

  @doc "List all known chats."
  def list(name \\ __MODULE__) do
    cache_table(name)
    |> :ets.tab2list()
    |> Enum.map(fn {_id, chat} -> chat end)
  end

  @doc "Get a chat by ID."
  def get(chat_id, name \\ __MODULE__) do
    case :ets.lookup(cache_table(name), chat_id) do
      [{_id, chat}] -> chat
      [] -> nil
    end
  end

  @doc "Count known chats."
  def count(name \\ __MODULE__) do
    :ets.info(cache_table(name), :size)
  end

  @doc "Manually track a chat."
  def track(chat, name \\ __MODULE__) do
    GenServer.cast(name, {:track, chat})
  end

  defp cache_table(name), do: :"#{name}.Cache"

  # --- GenServer ---

  def start_link(opts \\ []) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    name = opts[:name] || __MODULE__
    {store_mod, store_opts} = resolve_store(opts, name)

    cache = cache_table(name)
    :ets.new(cache, [:named_table, :set, :public, read_concurrency: true])

    case store_mod.init(store_opts) do
      {:ok, handle} ->
        warm_cache(cache, store_mod, handle)
        Phoenix.PubSub.subscribe(Hotline.PubSub, "hotline:updates")
        {:ok, %{cache: cache, store_mod: store_mod, store: handle}}

      {:error, reason} ->
        {:stop, {:store_init_failed, reason}}
    end
  end

  @impl true
  def handle_cast({:track, chat}, state) do
    {:noreply, do_track(chat, state)}
  end

  @impl true
  def handle_info({:hotline_update, update}, state) do
    chat = extract_chat(update)
    state = if chat, do: do_track(chat, state), else: state
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{store_mod: store_mod, store: handle}) do
    store_mod.close(handle)
  end

  def terminate(_reason, _state), do: :ok

  # --- Internal ---

  # Choose the durable backend. An explicit `{module, opts}` wins; otherwise build
  # the default DETS store from the legacy dets_path/sync_interval options and their
  # app-env fallbacks — so existing configs keep working unchanged.
  defp resolve_store(opts, name) do
    case opts[:store] do
      {module, store_opts} when is_atom(module) and is_list(store_opts) ->
        {module, store_opts}

      nil ->
        path =
          opts[:dets_path] ||
            Application.get_env(:hotline, :chat_registry_path) ||
            @default_dets_path

        sync_interval =
          opts[:sync_interval] ||
            Application.get_env(:hotline, :chat_registry_sync_interval) ||
            @default_sync_interval

        {Hotline.Store.DETS, name: :"#{name}.DETS", path: path, sync_interval: sync_interval}
    end
  end

  # Warm the read cache from durable storage on boot. Entries are keyed in the cache
  # by their chat id (do_track/2 guarantees an `:id` field on every stored value).
  defp warm_cache(cache, store_mod, handle) do
    for entry <- store_mod.list(handle, @collection) do
      :ets.insert(cache, {entry.id, entry})
    end

    :ok
  end

  # Handles both %Hotline.Types.Chat{} structs (atom keys) and raw maps (atom- or
  # string-keyed) via get_field/2, so there is a single entry shape and one write
  # path: through the ETS cache (hot reads) and the durable store.
  defp do_track(chat, %{cache: cache, store_mod: store_mod, store: handle} = state)
       when is_map(chat) do
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

      :ets.insert(cache, {id, entry})
      store_mod.put(handle, @collection, id, entry)
    end

    state
  end

  defp do_track(_chat, state), do: state

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
