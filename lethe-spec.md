# Lethe — Memory with Decay Library Specification

## What This Document Is

A specification for a standalone Elixir library that provides a memory data structure with time-based and access-based decay. Entries lose relevance over time unless reinforced. The library is not Hutch-specific — it solves a general problem (bounded, relevance-aware storage) that applies to agents, caches, session state, and any system that needs "recent context" without unbounded growth.

The primary consumer is Hutch's agent memory system, but the library should be useful independently.

## The Problem

Any long-running system that accumulates state faces the same question: what do you keep, what do you discard, and how do you decide? The naive approaches all have problems:

- **Keep everything** — unbounded growth. Eventually you're storing (and searching through, and paying tokens for) things that stopped being relevant months ago.
- **Fixed-size ring buffer** — drops the oldest item regardless of importance. A critical insight from 3 hours ago gets evicted because 100 routine items came after it.
- **Manual cleanup** — requires the consumer to implement their own relevance logic. Everyone does this differently and usually badly.

What we want: a data structure where entries naturally lose relevance over time, important things stick around longer, recently accessed things stay warm, and the whole thing stays bounded without manual intervention.

This maps directly to how human working memory operates. Items decay unless rehearsed (re-accessed) or marked as notable. The cognitive science grounding is ACT-R's activation-based memory model: each memory element has an activation level that decays logarithmically with time but gets boosted by access.

## Core Concepts

### Decay Score

Every entry has a **decay score** between 0.0 and 1.0. Score 1.0 means fully relevant (just inserted or just accessed). Score 0.0 means fully decayed (ready for eviction or summarization). The score is computed, not stored — it's a function of the entry's metadata and the current time.

```
decay_score(entry, now) → float in 0.0..1.0
```

The decay function is configurable per-memory instance. The library provides built-in decay functions and supports custom ones.

### Built-in Decay Functions

**Time-based exponential decay.** Score decreases exponentially from insertion (or last access). Half-life is configurable.

```
score = :math.exp(-lambda * seconds_since_last_touch)
# where lambda = :math.log(2) / half_life_seconds
```

With a 1-hour half-life: an item untouched for 1 hour has score ~0.5, untouched for 2 hours ~0.25, untouched for 4 hours ~0.06.

**Access-frequency weighted.** Items accessed more frequently decay more slowly. Each access boosts the item's effective "last touch" time.

```
score = :math.exp(-lambda * seconds_since_last_access) * frequency_boost(access_count)
```

**Combined (default).** Blends time since insertion, time since last access, and access count. This is the ACT-R-inspired model:

```
# Base-level activation (simplified ACT-R)
# Each access j contributes t_j^(-d) where t_j is time since access j, d is decay rate
activation = Enum.sum(for t <- access_times, do: :math.pow(t, -decay_rate))
score = sigmoid(activation - threshold)
```

### Entry Structure

Each entry in the memory stores:

```elixir
%Entry{
  key: term(),                    # unique identifier (optional — can be auto-generated)
  value: term(),                  # the actual content
  inserted_at: DateTime.t(),      # when the entry was added
  last_accessed_at: DateTime.t(), # when the entry was last read/touched
  access_count: non_neg_integer(),# how many times it's been accessed
  pinned: boolean(),              # exempt from decay (never evicted automatically)
  importance: float(),            # 0.0..1.0, multiplier on decay score
  metadata: map(),                # arbitrary consumer-provided metadata
  summary: term() | nil           # compressed version (populated by summarization hook)
}
```

### Pinned Entries

Some things should never decay. An agent's "I learned that client X always pays late" insight is worth remembering indefinitely. Pinned entries have an effective decay score of 1.0 regardless of age or access patterns. They still count against capacity limits and can be explicitly unpinned or removed.

### Importance

A multiplier on the decay score. An entry with `importance: 1.0` decays at the normal rate. An entry with `importance: 0.5` decays twice as fast (its score is halved). An entry with `importance: 2.0` would produce scores above 1.0, which get clamped — effectively it decays much slower than normal.

