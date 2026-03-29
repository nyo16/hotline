# Example: Bot using the declarative DSL
#
# Run with:
#   HOTLINE_TOKEN=your-token elixir examples/dsl_bot.exs

defmodule DslBot do
  use Hotline.Bot

  # Uncomment to restrict to specific user IDs:
  # allow [123_456_789]

  command "/start" do
    Hotline.send_message(%{chat_id: chat_id, text: "Welcome to DslBot!"})
  end

  command "/help" do
    help = """
    Commands:
    /start - Welcome message
    /help  - This message
    /echo  - Echo your text
    /ping  - Pong!
    """

    Hotline.send_message(%{chat_id: chat_id, text: help})
  end

  command "/echo" do
    text = if args == "", do: "Echo what? Usage: /echo <text>", else: args
    Hotline.send_message(%{chat_id: chat_id, text: text})
  end

  command "/ping" do
    Hotline.send_message(%{chat_id: chat_id, text: "Pong!"})
  end

  on :message do
    Hotline.send_message(%{
      chat_id: chat_id,
      text: "I don't understand '#{message.text}'. Try /help"
    })
  end

  on :callback_query do
    Hotline.answer_callback_query(%{
      callback_query_id: callback_query.id,
      text: "Got: #{callback_query.data}"
    })
  end
end

children = [
  {Hotline.Poller, []},
  {DslBot, []}
]

{:ok, _} = Supervisor.start_link(children, strategy: :one_for_one)

IO.puts("DslBot running — press Ctrl+C to stop")
Process.sleep(:infinity)
