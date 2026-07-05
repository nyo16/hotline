defmodule Hotline.BotTest do
  use ExUnit.Case, async: true

  # -- Test bot modules --

  defmodule CommandBot do
    use Hotline.Bot

    command "/start" do
      send(self(), {:command, :start, chat_id})
    end

    command "/echo" do
      send(self(), {:command, :echo, chat_id, args})
    end
  end

  defmodule TypeHandlerBot do
    use Hotline.Bot

    on :message do
      send(self(), {:on_message, chat_id, message})
    end

    on :callback_query do
      send(self(), {:on_callback_query, chat_id, callback_query})
    end
  end

  defmodule MixedBot do
    use Hotline.Bot

    command "/start" do
      send(self(), {:command, :start, chat_id})
    end

    on :message do
      send(self(), {:on_message, chat_id, message})
    end

    on :callback_query do
      send(self(), {:on_callback_query, chat_id, callback_query})
    end
  end

  defmodule RestrictedBot do
    use Hotline.Bot

    allow([111, 222])

    command "/start" do
      send(self(), {:command, :start, chat_id})
    end
  end

  defmodule MultiAllowBot do
    use Hotline.Bot

    allow([111])
    allow([222, 333])

    command "/start" do
      send(self(), :ok)
    end
  end

  defmodule UnsetConfigBot do
    use Hotline.Bot

    # Declares an allow-list sourced from config that the app never sets, so it
    # resolves to []. This must fail CLOSED (deny-all), NOT silently allow everyone
    # — the F1 auth-fails-open regression.
    allow({:config, :__hotline_never_set_allowed_ids__})

    command "/start" do
      send(self(), {:command, :start, chat_id})
    end
  end

  defmodule StatefulBot do
    use Hotline.Bot

    @impl Hotline.Bot
    def handle_update(%{message: %{text: "/inc"}} = _update, state) do
      {:noreply, Map.update(state, :count, 1, &(&1 + 1))}
    end

    def handle_update(%{message: %{text: "/get"}} = _update, state) do
      send(self(), {:count, Map.get(state, :count, 0)})
      {:noreply, state}
    end

    def handle_update(_update, state), do: {:noreply, state}
  end

  defmodule LegacyBot do
    use Hotline.Bot

    @impl Hotline.Bot
    def handle_update(update, state) do
      send(self(), {:legacy, update})
      {:noreply, state}
    end
  end

  defmodule HybridBot do
    use Hotline.Bot

    command "/start" do
      send(self(), {:command, :start, chat_id})
    end

    on :callback_query do
      send(self(), {:on_callback_query, chat_id, callback_query})
    end

    @impl Hotline.Bot
    def handle_update(update, state) do
      send(self(), {:fallback, update})
      {:noreply, state}
    end
  end

  defmodule EmptyBot do
    use Hotline.Bot
  end

  # -- Helpers --

  defp msg_update(text, chat_id, user_id \\ nil) do
    %{
      update_id: System.unique_integer([:positive]),
      message: %{text: text, chat: %{id: chat_id}, from: %{id: user_id || chat_id}},
      callback_query: nil,
      edited_message: nil,
      channel_post: nil
    }
  end

  defp cb_update(data, chat_id, user_id \\ nil) do
    %{
      update_id: System.unique_integer([:positive]),
      message: nil,
      callback_query: %{
        id: "cb_#{System.unique_integer([:positive])}",
        data: data,
        message: %{chat: %{id: chat_id}},
        from: %{id: user_id || chat_id}
      },
      edited_message: nil,
      channel_post: nil
    }
  end

  # -- Compile-time introspection tests --

  describe "compile-time introspection" do
    test "__commands__/0 returns declared commands in order" do
      assert [{"/start", _}, {"/echo", _}] = CommandBot.__commands__()
    end

    test "__handlers__/0 returns declared handlers in order" do
      assert [{:message, _}, {:callback_query, _}] = TypeHandlerBot.__handlers__()
    end

    test "__declared_allowed_ids__/0 returns declared IDs" do
      assert [[111, 222]] = RestrictedBot.__declared_allowed_ids__()
    end

    test "__declared_allowed_ids__/0 returns multiple allow declarations" do
      assert [[111], [222, 333]] = MultiAllowBot.__declared_allowed_ids__()
    end

    test "__declared_allowed_ids__/0 returns empty list when none declared" do
      assert [] = CommandBot.__declared_allowed_ids__()
    end

    test "empty bot has no commands or handlers" do
      assert [] = EmptyBot.__commands__()
      assert [] = EmptyBot.__handlers__()
    end
  end

  # -- Command dispatch tests --

  describe "command dispatch" do
    test "routes /start command" do
      update = msg_update("/start", 42)
      assert {:noreply, _} = CommandBot.handle_update(update, %{})
      assert_received {:command, :start, 42}
    end

    test "routes /echo command with args" do
      update = msg_update("/echo hello world", 42)
      assert {:noreply, _} = CommandBot.handle_update(update, %{})
      assert_received {:command, :echo, 42, "hello world"}
    end

    test "routes /echo command with empty args" do
      update = msg_update("/echo", 42)
      assert {:noreply, _} = CommandBot.handle_update(update, %{})
      assert_received {:command, :echo, 42, ""}
    end

    test "unknown command falls through to type handler" do
      update = msg_update("/unknown", 42)
      assert {:noreply, _} = MixedBot.handle_update(update, %{})
      assert_received {:on_message, 42, _}
    end

    test "command with @botname suffix is matched" do
      update = msg_update("/start@mybot", 42)
      assert {:noreply, _} = CommandBot.handle_update(update, %{})
      assert_received {:command, :start, 42}
    end
  end

  # -- Type handler dispatch tests --

  describe "type handler dispatch" do
    test "routes message to on :message handler" do
      update = msg_update("hello", 42)
      assert {:noreply, _} = TypeHandlerBot.handle_update(update, %{})
      assert_received {:on_message, 42, %{text: "hello"}}
    end

    test "routes callback_query to on :callback_query handler" do
      update = cb_update("btn_1", 42)
      assert {:noreply, _} = TypeHandlerBot.handle_update(update, %{})
      assert_received {:on_callback_query, 42, %{data: "btn_1"}}
    end

    test "unhandled update type returns {:noreply, state}" do
      update = %{
        update_id: 1,
        message: nil,
        callback_query: nil,
        edited_message: %{chat: %{id: 42}, from: %{id: 42}, text: "edited"},
        channel_post: nil
      }

      state = %{foo: :bar}
      assert {:noreply, ^state} = TypeHandlerBot.handle_update(update, state)
    end
  end

  # -- Priority tests --

  describe "dispatch priority" do
    test "commands take priority over on :message" do
      update = msg_update("/start", 42)
      assert {:noreply, _} = MixedBot.handle_update(update, %{})
      assert_received {:command, :start, 42}
      refute_received {:on_message, _, _}
    end

    test "non-command messages route to on :message" do
      update = msg_update("just a message", 42)
      assert {:noreply, _} = MixedBot.handle_update(update, %{})
      assert_received {:on_message, 42, _}
      refute_received {:command, _, _}
    end
  end

  # -- State mutation tests --

  describe "state mutation" do
    test "handler returning {:noreply, new_state} propagates" do
      update = msg_update("/inc", 42)
      assert {:noreply, %{count: 1}} = StatefulBot.handle_update(update, %{})
    end

    test "state accumulates across calls" do
      update = msg_update("/inc", 42)
      {:noreply, state} = StatefulBot.handle_update(update, %{})
      {:noreply, state} = StatefulBot.handle_update(update, state)
      assert %{count: 2} = state
    end
  end

  # -- Backward compatibility tests --

  describe "backward compatibility" do
    test "legacy bot with manual handle_update works" do
      update = msg_update("test", 42)
      assert {:noreply, _} = LegacyBot.handle_update(update, %{})
      assert_received {:legacy, ^update}
    end

    test "empty bot ignores all updates" do
      update = msg_update("test", 42)
      state = %{foo: :bar}
      assert {:noreply, ^state} = EmptyBot.handle_update(update, state)
    end
  end

  # -- Hybrid DSL + manual handle_update tests --

  describe "hybrid bot (DSL + manual handle_update)" do
    test "DSL commands take priority" do
      update = msg_update("/start", 42)
      assert {:noreply, _} = HybridBot.handle_update(update, %{})
      assert_received {:command, :start, 42}
      refute_received {:fallback, _}
    end

    test "DSL type handlers take priority" do
      update = cb_update("btn_1", 42)
      assert {:noreply, _} = HybridBot.handle_update(update, %{})
      assert_received {:on_callback_query, 42, _}
      refute_received {:fallback, _}
    end

    test "unmatched updates fall back to manual handle_update" do
      update = msg_update("just a message", 42)
      assert {:noreply, _} = HybridBot.handle_update(update, %{})
      assert_received {:fallback, ^update}
      refute_received {:command, _, _}
    end

    test "unknown commands fall back to manual handle_update" do
      update = msg_update("/unknown", 42)
      assert {:noreply, _} = HybridBot.handle_update(update, %{})
      assert_received {:fallback, ^update}
    end
  end

  # -- Access control tests --

  describe "access control" do
    test "resolve_allowed_ids handles literal lists" do
      assert [111, 222] = Hotline.Bot.resolve_allowed_ids([[111, 222]])
    end

    test "resolve_allowed_ids handles multiple declarations" do
      assert [111, 222, 333] = Hotline.Bot.resolve_allowed_ids([[111], [222, 333]])
    end

    test "resolve_allowed_ids handles {:config, key}" do
      # Unique key + on_exit: this file is async, so mutating global Application
      # env must not collide with a concurrent test or leak if an assertion fails.
      key = :"test_allowed_ids_#{System.unique_integer([:positive])}"
      Application.put_env(:hotline, key, [444, 555])
      on_exit(fn -> Application.delete_env(:hotline, key) end)

      assert [444, 555] = Hotline.Bot.resolve_allowed_ids([{:config, key}])
    end

    # merge_allowed_ids/3 takes (raw declared args, resolved ids, runtime opt).
    # Allow-all (nil) is decided from the PRESENCE of a declaration/runtime, not the
    # post-resolve list — so a declaration that resolves to [] still fails closed.
    test "merge_allowed_ids returns nil (allow-all) when nothing declared and no runtime" do
      assert nil == Hotline.Bot.merge_allowed_ids([], [], nil)
    end

    test "merge_allowed_ids uses resolved ids when no runtime" do
      assert [111] = Hotline.Bot.merge_allowed_ids([[111]], [111], nil)
    end

    test "merge_allowed_ids uses runtime when nothing declared" do
      assert [222] = Hotline.Bot.merge_allowed_ids([], [], [222])
    end

    test "merge_allowed_ids merges resolved and runtime" do
      result = Hotline.Bot.merge_allowed_ids([[111]], [111], [222])
      assert 111 in result
      assert 222 in result
    end

    test "merge_allowed_ids deduplicates" do
      result = Hotline.Bot.merge_allowed_ids([[111, 222]], [111, 222], [222, 333])
      assert length(result) == 3
    end

    test "merge_allowed_ids fails closed when a declaration resolves to [] (deny-all, not allow-all)" do
      # THE F1 BUG: `allow {:config, key}` with the key unset resolves to [] but is
      # still a declaration — it must deny-all ([]), never collapse to nil (allow-all).
      assert [] == Hotline.Bot.merge_allowed_ids([{:config, :unset}], [], nil)
      # A bare `allow []` is likewise a declaration → deny-all.
      assert [] == Hotline.Bot.merge_allowed_ids([[]], [], nil)
    end

    test "merge_allowed_ids keeps an explicit empty runtime list as deny-all (distinct from nil)" do
      # nil (both omitted) = allow-all; [] (explicit runtime) = deny-all. Must not collapse.
      assert nil == Hotline.Bot.merge_allowed_ids([], [], nil)
      assert [] == Hotline.Bot.merge_allowed_ids([], [], [])
    end

    test "allowed?/2 treats nil as allow-all and [] as deny-all" do
      assert Hotline.Bot.allowed?(111, nil)
      refute Hotline.Bot.allowed?(111, [])
      assert Hotline.Bot.allowed?(111, [111])
      refute Hotline.Bot.allowed?(999, [111])
      refute Hotline.Bot.allowed?(nil, [111])
    end

    test "warn_if_deny_all logs only for an empty merged allow-list" do
      import ExUnit.CaptureLog

      assert capture_log(fn -> Hotline.Bot.warn_if_deny_all([], CommandBot) end) =~ "deny-all"
      refute capture_log(fn -> Hotline.Bot.warn_if_deny_all([111], CommandBot) end) =~ "deny-all"
      refute capture_log(fn -> Hotline.Bot.warn_if_deny_all(nil, CommandBot) end) =~ "deny-all"
    end
  end

  # -- Token redaction (security) tests --

  describe "token redaction" do
    test "sanitize_opts strips the token but keeps other opts" do
      sanitized = Hotline.Bot.sanitize_opts(token: "SECRET", name: :my_bot, chat_id: 7)
      refute Keyword.has_key?(sanitized, :token)
      assert sanitized[:name] == :my_bot
      assert sanitized[:chat_id] == 7
    end

    test "redact_opts hides the token value but keeps the key" do
      redacted = Hotline.Bot.redact_opts(token: "SECRET", name: :my_bot)
      assert redacted[:token] == "[REDACTED]"
      assert redacted[:name] == :my_bot
      refute inspect(redacted) =~ "SECRET"
    end

    test "init does not store the token in state.opts" do
      name = :"redact_bot_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        CommandBot.start_link(token: "SUPER-SECRET-TOKEN", name: name, allowed_ids: [1])

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      state = :sys.get_state(pid)
      refute Keyword.has_key?(state.opts, :token)
      refute inspect(state) =~ "SUPER-SECRET-TOKEN"

      # And OTP status output (used by crash reports) is clean too.
      refute inspect(:sys.get_status(pid)) =~ "SUPER-SECRET-TOKEN"
    end

    test "format_status/1 redacts a token that reappears in opts" do
      status = %{state: %{chat_id: nil, allowed_ids: nil, opts: [token: "LEAK", name: :x]}}
      redacted = CommandBot.format_status(status)
      assert redacted.state.opts[:token] == "[REDACTED]"
      refute inspect(redacted) =~ "LEAK"
    end
  end

  # -- disallowed-sender telemetry tests --

  # Named handler (a remote capture, so :telemetry doesn't warn about local funs)
  # that only forwards events for this test's unique sender id — the global
  # [:hotline, :update, :rejected] event must not cross-talk between async tests.
  def forward_rejected(_event, _measurements, meta, %{pid: pid, sender_id: sender_id}) do
    if meta.sender_id == sender_id, do: send(pid, {:rejected, meta})
  end

  describe "disallowed sender telemetry" do
    defp attach_rejected_handler(sender_id) do
      handler_id = "rejected-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:hotline, :update, :rejected],
        &__MODULE__.forward_rejected/4,
        %{pid: self(), sender_id: sender_id}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    defp start_restricted_bot do
      name = :"restricted_#{System.unique_integer([:positive])}"
      {:ok, pid} = RestrictedBot.start_link(name: name)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      pid
    end

    test "emits [:hotline, :update, :rejected] for a disallowed sender" do
      # RestrictedBot allows [111, 222]; pick a large unique id that is never allowed.
      disallowed = System.unique_integer([:positive]) + 1_000_000
      attach_rejected_handler(disallowed)
      pid = start_restricted_bot()

      send(pid, {:hotline_update, msg_update("hi", 5, disallowed)})

      assert_receive {:rejected, %{sender_id: ^disallowed, bot: RestrictedBot, update_id: _}}
    end

    test "does not emit :rejected for an allowed sender" do
      attach_rejected_handler(111)
      pid = start_restricted_bot()

      # 111 is in RestrictedBot's allow-list, so it takes the handled path.
      send(pid, {:hotline_update, msg_update("hi", 5, 111)})
      # Sync on the bot processing the message before refuting.
      :sys.get_state(pid)

      refute_received {:rejected, _}
    end

    test "a config allow-list that resolves to [] fails closed at init (rejects everyone)" do
      import ExUnit.CaptureLog

      # End-to-end proof of the F1 fix through the real init path: UnsetConfigBot
      # declares `allow {:config, unset}`, which used to collapse to allow-all.
      disallowed = System.unique_integer([:positive]) + 1_000_000
      attach_rejected_handler(disallowed)

      name = :"unset_config_#{System.unique_integer([:positive])}"

      # The deny-all warning must fire on this exact end-to-end init path (not just
      # in the isolated warn_if_deny_all/2 unit test).
      {pid, log} =
        with_log(fn ->
          {:ok, pid} = UnsetConfigBot.start_link(name: name)
          pid
        end)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      assert log =~ "deny-all"

      send(pid, {:hotline_update, msg_update("hi", 5, disallowed)})
      assert_receive {:rejected, %{sender_id: ^disallowed, bot: UnsetConfigBot}}
    end
  end

  # -- allow/1 compile-time validation tests --

  describe "allow/1 compile-time validation" do
    test "rejects a bare non-list id with a helpful message" do
      assert_raise ArgumentError, ~r/allow\/1 expects a list/, fn ->
        Code.compile_string(~s"""
        defmodule BadAllowBot#{System.unique_integer([:positive])} do
          use Hotline.Bot
          allow 123
        end
        """)
      end
    end

    test "accepts a list and a {:config, key} tuple" do
      result =
        Code.compile_string(~s"""
        defmodule GoodAllowBot#{System.unique_integer([:positive])} do
          use Hotline.Bot
          allow [1, 2]
          allow {:config, :admins}
        end
        """)

      assert [{_mod, _bytecode}] = result
    end
  end

  # -- parse_command tests --

  describe "parse_command" do
    test "parses simple command" do
      assert {"/start", ""} = Hotline.Bot.parse_command("/start")
    end

    test "parses command with args" do
      assert {"/echo", "hello world"} = Hotline.Bot.parse_command("/echo hello world")
    end

    test "strips @botname" do
      assert {"/start", ""} = Hotline.Bot.parse_command("/start@mybot")
    end

    test "strips @botname with args" do
      assert {"/echo", "hello"} = Hotline.Bot.parse_command("/echo@mybot hello")
    end
  end

  # -- extract_chat_id tests --

  describe "extract_chat_id" do
    test "extracts from message" do
      assert 42 = Hotline.Bot.extract_chat_id(%{message: %{chat: %{id: 42}}})
    end

    test "extracts from callback_query" do
      assert 42 =
               Hotline.Bot.extract_chat_id(%{
                 callback_query: %{message: %{chat: %{id: 42}}}
               })
    end

    test "extracts from edited_message" do
      assert 42 = Hotline.Bot.extract_chat_id(%{edited_message: %{chat: %{id: 42}}})
    end

    test "returns nil for unknown" do
      assert nil == Hotline.Bot.extract_chat_id(%{})
    end
  end
end
