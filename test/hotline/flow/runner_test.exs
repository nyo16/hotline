defmodule Hotline.Flow.RunnerTest do
  use ExUnit.Case, async: true

  alias Hotline.Flow.Runner

  # Test flow modules

  defmodule RegistrationFlow do
    use Hotline.Flow

    step(:name, prompt: "What's your name?")
    step(:email, prompt: fn ctx -> "Thanks #{ctx.data.name}! Email?" end)
    step(:confirm, prompt: "Confirm? (yes/no)")

    @impl true
    def handle_input(:name, %{message: %{text: name}}, _ctx) when byte_size(name) >= 2 do
      {:next, store: %{name: name}}
    end

    def handle_input(:name, _, _ctx), do: {:retry, "Name must be at least 2 characters."}

    def handle_input(:email, %{message: %{text: "/skip"}}, _ctx),
      do: {:next, store: %{email: nil}}

    def handle_input(:email, %{message: %{text: email}}, _ctx) do
      {:next, store: %{email: email}}
    end

    def handle_input(:confirm, %{message: %{text: "yes"}}, _ctx), do: :done
    def handle_input(:confirm, %{message: %{text: "no"}}, _ctx), do: {:goto, :name, reset: true}
    def handle_input(:confirm, _, _ctx), do: {:retry, "Reply yes or no."}
  end

  defmodule SingleStepFlow do
    use Hotline.Flow

    step(:only, prompt: "Done?")

    @impl true
    def handle_input(:only, _, _ctx), do: :done
  end

  defmodule EmptyFlow do
    use Hotline.Flow

    @impl true
    def handle_input(_, _, _), do: :done
  end

  defmodule GotoFlow do
    use Hotline.Flow

    step(:a, prompt: "Step A")
    step(:b, prompt: "Step B")
    step(:c, prompt: "Step C")

    @impl true
    def handle_input(:a, _, _ctx), do: {:goto, :c}
    def handle_input(:b, _, _ctx), do: :next
    def handle_input(:c, _, _ctx), do: {:done, :result_value}
  end

  defmodule CancelFlow do
    use Hotline.Flow

    step(:ask, prompt: "Continue?")

    @impl true
    def handle_input(:ask, %{message: %{text: "no"}}, _ctx), do: :cancel
    def handle_input(:ask, _, _ctx), do: :done
  end

  # Helpers

  defp msg_update(text, chat_id \\ 123) do
    %{message: %{text: text, chat: %{id: chat_id}}, callback_query: nil}
  end

  # Tests

  describe "start/3" do
    test "returns context with first step and prompt effect" do
      {ctx, effects} = Runner.start(RegistrationFlow, 123)

      assert ctx.flow_module == RegistrationFlow
      assert ctx.chat_id == 123
      assert ctx.step == :name
      assert ctx.data == %{}
      assert [{:send_message, 123, "What's your name?", nil}] = effects
    end

    test "returns done effect for empty flow" do
      {_ctx, effects} = Runner.start(EmptyFlow, 123)
      assert [{:done, _}] = effects
    end

    test "passes opts through to context" do
      {ctx, _effects} = Runner.start(RegistrationFlow, 123, %{locale: "en"})
      assert ctx.opts == %{locale: "en"}
    end
  end

  describe "handle_update/2 — :next" do
    test "advances to the next step" do
      {ctx, _} = Runner.start(RegistrationFlow, 123)
      {ctx, effects} = Runner.handle_update(ctx, msg_update("Alice"))

      assert ctx.step == :email
      assert ctx.data == %{name: "Alice"}
      assert [{:send_message, 123, "Thanks Alice! Email?", nil}] = effects
    end

    test ":next on last step triggers done" do
      {ctx, _} = Runner.start(SingleStepFlow, 123)
      {_ctx, effects} = Runner.handle_update(ctx, msg_update("anything"))

      assert [{:done, _}] = effects
    end
  end

  describe "handle_update/2 — {:next, store:}" do
    test "merges data and advances" do
      {ctx, _} = Runner.start(RegistrationFlow, 123)

      # Step 1: name
      {ctx, _} = Runner.handle_update(ctx, msg_update("Alice"))
      assert ctx.data == %{name: "Alice"}

      # Step 2: email
      {ctx, _} = Runner.handle_update(ctx, msg_update("alice@test.com"))
      assert ctx.data == %{name: "Alice", email: "alice@test.com"}
      assert ctx.step == :confirm
    end
  end

  describe "handle_update/2 — {:retry, msg}" do
    test "stays on current step with error message" do
      {ctx, _} = Runner.start(RegistrationFlow, 123)
      {ctx, effects} = Runner.handle_update(ctx, msg_update("A"))

      assert ctx.step == :name
      assert ctx.data == %{}
      assert [{:send_message, 123, "Name must be at least 2 characters.", nil}] = effects
    end
  end

  describe "handle_update/2 — {:goto, step}" do
    test "jumps to named step" do
      {ctx, _} = Runner.start(GotoFlow, 123)
      {ctx, effects} = Runner.handle_update(ctx, msg_update("go"))

      assert ctx.step == :c
      assert [{:send_message, 123, "Step C", nil}] = effects
    end
  end

  describe "handle_update/2 — {:goto, step, reset: true}" do
    test "jumps and clears data" do
      {ctx, _} = Runner.start(RegistrationFlow, 123)

      # Fill in name and email
      {ctx, _} = Runner.handle_update(ctx, msg_update("Alice"))
      {ctx, _} = Runner.handle_update(ctx, msg_update("alice@test.com"))
      assert ctx.data == %{name: "Alice", email: "alice@test.com"}

      # Confirm with "no" → goto :name with reset
      {ctx, effects} = Runner.handle_update(ctx, msg_update("no"))

      assert ctx.step == :name
      assert ctx.data == %{}
      assert [{:send_message, 123, "What's your name?", nil}] = effects
    end
  end

  describe "handle_update/2 — :done" do
    test "returns done effect" do
      {ctx, _} = Runner.start(RegistrationFlow, 123)
      {ctx, _} = Runner.handle_update(ctx, msg_update("Alice"))
      {ctx, _} = Runner.handle_update(ctx, msg_update("alice@test.com"))
      {_ctx, effects} = Runner.handle_update(ctx, msg_update("yes"))

      assert [{:done, done_ctx}] = effects
      assert done_ctx.data == %{name: "Alice", email: "alice@test.com"}
    end
  end

  describe "handle_update/2 — {:done, result}" do
    test "returns done with result in data" do
      {ctx, _} = Runner.start(GotoFlow, 123)
      {ctx, _} = Runner.handle_update(ctx, msg_update("go"))
      {_ctx, effects} = Runner.handle_update(ctx, msg_update("finish"))

      assert [{:done, done_ctx}] = effects
      assert done_ctx.data.__result__ == :result_value
    end
  end

  describe "handle_update/2 — :cancel" do
    test "returns cancel effect" do
      {ctx, _} = Runner.start(CancelFlow, 123)
      {_ctx, effects} = Runner.handle_update(ctx, msg_update("no"))

      assert [{:cancel, _}] = effects
    end
  end

  describe "full flow lifecycle" do
    test "complete registration flow" do
      {ctx, effects} = Runner.start(RegistrationFlow, 123)
      assert [{:send_message, 123, "What's your name?", nil}] = effects

      # Name (retry then success)
      {ctx, effects} = Runner.handle_update(ctx, msg_update("A"))
      assert [{:send_message, 123, "Name must be at least 2 characters.", nil}] = effects
      assert ctx.step == :name

      {ctx, effects} = Runner.handle_update(ctx, msg_update("Alice"))
      assert [{:send_message, 123, "Thanks Alice! Email?", nil}] = effects
      assert ctx.step == :email

      # Email (skip)
      {ctx, effects} = Runner.handle_update(ctx, msg_update("/skip"))
      assert [{:send_message, 123, "Confirm? (yes/no)", nil}] = effects
      assert ctx.step == :confirm
      assert ctx.data == %{name: "Alice", email: nil}

      # Confirm
      {_ctx, effects} = Runner.handle_update(ctx, msg_update("yes"))
      assert [{:done, done_ctx}] = effects
      assert done_ctx.data == %{name: "Alice", email: nil}
    end
  end
end
