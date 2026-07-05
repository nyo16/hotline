defmodule Hotline.Store do
  @moduledoc """
  Behaviour for a pluggable key/value persistence backend.

  A `Store` is a generic keyed collection store — deliberately **not**
  registry-specific, so different callers (currently `Hotline.ChatRegistry`, and
  potentially flow state later) can persist through the same contract by using a
  different `collection`.

  ## The contract

  The contract is intentionally key/value only:

    * `init/1`   — open/allocate the backend, returns an opaque handle
    * `put/4`    — upsert a value under `{collection, key}`
    * `delete/3` — remove a key
    * `get/3`    — read a single value
    * `list/2`   — all values in a collection (used to warm a read cache at boot)
    * `keys/2`   — all keys in a collection
    * `close/1`  — flush and release the backend

  Rich querying / analytics is **out of scope** — do that against your own
  SQL database directly. Keeping the contract minimal is what lets every backend,
  from in-memory ETS to Postgres, implement it identically.

  ## The handle

  `init/1` returns an opaque `handle` that is threaded back into every other
  callback. Its shape is the adapter's business (an ETS tid, a DETS table name, a
  database reference, an `Ecto.Repo` + table, …). Callers must treat it as opaque.

  ## Durability

  Durability semantics are the adapter's responsibility, not the caller's. A
  backend may flush on every write, on a timer, or only on `close/1` — see each
  adapter's docs. `close/1` must always flush pending writes on a clean stop.

  ## Bundled adapters

    * `Hotline.Store.ETS`     — in-memory, zero-dep (non-persistent; tests/reference)
    * `Hotline.Store.DETS`    — disk-backed, zero-dep (the default)
    * `Hotline.Store.RocksDB` — LSM key/value, high write throughput (optional `:rocksdb`)
  """

  @type coll :: atom
  @type handle :: term
  @type key :: term
  @type value :: map

  @callback init(opts :: keyword) :: {:ok, handle} | {:error, term}
  @callback put(handle, coll, key, value) :: :ok
  @callback delete(handle, coll, key) :: :ok
  @callback get(handle, coll, key) :: {:ok, value} | :error
  @callback list(handle, coll) :: [value]
  @callback keys(handle, coll) :: [key]
  @callback close(handle) :: :ok
end
