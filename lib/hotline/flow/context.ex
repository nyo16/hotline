defmodule Hotline.Flow.Context do
  @moduledoc """
  Flow execution context passed to prompt functions and `handle_input/3` callbacks.

  Holds the current step, accumulated data, and metadata for a running flow.

  ## Fields

    * `:flow_module` — the module implementing `Hotline.Flow`
    * `:chat_id` — Telegram chat ID this flow belongs to
    * `:step` — current step atom (e.g. `:name`, `:confirm`)
    * `:data` — accumulated data map, built up via `{:next, store: %{...}}`
    * `:opts` — user-provided options passed when starting the flow

  ## Example

      ctx = Context.new(MyFlow, 123)
      ctx = Context.store(ctx, %{name: "Alice"})
      ctx.data.name
      #=> "Alice"
  """

  defstruct [:flow_module, :chat_id, :step, data: %{}, opts: %{}]

  @type t :: %__MODULE__{
          flow_module: module(),
          chat_id: integer(),
          step: atom() | nil,
          data: map(),
          opts: map()
        }

  @doc "Create a new context for a flow."
  @spec new(module(), integer(), map()) :: t()
  def new(flow_module, chat_id, opts \\ %{}) do
    %__MODULE__{
      flow_module: flow_module,
      chat_id: chat_id,
      step: nil,
      data: %{},
      opts: opts
    }
  end

  @doc "Merge new data into the context's accumulated data."
  @spec store(t(), map()) :: t()
  def store(%__MODULE__{data: data} = ctx, new_data) when is_map(new_data) do
    %{ctx | data: Map.merge(data, new_data)}
  end

  @doc "Move the context to a specific step."
  @spec move_to(t(), atom()) :: t()
  def move_to(%__MODULE__{} = ctx, step) when is_atom(step) do
    %{ctx | step: step}
  end
end
