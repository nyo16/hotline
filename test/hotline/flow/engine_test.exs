defmodule Hotline.Flow.EngineTest do
  use ExUnit.Case

  alias Hotline.Flow.Engine

  # Test flow modules

  defmodule TestRegistration do
    use Hotline.Flow

    step(:name, prompt: "What's your name?")
    step(:confirm, prompt: "Confirm?")

    @impl true
    def handle_input(:name, %{message: %{text: name}}, _ctx) when byte_size(name) >= 2 do
      {:next, store: %{name: name}}
    end

    def handle_input(:name, _, _ctx), do: {:retry, "Too short."}
    def handle_input(:confirm, %{message: %{text: "yes"}}, _ctx), do: :done
    def handle_input(:confirm, _, _ctx), do: {:retry, "Say yes."}

    def on_done(ctx), do: send(ctx.opts[:test_pid], {:flow_done, ctx.data})
    def on_cancel(ctx), do: send(ctx.opts[:test_pid], :flow_cancelled)
  end

  defmodule CrashingFlow do
    use Hotline.Flow

    step(:boom, prompt: "This will crash.")

    @impl true
    def handle_input(:boom, _, _ctx), do: raise("boom!")
  end

  # Helpers

  defp unique_name, do: :"engine_#{System.unique_integer([:positive])}"

  defp start_engine(opts \\ []) do
    test_pid = self()

    sender = fn params, _opts ->
      send(test_pid, {:sent, params})
      {:ok, %{}}
    end

    name = opts[:name] || unique_name()

    {:ok, pid} = Engine.start_link(Keyword.merge([sender: sender, name: name], opts))
    {pid, name}
  end

  defp msg_update(text, chat_id) do
    %{
      update_id: System.unique_integer([:positive]),
      message: %{text: text, chat: %{id: chat_id}, from: %{id: chat_id}},
      callback_query: nil,
      edited_message: nil
    }
  end

  defp cb_update(data, chat_id) do
    %{
      update_id: System.unique_integer([:positive]),
      message: nil,
      callback_query: %{
        id: "cb_#{System.unique_integer([:positive])}",
        data: data,
        message: %{chat: %{id: chat_id}},
        from: %{id: chat_id}
      },
      edited_message: nil
    }
  end

  defp send_update(engine_pid, update) do
    send(engine_pid, {:hotline_update, update})
    # Wait for the GenServer to process the message
    :sys.get_state(engine_pid)
  end

  # Tests

  describe "start_flow/4" do
    test "starts a flow and sends the first prompt" do
      {_pid, name} = start_engine()

      assert :ok = Engine.start_flow(123, TestRegistration, %{test_pid: self()}, name)
      assert_receive {:sent, %{chat_id: 123, text: "What's your name?"}}
    end

    test "returns error if flow already active" do
      {_pid, name} = start_engine()

      assert :ok = Engine.start_flow(123, TestRegistration, %{test_pid: self()}, name)
      assert {:error, :flow_active} = Engine.start_flow(123, TestRegistration, %{}, name)
    end

    test "allows different chats to have flows simultaneously" do
      {_pid, name} = start_engine()

      assert :ok = Engine.start_flow(100, TestRegistration, %{test_pid: self()}, name)
      assert :ok = Engine.start_flow(200, TestRegistration, %{test_pid: self()}, name)

      assert_receive {:sent, %{chat_id: 100, text: "What's your name?"}}
      assert_receive {:sent, %{chat_id: 200, text: "What's your name?"}}
    end
  end

  describe "cancel_flow/2" do
    test "cancels an active flow and calls on_cancel" do
      {_pid, name} = start_engine()

      Engine.start_flow(123, TestRegistration, %{test_pid: self()}, name)
      assert :ok = Engine.cancel_flow(123, name)
      assert_receive :flow_cancelled
      refute Engine.active_flow?(123, name)
    end

    test "returns error if no active flow" do
      {_pid, name} = start_engine()
      assert {:error, :no_flow} = Engine.cancel_flow(999, name)
    end
  end

  describe "active_flow?/2" do
    test "returns true when flow is active" do
      {_pid, name} = start_engine()

      Engine.start_flow(123, TestRegistration, %{test_pid: self()}, name)
      assert Engine.active_flow?(123, name)
    end

    test "returns false when no flow" do
      {_pid, name} = start_engine()
      refute Engine.active_flow?(999, name)
    end
  end

  describe "handles_update?/2" do
    test "returns true for update matching active flow" do
      {_pid, name} = start_engine()

      Engine.start_flow(123, TestRegistration, %{test_pid: self()}, name)
      assert Engine.handles_update?(msg_update("hi", 123), name)
    end

    test "returns false for unrelated update" do
      {_pid, name} = start_engine()
      refute Engine.handles_update?(msg_update("hi", 999), name)
    end

    test "returns false for update without chat_id" do
      {_pid, name} = start_engine()

      refute Engine.handles_update?(
               %{message: nil, callback_query: nil, edited_message: nil},
               name
             )
    end
  end

  describe "update routing" do
    test "routes text messages to active flow" do
      {pid, name} = start_engine()

      Engine.start_flow(123, TestRegistration, %{test_pid: self()}, name)
      assert_receive {:sent, %{chat_id: 123, text: "What's your name?"}}

      send_update(pid, msg_update("Alice", 123))
      assert_receive {:sent, %{chat_id: 123, text: "Confirm?"}}
    end

    test "ignores updates for chats without flows" do
      {pid, _name} = start_engine()

      send_update(pid, msg_update("hello", 999))
      refute_receive {:sent, _}
    end

    test "handles retry messages" do
      {pid, name} = start_engine()

      Engine.start_flow(123, TestRegistration, %{test_pid: self()}, name)
      assert_receive {:sent, %{chat_id: 123, text: "What's your name?"}}

      send_update(pid, msg_update("A", 123))
      assert_receive {:sent, %{chat_id: 123, text: "Too short."}}

      # Still active on same step
      assert Engine.active_flow?(123, name)
    end

    test "routes callback queries to active flow" do
      {pid, name} = start_engine()

      Engine.start_flow(123, TestRegistration, %{test_pid: self()}, name)
      assert_receive {:sent, _}

      # Callback queries still reach the flow (though TestRegistration doesn't handle them specially)
      send_update(pid, cb_update("some_data", 123))
      # Should get a retry since no callback handler matches "say yes"
      assert_receive {:sent, %{chat_id: 123}}
    end
  end

  describe "full flow lifecycle" do
    test "completes a flow from start to done" do
      {pid, name} = start_engine()

      Engine.start_flow(123, TestRegistration, %{test_pid: self()}, name)
      assert_receive {:sent, %{text: "What's your name?"}}

      send_update(pid, msg_update("Alice", 123))
      assert_receive {:sent, %{text: "Confirm?"}}

      send_update(pid, msg_update("yes", 123))
      assert_receive {:flow_done, %{name: "Alice"}}

      # Flow should be removed
      refute Engine.active_flow?(123, name)
    end

    test "flow removed after completion" do
      {pid, name} = start_engine()

      Engine.start_flow(123, TestRegistration, %{test_pid: self()}, name)
      assert_receive {:sent, _}

      send_update(pid, msg_update("Alice", 123))
      assert_receive {:sent, _}

      send_update(pid, msg_update("yes", 123))
      assert_receive {:flow_done, _}

      # Can start a new flow
      assert :ok = Engine.start_flow(123, TestRegistration, %{test_pid: self()}, name)
    end
  end

  describe "error handling" do
    test "crashing handle_input cancels the flow" do
      {pid, name} = start_engine()

      Engine.start_flow(123, CrashingFlow, %{}, name)
      assert_receive {:sent, %{text: "This will crash."}}

      send_update(pid, msg_update("trigger", 123))

      # Flow should be removed after crash
      refute Engine.active_flow?(123, name)
    end
  end
end
