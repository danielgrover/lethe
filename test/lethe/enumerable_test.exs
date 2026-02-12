defmodule Lethe.EnumerableTest do
  use ExUnit.Case, async: true

  defp new_mem_with_clock(opts \\ []) do
    base = ~U[2026-01-01 00:00:00Z]
    ref = :erlang.make_ref()
    :persistent_term.put(ref, base)

    mem =
      Lethe.new([clock_fn: fn -> :persistent_term.get(ref) end, decay_fn: :exponential] ++ opts)

    {mem, ref, base}
  end

  defp advance_clock(ref, base, seconds) do
    :persistent_term.put(ref, DateTime.add(base, seconds, :second))
  end

  defp cleanup_clock(ref), do: :persistent_term.erase(ref)

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

    cleanup_clock(ref)
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
end
