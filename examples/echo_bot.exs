# Echo Bot — replies with whatever the user sends.
#
# Usage:
#   HOTLINE_TOKEN="your-bot-token" mix run examples/echo_bot.exs
#
# Send a message to your bot in Telegram and it will echo it back.

defmodule EchoBot do
  use Hotline.Bot

  @impl Hotline.Bot
  def handle_update(%{message: %{text: text, chat: %{id: chat_id}}}, state)
      when is_binary(text) do
    Hotline.send_message(%{chat_id: chat_id, text: text})
    {:noreply, state}
  end

  def handle_update(_update, state) do
    {:noreply, state}
  end
end

children = [
  {Hotline.Poller, []},
  {EchoBot, []}
]

{:ok, _} = Supervisor.start_link(children, strategy: :one_for_one)

IO.puts("Echo bot running! Send a message to your bot in Telegram. Press Ctrl+C to stop.")
Process.sleep(:infinity)
