defmodule Hotline.ConfigTest do
  use ExUnit.Case, async: true

  alias Hotline.Config

  setup do
    # Clean up any app env we set
    on_exit(fn ->
      Application.delete_env(:hotline, :token)
      Application.delete_env(:hotline, :base_url)
      System.delete_env("HOTLINE_TOKEN")
      System.delete_env("HOTLINE_BASE_URL")
    end)
  end

  describe "resolve/2" do
    test "opts take highest priority" do
      Application.put_env(:hotline, :token, "app-token")
      System.put_env("HOTLINE_TOKEN", "env-token")

      assert Config.resolve(:token, token: "opt-token") == "opt-token"
    end

    test "app env is second priority" do
      Application.put_env(:hotline, :token, "app-token")
      System.put_env("HOTLINE_TOKEN", "env-token")

      assert Config.resolve(:token) == "app-token"
    end

    test "system env is third priority" do
      System.put_env("HOTLINE_TOKEN", "env-token")

      assert Config.resolve(:token) == "env-token"
    end

    test "returns default when nothing set" do
      assert Config.resolve(:base_url) == "https://api.telegram.org"
    end

    test "returns nil for unknown keys with no default" do
      assert Config.resolve(:nonexistent) == nil
    end
  end

  describe "token!/1" do
    test "returns token when configured" do
      assert Config.token!(token: "my-token") == "my-token"
    end

    test "raises when not configured" do
      assert_raise RuntimeError, ~r/bot token not configured/, fn ->
        Config.token!()
      end
    end
  end

  describe "base_url/1" do
    test "returns default base_url" do
      assert Config.base_url() == "https://api.telegram.org"
    end

    test "returns custom base_url from opts" do
      assert Config.base_url(base_url: "http://localhost:8081") == "http://localhost:8081"
    end
  end
end
