defmodule Lethe.SummarizationTest do
  use ExUnit.Case, async: true
  import Lethe.TestHelpers

  describe "evict/1 with summarize_fn" do
    test "entries below summarize_threshold get summarized" do
      test_pid = self()

      summarize_fn = fn entry ->
        send(test_pid, {:summarized, entry.key})
        "summary of #{entry.value}"
      end

      {mem, ref, base} =
        new_mem_with_clock(
          summarize_fn: summarize_fn,
          summarize_threshold: 0.3,
          eviction_threshold: 0.01
        )

      mem = Lethe.put(mem, :old, "old value")
      # Advance enough for score to drop below summarize_threshold (0.3)
      # At half_life (3600s), score ~0.5. At ~2*half_life, score ~0.25 < 0.3.
      advance_clock(ref, base, 7200)

      {_mem, _evicted} = Lethe.evict(mem)

      assert_receive {:summarized, :old}
    end

    test "entry.value preserved, entry.summary populated" do
      summarize_fn = fn entry ->
        "summarized: #{entry.value}"
      end

      {mem, ref, base} =
        new_mem_with_clock(
          summarize_fn: summarize_fn,
          summarize_threshold: 0.3,
          eviction_threshold: 0.01
        )

      mem = Lethe.put(mem, :old, "original value")
      advance_clock(ref, base, 7200)

      # Use summarize/1 to apply summaries without evicting
      mem = Lethe.summarize(mem)

      {:ok, entry} = Lethe.peek(mem, :old)
      assert entry.value == "original value"
      assert entry.summary == "summarized: original value"
    end

    test "summarize_fn called only once per entry" do
      counter = :counters.new(1, [:atomics])

      summarize_fn = fn _entry ->
        :counters.add(counter, 1, 1)
        "summary"
      end

      {mem, ref, base} =
        new_mem_with_clock(
          summarize_fn: summarize_fn,
          summarize_threshold: 0.3,
          eviction_threshold: 0.01
        )

      mem = Lethe.put(mem, :k, "value")
      advance_clock(ref, base, 7200)

      mem = Lethe.summarize(mem)
      _mem = Lethe.summarize(mem)

      assert :counters.get(counter, 1) == 1
    end
  end

  describe "evict/1 without summarize_fn" do
    test "no summarization happens" do
      {mem, ref, base} = new_mem_with_clock()
      mem = Lethe.put(mem, :k, "value")
      advance_clock(ref, base, 86_400)

      {_mem, evicted} = Lethe.evict(mem)
      assert length(evicted) == 1
      assert hd(evicted).summary == nil
    end
  end

  describe "summarize/1" do
    test "processes eligible entries" do
      summarize_fn = fn entry -> "short: #{entry.value}" end

      {mem, ref, base} =
        new_mem_with_clock(
          summarize_fn: summarize_fn,
          summarize_threshold: 0.3
        )

      mem = Lethe.put(mem, :recent, "recent")
      advance_clock(ref, base, 7200)
      mem = Lethe.put(mem, :fresh, "fresh")

      mem = Lethe.summarize(mem)

      # :recent is old enough to be summarized
      {:ok, old_entry} = Lethe.peek(mem, :recent)
      assert old_entry.summary == "short: recent"

      # :fresh was just inserted, should not be summarized
      {:ok, fresh_entry} = Lethe.peek(mem, :fresh)
      assert fresh_entry.summary == nil
    end

    test "no-op when summarize_fn is nil" do
      mem = Lethe.new() |> Lethe.put(:k, "value")
      assert Lethe.summarize(mem) == mem
    end

    test "pinned entries never summarized" do
      summarize_fn = fn _entry -> "summary" end

      {mem, ref, base} =
        new_mem_with_clock(
          summarize_fn: summarize_fn,
          summarize_threshold: 0.3
        )

      mem = Lethe.put(mem, :pinned, "important", pinned: true)
      advance_clock(ref, base, 86_400)

      mem = Lethe.summarize(mem)
      {:ok, entry} = Lethe.peek(mem, :pinned)
      assert entry.summary == nil
    end
  end
end
