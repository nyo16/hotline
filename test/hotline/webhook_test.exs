defmodule Hotline.WebhookTest do
  use ExUnit.Case

  alias Hotline.Webhook

  setup do
    Application.delete_env(:hotline, :webhook_secret)
    Phoenix.PubSub.subscribe(Hotline.PubSub, "hotline:updates")

    on_exit(fn ->
      Application.delete_env(:hotline, :webhook_secret)
    end)
  end

  test "POST / with valid update broadcasts to PubSub" do
    body =
      JSON.encode!(%{
        "update_id" => 123,
        "message" => %{
          "message_id" => 1,
          "chat" => %{"id" => 456, "type" => "private"},
          "text" => "hello",
          "date" => 1_234_567_890
        }
      })

    conn =
      Plug.Test.conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Webhook.call(Webhook.init([]))

    assert conn.status == 200
    assert_receive {:hotline_update, %Hotline.Types.Update{update_id: 123}}
  end

  test "non-matching route returns 404" do
    conn =
      Plug.Test.conn(:get, "/nonexistent")
      |> Webhook.call(Webhook.init([]))

    assert conn.status == 404
  end

  test "POST / with wrong secret returns 401" do
    Application.put_env(:hotline, :webhook_secret, "my-secret")

    body = JSON.encode!(%{"update_id" => 123})

    conn =
      Plug.Test.conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-telegram-bot-api-secret-token", "wrong-secret")
      |> Webhook.call(Webhook.init([]))

    assert conn.status == 401
  end

  test "POST / with correct secret succeeds" do
    Application.put_env(:hotline, :webhook_secret, "my-secret")

    body =
      JSON.encode!(%{
        "update_id" => 456,
        "message" => %{
          "message_id" => 2,
          "chat" => %{"id" => 789, "type" => "private"},
          "text" => "secure",
          "date" => 0
        }
      })

    conn =
      Plug.Test.conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-telegram-bot-api-secret-token", "my-secret")
      |> Webhook.call(Webhook.init([]))

    assert conn.status == 200
    assert_receive {:hotline_update, %Hotline.Types.Update{update_id: 456}}
  end
end
