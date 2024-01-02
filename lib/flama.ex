defmodule Flama do
  @moduledoc """
  Library for generating flame graphs on Elixir.
  """

  @type opts() :: [
          mode: :normal | :normal_with_children,
          backend: module(),
          output_file: Path.t(),
          sample_size: non_neg_integer()
        ]

  @doc """
  Runs a function and generates flamegraph data from the results.
  Accepts the following options:
    - `:mode`: `:normal` or `:normal_with_children`. Defaults to `:normal`.
    - `:backend`: a module that implements the event-handling logic. Defaults to `StackCollapser`.
    - `:output_file`: the file to write the flamegraph data to. Defaults to `stacks.out`.
    - `:sample_size`: the time delta of each sample (in nanoseconds). Defaults to `1000`.
  """
  @spec run(call :: mfa() | {fun(), list()}, opts :: opts()) :: :ok
  def run(call, opts \\ [])

  def run({m, f, a}, opts), do: run({{m, f}, a}, opts)

  def run({fun, args}, opts) when is_list(opts) do
    {:ok, tracer} = Tracer.start_trace(self(), opts)
    apply_fun(fun, args)
    Tracer.stop_trace(tracer, self())
  end

  # Helper functions

  defp apply_fun({m, f}, args) when is_atom(m) and is_atom(f), do: apply(m, f, args)
  defp apply_fun(fun, args) when is_function(fun, length(args)), do: apply(fun, args)
end
