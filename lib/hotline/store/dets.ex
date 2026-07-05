defmodule Hotline.Store.DETS do
  @moduledoc """
  Disk-backed `Hotline.Store` adapter using DETS (part of OTP — zero dependencies).

  This is the **default** backend for `Hotline.ChatRegistry`. Collections share one
  DETS table via composite `{collection, key}` keys.

  ## Durability

  Writes go to the DETS buffer synchronously but the disk flush is **not** done per
  write — an fsync on every update would make a busy caller the throughput ceiling.
  Instead:

    * Periodic flush is delegated to DETS's own `auto_save` (set from
      `:sync_interval`, default `5_000` ms). A `:sync_interval` of `0`/`:infinity`
      disables it.
    * `close/1` always flushes (`:dets.close` syncs), so a clean stop never loses
      data.
    * `sync/1` forces an immediate flush for callers that want a hard durability
      point (also used by tests to assert crash-survival deterministically).

  Consequence: a SIGKILL/power loss can drop writes newer than one `:sync_interval`
  that were never flushed by `auto_save`, `sync/1`, or `close/1`.

  ## Data at rest

  Tracked values may be personal data persisted **unencrypted**. On `init/1` the
  adapter locks its directory to `0700` **before** creating the file — closing the
  brief world-readable window `:dets.open_file` would otherwise leave — then
  restricts the file to `0600` (best effort; skipped with a warning on filesystems
  without POSIX modes). Store the file in a private, app-owned subdirectory (not the
  shared `priv/`), and apply disk-level encryption if the data warrants it.

  ## Options

    * `:path` — DETS file path (**required**)
    * `:sync_interval` — `auto_save` interval in ms (default `5_000`; `0`/`:infinity`
      disables periodic flushing)
    * `:name` — namespace for the DETS table atom (default derived from the path).
      Must be unique per open file within the VM.
  """

  @behaviour Hotline.Store

  require Logger

  @default_sync_interval 5_000

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    sync_interval = Keyword.get(opts, :sync_interval, @default_sync_interval)
    table = opts[:name] || :"hotline_store_dets_#{:erlang.phash2(path)}"

    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    # Lock the directory to owner-only BEFORE opening the file: :dets.open_file
    # creates the file at the default umask (a brief world-readable window), and a
    # 0700 dir makes that new file unreachable by other users during that window.
    restrict_dir_permissions(dir)

    open_opts = [file: String.to_charlist(path), auto_save: auto_save(sync_interval)]

    case :dets.open_file(table, open_opts) do
      {:ok, ^table} ->
        # Then tighten the file itself — values are persisted unencrypted.
        restrict_file_permissions(path)
        {:ok, table}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def put(table, coll, key, value) do
    :dets.insert(table, {{coll, key}, value})
  end

  @impl true
  def delete(table, coll, key) do
    :dets.delete(table, {coll, key})
  end

  @impl true
  def get(table, coll, key) do
    case :dets.lookup(table, {coll, key}) do
      [{_k, value}] -> {:ok, value}
      [] -> :error
    end
  end

  @impl true
  def list(table, coll) do
    table
    |> :dets.match_object({{coll, :_}, :_})
    |> Enum.map(fn {_k, value} -> value end)
  end

  @impl true
  def keys(table, coll) do
    table
    |> :dets.match({{coll, :"$1"}, :_})
    |> Enum.map(fn [key] -> key end)
  end

  @impl true
  def close(table) do
    # :dets.close/1 flushes pending writes before releasing the file.
    :dets.close(table)
    :ok
  end

  @doc """
  Force an immediate flush of pending writes to disk.

  A hard durability point on top of the periodic `auto_save`. Not part of the
  `Hotline.Store` behaviour — specific to this adapter.
  """
  @spec sync(Hotline.Store.handle()) :: :ok
  def sync(table), do: :dets.sync(table)

  # A non-positive / :infinity interval disables auto_save, leaving durability to a
  # clean stop (close) or an explicit sync/1.
  defp auto_save(:infinity), do: :infinity
  defp auto_save(ms) when is_integer(ms) and ms > 0, do: ms
  defp auto_save(_), do: :infinity

  # Restrict the DETS directory to owner-only rwx (before the file is created).
  defp restrict_dir_permissions(dir), do: chmod_best_effort(dir, 0o700)

  # Restrict the DETS file to owner-only rw (after :dets.open_file creates it).
  defp restrict_file_permissions(path), do: chmod_best_effort(path, 0o600)

  # Best effort: File.chmod returns {:error, :enotsup} on filesystems without
  # POSIX modes (e.g. Windows); warn rather than crash the store there.
  defp chmod_best_effort(path, mode) do
    case File.chmod(path, mode) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Hotline.Store.DETS could not restrict permissions on #{path} " <>
            "(#{inspect(reason)}); ensure it is stored in a private, app-owned directory."
        )
    end
  end
end
