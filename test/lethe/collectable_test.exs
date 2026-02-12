defmodule Lethe.CollectableTest do
  use ExUnit.Case, async: true

  test "Enum.into/2 with {key, value} tuples" do
    mem = Enum.into([{:a, "1"}, {:b, "2"}], Lethe.new())

    assert Lethe.size(mem) == 2
    assert {:ok, entry} = Lethe.peek(mem, :a)
    assert entry.value == "1"
  end

  test "Enum.into/2 with {key, value, opts} triples" do
    mem = Enum.into([{:a, "1", [pinned: true]}], Lethe.new())

    assert {:ok, entry} = Lethe.peek(mem, :a)
    assert entry.pinned == true
  end

  test "for comprehension with into" do
    mem =
      for i <- 1..3, into: Lethe.new() do
        {:"key_#{i}", "val_#{i}"}
      end

    assert Lethe.size(mem) == 3
  end

  test "halt during collection returns :ok" do
    {acc, collector} = Collectable.into(Lethe.new())
    acc = collector.(acc, {:cont, {:a, "1"}})
    result = collector.(acc, :halt)

    assert result == :ok
  end
end
