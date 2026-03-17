defmodule Hotline.Types.CallbackQuery do
  @moduledoc "Telegram CallbackQuery object."

  use Hotline.Type

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
          from: Hotline.Types.User.t(),
          message: Hotline.Types.Message.t() | nil,
          inline_message_id: String.t() | nil,
          chat_instance: String.t(),
          data: String.t() | nil,
          game_short_name: String.t() | nil
        }

  def parse_nested(_map) do
    %{
      from: &Hotline.Types.User.parse/1,
      message: &Hotline.Types.Message.parse/1
    }
  end
end
