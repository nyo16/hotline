# Pluggable persistence backend for Hotline (Store adapter)

**Date:** 2026-07-05
**Status:** Design approved, pending spec review
**Branch context:** `harden-bot-flow-dsl`

## Motivation

`Hotline.ChatRegistry` currently persists tracked chats with **DETS** (disk-based
ETS, part of OTP). DETS was chosen for one reason: **zero dependencies** — Hotline
is a library published to Hex, and DETS lets a user drop
`{Hotline.ChatRegistry, dets_path: ...}` into a supervision tree with no external
service, driver, NIF, or migration.

DETS's limits are real, though: a 2 GB per-table cap, single-node (local file),
single-writer with a repair scan after unclean shutdown, no querying beyond a
full-table scan, and weak write throughput (the fsync-per-message problem
addressed by the recent debounced-sync change).

Rather than swap DETS for one specific database — which would either force a
dependency on every consumer or lock the library into one deployment model — this
design makes the **persistence backend pluggable** behind a small behaviour, with
a zero-dependency default and opt-in adapters for heavier backends.

### Drivers (all four in play → no single backend wins)

| Driver | Best served by |
|---|---|
| Throughput / durability (single node) | RocksDB (LSM, write-optimized) |
| Querying / analytics (SQL) | SQLite / Postgres |
| Multi-node / distributed | Postgres |
| Modularity / future-proofing | the adapter seam itself |

No single backend satisfies all four, which is precisely why the architecture is a
pluggable adapter. DuckDB is intentionally **excluded** as a write backend — it is
an OLAP/columnar engine, wrong for transactional per-message upserts; it belongs
downstream as an analytics/export target fed from Postgres, not as a `Store`.

## Architecture

**Keep the ETS read cache; put the pluggable backend behind it.**

`ChatRegistry` already serves `get`/`list`/`count` from a public ETS table with no
GenServer round-trip. That stays, unconditionally, for every backend. Only the
**durable Store** behind the cache is pluggable.

```
updates ──► ChatRegistry (GenServer, per node)
                │  write-through
                ├──► ETS cache    (always; lock-free hot reads: get/list/count)
                └──► Store adapter (durable; DETS │ RocksDB │ SQLite │ Postgres)

reads ─────► ETS cache directly    (never touch the Store)
boot ──────► Store.list ──► load into ETS
```

Consequences:

- **Reads never depend on the backend.** Swapping DETS→Postgres cannot slow down
  `get`/`list`, because those hit ETS. The Store only sees writes (`put`/`delete`)
  and one bulk read at boot (restore).
- **Durability policy is the adapter's job.** The debounced-sync logic recently
  added to `ChatRegistry` is a *DETS* concern and moves into the DETS adapter.
  RocksDB uses WAL + async writes; SQLite uses WAL; Postgres commits per write. The
  generic contract stays dumb about durability.
- **Multi-node falls out naturally.** Every node's `ChatRegistry` already receives
  every update via the global PubSub topic, so each node write-throughs to its
  local ETS *and* the shared Store (e.g. Postgres). The per-node ETS caches
  converge because all nodes process the same update stream; the Store is the
  shared durable copy. No cache-invalidation machinery is needed for this
  low-stakes directory data (slightly stale `last_seen` across nodes is
  acceptable). Write amplification (N nodes upserting the same chat) is acceptable
  for a low-write registry and can be optimized later.

## The `Store` behaviour

Generic key/value contract — **not** registry-specific, so `Flow` state can reuse
it later via a different collection. Adapters own an opaque handle.

```elixir
defmodule Hotline.Store do
  @type coll :: atom          # :chats now, :flows later
  @type handle :: term        # opaque per-adapter state (dets ref, db handle, repo…)
  @type key :: term
  @type value :: map

  @callback init(opts :: keyword) :: {:ok, handle} | {:error, term}
  @callback put(handle, coll, key, value) :: :ok
  @callback delete(handle, coll, key) :: :ok
  @callback get(handle, coll, key) :: {:ok, value} | :error
  @callback list(handle, coll) :: [value]     # used at boot to warm ETS
  @callback keys(handle, coll) :: [key]
  @callback close(handle) :: :ok              # flush + release on clean stop
end
```

- The contract is intentionally **KV-only**. Analytics/SQL is done out-of-band
  against the user's own Postgres/SQLite, outside this abstraction. This keeps the
  contract implementable identically by every backend from ETS to Postgres.
- `get` is part of the contract (useful for a bare Store with no front cache, and
  for future flow-state use), but `ChatRegistry`'s hot reads use the ETS cache, not
  `Store.get`. The registry calls `init`/`list`/`close` at lifecycle boundaries and
  `put`/`delete` on writes.

## Adapters

### Packaging

In-core, with **optional deps** — the pattern already used for
`Hotline.BroadwayProducer` (`if Code.ensure_loaded?(Broadway)`):

- `Hotline.Store.DETS`, `Hotline.Store.ETS` — zero deps, always compiled.
- `Hotline.Store.RocksDB` (and future `.SQLite` / `.Postgres`) — module body
  wrapped in `if Code.ensure_loaded?(:rocksdb)`; compiled only when the user adds
  the dep. `mix.exs` lists these `optional: true`. No dep is forced on anyone.

### `Hotline.Store.DETS` (default)

