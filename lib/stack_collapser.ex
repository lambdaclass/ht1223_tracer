defmodule StackCollapser do
  @moduledoc """
  Stack collapsing implementation.
  """

  @type state() :: %{last_timestamp: integer(), trace_tree: %{}, stack: [mfa()], pid: pid()}

  @default_output_file "stacks.out"

  ###########################
  ### PUBLIC API
  ###########################

  def initial_state(pid, opts) when is_pid(pid),
    do: %{pid: pid, last_timestamp: nil, trace_tree: %{}, stack: [], opts: opts}

  def finalize(%{trace_tree: tree, opts: opts}) do
    file = Keyword.get(opts, :output_file, @default_output_file)
    dump_trace_tree(tree, file)
  end

  def handle_event(trace_event, state)

  # `pid` called a traced function
  # cp's MFA is the caller's MFA
  def handle_event(
        {:trace_ts, _pid, :call, mfa, {:cp, :undefined}, ts},
        %{stack: [mfa | _]} = state
      ) do
    update_state(state, ts, state.stack)
  end

  def handle_event({:trace_ts, _pid, :call, mfa, {:cp, :undefined}, ts}, %{stack: stack} = state) do
    update_state(state, ts, [mfa | stack])
  end

  def handle_event({:trace_ts, _pid, :call, mfa, {:cp, callerMfa}, ts}, %{stack: []} = state) do
    update_state(state, ts, [mfa, callerMfa])
  end

  ## Collapse tail recursion
  def handle_event({:trace_ts, _pid, :call, mfa, {:cp, mfa}, _ts}, state), do: state

  ## Non-special call
  def handle_event(
        {:trace_ts, _pid, :call, mfa, {:cp, callerMfa}, ts},
        %{stack: [callerMfa | stack]} = state
      ) do
    update_state(state, ts, [mfa, callerMfa | stack])
  end

  ## TCO happened, so stack is [otherMfa, ..., callerMfa, ...]
  ## Note that since we don't really know the "root" function, the stack could be just [otherMfa]
  def handle_event({:trace_ts, _pid, :call, _mfa, {:cp, _}, _} = t, %{stack: [_ | rest]} = state) do
    handle_event(t, %{state | stack: rest})
  end

  # `pid` is scheduled to run
  def handle_event({:trace_ts, _pid, :in, mfa, ts}, %{stack: []} = state) do
    update_state(state, ts, [mfa])
  end

  def handle_event({:trace_ts, _pid, :in, _mfa, ts}, %{stack: [:sleep | rest]} = state) do
    update_state(state, ts, rest)
  end

  # `pid` is scheduled out
  def handle_event({:trace_ts, _pid, :out, _mfa, ts}, %{stack: stack} = state) do
    update_state(state, ts, [:sleep | stack])
  end

  # `pid` returns to a function
  def handle_event(
        {:trace_ts, _pid, :return_to, mfa, ts},
        %{stack: [_current, mfa | rest]} = state
      ) do
    update_state(state, ts, [mfa | rest])
  end

  def handle_event({:trace_ts, _pid, :return_to, _mfa, _ts}, state), do: state

  ###########################
  ### PRIVATE FUNCTIONS
  ###########################

  defp update_state(%{last_timestamp: nil} = state, ts, new_stack) do
    %{state | last_timestamp: ts, stack: new_stack}
  end

  defp update_state(%{stack: []} = state, ts, new_stack) do
    %{state | last_timestamp: ts, stack: new_stack}
  end

  defp update_state(%{last_timestamp: ts} = state, ts, _), do: state

  defp update_state(%{stack: old_stack, last_timestamp: old_ts} = state, ts, new_stack) do
    new_tree =
      [state.pid | :lists.reverse(old_stack)]
      |> update_tree(state.trace_tree, ts - old_ts)

    %{state | trace_tree: new_tree, last_timestamp: ts, stack: new_stack}
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

  defp dump_trace_tree(tree, file) do
    tree
    |> flatten_tree()
    |> then(&File.write!(file, &1))
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

  defp format_entry(_, 0), do: ""

  defp format_entry(stack, time) do
    :lists.reverse(stack)
    |> Stream.intersperse(";")
    |> Enum.concat([" #{time}\n"])
  end

  defp stringify_id({m, f, a}), do: "#{m}.#{f}/#{a}"
  defp stringify_id(pid) when is_pid(pid), do: :erlang.pid_to_list(pid) |> List.to_string()
  defp stringify_id(:sleep), do: "sleep"
end
