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
        dump_trace_tree(state.trace_tree)
        :ok
    end
  end

  # `pid` called a traced function
  # cp's MFA is the caller's MFA
  defp handle({:trace_ts, _pid, :call, mfa, {:cp, :undefined}, ts}, %{stack: [mfa | _]} = state) do
    update_state(state, ts, state.stack)
  end

  defp handle({:trace_ts, _pid, :call, mfa, {:cp, :undefined}, ts}, %{stack: stack} = state) do
    update_state(state, ts, [mfa | stack])
  end

  defp handle({:trace_ts, _pid, :call, mfa, {:cp, callerMfa}, ts}, %{stack: []} = state) do
    update_state(state, ts, [mfa, callerMfa])
  end

  # Collapse tail recursion
  defp handle({:trace_ts, _pid, :call, mfa, {:cp, mfa}, _ts}, state), do: state

  defp handle(
         {:trace_ts, _pid, :call, mfa, {:cp, callerMfa}, ts},
         %{stack: [callerMfa | stack]} = state
       ) do
    update_state(state, ts, [mfa, callerMfa | stack])
  end

  defp handle({:trace_ts, _pid, :call, _mfa, {:cp, _}, ts}, %{stack: [_ | rest]} = state) do
    # TODO: collapse stack. This was probably a tail call.
    # This should map: [mfa, ..., callerMfa | rest] -> [mfa, callerMfa | rest]
    update_state(state, ts, rest)
  end

  # `pid` is scheduled to run
  defp handle({:trace_ts, _pid, :in, mfa, ts}, %{stack: []} = state) do
    update_state(state, ts, [mfa])
  end

  defp handle({:trace_ts, _pid, :in, _mfa, ts}, %{stack: [:sleep | rest]} = state) do
    update_state(state, ts, rest)
  end

  # `pid` is scheduled out
  defp handle({:trace_ts, _pid, :out, _mfa, ts}, %{stack: stack} = state) do
    update_state(state, ts, [:sleep | stack])
  end

  # `pid` returns to a function
  defp handle({:trace_ts, _pid, :return_to, mfa, ts}, %{stack: [_current, mfa | rest]} = state) do
    update_state(state, ts, [mfa | rest])
  end

  defp handle({:trace_ts, _pid, :return_to, _mfa, _ts}, state), do: state

  defp update_state(%{last_timestamp: nil} = state, ts, new_stack) do
    %{state | last_timestamp: ts, stack: new_stack}
  end

  defp update_state(%{stack: []} = state, ts, new_stack) do
    %{state | last_timestamp: ts, stack: new_stack}
  end

  defp update_state(%{stack: old_stack, last_timestamp: old_ts} = state, ts, new_stack) do
    time_spent = ts - old_ts

    old_stack
    |> :lists.reverse()
    |> then(&[state.pid | &1])
    |> update_tree(state.trace_tree, time_spent)
    |> then(&%{state | trace_tree: &1, last_timestamp: ts, stack: new_stack})
  end

  defp update_tree([mfa], tree, time) do
    Map.update(tree, mfa, {time, %{}}, fn {acc, children} -> {acc + time, children} end)
  end

  defp update_tree([mfa | rest], tree, time) do
    {acc, subtree} = Map.get(tree, mfa, {0, %{}})

    update_tree(rest, subtree, time)
    |> then(&{acc, &1})
    |> then(&Map.put(tree, mfa, &1))
  end

  defp dump_trace_tree(tree) do
    tree
    |> flatten_tree()
    |> then(&File.write!("trace.out", &1))
  end

  defp flatten_tree(tree, stack \\ []) do
    tree
    |> Enum.map(fn {mfa, {time, children}} ->
      id = stringify_id(mfa)
      stack = [id | stack]
      subtree = flatten_tree(children, stack)
      [format_entry(stack, time) | subtree]
    end)
  end

  defp format_entry(stack, time) do
    :lists.reverse(stack)
    |> Stream.intersperse(";")
    |> Enum.concat([" #{time}\n"])
  end

  defp stringify_id({m, f, a}), do: "#{m}.#{f}/#{a}"
  defp stringify_id(pid) when is_pid(pid), do: :erlang.pid_to_list(pid) |> List.to_string()
  defp stringify_id(:sleep), do: "sleep"

  defp dummy_load do
    @dummy_list
    |> Stream.with_index()
    |> Stream.map(fn {x, y} -> x * y end)
    |> Enum.reduce(0, fn x, acc -> x + acc end)

    # dummy_load()
  end
end
