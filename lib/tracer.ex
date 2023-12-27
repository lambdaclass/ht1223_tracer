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

  @dummy_list 0..100_000 |> Enum.to_list()

  def start do
    tracer = self()

    tracee =
      spawn(fn ->
        dummy_load()
        send(tracer, :end)
      end)

    match_spec = [{:_, [], [{:message, {{:cp, {:caller}}}}]}]
    :erlang.trace_pattern(:on_load, match_spec, [:local])
    :erlang.trace_pattern({:_, :_, :_}, match_spec, [:local])
    :erlang.trace(tracee, true, [:call, :arity, :return_to, :monotonic_timestamp, :running])

    StackCollapser.initial_state(tracee)
    |> process_trace()
  end

  defp process_trace(state) do
    receive do
      t when elem(t, 0) === :trace_ts ->
        t |> StackCollapser.handle_event(state) |> process_trace()

      :end ->
        StackCollapser.finalize(state)
        :ok
    end
  end

  defp dummy_load do
    @dummy_list
    |> Stream.with_index()
    |> Stream.map(fn {x, y} -> x * y end)
    |> Enum.reduce(0, fn x, acc -> x + acc end)
  end
end
