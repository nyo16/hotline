defmodule Hotline.Flow do
  @moduledoc """
  DSL and behaviour for building multi-step conversation flows.

  A flow is a module that declares a sequence of steps. Each step has a prompt
  (sent to the user) and the module implements `handle_input/3` to process
  responses and control transitions.

  ## Example

      defmodule MyBot.Flows.Registration do
        use Hotline.Flow

        step :name, prompt: "What's your name?"
        step :email, prompt: fn ctx -> "Thanks \#{ctx.data.name}! What's your email?" end
        step :confirm,
          prompt: fn ctx ->
            "Confirm?\\nName: \#{ctx.data.name}\\nEmail: \#{ctx.data[:email] || "skipped"}"
          end,
          keyboard: [[%{text: "Yes", callback_data: "yes"}, %{text: "No", callback_data: "no"}]]

        @impl true
        def handle_input(:name, %{message: %{text: name}}, _ctx) when byte_size(name) >= 2 do
          {:next, store: %{name: name}}
        end
        def handle_input(:name, _, _ctx), do: {:retry, "Name must be at least 2 characters."}

        def handle_input(:email, %{message: %{text: "/skip"}}, _ctx), do: {:next, store: %{email: nil}}
        def handle_input(:email, %{message: %{text: email}}, _ctx) do
          if String.contains?(email, "@"),
            do: {:next, store: %{email: email}},
            else: {:retry, "Invalid email. Try again or /skip."}
        end

        def handle_input(:confirm, %{callback_query: %{data: "yes"}}, _ctx), do: :done
        def handle_input(:confirm, %{callback_query: %{data: "no"}}, _ctx), do: {:goto, :name, reset: true}
        def handle_input(:confirm, _, _ctx), do: {:retry, "Use the buttons above."}
      end

  ## Return Values

  `handle_input/3` must return one of:

    * `:next` — advance to the next step in sequence
    * `{:next, store: %{key: value}}` — merge data, then advance
    * `{:goto, step}` — jump to a named step
    * `{:goto, step, reset: true}` — jump and clear accumulated data
    * `{:retry, message}` — stay on the current step, send error message
    * `:done` — complete the flow
    * `{:done, result}` — complete with a result value
    * `:cancel` — cancel the flow

  ## Optional Callbacks

    * `on_done/1` — called when the flow completes (receives the final context)
    * `on_cancel/1` — called when the flow is cancelled

  ## Running Flows

  Use `Hotline.Flow.Engine` to manage active flows. See `Hotline.Flow.Runner`
  for the pure execution logic.
  """

  alias Hotline.Flow.Context

  @type step_result ::
          :next
          | {:next, [{:store, map()}]}
          | {:goto, atom()}
          | {:goto, atom(), keyword()}
          | {:retry, String.t()}
          | :done
          | {:done, term()}
          | :cancel

  @callback handle_input(step :: atom(), update :: map(), ctx :: Context.t()) :: step_result()
  @callback on_done(ctx :: Context.t()) :: any()
  @callback on_cancel(ctx :: Context.t()) :: any()

  @optional_callbacks on_done: 1, on_cancel: 1

  defmacro __using__(_opts) do
    quote do
      @behaviour Hotline.Flow
      Module.register_attribute(__MODULE__, :hotline_step_names, accumulate: true)
      @before_compile Hotline.Flow
      import Hotline.Flow, only: [step: 1, step: 2]
    end
  end

  @doc """
  Declare a step in the flow.

  ## Options

    * `:prompt` — a string or `fn ctx -> string end` sent to the user when entering the step
    * `:keyboard` — inline keyboard markup (list of button rows) sent with the prompt
  """
  defmacro step(name, opts \\ []) do
    prompt_clause = build_step_clause(:__prompt__, name, Keyword.get(opts, :prompt))
    keyboard_clause = build_step_clause(:__keyboard__, name, Keyword.get(opts, :keyboard))

    quote do
      @hotline_step_names unquote(name)
      unquote(prompt_clause)
      unquote(keyboard_clause)
    end
  end

  defp build_step_clause(_fun, _name, nil), do: nil

  defp build_step_clause(fun, name, value) when is_binary(value) or is_list(value) do
    quote do
      def unquote(fun)(unquote(name), _flow_ctx), do: unquote(value)
    end
  end

  defp build_step_clause(fun, name, fn_ast) do
    quote do
      def unquote(fun)(unquote(name), flow_ctx), do: unquote(fn_ast).(flow_ctx)
    end
  end

  defmacro __before_compile__(env) do
    step_names = Module.get_attribute(env.module, :hotline_step_names) |> Enum.reverse()

    quote do
      def __steps__, do: unquote(step_names)

      def __prompt__(_step, _flow_ctx), do: nil
      def __keyboard__(_step, _flow_ctx), do: nil

      def on_done(_ctx), do: :ok
      def on_cancel(_ctx), do: :ok

      defoverridable on_done: 1, on_cancel: 1
    end
  end
end
