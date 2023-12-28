defmodule TracerTest do
  use ExUnit.Case
  doctest Tracer

  test "run example" do
    Tracer.run({__MODULE__, :dummy_load, []})
  end

  @dummy_list 0..100_000 |> Enum.to_list()

  def dummy_load do
    @dummy_list
    |> Stream.with_index()
    |> Stream.map(fn {x, y} -> x * y end)
    |> Enum.reduce(0, fn x, acc -> x + acc end)
  end
end
