# Benchmarking Components

Start with `qip bench`. It measures a component through the same wazero execution
path as `qip run`, checks the output on every measured run, and makes
before-and-after comparisons difficult to accidentally invalidate. Add a small
Node.js harness when the browser/V8 runtime, a warmed instance, or
component-specific telemetry is part of the measurement.

Benchmarking is not a substitute for a correctness test. Keep a deterministic
test fixture and expected output first; then time the exact artifact that passed
that test.

## The Default: `qip bench`

Build once, then run the benchmark without another build or test process in
parallel:

```sh
make -j components/text/markdown/commonmark.0.31.2.wasm

./qip bench \
  -i README.md \
  --benchtime=3s \
  components/text/markdown/commonmark.0.31.2.wasm
```

`qip bench` compiles the module once and creates a fresh instance for each
sample. Its report includes:

- mean, standard deviation, minimum, p95, and maximum total time;
- mean execution and instantiation time, plus one compile measurement;
- mean and peak allocated WebAssembly linear memory;
- input and output capacities;
- raw and gzip-compressed module size; and
- output length and SHA-256.

The total time is the best first number for a normal Content component because
QIP hosts do not promise that instances will be reused. The execution breakdown
helps distinguish a slow algorithm from a large module that is expensive to
instantiate.

Prefer `--benchtime` for quick components. It gathers as many samples as fit in
the requested measured time:

```sh
./qip bench -i input.bin --benchtime=5s component.wasm
```

Use a fixed run count for slow inputs, and raise the per-run timeout explicitly:

```sh
./qip bench \
  -i fixtures/25mp-lossless.jp2 \
  -r 3 \
  --timeout-ms 30000 \
  components/image/jp2/jp2-to-bmp-bgra32.wasm
```

The timeout protects each sample; it is not the benchmark duration.

## Compare Variants In One Command

Before changing the implementation, copy the built artifact to a separate path.
Then pass that baseline first and one or more candidates after it:

```sh
cp components/text/markdown/commonmark.0.31.2.wasm \
  /tmp/commonmark-before.wasm

# Make the source change and rebuild the production target.
make -j components/text/markdown/commonmark.0.31.2.wasm

./qip bench \
  -i README.md \
  --benchtime=3s \
  /tmp/commonmark-before.wasm \
  components/text/markdown/commonmark.0.31.2.wasm
```

QIP alternates the order in which it runs the modules. It also requires every
output byte from every sample to match the first module. The final comparison
reports relative speed and the variant with the lowest peak linear memory.

Keep the old artifact at a separate path. Rebuilding the same target and relying
on remembered numbers loses both the executable baseline and the strongest
correctness check.

Byte equality is deliberately strict. It works well for parsers, transforms,
lossless codecs, and optimizations that should not change pixels. It is not the
right equivalence rule when multiple encodings are valid, such as two DEFLATE
streams that decompress to the same bytes. Benchmark those variants separately,
then test semantic equivalence by decoding their outputs.

## Choose Inputs Before Optimizing

One friendly fixture rarely represents a component. Choose a small input matrix
that exercises the work the algorithm actually performs:

- tiny, typical, and near-limit sizes;
- compressible and incompressible bytes for codecs;
- opaque and alpha-bearing images;
- shallow and deeply nested structured data; and
- any format feature that selects a separate hot path.

Keep malformed-input and limit tests in the test suite. Do not mix them into
throughput numbers unless you intend to measure rejection latency.

Record fixture names and hashes when the bytes are not obvious from the
repository. A benchmark without its input is not reproducible.

## When To Write A Node.js Harness

Use Node when the intended host is a browser or V8-based application, or when
`qip bench` cannot isolate the operation you need to time. Common cases are:

- measuring a reused instance after V8 has warmed and optimized it;
- driving interactive events or a particular renderer state;
- timing one exported kernel rather than a complete Content invocation;
- reading component-specific counters such as allocator peak usage; and
- comparing scalar and SIMD behavior in the engine users will run.

