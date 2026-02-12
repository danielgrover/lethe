defmodule LetheTest do
  use ExUnit.Case, async: true
  import Lethe.TestHelpers

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
      mem = Lethe.put(mem, :k, "v")

      {:ok, entry} = Lethe.peek(mem, :k)
      assert entry.inserted_at == fixed
    end

    test "raises on invalid keys" do
      assert_raise KeyError, fn ->
        Lethe.new(bogus: true)
      end
    end

    test "raises on non-positive max_entries" do
      assert_raise ArgumentError, fn -> Lethe.new(max_entries: 0) end
      assert_raise ArgumentError, fn -> Lethe.new(max_entries: -1) end
    end

    test "raises on non-positive half_life" do
      assert_raise ArgumentError, fn -> Lethe.new(half_life: 0) end
      assert_raise ArgumentError, fn -> Lethe.new(half_life: -100) end
    end

    test "raises on invalid decay_fn" do
      assert_raise ArgumentError, fn -> Lethe.new(decay_fn: :bogus) end
    end

    test "accepts custom decay function" do
      custom_fn = fn _entry, _now, _opts -> 0.42 end
      mem = Lethe.new(decay_fn: custom_fn)
      mem = Lethe.put(mem, :k, "value")
      assert_in_delta Lethe.score(mem, :k), 0.42, 0.001
    end

    test "rejects wrong-arity decay function" do
      assert_raise ArgumentError, fn -> Lethe.new(decay_fn: fn -> 0.5 end) end
      assert_raise ArgumentError, fn -> Lethe.new(decay_fn: fn _a, _b -> 0.5 end) end
    end

    test "raises when summarize_threshold < eviction_threshold" do
      assert_raise ArgumentError, fn ->
        Lethe.new(summarize_threshold: 0.01, eviction_threshold: 0.1)
      end
    end

    test "raises on out-of-range eviction_threshold" do
      assert_raise ArgumentError, fn -> Lethe.new(eviction_threshold: -0.1) end
      assert_raise ArgumentError, fn -> Lethe.new(eviction_threshold: 1.5) end
    end
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

    test "replace at capacity does not evict" do
      mem = new_mem(max_entries: 2) |> Lethe.put(:a, "1") |> Lethe.put(:b, "2")
      mem = Lethe.put(mem, :a, "updated")

      assert Lethe.size(mem) == 2
      assert {:ok, entry} = Lethe.peek(mem, :a)
      assert entry.value == "updated"
      assert {:ok, _} = Lethe.peek(mem, :b)
    end

    test "auto-key advances when explicit key matches next_key" do
      mem = new_mem() |> Lethe.put("first")
      # auto-key 1 used, next_key is now 2
      mem = Lethe.put(mem, 2, "explicit at 2")
      # explicit key 2 == next_key, so next_key advances to 3
      mem = Lethe.put(mem, "third")

      assert Lethe.size(mem) == 3
      assert {:ok, _} = Lethe.peek(mem, 1)
      assert {:ok, _} = Lethe.peek(mem, 2)
      assert {:ok, entry} = Lethe.peek(mem, 3)
      assert entry.value == "third"
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

    test "raises on unknown option keys" do
      assert_raise ArgumentError, ~r/unknown option/, fn ->
        new_mem() |> Lethe.put(:k, "v", bogus: true)
      end
    end
  end

  describe "get/2" do
    test "returns entry and updates access metadata" do
      {mem, ref, base} = new_mem_with_clock()
      mem = Lethe.put(mem, :k, "v")
      later = DateTime.add(base, 60, :second)
      advance_clock(ref, base, 60)

      {{:ok, entry}, mem} = Lethe.get(mem, :k)

      assert entry.access_count == 1
      assert entry.last_accessed_at == later
      # Struct is updated in memory too
      assert {:ok, stored} = Lethe.peek(mem, :k)
      assert stored.access_count == 1
    end

    test "returns error for missing key" do
      mem = new_mem()
      {:error, ^mem} = Lethe.get(mem, :missing)
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

    test "preserves function options" do
      clock_fn = fn -> ~U[2026-01-01 00:00:00Z] end
      summarize_fn = fn entry -> "summary: #{entry.value}" end

      mem =
        Lethe.new(clock_fn: clock_fn, summarize_fn: summarize_fn)
        |> Lethe.put(:k, "v")
        |> Lethe.clear()

      assert mem.clock_fn == clock_fn
      assert mem.summarize_fn == summarize_fn
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

  describe "keys/1" do
    test "returns all keys" do
      mem = new_mem() |> Lethe.put(:a, "1") |> Lethe.put(:b, "2")
      assert Enum.sort(Lethe.keys(mem)) == [:a, :b]
    end

    test "returns [] for empty" do
      assert Lethe.keys(new_mem()) == []
    end
  end

  describe "has_key?/2" do
    test "returns true for existing key" do
      mem = new_mem() |> Lethe.put(:a, "1")
      assert Lethe.has_key?(mem, :a)
    end

    test "returns false for missing key" do
      refute Lethe.has_key?(new_mem(), :missing)
    end
  end

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

    test "returns empty map for empty memory" do
      assert Lethe.score_map(new_mem()) == %{}
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
    end

    test "returns [] for empty memory" do
      assert Lethe.active(new_mem()) == []
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
    end

    test "threshold 0.0 returns all entries" do
      mem = new_mem() |> Lethe.put(:a, "1") |> Lethe.put(:b, "2")
      assert length(Lethe.above(mem, 0.0)) == 2
    end

    test "returns entries sorted by score descending" do
      {mem, ref, base} = new_mem_with_clock()
      mem = Lethe.put(mem, :old, "old")
      advance_clock(ref, base, 1800)
      mem = Lethe.put(mem, :new, "new")

      result = Lethe.above(mem, 0.0)
      assert hd(result).key == :new
      assert List.last(result).key == :old
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

    test "N = 0 returns empty list" do
      mem = new_mem() |> Lethe.put(:a, "1")
      assert Lethe.top(mem, 0) == []
    end

    test "returns entries sorted by score descending" do
      {mem, ref, base} = new_mem_with_clock()
      mem = Lethe.put(mem, :old, "old")
      advance_clock(ref, base, 1800)
      mem = Lethe.put(mem, :new, "new")

      top = Lethe.top(mem, 2)
      assert hd(top).key == :new
      assert List.last(top).key == :old
    end
  end

  describe "active_count/1" do
    test "counts entries above eviction threshold" do
      {mem, ref, base} = new_mem_with_clock()
      mem = Lethe.put(mem, :old, "old")
      advance_clock(ref, base, 86_400)
      mem = Lethe.put(mem, :new, "new")

      assert Lethe.active_count(mem) == 1
    end

    test "returns 0 for empty memory" do
      assert Lethe.active_count(new_mem()) == 0
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

    test "returns 0 for empty memory" do
      assert Lethe.pinned_count(new_mem()) == 0
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

    test "returns [] when no matches" do
      mem = new_mem() |> Lethe.put(:a, "1")
      assert Lethe.filter(mem, fn _ -> false end) == []
    end

    test "returns [] for empty memory" do
      assert Lethe.filter(new_mem(), fn _ -> true end) == []
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
    end

    test "median with odd number of entries" do
      mem =
        new_mem()
        |> Lethe.put(:a, "1")
        |> Lethe.put(:b, "2")
        |> Lethe.put(:c, "3")

      stats = Lethe.stats(mem)
      assert stats.size == 3
      assert is_float(stats.median_score)
    end

    test "single entry stats" do
      mem = new_mem() |> Lethe.put(:a, "1")

      stats = Lethe.stats(mem)
      assert stats.size == 1
      assert stats.active == 1
      assert stats.pinned == 0
      assert stats.oldest_entry == stats.newest_entry
      assert stats.mean_score == stats.median_score
    end
  end

  describe "clock_fn consistency" do
    defp counting_clock do
      counter = :counters.new(1, [:atomics])
      base = ~U[2026-01-01 00:00:00Z]

      clock_fn = fn ->
        :counters.add(counter, 1, 1)
        base
      end

      {clock_fn, counter}
    end

    test "scored/1 calls clock_fn exactly once" do
      {clock_fn, counter} = counting_clock()
      mem = Lethe.new(clock_fn: clock_fn) |> Lethe.put(:a, "1") |> Lethe.put(:b, "2")

      before = :counters.get(counter, 1)
      _scored = Lethe.scored(mem)

      assert :counters.get(counter, 1) - before == 1
    end

    test "stats/1 calls clock_fn exactly once" do
      {clock_fn, counter} = counting_clock()
      mem = Lethe.new(clock_fn: clock_fn) |> Lethe.put(:a, "1") |> Lethe.put(:b, "2")

      before = :counters.get(counter, 1)
      _stats = Lethe.stats(mem)

      assert :counters.get(counter, 1) - before == 1
    end

    test "evict/1 calls clock_fn exactly once" do
      {clock_fn, counter} = counting_clock()
      mem = Lethe.new(clock_fn: clock_fn) |> Lethe.put(:a, "1") |> Lethe.put(:b, "2")

      before = :counters.get(counter, 1)
      _result = Lethe.evict(mem)

      assert :counters.get(counter, 1) - before == 1
    end
  end

  describe "eviction on put" do
    test "evicts lowest-scored unpinned entry when at capacity" do
      {mem, ref, base} = new_mem_with_clock(max_entries: 3)

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
      {mem, ref, base} = new_mem_with_clock(max_entries: 2)

      mem = Lethe.put(mem, :pinned, "important", pinned: true)
      advance_clock(ref, base, 7200)
      mem = Lethe.put(mem, :recent, "new")
      advance_clock(ref, base, 7201)
      mem = Lethe.put(mem, :newest, "newest")

      assert Lethe.size(mem) == 2
      assert {:ok, _} = Lethe.peek(mem, :pinned)
      assert {:ok, _} = Lethe.peek(mem, :newest)
      assert :error = Lethe.peek(mem, :recent)
    end

    test "lazy eviction does not call summarize_fn" do
      counter = :counters.new(1, [:atomics])

      summarize_fn = fn _entry ->
        :counters.add(counter, 1, 1)
        "summary"
      end

      {mem, ref, base} =
        new_mem_with_clock(
          max_entries: 2,
          summarize_fn: summarize_fn,
          summarize_threshold: 0.3
        )

      mem = Lethe.put(mem, :a, "1")
      advance_clock(ref, base, 7200)
      mem = Lethe.put(mem, :b, "2")

      before = :counters.get(counter, 1)
      advance_clock(ref, base, 7201)
      _mem = Lethe.put(mem, :c, "3")

      assert :counters.get(counter, 1) - before == 0
    end

    test "size never exceeds max_entries" do
      {mem, ref, base} = new_mem_with_clock(max_entries: 5)

      for i <- 1..20, reduce: mem do
        mem ->
          advance_clock(ref, base, i * 60)
          Lethe.put(mem, :"key_#{i}", "val_#{i}")
      end
      |> then(fn mem -> assert Lethe.size(mem) <= 5 end)
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
    end

    test "keeps pinned entries regardless of score" do
      {mem, ref, base} = new_mem_with_clock()
      mem = Lethe.put(mem, :pinned, "important", pinned: true)
      advance_clock(ref, base, 86_400)

      {mem, evicted} = Lethe.evict(mem)

      assert evicted == []
      assert Lethe.size(mem) == 1
    end

    test "empty memory returns empty evicted list" do
      {mem, evicted} = Lethe.evict(new_mem())
      assert evicted == []
      assert Lethe.size(mem) == 0
    end

    test "all above threshold returns no evictions" do
      mem = new_mem() |> Lethe.put(:a, "1") |> Lethe.put(:b, "2")
      {mem, evicted} = Lethe.evict(mem)
      assert evicted == []
      assert Lethe.size(mem) == 2
    end

    test "evicted entries carry summaries when summarize_fn configured" do
      summarize_fn = fn entry -> "summary of #{entry.value}" end

      {mem, ref, base} =
        new_mem_with_clock(
          decay_fn: :exponential,
          summarize_fn: summarize_fn,
          summarize_threshold: 0.3,
          eviction_threshold: 0.01
        )

      mem = Lethe.put(mem, :old, "old value")
      advance_clock(ref, base, 86_400)

      {_mem, evicted} = Lethe.evict(mem)

      assert length(evicted) == 1
      assert hd(evicted).summary == "summary of old value"
      assert hd(evicted).value == "old value"
    end
  end

  describe "serialization round-trip" do
    test "struct survives term_to_binary/binary_to_term" do
      mem =
        Lethe.new(decay_fn: :exponential, max_entries: 50)
        |> Lethe.put(:a, "hello", importance: 1.5, metadata: %{source: :test})
        |> Lethe.put(:b, "world", pinned: true)

      serializable = %{mem | clock_fn: nil, summarize_fn: nil}
      binary = :erlang.term_to_binary(serializable)
      restored = :erlang.binary_to_term(binary)

      assert restored.max_entries == 50
      assert restored.decay_fn == :exponential
      assert Lethe.size(restored) == 2

      {:ok, entry_a} = Lethe.peek(restored, :a)
      assert entry_a.value == "hello"
      assert entry_a.importance == 1.5
      assert entry_a.metadata == %{source: :test}

      {:ok, entry_b} = Lethe.peek(restored, :b)
      assert entry_b.value == "world"
      assert entry_b.pinned == true
    end

    test "restored struct supports operations after re-attaching clock_fn" do
      mem =
        Lethe.new(decay_fn: :exponential)
        |> Lethe.put(:k, "value")

      serializable = %{mem | clock_fn: nil, summarize_fn: nil}
      binary = :erlang.term_to_binary(serializable)
      restored = :erlang.binary_to_term(binary)

      # Re-attach a clock and verify operations work
      restored = %{restored | clock_fn: fn -> DateTime.utc_now() end}

      score = Lethe.score(restored, :k)
      assert is_float(score)
      assert score >= 0.0 and score <= 1.0

      restored = Lethe.put(restored, :new, "added after restore")
      assert Lethe.size(restored) == 2
    end
  end
end
