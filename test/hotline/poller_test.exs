defmodule Hotline.PollerTest do
  use ExUnit.Case

  test "broadcasts updates to PubSub" do
    Phoenix.PubSub.subscribe(Hotline.PubSub, "hotline:updates")

    update = %Hotline.Types.Update{
      update_id: 42,
      message: %Hotline.Types.Message{
        message_id: 1,
        date: 0,
        chat: %Hotline.Types.Chat{id: 1, type: "private"},
        text: "test"
      }
    }

    Phoenix.PubSub.broadcast(Hotline.PubSub, "hotline:updates", {:hotline_update, update})

    assert_receive {:hotline_update, %Hotline.Types.Update{update_id: 42}}
  end
end
