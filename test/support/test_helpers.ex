defmodule Lethe.TestHelpers do
  @moduledoc false

  import ExUnit.Callbacks, only: [on_exit: 1]

  @base_time ~U[2026-01-01 00:00:00Z]

  @doc """
  Creates a Lethe with a mutable clock backed by persistent_term.
  Automatically registers cleanup via on_exit.

  Returns `{mem, ref, base_time}`.
  """
  def new_mem_with_clock(opts \\ []) do
    ref = :erlang.make_ref()
    :persistent_term.put(ref, @base_time)
    on_exit(fn -> :persistent_term.erase(ref) end)

    mem =
      Lethe.new([clock_fn: fn -> :persistent_term.get(ref) end, decay_fn: :exponential] ++ opts)

    {mem, ref, @base_time}
  end

  @doc """
  Creates a Lethe with a fixed (non-mutable) clock. No cleanup needed.
  """
  def new_mem(opts \\ []) do
    Lethe.new([clock_fn: fn -> @base_time end] ++ opts)
  end

  @doc """
  Advances the mutable clock to `base + seconds`.
  """
  def advance_clock(ref, base, seconds) do
    :persistent_term.put(ref, DateTime.add(base, seconds, :second))
  end
end
