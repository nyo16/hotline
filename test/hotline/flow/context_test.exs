defmodule Hotline.Flow.ContextTest do
  use ExUnit.Case, async: true

  alias Hotline.Flow.Context

  describe "new/3" do
    test "creates context with defaults" do
      ctx = Context.new(SomeFlow, 123)

      assert ctx.flow_module == SomeFlow
      assert ctx.chat_id == 123
      assert ctx.step == nil
      assert ctx.data == %{}
      assert ctx.opts == %{}
    end

    test "accepts opts" do
      ctx = Context.new(SomeFlow, 123, %{token: "abc"})
      assert ctx.opts == %{token: "abc"}
    end
  end

  describe "store/2" do
    test "merges data into context" do
      ctx = Context.new(SomeFlow, 123)
      ctx = Context.store(ctx, %{name: "Alice"})

      assert ctx.data == %{name: "Alice"}
    end

    test "merges incrementally" do
      ctx =
        Context.new(SomeFlow, 123)
        |> Context.store(%{name: "Alice"})
        |> Context.store(%{email: "alice@test.com"})

      assert ctx.data == %{name: "Alice", email: "alice@test.com"}
    end

    test "overwrites existing keys" do
      ctx =
        Context.new(SomeFlow, 123)
        |> Context.store(%{name: "Alice"})
        |> Context.store(%{name: "Bob"})

      assert ctx.data == %{name: "Bob"}
    end
  end

  describe "move_to/2" do
    test "sets the step" do
      ctx = Context.new(SomeFlow, 123)
      ctx = Context.move_to(ctx, :email)

      assert ctx.step == :email
    end

    test "does not affect other fields" do
      ctx =
        Context.new(SomeFlow, 123)
        |> Context.store(%{name: "Alice"})
        |> Context.move_to(:confirm)

      assert ctx.data == %{name: "Alice"}
      assert ctx.chat_id == 123
    end
  end
end
