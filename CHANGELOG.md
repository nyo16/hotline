# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-03-19

### Added

- Core Telegram Bot API client (`Hotline.Client`) with JSON and multipart support
- Type system with `use Hotline.Type` macro and automatic nested parsing
- Seed types: `User`, `Chat`, `Message`, `CallbackQuery`, `Update`
- Cascading config resolution (opts > app env > system env > defaults)
- Structured error types with `retry_after` extraction
- Long-polling via `Hotline.Poller` with 409/429 handling
- Webhook support via `Hotline.Webhook` Plug with secret token verification
- `Hotline.Webhook.Router` for standalone Bandit deployment
- Bot behaviour (`use Hotline.Bot`) with PubSub-driven update handling
- `allowed_ids` option to restrict bots to specific Telegram user IDs
- Lazy `Hotline.Stream` for IEx exploration
- Optional `Hotline.BroadwayProducer` for pipeline processing
- Top-level API: `get_me`, `send_message`, `send_photo`, `send_document`, `answer_callback_query`, `edit_message_text`, `delete_message`, `set_webhook`, `delete_webhook`
- Code generator (`mix hotline.gen`) fetching from official Bot API spec
- Telemetry events for requests and received updates
- MIME type detection with optional `MIME` library fallback
- Retry support via Req (`:transient`, max 3 retries)
