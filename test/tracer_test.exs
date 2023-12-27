defmodule TracerTest do
  use ExUnit.Case
  doctest Tracer

  test "greets the world" do
    assert Tracer.hello() == :world
  end
end
