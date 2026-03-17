defmodule Hotline.Bot do
  @moduledoc """
  Behaviour and GenServer for building Telegram bots.

  Usage:

      defmodule MyBot do
        use Hotline.Bot

        @impl Hotline.Bot
        def handle_update(update, state) do
          case update.message do
            %{text: "/start"} ->
              Hotline.send_message(%{chat_id: state.chat_id, text: "Hello!"})
            _ ->
              :ok
          end

          {:noreply, state}
        end
      end

  Start the bot in your supervision tree:

      children = [
        {MyBot, token: "your-bot-token"}
      ]
  """

  @callback handle_update(Hotline.Types.Update.t(), map()) :: {:noreply, map()}
  @callback init_bot(map()) :: {:ok, map()}

  @optional_callbacks init_bot: 1

  defmacro __using__(opts) do
    quote do
      use GenServer

      @behaviour Hotline.Bot

      def start_link(init_opts \\ []) do
        name = unquote(opts[:name]) || Keyword.get(init_opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, init_opts, name: name)
      end

      @impl GenServer
      def init(init_opts) do
        Phoenix.PubSub.subscribe(Hotline.PubSub, "hotline:updates")

        state = %{
          chat_id: init_opts[:chat_id],
          opts: init_opts
        }

        state =
          if function_exported?(__MODULE__, :init_bot, 1) do
            case init_bot(state) do
              {:ok, new_state} -> new_state
              _ -> state
            end
          else
            state
          end

        {:ok, state}
      end

      @impl GenServer
      def handle_info({:hotline_update, update}, state) do
        state =
          case update do
            %{message: %{chat: %{id: chat_id}}} when is_nil(state.chat_id) ->
              %{state | chat_id: chat_id}

            _ ->
              state
          end

        handle_update(update, state)
      end

      def handle_info(_msg, state), do: {:noreply, state}

      defoverridable start_link: 1, init: 1
    end
  end
end
