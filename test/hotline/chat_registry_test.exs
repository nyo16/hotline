defmodule Hotline.ChatRegistryTest do
  use ExUnit.Case, async: true

  alias Hotline.ChatRegistry

  # Start a registry and guarantee teardown even if an assertion fails. Named
  # GenServers and their named ETS/DETS tables would otherwise leak for the VM
  # lifetime (a normal test-process exit does not kill the linked child).
  defp start_registry(opts) do
    {:ok, pid} = ChatRegistry.start_link(opts)
    stop_on_exit(pid)
  end

  defp stop_on_exit(pid) do
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  # A brutally-killed owner releases its DETS file asynchronously; retry the
  # reopen briefly until the dets server has closed the dead table's handle.
  defp reopen_registry(name, dets_path, attempts \\ 50) do
    case ChatRegistry.start_link(name: name, dets_path: dets_path) do
      {:ok, pid} ->
        stop_on_exit(pid)

      {:error, _} when attempts > 0 ->
        Process.sleep(10)
        reopen_registry(name, dets_path, attempts - 1)

      # Retries exhausted: fail with a clear diagnosis instead of a cryptic
      # CaseClauseError, so a future flake points straight at the real cause.
      {:error, reason} ->
        flunk(
          "DETS file #{dets_path} never released after kill (retries exhausted); " <>
            "the dead owner's handle was still open. Last error: #{inspect(reason)}"
        )
    end
  end

  @tag :tmp_dir
  test "tracks chats from updates and persists via DETS", %{tmp_dir: tmp_dir} do
    dets_path = Path.join(tmp_dir, "test_chats.dets")
    name = :"TestRegistry#{System.unique_integer([:positive])}"

    pid = start_registry(name: name, dets_path: dets_path)

    chat = %Hotline.Types.Chat{id: 123, type: "private", first_name: "Alice"}
    ChatRegistry.track(chat, name)

    # Give the cast time to process
    :sys.get_state(pid)

    assert ChatRegistry.count(name) == 1
    assert %{id: 123, first_name: "Alice", type: "private"} = ChatRegistry.get(123, name)
    assert [%{id: 123}] = ChatRegistry.list(name)
  end

  @tag :tmp_dir
  test "restores chats from DETS on restart", %{tmp_dir: tmp_dir} do
    dets_path = Path.join(tmp_dir, "persist_chats.dets")
    name = :"PersistRegistry#{System.unique_integer([:positive])}"

    pid = start_registry(name: name, dets_path: dets_path)

    chat = %Hotline.Types.Chat{id: 456, type: "group", title: "Test Group"}
    ChatRegistry.track(chat, name)
    :sys.get_state(pid)

    assert ChatRegistry.count(name) == 1
    GenServer.stop(pid)

    # Restart with same DETS path, new ETS
    name2 = :"PersistRegistry2#{System.unique_integer([:positive])}"
    start_registry(name: name2, dets_path: dets_path)

    assert ChatRegistry.count(name2) == 1
    assert %{id: 456, title: "Test Group"} = ChatRegistry.get(456, name2)
  end

  @tag :tmp_dir
  test "synced writes survive a brutal kill (no clean terminate)", %{tmp_dir: tmp_dir} do
    dets_path = Path.join(tmp_dir, "crash_chats.dets")
    name = :"CrashRegistry#{System.unique_integer([:positive])}"

    pid = start_registry(name: name, dets_path: dets_path)

    chat = %Hotline.Types.Chat{id: 999, type: "private", first_name: "Crash"}
    ChatRegistry.track(chat, name)
    # Ensure the cast (and its :dets.sync) completed before we kill.
    :sys.get_state(pid)

    # Brutal kill: terminate/2 never runs, so only writes already flushed by
    # :dets.sync/1 can survive. Trap the linked exit so the test itself lives.
    Process.flag(:trap_exit, true)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    # Reopen the same DETS file from a fresh registry and assert the data is there.
    name2 = :"CrashRegistry2#{System.unique_integer([:positive])}"
    reopen_registry(name2, dets_path)

    assert ChatRegistry.count(name2) == 1
    assert %{id: 999, first_name: "Crash"} = ChatRegistry.get(999, name2)
  end

  @tag :tmp_dir
  test "restricts DETS file and directory permissions to the owner", %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "private")
    dets_path = Path.join(dir, "chats.dets")
    name = :"PermRegistry#{System.unique_integer([:positive])}"

    start_registry(name: name, dets_path: dets_path)

    file_mode = File.stat!(dets_path).mode
    assert Bitwise.band(file_mode, 0o777) == 0o600

    dir_mode = File.stat!(dir).mode
    assert Bitwise.band(dir_mode, 0o777) == 0o700
  end

  @tag :tmp_dir
  test "tracks a raw string-keyed chat map", %{tmp_dir: tmp_dir} do
    dets_path = Path.join(tmp_dir, "raw_chats.dets")
    name = :"RawRegistry#{System.unique_integer([:positive])}"

    pid = start_registry(name: name, dets_path: dets_path)

    ChatRegistry.track(%{"id" => 321, "type" => "private", "first_name" => "Raw"}, name)
    :sys.get_state(pid)

    assert %{id: 321, first_name: "Raw", type: "private"} = ChatRegistry.get(321, name)
  end

  @tag :tmp_dir
  test "auto-tracks chats from PubSub updates", %{tmp_dir: tmp_dir} do
    dets_path = Path.join(tmp_dir, "pubsub_chats.dets")
    name = :"PubSubRegistry#{System.unique_integer([:positive])}"

    pid = start_registry(name: name, dets_path: dets_path)

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

    assert %{id: 789, first_name: "Bob"} = ChatRegistry.get(789, name)
  end
end
