defmodule Tracer do
  @moduledoc """
  A tracer module that receives :erlang.trace generated messages, parses them into
  a local state and prints them to the screen.
  """

  use GenServer

  @trace_flags [:call, :arity, :return_to, :monotonic_timestamp, :running]

  ###########################
  ### PUBLIC API
  ###########################

  def start_trace(pid) do
    with {:ok, tracer} <- GenServer.start_link(__MODULE__, pid) do
      match_spec = [{:_, [], [{:message, {{:cp, {:caller}}}}]}]
      :erlang.trace_pattern(:on_load, match_spec, [:local])
      :erlang.trace_pattern({:_, :_, :_}, match_spec, [:local])
      :erlang.trace(pid, true, [{:tracer, tracer} | @trace_flags])
      {:ok, tracer}
    end
  end

  def stop_trace(tracer), do: GenServer.call(tracer, :stop)

  ###########################
  ### GENSERVER CALLBACKS
  ###########################
  def init(pid) do
    {:ok, StackCollapser.initial_state(pid)}
  end

  def handle_info(t, state) when elem(t, 0) === :trace_ts do
    new_state = StackCollapser.handle_event(t, state)
    {:noreply, new_state}
  end

  def handle_call(:stop, _, state) do
    StackCollapser.finalize(state)
    {:stop, :normal, :ok, state}
  end
end