Keep the harness small and checked in under `tools/` when other developers will
repeat the measurement. A benchmark script should:

1. Load the same `.wasm` artifact shipped by the project.
2. Validate required exports and copy the fixture into Wasm memory.
3. Run unmeasured warmup iterations when measuring a reused instance.
4. State whether the number covers compilation, instantiation, one export, or
   the full pipeline, then time exactly that boundary.
5. Collect many samples and report at least mean, p50, p95, and maximum.
6. Hash or otherwise validate the output outside the timed region.

`tools/bench-qip-play.mjs` is the repository example for warmed interactive
rendering:

```sh
node tools/bench-qip-play.mjs \
  components/interactive/dock-magnification.wasm
```

Do not turn a Node test into a timing assertion. Use `node --test` to instantiate
a module, exercise its ABI, check output hashes, and read
telemetry. Wall-clock thresholds in a correctness suite are noisy across CI
machines and tend to fail without identifying a regression. Put repeatable
timing in a benchmark script and keep pass/fail assertions about correctness.

## Compare With A Native Reference

For a common algorithm, also measure a mature native implementation when one is
available: a standard library, an installed CLI, or the upstream library's own
tool. Each comparison supplies different evidence:

- QIP variant comparisons tell you whether your change helped.
- A native reference estimates the remaining performance gap.
- Cross-engine Node and wazero results show whether a speedup or slowdown
  changes with the runtime.

Match boundaries before comparing numbers. If `qip bench` includes
instantiation and output copying, a native command that times only its inner
codec loop is not an equivalent end-to-end measurement. Either align the
boundaries or label the difference plainly.

For image and codec work, compare decoded bytes as well as timing. In the JPEG
2000 component work, the QIP output was checked pixel-for-pixel against FFmpeg
before its runtime was compared with FFmpeg. Compare speed only if the decoded
images match pixel for pixel. Otherwise, you are making incorrect output
faster. Flawless first, then fast.

## Memory Needs Two Measurements

`qip bench` reports allocated WebAssembly linear memory. For a fixed-memory
component, that may be the full declared memory even if the algorithm touches
much less of it.

If a vendored library uses an arena, export counters such as peak live bytes,
largest allocation, failed allocations, and unmatched frees. Read them in a
correctness test or a dedicated Node harness after decoding. Report both values:
the host-visible linear-memory commitment and the allocator's observed peak
describe different costs.

Do not add telemetry imports solely for benchmarking. Exported integer counters
keep the component deterministic and work in both direct WebAssembly harnesses
and QIP hosts.

## Keep Timing Runs Quiet

Builds and tests should use the repository's parallel Makefile targets:

```sh
make -j test
```

Timing runs should be serial. Do not run `make -j`, another benchmark, a browser
preview, or a large download in parallel with them. For performance-sensitive
changes:

1. Build and test both artifacts.
2. Stop unrelated CPU-heavy work.
3. Run the comparison more than once.
4. Treat isolated minimums and maximums as clues, not conclusions.
5. Record the command, input, hardware, runtime, artifact sizes, output hash,
   and representative distribution.

If a claimed improvement is smaller than the run-to-run standard deviation,
collect more samples and repeat the trial. If the component ships in both CLI
and browser hosts, confirm the change with wazero and V8.

## Recommended Workflow

Use this sequence for most component work:

1. Add a deterministic fixture and correctness test.
2. Save the current `.wasm` artifact as the baseline.
3. Run `qip bench` against baseline and candidate on several inputs.
4. Inspect execution, instantiation, memory, and binary size—not only the mean.
5. Add a Node harness only for V8, warm-instance, stateful, or telemetry
   measurements.
6. Compare with a mature native implementation that accepts the same input and
   produces equivalent output.
7. Run `make -j test`, then repeat the timing commands without parallel work.
8. Report regressions and tradeoffs along with improvements.

Benchmark the exported function or pipeline that users exercise. A
microbenchmark of an inner helper can locate a bottleneck, but it cannot
establish an end-to-end improvement.
