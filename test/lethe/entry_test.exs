defmodule Lethe.EntryTest do
  use ExUnit.Case, async: true

  alias Lethe.Entry

  test "creates entry with required fields" do
    now = DateTime.utc_now()

    entry = %Entry{
      key: :test,
      value: "hello",
      inserted_at: now,
      last_accessed_at: now
    }

    assert entry.key == :test
    assert entry.value == "hello"
    assert entry.inserted_at == now
    assert entry.last_accessed_at == now
  end

  test "has correct defaults" do
    now = DateTime.utc_now()

    entry = %Entry{
      key: 1,
      value: "test",
      inserted_at: now,
      last_accessed_at: now
    }

    assert entry.access_count == 0
    assert entry.pinned == false
    assert entry.importance == 1.0
    assert entry.metadata == %{}
    assert entry.summary == nil
  end

  test "enforces required keys" do
    assert_raise ArgumentError, fn ->
      struct!(Entry, %{key: :test})
    end
  end
end
