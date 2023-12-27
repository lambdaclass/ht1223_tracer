defmodule Tracer do
  @moduledoc """
  A tracer module that receives :erlang.trace generated messages, parses them into
  a local state and prints them to the screen.
  """

  use GenServer

  ###########################
  ### PUBLIC API
  ###########################

  def trace(pid) do
    GenServer.start_link(__MODULE__, pid)
  end

  ###########################
  ### GENSERVER CALLBACKS
  ###########################
  def init(pid) do
    match_spec = [{:_, [], [{:message, {{:cp, {:caller}}}}]}]
    :erlang.trace_pattern(:on_load, match_spec, [:local])
    :erlang.trace_pattern({:_, :_, :_}, match_spec, [:local])
    :erlang.trace(pid, true, [:call, :arity, :return_to, :timestamp, :running])
    {:ok, %{}}
  end

  def handle_info(t, state) do
    :trace_ts = elem(t, 0)
    IO.inspect(t)
    {:noreply, state}
  end
end
