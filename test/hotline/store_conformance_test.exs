defmodule Hotline.StoreConformanceTest do
  @moduledoc """
  One contract, every adapter. Each `Hotline.Store` implementation is driven
  through the same put/get/delete/list/keys assertions, and the persistent ones
  additionally through a close/reopen restore cycle.

  RocksDB is included only when the optional `:rocksdb` dep is loaded.
  """
  use ExUnit.Case, async: true

  alias Hotline.Store

  defp uniq(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  # {module, init_opts, persistent?}
  defp adapters(tmp_dir) do
    base = [
      {Store.ETS, [name: uniq(:ets_store)], false},
      {Store.DETS,
       [
         name: uniq(:dets_store),
         path: Path.join(tmp_dir, "#{uniq(:f)}.dets"),
         sync_interval: :infinity
       ], true}
    ]

    if Code.ensure_loaded?(:rocksdb) do
      base ++ [{Store.RocksDB, [path: Path.join(tmp_dir, "#{uniq(:r)}.rocksdb")], true}]
    else
      base
    end
  end

  @tag :tmp_dir
  test "put/get/delete/list/keys behave identically across adapters", %{tmp_dir: tmp_dir} do
    for {mod, opts, _persistent} <- adapters(tmp_dir) do
      {:ok, h} = mod.init(opts)

      try do
        # Missing key
        assert mod.get(h, :chats, 1) == :error

        # Upsert + read
        assert mod.put(h, :chats, 1, %{id: 1, name: "a"}) == :ok
        assert mod.put(h, :chats, 2, %{id: 2, name: "b"}) == :ok
        assert {:ok, %{id: 1, name: "a"}} = mod.get(h, :chats, 1)

        # Update in place
        assert mod.put(h, :chats, 1, %{id: 1, name: "a2"}) == :ok
        assert {:ok, %{id: 1, name: "a2"}} = mod.get(h, :chats, 1)

        # list / keys
        assert Enum.sort(mod.keys(h, :chats)) == [1, 2]
        assert length(mod.list(h, :chats)) == 2

        # Collection isolation: a second collection shares nothing with the first
        assert mod.put(h, :flows, 1, %{id: 1, flow: true}) == :ok
        assert Enum.sort(mod.keys(h, :chats)) == [1, 2]
        assert mod.keys(h, :flows) == [1]
        assert {:ok, %{flow: true}} = mod.get(h, :flows, 1)

        # Delete
        assert mod.delete(h, :chats, 1) == :ok
        assert mod.get(h, :chats, 1) == :error
        assert mod.keys(h, :chats) == [2]

        # Deleting a missing key is a no-op
        assert mod.delete(h, :chats, 999) == :ok
      after
        mod.close(h)
      end
    end
  end

  @tag :tmp_dir
  test "persistent adapters restore their data across close and reopen", %{tmp_dir: tmp_dir} do
    for {mod, opts, true} <- adapters(tmp_dir) do
      {:ok, h} = mod.init(opts)
      assert mod.put(h, :chats, 7, %{id: 7, name: "lucky"}) == :ok
      # close/1 must flush pending writes.
      assert mod.close(h) == :ok

      # Reopen the same backing store with identical opts.
      {:ok, h2} = mod.init(opts)

      try do
        assert {:ok, %{id: 7, name: "lucky"}} = mod.get(h2, :chats, 7)
        assert mod.list(h2, :chats) == [%{id: 7, name: "lucky"}]
      after
        mod.close(h2)
      end
    end
  end
end
