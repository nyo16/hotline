defmodule Hotline.ErrorTest do
  use ExUnit.Case, async: true

  alias Hotline.Error

  describe "message/1" do
    test "formats API error with code" do
      error = Error.api(400, "Bad Request")
      assert Exception.message(error) == "[api] 400: Bad Request"
    end

    test "formats transport error without code" do
      error = Error.transport("connection refused")
      assert Exception.message(error) == "[transport] connection refused"
    end
  end

  describe "retry_after/1" do
    test "extracts retry_after from parameters" do
      error = Error.api(429, "Too Many Requests", %{"retry_after" => 30})
      assert Error.retry_after(error) == 30
    end

    test "returns nil when no retry_after" do
      error = Error.api(400, "Bad Request")
      assert Error.retry_after(error) == nil
    end

    test "returns nil when parameters is nil" do
      error = Error.api(400, "Bad Request", nil)
      assert Error.retry_after(error) == nil
    end
  end

  describe "api/3" do
    test "builds API error struct" do
      error = Error.api(403, "Forbidden", %{"retry_after" => 10})

      assert %Error{
               type: :api,
               code: 403,
               message: "Forbidden",
               parameters: %{"retry_after" => 10}
             } = error
    end
  end

  describe "transport/1" do
    test "builds transport error struct" do
      error = Error.transport("timeout")

      assert %Error{
               type: :transport,
               code: nil,
               message: "timeout"
             } = error
    end
  end

  test "is a proper exception" do
    error = Error.api(500, "Internal Server Error")
    assert is_exception(error)

    assert_raise Error, "[api] 500: Internal Server Error", fn ->
      raise error
    end
  end
end
