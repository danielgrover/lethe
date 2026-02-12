defimpl Enumerable, for: Lethe do
  alias Lethe.Decay

  def count(%Lethe{entries: entries}) do
    {:ok, map_size(entries)}
  end

  def member?(%Lethe{entries: entries}, %Lethe.Entry{key: key} = entry) do
    case Map.fetch(entries, key) do
      {:ok, ^entry} -> {:ok, true}
      _ -> {:ok, false}
    end
  end

  def member?(_mem, _value) do
    {:ok, false}
  end

  def reduce(%Lethe{} = mem, acc, fun) do
    # Snapshot now once for consistent scoring across all entries
    now = if mem.clock_fn, do: mem.clock_fn.(), else: DateTime.utc_now()
    opts = [half_life: mem.half_life]

    sorted_entries =
      mem.entries
      |> Map.values()
      |> Enum.map(fn entry ->
        {entry, Decay.compute(entry, now, mem.decay_fn, opts)}
      end)
      |> Enum.sort_by(fn {_entry, score} -> score end, :desc)
      |> Enum.map(fn {entry, _score} -> entry end)

    Enumerable.List.reduce(sorted_entries, acc, fun)
  end

  def slice(_mem) do
    {:error, __MODULE__}
  end
end
