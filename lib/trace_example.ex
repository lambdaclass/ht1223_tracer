defmodule Example do
  @dummy_list 0..1000 |> Enum.to_list()

  def start do
    tracee = spawn(fn -> dummy_load() end)
    Tracer.trace(tracee)
  end

  defp dummy_load do
    @dummy_list
    |> Stream.with_index()
    |> Stream.map(fn {x, y} -> x * y end)
    |> Enum.reduce(0, fn x, acc -> x + acc end)

    dummy_load()
  end
end
