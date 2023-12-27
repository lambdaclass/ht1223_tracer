defmodule Example do
  @dummy_list 0..100_000 |> Enum.to_list()

  def start do
    Tracer.run({__MODULE__, :dummy_load, []})
  end

  def dummy_load do
    @dummy_list
    |> Stream.with_index()
    |> Stream.map(fn {x, y} -> x * y end)
    |> Enum.reduce(0, fn x, acc -> x + acc end)
  end
end
