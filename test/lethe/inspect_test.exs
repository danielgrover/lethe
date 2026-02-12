defmodule Lethe.InspectTest do
  use ExUnit.Case, async: true

  test "inspect shows size, max_entries, and decay_fn" do
    mem = Lethe.new() |> Lethe.put(:a, "1") |> Lethe.put(:b, "2")
    result = inspect(mem)

    assert result =~ "#Lethe<"
    assert result =~ "size: 2"
    assert result =~ "max_entries: 100"
    assert result =~ "decay_fn: :combined"
  end

  test "inspect for empty memory" do
    result = inspect(Lethe.new())
    assert result =~ "size: 0"
  end
end