The raw computation is `decay_score(entry) * importance`, clamped to the 0.0..1.0 range. So an entry with `importance: 2.0` and a raw decay score of 0.4 gets an effective score of 0.8, not 0.8 unclamped. An entry with `importance: 2.0` and raw score of 0.7 gets clamped to 1.0, not 1.4. Scores are always in 0.0..1.0.

Importance is set at insertion time (or updated later). The consumer decides what's important. In a Hutch agent, challenge outcomes might get `importance: 1.5` while routine inputs get `importance: 0.8`.

## Public API

### Creating a Memory

```elixir
# Minimal — defaults for everything
mem = Lethe.new()

# Configured
mem = Lethe.new(
  max_entries: 1000,              # hard cap on entry count
  decay_fn: :exponential,         # :exponential | :access_weighted | :combined | custom fn
  half_life: :timer.hours(1),     # for exponential decay
  eviction_threshold: 0.05,       # entries below this score get evicted
  summarize_threshold: 0.15,      # entries below this score get summarized before eviction
  summarize_fn: nil,              # fn entry -> summary_term (optional, see Summarization)
  clock_fn: nil                   # fn -> DateTime.t() — injectable clock for testing
)
```

### Adding Entries

```elixir
# Basic — key is auto-generated
mem = Lethe.put(mem, "Price spike detected for AAPL at $195.50")

# With key
mem = Lethe.put(mem, :last_challenge,
  "Challenged PriceFetcher on stale data — confirmed, data was 5 min old")

# With options
mem = Lethe.put(mem, :client_insight,
  "Client X prefers async communication, dislikes meetings",
  importance: 1.5,
  pinned: true,
  metadata: %{source: :human_input, client_id: "client_x"}
)
```

When `max_entries` is reached and a new entry is added, the entry with the lowest decay score is evicted (after summarization if configured).

### Reading Entries

```elixir
# Get a specific entry by key (touches it — resets last_accessed_at, increments access_count)
{:ok, entry} = Lethe.get(mem, :last_challenge)

# Get without touching (peek — doesn't affect decay)
{:ok, entry} = Lethe.peek(mem, :last_challenge)

# Get all active entries (above eviction threshold), sorted by decay score descending
entries = Lethe.active(mem)

# Get all entries above a custom score threshold
entries = Lethe.above(mem, 0.3)

# Get the N most relevant entries
entries = Lethe.top(mem, 10)
```

**Important:** `get/2` is a "rehearsal" — it refreshes the entry's decay, keeping it alive longer. This mirrors cognitive rehearsal in working memory. `peek/2` observes without affecting decay. The consumer chooses which to use based on whether the access should count as reinforcement.

### Updating Entries

```elixir
# Update value (resets last_accessed_at)
mem = Lethe.update(mem, :last_challenge, "Updated: challenge was resolved as false alarm")

# Update importance
mem = Lethe.touch(mem, :some_key, importance: 1.8)

# Pin/unpin
mem = Lethe.pin(mem, :critical_insight)
mem = Lethe.unpin(mem, :critical_insight)
```

### Removing Entries

```elixir
# Explicit removal
mem = Lethe.delete(mem, :some_key)

# Evict all entries below threshold (normally automatic, but available manually)
{mem, evicted} = Lethe.evict(mem)

# Clear everything
mem = Lethe.clear(mem)
```

### Querying

```elixir
# Count
Lethe.size(mem)           # total entries
Lethe.active_count(mem)   # entries above eviction threshold
Lethe.pinned_count(mem)   # pinned entries

# Stats
Lethe.stats(mem)
# => %{
#   size: 847,
#   active: 312,
#   pinned: 5,
#   oldest_entry: ~U[2026-02-10 08:00:00Z],
#   newest_entry: ~U[2026-02-11 15:30:00Z],
#   mean_score: 0.34,
#   median_score: 0.22
# }

# Filter by metadata
entries = Lethe.filter(mem, fn entry ->
  entry.metadata[:source] == :challenge_outcome
end)
```

### Decay Score Access

