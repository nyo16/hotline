defmodule Hotline.Type do
  @moduledoc """
  Macro for Telegram API type structs with automatic parsing.

  Usage:

      defmodule Hotline.Types.User do
        use Hotline.Type

        defstruct [:id, :is_bot, :first_name]

        @type t :: %__MODULE__{
                id: integer(),
                is_bot: boolean(),
                first_name: String.t()
              }
      end

  The `parse/1` function converts a raw map (with string keys) into the struct,
  dropping unknown fields and applying nested type parsing via `parse_nested/1`.

  Override `parse_nested/1` to return a map of `%{field_atom => parser_fn}` for
  fields that contain nested Hotline types.
  """

  @callback parse(map() | nil) :: struct() | nil
  @callback parse_nested(map()) :: map()

  @doc false
  def apply_nested(nested, key, raw) do
    case Map.get(nested, key) do
      parser when is_function(parser, 1) and not is_nil(raw) -> parser.(raw)
      _ -> raw
    end
  end

  defmacro __using__(_opts) do
    quote do
      @behaviour Hotline.Type

      @doc "Parse a raw map into this type struct."
      def parse(nil), do: nil

      def parse(%{} = map) when not is_struct(map) do
        known_keys =
          __MODULE__.__struct__()
          |> Map.from_struct()
          |> Map.keys()

        nested = parse_nested(map)

        attrs =
          for key <- known_keys, into: %{} do
            str_key = Atom.to_string(key)
            raw = Map.get(map, str_key)
            value = Hotline.Type.apply_nested(nested, key, raw)
            {key, value}
          end

        struct(__MODULE__, attrs)
      end

      @doc "Parse a list of raw maps."
      def parse_list(nil), do: []

      def parse_list(list) when is_list(list) do
        Enum.map(list, &parse/1)
      end

      @doc false
      def parse_nested(_map), do: %{}

      defoverridable parse_nested: 1
    end
  end
end
