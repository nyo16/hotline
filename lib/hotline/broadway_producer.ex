if Code.ensure_loaded?(Broadway) do
  defmodule Hotline.BroadwayProducer do
    @moduledoc """
    Broadway producer for Telegram updates.

    Only available when Broadway is loaded.

    Usage:

        defmodule MyPipeline do
          use Broadway

          def start_link(_opts) do
            Broadway.start_link(__MODULE__,
              name: __MODULE__,
              producer: [
                module: {Hotline.BroadwayProducer, [token: "your-token"]}
              ],
              processors: [default: [concurrency: 5]]
            )
          end

          def handle_message(_, message, _) do
            IO.inspect(message.data)
            message
          end
        end
    """

    use GenStage

    alias Hotline.{Client, Config, Types.Update}

    def start_link(opts) do
      GenStage.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      state = %{
        offset: 0,
        token: Config.token!(opts),
        base_url: Config.base_url(opts),
        timeout: opts[:timeout] || 30,
        demand: 0
      }

      {:producer, state}
    end

    @impl true
    def handle_demand(demand, state) do
      state = %{state | demand: state.demand + demand}
      fetch_updates(state)
    end

    @impl true
    def handle_info(:fetch, state) do
      fetch_updates(state)
    end

    defp fetch_updates(%{demand: 0} = state), do: {:noreply, [], state}

    defp fetch_updates(state) do
      params = %{offset: state.offset, timeout: state.timeout, limit: state.demand}
      opts = [token: state.token, base_url: state.base_url]

      case Client.request("getUpdates", params, opts) do
        {:ok, updates} when is_list(updates) and updates != [] ->
          parsed = Enum.map(updates, &Update.parse/1)
          new_offset = List.last(parsed).update_id + 1

          messages =
            Enum.map(parsed, fn update ->
              %Broadway.Message{
                data: update,
                acknowledger: {__MODULE__, :ack_id, :ack_data}
              }
            end)

          new_demand = max(0, state.demand - length(messages))
          {:noreply, messages, %{state | offset: new_offset, demand: new_demand}}

        _ ->
          Process.send_after(self(), :fetch, 1_000)
          {:noreply, [], state}
      end
    end

    def ack(_ack_ref, _successful, _failed), do: :ok
  end
end