This is the critical integration point with Winnow.

```elixir
# Get the current decay score for a single entry
score = Lethe.score(mem, :some_key)
# => 0.73

# Get all entries with their current scores
scored = Lethe.scored(mem)
# => [{entry, 0.95}, {entry, 0.73}, {entry, 0.41}, ...] sorted by score desc

# Get entries with scores as a map (for batch processing)
score_map = Lethe.score_map(mem)
# => %{key1 => 0.95, key2 => 0.73, ...}
```

## Summarization

When an entry's decay score drops below `summarize_threshold` (but is still above `eviction_threshold`), the library calls the configured `summarize_fn` before the entry transitions to its compressed form. This is a hook — the library doesn't do summarization itself.

```elixir
mem = Lethe.new(
  summarize_threshold: 0.15,
  eviction_threshold: 0.05,
  summarize_fn: fn entry ->
    # This could be an LLM call, a simple truncation, or any transformation
    # The return value replaces entry.value; the original moves to entry.summary
    String.slice(entry.value, 0, 100) <> "..."
  end
)
```

The lifecycle of an entry:

```
[inserted, score ~1.0]
    │
    ▼ (time passes, no access)
[active, score 0.5..1.0]
    │
    ▼ (score drops below summarize_threshold)
[summarized — summarize_fn called, compressed value stored]
    │
    ▼ (score drops below eviction_threshold)
[evicted — removed from memory]
```

If no `summarize_fn` is configured, entries go directly from active to evicted.

For Hutch agents, the `summarize_fn` is where you'd call the LLM to compress a detailed memory into a one-line summary. This is expensive, so it only happens as entries are aging out — not on every access.

```elixir
# Example summarize_fn for a Hutch agent
summarize_fn: fn entry ->
  {:ok, summary} = ReqLLM.generate_text("anthropic:claude-3-5-haiku",
    "Summarize this agent memory entry in one sentence: #{entry.value}")
  summary
end
```

## Integration with Winnow

This is the primary integration point and the reason both libraries exist. Winnow decides what fits in a single LLM call. Lethe decides what's still relevant across the agent's lifetime. They connect through decay scores becoming Winnow priorities.

### The Pattern

```elixir
defmodule MyAgent do
  use Hutch.Agent

  @impl true
  def handle_input(data, state) do
    # 1. Get memory entries with their decay scores
    memory_entries = Lethe.scored(state.memory)

    # 2. Build the dynamic part of the prompt using Winnow
    dynamic =
      Winnow.new(budget: 0)  # budget doesn't matter — merge/2 uses left's budget
      |> Winnow.add(:user, priority: 900, content: format_input(data))
      |> Winnow.add_each(:user,
          items: memory_entries,
          priority_fn: fn {_entry, score}, _index ->
            # Decay score (0.0-1.0) mapped to priority range (100-600)
            trunc(score * 500) + 100
          end,
          formatter: fn {entry, _score} ->
            "Previous: #{entry.value}"
          end)

    # 3. Merge with the base prompt (system prompt, tools, response reservation)
    result =
      state.base_winnow
      |> Winnow.merge(dynamic)
      |> Winnow.render()

    # 4. Call the LLM
    response = ReqLLM.generate_text(state.model, result.messages)

    # 5. Store result in memory
    mem = Lethe.put(state.memory, response.content,
      metadata: %{input: data, timestamp: DateTime.utc_now()})

    {:write, :my_representation, output, %{state | memory: mem}}
  end
end
```

### Why This Works

The decay score is a natural priority signal. A memory entry that was created 5 minutes ago and accessed twice has a high decay score — it's clearly relevant, so it should have a high priority in the prompt. An entry from yesterday that hasn't been accessed since has a low decay score — include it only if there's room.

The mapping function (`fn {_entry, score}, _index -> trunc(score * 500) + 100 end`) is the consumer's decision. Different agents might map scores to priorities differently:

