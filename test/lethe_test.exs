defmodule LetheTest do
  use ExUnit.Case
  doctest Lethe

  test "greets the world" do
    assert Lethe.hello() == :world
  end
end
