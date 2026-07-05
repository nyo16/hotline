defmodule Hotline.Bot do
  @moduledoc """
  Behaviour and GenServer for building Telegram bots.

  ## DSL Usage

  The Bot DSL provides declarative macros for defining command handlers,
  update-type handlers, and access control:

      defmodule MyBot do
        use Hotline.Bot

        # Restrict to specific user IDs (optional)
        allow [123_456_789]

        # Command handlers — binds: update, state, chat_id, args
        command "/start" do
          Hotline.send_message(%{chat_id: chat_id, text: "Welcome!"})
        end

        command "/echo" do
          Hotline.send_message(%{chat_id: chat_id, text: args})
        end

        # Update-type handlers — binds: update, state, chat_id, <type>
        on :message do
          Hotline.send_message(%{chat_id: chat_id, text: "Got: \#{message.text}"})
        end

        on :callback_query do
          Hotline.answer_callback_query(%{callback_query_id: callback_query.id})
        end
      end

  Start the bot in your supervision tree:

      children = [
        {MyBot, token: "your-bot-token"}
      ]

  ### Dispatch Priority

  When an update arrives, handlers are checked in this order:

  1. **Commands** — if the message text starts with `/`, declared `command` handlers
     are checked first (in declaration order)
  2. **Type handlers** — `on` handlers matching the update type
  3. **Fallback** — `handle_update/2` if defined manually
  4. **Default** — `{:noreply, state}`

  ### Handler Bindings

  Inside `command` blocks: `update`, `state`, `chat_id`, `args`
  Inside `on` blocks: `update`, `state`, `chat_id`, plus the type-specific
  variable (e.g., `message`, `callback_query`)

  Handlers that return `{:noreply, new_state}` propagate the new state.
  Any other return value defaults to `{:noreply, state}`.

  ### Access Control

  Use `allow` at the module level to declare permitted user IDs:

      allow [111, 222]                    # literal IDs
      allow {:config, :my_allowed_ids}    # resolve from Application env at init

  These merge with the runtime `allowed_ids` option.

  **Empty vs. omitted (important):**

    * Omit `allow` **and** `allowed_ids` entirely → allow-all (every user accepted).
    * A merged allow-list that resolves to `[]` → **deny-all** (every update rejected).

  These are deliberately different: an explicit empty list fails closed. The
  common footgun is an *accidental* empty list — e.g. `allowed_ids:
  MyApp.admin_ids()` where the query returns `[]` — which silently locks everyone
  out. The bot logs a `Logger.warning` at init whenever the merged allow-list is
  empty so this is visible in the logs.

  > #### `channel_post` note {: .info}
  >
  > For `channel_post` updates there is no `from` user, so `extract_sender_id/1`
  > falls back to the *chat* id. That chat id is then checked against the *user*
  > allow-list. If you allow channel posts, add the relevant chat ids to the
  > allow-list. Updates with no extractable sender fail closed (rejected).

  ## Manual Usage

  You can still use the raw callback approach for full control:

      defmodule MyBot do
        use Hotline.Bot

        @impl Hotline.Bot
        def handle_update(update, state) do
          # full manual control
          {:noreply, state}
        end
      end

  ## Options

    * `:token` — bot token (can also be set via config or env var)
    * `:allowed_ids` — list of user IDs permitted to interact (merged with `allow`).
      An empty merged list means deny-all; omit entirely for allow-all.
    * `:chat_id` — initial chat ID (auto-detected from first message if omitted)
    * `:name` — process name (defaults to module name)

  ## Callbacks

    * `handle_update/2` — called for updates not matched by DSL handlers (optional with DSL)
    * `init_bot/1` — called during init for custom state setup (optional)
  """

  @callback handle_update(Hotline.Types.Update.t(), map()) :: {:noreply, map()}
  @callback init_bot(map()) :: {:ok, map()}

  @optional_callbacks handle_update: 2, init_bot: 1

  require Logger

  @valid_update_types [
    :message,
    :callback_query,
    :edited_message,
    :channel_post,
    :edited_channel_post,
    :inline_query,
    :chosen_inline_result,
    :shipping_query,
    :pre_checkout_query,
    :poll,
    :poll_answer,
    :my_chat_member,
    :chat_member,
    :chat_join_request
  ]

  defmacro __using__(opts) do
    quote do
      use GenServer

      @behaviour Hotline.Bot

      Module.register_attribute(__MODULE__, :hotline_commands, accumulate: true)
      Module.register_attribute(__MODULE__, :hotline_handlers, accumulate: true)
      Module.register_attribute(__MODULE__, :hotline_allowed_ids, accumulate: true)

      @before_compile Hotline.Bot

      import Hotline.Bot, only: [command: 2, on: 2, allow: 1]

      def start_link(init_opts \\ []) do
        name = unquote(opts[:name]) || Keyword.get(init_opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, init_opts, name: name)
      end

      @impl GenServer
      def init(init_opts) do
        Phoenix.PubSub.subscribe(Hotline.PubSub, "hotline:updates")

        declared = __MODULE__.__declared_allowed_ids__()
        resolved_declared = Hotline.Bot.resolve_allowed_ids(declared)

        merged_ids =
          Hotline.Bot.merge_allowed_ids(declared, resolved_declared, init_opts[:allowed_ids])

        Hotline.Bot.warn_if_deny_all(merged_ids, __MODULE__)

        # Store opts WITHOUT the token: the framework never reads it (bots send via
        # Config-resolved tokens), and keeping it here would leak it into SASL crash
        # reports and inspect/1 output.
        state = %{
          chat_id: init_opts[:chat_id],
          allowed_ids: merged_ids,
          opts: Hotline.Bot.sanitize_opts(init_opts)
        }

        state =
          if function_exported?(__MODULE__, :init_bot, 1) do
            case apply(__MODULE__, :init_bot, [state]) do
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
          # Give operators a signal for *why* a bot ignored a user, mirroring the
          # poller's [:hotline, :update, :received] event.
          :telemetry.execute(
            [:hotline, :update, :rejected],
            %{},
            %{bot: __MODULE__, sender_id: sender_id, update_id: Map.get(update, :update_id)}
          )

          {:noreply, state}
        end
      end

      def handle_info(_msg, state), do: {:noreply, state}

      # Defense-in-depth token redaction for SASL crash reports / :sys.get_status.
      # The token is already stripped from stored opts at init; this also covers
      # anything a custom init_bot/1 may have added back.
      @impl GenServer
      def format_status(status) do
        case status do
          %{state: %{opts: opts} = state} ->
            %{status | state: %{state | opts: Hotline.Bot.redact_opts(opts)}}

          _ ->
            status
        end
      end

      defoverridable start_link: 1, init: 1, format_status: 1
    end
  end

  @doc """
  Declare a command handler.

  The block receives bindings for `update`, `state`, `chat_id`, and `args`
  (the text after the command). Commands strip `@botname` suffixes for group chat support.

  ## Example

      command "/start" do
        Hotline.send_message(%{chat_id: chat_id, text: "Hello!"})
      end

      command "/echo" do
        Hotline.send_message(%{chat_id: chat_id, text: args})
      end
  """
  defmacro command(cmd_string, do: body) do
    func_name = cmd_to_func_name(cmd_string)

    quote do
      @hotline_commands {unquote(cmd_string), unquote(func_name)}

      @doc false
      def unquote(func_name)(var!(update), var!(state), var!(chat_id), var!(args)) do
        _ = var!(update)
        _ = var!(state)
        _ = var!(chat_id)
        _ = var!(args)
        result = unquote(body)

        case result do
          {:noreply, new_state} -> {:noreply, new_state}
          _ -> {:noreply, var!(state)}
        end
      end
    end
  end

  @doc """
  Declare a handler for a specific update type.

  The block receives bindings for `update`, `state`, `chat_id`, and the
  type-specific variable (e.g., `message`, `callback_query`).

  ## Valid types

  `:message`, `:callback_query`, `:edited_message`, `:channel_post`,
  `:edited_channel_post`, `:inline_query`, `:chosen_inline_result`,
  `:shipping_query`, `:pre_checkout_query`, `:poll`, `:poll_answer`,
  `:my_chat_member`, `:chat_member`, `:chat_join_request`

  ## Example

      on :message do
        Hotline.send_message(%{chat_id: chat_id, text: "Echo: \#{message.text}"})
      end

      on :callback_query do
        Hotline.answer_callback_query(%{callback_query_id: callback_query.id})
      end
  """
  defmacro on(update_type, do: body) do
    unless update_type in @valid_update_types do
      raise ArgumentError,
            "invalid update type #{inspect(update_type)}. " <>
              "Must be one of: #{inspect(@valid_update_types)}"
    end

    func_name = :"__on_#{update_type}__"
    type_var = Macro.var(update_type, nil)

    quote do
      @hotline_handlers {unquote(update_type), unquote(func_name)}

      @doc false
      def unquote(func_name)(var!(update), var!(state), var!(chat_id)) do
        _ = var!(update)
        _ = var!(state)
        _ = var!(chat_id)
        unquote(type_var) = Map.get(var!(update), unquote(update_type))
        _ = unquote(type_var)
        result = unquote(body)

        case result do
          {:noreply, new_state} -> {:noreply, new_state}
          _ -> {:noreply, var!(state)}
        end
      end
    end
  end

  @doc """
  Declare allowed user IDs for access control.

  Accepts a literal list of IDs or `{:config, key}` to resolve from
  `Application.get_env(:hotline, key)` at init time.

  Multiple `allow` declarations are merged together, and also merge
  with the runtime `allowed_ids` option.

  ## Example

      allow [123_456_789, 987_654_321]
      allow {:config, :admin_ids}
  """
  defmacro allow(ids) do
    validate_allowed_ids!(ids)

    quote do
      @hotline_allowed_ids unquote(ids)
    end
  end

  # Compile-time guard (mirrors how on/2 validates update types): a bare
  # `allow 123` would otherwise raise a cryptic FunctionClauseError from
  # resolve_allowed_ids/1 at init. Non-literal expressions (vars, calls, config
  # tuples) are resolved later, so only obviously-wrong scalar literals raise.
  defp validate_allowed_ids!(ids) when is_list(ids), do: :ok
  defp validate_allowed_ids!({:config, _key}), do: :ok

  defp validate_allowed_ids!(scalar)
       when is_integer(scalar) or is_float(scalar) or is_binary(scalar) or is_atom(scalar) do
    raise ArgumentError,
          "allow/1 expects a list of user IDs or {:config, key}, got: #{inspect(scalar)}. " <>
            "Did you mean `allow [#{inspect(scalar)}]`?"
  end

  defp validate_allowed_ids!(_other), do: :ok

  defmacro __before_compile__(env) do
    commands = Module.get_attribute(env.module, :hotline_commands) |> Enum.reverse()
    handlers = Module.get_attribute(env.module, :hotline_handlers) |> Enum.reverse()
    allowed_ids = Module.get_attribute(env.module, :hotline_allowed_ids) |> Enum.reverse()

    has_custom = Module.defines?(env.module, {:handle_update, 2})
    has_dsl = commands != [] or handlers != []

    handle_update_def = build_handle_update(has_custom, has_dsl)

    quote do
      @doc false
      def __commands__, do: unquote(Macro.escape(commands))

      @doc false
      def __handlers__, do: unquote(Macro.escape(handlers))

      @doc false
      def __declared_allowed_ids__, do: unquote(Macro.escape(allowed_ids))

      unquote(build_command_dispatch(commands))
      unquote(build_type_dispatch(handlers))
      unquote(handle_update_def)
    end
  end

  # -- Compile-time helpers (private functions, not macros) --

  defp build_handle_update(true = _has_custom, true = _has_dsl) do
    # DSL dispatch first, fall back to user's manual handle_update via super
    quote do
      defoverridable handle_update: 2

      @impl Hotline.Bot
      def handle_update(update, state) do
        case __dispatch_command__(update, state) do
          {:__not_handled__, fallback_state} -> super(update, fallback_state)
          result -> result
        end
      end
    end
  end

  defp build_handle_update(true = _has_custom, false = _has_dsl), do: nil

  defp build_handle_update(false = _has_custom, false = _has_dsl) do
    quote do
      @impl Hotline.Bot
      def handle_update(_update, state), do: {:noreply, state}
      defoverridable handle_update: 2
    end
  end

  defp build_handle_update(false = _has_custom, true = _has_dsl) do
    quote do
      @impl Hotline.Bot
      def handle_update(update, state) do
        case __dispatch_command__(update, state) do
          {:__not_handled__, fallback_state} -> {:noreply, fallback_state}
          result -> result
        end
      end

      defoverridable handle_update: 2
    end
  end

  defp cmd_to_func_name(cmd_string) do
    name =
      cmd_string
      |> String.trim_leading("/")
      |> String.replace(~r/[^a-zA-Z0-9_]/, "_")

    :"__command_#{name}__"
  end

  defp build_command_dispatch(commands) do
    if commands == [] do
      quote do
        @doc false
        def __dispatch_command__(update, state) do
          __dispatch_type__(update, state)
        end
      end
    else
      clauses =
        Enum.map(commands, fn {cmd_string, func_name} ->
          {:->, [],
           [
             [cmd_string],
             quote do
               chat_id = Hotline.Bot.extract_chat_id(update)
               unquote(func_name)(update, state, chat_id, args)
             end
           ]}
        end)

      fallback =
        {:->, [],
         [
           [{:_, [], Elixir}],
           quote do
             __dispatch_type__(update, state)
           end
         ]}

      all_clauses = clauses ++ [fallback]

      quote do
        @doc false
        def __dispatch_command__(%{message: %{text: "/" <> _ = text}} = update, state)
            when is_binary(text) do
          {cmd, args} = Hotline.Bot.parse_command(text)

          case cmd do
            unquote(all_clauses)
          end
        end

        def __dispatch_command__(update, state) do
          __dispatch_type__(update, state)
        end
      end
    end
  end

  defp build_type_dispatch(handlers) do
    clauses =
      Enum.map(handlers, fn {update_type, func_name} ->
        pattern =
          quote do
            %{unquote(update_type) => val} when not is_nil(val)
          end

        body =
          quote do
            chat_id = Hotline.Bot.extract_chat_id(update)
            unquote(func_name)(update, state, chat_id)
          end

        {:->, [], [[pattern], body]}
      end)

    fallback =
      {:->, [],
       [
         [{:_, [], Elixir}],
         quote do
           {:__not_handled__, state}
         end
       ]}

    all_clauses = clauses ++ [fallback]

    quote do
      @doc false
      def __dispatch_type__(update, state) do
        case update do
          unquote(all_clauses)
        end
      end
    end
  end

  # -- Public runtime helpers --

  @doc false
  def allowed?(_sender_id, nil), do: true
  def allowed?(nil, _allowed_ids), do: false
  def allowed?(sender_id, allowed_ids), do: sender_id in allowed_ids

  # Resolve the "sender" id used for access control. `channel_post` updates have
  # no `from` user, so we fall back to the *chat* id — meaning a channel's chat id
  # is checked against the *user* allow-list (allow channel posts by adding the
  # chat id to the allow-list). Anything with no extractable sender returns nil,
  # which `allowed?/2` rejects (fail closed).
  @doc false
  def extract_sender_id(%{message: %{from: %{id: id}}}), do: id
  def extract_sender_id(%{callback_query: %{from: %{id: id}}}), do: id
  def extract_sender_id(%{edited_message: %{from: %{id: id}}}), do: id
  def extract_sender_id(%{channel_post: %{chat: %{id: id}}}), do: id
  def extract_sender_id(_), do: nil

  @doc false
  def extract_chat_id(%{message: %{chat: %{id: id}}}), do: id
  def extract_chat_id(%{callback_query: %{message: %{chat: %{id: id}}}}), do: id
  def extract_chat_id(%{edited_message: %{chat: %{id: id}}}), do: id
  def extract_chat_id(%{channel_post: %{chat: %{id: id}}}), do: id
  def extract_chat_id(_), do: nil

  @doc false
  def parse_command(text) do
    {cmd_part, args} =
      case String.split(text, " ", parts: 2) do
        [cmd] -> {cmd, ""}
        [cmd, rest] -> {cmd, rest}
      end

    cmd = strip_bot_mention(cmd_part)
    {cmd, args}
  end

  defp strip_bot_mention(cmd) do
    case String.split(cmd, "@", parts: 2) do
      [cmd_only, _bot_name] -> cmd_only
      [cmd_only] -> cmd_only
    end
  end

  @doc false
  def resolve_allowed_ids(declared_list) do
    Enum.flat_map(declared_list, fn
      {:config, key} ->
        Application.get_env(:hotline, key, []) |> List.wrap()

      ids when is_list(ids) ->
        ids
    end)
  end

  # Merge compile-time `allow` declarations with the runtime `:allowed_ids`.
  #
  # Allow-all (`nil`) is decided from the *presence* of a declaration or runtime
  # opt, NOT the post-resolve list. `declared` is the raw list of `allow` args, so
  # `allow {:config, key}` with the config unset — which *resolves* to `[]` — is
  # still a declaration and must fail closed (deny-all), never silently reopen the
  # bot to everyone. That distinction is impossible to make from the resolved list
  # alone (both an unset config and a bare `allow []` resolve to `[]`).
  #
  # Returns `nil` (allow-all) only when nothing was declared AND no runtime opt was
  # given. Otherwise returns the resolved ids merged with the runtime list — which
  # may itself be `[]` (deny-all), kept distinct from `nil` on purpose.
  @doc false
  def merge_allowed_ids([] = _declared, _resolved, nil), do: nil

  def merge_allowed_ids(_declared, resolved, runtime),
    do: Enum.uniq(resolved ++ List.wrap(runtime))

  # Drop the token from opts before they are stored in GenServer state.
  @doc false
  def sanitize_opts(opts) when is_list(opts), do: Keyword.delete(opts, :token)
  def sanitize_opts(opts), do: opts

  # Redact the token in opts for status/inspect output (keeps the key, hides the value).
  @doc false
  def redact_opts(opts) when is_list(opts) do
    if Keyword.has_key?(opts, :token), do: Keyword.put(opts, :token, "[REDACTED]"), else: opts
  end

  def redact_opts(opts), do: opts

  @doc false
  def warn_if_deny_all([], module) do
    Logger.warning(
      "#{inspect(module)}: allow-list resolved to [] — the bot will reject ALL updates " <>
        "(deny-all). Omit `allow`/`:allowed_ids` entirely to accept all users, or check " <>
        "whether a runtime source (config/DB query) returned an empty list."
    )
  end

  def warn_if_deny_all(_merged, _module), do: :ok
end
