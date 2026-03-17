defmodule Hotline.Types.Update do
  @moduledoc "Telegram Update object."

  use Hotline.Type

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
          message: Hotline.Types.Message.t() | nil,
          edited_message: Hotline.Types.Message.t() | nil,
          channel_post: Hotline.Types.Message.t() | nil,
          edited_channel_post: Hotline.Types.Message.t() | nil,
          callback_query: Hotline.Types.CallbackQuery.t() | nil,
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
      message: &Hotline.Types.Message.parse/1,
      edited_message: &Hotline.Types.Message.parse/1,
      channel_post: &Hotline.Types.Message.parse/1,
      edited_channel_post: &Hotline.Types.Message.parse/1,
      callback_query: &Hotline.Types.CallbackQuery.parse/1
    }
  end
end
