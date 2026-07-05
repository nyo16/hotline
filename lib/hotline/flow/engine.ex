defmodule Hotline.Flow.Engine do
  @moduledoc """
  GenServer that manages active conversation flows per chat.

  Subscribes to PubSub updates and routes them to the correct flow.
  Sends prompts and error messages back via the Telegram API.

  ## Supervision Tree

  Add the Engine before any bots that use flows:

      children = [
        {Hotline.Poller, []},
        {Hotline.Flow.Engine, []},
        {MyBot, []}
      ]

  ## Starting Flows

      # From a Bot's handle_update/2:
      def handle_update(%{message: %{text: "/register", chat: %{id: chat_id}}}, state) do
        Hotline.Flow.Engine.start_flow(chat_id, MyBot.Flows.Registration)
        {:noreply, state}
      end

  ## Integration with Bots

  Use `handles_update?/1` to skip updates being handled by an active flow:

      def handle_update(update, state) do
        unless Hotline.Flow.Engine.handles_update?(update) do
          # normal handling
        end
        {:noreply, state}
      end

  ## Testing

  Inject a `:sender` function to capture messages in tests:

      test_pid = self()
      sender = fn params, _opts -> send(test_pid, {:sent, params}); {:ok, %{}} end
      {:ok, engine} = Engine.start_link(sender: sender, name: :test_engine)
  """

  use GenServer

  require Logger

  alias Hotline.Flow.Runner

  def start_link(opts \\ []) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Start a flow for a chat.

  Returns `{:error, :flow_active}` if one is already running, or
  `{:error, :flow_start_failed}` if the `flow_module` raises while starting
  (e.g. a module that does not `use Hotline.Flow`). A failed start never
  crashes the Engine, so other chats' in-flight flows are unaffected.
  """
  @spec start_flow(integer(), module(), map(), GenServer.server()) ::
          :ok | {:error, :flow_active | :flow_start_failed}
  def start_flow(chat_id, flow_module, opts \\ %{}, engine \\ __MODULE__) do
    GenServer.call(engine, {:start_flow, chat_id, flow_module, opts})
  end

  @doc "Cancel the active flow for a chat."
  @spec cancel_flow(integer(), GenServer.server()) :: :ok | {:error, :no_flow}
  def cancel_flow(chat_id, engine \\ __MODULE__) do
    GenServer.call(engine, {:cancel_flow, chat_id})
  end

  @doc "Check if a chat has an active flow."
  @spec active_flow?(integer(), GenServer.server()) :: boolean()
  def active_flow?(chat_id, engine \\ __MODULE__) do
    GenServer.call(engine, {:active_flow?, chat_id})
  end

  @doc "Check if an update belongs to a chat with an active flow."
  @spec handles_update?(map(), GenServer.server()) :: boolean()
  def handles_update?(update, engine \\ __MODULE__) do
    case extract_chat_id(update) do
      nil -> false
      chat_id -> active_flow?(chat_id, engine)
    end
  end

  # Server

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(Hotline.PubSub, "hotline:updates")

    sender = opts[:sender] || (&Hotline.send_message/2)
    answer_callback = opts[:answer_callback] || (&Hotline.answer_callback_query/2)

    {:ok, %{flows: %{}, opts: opts, sender: sender, answer_callback: answer_callback}}
  end

  @impl true
  def handle_call({:start_flow, chat_id, flow_module, flow_opts}, _from, state) do
    if Map.has_key?(state.flows, chat_id) do
      {:reply, {:error, :flow_active}, state}
    else
      # Isolate start failures the same way handle_info isolates update failures:
      # a misconfigured flow_module must not crash the Engine and drop every other
      # chat's flow state. Degrade to {:error, _} with the existing state intact.
      # The rescue is scoped to Runner.start only — effect sends are isolated
      # separately in execute_effects/2, so a send failure is no longer mislabeled
      # as :flow_start_failed (review W1).
      case safe_start(flow_module, chat_id, flow_opts) do
        {:ok, ctx, effects} ->
          execute_effects(effects, state)
          state = put_or_remove_flow(state, chat_id, ctx, effects)
          {:reply, :ok, state}

        {:error, :flow_start_failed} ->
          {:reply, {:error, :flow_start_failed}, state}
      end
    end
  end

  def handle_call({:cancel_flow, chat_id}, _from, state) do
    case Map.pop(state.flows, chat_id) do
      {nil, _} ->
        {:reply, {:error, :no_flow}, state}

      {ctx, flows} ->
        safe_callback(ctx.flow_module, :on_cancel, [ctx])
        {:reply, :ok, %{state | flows: flows}}
    end
  end

  def handle_call({:active_flow?, chat_id}, _from, state) do
    {:reply, Map.has_key?(state.flows, chat_id), state}
  end

  @impl true
  def handle_info({:hotline_update, update}, state) do
    chat_id = extract_chat_id(update)

    case chat_id && Map.get(state.flows, chat_id) do
      nil ->
        {:noreply, state}

      ctx ->
        {new_ctx, effects} =
          try do
            Runner.handle_update(ctx, update)
          rescue
            e ->
              Logger.warning(
                "Flow #{inspect(ctx.flow_module)} crashed on step #{ctx.step}: #{Exception.message(e)}"
              )

              safe_callback(ctx.flow_module, :on_cancel, [ctx])
              {ctx, [{:cancel, ctx}]}
          end

        # Answer callback queries to remove loading spinner
        if update.callback_query do
          safe_answer_callback(update.callback_query, state)
        end

        execute_effects(effects, state)
        state = put_or_remove_flow(state, chat_id, new_ctx, effects)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Redact the bot token (carried in :opts and threaded to the sender) from SASL
  # crash reports and :sys.get_status/1 output.
  @impl true
  def format_status(status) do
    case status do
      %{state: %{opts: opts} = state} -> %{status | state: %{state | opts: redact_token(opts)}}
      _ -> status
    end
  end

  defp redact_token(opts) when is_list(opts) do
    if Keyword.has_key?(opts, :token), do: Keyword.put(opts, :token, "[REDACTED]"), else: opts
  end

  defp redact_token(opts), do: opts

  # Helpers

  defp put_or_remove_flow(state, chat_id, ctx, effects) do
    terminal? =
      Enum.any?(effects, fn
        {:done, _} -> true
        {:cancel, _} -> true
        _ -> false
      end)

    if terminal? do
      # Call on_done for :done effects
      for {:done, done_ctx} <- effects do
        safe_callback(done_ctx.flow_module, :on_done, [done_ctx])
      end

      %{state | flows: Map.delete(state.flows, chat_id)}
    else
      %{state | flows: Map.put(state.flows, chat_id, ctx)}
    end
  end

  defp execute_effects(effects, state) do
    for effect <- effects do
      case effect do
        {:send_message, chat_id, text, nil} ->
          safe_send(state, %{chat_id: chat_id, text: text})

        {:send_message, chat_id, text, keyboard} ->
          reply_markup = %{inline_keyboard: keyboard}
          safe_send(state, %{chat_id: chat_id, text: text, reply_markup: reply_markup})

        _ ->
          :ok
      end
    end
  end

  # Isolate a single chat's send failure (mirrors safe_answer_callback): the sender
  # is called outside any try in handle_info/start_flow, so a raising sender — a
  # misconfig or a custom test/injected sender — would otherwise crash the Engine
  # and drop EVERY chat's in-flight flow. Degrade to a logged warning instead.
  defp safe_send(state, params) do
    state.sender.(params, state.opts)
  rescue
    e ->
      Logger.warning(
        "Flow send_message failed for chat #{params[:chat_id]}: #{Exception.message(e)}"
      )

      :ok
  end

  # Guard only the flow start (e.g. a module that doesn't `use Hotline.Flow`); the
  # effect sends it produces are isolated separately in execute_effects/2.
  defp safe_start(flow_module, chat_id, flow_opts) do
    {ctx, effects} = Runner.start(flow_module, chat_id, flow_opts)
    {:ok, ctx, effects}
  rescue
    e ->
      Logger.warning(
        "Flow #{inspect(flow_module)} failed to start for chat #{chat_id}: #{Exception.message(e)}"
      )

      {:error, :flow_start_failed}
  end

  defp safe_callback(module, function, args) do
    if function_exported?(module, function, length(args)) do
      apply(module, function, args)
    end
  rescue
    e ->
      Logger.warning("Flow callback #{function} failed: #{Exception.message(e)}")
  end

  defp safe_answer_callback(callback_query, state) do
    id = if is_map(callback_query), do: Map.get(callback_query, :id)

    if id do
      # Routed through an injectable seam (defaults to Hotline.answer_callback_query/2)
      # so tests can assert on a double instead of hitting a live Telegram boundary.
      state.answer_callback.(%{callback_query_id: id}, state.opts)
    end
  rescue
    e ->
      Logger.warning("Failed to answer callback query: #{Exception.message(e)}")
      :ok
  end

  @doc false
  def extract_chat_id(%{message: %{chat: %{id: id}}}), do: id
  def extract_chat_id(%{callback_query: %{message: %{chat: %{id: id}}}}), do: id
  def extract_chat_id(%{edited_message: %{chat: %{id: id}}}), do: id
  def extract_chat_id(_), do: nil
end
