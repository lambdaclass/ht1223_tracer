defmodule Example do
  @dummy_list 0..1_000_000 |> Enum.to_list()

  def start do
    {:ok, tracer} = Tracer.start_trace(self())
    dummy_load()
    Tracer.stop_trace(tracer)
  end

  defp dummy_load do
    @dummy_list
    |> Stream.with_index()
    |> Stream.map(fn {x, y} -> x * y end)
    |> Enum.reduce(0, fn x, acc -> x + acc end)
  end
end
