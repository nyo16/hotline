defmodule Hotline.Poller do
  @moduledoc """
  GenServer that long-polls `getUpdates` and broadcasts to PubSub.

  Handles 409 conflict detection and 429 rate limit backoff.
  """

  use GenServer

  alias Hotline.{Client, Config, Error, Types.Update}

  @default_timeout 30

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %{
      offset: 0,
      token: Config.token!(opts),
      base_url: Config.base_url(opts),
      timeout: opts[:timeout] || @default_timeout,
      allowed_updates: opts[:allowed_updates],
      poll_interval: opts[:poll_interval] || 0,
      # Injectable client boundary (defaults to Client.request/3) so tests can
      # stub getUpdates without making live Telegram calls.
      request_fun: opts[:request_fun] || (&Client.request/3)
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    params =
      %{offset: state.offset, timeout: state.timeout}
      |> maybe_put(:allowed_updates, state.allowed_updates)

    opts = [token: state.token, base_url: state.base_url]

    case state.request_fun.("getUpdates", params, opts) do
      {:ok, updates} when is_list(updates) ->
        handle_updates(updates, state)

      {:error, %Error{} = error} ->
        handle_poll_error(error, state)
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Redact the bot token from SASL crash reports and :sys.get_status/1 output.
  # OTP dumps process state on any crash; without this the full Telegram token
  # would be written to logs/aggregators.
  @impl true
  def format_status(status) do
    case status do
      %{state: %{token: _} = state} -> %{status | state: %{state | token: "[REDACTED]"}}
      _ -> status
    end
  end

  defp handle_updates(updates, state) do
    parsed = Enum.map(updates, &Update.parse/1)

    # Single GLOBAL topic: ChatRegistry, Flow.Engine, and every Bot all subscribe to
    # "hotline:updates". There is no per-chat or per-bot topic partitioning, so every
    # subscriber receives every update and must ignore the ones it doesn't handle.
    # Consequently anything broadcasting here (including tests) can cross-talk with
    # other subscribers — which is why poller_test.exs must stay `async: false`.
    for update <- parsed do
      :telemetry.execute([:hotline, :update, :received], %{}, %{update_id: update.update_id})
      Phoenix.PubSub.broadcast(Hotline.PubSub, "hotline:updates", {:hotline_update, update})
    end

    new_offset =
      case parsed do
        [] -> state.offset
        _ -> List.last(parsed).update_id + 1
      end

    schedule_poll(state.poll_interval)
    {:noreply, %{state | offset: new_offset}}
  end

  defp handle_poll_error(%Error{} = error, state) do
    schedule_poll(backoff_ms(error))
    {:noreply, state}
  end

  @doc false
  # Backoff before the next poll: 5s on a 409 conflict (another getUpdates
  # consumer is running), the server's `retry_after` on a 429, else 1s.
  @spec backoff_ms(Error.t()) :: pos_integer()
  def backoff_ms(%Error{code: 409}), do: 5_000

  def backoff_ms(%Error{} = error) do
    case Error.retry_after(error) do
      nil -> 1_000
      seconds -> seconds * 1_000
    end
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
