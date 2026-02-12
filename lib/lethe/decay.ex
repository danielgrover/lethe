defmodule Lethe.Decay do
  @moduledoc """
  Decay score computation for Lethe entries.

  All decay functions return a float in 0.0..1.0. Pinned entries always
  return 1.0. The importance multiplier is applied after computation and
  clamped to range.
  """

  alias Lethe.Entry

  @doc """
  Computes the decay score for an entry at the given time.

  `opts` must include `:half_life` (in milliseconds).
  """
  @spec compute(Entry.t(), DateTime.t(), atom(), keyword()) :: float()
  def compute(%Entry{pinned: true}, _now, _decay_fn, _opts), do: 1.0

  def compute(%Entry{} = entry, now, decay_fn, opts) do
    half_life_ms = Keyword.fetch!(opts, :half_life)
    half_life_s = half_life_ms / 1000.0

    raw_score =
      case decay_fn do
        :exponential -> exponential(entry, now, half_life_s)
        :access_weighted -> access_weighted(entry, now, half_life_s)
        :combined -> combined(entry, now, half_life_s)
      end

    raw_score
    |> Kernel.*(entry.importance)
    |> clamp(0.0, 1.0)
  end

  # Pure time-based exponential decay from last access.
  defp exponential(entry, now, half_life_s) do
    seconds = seconds_since(entry.last_accessed_at, now)
    lambda = :math.log(2) / half_life_s
    :math.exp(-lambda * seconds)
  end

  # Exponential decay boosted by access frequency.
  # Normalized to 0.0..1.0 before importance is applied.
  defp access_weighted(entry, now, half_life_s) do
    base = exponential(entry, now, half_life_s)
    frequency_boost = :math.log10(entry.access_count + 1) + 1.0
    min(base * frequency_boost, 1.0)
  end

  # ACT-R inspired: blends recency and frequency with a sigmoid normalization.
  # Sigmoid scaling maps activation=1.0 (fresh) to ~0.98, activation=0.5 to 0.5,
  # activation=0.0 to ~0.02.
  defp combined(entry, now, half_life_s) do
    seconds_since_access = seconds_since(entry.last_accessed_at, now)
    seconds_since_insert = seconds_since(entry.inserted_at, now)

    # Recency component: exponential decay from last access
    lambda = :math.log(2) / half_life_s
    recency = :math.exp(-lambda * seconds_since_access)

    # Frequency component: log of access count, scaled by inverse sqrt of age
    age_factor =
      if seconds_since_insert > 0,
        do: 1.0 / :math.sqrt(seconds_since_insert + 1),
        else: 1.0

    frequency = :math.log(entry.access_count + 1) * age_factor

    # Combine via sigmoid: maps [0, 1] activation range to [~0, ~1] output
    activation = recency + frequency
    sigmoid(activation * 8.0 - 4.0)
  end

  defp seconds_since(from, to) do
    diff = DateTime.diff(to, from, :millisecond)
    max(diff, 0) / 1000.0
  end

  defp sigmoid(x) do
    1.0 / (1.0 + :math.exp(-x))
  end

  defp clamp(value, min_val, max_val) do
    value |> max(min_val) |> min(max_val)
  end
end
