defimpl Enumerable, for: Lethe do
  alias Lethe.Decay

  def count(%Lethe{entries: entries}) do
    {:ok, map_size(entries)}
  end

  def member?(%Lethe{entries: entries}, %Lethe.Entry{key: key}) do
    {:ok, Map.has_key?(entries, key)}
  end

  def member?(_mem, _value) do
    {:ok, false}
  end

  def reduce(%Lethe{} = mem, acc, fun) do
    now = Lethe.now(mem)
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
