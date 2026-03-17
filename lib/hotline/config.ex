defmodule Hotline.Config do
  @moduledoc """
  Cascading configuration resolution.

  Resolution order (first non-nil wins):

  1. Explicit options passed to functions
  2. Application environment (`config :hotline, ...`)
  3. System environment variables
  4. Defaults
  """

  @env_mappings %{
    token: "HOTLINE_TOKEN",
    base_url: "HOTLINE_BASE_URL"
  }

  @defaults %{
    base_url: "https://api.telegram.org"
  }

  @doc "Resolve a config key using cascading resolution."
  def resolve(key, opts \\ []) do
    with nil <- opts[key],
         nil <- Application.get_env(:hotline, key),
         nil <- sys_env(key) do
      @defaults[key]
    end
  end

  @doc "Resolve the bot token. Raises if not configured."
  def token!(opts \\ []) do
    resolve(:token, opts) ||
      raise """
      Hotline bot token not configured.
      Set via one of:
        - opts: [token: "..."]
        - config :hotline, token: "..."
        - HOTLINE_TOKEN env var
      """
  end

  @doc "Resolve the base URL for the Telegram API."
  def base_url(opts \\ []) do
    resolve(:base_url, opts)
  end

  defp sys_env(key) do
    case @env_mappings[key] do
      nil -> nil
      env_var -> System.get_env(env_var)
    end
  end
end
