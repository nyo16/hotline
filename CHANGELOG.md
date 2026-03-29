# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- **Bot DSL** — declarative `command` and `on` macros for routing updates without manual pattern matching
- `allow` macro for compile-time access control (literal IDs or `{:config, key}`)
- `extract_chat_id/1` and `parse_command/1` public helpers on `Hotline.Bot`
- DSL bot example (`examples/dsl_bot.exs`)
- Comprehensive Bot DSL test suite (`test/hotline/bot_test.exs`)

### Changed

- `handle_update/2` is now an optional callback — DSL bots don't need it
- `init_bot/1` call uses `apply/3` to avoid compile-time resolution errors
- Compile-time `allow` IDs merge with runtime `allowed_ids` option
- Hybrid bots (DSL + manual `handle_update/2`) dispatch DSL first, then fall back via `super`

### Fixed

- `Hotline.Type` — extracted `apply_nested/3` to eliminate `Map.get` type warnings on modules without nested types (User, Chat)
- `Hotline.Flow` — skip generating default `on_done/1`/`on_cancel/1` when user already defines them, eliminating redundant clause warnings

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
