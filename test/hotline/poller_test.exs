defmodule Hotline.PollerTest do
  # async: false (the default) is REQUIRED here — do NOT flip to async: true.
  # These tests drive real broadcasts on the GLOBAL "hotline:updates" topic that
  # ChatRegistry, Flow.Engine, and every Bot subscribe to. Running async would let
  # those broadcasts land in other modules' async-test subscribers mid-run; today
  # that only stays safe because those subscribers no-op on unknown updates.
  use ExUnit.Case

  alias Hotline.{Error, Poller}

  defp unique_name, do: :"poller_#{System.unique_integer([:positive])}"

  # Start a poller whose single immediate poll returns `response`. poll_interval
  # is large so no second poll fires during the test; the stub notifies the test
  # process of each request so we can assert on the getUpdates params.
  defp start_poller(response, opts \\ []) do
    test_pid = self()

    request_fun = fn method, params, _opts ->
      send(test_pid, {:request, method, params})
      response
    end

    defaults = [
      token: "test-token",
      name: unique_name(),
      poll_interval: 60_000,
      request_fun: request_fun
    ]

    {:ok, pid} = Poller.start_link(Keyword.merge(defaults, opts))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  describe "init/1" do
    test "seeds state from opts and defaults" do
      pid = start_poller({:ok, []}, timeout: 45, allowed_updates: ["message"])
      # :sys.get_state syncs past the immediate empty poll.
      state = :sys.get_state(pid)

      assert state.offset == 0
      assert state.token == "test-token"
      assert state.timeout == 45
      assert state.allowed_updates == ["message"]
      assert state.base_url == "https://api.telegram.org"
      assert is_function(state.request_fun, 3)
    end

    test "returns an error when no token is configured" do
      Process.flag(:trap_exit, true)

      assert {:error, {%RuntimeError{message: msg}, _stack}} =
               Poller.start_link(name: unique_name(), request_fun: fn _, _, _ -> {:ok, []} end)

      assert msg =~ "token not configured"
    end
  end

  describe "polling" do
    test "requests getUpdates with the current offset and timeout" do
      start_poller({:ok, []})
      assert_receive {:request, "getUpdates", params}
      assert params.offset == 0
      assert params.timeout == 30
      refute Map.has_key?(params, :allowed_updates)
    end

    test "includes allowed_updates when configured" do
      start_poller({:ok, []}, allowed_updates: ["message", "callback_query"])
      assert_receive {:request, "getUpdates", params}
      assert params.allowed_updates == ["message", "callback_query"]
    end

    test "advances the offset past the last update and broadcasts each update" do
      Phoenix.PubSub.subscribe(Hotline.PubSub, "hotline:updates")

      pid = start_poller({:ok, [%{"update_id" => 10}, %{"update_id" => 11}]})

      assert_receive {:hotline_update, %{update_id: 10}}
      assert_receive {:hotline_update, %{update_id: 11}}

      assert :sys.get_state(pid).offset == 12
    end

    test "keeps the offset unchanged when there are no updates" do
      pid = start_poller({:ok, []})
      assert :sys.get_state(pid).offset == 0
    end
  end

  describe "error backoff" do
    test "survives a poll error and does not advance the offset" do
      pid = start_poller({:error, Error.api(409, "Conflict: terminated by other getUpdates")})

      assert_receive {:request, "getUpdates", _params}
      state = :sys.get_state(pid)

      assert Process.alive?(pid)
      assert state.offset == 0
    end

    test "re-polls after an error: issues a second getUpdates and advances the offset" do
      # The other error tests only prove the Poller survives ONE failed poll. This
      # proves it actually keeps polling: first poll fails, a second poll fires and
      # succeeds. A stateful stub (atomics counter) varies the response per call.
      test_pid = self()
      counter = :atomics.new(1, [])

      request_fun = fn method, params, _opts ->
        n = :atomics.add_get(counter, 1, 1)
        send(test_pid, {:request, n, method, params})

        case n do
          # retry_after: 0 keeps the backoff ~0ms so the re-poll lands inside the
          # assert_receive window. The exact backoff is covered by backoff_ms/1
          # unit tests — here we only care THAT it re-polls.
          1 -> {:error, Error.api(429, "Too Many Requests", %{"retry_after" => 0})}
          _ -> {:ok, [%{"update_id" => 77}]}
        end
      end

      {:ok, pid} =
        Poller.start_link(
          token: "test-token",
          name: unique_name(),
          poll_interval: 60_000,
          request_fun: request_fun
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      # First poll errored (offset unchanged), then a second poll fires at the same
      # offset and succeeds.
      assert_receive {:request, 1, "getUpdates", %{offset: 0}}
      assert_receive {:request, 2, "getUpdates", %{offset: 0}}

      # The successful second poll advanced the offset past update 77.
      assert :sys.get_state(pid).offset == 78
    end

    test "backoff_ms/1 waits 5s on a 409 conflict" do
      assert Poller.backoff_ms(Error.api(409, "Conflict")) == 5_000
    end

    test "backoff_ms/1 honours retry_after on a 429" do
      error = Error.api(429, "Too Many Requests", %{"retry_after" => 30})
      assert Poller.backoff_ms(error) == 30_000
    end

    test "backoff_ms/1 falls back to 1s for other errors" do
      assert Poller.backoff_ms(Error.api(500, "Internal Server Error")) == 1_000
      assert Poller.backoff_ms(Error.transport("connection refused")) == 1_000
    end
  end

  describe "format_status/1" do
    test "redacts the bot token from status output" do
      status = %{
        state: %{
          offset: 0,
          token: "SUPER-SECRET-TOKEN",
          base_url: "https://api.telegram.org",
          timeout: 30,
          allowed_updates: nil,
          poll_interval: 0,
          request_fun: fn _, _, _ -> {:ok, []} end
        }
      }

      redacted = Poller.format_status(status)
      assert redacted.state.token == "[REDACTED]"
      refute inspect(redacted) =~ "SUPER-SECRET-TOKEN"
    end

    test "hides the token from :sys.get_status/1 (exercises the real OTP callback path)" do
      # The direct-call test above would still pass if format_status/1 had the wrong
      # callback shape and OTP silently fell back to the default (no redaction). Drive
      # the token through :sys.get_status so a broken callback fails OPEN visibly here.
      pid = start_poller({:ok, []}, token: "SUPER-SECRET-OTP-TOKEN")

      dump = inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity)

      refute dump =~ "SUPER-SECRET-OTP-TOKEN"
      assert dump =~ "[REDACTED]"
    end
  end
end
