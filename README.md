# Hotline

Telegram Bot API client and framework for Elixir.

## Features

- **Type-safe** — Parsed Telegram types with nested struct resolution
- **Long-polling** — Built-in `Hotline.Poller` GenServer with offset tracking, 409/429 handling
- **Webhooks** — `Hotline.Webhook` Plug with secret token verification
- **Bot behaviour** — `use Hotline.Bot` for quick PubSub-driven bots
- **Access control** — Restrict bots to specific user IDs with `allowed_ids`
- **Streaming** — Lazy `Stream.resource` for IEx exploration
- **Broadway** — Optional `Hotline.BroadwayProducer` for pipeline processing
- **Code generator** — `mix hotline.gen` fetches the official API spec and generates all types and methods
- **Telemetry** — `[:hotline, :request, :start | :stop]` and `[:hotline, :update, :received]` events
- **No Jason dependency** — Uses Elixir 1.18+ native `JSON` module

## Installation

Add `hotline` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:hotline, "~> 0.1.0"}
  ]
end
```

## Configuration

Configure via application environment, system environment variables, or runtime options:

```elixir
# config/config.exs
config :hotline,
  token: "your-bot-token"
```

Or use environment variables:

```sh
export HOTLINE_TOKEN="your-bot-token"
```

Or pass options directly to any function:

```elixir
Hotline.get_me(token: "your-bot-token")
```

Resolution order: **opts > app env > system env > defaults**.

## Usage

### Quick start in IEx

```sh
HOTLINE_TOKEN="your-bot-token" iex -S mix
```

```elixir
# Get bot info
{:ok, me} = Hotline.get_me()

# Send a message (find your chat_id first)
[update] = Hotline.stream() |> Enum.take(1)
chat_id = update.message.chat.id

{:ok, msg} = Hotline.send_message(%{chat_id: chat_id, text: "Hello from Hotline!"})

# Stream updates
Hotline.stream() |> Enum.each(&IO.inspect/1)
```

### Bot behaviour

```elixir
defmodule MyBot do
  use Hotline.Bot

  @impl Hotline.Bot
  def handle_update(%{message: %{text: "/start"}} = _update, state) do
    Hotline.send_message(%{chat_id: state.chat_id, text: "Hello!"})
    {:noreply, state}
  end

  def handle_update(_update, state) do
    {:noreply, state}
  end
end
```

Add the poller and bot to your supervision tree:

```elixir
children = [
  {Hotline.Poller, token: "your-token"},
  {MyBot, []}
]
```

### Restricting access by user ID

Only accept updates from specific Telegram user IDs:

```elixir
# Single user
{MyBot, allowed_ids: [7644580464]}

# Multiple users
{MyBot, allowed_ids: [7644580464, 123456789]}
```

Updates from other users are silently dropped. Omit `allowed_ids` to accept everyone.

### Webhooks

Use `Hotline.Webhook` as a Plug, or deploy standalone with Bandit:

```elixir
# In your supervision tree
{Bandit, plug: Hotline.Webhook.Router, port: 4000}
```

Configure a secret token for verification:

```elixir
config :hotline,
  webhook_secret: "your-secret-token"
```

### Sending files

```elixir
# From file path
Hotline.send_photo(%{chat_id: chat_id, photo: {:file, "/path/to/photo.jpg"}})

# From binary content
Hotline.send_document(%{chat_id: chat_id, document: {:file_content, binary_data, "report.pdf"}})
```

### Code generator

Generate all Telegram API types and methods from the official spec:

```sh
mix hotline.gen
mix format
```

This creates type modules in `lib/hotline/types/` and a `Hotline.GeneratedAPI` module with all API methods.

## Examples

See the [`examples/`](examples/) directory for runnable examples:

- [`echo_bot.exs`](examples/echo_bot.exs) — Simple echo bot
- [`greeter_bot.exs`](examples/greeter_bot.exs) — Greeter with command handling
- [`stream_logger.exs`](examples/stream_logger.exs) — Log updates via streaming

Run any example with:

```sh
HOTLINE_TOKEN="your-bot-token" mix run examples/echo_bot.exs
```

## License

MIT
