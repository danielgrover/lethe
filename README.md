# Lethe

Bounded, relevance-aware storage with time-based and access-based decay for Elixir.

Entries lose relevance over time unless reinforced through access or marked as important. Think of it as a smarter alternative to ring buffers or LRU caches — instead of blindly dropping the oldest item, Lethe keeps what's still relevant.

Named after the river of forgetfulness in Greek mythology: memories that aren't reinforced drift away.

## Installation

Add `lethe` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:lethe, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Create a memory store
mem = Lethe.new(max_entries: 100, half_life: :timer.hours(1))

# Add entries
mem = Lethe.put(mem, :insight, "Client prefers async communication")
mem = Lethe.put(mem, :alert, "Price spike detected", importance: 1.5)
mem = Lethe.put(mem, :rule, "Never auto-deploy on Fridays", pinned: true)

# Read entries — get/2 refreshes decay (rehearsal), peek/2 doesn't
{{:ok, entry}, mem} = Lethe.get(mem, :insight)
{:ok, entry} = Lethe.peek(mem, :alert)

# Query by relevance
active_entries = Lethe.active(mem)           # above eviction threshold
top_5 = Lethe.top(mem, 5)                    # 5 highest-scored
scored = Lethe.scored(mem)                   # [{entry, score}, ...] sorted desc

# Scores decay over time — entries you don't access fade away
# Pinned entries always score 1.0
# When max_entries is reached, the lowest-scored unpinned entry is evicted
```

## Core Concepts

### Decay Scores

Every entry has a computed score between 0.0 and 1.0. Fresh or recently accessed entries score near 1.0. Old, untouched entries drift toward 0.0. Scores are computed on read, not stored — they're a function of the entry's metadata and the current time.

### Rehearsal: `get` vs `peek`

This is the library's key semantic distinction:

- **`get/2`** retrieves an entry and refreshes its decay — like rehearsing a memory keeps it alive. It updates `last_accessed_at` and increments `access_count`.
- **`peek/2`** retrieves an entry without affecting its decay — a read-only observation.

Choose based on whether the access should count as reinforcement.

### Pinned Entries

Entries marked `pinned: true` always score 1.0 and are never automatically evicted. They still count against `max_entries` and can be explicitly deleted or unpinned.

```elixir
mem = Lethe.put(mem, :critical, "important insight", pinned: true)
mem = Lethe.pin(mem, :existing_key)
mem = Lethe.unpin(mem, :existing_key)
```

### Importance

A multiplier on the decay score. The default is 1.0. Higher values slow decay; lower values accelerate it. The final score is always clamped to 0.0..1.0.

```elixir
mem = Lethe.put(mem, :key, "value", importance: 1.5)  # decays slower
mem = Lethe.put(mem, :key, "value", importance: 0.5)  # decays faster
```

### Eviction

When `max_entries` is reached and a new entry is added, the lowest-scored unpinned entry is evicted automatically. If all entries are pinned, the new entry is silently dropped.

You can also evict manually:

```elixir
{mem, evicted_entries} = Lethe.evict(mem)
```

## Decay Functions

Three built-in decay functions, selected via the `:decay_fn` option:

### `:exponential`

Pure time-based exponential decay from last access. With a 1-hour half-life, an untouched entry scores ~0.5 after 1 hour, ~0.25 after 2 hours.

### `:access_weighted`

Exponential decay boosted by access frequency. Entries accessed more often decay slower.

### `:combined` (default)

ACT-R inspired model blending recency and frequency through a sigmoid normalization. Accounts for both time since last access and total access count relative to age. This is the most nuanced option and the default.

```elixir
Lethe.new(decay_fn: :exponential, half_life: :timer.hours(2))
```

### Custom

You can provide a custom 3-arity function that receives the entry, current time, and options (including `:half_life`). Return a raw score — importance multiplication and clamping to 0.0..1.0 are applied automatically.

```elixir
Lethe.new(decay_fn: fn entry, now, _opts ->
  seconds = DateTime.diff(now, entry.last_accessed_at)
  max(1.0 - seconds / 3600, 0.0)
end)
```

## API Overview

### Creating and Configuring

```elixir
mem = Lethe.new(
  max_entries: 100,               # hard cap (default: 100)
  decay_fn: :combined,            # :exponential | :access_weighted | :combined | custom fn
  half_life: :timer.hours(1),     # decay half-life in ms (default: 3,600,000)
  eviction_threshold: 0.05,       # entries below this are evicted (default: 0.05)
  summarize_threshold: 0.15,      # entries below this are summarized (default: 0.15)
  summarize_fn: nil,              # fn entry -> summary (default: nil)
  clock_fn: nil                   # fn -> DateTime.t() for testing (default: nil)
)
```

### Writing

```elixir
mem = Lethe.put(mem, "auto-keyed value")
mem = Lethe.put(mem, :key, "explicit key")
mem = Lethe.put(mem, :key, "value", importance: 1.5, pinned: true, metadata: %{source: :api})
mem = Lethe.update(mem, :key, "new value")        # update value, refresh access
mem = Lethe.touch(mem, :key)                       # refresh access without changing value
mem = Lethe.touch(mem, :key, importance: 2.0)      # refresh + update importance
mem = Lethe.delete(mem, :key)
mem = Lethe.clear(mem)                             # remove all entries, keep config
```

### Reading

```elixir
{{:ok, entry}, mem} = Lethe.get(mem, :key)         # rehearsal (refreshes decay)
{:ok, entry} = Lethe.peek(mem, :key)               # no side effects
:error = Lethe.peek(mem, :missing)
```

### Scoring and Querying

```elixir
score = Lethe.score(mem, :key)                     # float | :error
scored = Lethe.scored(mem)                         # [{entry, score}] sorted desc
map = Lethe.score_map(mem)                         # %{key => score}

