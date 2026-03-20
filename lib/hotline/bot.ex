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

  ## Restricting by user ID

  Pass `allowed_ids` to only accept updates from specific users:

      children = [
        {MyBot, token: "your-bot-token", allowed_ids: [7644580464]}
      ]

  Updates from other users are silently dropped. Omit `allowed_ids` to accept all.
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
          allowed_ids: init_opts[:allowed_ids],
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
        sender_id = Hotline.Bot.extract_sender_id(update)

        if Hotline.Bot.allowed?(sender_id, state.allowed_ids) do
          state =
            case update do
              %{message: %{chat: %{id: chat_id}}} when is_nil(state.chat_id) ->
                %{state | chat_id: chat_id}

              _ ->
                state
            end

          handle_update(update, state)
        else
          {:noreply, state}
        end
      end

      def handle_info(_msg, state), do: {:noreply, state}

      defoverridable start_link: 1, init: 1
    end
  end

  @doc false
  def allowed?(_sender_id, nil), do: true
  def allowed?(nil, _allowed_ids), do: false
  def allowed?(sender_id, allowed_ids), do: sender_id in allowed_ids

  @doc false
  def extract_sender_id(%{message: %{from: %{id: id}}}), do: id
  def extract_sender_id(%{callback_query: %{from: %{id: id}}}), do: id
  def extract_sender_id(%{edited_message: %{from: %{id: id}}}), do: id
  def extract_sender_id(%{channel_post: %{chat: %{id: id}}}), do: id
  def extract_sender_id(_), do: nil
end
