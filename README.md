# Hotline

> Telegram Bot API client and framework for Elixir.

Hotline gives you everything you need to build Telegram bots in Elixir — from quick IEx exploration to production-ready supervised bots with long-polling, webhooks, and Broadway pipelines.

---

## Features

| | |
|---|---|
| **Type-safe** | Parsed Telegram types with nested struct resolution |
| **Long-polling** | Built-in `Hotline.Poller` with offset tracking, 409/429 handling |
| **Webhooks** | `Hotline.Webhook` Plug with secret token verification |
| **Bot behaviour** | `use Hotline.Bot` for quick PubSub-driven bots |
| **Access control** | Restrict bots to specific user IDs via `allowed_ids` |
| **Streaming** | Lazy `Stream.resource` for IEx exploration |
| **Broadway** | Optional `Hotline.BroadwayProducer` for pipeline processing |
| **Code generator** | `mix hotline.gen` generates types and methods from the official API spec |
| **Telemetry** | Request and update events out of the box |
| **Native JSON** | Uses Elixir 1.18+ built-in `JSON` module — no Jason dependency |

## Installation

Add `hotline` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:hotline, "~> 0.1.0"}
  ]
end
```

Requires **Elixir ~> 1.18**.

## Configuration

Three ways to configure, in priority order:

```elixir
# 1. Runtime options (highest priority)
Hotline.get_me(token: "your-bot-token")

# 2. Application environment
# config/config.exs
config :hotline,
  token: "your-bot-token"

# 3. System environment variables
# export HOTLINE_TOKEN="your-bot-token"
```

## Quick Start

```sh
HOTLINE_TOKEN="your-bot-token" iex -S mix
```

```elixir
# Verify your bot
iex> {:ok, me} = Hotline.get_me()
{:ok, %Hotline.Types.User{first_name: "MyBot", ...}}

# Find your chat_id — send a message to your bot in Telegram, then:
iex> [update] = Hotline.stream() |> Enum.take(1)
iex> chat_id = update.message.chat.id
7644580464

# Send a message
iex> Hotline.send_message(%{chat_id: chat_id, text: "Hello from Hotline!"})
{:ok, %Hotline.Types.Message{...}}
```

## Building a Bot

Define a bot module with `use Hotline.Bot` and implement `handle_update/2`:

```elixir
defmodule MyBot do
  use Hotline.Bot

  @impl Hotline.Bot
  def handle_update(%{message: %{text: "/start", chat: %{id: chat_id}}}, state) do
    Hotline.send_message(%{chat_id: chat_id, text: "Welcome! Try /help"})
    {:noreply, state}
  end

  def handle_update(%{message: %{text: "/ping", chat: %{id: chat_id}}}, state) do
    Hotline.send_message(%{chat_id: chat_id, text: "Pong!"})
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
  {Hotline.Poller, []},
  {MyBot, []}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

### Restricting Access

Only accept updates from specific Telegram user IDs:

```elixir
# Single user
{MyBot, allowed_ids: [7644580464]}

# Multiple users
{MyBot, allowed_ids: [7644580464, 123456789]}

# Everyone (default)
{MyBot, []}
```

Updates from non-allowed users are silently dropped.

## Webhooks

Use `Hotline.Webhook` as a Plug, or deploy standalone with Bandit:

```elixir
children = [
  {Bandit, plug: Hotline.Webhook.Router, port: 4000},
  {MyBot, []}
]
```

With secret token verification:

```elixir
config :hotline,
  webhook_secret: "your-secret-token"
```

## Sending Files

```elixir
# From a file path
Hotline.send_photo(%{chat_id: chat_id, photo: {:file, "/path/to/photo.jpg"}})

# From binary content
Hotline.send_document(%{chat_id: chat_id, document: {:file_content, pdf_binary, "report.pdf"}})
```

## Code Generator

Generate all Telegram API types and methods from the [official spec](https://github.com/PaulSonOfLars/telegram-bot-api-spec):

```sh
mix hotline.gen
mix format
```

This creates full type modules in `lib/hotline/types/` and a `Hotline.GeneratedAPI` module with every API method, complete with typespecs and docs.

## Examples

See the [`examples/`](examples/) directory:

| Example | Description |
|---------|-------------|
| [`echo_bot.exs`](examples/echo_bot.exs) | Echoes back whatever the user sends |
| [`greeter_bot.exs`](examples/greeter_bot.exs) | Handles `/start`, `/help`, `/ping`, `/whoami` commands |
| [`stream_logger.exs`](examples/stream_logger.exs) | Logs incoming updates to the console via streaming |

Run any example:

```sh
HOTLINE_TOKEN="your-bot-token" mix run examples/echo_bot.exs
```

## License

[MIT](LICENSE)
