defmodule Hotline.Flow.Runner do
  @moduledoc """
  Pure flow execution logic with no side effects.

  All functions return `{context, effects}` tuples where effects are
  instructions for the caller (typically `Hotline.Flow.Engine`) to execute.

  This separation makes flows trivially testable — call `start/3` and
  `handle_update/2` directly with hand-built update structs.

  ## Effect Types

    * `{:send_message, chat_id, text, keyboard}` — send a Telegram message
    * `{:done, context}` — the flow completed
    * `{:cancel, context}` — the flow was cancelled

  ## Example

      {ctx, effects} = Runner.start(MyFlow, 123)
      assert [{:send_message, 123, "What's your name?", nil}] = effects

      update = %{message: %{text: "Alice", chat: %{id: 123}}}
      {ctx, effects} = Runner.handle_update(ctx, update)
  """

  alias Hotline.Flow.Context

  @type effect ::
          {:send_message, integer(), String.t(), map() | nil}
          | {:done, Context.t()}
          | {:cancel, Context.t()}

  @doc "Initialize a flow and return the first step's prompt effects."
  @spec start(module(), integer(), map()) :: {Context.t(), [effect()]}
  def start(flow_module, chat_id, opts \\ %{}) do
    ctx = Context.new(flow_module, chat_id, opts)

    case flow_module.__steps__() do
      [first_step | _] ->
        ctx = Context.move_to(ctx, first_step)
        {ctx, build_prompt_effects(ctx)}

      [] ->
        {ctx, [{:done, ctx}]}
    end
  end

  @doc "Process an incoming update against the current flow context."
  @spec handle_update(Context.t(), map()) :: {Context.t(), [effect()]}
  def handle_update(%Context{} = ctx, update) do
    result = ctx.flow_module.handle_input(ctx.step, update, ctx)
    process_result(ctx, result)
  end

  defp process_result(ctx, :next) do
    advance(ctx)
  end

  defp process_result(ctx, {:next, opts}) do
    ctx = maybe_store(ctx, opts)
    advance(ctx)
  end

  defp process_result(ctx, {:goto, step}) do
    ctx = Context.move_to(ctx, step)
    {ctx, build_prompt_effects(ctx)}
  end

  defp process_result(ctx, {:goto, step, opts}) do
    ctx = if Keyword.get(opts, :reset, false), do: %{ctx | data: %{}}, else: ctx
    ctx = maybe_store(ctx, opts)
    ctx = Context.move_to(ctx, step)
    {ctx, build_prompt_effects(ctx)}
  end

  defp process_result(ctx, {:retry, message}) do
    {ctx, [{:send_message, ctx.chat_id, message, nil}]}
  end

  defp process_result(ctx, :done) do
    {ctx, [{:done, ctx}]}
  end

  defp process_result(ctx, {:done, result}) do
    ctx = Context.store(ctx, %{__result__: result})
    {ctx, [{:done, ctx}]}
  end

  defp process_result(ctx, :cancel) do
    {ctx, [{:cancel, ctx}]}
  end

  defp advance(ctx) do
    case next_step(ctx.flow_module, ctx.step) do
      {:ok, next} ->
        ctx = Context.move_to(ctx, next)
        {ctx, build_prompt_effects(ctx)}

      :done ->
        {ctx, [{:done, ctx}]}
    end
  end

  defp next_step(flow_module, current_step) do
    steps = flow_module.__steps__()

    # O(n) scan per transition — fine because __steps__/0 is a small, compile-time
    # list of step names (a flow has a handful of steps, not thousands).
    case Enum.drop_while(steps, &(&1 != current_step)) do
      [^current_step, next | _] -> {:ok, next}
      _ -> :done
    end
  end

  defp build_prompt_effects(%Context{} = ctx) do
    prompt = ctx.flow_module.__prompt__(ctx.step, ctx)
    keyboard = ctx.flow_module.__keyboard__(ctx.step, ctx)

    if prompt do
      [{:send_message, ctx.chat_id, prompt, keyboard}]
    else
      []
    end
  end

  defp maybe_store(ctx, opts) do
    case Keyword.get(opts, :store) do
      nil -> ctx
      data when is_map(data) -> Context.store(ctx, data)
    end
  end
end
