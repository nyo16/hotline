defmodule Hotline.Client do
  @moduledoc """
  HTTP client for the Telegram Bot API using Req.

  Handles JSON and multipart requests, retries, telemetry, and response parsing.

  ## Token handling

  The bot token is embedded in the request path (`/bot<TOKEN>/<method>`) as the
  Telegram API requires. It is never logged: telemetry metadata carries only the
  method and params, transport errors surface the reason (not the URL), and Req's
  retry logging omits the URL. Keep custom telemetry handlers from logging the URL.
  """

  alias Hotline.{Config, Error}

  @doc "Make a request to the Telegram Bot API."
  def request(method, params \\ %{}, opts \\ []) do
    token = Config.token!(opts)
    base_url = Config.base_url(opts)
    url = "#{base_url}/bot#{token}/#{method}"
    params = normalize_params(params)
    {file_params, json_params} = split_params(params)

    metadata = %{method: method, params: params}

    :telemetry.execute(
      [:hotline, :request, :start],
      %{system_time: System.system_time()},
      metadata
    )

    start_time = System.monotonic_time()

    result =
      if map_size(file_params) > 0 do
        do_multipart_request(url, json_params, file_params)
      else
        do_json_request(url, json_params)
      end

    duration = System.monotonic_time() - start_time
    :telemetry.execute([:hotline, :request, :stop], %{duration: duration}, metadata)

    result
  end

  defp do_json_request(url, params) do
    body = JSON.encode!(params)

    Req.post(url,
      body: body,
      headers: [{"content-type", "application/json"}],
      decode_body: false,
      retry: :transient,
      max_retries: 3
    )
    |> handle_response()
  end

  defp do_multipart_request(url, json_params, file_params) do
    form_fields =
      Enum.map(json_params, fn {k, v} ->
        {to_string(k), encode_param_value(v)}
      end)

    file_fields =
      Enum.map(file_params, fn {k, v} ->
        {to_string(k), build_file_part(v)}
      end)

    Req.post(url,
      form_multipart: form_fields ++ file_fields,
      decode_body: false,
      retry: :transient,
      max_retries: 3
    )
    |> handle_response()
  end

  defp build_file_part({:file, path}) do
    mime = detect_mime(path)
    filename = Path.basename(path)
    {filename, File.read!(path), content_type: mime, filename: filename}
  end

  defp build_file_part({:file_content, data, filename}) do
    mime = detect_mime(filename)
    {filename, data, content_type: mime, filename: filename}
  end

  defp handle_response({:ok, %Req.Response{body: body}}) do
    decoded = decode_body(body)

    case decoded do
      %{"ok" => true, "result" => result} ->
        {:ok, result}

      %{"ok" => false, "error_code" => code, "description" => desc} = resp ->
        {:error, Error.api(code, desc, resp["parameters"])}

      _ ->
        {:error, Error.transport("unexpected response format")}
    end
  end

  defp handle_response({:error, %Req.TransportError{reason: reason}}) do
    {:error, Error.transport("transport error: #{inspect(reason)}")}
  end

  defp handle_response({:error, exception}) when is_exception(exception) do
    {:error, Error.transport(Exception.message(exception))}
  end

  defp handle_response({:error, reason}) do
    {:error, Error.transport("request failed: #{inspect(reason)}")}
  end

  defp decode_body(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{"ok" => false, "error_code" => 0, "description" => "invalid JSON response"}
    end
  end

  defp decode_body(body) when is_map(body), do: body

  defp normalize_params(params) when is_map(params), do: params
  defp normalize_params(params) when is_list(params), do: Map.new(params)

  defp split_params(params) do
    {file, json} =
      Enum.split_with(params, fn
        {_k, {:file, _}} -> true
        {_k, {:file_content, _, _}} -> true
        _ -> false
      end)

    {Map.new(file), Map.new(json)}
  end

  defp encode_param_value(v) when is_map(v), do: JSON.encode!(v)
  defp encode_param_value(v) when is_list(v), do: JSON.encode!(v)
  defp encode_param_value(v), do: to_string(v)

  defp detect_mime(path) do
    if Code.ensure_loaded?(MIME) and function_exported?(MIME, :from_path, 1) do
      MIME.from_path(path)
    else
      "application/octet-stream"
    end
  end
end
