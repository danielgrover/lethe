defmodule LetheTest do
  use ExUnit.Case, async: true

  describe "new/0" do
    test "creates memory with default options" do
      mem = Lethe.new()

      assert mem.max_entries == 100
      assert mem.decay_fn == :combined
      assert mem.half_life == 3_600_000
      assert mem.eviction_threshold == 0.05
      assert mem.summarize_threshold == 0.15
      assert mem.summarize_fn == nil
      assert mem.clock_fn == nil
      assert mem.entries == %{}
      assert mem.next_key == 1
    end
  end

  describe "new/1" do
    test "overrides defaults" do
      mem = Lethe.new(max_entries: 50, decay_fn: :exponential, half_life: 1000)

      assert mem.max_entries == 50
      assert mem.decay_fn == :exponential
      assert mem.half_life == 1000
    end

    test "accepts clock_fn" do
      fixed = ~U[2026-01-01 00:00:00Z]
      mem = Lethe.new(clock_fn: fn -> fixed end)

      assert Lethe.now(mem) == fixed
    end

    test "raises on invalid keys" do
      assert_raise KeyError, fn ->
        Lethe.new(bogus: true)
      end
    end
  end

  defp new_mem(opts \\ []) do
    base = ~U[2026-01-01 00:00:00Z]
    clock_fn = fn -> base end
    Lethe.new([clock_fn: clock_fn] ++ opts)
  end

  describe "put/2 (auto-key)" do
    test "adds entry with auto-generated key" do
      mem = new_mem() |> Lethe.put("hello")

      assert Lethe.size(mem) == 1
      assert {:ok, entry} = Lethe.peek(mem, 1)
      assert entry.key == 1
      assert entry.value == "hello"
    end

    test "increments auto-key" do
      mem = new_mem() |> Lethe.put("a") |> Lethe.put("b")

      assert Lethe.size(mem) == 2
      assert {:ok, _} = Lethe.peek(mem, 1)
      assert {:ok, _} = Lethe.peek(mem, 2)
    end
  end

  describe "put/3 (explicit key)" do
    test "adds entry with given key" do
      mem = new_mem() |> Lethe.put(:my_key, "value")

      assert {:ok, entry} = Lethe.peek(mem, :my_key)
      assert entry.key == :my_key
      assert entry.value == "value"
    end

    test "replaces entry with same key" do
      mem = new_mem() |> Lethe.put(:k, "v1") |> Lethe.put(:k, "v2")

      assert Lethe.size(mem) == 1
      assert {:ok, entry} = Lethe.peek(mem, :k)
      assert entry.value == "v2"
    end
  end

  describe "put/4 (with opts)" do
    test "sets importance, pinned, metadata" do
      mem =
        new_mem()
        |> Lethe.put(:k, "v", importance: 1.5, pinned: true, metadata: %{source: :test})

      assert {:ok, entry} = Lethe.peek(mem, :k)
      assert entry.importance == 1.5
      assert entry.pinned == true
      assert entry.metadata == %{source: :test}
    end
  end

  describe "get/2" do
    test "returns entry and updates access metadata" do
      base = ~U[2026-01-01 00:00:00Z]
      later = DateTime.add(base, 60, :second)
      time = :erlang.make_ref()
      :persistent_term.put(time, base)
      mem = Lethe.new(clock_fn: fn -> :persistent_term.get(time) end)
      mem = Lethe.put(mem, :k, "v")

      :persistent_term.put(time, later)
      {mem, {:ok, entry}} = Lethe.get(mem, :k)

      assert entry.access_count == 1
      assert entry.last_accessed_at == later
      # Struct is updated in memory too
      assert {:ok, stored} = Lethe.peek(mem, :k)
      assert stored.access_count == 1

      :persistent_term.erase(time)
    end

    test "returns error for missing key" do
      mem = new_mem()
      {^mem, :error} = Lethe.get(mem, :missing)
    end
  end

  describe "peek/2" do
    test "returns entry without modifying access metadata" do
      mem = new_mem() |> Lethe.put(:k, "v")

      assert {:ok, entry} = Lethe.peek(mem, :k)
      assert entry.access_count == 0
    end

    test "returns error for missing key" do
      assert :error = Lethe.peek(new_mem(), :missing)
    end
  end

  describe "delete/2" do
    test "removes entry" do
      mem = new_mem() |> Lethe.put(:k, "v") |> Lethe.delete(:k)
      assert Lethe.size(mem) == 0
    end

    test "no-op for missing key" do
      mem = new_mem()
      assert Lethe.delete(mem, :missing) == mem
    end
  end

  describe "clear/1" do
    test "empties entries and resets next_key" do
      mem = new_mem() |> Lethe.put("a") |> Lethe.put("b") |> Lethe.clear()

      assert Lethe.size(mem) == 0
      assert mem.next_key == 1
      # config preserved
      assert mem.max_entries == 100
    end
  end

  describe "size/1" do
    test "returns 0 for empty" do
      assert Lethe.size(new_mem()) == 0
    end

    test "reflects entry count" do
      mem = new_mem() |> Lethe.put("a") |> Lethe.put("b") |> Lethe.put("c")
      assert Lethe.size(mem) == 3
    end
  end

  # Helper for scoring tests: creates mem with mutable clock
  defp new_mem_with_clock do
    base = ~U[2026-01-01 00:00:00Z]
    ref = :erlang.make_ref()
    :persistent_term.put(ref, base)
    mem = Lethe.new(clock_fn: fn -> :persistent_term.get(ref) end, decay_fn: :exponential)
    {mem, ref, base}
  end

  defp advance_clock(ref, base, seconds) do
    :persistent_term.put(ref, DateTime.add(base, seconds, :second))
  end

  defp cleanup_clock(ref), do: :persistent_term.erase(ref)

  describe "score/2" do
    test "returns score for existing key" do
      mem = new_mem(decay_fn: :exponential) |> Lethe.put(:k, "v")
      score = Lethe.score(mem, :k)
      assert is_float(score)
      assert_in_delta score, 1.0, 0.01
    end

    test "returns :error for missing key" do
      assert Lethe.score(new_mem(), :missing) == :error
    end
  end

  describe "scored/1" do
    test "returns sorted tuples" do
      {mem, ref, base} = new_mem_with_clock()
      mem = Lethe.put(mem, :old, "old")
      advance_clock(ref, base, 1800)
      mem = Lethe.put(mem, :new, "new")

      scored = Lethe.scored(mem)
      assert length(scored) == 2
      [{first, s1}, {second, s2}] = scored
      assert first.key == :new
      assert second.key == :old
      assert s1 >= s2

      cleanup_clock(ref)
    end

    test "empty returns []" do
      assert Lethe.scored(new_mem()) == []
    end
  end

  describe "score_map/1" do
    test "returns key => score map" do
      mem = new_mem(decay_fn: :exponential) |> Lethe.put(:a, "1") |> Lethe.put(:b, "2")
      map = Lethe.score_map(mem)

      assert is_map(map)
      assert Map.has_key?(map, :a)
      assert Map.has_key?(map, :b)
      assert is_float(map[:a])
    end
  end

  describe "active/1" do
    test "excludes low-score entries" do
      {mem, ref, base} = new_mem_with_clock()
      mem = Lethe.put(mem, :old, "old")
      # advance far past half-life so :old decays below threshold
      advance_clock(ref, base, 86_400)
      mem = Lethe.put(mem, :new, "new")

      active = Lethe.active(mem)
      keys = Enum.map(active, & &1.key)
      assert :new in keys
      refute :old in keys

      cleanup_clock(ref)
    end
  end

  describe "above/2" do
    test "filters by custom threshold" do
      {mem, ref, base} = new_mem_with_clock()
      mem = Lethe.put(mem, :old, "old")
      advance_clock(ref, base, 3600)
      mem = Lethe.put(mem, :new, "new")

      above_07 = Lethe.above(mem, 0.7)
      keys = Enum.map(above_07, & &1.key)
      assert :new in keys
      refute :old in keys

      cleanup_clock(ref)
    end
  end

  describe "top/2" do
    test "returns at most N entries" do
      mem = new_mem() |> Lethe.put(:a, "1") |> Lethe.put(:b, "2") |> Lethe.put(:c, "3")
      assert length(Lethe.top(mem, 2)) == 2
    end

    test "handles N > size" do
      mem = new_mem() |> Lethe.put(:a, "1")
      assert length(Lethe.top(mem, 10)) == 1
    end
  end

  describe "active_count/1" do
    test "counts entries above eviction threshold" do
      {mem, ref, base} = new_mem_with_clock()
      mem = Lethe.put(mem, :old, "old")
      advance_clock(ref, base, 86_400)
      mem = Lethe.put(mem, :new, "new")

      assert Lethe.active_count(mem) == 1

      cleanup_clock(ref)
    end
  end

  describe "pinned_count/1" do
    test "counts pinned entries" do
      mem =
        new_mem()
        |> Lethe.put(:a, "1", pinned: true)
        |> Lethe.put(:b, "2")
        |> Lethe.put(:c, "3", pinned: true)

      assert Lethe.pinned_count(mem) == 2
    end
  end

  describe "filter/2" do
    test "filters by predicate" do
      mem =
        new_mem()
        |> Lethe.put(:a, "1", metadata: %{source: :test})
        |> Lethe.put(:b, "2", metadata: %{source: :other})
        |> Lethe.put(:c, "3", metadata: %{source: :test})

      result = Lethe.filter(mem, fn entry -> entry.metadata[:source] == :test end)
      keys = Enum.map(result, & &1.key) |> Enum.sort()
      assert keys == [:a, :c]
    end
  end

  describe "stats/1" do
    test "returns nil values for empty memory" do
      stats = Lethe.stats(new_mem())

      assert stats.size == 0
      assert stats.active == 0
      assert stats.pinned == 0
      assert stats.oldest_entry == nil
      assert stats.newest_entry == nil
      assert stats.mean_score == nil
      assert stats.median_score == nil
    end

    test "returns correct stats for populated memory" do
      {mem, ref, base} = new_mem_with_clock()
      mem = Lethe.put(mem, :a, "1", pinned: true)
      advance_clock(ref, base, 60)
      mem = Lethe.put(mem, :b, "2")

      stats = Lethe.stats(mem)
      assert stats.size == 2
      assert stats.pinned == 1
      assert stats.oldest_entry == base
      assert stats.newest_entry == DateTime.add(base, 60, :second)
      assert is_float(stats.mean_score)
      assert is_float(stats.median_score)

      cleanup_clock(ref)
    end
  end

  describe "eviction on put" do
    test "evicts lowest-scored unpinned entry when at capacity" do
      {mem, ref, base} = new_mem_with_clock()
      mem = %{mem | max_entries: 3}

      mem = Lethe.put(mem, :a, "first")
      advance_clock(ref, base, 1800)
      mem = Lethe.put(mem, :b, "second")
      advance_clock(ref, base, 3600)
      mem = Lethe.put(mem, :c, "third")

      # At capacity. :a is oldest/lowest-scored
      advance_clock(ref, base, 3601)
      mem = Lethe.put(mem, :d, "fourth")

      assert Lethe.size(mem) == 3
      assert :error = Lethe.peek(mem, :a)
      assert {:ok, _} = Lethe.peek(mem, :b)
      assert {:ok, _} = Lethe.peek(mem, :c)
      assert {:ok, _} = Lethe.peek(mem, :d)

      cleanup_clock(ref)
    end

    test "all pinned at capacity is no-op" do
      mem = new_mem(max_entries: 2)
      mem = Lethe.put(mem, :a, "1", pinned: true)
      mem = Lethe.put(mem, :b, "2", pinned: true)
      mem = Lethe.put(mem, :c, "3")

      assert Lethe.size(mem) == 2
      assert :error = Lethe.peek(mem, :c)
    end

    test "pinned entries are never auto-evicted" do
      {mem, ref, base} = new_mem_with_clock()
      mem = %{mem | max_entries: 2}

      mem = Lethe.put(mem, :pinned, "important", pinned: true)
      advance_clock(ref, base, 7200)
      mem = Lethe.put(mem, :recent, "new")
      advance_clock(ref, base, 7201)
      mem = Lethe.put(mem, :newest, "newest")

      assert Lethe.size(mem) == 2
      assert {:ok, _} = Lethe.peek(mem, :pinned)
      assert {:ok, _} = Lethe.peek(mem, :newest)
      assert :error = Lethe.peek(mem, :recent)

      cleanup_clock(ref)
    end

    test "size never exceeds max_entries" do
      {mem, ref, base} = new_mem_with_clock()
      mem = %{mem | max_entries: 5}

      for i <- 1..20, reduce: mem do
        mem ->
          advance_clock(ref, base, i * 60)
          Lethe.put(mem, :"key_#{i}", "val_#{i}")
      end
      |> then(fn mem -> assert Lethe.size(mem) <= 5 end)

      cleanup_clock(ref)
    end
  end

  describe "evict/1" do
    test "removes entries below threshold" do
      {mem, ref, base} = new_mem_with_clock()
      mem = Lethe.put(mem, :old, "old")
      advance_clock(ref, base, 86_400)
      mem = Lethe.put(mem, :new, "new")

      {mem, evicted} = Lethe.evict(mem)

      assert length(evicted) == 1
      assert hd(evicted).key == :old
      assert Lethe.size(mem) == 1

      cleanup_clock(ref)
    end

    test "keeps pinned entries regardless of score" do
      {mem, ref, base} = new_mem_with_clock()
      mem = Lethe.put(mem, :pinned, "important", pinned: true)
      advance_clock(ref, base, 86_400)

      {mem, evicted} = Lethe.evict(mem)

      assert evicted == []
      assert Lethe.size(mem) == 1

      cleanup_clock(ref)
    end
  end
end