The current `ChatRegistry` DETS logic moved behind the behaviour, unchanged in
behavior:

- Directory locked to `0700` before file creation; file to `0600` (best effort,
  warn-not-crash on filesystems without POSIX modes).
- Debounced disk flush (`sync_interval`, default `5_000` ms; dirty-flag; sync on
  the timer and on `close`). SIGKILL can lose writes newer than one interval; a
  clean stop always flushes.
- Collections keyed within a single DETS table (or one table per collection —
  decided at plan time; single table with `{coll, key}` tuples keeps the file
  count down).

### `Hotline.Store.ETS` (in-memory reference / test double)

- Zero-dep, non-persistent (`init` creates a table, `close` drops it).
- Simplest reference implementation of the behaviour and the default backend for
  `ChatRegistry` unit tests that don't care about persistence (faster, no tmp
  files).

### `Hotline.Store.RocksDB`

Backed by the `:rocksdb` Erlang NIF bindings.

- **Open/close:** `:rocksdb.open(path_charlist, create_if_missing: true)` in
  `init`; `:rocksdb.close/1` in `close`.
- **Collections:** each collection maps to a RocksDB **column family** (the
  idiomatic separation), or, as a simpler first cut, a key prefix
  (`"<coll>:" <> encoded_key`). Plan step to choose; column families preferred for
  clean `list`/`keys` per collection.
- **Serialization:** keys and values are binaries. Values (chat maps) via
  `:erlang.term_to_binary/1` ↔ `:erlang.binary_to_term(bin, [:safe])`. Keys
  (integer chat ids) via `:erlang.term_to_binary/1`.
- **Durability:** `:rocksdb.put` with async WAL (default) for throughput; a
  `sync: true` option exposed for callers that want per-write fsync. This is the
  headline throughput/durability win over DETS (LSM trees are built for high-rate
  upserts; no 2 GB cap; no repair-scan).
- **list/keys:** RocksDB iterator over the column family / prefix.
- **Cost:** heavy NIF build (C++ toolchain, slow first compile). Optional dep only.

## Configuration & backward compatibility

```elixir
# New, explicit:
{Hotline.ChatRegistry, store: {Hotline.Store.RocksDB, path: "priv/hotline/chats.db"}}

# Default when :store omitted → DETS adapter:
{Hotline.ChatRegistry, store: {Hotline.Store.DETS, path: "...", sync_interval: 5_000}}

# Existing API keeps working, mapped onto the default DETS adapter:
{Hotline.ChatRegistry, dets_path: "priv/chats.dets"}   # → {Hotline.Store.DETS, path: ...}
```

- `:store` is `{module, opts}`. When omitted, `ChatRegistry` builds the DETS
  adapter from the existing `:dets_path` / `:sync_interval` opts and the
  `:chat_registry_path` / `:chat_registry_sync_interval` app-env keys.
- **No breaking change.** All current options and app-env keys continue to work.
- Postgres (follow-on) takes a **user-provided `repo:`** (their existing
  `Ecto.Repo`) + table name, plus a migration helper — Hotline never owns a
  connection pool or forces Ecto.

## Scope

### In scope (this spec)

1. `Hotline.Store` behaviour.
2. `ChatRegistry` refactored to ETS-cache + Store (identical external behavior).
3. `Hotline.Store.DETS` — current logic moved behind the behaviour (default;
   existing tests must stay green).
4. `Hotline.Store.ETS` — in-memory, zero-dep reference adapter / test double.
5. `Hotline.Store.RocksDB` — real single-node throughput/durability adapter
   (optional `:rocksdb` dep).
6. Back-compat shim for `:dets_path` / `:sync_interval` / app-env.

### Out of scope (follow-on specs, enabled by the seam)

- `Hotline.Store.SQLite` / `Hotline.Store.Postgres` (SQL, multi-node).
- Flow-state persistence via the same `Store` (`:flows` collection).
- Multi-node poller singleton (only one Telegram `getUpdates` consumer per token
  across a cluster) — a separate cluster-readiness concern, not a Store concern.
- DuckDB analytics/export pipeline.

## Testing

- **Behaviour conformance suite** — one shared test module run against *every*
  adapter (`for adapter <- [Hotline.Store.ETS, Hotline.Store.DETS,
  Hotline.Store.RocksDB]`), proving the same contract: put/get/delete/list/keys,
  and restore-after-reopen for the persistent ones.
- **DETS adapter** inherits the current `ChatRegistry` persistence tests
  (permissions, brutal-kill-after-sync, periodic sync) — behavior is unchanged, so
  they must stay green (moved/retargeted to the adapter).
- **RocksDB adapter** tests gated on `Code.ensure_loaded?(:rocksdb)` so the suite
  runs without the optional dep present (skip/exclude tag when absent).
- **ChatRegistry** tests use the in-memory `ETS` adapter by default → faster, no
  tmp files for cases that don't exercise persistence.

## Open questions (resolve at plan time)

1. RocksDB collection separation: column families vs key prefix (lean: column
   families).
2. DETS collection layout: single table with `{coll, key}` tuples vs one table per
   collection (lean: single table).
3. Whether the `ETS` adapter and the `ChatRegistry` front cache should share code
   or stay deliberately separate (they serve different roles — cache vs backend —
   so likely separate).
