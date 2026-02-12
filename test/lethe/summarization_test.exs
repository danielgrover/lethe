defmodule Lethe.SummarizationTest do
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

      cleanup_clock(ref)
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

      cleanup_clock(ref)
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

      cleanup_clock(ref)
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

      cleanup_clock(ref)
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

      cleanup_clock(ref)
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

      cleanup_clock(ref)
    end
  end
end
