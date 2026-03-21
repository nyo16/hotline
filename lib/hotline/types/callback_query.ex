defmodule Hotline.Types.CallbackQuery do
  @moduledoc "Telegram CallbackQuery object."

  use Hotline.Type

  alias Hotline.Types.{Message, User}

  defstruct [
    :id,
    :from,
    :message,
    :inline_message_id,
    :chat_instance,
    :data,
    :game_short_name
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          from: User.t(),
          message: Message.t() | nil,
          inline_message_id: String.t() | nil,
          chat_instance: String.t(),
          data: String.t() | nil,
          game_short_name: String.t() | nil
        }

  def parse_nested(_map) do
    %{
      from: &User.parse/1,
      message: &Message.parse/1
    }
  end
end
