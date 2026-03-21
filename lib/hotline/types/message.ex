defmodule Hotline.Types.Message do
  @moduledoc "Telegram Message object."

  use Hotline.Type

  alias Hotline.Types.{Chat, User}

  defstruct [
    :message_id,
    :message_thread_id,
    :from,
    :sender_chat,
    :date,
    :chat,
    :text,
    :reply_to_message,
    :photo,
    :document,
    :caption,
    :entities,
    :reply_markup
  ]

  @type t :: %__MODULE__{
          message_id: integer(),
          message_thread_id: integer() | nil,
          from: User.t() | nil,
          sender_chat: Chat.t() | nil,
          date: integer(),
          chat: Chat.t(),
          text: String.t() | nil,
          reply_to_message: t() | nil,
          photo: list() | nil,
          document: map() | nil,
          caption: String.t() | nil,
          entities: list() | nil,
          reply_markup: map() | nil
        }

  def parse_nested(_map) do
    %{
      from: &User.parse/1,
      sender_chat: &Chat.parse/1,
      chat: &Chat.parse/1,
      reply_to_message: &parse/1
    }
  end
end
