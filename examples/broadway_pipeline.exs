# Broadway Pipeline — process Telegram updates through a Broadway pipeline.
#
# Usage:
#   HOTLINE_TOKEN="your-bot-token" mix run examples/broadway_pipeline.exs
#
# Broadway gives you concurrent processors, batching, rate limiting,
# and back-pressure out of the box.

defmodule MyPipeline do
  use Broadway

  def start_link(opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {Hotline.BroadwayProducer, opts}
      ],
      processors: [
        default: [concurrency: 5]
      ]
    )
  end

  @impl true
  def handle_message(_processor, message, _context) do
    update = message.data

    cond do
      update.message && update.message.text ->
        chat_id = update.message.chat.id
        text = update.message.text
        from = update.message.from

        IO.puts("[Broadway] Message from #{from.first_name}: #{text}")

        case text do
          "/start" ->
            Hotline.send_message(%{chat_id: chat_id, text: "Hello from Broadway pipeline!"})

          "/stats" ->
            Hotline.send_message(%{
              chat_id: chat_id,
              text: "Pipeline is running with 5 processors."
            })

          _ ->
            Hotline.send_message(%{chat_id: chat_id, text: "Processed: #{text}"})
        end

      update.callback_query ->
        IO.puts("[Broadway] Callback query: #{update.callback_query.data}")

      true ->
        IO.puts("[Broadway] Other update type: ##{update.update_id}")
    end

    message
  end
end

{:ok, _} = MyPipeline.start_link([])

IO.puts("Broadway pipeline running! Send a message to your bot. Press Ctrl+C to stop.")
Process.sleep(:infinity)
