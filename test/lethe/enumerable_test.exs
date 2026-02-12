defmodule Lethe.EnumerableTest do
  use ExUnit.Case, async: true
  import Lethe.TestHelpers

  test "Enum.count/1" do
    mem =
      Lethe.new()
      |> Lethe.put(:a, "1")
      |> Lethe.put(:b, "2")

    assert Enum.count(mem) == 2
  end

  test "Enum.to_list/1 returns entries sorted by score desc" do
    {mem, ref, base} = new_mem_with_clock()
    mem = Lethe.put(mem, :old, "old")
    advance_clock(ref, base, 1800)
    mem = Lethe.put(mem, :new, "new")

    entries = Enum.to_list(mem)
    assert length(entries) == 2
    assert hd(entries).key == :new
    assert List.last(entries).key == :old
  end

  test "Enum.take/2" do
    mem =
      Lethe.new()
      |> Lethe.put(:a, "1")
      |> Lethe.put(:b, "2")
      |> Lethe.put(:c, "3")

    assert length(Enum.take(mem, 2)) == 2
  end

  test "Enum.map/2" do
    mem =
      Lethe.new()
      |> Lethe.put(:a, "1")
      |> Lethe.put(:b, "2")

    values = Enum.map(mem, & &1.value)
    assert Enum.sort(values) == ["1", "2"]
  end

  test "Enum.member?/2" do
    mem = Lethe.new() |> Lethe.put(:a, "1")
    {:ok, entry} = Lethe.peek(mem, :a)

    assert Enum.member?(mem, entry)

    refute Enum.member?(mem, %Lethe.Entry{
             key: :missing,
             value: "x",
             inserted_at: DateTime.utc_now(),
             last_accessed_at: DateTime.utc_now()
           })
  end

  test "Enum.member?/2 checks value equality, not just key" do
    mem = Lethe.new() |> Lethe.put(:a, "original")
    {:ok, entry} = Lethe.peek(mem, :a)

    assert Enum.member?(mem, entry)
    refute Enum.member?(mem, %{entry | value: "modified"})
  end

  test "Enum.member?/2 returns false for non-Entry values" do
    mem = Lethe.new() |> Lethe.put(:a, "1")

    refute Enum.member?(mem, "not an entry")
    refute Enum.member?(mem, 42)
    refute Enum.member?(mem, :a)
  end

  test "Enum.slice/2 works" do
    mem =
      Lethe.new()
      |> Lethe.put(:a, "1")
      |> Lethe.put(:b, "2")
      |> Lethe.put(:c, "3")

    assert length(Enum.slice(mem, 0..1)) == 2
  end

  test "empty mem enumerates to []" do
    assert Enum.to_list(Lethe.new()) == []
  end

  test "for comprehension works" do
    mem =
      Lethe.new()
      |> Lethe.put(:a, "1")
      |> Lethe.put(:b, "2")

    values = for entry <- mem, do: entry.value
    assert Enum.sort(values) == ["1", "2"]
  end

  test "for comprehension with filter" do
    mem =
      Lethe.new()
      |> Lethe.put(:a, "1", pinned: true)
      |> Lethe.put(:b, "2")
      |> Lethe.put(:c, "3", pinned: true)

    keys = for entry <- mem, entry.pinned, do: entry.key
    assert Enum.sort(keys) == [:a, :c]
  end
end
