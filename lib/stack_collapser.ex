defmodule StackCollapser do
  @moduledoc """
  Stack collapsing implementation.
  """

  @opaque state() :: %{
            last_ts: integer(),
            samples: %{[mfa() | :sleep] => non_neg_integer()},
            stack: [mfa()],
            pid: pid(),
            opts: opts_map()
          }
  @opaque opts_map() :: %{file: Path.t(), sample_size: non_neg_integer()}
  @type opts() :: [output_file: Path.t(), sample_size: non_neg_integer()]

  @default_output_file "stacks.out"
  @default_sample_size 1_000

  ###########################
  ### PUBLIC API
  ###########################

  def initial_state(pid, opts) when is_pid(pid) do
    file = Keyword.get(opts, :output_file, @default_output_file)
    sample_size = Keyword.get(opts, :sample_size, @default_sample_size)
    parsed_opts = %{file: file, sample_size: sample_size}
    %{pid: pid, last_ts: nil, samples: %{}, stack: [], opts: parsed_opts}
  end

  def finalize(%{samples: samples, pid: pid, opts: %{file: file}}) do
    dump_trace(samples, pid, file)
  end

  def handle_event(trace_event, state)

  # `pid` called a traced function
  # cp contains the caller's MFA
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
  def handle_event(
        {:trace_ts, _pid, :call, mfa, {:cp, callerMfa}, _ts},
        %{stack: [mfa, callerMfa | _]} = state
      ),
      do: state

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

  defp update_state(%{last_ts: nil} = state, ts, new_stack) do
    %{state | last_ts: ts, stack: new_stack}
  end

  defp update_state(%{stack: []} = state, ts, new_stack) do
    %{state | last_ts: ts, stack: new_stack}
  end

  defp update_state(%{last_ts: ts} = state, ts, _), do: state

  defp update_state(%{stack: old_stack, last_ts: old_ts, opts: opts} = state, ts, new_stack) do
    %{sample_size: sample_size} = opts
    delta = div(ts - old_ts, sample_size)

    if delta < 1 do
      %{state | stack: new_stack}
    else
      new_samples = Map.update(state.samples, old_stack, delta, &(&1 + delta))
      new_ts = old_ts + delta * sample_size
      %{state | samples: new_samples, last_ts: new_ts, stack: new_stack}
    end
  end

  defp dump_trace(samples, pid, file) do
    samples
    |> Enum.map(fn {stack, sample_count} ->
      stack
      |> Enum.map(&stringify_id/1)
      |> format_entry(pid, sample_count)
    end)
    |> then(&File.write!(file, &1))
  end

  defp format_entry(_, _, 0), do: ""

  defp format_entry(stack, pid, sample_count) do
    [stringify_id(pid) | :lists.reverse(stack)]
    |> Stream.intersperse(";")
    |> Enum.concat([" #{sample_count}\n"])
  end

  defp stringify_id({m, f, a}), do: "#{m}.#{f}/#{a}"
  defp stringify_id(pid) when is_pid(pid), do: :erlang.pid_to_list(pid)
  defp stringify_id(:sleep), do: "sleep"
end
