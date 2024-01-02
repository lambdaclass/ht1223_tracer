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

  def initial_state(opts) do
    file = Keyword.get(opts, :output_file, @default_output_file)
    sample_size = Keyword.get(opts, :sample_size, @default_sample_size)
    parsed_opts = %{file: file, sample_size: sample_size}
    %{states: %{}, opts: parsed_opts}
  end

  def finalize(%{states: states, opts: %{file: file}}) do
    states
    |> Enum.map(fn {pid, state} -> format_trace(state.samples, pid) end)
    |> then(&File.write!(file, &1))
  end

  def handle_event(trace_event, %{states: states, opts: opts} = state) do
    pid = elem(trace_event, 1)

    process_state = Map.get(states, pid, %{last_ts: nil, samples: %{}, stack: []})
    new_process_state = handle_process_event(trace_event, process_state, opts)

    %{state | states: Map.put(states, pid, new_process_state)}
  end

  # `pid` called a traced function
  # cp contains the caller's MFA
  defp handle_process_event(
         {:trace_ts, _pid, :call, mfa, {:cp, :undefined}, _ts},
         %{stack: [mfa | _]} = state,
         _opts
       ),
       do: state

  defp handle_process_event(
         {:trace_ts, _pid, :call, mfa, {:cp, :undefined}, ts},
         %{stack: stack} = state,
         opts
       ) do
    update_state(state, ts, [mfa | stack], opts)
  end

  defp handle_process_event(
         {:trace_ts, _pid, :call, mfa, {:cp, callerMfa}, ts},
         %{stack: []} = state,
         opts
       ) do
    update_state(state, ts, [mfa, callerMfa], opts)
  end

  ## Collapse tail recursion
  defp handle_process_event(
         {:trace_ts, _pid, :call, mfa, {:cp, callerMfa}, _ts},
         %{stack: [mfa, callerMfa | _]} = state,
         _opts
       ),
       do: state

  ## Non-special call
  defp handle_process_event(
         {:trace_ts, _pid, :call, mfa, {:cp, callerMfa}, ts},
         %{stack: [callerMfa | stack]} = state,
         opts
       ) do
    update_state(state, ts, [mfa, callerMfa | stack], opts)
  end

  ## TCO happened, so stack is [otherMfa, ..., callerMfa, ...]
  ## Note that since we don't really know the "root" function, the stack could be just [otherMfa]
  defp handle_process_event(
         {:trace_ts, _pid, :call, _mfa, {:cp, _}, _} = t,
         %{stack: [_ | rest]} = state,
         opts
       ) do
    handle_process_event(t, %{state | stack: rest}, opts)
  end

  # `pid` is scheduled to run
  defp handle_process_event({:trace_ts, _pid, :in, mfa, ts}, %{stack: []} = state, opts) do
    update_state(state, ts, [mfa], opts)
  end

  defp handle_process_event(
         {:trace_ts, _pid, :in, _mfa, ts},
         %{stack: [:sleep | rest]} = state,
         opts
       ) do
    update_state(state, ts, rest, opts)
  end

  # `pid` is scheduled out
  defp handle_process_event({:trace_ts, _pid, :out, _mfa, ts}, %{stack: stack} = state, opts) do
    update_state(state, ts, [:sleep | stack], opts)
  end

  # `pid` returns to a function
  defp handle_process_event(
         {:trace_ts, _pid, :return_to, mfa, ts},
         %{stack: [_current, mfa | rest]} = state,
         opts
       ) do
    update_state(state, ts, [mfa | rest], opts)
  end

  defp handle_process_event({:trace_ts, _pid, :return_to, _mfa, _ts}, state, _opts), do: state

  ###########################
  ### PRIVATE FUNCTIONS
  ###########################

  defp update_state(%{last_ts: nil} = state, ts, new_stack, _) do
    %{state | last_ts: ts, stack: new_stack}
  end

  defp update_state(%{stack: []} = state, ts, new_stack, _) do
    %{state | last_ts: ts, stack: new_stack}
  end

  defp update_state(%{last_ts: ts} = state, ts, _, _), do: state

  defp update_state(%{stack: old_stack, last_ts: old_ts} = state, ts, new_stack, opts) do
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

  defp format_trace(samples, pid) do
    samples
    |> Enum.map(fn {stack, sample_count} ->
      stack
      |> Enum.map(&stringify_id/1)
      |> format_entry(pid, sample_count)
    end)
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
