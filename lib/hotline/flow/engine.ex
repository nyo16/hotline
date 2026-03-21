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

  @doc "Start a flow for a chat. Returns `{:error, :flow_active}` if one is already running."
  @spec start_flow(integer(), module(), map(), GenServer.server()) :: :ok | {:error, :flow_active}
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

    {:ok, %{flows: %{}, opts: opts, sender: sender}}
  end

  @impl true
  def handle_call({:start_flow, chat_id, flow_module, flow_opts}, _from, state) do
    if Map.has_key?(state.flows, chat_id) do
      {:reply, {:error, :flow_active}, state}
    else
      {ctx, effects} = Runner.start(flow_module, chat_id, flow_opts)
      execute_effects(effects, state)
      state = put_or_remove_flow(state, chat_id, ctx, effects)
      {:reply, :ok, state}
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
          state.sender.(%{chat_id: chat_id, text: text}, state.opts)

        {:send_message, chat_id, text, keyboard} ->
          reply_markup = %{inline_keyboard: keyboard}
          state.sender.(%{chat_id: chat_id, text: text, reply_markup: reply_markup}, state.opts)

        _ ->
          :ok
      end
    end
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
      opts = state.opts
      Hotline.answer_callback_query(%{callback_query_id: id}, opts)
    end
  rescue
    _ -> :ok
  end

  @doc false
  def extract_chat_id(%{message: %{chat: %{id: id}}}), do: id
  def extract_chat_id(%{callback_query: %{message: %{chat: %{id: id}}}}), do: id
  def extract_chat_id(%{edited_message: %{chat: %{id: id}}}), do: id
  def extract_chat_id(_), do: nil
end
