defmodule Lethe.DecayTest do
  use ExUnit.Case, async: true

  alias Lethe.{Decay, Entry}

  @half_life :timer.hours(1)
  @opts [half_life: @half_life]
  @base_time ~U[2026-01-01 00:00:00Z]

  defp make_entry(opts \\ []) do
    %Entry{
      key: :test,
      value: "test",
      inserted_at: Keyword.get(opts, :inserted_at, @base_time),
      last_accessed_at: Keyword.get(opts, :last_accessed_at, @base_time),
      access_count: Keyword.get(opts, :access_count, 0),
      pinned: Keyword.get(opts, :pinned, false),
      importance: Keyword.get(opts, :importance, 1.0)
    }
  end

  defp at(seconds), do: DateTime.add(@base_time, seconds, :second)

  describe "pinned entries" do
    test "always return 1.0 regardless of age" do
      entry = make_entry(pinned: true)

      for decay_fn <- [:exponential, :access_weighted, :combined] do
        assert Decay.compute(entry, at(86_400), decay_fn, @opts) == 1.0
      end
    end
  end

  describe "exponential" do
    test "fresh entry scores near 1.0" do
      entry = make_entry()
      score = Decay.compute(entry, @base_time, :exponential, @opts)
      assert_in_delta score, 1.0, 0.001
    end

    test "at half-life scores near 0.5" do
      entry = make_entry()
      score = Decay.compute(entry, at(3600), :exponential, @opts)
      assert_in_delta score, 0.5, 0.01
    end

    test "at 2x half-life scores near 0.25" do
      entry = make_entry()
      score = Decay.compute(entry, at(7200), :exponential, @opts)
      assert_in_delta score, 0.25, 0.01
    end

    test "very old entry scores near 0.0" do
      entry = make_entry()
      score = Decay.compute(entry, at(86_400), :exponential, @opts)
      assert score < 0.001
    end

    test "zero elapsed time scores 1.0" do
      entry = make_entry()
      score = Decay.compute(entry, @base_time, :exponential, @opts)
      assert_in_delta score, 1.0, 0.001
    end
  end

  describe "importance multiplier" do
    test "0.5 importance halves the score" do
      entry = make_entry(importance: 0.5)
      score = Decay.compute(entry, at(3600), :exponential, @opts)
      assert_in_delta score, 0.25, 0.01
    end

    test "2.0 importance doubles (clamped to 1.0 when raw score is high)" do
      entry = make_entry(importance: 2.0)
      # Fresh: raw ~1.0, * 2.0 = 2.0, clamped to 1.0
      score = Decay.compute(entry, @base_time, :exponential, @opts)
      assert score == 1.0
    end

    test "2.0 importance at half-life gives ~1.0 (0.5 * 2.0 clamped)" do
      entry = make_entry(importance: 2.0)
      score = Decay.compute(entry, at(3600), :exponential, @opts)
      assert_in_delta score, 1.0, 0.01
    end
  end

  describe "access_weighted" do
    test "more accesses = higher score at same age" do
      no_access = make_entry(access_count: 0)
      many_access = make_entry(access_count: 10)

      score_none = Decay.compute(no_access, at(3600), :access_weighted, @opts)
      score_many = Decay.compute(many_access, at(3600), :access_weighted, @opts)

      assert score_many > score_none
    end

    test "fresh entry with no accesses scores near 1.0" do
      entry = make_entry(access_count: 0)
      score = Decay.compute(entry, @base_time, :access_weighted, @opts)
      assert_in_delta score, 1.0, 0.01
    end

    test "importance 0.5 halves score proportionally" do
      normal = make_entry(access_count: 10)
      half_imp = make_entry(access_count: 10, importance: 0.5)

      score_normal = Decay.compute(normal, at(3600), :access_weighted, @opts)
      score_half = Decay.compute(half_imp, at(3600), :access_weighted, @opts)

      assert_in_delta score_half, score_normal * 0.5, 0.01
    end
  end

  describe "combined" do
    test "fresh entry scores near 1.0" do
      entry = make_entry()
      score = Decay.compute(entry, @base_time, :combined, @opts)
      assert score > 0.95
    end

    test "decays over time" do
      entry = make_entry()
      score_early = Decay.compute(entry, at(60), :combined, @opts)
      score_later = Decay.compute(entry, at(7200), :combined, @opts)
      assert score_early > score_later
    end

    test "frequent access slows decay" do
      no_access = make_entry(access_count: 0)
      high_access = make_entry(access_count: 20)

      score_none = Decay.compute(no_access, at(3600), :combined, @opts)
      score_high = Decay.compute(high_access, at(3600), :combined, @opts)

      assert score_high > score_none
    end
  end

  describe "score range invariant" do
    test "all functions produce scores in 0.0..1.0" do
      entries = [
        make_entry(),
        make_entry(access_count: 100),
        make_entry(importance: 0.1),
        make_entry(importance: 3.0),
        make_entry(pinned: true)
      ]

      times = [@base_time, at(60), at(3600), at(86_400)]
      fns = [:exponential, :access_weighted, :combined]

      for entry <- entries, t <- times, f <- fns do
        score = Decay.compute(entry, t, f, @opts)
        assert score >= 0.0 and score <= 1.0, "score #{score} out of range for #{f}"
      end
    end
  end
end
