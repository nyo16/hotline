if Code.ensure_loaded?(:rocksdb) do
  defmodule Hotline.Store.RocksDB do
    @moduledoc """
    `Hotline.Store` adapter backed by RocksDB (via the `:rocksdb` NIF).

    Only compiled when the optional `:rocksdb` dependency is present. RocksDB is an
    embedded, single-node, **LSM-tree** key/value store — write-optimized, which
    suits the registry's high-rate `last_seen` upserts. No 2 GB cap, no
    repair-scan-on-crash, durability via the write-ahead log.

    ## Enabling

    Add the dependency to your app (Hotline does not pull it in, so its native
    build never burdens Hotline's own compile):

        {:rocksdb, "~> 3.1"}

    The `:rocksdb` package builds RocksDB's C++ from source, so a C++ toolchain and
    CMake are required. With CMake ≥ 4 the vendored build may fail on RocksDB's old
    `cmake_minimum_required`; set `CMAKE_POLICY_VERSION_MINIMUM=3.5` in the build
    environment to work around it.

    ## Layout

    Collections are namespaced with a key prefix (`"<collection>\\0"`), so a
    collection's keys form a contiguous range that `list/2` and `keys/2` scan with a
    RocksDB iterator. Keys and values are serialized with `:erlang.term_to_binary/1`
    (values decoded with the `:safe` flag).

    ## Durability

    Writes use the write-ahead log with async flushing (throughput over per-write
    fsync). `close/1` releases the database, flushing the WAL. A hard kill can lose
    writes still buffered in the WAL that the OS had not yet flushed.

    ## Options

      * `:path` — directory for the RocksDB database (**required**)
      * `:open_opts` — extra options merged into `:rocksdb.open/2`
        (default `[create_if_missing: true]`)
    """

    @behaviour Hotline.Store

    @impl true
    def init(opts) do
      path = Keyword.fetch!(opts, :path)
      File.mkdir_p!(Path.dirname(path))
      open_opts = Keyword.get(opts, :open_opts, create_if_missing: true)
      :rocksdb.open(String.to_charlist(path), open_opts)
    end

    @impl true
    def put(db, coll, key, value) do
      :rocksdb.put(db, enc_key(coll, key), enc_val(value), [])
    end

    @impl true
    def delete(db, coll, key) do
      :rocksdb.delete(db, enc_key(coll, key), [])
    end

    @impl true
    def get(db, coll, key) do
      case :rocksdb.get(db, enc_key(coll, key), []) do
        {:ok, bin} -> {:ok, dec_val(bin)}
        :not_found -> :error
      end
    end

    @impl true
    def list(db, coll) do
      fold(db, coll, fn _key, value_bin, acc -> [dec_val(value_bin) | acc] end, [])
    end

    @impl true
    def keys(db, coll) do
      fold(db, coll, fn key_bin, _value, acc -> [dec_key(coll, key_bin) | acc] end, [])
    end

    @impl true
    def close(db) do
      :rocksdb.close(db)
    end

    # --- Internal ---

    # Namespace prefix for a collection. The trailing NUL byte cannot appear in the
    # Atom.to_string/1 name, so it cleanly bounds the collection's key range.
    defp prefix(coll), do: Atom.to_string(coll) <> <<0>>

    defp enc_key(coll, key), do: prefix(coll) <> :erlang.term_to_binary(key)

    defp dec_key(coll, key_bin) do
      psize = byte_size(prefix(coll))

      key_bin
      |> binary_part(psize, byte_size(key_bin) - psize)
      |> :erlang.binary_to_term([:safe])
    end

    defp enc_val(value), do: :erlang.term_to_binary(value)
    defp dec_val(bin), do: :erlang.binary_to_term(bin, [:safe])

    # Iterate the contiguous key range for a collection, folding matching entries.
    defp fold(db, coll, fun, acc0) do
      p = prefix(coll)
      {:ok, it} = :rocksdb.iterator(db, [])

      try do
        fold_loop(it, :rocksdb.iterator_move(it, {:seek, p}), p, fun, acc0)
      after
        :rocksdb.iterator_close(it)
      end
    end

    defp fold_loop(it, {:ok, key_bin, value_bin}, p, fun, acc) do
      if binary_prefix?(key_bin, p) do
        acc = fun.(key_bin, value_bin, acc)
        fold_loop(it, :rocksdb.iterator_move(it, :next), p, fun, acc)
      else
        # Iterator has walked past this collection's range (keys are ordered).
        acc
      end
    end

    defp fold_loop(_it, {:error, :invalid_iterator}, _p, _fun, acc), do: acc

    defp binary_prefix?(bin, prefix) do
      psize = byte_size(prefix)
      byte_size(bin) >= psize and binary_part(bin, 0, psize) == prefix
    end
  end
end
