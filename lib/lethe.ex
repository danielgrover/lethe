defmodule Lethe do
  @moduledoc """
  Bounded, relevance-aware storage with time-based and access-based decay.

  Entries lose relevance over time unless reinforced through access or marked
  as important. Think of it as a smarter alternative to ring buffers or LRU
  caches, grounded in how human working memory actually works.
  """

  alias Lethe.Entry

  defstruct entries: %{},
            max_entries: 100,
            decay_fn: :combined,
            half_life: 3_600_000,
            eviction_threshold: 0.05,
            summarize_threshold: 0.15,
            summarize_fn: nil,
            clock_fn: nil,
            next_key: 1

  @type t :: %__MODULE__{
          entries: %{term() => Entry.t()},
          max_entries: pos_integer(),
          decay_fn: :exponential | :access_weighted | :combined,
          half_life: pos_integer(),
          eviction_threshold: float(),
          summarize_threshold: float(),
          summarize_fn: (Entry.t() -> term()) | nil,
          clock_fn: (-> DateTime.t()) | nil,
          next_key: pos_integer()
        }

  @doc """
  Creates a new Lethe memory store with the given options.

  ## Options

    * `:max_entries` - hard cap on entry count (default: 100)
    * `:decay_fn` - `:exponential | :access_weighted | :combined` (default: `:combined`)
    * `:half_life` - half-life in milliseconds for decay (default: 3,600,000 — 1 hour)
    * `:eviction_threshold` - entries below this score get evicted (default: 0.05)
    * `:summarize_threshold` - entries below this score get summarized (default: 0.15)
    * `:summarize_fn` - function called to summarize an entry before eviction (default: nil)
    * `:clock_fn` - injectable clock for testing (default: nil, uses `DateTime.utc_now/0`)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct!(__MODULE__, opts)
  end

  @doc """
  Adds an entry with an auto-generated key.
  """
  @spec put(t(), term()) :: t()
  def put(%__MODULE__{} = mem, value) do
    put(mem, mem.next_key, value, [])
  end

  @doc """
  Adds an entry with an explicit key.
  """
  @spec put(t(), term(), term()) :: t()
  def put(%__MODULE__{} = mem, key, value) do
    put(mem, key, value, [])
  end

  @doc """
  Adds an entry with an explicit key and options.

  ## Options

    * `:importance` - importance multiplier (default: 1.0)
    * `:pinned` - whether the entry is exempt from decay (default: false)
    * `:metadata` - arbitrary metadata map (default: %{})
  """
  @spec put(t(), term(), term(), keyword()) :: t()
  def put(%__MODULE__{} = mem, key, value, opts) do
    timestamp = now(mem)

    entry = %Entry{
      key: key,
      value: value,
      inserted_at: timestamp,
      last_accessed_at: timestamp,
      access_count: 0,
      pinned: Keyword.get(opts, :pinned, false),
      importance: Keyword.get(opts, :importance, 1.0),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    # If replacing an existing key, no capacity check needed
    mem =
      if Map.has_key?(mem.entries, key) or map_size(mem.entries) < mem.max_entries do
        mem
      else
        maybe_evict_one(mem)
      end

    # If eviction failed (all pinned), skip insertion
    if not Map.has_key?(mem.entries, key) and map_size(mem.entries) >= mem.max_entries do
      mem
    else
      next_key = if key == mem.next_key, do: mem.next_key + 1, else: mem.next_key
      %{mem | entries: Map.put(mem.entries, key, entry), next_key: next_key}
    end
  end

  @doc """
  Retrieves an entry by key, refreshing its access metadata (rehearsal).

  Returns `{updated_mem, {:ok, entry}}` or `{mem, :error}`.
  """
  @spec get(t(), term()) :: {t(), {:ok, Entry.t()} | :error}
  def get(%__MODULE__{} = mem, key) do
    case Map.fetch(mem.entries, key) do
      {:ok, entry} ->
        updated =
          %{entry | last_accessed_at: now(mem), access_count: entry.access_count + 1}

        mem = %{mem | entries: Map.put(mem.entries, key, updated)}
        {mem, {:ok, updated}}

      :error ->
        {mem, :error}
    end
  end

  @doc """
  Retrieves an entry by key without modifying access metadata.

  Returns `{:ok, entry}` or `:error`.
  """
  @spec peek(t(), term()) :: {:ok, Entry.t()} | :error
  def peek(%__MODULE__{} = mem, key) do
    Map.fetch(mem.entries, key)
  end

  @doc """
  Removes an entry by key. No-op if the key doesn't exist.
  """
  @spec delete(t(), term()) :: t()
  def delete(%__MODULE__{} = mem, key) do
    %{mem | entries: Map.delete(mem.entries, key)}
  end

  @doc """
  Replaces an entry's value, resets last_accessed_at, increments access_count.

  Preserves metadata, pinned, and importance. No-op if the key doesn't exist.
  """
  @spec update(t(), term(), term()) :: t()
  def update(%__MODULE__{} = mem, key, new_value) do
    update_entry(mem, key, fn entry ->
      %{
        entry
        | value: new_value,
          last_accessed_at: now(mem),
          access_count: entry.access_count + 1
      }
    end)
  end

  @doc """
  Refreshes an entry's access metadata. No-op if the key doesn't exist.
  """
  @spec touch(t(), term()) :: t()
  def touch(%__MODULE__{} = mem, key), do: touch(mem, key, [])

  @doc """
  Refreshes an entry's access metadata and applies options.

  ## Options

    * `:importance` - update the importance multiplier

  No-op if the key doesn't exist.
  """
  @spec touch(t(), term(), keyword()) :: t()
  def touch(%__MODULE__{} = mem, key, opts) do
    update_entry(mem, key, fn entry ->
      entry = %{entry | last_accessed_at: now(mem), access_count: entry.access_count + 1}

      case Keyword.fetch(opts, :importance) do
        {:ok, importance} -> %{entry | importance: importance}
        :error -> entry
      end
    end)
  end

  @doc """
  Removes all entries, preserving configuration.
  """
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = mem) do
    %{mem | entries: %{}, next_key: 1}
  end

  @doc """
  Returns the number of entries.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{entries: entries}), do: map_size(entries)

  @doc """
  Pins an entry, making it exempt from decay. No-op if the key doesn't exist.
  """
  @spec pin(t(), term()) :: t()
  def pin(%__MODULE__{} = mem, key) do
    update_entry(mem, key, fn entry -> %{entry | pinned: true} end)
  end

  @doc """
  Unpins an entry, allowing it to decay normally. No-op if the key doesn't exist.
  """
  @spec unpin(t(), term()) :: t()
  def unpin(%__MODULE__{} = mem, key) do
    update_entry(mem, key, fn entry -> %{entry | pinned: false} end)
  end

  @doc """
  Removes all entries below the eviction threshold.

  Returns `{new_mem, evicted_entries}`. Pinned entries are never evicted.
  """
  @spec evict(t()) :: {t(), [Entry.t()]}
  def evict(%__MODULE__{} = mem) do
    # First, summarize eligible entries
    mem = maybe_summarize_entries(mem)

    {keep, evicted} =
      Enum.split_with(mem.entries, fn {_key, entry} ->
        entry.pinned or compute_score(mem, entry) >= mem.eviction_threshold
      end)

    evicted_entries = Enum.map(evicted, fn {_key, entry} -> entry end)
    {%{mem | entries: Map.new(keep)}, evicted_entries}
  end

  @doc """
  Runs `summarize_fn` on all eligible entries (below summarize_threshold,
  no existing summary, not pinned). No-op if `summarize_fn` is nil.
  """
  @spec summarize(t()) :: t()
  def summarize(%__MODULE__{summarize_fn: nil} = mem), do: mem

  def summarize(%__MODULE__{} = mem) do
    maybe_summarize_entries(mem)
  end

  @doc """
  Returns the decay score for a single entry by key.

  Returns the score as a float, or `:error` if the key doesn't exist.
  """
  @spec score(t(), term()) :: float() | :error
  def score(%__MODULE__{} = mem, key) do
    case Map.fetch(mem.entries, key) do
      {:ok, entry} -> compute_score(mem, entry)
      :error -> :error
    end
  end

  @doc """
  Returns all entries with their scores, sorted by score descending.

  This is the primary Winnow integration point.
  """
  @spec scored(t()) :: [{Entry.t(), float()}]
  def scored(%__MODULE__{} = mem) do
    mem.entries
    |> Map.values()
    |> Enum.map(fn entry -> {entry, compute_score(mem, entry)} end)
    |> Enum.sort_by(fn {_entry, score} -> score end, :desc)
  end

  @doc """
  Returns a map of key => score for all entries.
  """
  @spec score_map(t()) :: %{term() => float()}
  def score_map(%__MODULE__{} = mem) do
    Map.new(mem.entries, fn {key, entry} -> {key, compute_score(mem, entry)} end)
  end

  @doc """
  Returns entries above the eviction threshold, sorted by score descending.
  """
  @spec active(t()) :: [Entry.t()]
  def active(%__MODULE__{} = mem) do
    above(mem, mem.eviction_threshold)
  end

  @doc """
  Returns entries above a custom score threshold, sorted by score descending.
  """
  @spec above(t(), float()) :: [Entry.t()]
  def above(%__MODULE__{} = mem, threshold) do
    mem.entries
    |> Map.values()
    |> Enum.map(fn entry -> {entry, compute_score(mem, entry)} end)
    |> Enum.filter(fn {_entry, score} -> score >= threshold end)
    |> Enum.sort_by(fn {_entry, score} -> score end, :desc)
    |> Enum.map(fn {entry, _score} -> entry end)
  end

  @doc """
  Returns the N highest-scored entries.
  """
  @spec top(t(), non_neg_integer()) :: [Entry.t()]
  def top(%__MODULE__{} = mem, n) do
    mem
    |> scored()
    |> Enum.take(n)
    |> Enum.map(fn {entry, _score} -> entry end)
  end

  @doc """
  Returns the count of entries above the eviction threshold.
  """
  @spec active_count(t()) :: non_neg_integer()
  def active_count(%__MODULE__{} = mem) do
    Enum.count(mem.entries, fn {_key, entry} ->
      compute_score(mem, entry) >= mem.eviction_threshold
    end)
  end

  @doc """
  Returns the count of pinned entries.
  """
  @spec pinned_count(t()) :: non_neg_integer()
  def pinned_count(%__MODULE__{} = mem) do
    Enum.count(mem.entries, fn {_key, entry} -> entry.pinned end)
  end

  @doc """
  Filters entries by a predicate function. Returns matching entries.
  """
  @spec filter(t(), (Entry.t() -> boolean())) :: [Entry.t()]
  def filter(%__MODULE__{} = mem, pred) do
    mem.entries
    |> Map.values()
    |> Enum.filter(pred)
  end

  @doc """
  Returns summary statistics about the memory store.
  """
  @spec stats(t()) :: map()
  def stats(%__MODULE__{entries: entries} = _mem) when map_size(entries) == 0 do
    %{
      size: 0,
      active: 0,
      pinned: 0,
      oldest_entry: nil,
      newest_entry: nil,
      mean_score: nil,
      median_score: nil
    }
  end

  def stats(%__MODULE__{} = mem) do
    scores =
      mem.entries
      |> Map.values()
      |> Enum.map(fn entry -> compute_score(mem, entry) end)
      |> Enum.sort()

    entries = Map.values(mem.entries)
    n = length(scores)

    %{
      size: map_size(mem.entries),
      active: active_count(mem),
      pinned: pinned_count(mem),
      oldest_entry: entries |> Enum.min_by(& &1.inserted_at, DateTime) |> Map.get(:inserted_at),
      newest_entry: entries |> Enum.max_by(& &1.inserted_at, DateTime) |> Map.get(:inserted_at),
      mean_score: Enum.sum(scores) / n,
      median_score: median(scores, n)
    }
  end

  defp median(sorted, n) when rem(n, 2) == 1, do: Enum.at(sorted, div(n, 2))

  defp median(sorted, n) do
    (Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) / 2.0
  end

  defp compute_score(%__MODULE__{} = mem, %Entry{} = entry) do
    Lethe.Decay.compute(entry, now(mem), mem.decay_fn, half_life: mem.half_life)
  end

  defp update_entry(%__MODULE__{} = mem, key, fun) do
    case Map.fetch(mem.entries, key) do
      {:ok, entry} -> %{mem | entries: Map.put(mem.entries, key, fun.(entry))}
      :error -> mem
    end
  end

  # Evicts the single lowest-scored unpinned entry. Summarizes it first if eligible.
  defp maybe_evict_one(%__MODULE__{} = mem) do
    unpinned =
      mem.entries
      |> Enum.reject(fn {_key, entry} -> entry.pinned end)

    case unpinned do
      [] ->
        mem

      entries ->
        {victim_key, victim} =
          Enum.min_by(entries, fn {_key, entry} -> compute_score(mem, entry) end)

        # Summarize the victim before evicting, if eligible
        mem =
          if should_summarize?(mem, victim) do
            summarized = %{victim | summary: mem.summarize_fn.(victim)}
            %{mem | entries: Map.put(mem.entries, victim_key, summarized)}
          else
            mem
          end

        %{mem | entries: Map.delete(mem.entries, victim_key)}
    end
  end

  # Summarizes all eligible entries in the memory store.
  defp maybe_summarize_entries(%__MODULE__{summarize_fn: nil} = mem), do: mem

  defp maybe_summarize_entries(%__MODULE__{} = mem) do
    updated_entries =
      Map.new(mem.entries, fn {key, entry} ->
        if should_summarize?(mem, entry) do
          {key, %{entry | summary: mem.summarize_fn.(entry)}}
        else
          {key, entry}
        end
      end)

    %{mem | entries: updated_entries}
  end

  defp should_summarize?(%__MODULE__{summarize_fn: nil}, _entry), do: false

  defp should_summarize?(%__MODULE__{} = mem, %Entry{} = entry) do
    not entry.pinned and
      entry.summary == nil and
      compute_score(mem, entry) < mem.summarize_threshold
  end

  @doc false
  @spec now(t()) :: DateTime.t()
  def now(%__MODULE__{clock_fn: nil}), do: DateTime.utc_now()
  def now(%__MODULE__{clock_fn: clock_fn}), do: clock_fn.()
end
