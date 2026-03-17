defmodule Hotline do
  @moduledoc """
  Telegram Bot API client and framework for Elixir.

  Provides convenience functions for common Telegram Bot API methods,
  automatic type parsing, long-polling, webhooks, and a bot behaviour.

  ## Quick Start

      # Get bot info
      {:ok, me} = Hotline.get_me(token: "your-bot-token")

      # Send a message
      {:ok, msg} = Hotline.send_message(%{chat_id: 123, text: "Hello!"}, token: "your-bot-token")

      # Stream updates in IEx
      Hotline.stream(token: "your-token") |> Enum.each(&IO.inspect/1)
  """

  alias Hotline.{Client, Types}

  @doc "Get information about the bot."
  def get_me(opts \\ []) do
    with {:ok, result} <- Client.request("getMe", %{}, opts) do
      {:ok, Types.User.parse(result)}
    end
  end

  @doc "Send a text message."
  def send_message(params, opts \\ []) do
    with {:ok, result} <- Client.request("sendMessage", Map.new(params), opts) do
      {:ok, Types.Message.parse(result)}
    end
  end

  @doc "Send a photo."
  def send_photo(params, opts \\ []) do
    with {:ok, result} <- Client.request("sendPhoto", Map.new(params), opts) do
      {:ok, Types.Message.parse(result)}
    end
  end

  @doc "Send a document."
  def send_document(params, opts \\ []) do
    with {:ok, result} <- Client.request("sendDocument", Map.new(params), opts) do
      {:ok, Types.Message.parse(result)}
    end
  end

  @doc "Answer a callback query."
  def answer_callback_query(params, opts \\ []) do
    Client.request("answerCallbackQuery", Map.new(params), opts)
  end

  @doc "Edit a message's text."
  def edit_message_text(params, opts \\ []) do
    with {:ok, result} <- Client.request("editMessageText", Map.new(params), opts) do
      {:ok, Types.Message.parse(result)}
    end
  end

  @doc "Delete a message."
  def delete_message(params, opts \\ []) do
    Client.request("deleteMessage", Map.new(params), opts)
  end

  @doc "Set webhook URL."
  def set_webhook(params, opts \\ []) do
    Client.request("setWebhook", Map.new(params), opts)
  end

  @doc "Delete webhook."
  def delete_webhook(opts \\ []) do
    Client.request("deleteWebhook", %{}, opts)
  end

  @doc "Make a raw API request."
  def request(method, params \\ %{}, opts \\ []) do
    Client.request(method, params, opts)
  end

  @doc "Create a lazy stream of updates."
  def stream(opts \\ []) do
    Hotline.Stream.resource(opts)
  end
end
