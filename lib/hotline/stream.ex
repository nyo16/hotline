defmodule Hotline.Stream do
  @moduledoc """
  Lazy stream of Telegram updates for IEx exploration.

  Usage:

      Hotline.stream(token: "your-token")
      |> Enum.each(fn update -> IO.inspect(update) end)
  """

  alias Hotline.{Client, Config, Types.Update}

  @doc "Create a lazy stream of Telegram updates."
  def resource(opts \\ []) do
    Stream.resource(
      fn -> {0, opts} end,
      fn {offset, opts} ->
        params = %{offset: offset, timeout: opts[:timeout] || 30}
        req_opts = [token: Config.token!(opts), base_url: Config.base_url(opts)]

        case Client.request("getUpdates", params, req_opts) do
          {:ok, []} ->
            {[], {offset, opts}}

          {:ok, updates} when is_list(updates) ->
            parsed = Enum.map(updates, &Update.parse/1)
            new_offset = List.last(parsed).update_id + 1
            {parsed, {new_offset, opts}}

          {:error, _} ->
            Process.sleep(1_000)
            {[], {offset, opts}}
        end
      end,
      fn _acc -> :ok end
    )
  end
end