- An agent where history matters a lot: `trunc(score * 700) + 200` (memory competes with current input)
- An agent where only the latest matters: `trunc(score * 200) + 50` (memory is low priority, only included if there's lots of room)
- An agent where challenge history is critical: filter to challenge entries, boost their priority range

Winnow doesn't know about decay. Lethe doesn't know about token budgets. The consumer wires them together with a mapping function. This keeps both libraries focused and independently testable.

### Memory Sections in Winnow

For agents with multiple memory categories (recent inputs, challenge history, contacts), use Winnow sections to allocate sub-budgets:

```elixir
dynamic =
  Winnow.new(budget: 0)
  |> Winnow.section(:memory_inputs, max_tokens: 3000)
  |> Winnow.section(:memory_challenges, max_tokens: 1500)
  |> Winnow.add(:user, priority: 900, content: format_input(data))
  |> Winnow.add_each(:user,
      items: Lethe.scored(state.memory.recent_inputs),
      section: :memory_inputs,
      priority_fn: fn {_e, score}, _i -> trunc(score * 500) + 100 end,
      formatter: &format_input_memory/1)
  |> Winnow.add_each(:user,
      items: Lethe.scored(state.memory.challenges),
      section: :memory_challenges,
      priority_fn: fn {_e, score}, _i -> trunc(score * 500) + 200 end,
      formatter: &format_challenge_memory/1)
```

This ensures challenge history doesn't crowd out recent inputs (or vice versa), even if one category has many more entries.

### Fallback Integration

When an entry has been summarized (decay score between `summarize_threshold` and `eviction_threshold`), you can use Winnow's fallback mechanism:

```elixir
Winnow.add_each(:user,
  items: Lethe.scored(state.memory),
  priority_fn: fn {_e, score}, _i -> trunc(score * 500) + 100 end,
  formatter: fn {entry, _score} ->
    case entry.summary do
      nil -> format_full(entry)        # No summary yet — use full content
      _   -> format_full(entry)        # Primary: full content
    end
  end,
  fallback_fn: fn {entry, _score} ->
    case entry.summary do
      nil -> nil                        # No fallback available
      sum -> format_summary(entry, sum) # Fallback: use the summary
    end
  end
)
```

If the full content doesn't fit in the budget, Winnow tries the summary. If neither fits, the entry is dropped. This creates a three-tier degradation: full → summarized → absent.

## Integration with Hutch.Agent

Hutch's agent memory system (from the API speculative design) uses multiple memory categories:

```elixir
%Hutch.Memory{
  recent_inputs: ...,         # last N inputs processed
  recent_outputs: ...,        # last N outputs produced
  challenges_sent: ...,       # with outcomes and timestamps
  challenges_received: ...,   # with responses and timestamps
  escalations: ...,           # blackboard escalations
  notable_events: ...,        # agent-determined "worth remembering"
  contacts: %{}               # learned direct references (organic service discovery)
}
```

The current design uses ring buffers (fixed-size, drop oldest). Lethe replaces ring buffers for the categories where relevance matters more than recency:

| Category | Current Design | With Lethe | Rationale |
|----------|---------------|-----------------|-----------|
| `recent_inputs` | Ring buffer (100) | **Lethe** | A critical anomalous input from 2 hours ago is more relevant than 50 routine inputs from the last 30 minutes |
| `recent_outputs` | Ring buffer (100) | **Lethe** | Same reasoning — outputs associated with challenges or corrections should persist longer |
| `challenges_sent` | List | **Lethe** with `importance: 1.5` | Challenge outcomes are high-value memories; should decay slower |
| `challenges_received` | List | **Lethe** with `importance: 1.5` | Same |
| `escalations` | List | **Lethe** with `importance: 1.3` | Escalation patterns are informative but less critical than challenge outcomes |
| `notable_events` | List | **Lethe** with `pinned: true` | Agent-flagged notable events should never auto-evict |
| `contacts` | Map | **Keep as map** | Contacts are structural, not temporal. Decay doesn't apply — a contact is either valid or removed. |

The `Hutch.Memory` struct would hold multiple `Lethe` instances, each configured for its category:

```elixir
%Hutch.Memory{
  inputs: Lethe.new(
    max_entries: 500,
    half_life: :timer.hours(2),
    summarize_fn: &summarize_input/1
  ),
  outputs: Lethe.new(
    max_entries: 500,
    half_life: :timer.hours(2)
  ),
  challenges: Lethe.new(
    max_entries: 200,
    half_life: :timer.hours(8),   # challenges are worth remembering longer
    eviction_threshold: 0.02       # keep them around longer
  ),
  notable: Lethe.new(
    max_entries: 100                # all entries expected to be pinned
  ),
  contacts: %{}                     # plain map, not Lethe
}
```

### Pool Memory

The Hutch API design specifies that agent pools (horizontal scaling) share memory across instances. Lethe itself is an immutable struct — it doesn't handle concurrency. For pool-shared memory, the consumer wraps a Lethe in a shared process (GenServer or ETS-backed):

```elixir
# Pool memory: single Lethe instance behind a GenServer, shared by all pool members
defmodule Hutch.PoolMemory do
  use GenServer

  def put(pool, key, value, opts \\ []) do
    GenServer.call(pool, {:put, key, value, opts})
  end

  def scored(pool) do
    GenServer.call(pool, :scored)
  end

  # GenServer holds the Lethe struct as state
  def handle_call({:put, key, value, opts}, _from, mem) do
    mem = Lethe.put(mem, key, value, opts)
    {:reply, :ok, mem}
  end

  def handle_call(:scored, _from, mem) do
    {:reply, Lethe.scored(mem), mem}
  end
end
```

This is Hutch's responsibility, not the library's. Lethe provides the data structure and algorithms; the Hutch framework provides the concurrency wrapper. The separation means Lethe stays simple and testable (pure functions on immutable data), while pool behavior is handled at the framework level where it belongs.

## What the Library Does NOT Do

These are explicit non-goals:

- **Persistence.** Lethe is in-memory only. Persisting to disk, database, or across restarts is the consumer's responsibility. The library should be serializable (all state is data, no pids or refs in the struct), but it doesn't manage persistence itself.
- **Concurrency.** The struct is immutable — every operation returns a new struct. If you need concurrent access (e.g., agent pools sharing memory), wrap it in a GenServer or use ETS. The library doesn't make that choice for you.
- **LLM calls.** The `summarize_fn` hook accepts any function. It doesn't import ReqLLM or any LLM library. The consumer provides the summarization logic.
- **Prompt composition.** That's Winnow's job. Lethe provides scored entries; Winnow decides what fits.
- **Semantic similarity.** Entries are keyed and scored by temporal/access patterns, not by content similarity. Semantic retrieval (RAG-style) is a different problem. Could be layered on top but is not built in.

## Design Decisions for the Implementer

### 1. Lazy vs. Eager Eviction

**Recommendation: Lazy.** Don't run eviction on every operation. Compute scores on read (`active/1`, `scored/1`, `top/2`). Evict only when: (a) `max_entries` is reached and a new entry is being added, or (b) `evict/1` is called explicitly, or (c) optionally on a configurable periodic sweep.

This keeps writes fast (just append) and avoids unnecessary computation when nobody is reading.

### 2. Clock Injection

**Required for testing.** The decay score depends on the current time. The library must accept an injectable clock function (`clock_fn` in config) so tests can control time. Default: `DateTime.utc_now/0`.

```elixir
# In tests
clock = fn -> DateTime.add(~U[2026-02-11 12:00:00Z], @elapsed, :second) end
mem = Lethe.new(clock_fn: clock)
```

### 3. Score Caching

Decay scores are computed on access, not stored. This means `scored/1` on a 1000-entry memory computes 1000 scores. For most use cases this is fine (float math is fast). If it becomes a bottleneck, consider caching scores with a TTL (recompute if last computation was more than N seconds ago).

### 4. Struct vs. Protocol

**Recommendation: Start with a struct.** `Lethe` is a struct with a clean function-based API. If we later need multiple backing stores (ETS-backed, distributed), extract a protocol then. Don't over-abstract upfront.

### 5. Enumerable Protocol

**Implement `Enumerable`.** `Lethe` should be enumerable, yielding entries sorted by decay score descending. This makes it composable with `Enum` and `Stream` functions, and plays nicely with `Winnow.add_each/3` which accepts any enumerable.

```elixir
# This should work
mem
|> Enum.take(10)
|> Enum.map(& &1.value)
```

### 6. Entry Keys

Keys are optional. If provided, they enable `get/2`, `update/3`, `delete/2` by key. If not provided, an auto-generated key is assigned (monotonic integer or reference). Some use cases (like a simple "recent inputs" buffer) don't need keys — entries are just appended and consumed by score.

## Testing Strategy

- **Unit tests for decay functions.** Given an entry with known timestamps and access counts, verify the score computation is correct. Test edge cases: zero elapsed time, very large elapsed time, many accesses, no accesses.
- **Property-based tests.** Scores are always in 0.0..1.0 (or 1.0 for pinned). Scores decrease monotonically with time (for entries with no new accesses). `size/1` never exceeds `max_entries`. `active/1` never returns entries below `eviction_threshold`.
- **Clock injection tests.** Advance time, verify entries decay as expected. Verify `get/2` refreshes decay. Verify `peek/2` doesn't.
- **Summarization tests.** Verify `summarize_fn` is called when score crosses `summarize_threshold`. Verify it's called exactly once per entry. Verify the summary is stored.
- **Eviction tests.** Verify lowest-scored entry is evicted when `max_entries` is reached. Verify pinned entries are never auto-evicted. Verify eviction happens after summarization (if configured).
- **Integration tests with Winnow.** Create a Lethe with known entries, pipe through `scored/1` into `Winnow.add_each/3`, verify that high-decay-score entries get higher Winnow priorities and appear in the rendered output.

## Cognitive Science Grounding

For reference, the cognitive science concepts this library implements:

- **ACT-R base-level activation** (Anderson, 1993): Memory activation = sum of recency-weighted access history. Items accessed recently and frequently have higher activation. Our decay score is a simplified version of this.
- **Working memory rehearsal** (Baddeley, 1986): Accessing an item refreshes its availability. Our `get/2` (vs. `peek/2`) distinction captures this — "using" a memory keeps it alive.
- **Chunking** (Miller, 1956): Summarization compresses detailed memories into compact chunks. The `summarize_fn` hook enables this.
- **Importance weighting**: Not directly from a single cognitive theory, but reflects the general principle that emotionally significant or goal-relevant memories persist longer. Our `importance` field is this.
- **Long-term vs. working memory boundary**: Pinned entries are analogous to memories that have been consolidated into long-term storage — they don't decay with time. Unpinned entries are working memory — transient, capacity-limited, decay-prone.

## Summary

| Aspect | Decision |
|--------|----------|
| **Name** | Lethe (the river of forgetfulness — memories that aren't reinforced drift away) |
| **Scope** | Standalone hex package, not Hutch-namespaced |
| **Core abstraction** | Bounded collection where entries have computed decay scores based on time, access, and importance |
| **Decay functions** | Exponential (default), access-weighted, combined (ACT-R inspired), custom |
| **Key operations** | `put`, `get` (rehearsal), `peek` (no rehearsal), `active`, `scored`, `top`, `pin`, `evict` |
| **Summarization** | Hook-based (`summarize_fn`). Called when score crosses threshold. Consumer provides the function. |
| **Winnow integration** | `scored/1` returns `[{entry, score}]` pairs. Consumer maps scores to Winnow priorities via `priority_fn`. |
| **Hutch integration** | Replaces ring buffers in `Hutch.Memory` for categories where relevance > pure recency. Multiple instances per agent, one per memory category. |
| **Concurrency** | Immutable struct. Consumer wraps in GenServer/ETS for concurrent access. |
| **Persistence** | Not included. Struct is serializable. Consumer handles persistence. |
| **Testing** | Clock injection required. Property-based tests for score invariants. |
