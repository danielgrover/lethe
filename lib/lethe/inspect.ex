defimpl Inspect, for: Lethe do
  import Inspect.Algebra

  def inspect(%Lethe{} = mem, opts) do
    info = %{
      size: map_size(mem.entries),
      max_entries: mem.max_entries,
      decay_fn: mem.decay_fn
    }

    concat(["#Lethe<", to_doc(info, opts), ">"])
  end
end
