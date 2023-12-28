defmodule SpeedScope do
  @moduledoc """
  SpeedScope JSON implementation.
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

  @default_output_file "stacks.speedscope.json"
  @default_sample_size 1_000

  ###########################
  ### PUBLIC API
  ###########################

  def initial_state(opts) do
    file = Keyword.get(opts, :output_file, @default_output_file)
    sample_size = Keyword.get(opts, :sample_size, @default_sample_size)
    parsed_opts = %{file: file, sample_size: sample_size}
    %{frames: %{}, events: [], stack: [], last_ts: nil, opts: parsed_opts}
  end

  def finalize(%{stack: stack, events: [%{at: last_at} | _]} = state) do
    %{frames: frames, events: events, opts: %{file: file}} =
      Enum.reduce(stack, state, fn mfa, state ->
        add_event(state, :C, last_at, mfa)
      end)

    {:ok, f} = File.open(file, [:write])

    header =
      ~S({"exporter":"speedscope@1.19.0","name":"perf-vertx-stacks-01-collapsed-all.txt","activeProfileIndex":0,"$schema":"https://www.speedscope.app/file-format-schema.json","shared":{"frames":[)

    IO.write(f, header)

    frames
    |> Enum.sort_by(fn {_, i} -> i end)
    |> Stream.map(fn {name, _} -> ~s({"name": "#{stringify_id(name)}"}) end)
    |> Stream.intersperse(",")
    |> Enum.each(&IO.write(f, &1))

    intersection =
      ~s(]},"profiles":[{"type": "evented","name": "perf-vertx-stacks-01-collapsed-all.txt","unit": "none","startValue": 0,"endValue": #{last_at},"events": [)

    IO.write(f, intersection)

    :lists.reverse(events)
    |> Stream.map(fn %{type: type, frame: frame, at: at} ->
      ~s({"type": "#{type}","frame": #{frame},"at": #{at}})
    end)
    |> Stream.intersperse(",")
    |> Enum.each(&IO.write(f, &1))

    IO.write(f, "]}]}")
  end

  # `pid` called a traced function
  # cp's MFA is the caller's MFA
  def handle_event(
        {:trace_ts, _pid, :call, mfa, {:cp, :undefined}, _ts},
        %{stack: [mfa | _]} = state
      ),
      do: state

  def handle_event(
        {:trace_ts, _pid, :call, mfa, {:cp, :undefined}, ts},
        %{stack: stack, opts: opts} = state
      ) do
    add_event(state, :O, ts, mfa)
    |> update_state([mfa | stack], opts)
  end

  def handle_event(
        {:trace_ts, _pid, :call, mfa, {:cp, callerMfa}, ts},
        %{stack: [], opts: opts} = state
      ) do
    state
    |> add_event(:O, ts, callerMfa)
    |> add_event(:O, ts, mfa)
    |> update_state([mfa, callerMfa], opts)
  end

  ## Collapse tail recursion
  def handle_event({:trace_ts, _pid, :call, mfa, {:cp, mfa}, _ts}, state), do: state

  ## Non-special call
  def handle_event(
        {:trace_ts, _pid, :call, mfa, {:cp, callerMfa}, ts},
        %{stack: [callerMfa | stack], opts: opts} = state
      ) do
    add_event(state, :O, ts, mfa)
    |> update_state([mfa, callerMfa | stack], opts)
  end

  ## TCO happened, so stack is [otherMfa, ..., callerMfa, ...]
  ## Note that since we don't really know the "root" function, the stack could be just [otherMfa]
  def handle_event(
        {:trace_ts, _pid, :call, _mfa, {:cp, _}, ts} = t,
        %{stack: [top | rest]} = state
      ) do
    state = add_event(state, :C, ts, top)
    handle_event(t, %{state | stack: rest})
  end

  # `pid` is scheduled to run
  def handle_event(
        {:trace_ts, _pid, :in, mfa, ts},
        %{stack: [], opts: opts} = state
      ) do
    add_event(state, :O, ts, mfa)
    |> update_state([mfa], opts)
  end

  def handle_event(
        {:trace_ts, _pid, :in, _mfa, ts},
        %{stack: [:sleep | rest], opts: opts} = state
      ) do
    add_event(state, :C, ts, :sleep)
    |> update_state(rest, opts)
  end

  # `pid` is scheduled out
  def handle_event(
        {:trace_ts, _pid, :out, _mfa, ts},
        %{stack: stack, opts: opts} = state
      ) do
    add_event(state, :O, ts, :sleep)
    |> update_state([:sleep | stack], opts)
  end

  # `pid` returns to a function
  def handle_event(
        {:trace_ts, _pid, :return_to, mfa, ts},
        %{stack: [current, mfa | rest], opts: opts} = state
      ) do
    add_event(state, :C, ts, current)
    |> update_state([mfa | rest], opts)
  end

  def handle_event({:trace_ts, _pid, :return_to, _mfa, _ts}, state), do: state

  ###########################
  ### PRIVATE FUNCTIONS
  ###########################

  defp add_event(%{frames: frames, events: events, last_ts: last_ts} = state, type, ts, mfa) do
    new_at =
      if is_nil(last_ts) do
        0
      else
        %{at: old_at} = List.first(events)
        new_at = ts - last_ts + old_at

        # if new_at > 576_460_751_683_392 do
        # IO.inspect(mfa, label: "mfa")
        # IO.inspect(state.stack, label: "stack")
        IO.inspect(ts, label: "ts")
        IO.inspect(last_ts, label: "last_ts")
        IO.inspect(old_at, label: "old_at")
        IO.inspect(new_at, label: "aaaaaaa")
        # end

        new_at
      end

    {new_frames, i} =
      case Map.get(frames, mfa) do
        nil ->
          i = map_size(frames)
          {Map.put(frames, mfa, i), i}

        i ->
          {frames, i}
      end

    new_event = %{type: type, frame: i, at: new_at}

    %{state | events: [new_event | events], frames: new_frames, last_ts: ts}
  end

  defp update_state(state, new_stack, _) do
    %{state | stack: new_stack}
  end

  defp stringify_id({m, f, a}), do: "#{m}.#{f}/#{a}"
  defp stringify_id(pid) when is_pid(pid), do: :erlang.pid_to_list(pid)
  defp stringify_id(:sleep), do: "sleep"
end
