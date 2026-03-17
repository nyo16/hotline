defmodule Hotline.Types.Chat do
  @moduledoc "Telegram Chat object."

  use Hotline.Type

  defstruct [
    :id,
    :type,
    :title,
    :username,
    :first_name,
    :last_name
  ]

  @type t :: %__MODULE__{
          id: integer(),
          type: String.t(),
          title: String.t() | nil,
          username: String.t() | nil,
          first_name: String.t() | nil,
          last_name: String.t() | nil
        }
end
