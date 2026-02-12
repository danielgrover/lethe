defmodule Lethe do
  @moduledoc """
  Bounded, relevance-aware storage with time-based and access-based decay.

  Entries lose relevance over time unless reinforced through access or marked
  as important. Think of it as a smarter alternative to ring buffers or LRU
  caches, grounded in how human working memory actually works.

  ## Serializability

  The `%Lethe{}` struct stores `:decay_fn` as an atom (when using built-in
  functions) or as an anonymous function (when using a custom decay function).
  `:clock_fn` and `:summarize_fn` are also anonymous functions. If you need
  to serialize the struct (e.g. with `:erlang.term_to_binary/1` or JSON),
  set any function fields to `nil` (or a built-in atom for `:decay_fn`)
  before serializing and re-attach them after deserialization.
  """

  alias Lethe.Entry

  @builtin_decay_fns [:exponential, :access_weighted, :combined]

  defstruct entries: %{},
            max_entries: 100,
            decay_fn: :combined,
            half_life: 3_600_000,
            eviction_threshold: 0.05,
            summarize_threshold: 0.15,
            summarize_fn: nil,
            clock_fn: nil,
            next_key: 1

  @type decay_fn :: :exponential | :access_weighted | :combined | (Entry.t(), DateTime.t(), keyword() -> float())

  @type t :: %__MODULE__{
          entries: %{term() => Entry.t()},
          max_entries: pos_integer(),
          decay_fn: decay_fn(),
          half_life: pos_integer(),
          eviction_threshold: float(),
          summarize_threshold: float(),
          summarize_fn: (Entry.t() -> term()) | nil,
          clock_fn: (-> DateTime.t()) | nil,
          next_key: pos_integer()
        }

  @type stats :: %{
          size: non_neg_integer(),
          active: non_neg_integer(),
          pinned: non_neg_integer(),
          oldest_entry: DateTime.t() | nil,
          newest_entry: DateTime.t() | nil,
          mean_score: float() | nil,
          median_score: float() | nil
        }

  @doc """
  Creates a new Lethe memory store with the given options.

  ## Options

    * `:max_entries` - hard cap on entry count (default: 100)
    * `:decay_fn` - `:exponential | :access_weighted | :combined` or a custom function
      `fn(entry, now, opts) -> raw_score`. The custom function receives the entry, current
      time, and options (including `:half_life`), and should return a raw score. Importance
      multiplication and clamping to 0.0..1.0 are applied automatically. (default: `:combined`)
    * `:half_life` - half-life in milliseconds for decay (default: 3,600,000 — 1 hour)
    * `:eviction_threshold` - entries below this score get evicted (default: 0.05)
    * `:summarize_threshold` - entries below this score get summarized (default: 0.15)
    * `:summarize_fn` - function called to summarize an entry before eviction (default: nil)
    * `:clock_fn` - injectable clock for testing (default: nil, uses `DateTime.utc_now/0`)

  ## Raises

    * `ArgumentError` if `:max_entries` is not a positive integer
    * `ArgumentError` if `:half_life` is not a positive integer
    * `ArgumentError` if `:decay_fn` is not a valid atom or function
    * `ArgumentError` if `:eviction_threshold` is outside 0.0..1.0
    * `ArgumentError` if `:summarize_threshold` is less than `:eviction_threshold`
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    mem = struct!(__MODULE__, opts)
    validate!(mem)
    mem
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

    * `:importance` - importance multiplier, must be > 0. Values > 1.0 boost the
      score, values < 1.0 reduce it. The final score is always clamped to 0.0..1.0.
      (default: 1.0)
    * `:pinned` - whether the entry is exempt from decay (default: false)
    * `:metadata` - arbitrary metadata map (default: %{})
  """
  @valid_put_opts [:importance, :pinned, :metadata]

  @spec put(t(), term(), term(), keyword()) :: t()
  def put(%__MODULE__{} = mem, key, value, opts) do
    validate_put_opts!(opts)
    ts = now(mem)

    entry = %Entry{
      key: key,
      value: value,
      inserted_at: ts,
      last_accessed_at: ts,
      access_count: 0,
      pinned: Keyword.get(opts, :pinned, false),
      importance: Keyword.get(opts, :importance, 1.0),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    replacing? = Map.has_key?(mem.entries, key)
    at_capacity? = map_size(mem.entries) >= mem.max_entries

    if replacing? or not at_capacity? do
      insert_entry(mem, key, entry)
    else
      # At capacity with a new key — try to evict, insert if successful
      evicted_mem = maybe_evict_one(mem, ts)
      if evicted_mem == mem, do: mem, else: insert_entry(evicted_mem, key, entry)
    end
  end

  @doc """
  Retrieves an entry by key, refreshing its access metadata (rehearsal).

  Returns `{entry, updated_mem}` if the key exists, or `{nil, mem}` if it
  does not. Follows the Elixir convention for get-and-modify operations
  (see `Map.pop/3`, `Map.get_and_update/3`).
  """
  @spec get(t(), term()) :: {Entry.t() | nil, t()}
  def get(%__MODULE__{} = mem, key) do
    case Map.fetch(mem.entries, key) do
      {:ok, entry} ->
        updated =
          %{entry | last_accessed_at: now(mem), access_count: entry.access_count + 1}

        mem = %{mem | entries: Map.put(mem.entries, key, updated)}
        {updated, mem}

      :error ->
        {nil, mem}
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
  Updates an entry's value, resets last_accessed_at, increments access_count.

  Preserves metadata, pinned, and importance. No-op if the key doesn't exist.
  """
  @spec update(t(), term(), term()) :: t()
  def update(%__MODULE__{} = mem, key, new_value) do
    ts = now(mem)

    update_entry(mem, key, fn entry ->
      %{
        entry
        | value: new_value,
          last_accessed_at: ts,
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
    ts = now(mem)

    update_entry(mem, key, fn entry ->
      entry = %{entry | last_accessed_at: ts, access_count: entry.access_count + 1}

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
  Returns all keys in the memory store.
  """
  @spec keys(t()) :: [term()]
  def keys(%__MODULE__{entries: entries}), do: Map.keys(entries)

  @doc """
  Returns whether the memory store contains the given key.
  """
  @spec has_key?(t(), term()) :: boolean()
  def has_key?(%__MODULE__{entries: entries}, key), do: Map.has_key?(entries, key)

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

  When a `summarize_fn` is configured, entries below the `summarize_threshold`
  that don't already have a summary will be summarized before eviction. This
  means evicted entries in the returned list may have their `summary` field
  populated, allowing callers to preserve compressed versions of evicted data.
  Entries that are kept but fall below the summarize threshold are also
  summarized in-place.
  """
  @spec evict(t()) :: {t(), [Entry.t()]}
  def evict(%__MODULE__{} = mem) do
    ts = now(mem)

    {keep, evicted} =
      Enum.reduce(mem.entries, {[], []}, fn {key, entry}, {kept, evict_acc} ->
        classify_for_eviction(mem, key, entry, ts, kept, evict_acc)
      end)

    {%{mem | entries: Map.new(keep)}, evicted}
  end

  @doc """
  Runs `summarize_fn` on all eligible entries (below summarize_threshold,
  no existing summary, not pinned). No-op if `summarize_fn` is nil.
  """
  @spec summarize(t()) :: t()
  def summarize(%__MODULE__{summarize_fn: nil} = mem), do: mem

  def summarize(%__MODULE__{} = mem) do
    ts = now(mem)
    maybe_summarize_entries(mem, ts)
  end

  @doc """
  Returns the decay score for a single entry by key.

  Returns the score as a float, or `:error` if the key doesn't exist.
  """
  @spec score(t(), term()) :: float() | :error
  def score(%__MODULE__{} = mem, key) do
    case Map.fetch(mem.entries, key) do
      {:ok, entry} -> compute_score(mem, entry, now(mem))
      :error -> :error
    end
  end

  @doc """
  Returns all entries with their scores, sorted by score descending.

  This is the primary Winnow integration point.
  """
  @spec scored(t()) :: [{Entry.t(), float()}]
  def scored(%__MODULE__{} = mem) do
    ts = now(mem)

    mem.entries
    |> Map.values()
    |> Enum.map(fn entry -> {entry, compute_score(mem, entry, ts)} end)
    |> Enum.sort_by(fn {_entry, score} -> score end, :desc)
  end

  @doc """
  Returns a map of key => score for all entries.
  """
  @spec score_map(t()) :: %{term() => float()}
  def score_map(%__MODULE__{} = mem) do
    ts = now(mem)
    Map.new(mem.entries, fn {key, entry} -> {key, compute_score(mem, entry, ts)} end)
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
    ts = now(mem)

    mem.entries
    |> Map.values()
    |> Enum.reduce([], fn entry, acc ->
      score = compute_score(mem, entry, ts)
      if score >= threshold, do: [{entry, score} | acc], else: acc
    end)
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
    ts = now(mem)

    Enum.count(mem.entries, fn {_key, entry} ->
      compute_score(mem, entry, ts) >= mem.eviction_threshold
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
  @spec stats(t()) :: stats()
  def stats(%__MODULE__{entries: entries}) when map_size(entries) == 0 do
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
    ts = now(mem)

    {scores, active_count, pinned_count, oldest, newest} =
      Enum.reduce(mem.entries, {[], 0, 0, nil, nil}, fn {_key, entry},
                                                        {scores, active, pinned, oldest, newest} ->
        score = compute_score(mem, entry, ts)
        active = if score >= mem.eviction_threshold, do: active + 1, else: active
        pinned = if entry.pinned, do: pinned + 1, else: pinned

        oldest =
          if oldest == nil or DateTime.compare(entry.inserted_at, oldest) == :lt,
            do: entry.inserted_at,
            else: oldest

        newest =
          if newest == nil or DateTime.compare(entry.inserted_at, newest) == :gt,
            do: entry.inserted_at,
            else: newest

        {[score | scores], active, pinned, oldest, newest}
      end)

    sorted_scores = Enum.sort(scores)
    n = length(sorted_scores)

    %{
      size: map_size(mem.entries),
      active: active_count,
      pinned: pinned_count,
      oldest_entry: oldest,
      newest_entry: newest,
      mean_score: Enum.sum(sorted_scores) / n,
      median_score: median(sorted_scores, n)
    }
  end

  # Returns the current timestamp from the clock function or UTC now.
  @spec now(t()) :: DateTime.t()
  defp now(%__MODULE__{clock_fn: nil}), do: DateTime.utc_now()
  defp now(%__MODULE__{clock_fn: clock_fn}), do: clock_fn.()

  defp median(sorted, n) do
    tup = List.to_tuple(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      elem(tup, mid)
    else
      (elem(tup, mid - 1) + elem(tup, mid)) / 2.0
    end
  end

  defp insert_entry(%__MODULE__{} = mem, key, %Entry{} = entry) do
    next_key = if key == mem.next_key, do: mem.next_key + 1, else: mem.next_key
    %{mem | entries: Map.put(mem.entries, key, entry), next_key: next_key}
  end

  defp compute_score(%__MODULE__{} = mem, %Entry{} = entry, ts) do
    Lethe.Decay.compute(entry, ts, mem.decay_fn, half_life: mem.half_life)
  end

  defp update_entry(%__MODULE__{} = mem, key, fun) do
    case Map.fetch(mem.entries, key) do
      {:ok, entry} -> %{mem | entries: Map.put(mem.entries, key, fun.(entry))}
      :error -> mem
    end
  end

  # Evicts the single lowest-scored unpinned entry. No summarization —
  # the entry is being deleted immediately, so summarizing it is wasted work.
  defp maybe_evict_one(%__MODULE__{} = mem, ts) do
    unpinned =
      Enum.reject(mem.entries, fn {_key, entry} -> entry.pinned end)

    case unpinned do
      [] ->
        mem

      entries ->
        {victim_key, _victim} =
          Enum.min_by(entries, fn {_key, entry} -> compute_score(mem, entry, ts) end)

        %{mem | entries: Map.delete(mem.entries, victim_key)}
    end
  end

  # Classifies a single entry during evict/1: keep (maybe summarize) or evict.
  defp classify_for_eviction(_mem, key, %Entry{pinned: true} = entry, _ts, kept, evict_acc) do
    {[{key, entry} | kept], evict_acc}
  end

  defp classify_for_eviction(mem, key, entry, ts, kept, evict_acc) do
    score = compute_score(mem, entry, ts)
    entry = maybe_summarize_entry(mem, entry, score)

    if score >= mem.eviction_threshold do
      {[{key, entry} | kept], evict_acc}
    else
      {kept, [entry | evict_acc]}
    end
  end

  # Summarizes a single entry if eligible (below threshold, no existing summary).
  defp maybe_summarize_entry(%__MODULE__{summarize_fn: nil}, entry, _score), do: entry

  defp maybe_summarize_entry(%__MODULE__{} = mem, %Entry{} = entry, score) do
    if not entry.pinned and entry.summary == nil and score < mem.summarize_threshold do
      %{entry | summary: mem.summarize_fn.(entry)}
    else
      entry
    end
  end

  # Summarizes all eligible entries in the memory store.
  # Only called from summarize/1 which already guards against nil summarize_fn.
  defp maybe_summarize_entries(%__MODULE__{} = mem, ts) do
    updated_entries =
      Map.new(mem.entries, fn {key, entry} ->
        score = compute_score(mem, entry, ts)
        {key, maybe_summarize_entry(mem, entry, score)}
      end)

    %{mem | entries: updated_entries}
  end

  defp validate!(%__MODULE__{} = mem) do
    validate_pos_integer!(mem.max_entries, "max_entries")
    validate_pos_integer!(mem.half_life, "half_life")
    validate_decay_fn!(mem.decay_fn)
    validate_threshold!(mem.eviction_threshold, "eviction_threshold")
    validate_threshold!(mem.summarize_threshold, "summarize_threshold")
    validate_threshold_order!(mem.summarize_threshold, mem.eviction_threshold)
  end

  defp validate_pos_integer!(value, name) do
    unless is_integer(value) and value > 0 do
      raise ArgumentError, "#{name} must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp validate_decay_fn!(decay_fn) when is_function(decay_fn, 3), do: :ok

  defp validate_decay_fn!(decay_fn) do
    unless decay_fn in @builtin_decay_fns do
      raise ArgumentError,
            "decay_fn must be one of #{inspect(@builtin_decay_fns)} or a 3-arity function, got: #{inspect(decay_fn)}"
    end
  end

  defp validate_threshold!(value, name) do
    unless is_number(value) and value >= 0.0 and value <= 1.0 do
      raise ArgumentError, "#{name} must be in 0.0..1.0, got: #{inspect(value)}"
    end
  end

  defp validate_threshold_order!(summarize, eviction) do
    unless summarize >= eviction do
      raise ArgumentError,
            "summarize_threshold (#{summarize}) must be >= eviction_threshold (#{eviction})"
    end
  end

  defp validate_put_opts!(opts) do
    Enum.each(opts, fn {key, _value} ->
      unless key in @valid_put_opts do
        raise ArgumentError,
              "unknown option #{inspect(key)} for put/4, valid options: #{inspect(@valid_put_opts)}"
      end
    end)
  end
end
