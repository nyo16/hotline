defmodule Hotline.Error do
  @moduledoc """
  Structured error type for Telegram API and transport errors.
  """

  defexception [:type, :code, :message, :parameters]

  @type t :: %__MODULE__{
          type: :api | :transport,
          code: integer() | nil,
          message: String.t(),
          parameters: map() | nil
        }

  @impl true
  def message(%__MODULE__{type: type, code: nil, message: msg}) do
    "[#{type}] #{msg}"
  end

  def message(%__MODULE__{type: type, code: code, message: msg}) do
    "[#{type}] #{code}: #{msg}"
  end

  @doc "Extract retry_after from error parameters, if present."
  def retry_after(%__MODULE__{parameters: %{"retry_after" => seconds}}), do: seconds
  def retry_after(%__MODULE__{}), do: nil

  @doc "Build an API error from a Telegram error response."
  def api(code, description, parameters \\ nil) do
    %__MODULE__{
      type: :api,
      code: code,
      message: description,
      parameters: parameters
    }
  end

  @doc "Build a transport error."
  def transport(message) do
    %__MODULE__{
      type: :transport,
      message: message
    }
  end
end
