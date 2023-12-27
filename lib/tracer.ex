defmodule Tracer do
  @moduledoc """
  Documentation for `Tracer`.
  """

  @doc """
  Hello world.

  ## Examples

      iex> Tracer.hello()
      :world

  """
  def hello do
    :world
  end

  @dummy_list 0..1000 |> Enum.to_list()

  def start do
    tracee = spawn(fn -> dummy_load() end)
    match_spec = [{:_, [], [{:message, {{:cp, {:caller}}}}]}]
    :erlang.trace_pattern(:on_load, match_spec, [:local])
    :erlang.trace_pattern({:_, :_, :_}, match_spec, [:local])
    :erlang.trace(tracee, true, [:call, :arity, :return_to, :timestamp, :running])

    print_traces()
  end

  defp print_traces do
    receive do
      t ->
        :trace_ts = elem(t, 0)
        IO.inspect(t)
    end

    print_traces()
  end

  defp dummy_load do
    @dummy_list
    |> Stream.with_index()
    |> Stream.map(fn {x, y} -> x * y end)
    |> Enum.reduce(0, fn x, acc -> x + acc end)

    dummy_load()
  end
end
