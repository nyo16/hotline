defmodule Hotline.ChatRegistry do
  @moduledoc """
  Tracks known chats using ETS (fast reads) backed by DETS (persistence).

  Automatically subscribes to PubSub and records chats from incoming updates.
  Survives restarts via DETS.

  ## Usage

  Add to your supervision tree (after PubSub):

      {Hotline.ChatRegistry, dets_path: "priv/chats.dets"}

  Then query:

      Hotline.ChatRegistry.list()
      Hotline.ChatRegistry.get(7644580464)
      Hotline.ChatRegistry.count()
  """

  use GenServer

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

    dets_path |> Path.dirname() |> File.mkdir_p!()

    ets = ets_table(name)
    dets = dets_table(name)

    :ets.new(ets, [:named_table, :set, :public, read_concurrency: true])
    {:ok, ^dets} = :dets.open_file(dets, file: String.to_charlist(dets_path))

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

  defp do_track(%{id: id} = chat, %{ets: ets, dets: dets}) do
    entry = %{
      id: id,
      type: chat.type,
      title: chat.title,
      first_name: chat.first_name,
      last_name: chat.last_name,
      username: chat.username,
      last_seen: System.system_time(:second)
    }

    :ets.insert(ets, {id, entry})
    :dets.insert(dets, {id, entry})
  end

  defp do_track(%{} = chat_map, %{ets: ets, dets: dets}) do
    id = chat_map[:id] || chat_map["id"]

    if id do
      entry = %{
        id: id,
        type: chat_map[:type] || chat_map["type"],
        title: chat_map[:title] || chat_map["title"],
        first_name: chat_map[:first_name] || chat_map["first_name"],
        last_name: chat_map[:last_name] || chat_map["last_name"],
        username: chat_map[:username] || chat_map["username"],
        last_seen: System.system_time(:second)
      }

      :ets.insert(ets, {id, entry})
      :dets.insert(dets, {id, entry})
    end
  end

  defp extract_chat(%{message: %{chat: chat}}) when not is_nil(chat), do: chat
  defp extract_chat(%{edited_message: %{chat: chat}}) when not is_nil(chat), do: chat
  defp extract_chat(%{channel_post: %{chat: chat}}) when not is_nil(chat), do: chat
  defp extract_chat(%{callback_query: %{message: %{chat: chat}}}) when not is_nil(chat), do: chat
  defp extract_chat(_), do: nil
end
