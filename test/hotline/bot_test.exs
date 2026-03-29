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
      Application.put_env(:hotline, :test_allowed_ids, [444, 555])
      assert [444, 555] = Hotline.Bot.resolve_allowed_ids([{:config, :test_allowed_ids}])
      Application.delete_env(:hotline, :test_allowed_ids)
    end

    test "merge_allowed_ids returns nil when both empty" do
      assert nil == Hotline.Bot.merge_allowed_ids([], nil)
    end

    test "merge_allowed_ids uses declared when no runtime" do
      assert [111] = Hotline.Bot.merge_allowed_ids([111], nil)
    end

    test "merge_allowed_ids uses runtime when no declared" do
      assert [222] = Hotline.Bot.merge_allowed_ids([], [222])
    end

    test "merge_allowed_ids merges both" do
      result = Hotline.Bot.merge_allowed_ids([111], [222])
      assert 111 in result
      assert 222 in result
    end

    test "merge_allowed_ids deduplicates" do
      result = Hotline.Bot.merge_allowed_ids([111, 222], [222, 333])
      assert length(result) == 3
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
