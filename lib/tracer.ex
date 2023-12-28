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

  def run(mfa, opts \\ [])
  def run({m, f, a}, opts), do: run({{m, f}, a}, opts)

  def run({fun, args}, opts) when is_list(opts) do
    {:ok, tracer} = Tracer.start_trace(self(), opts)
    apply_fun(fun, args)
    Tracer.stop_trace(tracer, self())
  end

  defp apply_fun({m, f}, args) when is_atom(m) and is_atom(f), do: apply(m, f, args)
  defp apply_fun(fun, args) when is_function(fun, length(args)), do: apply(fun, args)

  def start_trace(target, opts \\ []) do
    with {:ok, tracer} <- GenServer.start_link(__MODULE__, {target, opts}) do
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
  def init({pid, opts}) do
    backend = Keyword.get(opts, :backend, @default_backend)
    {:ok, apply(backend, :initial_state, [pid, opts])}
  end

  def handle_info(t, state) when elem(t, 0) === :trace_ts do
    new_state = StackCollapser.handle_event(t, state)
    {:noreply, new_state}
  end

  def handle_call(:finalize, _, state) do
    StackCollapser.finalize(state)
    {:reply, :ok, state}
  end
end
