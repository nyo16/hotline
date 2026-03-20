# Stream Logger — prints incoming updates to the console using lazy streaming.
#
# Usage:
#   HOTLINE_TOKEN="your-bot-token" mix run examples/stream_logger.exs
#
# Great for exploring the Telegram API and seeing what updates look like.

IO.puts("Streaming updates... Send a message to your bot. Press Ctrl+C to stop.\n")

Hotline.stream()
|> Stream.each(fn update ->
  IO.puts("--- Update ##{update.update_id} ---")

  cond do
    update.message ->
      msg = update.message
      from = if msg.from, do: "#{msg.from.first_name} (#{msg.from.id})", else: "unknown"
      IO.puts("  Message from: #{from}")
      IO.puts("  Chat: #{msg.chat.id} (#{msg.chat.type})")
      if msg.text, do: IO.puts("  Text: #{msg.text}")

    update.callback_query ->
      cq = update.callback_query
      IO.puts("  Callback from: #{cq.from.first_name} (#{cq.from.id})")
      IO.puts("  Data: #{cq.data}")

    true ->
      IO.puts("  (other update type)")
  end

  IO.puts("")
end)
|> Stream.run()
