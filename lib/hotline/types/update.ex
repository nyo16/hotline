defmodule Hotline.Types.Update do
  @moduledoc "Telegram Update object."

  use Hotline.Type

  alias Hotline.Types.{CallbackQuery, Message}

  defstruct [
    :update_id,
    :message,
    :edited_message,
    :channel_post,
    :edited_channel_post,
    :callback_query,
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

  @type t :: %__MODULE__{
          update_id: integer(),
          message: Message.t() | nil,
          edited_message: Message.t() | nil,
          channel_post: Message.t() | nil,
          edited_channel_post: Message.t() | nil,
          callback_query: CallbackQuery.t() | nil,
          inline_query: map() | nil,
          chosen_inline_result: map() | nil,
          shipping_query: map() | nil,
          pre_checkout_query: map() | nil,
          poll: map() | nil,
          poll_answer: map() | nil,
          my_chat_member: map() | nil,
          chat_member: map() | nil,
          chat_join_request: map() | nil
        }

  def parse_nested(_map) do
    %{
      message: &Message.parse/1,
      edited_message: &Message.parse/1,
      channel_post: &Message.parse/1,
      edited_channel_post: &Message.parse/1,
      callback_query: &CallbackQuery.parse/1
    }
  end
end