entries = Lethe.active(mem)                        # above eviction_threshold
entries = Lethe.above(mem, 0.3)                    # above custom threshold
entries = Lethe.top(mem, 10)                       # N highest-scored
entries = Lethe.filter(mem, &(&1.metadata[:source] == :api))
```

### Counting and Stats

```elixir
Lethe.size(mem)                                    # total entries
Lethe.active_count(mem)                            # entries above eviction threshold
Lethe.pinned_count(mem)                            # pinned entries
Lethe.keys(mem)                                    # all keys
Lethe.has_key?(mem, :key)                          # key exists?

Lethe.stats(mem)
# => %{
#   size: 42,
#   active: 28,
#   pinned: 3,
#   oldest_entry: ~U[2026-02-10 08:00:00Z],
#   newest_entry: ~U[2026-02-11 15:30:00Z],
#   mean_score: 0.34,
#   median_score: 0.22
# }
```

## Summarization

When an entry's score drops below `summarize_threshold`, Lethe can call a `summarize_fn` to compress it before eviction. The original value is preserved; the summary is stored in `entry.summary`.

```elixir
mem = Lethe.new(
  summarize_threshold: 0.15,
  eviction_threshold: 0.05,
  summarize_fn: fn entry ->
    String.slice(entry.value, 0, 100) <> "..."
  end
)
```

The lifecycle: **active** (score > summarize_threshold) -> **summarized** (summarize_fn called, summary stored) -> **evicted** (score < eviction_threshold, removed).

Summarization happens during `evict/1` and can also be triggered explicitly:

```elixir
mem = Lethe.summarize(mem)                         # summarize eligible entries
{mem, evicted} = Lethe.evict(mem)                  # summarize + evict
```

Pinned entries are never summarized. Entries are only summarized once (skipped if `summary` is already populated).

## Protocols

Lethe implements `Enumerable`, `Inspect`, and `Collectable`.

### Enumerable

Enumerates entries sorted by decay score descending:

```elixir
Enum.take(mem, 5)                                  # top 5 entries
Enum.map(mem, & &1.value)                          # all values by relevance
Enum.count(mem)                                    # entry count

for entry <- mem, entry.pinned, do: entry.key      # comprehensions work
```

### Collectable

Build a Lethe from key-value pairs:

```elixir
mem = Enum.into([{:a, "1"}, {:b, "2"}], Lethe.new())

mem = for i <- 1..10, into: Lethe.new() do
  {:"item_#{i}", "value #{i}"}
end
```

### Inspect

```elixir
inspect(mem)
# => #Lethe<%{decay_fn: :combined, max_entries: 100, size: 42}>
```

## Testing

Lethe supports clock injection for deterministic time-dependent tests:

```elixir
test "entries decay over time" do
  ref = make_ref()
  base = ~U[2026-01-01 00:00:00Z]
  :persistent_term.put(ref, base)

  mem = Lethe.new(
    clock_fn: fn -> :persistent_term.get(ref) end,
    decay_fn: :exponential
  )

  mem = Lethe.put(mem, :k, "value")
  assert Lethe.score(mem, :k) > 0.99

  # Advance 1 hour (= half_life)
  :persistent_term.put(ref, DateTime.add(base, 3600, :second))
  assert_in_delta Lethe.score(mem, :k), 0.5, 0.01

  :persistent_term.erase(ref)
end
```

## Serializability

The `%Lethe{}` struct stores `:decay_fn` as an atom when using built-in functions (always safe to serialize). `:clock_fn`, `:summarize_fn`, and custom `:decay_fn` functions are anonymous functions that cannot be serialized. To serialize:

1. Set any function fields to `nil` (or a built-in atom for `:decay_fn`) before serializing
2. Re-attach them after deserialization

```elixir
# Serialize (using a built-in decay_fn)
serializable = %{mem | clock_fn: nil, summarize_fn: nil}
binary = :erlang.term_to_binary(serializable)

# Deserialize
mem = :erlang.binary_to_term(binary)
mem = %{mem | clock_fn: my_clock_fn, summarize_fn: my_summarize_fn}
```

## Design Principles

- **Zero runtime dependencies.** Only Elixir standard library.
- **Immutable.** Every operation returns a new struct. Wrap in a GenServer or ETS for concurrent access.
- **Lazy eviction.** Entries aren't evicted on every operation — only when capacity is reached or `evict/1` is called.
- **Scores always 0.0..1.0.** Pinned entries return 1.0. Importance-weighted scores are clamped.
- **Size never exceeds `max_entries`.** This is a hard invariant enforced on every `put`.

## License

MIT
