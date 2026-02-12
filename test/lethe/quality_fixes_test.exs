defmodule Lethe.QualityFixesTest do
  @moduledoc """
  Regression tests for quality issues. Each describe block maps to a
  numbered issue from the codebase analysis. These tests are written
  BEFORE the fixes — they should fail on the unfixed code.
  """
  use ExUnit.Case, async: true
  import Lethe.TestHelpers

  # -----------------------------------------------------------
  # Issue #1: maybe_evict_one summarizes then immediately deletes
  # -----------------------------------------------------------
  describe "issue #1: lazy eviction does not waste summarization" do
    test "summarize_fn is NOT called during lazy eviction on put" do
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
      calls = :counters.get(counter, 1) - before

      assert calls == 0,
             "summarize_fn was called #{calls} times during lazy eviction, expected 0"
    end
  end

  # -----------------------------------------------------------
  # Issue #2: now/1 called multiple times per operation
  # -----------------------------------------------------------
  describe "issue #2: clock_fn called exactly once per public operation" do
    defp counting_clock do
      counter = :counters.new(1, [:atomics])
      base = ~U[2026-01-01 00:00:00Z]

      clock_fn = fn ->
        :counters.add(counter, 1, 1)
        base
      end

      {clock_fn, counter}
    end

    defp calls_since(counter, before) do
      :counters.get(counter, 1) - before
    end

    test "scored/1 calls clock_fn exactly once" do
      {clock_fn, counter} = counting_clock()
      mem = Lethe.new(clock_fn: clock_fn, decay_fn: :exponential)
      mem = Lethe.put(mem, :a, "1")
      mem = Lethe.put(mem, :b, "2")
      mem = Lethe.put(mem, :c, "3")

      before = :counters.get(counter, 1)
      _scored = Lethe.scored(mem)

      assert calls_since(counter, before) == 1,
             "scored/1 called clock_fn #{calls_since(counter, before)} times, expected 1"
    end

    test "score_map/1 calls clock_fn exactly once" do
      {clock_fn, counter} = counting_clock()
      mem = Lethe.new(clock_fn: clock_fn, decay_fn: :exponential)
      mem = Lethe.put(mem, :a, "1")
      mem = Lethe.put(mem, :b, "2")

      before = :counters.get(counter, 1)
      _map = Lethe.score_map(mem)

      assert calls_since(counter, before) == 1
    end

    test "active/1 calls clock_fn exactly once" do
      {clock_fn, counter} = counting_clock()
      mem = Lethe.new(clock_fn: clock_fn, decay_fn: :exponential)
      mem = Lethe.put(mem, :a, "1")
      mem = Lethe.put(mem, :b, "2")

      before = :counters.get(counter, 1)
      _active = Lethe.active(mem)

      assert calls_since(counter, before) == 1
    end

    test "stats/1 calls clock_fn exactly once" do
      {clock_fn, counter} = counting_clock()
      mem = Lethe.new(clock_fn: clock_fn, decay_fn: :exponential)
      mem = Lethe.put(mem, :a, "1")
      mem = Lethe.put(mem, :b, "2")

      before = :counters.get(counter, 1)
      _stats = Lethe.stats(mem)

      assert calls_since(counter, before) == 1,
             "stats/1 called clock_fn #{calls_since(counter, before)} times, expected 1"
    end

    test "evict/1 calls clock_fn exactly once" do
      {clock_fn, counter} = counting_clock()
      mem = Lethe.new(clock_fn: clock_fn, decay_fn: :exponential)
      mem = Lethe.put(mem, :a, "1")
      mem = Lethe.put(mem, :b, "2")

      before = :counters.get(counter, 1)
      _result = Lethe.evict(mem)

      assert calls_since(counter, before) == 1,
             "evict/1 called clock_fn #{calls_since(counter, before)} times, expected 1"
    end

    test "active_count/1 calls clock_fn exactly once" do
      {clock_fn, counter} = counting_clock()
      mem = Lethe.new(clock_fn: clock_fn, decay_fn: :exponential)
      mem = Lethe.put(mem, :a, "1")
      mem = Lethe.put(mem, :b, "2")

      before = :counters.get(counter, 1)
      _count = Lethe.active_count(mem)

      assert calls_since(counter, before) == 1
    end
  end

  # -----------------------------------------------------------
  # Issue #3: Enumerable.member?/2 checks key, not value equality
  # -----------------------------------------------------------
  describe "issue #3: Enumerable.member?/2 uses value equality" do
    test "entry with same key but different value is NOT a member" do
      mem = Lethe.new() |> Lethe.put(:a, "original")
      {:ok, entry} = Lethe.peek(mem, :a)

      different = %{entry | value: "modified"}

      assert Enum.member?(mem, entry)
      refute Enum.member?(mem, different)
    end
  end

  # -----------------------------------------------------------
  # Issue #5: combined fresh score is ~0.73, not ~1.0
  # -----------------------------------------------------------
  describe "issue #5: combined fresh score near 1.0" do
    test "fresh combined entry scores > 0.95" do
      base = ~U[2026-01-01 00:00:00Z]

      entry = %Lethe.Entry{
        key: :test,
        value: "test",
        inserted_at: base,
        last_accessed_at: base,
        access_count: 0,
        importance: 1.0,
        pinned: false
      }

      score = Lethe.Decay.compute(entry, base, :combined, half_life: :timer.hours(1))
      assert score > 0.95, "Fresh combined score was #{score}, expected > 0.95"
    end
  end

  # -----------------------------------------------------------
  # Issue #4: access_weighted importance proportionality
  # -----------------------------------------------------------
  describe "issue #4: access_weighted importance works proportionally" do
    test "importance 0.5 halves score even with high access count" do
      base = ~U[2026-01-01 00:00:00Z]
      at_half_life = DateTime.add(base, 3600, :second)
      opts = [half_life: :timer.hours(1)]

      normal = %Lethe.Entry{
        key: :test,
        value: "test",
        inserted_at: base,
        last_accessed_at: base,
        access_count: 10,
        importance: 1.0,
        pinned: false
      }

      half_imp = %{normal | importance: 0.5}

      score_normal = Lethe.Decay.compute(normal, at_half_life, :access_weighted, opts)
      score_half = Lethe.Decay.compute(half_imp, at_half_life, :access_weighted, opts)

      assert_in_delta score_half,
                      score_normal * 0.5,
                      0.01,
                      "Expected #{score_normal * 0.5}, got #{score_half}"
    end
  end

  # -----------------------------------------------------------
  # Issue #11: no input validation in new/1
  # -----------------------------------------------------------
  describe "issue #11: input validation" do
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
end
