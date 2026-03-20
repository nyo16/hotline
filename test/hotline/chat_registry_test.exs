defmodule Hotline.ChatRegistryTest do
  use ExUnit.Case

  @tag :tmp_dir
  test "tracks chats from updates and persists via DETS", %{tmp_dir: tmp_dir} do
    dets_path = Path.join(tmp_dir, "test_chats.dets")
    name = :"TestRegistry#{System.unique_integer([:positive])}"

    {:ok, pid} = Hotline.ChatRegistry.start_link(name: name, dets_path: dets_path)

    chat = %Hotline.Types.Chat{id: 123, type: "private", first_name: "Alice"}
    Hotline.ChatRegistry.track(chat, name)

    # Give the cast time to process
    :sys.get_state(pid)

    assert Hotline.ChatRegistry.count(name) == 1
    assert %{id: 123, first_name: "Alice", type: "private"} = Hotline.ChatRegistry.get(123, name)
    assert [%{id: 123}] = Hotline.ChatRegistry.list(name)

    GenServer.stop(pid)
  end

  @tag :tmp_dir
  test "restores chats from DETS on restart", %{tmp_dir: tmp_dir} do
    dets_path = Path.join(tmp_dir, "persist_chats.dets")
    name = :"PersistRegistry#{System.unique_integer([:positive])}"

    {:ok, pid} = Hotline.ChatRegistry.start_link(name: name, dets_path: dets_path)

    chat = %Hotline.Types.Chat{id: 456, type: "group", title: "Test Group"}
    Hotline.ChatRegistry.track(chat, name)
    :sys.get_state(pid)

    assert Hotline.ChatRegistry.count(name) == 1
    GenServer.stop(pid)

    # Restart with same DETS path, new ETS
    name2 = :"PersistRegistry2#{System.unique_integer([:positive])}"
    {:ok, _pid2} = Hotline.ChatRegistry.start_link(name: name2, dets_path: dets_path)

    assert Hotline.ChatRegistry.count(name2) == 1
    assert %{id: 456, title: "Test Group"} = Hotline.ChatRegistry.get(456, name2)
  end

  @tag :tmp_dir
  test "auto-tracks chats from PubSub updates", %{tmp_dir: tmp_dir} do
    dets_path = Path.join(tmp_dir, "pubsub_chats.dets")
    name = :"PubSubRegistry#{System.unique_integer([:positive])}"

    {:ok, pid} = Hotline.ChatRegistry.start_link(name: name, dets_path: dets_path)

    update = %Hotline.Types.Update{
      update_id: 1,
      message: %Hotline.Types.Message{
        message_id: 1,
        date: 0,
        chat: %Hotline.Types.Chat{id: 789, type: "private", first_name: "Bob"},
        text: "hello"
      }
    }

    send(pid, {:hotline_update, update})
    :sys.get_state(pid)

    assert %{id: 789, first_name: "Bob"} = Hotline.ChatRegistry.get(789, name)
  end
end
