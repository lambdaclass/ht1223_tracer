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

  @type state() :: %{last_timestamp: integer(), trace_tree: %{}, stack: [mfa()], pid: pid()}

  @dummy_list 0..100 |> Enum.to_list()

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

    print_traces(%{
      pid: tracee,
      last_timestamp: nil,
      trace_tree: %{},
      stack: []
    })
  end

  defp print_traces(state) do
    receive do
      t when elem(t, 0) === :trace_ts ->
        t |> handle(state) |> print_traces()

      :end ->
        :ok
    end
  end

  # `pid` called a traced function
  # cp's MFA is the caller's MFA
  defp handle({:trace_ts, _pid, :call, mfa, {:cp, :undefined}, ts}, %{stack: [mfa | _]} = state) do
    %{state | last_timestamp: ts}
  end

  defp handle({:trace_ts, _pid, :call, mfa, {:cp, :undefined}, ts}, %{stack: stack} = state) do
    %{state | stack: [mfa | stack], last_timestamp: ts}
  end

  defp handle({:trace_ts, _pid, :call, mfa, {:cp, callerMfa}, ts}, %{stack: []} = state) do
    %{state | stack: [mfa, callerMfa], last_timestamp: ts}
  end

  # Collapse tail recursion
  defp handle({:trace_ts, _pid, :call, mfa, {:cp, mfa}, _ts}, state) do
    state
  end

  defp handle(
         {:trace_ts, _pid, :call, mfa, {:cp, callerMfa}, ts},
         %{stack: [callerMfa | stack]} = state
       ) do
    new_stack = [mfa, callerMfa | stack]
    %{state | stack: new_stack, last_timestamp: ts}
  end

  defp handle({:trace_ts, _pid, :call, _mfa, {:cp, _}, ts}, %{stack: [_ | rest]} = state) do
    # TODO: collapse stack. This was probably a tail call.
    # This should map: [mfa, ..., callerMfa | rest] -> [mfa, callerMfa | rest]
    %{state | stack: rest, last_timestamp: ts}
  end

  # `pid` is scheduled to run
  defp handle({:trace_ts, _pid, :in, mfa, ts}, %{stack: []} = state) do
    %{state | stack: [mfa], last_timestamp: ts}
  end

  defp handle({:trace_ts, _pid, :in, _mfa, ts}, %{stack: [:sleep | rest]} = state) do
    %{state | stack: rest, last_timestamp: ts}
  end

  # `pid` is scheduled out
  defp handle({:trace_ts, _pid, :out, _mfa, ts}, %{stack: stack} = state) do
    %{state | stack: [:sleep | stack], last_timestamp: ts}
  end

  # `pid` returns to a function
  defp handle({:trace_ts, _pid, :return_to, mfa, ts}, %{stack: [_current, mfa | rest]} = state) do
    %{state | stack: [mfa | rest], last_timestamp: ts}
  end

  defp handle({:trace_ts, _pid, :return_to, _mfa, _ts}, state) do
    state
  end

  defp dummy_load do
    @dummy_list
    |> Stream.with_index()
    |> Stream.map(fn {x, y} -> x * y end)
    |> Enum.reduce(0, fn x, acc -> x + acc end)

    # dummy_load()
  end
end
