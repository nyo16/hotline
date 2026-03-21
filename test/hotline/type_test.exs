defmodule Hotline.TypeTest do
  use ExUnit.Case, async: true

  alias Hotline.Types.{CallbackQuery, Chat, Message, Update, User}

  describe "User.parse/1" do
    test "parses a user map" do
      assert %User{id: 123, is_bot: false, first_name: "John"} =
               User.parse(%{
                 "id" => 123,
                 "is_bot" => false,
                 "first_name" => "John",
                 "last_name" => "Doe",
                 "username" => "johndoe"
               })
    end

    test "returns nil for nil input" do
      assert User.parse(nil) == nil
    end

    test "drops unknown fields" do
      user =
        User.parse(%{
          "id" => 1,
          "is_bot" => false,
          "first_name" => "Test",
          "unknown_field" => "should be dropped",
          "another_unknown" => 42
        })

      assert %User{id: 1, first_name: "Test"} = user
      refute Map.has_key?(Map.from_struct(user), :unknown_field)
    end

    test "handles missing optional fields" do
      user = User.parse(%{"id" => 1, "is_bot" => true, "first_name" => "Bot"})

      assert %User{id: 1, last_name: nil, username: nil} = user
    end
  end

  describe "Chat.parse/1" do
    test "parses a chat map" do
      assert %Chat{id: 456, type: "private"} =
               Chat.parse(%{"id" => 456, "type" => "private"})
    end
  end

  describe "Message.parse/1" do
    test "parses nested user and chat" do
      msg =
        Message.parse(%{
          "message_id" => 1,
          "date" => 1_234_567_890,
          "chat" => %{"id" => 100, "type" => "private"},
          "from" => %{"id" => 200, "is_bot" => false, "first_name" => "Alice"},
          "text" => "hello"
        })

      assert %Message{
               message_id: 1,
               text: "hello",
               chat: %Chat{id: 100},
               from: %User{id: 200, first_name: "Alice"}
             } = msg
    end

    test "handles nil nested fields" do
      msg =
        Message.parse(%{
          "message_id" => 1,
          "date" => 0,
          "chat" => %{"id" => 1, "type" => "private"}
        })

      assert %Message{from: nil, reply_to_message: nil} = msg
    end

    test "parses recursive reply_to_message" do
      msg =
        Message.parse(%{
          "message_id" => 2,
          "date" => 0,
          "chat" => %{"id" => 1, "type" => "private"},
          "reply_to_message" => %{
            "message_id" => 1,
            "date" => 0,
            "chat" => %{"id" => 1, "type" => "private"},
            "text" => "original"
          }
        })

      assert %Message{reply_to_message: %Message{message_id: 1, text: "original"}} = msg
    end
  end

  describe "CallbackQuery.parse/1" do
    test "parses with nested from and message" do
      cq =
        CallbackQuery.parse(%{
          "id" => "abc123",
          "from" => %{"id" => 1, "is_bot" => false, "first_name" => "Test"},
          "chat_instance" => "inst",
          "data" => "btn_1",
          "message" => %{
            "message_id" => 5,
            "date" => 0,
            "chat" => %{"id" => 1, "type" => "private"}
          }
        })

      assert %CallbackQuery{
               id: "abc123",
               data: "btn_1",
               from: %User{id: 1},
               message: %Message{message_id: 5}
             } = cq
    end
  end

  describe "Update.parse/1" do
    test "parses update with message" do
      update =
        Update.parse(%{
          "update_id" => 999,
          "message" => %{
            "message_id" => 1,
            "date" => 0,
            "chat" => %{"id" => 1, "type" => "private"},
            "text" => "hi"
          }
        })

      assert %Update{
               update_id: 999,
               message: %Message{text: "hi"}
             } = update
    end

    test "parses update with callback_query" do
      update =
        Update.parse(%{
          "update_id" => 1000,
          "callback_query" => %{
            "id" => "q1",
            "from" => %{"id" => 1, "is_bot" => false, "first_name" => "X"},
            "chat_instance" => "ci",
            "data" => "click"
          }
        })

      assert %Update{
               update_id: 1000,
               callback_query: %CallbackQuery{data: "click"}
             } = update
    end

    test "leaves unrecognized update types as raw maps" do
      update =
        Update.parse(%{
          "update_id" => 1001,
          "inline_query" => %{"id" => "iq1", "query" => "search"}
        })

      assert %Update{update_id: 1001, inline_query: %{"id" => "iq1"}} = update
    end
  end

  describe "parse_list/1" do
    test "parses a list of maps" do
      assert [%User{id: 1}, %User{id: 2}] =
               User.parse_list([
                 %{"id" => 1, "is_bot" => false, "first_name" => "A"},
                 %{"id" => 2, "is_bot" => true, "first_name" => "B"}
               ])
    end

    test "returns empty list for nil" do
      assert User.parse_list(nil) == []
    end
  end
end
