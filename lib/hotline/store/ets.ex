defmodule Hotline.Store.ETS do
  @moduledoc """
  In-memory `Hotline.Store` adapter backed by a single ETS table.

  Zero dependencies and **non-persistent** — the data lives only for the lifetime
  of the owning process (`close/1` drops the table). Intended as the simplest
  reference implementation of the behaviour and as a fast, file-free test double.

  Collections share one table via composite `{collection, key}` keys.

  ## Options

    * `:name` — optional atom used to name the ETS table (default: an anonymous
      table). An anonymous table is fine for a single store; name it only if you
      need to reach it by name.
  """

  @behaviour Hotline.Store

  @impl true
  def init(opts) do
    base = [:set, :public]
    ets_opts = if opts[:name], do: [:named_table | base], else: base
    table = :ets.new(opts[:name] || :hotline_store_ets, ets_opts)
    {:ok, table}
  end

  @impl true
  def put(table, coll, key, value) do
    :ets.insert(table, {{coll, key}, value})
    :ok
  end

  @impl true
  def delete(table, coll, key) do
    :ets.delete(table, {coll, key})
    :ok
  end

  @impl true
  def get(table, coll, key) do
    case :ets.lookup(table, {coll, key}) do
      [{_k, value}] -> {:ok, value}
      [] -> :error
    end
  end

  @impl true
  def list(table, coll) do
    table
    |> :ets.match_object({{coll, :_}, :_})
    |> Enum.map(fn {_k, value} -> value end)
  end

  @impl true
  def keys(table, coll) do
    table
    |> :ets.match({{coll, :"$1"}, :_})
    |> Enum.map(fn [key] -> key end)
  end

  @impl true
  def close(table) do
    :ets.delete(table)
    :ok
  end
end
