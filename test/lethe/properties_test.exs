defmodule Lethe.PropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @max_entries 10
  @half_life :timer.hours(1)
  @decay_fns [:exponential, :access_weighted, :combined]

  # -- Generators --

  defp key_gen, do: one_of([atom(:alphanumeric), integer(1..100)])
  defp value_gen, do: string(:printable, min_length: 1, max_length: 20)
  defp importance_gen, do: float(min: 0.1, max: 3.0)
  defp time_step_gen, do: integer(0..7200)
  defp decay_fn_gen, do: member_of(@decay_fns)

  defp operation_gen do
    one_of([
      constant(:put),
      constant(:get),
      constant(:peek),
      constant(:delete),
      constant(:pin),
      constant(:unpin),
      constant(:touch)
    ])
  end

  defp operation_sequence_gen do
    list_of(
      tuple({operation_gen(), key_gen(), value_gen(), importance_gen(), time_step_gen()}),
      min_length: 1,
      max_length: 50
    )
  end

  # -- Helpers --

  defp apply_operation({:put, key, value, importance, _step}, mem) do
    Lethe.put(mem, key, value, importance: importance)
  end

  defp apply_operation({:get, key, _value, _importance, _step}, mem) do
    {_result, mem} = Lethe.get(mem, key)
    mem
  end

  defp apply_operation({:peek, key, _value, _importance, _step}, mem) do
    Lethe.peek(mem, key)
    mem
  end

  defp apply_operation({:delete, key, _value, _importance, _step}, mem) do
    Lethe.delete(mem, key)
  end

  defp apply_operation({:pin, key, _value, _importance, _step}, mem) do
    Lethe.pin(mem, key)
  end

  defp apply_operation({:unpin, key, _value, _importance, _step}, mem) do
    Lethe.unpin(mem, key)
  end

  defp apply_operation({:touch, key, _value, importance, _step}, mem) do
    Lethe.touch(mem, key, importance: importance)
  end

  defp make_mem(time_ref, decay_fn) do
    Lethe.new(
      max_entries: @max_entries,
      decay_fn: decay_fn,
      half_life: @half_life,
      clock_fn: fn -> :persistent_term.get(time_ref) end
    )
  end

  defp with_time_ref(fun) do
    time_ref = :erlang.make_ref()
    base = ~U[2026-01-01 00:00:00Z]
    :persistent_term.put(time_ref, base)

    try do
      fun.(time_ref, base)
    after
      :persistent_term.erase(time_ref)
    end
  end

  defp run_ops_with_invariant(ops, decay_fn, invariant_fn) do
    with_time_ref(fn time_ref, _base ->
      mem = make_mem(time_ref, decay_fn)

      Enum.reduce(ops, mem, fn {_op, _key, _val, _imp, step} = op, mem ->
        :persistent_term.put(
          time_ref,
          DateTime.add(:persistent_term.get(time_ref), step, :second)
        )

        mem = apply_operation(op, mem)
        invariant_fn.(mem)
        mem
      end)
    end)
  end

  # -- Properties --

  property "score is always in 0.0..1.0" do
    check all(
            ops <- operation_sequence_gen(),
            decay_fn <- decay_fn_gen(),
            max_runs: 100
          ) do
      run_ops_with_invariant(ops, decay_fn, fn mem ->
        for {_entry, score} <- Lethe.scored(mem) do
          assert score >= 0.0 and score <= 1.0,
                 "Score #{score} out of range (decay_fn: #{decay_fn})"
        end
      end)
    end
  end

  property "pinned entries always score exactly 1.0" do
    check all(
            ops <- operation_sequence_gen(),
            decay_fn <- decay_fn_gen(),
            max_runs: 100
          ) do
      run_ops_with_invariant(ops, decay_fn, fn mem ->
        for {entry, score} <- Lethe.scored(mem), entry.pinned do
          assert score == 1.0,
                 "Pinned entry #{inspect(entry.key)} scored #{score}, expected 1.0 (decay_fn: #{decay_fn})"
        end
      end)
    end
  end

  property "monotonic decay: score does not increase over time without access" do
    check all(
            key <- key_gen(),
            value <- value_gen(),
            importance <- importance_gen(),
            decay_fn <- decay_fn_gen(),
            time_steps <- list_of(integer(1..3600), min_length: 2, max_length: 10),
            max_runs: 100
          ) do
      with_time_ref(fn time_ref, _base ->
        mem = make_mem(time_ref, decay_fn)
        mem = Lethe.put(mem, key, value, importance: importance)

        Enum.reduce(time_steps, {mem, nil}, fn step, {mem, prev_score} ->
          :persistent_term.put(
            time_ref,
            DateTime.add(:persistent_term.get(time_ref), step, :second)
          )

          score = Lethe.score(mem, key)

          if prev_score != nil and score != :error do
            assert score <= prev_score + 1.0e-10,
                   "Score increased from #{prev_score} to #{score} without access (decay_fn: #{decay_fn})"
          end

          {mem, score}
        end)
      end)
    end
  end

  property "size never exceeds max_entries after any operation" do
    check all(
            ops <- operation_sequence_gen(),
            decay_fn <- decay_fn_gen(),
            max_runs: 100
          ) do
      run_ops_with_invariant(ops, decay_fn, fn mem ->
        assert Lethe.size(mem) <= @max_entries,
               "Size #{Lethe.size(mem)} exceeds max #{@max_entries} (decay_fn: #{decay_fn})"
      end)
    end
  end

  property "eviction ordering: evicted entry has lowest score among unpinned" do
    check all(
            values <- list_of(value_gen(), min_length: @max_entries, max_length: @max_entries),
            extra_value <- value_gen(),
            decay_fn <- decay_fn_gen(),
            max_runs: 50
          ) do
      with_time_ref(fn time_ref, base ->
        mem = make_mem(time_ref, decay_fn)

        # Fill to capacity with time gaps between each
        mem =
          Enum.with_index(values)
          |> Enum.reduce(mem, fn {value, i}, mem ->
            :persistent_term.put(time_ref, DateTime.add(base, i * 60, :second))
            Lethe.put(mem, :"k#{i}", value)
          end)

        # Record scores before eviction
        scores_before = Lethe.score_map(mem)

        unpinned_scores =
          Enum.reject(scores_before, fn {key, _} ->
            {:ok, e} = Lethe.peek(mem, key)
            e.pinned
          end)

        {min_key, _min_score} = Enum.min_by(unpinned_scores, fn {_k, s} -> s end)

        # Add one more to trigger eviction
        :persistent_term.put(time_ref, DateTime.add(base, @max_entries * 60, :second))
        mem = Lethe.put(mem, :extra, extra_value)

        # The lowest-scored unpinned entry should have been evicted
        assert :error = Lethe.peek(mem, min_key)
      end)
    end
  end

  property "active/1 never returns entries below eviction_threshold" do
    check all(
            ops <- operation_sequence_gen(),
            decay_fn <- decay_fn_gen(),
            max_runs: 100
          ) do
      with_time_ref(fn time_ref, _base ->
        mem = make_mem(time_ref, decay_fn)

        final_mem =
          Enum.reduce(ops, mem, fn {_op, _key, _val, _imp, step} = op, mem ->
            :persistent_term.put(
              time_ref,
              DateTime.add(:persistent_term.get(time_ref), step, :second)
            )

            apply_operation(op, mem)
          end)

        for entry <- Lethe.active(final_mem) do
          score = Lethe.score(final_mem, entry.key)

          assert score >= final_mem.eviction_threshold,
                 "Active entry #{inspect(entry.key)} has score #{score} below threshold #{final_mem.eviction_threshold} (decay_fn: #{decay_fn})"
        end
      end)
    end
  end

  property "scored/1 is sorted descending by score" do
    check all(
            ops <- operation_sequence_gen(),
            decay_fn <- decay_fn_gen(),
            max_runs: 100
          ) do
      with_time_ref(fn time_ref, _base ->
        mem = make_mem(time_ref, decay_fn)

        final_mem =
          Enum.reduce(ops, mem, fn {_op, _key, _val, _imp, step} = op, mem ->
            :persistent_term.put(
              time_ref,
              DateTime.add(:persistent_term.get(time_ref), step, :second)
            )

            apply_operation(op, mem)
          end)

        scored = Lethe.scored(final_mem)
        scores = Enum.map(scored, fn {_entry, score} -> score end)

        assert scores == Enum.sort(scores, :desc),
               "scored/1 not sorted descending: #{inspect(scores)} (decay_fn: #{decay_fn})"
      end)
    end
  end

  property "get increments access_count, peek does not" do
    check all(key <- key_gen(), value <- value_gen(), max_runs: 50) do
      mem = Lethe.new() |> Lethe.put(key, value)

      {:ok, before_peek} = Lethe.peek(mem, key)
      Lethe.peek(mem, key)
      {:ok, after_peek} = Lethe.peek(mem, key)
      assert after_peek.access_count == before_peek.access_count

      {{:ok, after_get}, mem} = Lethe.get(mem, key)
      assert after_get.access_count == before_peek.access_count + 1

      {{:ok, after_get2}, _mem} = Lethe.get(mem, key)
      assert after_get2.access_count == before_peek.access_count + 2
    end
  end
end
