defmodule Lethe.UpdateTest do
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

  describe "update/3" do
    test "changes value and refreshes access time" do
      {mem, ref, base} = new_mem_with_clock()
      mem = Lethe.put(mem, :k, "old")
      advance_clock(ref, base, 60)

      mem = Lethe.update(mem, :k, "new")
      {:ok, entry} = Lethe.peek(mem, :k)

      assert entry.value == "new"
      assert entry.access_count == 1
      assert entry.last_accessed_at == DateTime.add(base, 60, :second)

      cleanup_clock(ref)
    end

    test "preserves metadata, pinned, importance" do
      {mem, _ref, _base} = new_mem_with_clock()
      mem = Lethe.put(mem, :k, "v", importance: 1.5, pinned: true, metadata: %{source: :test})
      mem = Lethe.update(mem, :k, "new_v")

      {:ok, entry} = Lethe.peek(mem, :k)
      assert entry.importance == 1.5
      assert entry.pinned == true
      assert entry.metadata == %{source: :test}
    end

    test "no-op for missing key" do
      {mem, _ref, _base} = new_mem_with_clock()
      assert Lethe.update(mem, :missing, "val") == mem
    end
  end

  describe "touch/2" do
    test "refreshes access and increments access_count" do
      {mem, ref, base} = new_mem_with_clock()
      mem = Lethe.put(mem, :k, "value")
      advance_clock(ref, base, 60)

      mem = Lethe.touch(mem, :k)
      {:ok, entry} = Lethe.peek(mem, :k)

      assert entry.access_count == 1
      assert entry.last_accessed_at == DateTime.add(base, 60, :second)
      assert entry.value == "value"

      cleanup_clock(ref)
    end

    test "no-op for missing key" do
      {mem, _ref, _base} = new_mem_with_clock()
      assert Lethe.touch(mem, :missing) == mem
    end
  end

  describe "touch/3" do
    test "updates importance" do
      {mem, _ref, _base} = new_mem_with_clock()
      mem = Lethe.put(mem, :k, "value", importance: 1.0)
      mem = Lethe.touch(mem, :k, importance: 1.8)

      {:ok, entry} = Lethe.peek(mem, :k)
      assert entry.importance == 1.8
    end

    test "no-op for missing key" do
      {mem, _ref, _base} = new_mem_with_clock()
      assert Lethe.touch(mem, :missing, importance: 2.0) == mem
    end
  end

  describe "touch improves decay score" do
    test "after touch, score is higher than before" do
      {mem, ref, base} = new_mem_with_clock()
      mem = Lethe.put(mem, :k, "value")
      advance_clock(ref, base, 3600)

      score_before = Lethe.score(mem, :k)
      mem = Lethe.touch(mem, :k)
      score_after = Lethe.score(mem, :k)

      assert score_after > score_before

      cleanup_clock(ref)
    end
  end
end
