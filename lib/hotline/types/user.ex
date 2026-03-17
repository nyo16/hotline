defmodule Hotline.Types.User do
  @moduledoc "Telegram User object."

  use Hotline.Type

  defstruct [
    :id,
    :is_bot,
    :first_name,
    :last_name,
    :username,
    :language_code,
    :is_premium,
    :added_to_attachment_menu,
    :can_join_groups,
    :can_read_all_group_messages,
    :supports_inline_queries,
    :can_connect_to_business,
    :has_main_web_app
  ]

  @type t :: %__MODULE__{
          id: integer(),
          is_bot: boolean(),
          first_name: String.t(),
          last_name: String.t() | nil,
          username: String.t() | nil,
          language_code: String.t() | nil,
          is_premium: boolean() | nil,
          added_to_attachment_menu: boolean() | nil,
          can_join_groups: boolean() | nil,
          can_read_all_group_messages: boolean() | nil,
          supports_inline_queries: boolean() | nil,
          can_connect_to_business: boolean() | nil,
          has_main_web_app: boolean() | nil
        }
end
