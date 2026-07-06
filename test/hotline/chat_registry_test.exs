defmodule Hotline.ChatRegistryTest do
  use ExUnit.Case, async: true

  alias Hotline.ChatRegistry
  alias Hotline.Store.DETS
  alias Hotline.Store.ETS

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
  test "tracks chats from updates and persists via the store", %{tmp_dir: tmp_dir} do
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
  test "restores chats from the store on restart", %{tmp_dir: tmp_dir} do
    dets_path = Path.join(tmp_dir, "persist_chats.dets")
    name = :"PersistRegistry#{System.unique_integer([:positive])}"

    pid = start_registry(name: name, dets_path: dets_path)

    chat = %Hotline.Types.Chat{id: 456, type: "group", title: "Test Group"}
    ChatRegistry.track(chat, name)
    :sys.get_state(pid)

    assert ChatRegistry.count(name) == 1
    # Clean stop flushes the store (Store.close/1) before releasing the file.
    GenServer.stop(pid)

    # Restart with same DETS path, new registry (fresh cache warmed from the store).
    name2 = :"PersistRegistry2#{System.unique_integer([:positive])}"
    start_registry(name: name2, dets_path: dets_path)

    assert ChatRegistry.count(name2) == 1
    assert %{id: 456, title: "Test Group"} = ChatRegistry.get(456, name2)
  end

  @tag :tmp_dir
  test "a flushed write survives a brutal kill (no clean terminate)", %{tmp_dir: tmp_dir} do
    dets_path = Path.join(tmp_dir, "crash_chats.dets")
    name = :"CrashRegistry#{System.unique_integer([:positive])}"

    pid = start_registry(name: name, dets_path: dets_path)

    chat = %Hotline.Types.Chat{id: 999, type: "private", first_name: "Crash"}
    ChatRegistry.track(chat, name)

    # Writes are no longer fsynced per-track — durability comes from a flush
    # (periodic auto_save, an explicit sync, or a clean close). Force a flush
    # through the store handle, using :sys.get_state as a FIFO barrier so the
    # :track cast has definitely been applied first.
    %{store: store_handle} = :sys.get_state(pid)
    DETS.sync(store_handle)

    # Brutal kill: terminate/2 never runs, so only data already flushed to disk can
    # survive. Trap the linked exit so the test itself lives.
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

  test "supports an explicit :store backend (in-memory ETS, no files)" do
    name = :"EtsStoreRegistry#{System.unique_integer([:positive])}"

    {:ok, pid} =
      ChatRegistry.start_link(name: name, store: {ETS, name: :"#{name}.EtsStore"})

    stop_on_exit(pid)

    ChatRegistry.track(
      %Hotline.Types.Chat{id: 42, type: "private", first_name: "Ephemeral"},
      name
    )

    :sys.get_state(pid)

    assert %{id: 42, first_name: "Ephemeral"} = ChatRegistry.get(42, name)
    assert ChatRegistry.count(name) == 1
  end

  @tag :tmp_dir
  test "with cache: false, reads go through to the store (no in-RAM cache)", %{tmp_dir: tmp_dir} do
    dets_path = Path.join(tmp_dir, "nocache_chats.dets")
    name = :"NoCacheRegistry#{System.unique_integer([:positive])}"

    pid = start_registry(name: name, dets_path: dets_path, cache: false)

    # No front cache table is created when caching is disabled.
    assert :ets.whereis(:"#{name}.Cache") == :undefined

    ChatRegistry.track(
      %Hotline.Types.Chat{id: 5, type: "private", first_name: "ReadThrough"},
      name
    )

    :sys.get_state(pid)

    # Reads are served straight from the durable store (no GenServer round-trip).
    assert %{id: 5, first_name: "ReadThrough"} = ChatRegistry.get(5, name)
    assert ChatRegistry.count(name) == 1
    assert [%{id: 5}] = ChatRegistry.list(name)
    assert ChatRegistry.get(404, name) == nil
  end

  test "publishes and cleans up its persistent_term read descriptor" do
    name = :"PtermRegistry#{System.unique_integer([:positive])}"

    {:ok, pid} =
      ChatRegistry.start_link(name: name, store: {ETS, name: :"#{name}.EtsStore"})

    assert %{store_mod: ETS} = :persistent_term.get({ChatRegistry, name})

    GenServer.stop(pid)
    assert :persistent_term.get({ChatRegistry, name}, :absent) == :absent
  end
end
