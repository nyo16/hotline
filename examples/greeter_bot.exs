# Greeter Bot — responds to /start and /help commands.
#
# Usage:
#   HOTLINE_TOKEN="your-bot-token" mix run examples/greeter_bot.exs

defmodule GreeterBot do
  use Hotline.Bot

  @impl Hotline.Bot
  def handle_update(%{message: %{text: "/start", chat: %{id: chat_id}}} = _update, state) do
    Hotline.send_message(%{chat_id: chat_id, text: "Welcome! I'm a Hotline bot. Try /help."})
    {:noreply, state}
  end

  def handle_update(%{message: %{text: "/help", chat: %{id: chat_id}}} = _update, state) do
    help = """
    Available commands:
    /start - Welcome message
    /help  - Show this help
    /ping  - Check if I'm alive
    /whoami - Show your user info
    """

    Hotline.send_message(%{chat_id: chat_id, text: help})
    {:noreply, state}
  end

  def handle_update(%{message: %{text: "/ping", chat: %{id: chat_id}}} = _update, state) do
    Hotline.send_message(%{chat_id: chat_id, text: "Pong!"})
    {:noreply, state}
  end

  def handle_update(
        %{message: %{text: "/whoami", chat: %{id: chat_id}, from: from}} = _update,
        state
      ) do
    info = """
    User ID: #{from.id}
    Name: #{from.first_name} #{from.last_name || ""}
    Username: #{from.username || "not set"}
    Language: #{from.language_code || "unknown"}
    """

    Hotline.send_message(%{chat_id: chat_id, text: String.trim(info)})
    {:noreply, state}
  end

  def handle_update(_update, state) do
    {:noreply, state}
  end
end

children = [
  {Hotline.Poller, []},
  {GreeterBot, []}
]

{:ok, _} = Supervisor.start_link(children, strategy: :one_for_one)

IO.puts("Greeter bot running! Send /start to your bot. Press Ctrl+C to stop.")
Process.sleep(:infinity)
