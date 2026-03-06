# Replay Debugging for `qip` (rr-style)

`qip` should prefer a **record/replay debugger** over a live step debugger, because reproducibility is one of `qip`’s strongest advantages and replay turns flaky module behavior into inspectable facts.

## What this would look like

A practical shape is a top-level command:

```bash
qip replay <subcommand> ...
```

With subcommands focused on the full workflow:

- `qip replay record ...`  
  Run a normal pipeline and write a trace artifact with enough data to replay exactly.
- `qip replay inspect <trace.qtr>`  
  Print trace metadata (modules, versions, input hashes, host flags, stage count, failures).
- `qip replay debug <trace.qtr>`  
  Open an interactive debugger for one recorded execution.
- `qip replay export <trace.qtr>`  
  Emit selected slices (for example stage I/O or memory windows) as JSON/CBOR for offline analysis.

This keeps the default `qip run` path fast while giving a deliberate “forensics mode” when needed.

## What you should be able to do in `qip replay debug`

Claim: debugging should map to the module contract, not invent a second execution model.  
Reason: users already think in `input_ptr`, caps, `run(input_size)`, and output buffers.  
Example: breakpoints and memory reads should be expressed in those terms.

Core capabilities:

- Set breakpoints:
  - by stage (`break stage 2`)
  - by module export (`break export run`)
  - by wasm pc offset (`break pc 0x12af`)
- Step controls:
  - `continue`, `step`, `next`, `finish`
  - reverse equivalents on replay (`reverse-step`, `reverse-continue`)
- Read memory:
  - `x/64xb input_ptr`
  - `x/32xf output_ptr` (useful for `qip image` float tiles)
  - `hexdump <addr> <len>`
- Watch memory/register-style values:
  - `watch output_ptr+128`
  - `print input_size`
  - `print uniform.max_radius`
- Stage-aware inspection:
  - `info stages`
  - `frame stage 3`
  - `diff stage 2 output vs stage 3 input`
- Assertions while debugging:
  - `assert run_return <= output_cap`
  - `assert mem[input_ptr:input_ptr+4] == 0x89504e47`

## Trace format expectations

Default trace contents should be:

- host version and command line
- module identities (path/URL plus digest)
- effective uniforms/query args
- per-stage input/output sizes and hashes
- deterministic event log for replay
- optional memory snapshots around breakpoints

Recommended default: store hashes + selective snapshots first, then allow `--full-memory` when deep forensics is required.

Tradeoff:

- selective capture keeps traces small and fast
- full-memory capture is easier to inspect but expensive

## Quick command sketch

```bash
# 1) Record an execution
qip replay record -i in.txt -o out.txt \
  --trace trace.qtr \
  modules/utf8/a.wasm modules/utf8/b.wasm

# 2) Inspect what was captured
qip replay inspect trace.qtr

# 3) Debug the captured run
qip replay debug trace.qtr
# (qip-replay) break stage 1
# (qip-replay) run
# (qip-replay) x/64xb input_ptr
# (qip-replay) reverse-step
```

## When not to use replay debugging

Use plain `qip run` or `qip bench` when you only need correctness/perf checks and do not need execution history. Replay adds overhead and should be opt-in.

## Decision rubric

Use replay mode when at least one is true:

- A module fails only for specific inputs and is hard to reproduce interactively.
- You need to prove where bytes changed between stages.
- You need memory-level evidence for a bug report or compliance failure.

