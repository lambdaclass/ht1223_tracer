# Tracer

An elixir tracer that produces flamegraph-friendly outputs. Inspired in [eflame](https://github.com/proger/eflame), a tracer for erlang. Uses [`:erlang.trace/3`](https://www.erlang.org/doc/man/erlang#trace-3) to produce traces, parses them in a Genserver, outputs results to collapsed stack files.

Built for the LambdaClass Hackathon of December 2023 🎄.

## User guide

### Instalation

Pre-requisites:

- erlang OTP 26.
- elixir 1.16.
- Alternatively: erlang and elixir may be installed using asdf (`.tool-versions` file provided so that `asdf install` can be run easily).

To install the elixir dependencies, run:

```bash
mix deps.get
```

### Tests

Tests can be run with:

```bash
mix test
```

They currently feature a simple example of stream processing.

### Usage

In elixir, if we want to produce a flamegraph for the execution of the function `my_function(arg1, arg2)`, we need to run:

```elixir
Tracer.run({:my_function, [arg1, arg2]})
```

Additionally, if the function is in a different module, this can be specified as:

```elixir
Tracer.run({SomeModule, :my_function, [arg1, arg2]})
```

### Results

Results are produced by default in a `stacks.out` file. Each line contains the PID where the function is executed, a call stack and an amount of time. This format is compatible with tools such as Brendan Gregg's [FlameGraph](https://github.com/brendangregg/FlameGraph?tab=readme-ov-file#2-fold-stacks), specifically, the script [flamegraph.pl](https://github.com/brendangregg/FlameGraph/blob/master/flamegraph.pl). If you have that script locally, you can just execute the following line:

```bash
# Give exec access to the script. This only needs to be executed once.
chmod +x flamegraph.pl 

# Produce an svg out of the trace file.
./flamegraph.pl stacks.out > flamegraph.svg
```

The resulting svg can be open in an internet browser like Google Chrome, for interactive exploring (e.g. hovering over the a function call in a stack displays its full name).

## Architecture and design

A simple call to `Tracer.run` will:

1. Spawn a Tracer process.
2. Activate BEAM tracing.
3. Execute the function to be traced in the caller's process.
4. Each message sent by BEAM tracing will be received by the tracer process, which will save the stack tree in its internal state (more details later).

When the function finishes, then:

1. BEAM tracing will be stopped.
2. A call to the Tracer process will be sent to write the results to a file.
3. After this finishes (or there's a timeout) the Tracer process will be stopped.

A timeout will mean that the Tracer GenServer did not finish processing the trace messages in a reasonable amount of time after the call to stop happened. This usually happens when the amount of events to process was very high and stacks very deep. Consider increasing the timeout if that happens.
