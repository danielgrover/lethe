defimpl Collectable, for: Lethe do
  def into(%Lethe{} = mem) do
    collector = fn
      acc, {:cont, {key, value}} -> Lethe.put(acc, key, value)
      acc, {:cont, {key, value, opts}} -> Lethe.put(acc, key, value, opts)
      acc, :done -> acc
      _acc, :halt -> :ok
    end

    {mem, collector}
  end
end
