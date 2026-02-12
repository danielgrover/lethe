defmodule Lethe.PinningTest do
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

  describe "pin/2" do
    test "sets pinned flag" do
      {mem, _ref, _base} = new_mem_with_clock()
      mem = Lethe.put(mem, :k, "value")
      mem = Lethe.pin(mem, :k)

      {:ok, entry} = Lethe.peek(mem, :k)
      assert entry.pinned == true
    end

    test "no-op for missing key" do
      {mem, _ref, _base} = new_mem_with_clock()
      assert Lethe.pin(mem, :missing) == mem
    end
  end

  describe "unpin/2" do
    test "clears pinned flag" do
      {mem, _ref, _base} = new_mem_with_clock()
      mem = Lethe.put(mem, :k, "value", pinned: true)
      mem = Lethe.unpin(mem, :k)

      {:ok, entry} = Lethe.peek(mem, :k)
      assert entry.pinned == false
    end

    test "no-op for missing key" do
      {mem, _ref, _base} = new_mem_with_clock()
      assert Lethe.unpin(mem, :missing) == mem
    end
  end

  describe "pinned entry behavior" do
    test "scores 1.0 regardless of age" do
      {mem, ref, base} = new_mem_with_clock()
      mem = Lethe.put(mem, :k, "value", pinned: true)
      advance_clock(ref, base, 86_400)

      assert Lethe.score(mem, :k) == 1.0

      cleanup_clock(ref)
    end

    test "not evicted by evict/1" do
      {mem, ref, base} = new_mem_with_clock()
      mem = Lethe.put(mem, :k, "value", pinned: true)
      advance_clock(ref, base, 86_400)

      {mem, evicted} = Lethe.evict(mem)
      assert evicted == []
      assert Lethe.size(mem) == 1

      cleanup_clock(ref)
    end

    test "not auto-evicted on put at capacity" do
      {mem, ref, base} = new_mem_with_clock(max_entries: 2)
      mem = Lethe.put(mem, :a, "1", pinned: true)
      advance_clock(ref, base, 7200)
      mem = Lethe.put(mem, :b, "2")
      advance_clock(ref, base, 7201)
      mem = Lethe.put(mem, :c, "3")

      # :b should be evicted (unpinned, lower score), not :a
      assert Lethe.size(mem) == 2
      assert {:ok, _} = Lethe.peek(mem, :a)
      assert {:ok, _} = Lethe.peek(mem, :c)

      cleanup_clock(ref)
    end

    test "unpin allows entry to decay normally" do
      {mem, ref, base} = new_mem_with_clock()
      mem = Lethe.put(mem, :k, "value", pinned: true)
      advance_clock(ref, base, 86_400)

      assert Lethe.score(mem, :k) == 1.0

      mem = Lethe.unpin(mem, :k)
      score = Lethe.score(mem, :k)
      assert score < 0.01

      cleanup_clock(ref)
    end
  end

  describe "pinned_count/1" do
    test "correct after pin/unpin" do
      {mem, _ref, _base} = new_mem_with_clock()
      mem = Lethe.put(mem, :a, "1")
      mem = Lethe.put(mem, :b, "2")

      assert Lethe.pinned_count(mem) == 0

      mem = Lethe.pin(mem, :a)
      assert Lethe.pinned_count(mem) == 1

      mem = Lethe.pin(mem, :b)
      assert Lethe.pinned_count(mem) == 2

      mem = Lethe.unpin(mem, :a)
      assert Lethe.pinned_count(mem) == 1
    end
  end

  describe "put with pinned: true" do
    test "entry is pinned from creation" do
      {mem, _ref, _base} = new_mem_with_clock()
      mem = Lethe.put(mem, :k, "value", pinned: true)

      {:ok, entry} = Lethe.peek(mem, :k)
      assert entry.pinned == true
      assert Lethe.pinned_count(mem) == 1
    end
  end
end
