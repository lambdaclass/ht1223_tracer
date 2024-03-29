defmodule Tracer do
  @moduledoc """
  A tracer module that receives :erlang.trace generated messages, parses them into
  a local state and prints them to the screen.
  """

  use GenServer

  @default_mode :normal
  @default_backend StackCollapser

  ###########################
  ### PUBLIC API
  ###########################

  def start_trace(target, opts \\ []) do
    with {:ok, tracer} <- GenServer.start_link(__MODULE__, opts) do
      match_spec = [{:_, [], [{:message, {{:cp, {:caller}}}}]}]
      :erlang.trace_pattern(:on_load, match_spec, [:local])
      :erlang.trace_pattern({:_, :_, :_}, match_spec, [:local])
      :erlang.trace(target, true, [{:tracer, tracer} | trace_flags(opts)])
      {:ok, tracer}
    end
  end

  def stop_trace(tracer, target, timeout \\ :infinity) do
    :erlang.trace(target, false, [:all])
    GenServer.call(tracer, :finalize, timeout)
    GenServer.stop(tracer)
  end

  @base_flags [:call, :arity, :return_to, :monotonic_timestamp, :running]

  defp trace_flags(opts) do
    mode = Keyword.get(opts, :mode, @default_mode)

    case mode do
      :normal -> @base_flags
      :normal_with_children -> [:set_on_spawn | @base_flags]
    end
  end

  ###########################
  ### GENSERVER CALLBACKS
  ###########################

  def init(opts) do
    backend = Keyword.get(opts, :backend, @default_backend)
    {:ok, {apply(backend, :initial_state, [opts]), backend}}
  end

  def handle_info(t, {state, backend}) when elem(t, 0) === :trace_ts do
    new_state = apply(backend, :handle_event, [t, state])
    {:noreply, {new_state, backend}}
  end

  def handle_call(:finalize, _, {state, backend}) do
    apply(backend, :finalize, [state])
    {:reply, :ok, {state, backend}}
  end
end
