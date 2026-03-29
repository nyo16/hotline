defmodule Hotline.FlowTest do
  use ExUnit.Case, async: true

  defmodule StringPromptFlow do
    use Hotline.Flow

    step(:name, prompt: "What's your name?")
    step(:email, prompt: "What's your email?")

    @impl true
    def handle_input(:name, _update, _ctx), do: :next
    def handle_input(:email, _update, _ctx), do: :done
  end

  defmodule FunctionPromptFlow do
    use Hotline.Flow

    step(:greet, prompt: fn ctx -> "Hello #{ctx.data[:name] || "stranger"}!" end)
    step(:done_step, prompt: fn _ctx -> "All done." end)

    @impl true
    def handle_input(:greet, _update, _ctx), do: {:next, store: %{name: "Alice"}}
    def handle_input(:done_step, _update, _ctx), do: :done
  end

  defmodule KeyboardFlow do
    use Hotline.Flow

    step(:choice,
      prompt: "Pick one:",
      keyboard: [[%{text: "A", callback_data: "a"}, %{text: "B", callback_data: "b"}]]
    )

    step(:no_keyboard, prompt: "Thanks!")

    @impl true
    def handle_input(:choice, _update, _ctx), do: :next
    def handle_input(:no_keyboard, _update, _ctx), do: :done
  end

  defmodule NoPromptFlow do
    use Hotline.Flow

    step(:silent)
    step(:with_prompt, prompt: "Now talk.")

    @impl true
    def handle_input(:silent, _update, _ctx), do: :next
    def handle_input(:with_prompt, _update, _ctx), do: :done
  end

  defmodule CallbackFlow do
    use Hotline.Flow

    step(:ask, prompt: "Go?")

    @impl true
    def handle_input(:ask, _update, _ctx), do: :done

    @impl true
    def on_done(ctx), do: {:completed, ctx.data}
    @impl true
    def on_cancel(_ctx), do: :cancelled
  end

  describe "__steps__/0" do
    test "returns steps in declaration order" do
      assert StringPromptFlow.__steps__() == [:name, :email]
      assert FunctionPromptFlow.__steps__() == [:greet, :done_step]
      assert KeyboardFlow.__steps__() == [:choice, :no_keyboard]
    end
  end

  describe "__prompt__/2" do
    test "returns static string prompts" do
      ctx = %Hotline.Flow.Context{data: %{}}
      assert StringPromptFlow.__prompt__(:name, ctx) == "What's your name?"
      assert StringPromptFlow.__prompt__(:email, ctx) == "What's your email?"
    end

    test "calls function prompts with context" do
      ctx = %Hotline.Flow.Context{data: %{name: "Alice"}}
      assert FunctionPromptFlow.__prompt__(:greet, ctx) == "Hello Alice!"
    end

    test "returns nil for unknown steps" do
      ctx = %Hotline.Flow.Context{data: %{}}
      assert StringPromptFlow.__prompt__(:unknown, ctx) == nil
    end

    test "returns nil for steps without prompts" do
      ctx = %Hotline.Flow.Context{data: %{}}
      assert NoPromptFlow.__prompt__(:silent, ctx) == nil
      assert NoPromptFlow.__prompt__(:with_prompt, ctx) == "Now talk."
    end
  end

  describe "__keyboard__/2" do
    test "returns keyboard when defined" do
      ctx = %Hotline.Flow.Context{data: %{}}
      keyboard = KeyboardFlow.__keyboard__(:choice, ctx)
      assert [[%{text: "A", callback_data: "a"}, %{text: "B", callback_data: "b"}]] = keyboard
    end

    test "returns nil when no keyboard" do
      ctx = %Hotline.Flow.Context{data: %{}}
      assert KeyboardFlow.__keyboard__(:no_keyboard, ctx) == nil
      assert StringPromptFlow.__keyboard__(:name, ctx) == nil
    end
  end

  describe "optional callbacks" do
    test "on_done is overridable" do
      ctx = %Hotline.Flow.Context{data: %{name: "Alice"}}
      assert {:completed, %{name: "Alice"}} = CallbackFlow.on_done(ctx)
    end

    test "on_cancel is overridable" do
      ctx = %Hotline.Flow.Context{data: %{}}
      assert :cancelled = CallbackFlow.on_cancel(ctx)
    end

    test "defaults return :ok" do
      ctx = %Hotline.Flow.Context{data: %{}}
      assert StringPromptFlow.on_done(ctx) == :ok
      assert StringPromptFlow.on_cancel(ctx) == :ok
    end
  end
end
