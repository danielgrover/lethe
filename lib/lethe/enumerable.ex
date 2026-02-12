defimpl Enumerable, for: Lethe do
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
    entries = Enum.map(Lethe.scored(mem), fn {entry, _score} -> entry end)
    Enumerable.List.reduce(entries, acc, fun)
  end

  def slice(_mem) do
    {:error, __MODULE__}
  end
end
