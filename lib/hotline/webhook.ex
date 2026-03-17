defmodule Hotline.Webhook do
  @moduledoc """
  Plug for receiving Telegram webhook POSTs.

  Verifies the secret token header if configured, parses the update,
  and broadcasts to PubSub.
  """

  use Plug.Router

  alias Hotline.Types.Update

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: JSON)
  plug(:dispatch)

  post "/" do
    secret = Application.get_env(:hotline, :webhook_secret)

    if secret && get_req_header(conn, "x-telegram-bot-api-secret-token") != [secret] do
      send_resp(conn, 401, "unauthorized")
    else
      update = Update.parse(conn.body_params)

      :telemetry.execute([:hotline, :update, :received], %{}, %{update_id: update.update_id})
      Phoenix.PubSub.broadcast(Hotline.PubSub, "hotline:updates", {:hotline_update, update})

      send_resp(conn, 200, "ok")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end

defmodule Hotline.Webhook.Router do
  @moduledoc """
  Standalone router for webhook deployment with Bandit.

  Usage in your supervision tree:

      {Bandit, plug: Hotline.Webhook.Router, port: 4000}
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  forward("/webhook", to: Hotline.Webhook)

  match _ do
    send_resp(conn, 404, "not found")
  end
end
