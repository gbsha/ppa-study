# HOWTO: reproduce the M1–M3 baseline

This walks through every command needed to take this repo from a clean clone to the **M3 baseline PPA numbers** on sky130 — DSLX reference function, multi-architecture codegen from one source, and one librelane Classic-flow run with extracted PPA metrics. Each tool call is shown with its full CLI; each config file is shown with its full content.

Read `PLAN.md` for the *why* (study methodology, milestone gates). This file is the *how*.

## 0 — Prerequisites and sanity check

You must be inside the librelane nix-shell. The `external/xls-bin/` directory must be populated (see `README.md` "Install Tools").

```bash
# Confirm all four toolchains are visible.
which librelane openroad yosys
ls external/xls-bin/codegen_main
```

Expected: the first three resolve to `/nix/store/...` paths; the fourth is an executable. If any of these fail, fix that before continuing.

**Two known toolchain caveats** that you'll hit otherwise (see README "Known toolchain caveats" for detail): `import std;` in DSLX is broken because of an `xls-bin`/`external/xls` version skew, and the `xls-bin` binary set is a curated subset (no `simulate_module_main`, `eval_proc_main`, etc.). The flow below avoids both issues.

## 1 — M1: DSLX reference function (interpret + JIT cross-check)

**Source.** Two `.x` files in `dslx/`:

- `dslx/binner.x` — parametric `binner<BW_GLOBAL, N_BOUNDS, BW_BIN>` matching the Python in README.md, with six `#[test]` cases (basic 8-bit/4-bin, sentinel-for-inactive-entries, only-bin-0-active, non-zero `lbb[0]`, 2-bin minimal, 16-bit wider case).
- `dslx/binner_top_8x4.x` — concrete top-level instantiation for `BW_GLOBAL=8, N_BOUNDS=4, BW_BIN=2`, required because parametric functions can't be top-level for IR conversion.

`BW_BIN` is supplied explicitly rather than defaulting to `std::clog2(N_BOUNDS)` because `import std;` is broken (the version skew). When that's fixed, restore the default.

**Gate.** Run all DSLX tests and cross-check the DSLX interpreter against the IR JIT. The `--compare=jit` flag re-evaluates each test through the IR jitter and asserts equivalence — this is the strongest XLS-internal verification we have without `simulate_module_main`.

```bash
./external/xls-bin/interpreter_main --compare=jit dslx/binner.x
```

**Expected:** all 6 tests print `[ OK ]`; final line `[===============] 6 test(s) ran; 0 failed; 0 skipped.`; exit code 0.

If you see an `ImportError` about `xls/dslx/stdlib/std.x` being missing, add `--dslx_stdlib_path=external/xls/xls/dslx/stdlib` — but it shouldn't be needed since `binner.x` doesn't import std.

## 2 — M2: multi-architecture codegen from one DSLX source

The load-bearing strategy claim of the whole study: one parametric DSLX source, multiple hardware architectures driven by codegen constraints. M2 proves it for the unrefined binner at `BW_GLOBAL=8, N_BOUNDS=4`.

All commands assume project-root cwd. They write to `runs/` (gitignored).

### 2a — DSLX → IR

`ir_converter_main` converts the concrete top into XLS IR. Three flags worth knowing:

- `--top=binner_top` selects which DSLX function becomes the IR's top entry.
- `--dslx_path=dslx` lets `import binner;` in `binner_top_8x4.x` resolve to `dslx/binner.x`.
- `--dslx_stdlib_path=external/xls/xls/dslx/stdlib` — required even though we don't `import std;`. The tool wants the path, period.

```bash
mkdir -p runs/sky130
./external/xls-bin/ir_converter_main \
    --dslx_stdlib_path=external/xls/xls/dslx/stdlib \
    --dslx_path=dslx \
    --top=binner_top \
    dslx/binner_top_8x4.x > runs/sky130/binner_8x4.ir
```

**Expected:** exit 0, `runs/sky130/binner_8x4.ir` produced (~30 lines). Inspect it — you'll see a `counted_for` node with `trip_count=3` (the loop over indices 1..N_BOUNDS, skipping index 0), an `array_index` + `uge` + `sel` inside the body, and a final `sub` for `local_index`.

### 2b — Optimize the IR

`opt_main` runs the standard XLS optimization pipeline (inlining, dead-code elimination, peepholes, …). For this tiny design it doesn't change much, but the codegen step expects optimized IR.

```bash
./external/xls-bin/opt_main runs/sky130/binner_8x4.ir > runs/sky130/binner_8x4.opt.ir
```

**Expected:** exit 0, `runs/sky130/binner_8x4.opt.ir` produced.

### 2c — Codegen variant A: combinational (parallel architecture, zero flops)

This is the "parallel" architecture in pure combinational form — useful for inspection (one assign per logical step, easy to read). **Not usable directly in librelane Classic flow** (no clock; librelane wedges at CTS — see M3).

```bash
mkdir -p runs/sky130/comb/bw8_nb4
./external/xls-bin/codegen_main \
    --generator=combinational \
    --module_name=binner_top \
    --output_verilog_path=runs/sky130/comb/bw8_nb4/binner.v \
    --output_signature_path=runs/sky130/comb/bw8_nb4/binner.sig.textproto \
    --block_metrics_path=runs/sky130/comb/bw8_nb4/binner.metrics.textproto \
    runs/sky130/binner_8x4.opt.ir
```

**Expected:** exit 0; `binner.v` ~17 lines, `flop_count: 0` in `binner.metrics.textproto`.

### 2d — Codegen variant B: 4-stage pipeline at a *loose* clock (1809 ps logic in stage 0; stages 1–3 are buffers)

Demonstrates what *doesn't* happen if you just bump up `--pipeline_stages` without tightening the clock. At a 2000 ps budget, all the logic fits in one stage (XLS reports path delay 1809 ps); the remaining 3 stages are pass-through registers.

```bash
mkdir -p runs/sky130/pipe_s4_2000ps/bw8_nb4
./external/xls-bin/codegen_main \
    --generator=pipeline \
    --delay_model=sky130 \
    --clock_period_ps=2000 \
    --pipeline_stages=4 \
    --reset=rst \
    --module_name=binner_top \
    --output_verilog_path=runs/sky130/pipe_s4_2000ps/bw8_nb4/binner.v \
    --output_schedule_path=runs/sky130/pipe_s4_2000ps/bw8_nb4/binner.schedule.textproto \
    --block_metrics_path=runs/sky130/pipe_s4_2000ps/bw8_nb4/binner.metrics.textproto \
    runs/sky130/binner_8x4.opt.ir
```

**Expected:** `flop_count: 80`, `max_reg_to_reg_delay_ps: 1809`. Stage occupancy in the schedule textproto — most operations sit in stage 0; stages 1–2 are empty; stage 3 holds only the output tuple.

Inspect stage assignments:

```bash
awk '/stage: /{stage=$2; print "Stage", stage":"} /node:/{print "  ", $2}' \
    runs/sky130/pipe_s4_2000ps/bw8_nb4/binner.schedule.textproto
```

### 2e — Codegen variant C: 4-stage pipeline at the *minimum-feasible* clock (logic actually distributed)

Now drive the clock period tight enough that XLS *must* spread comparators across stages. The minimum-feasible clock for `--pipeline_stages=4` on this design is discoverable cheaply: ask for an impossible clock and read the suggestion.

```bash
# Probe: deliberately too tight, scheduler reports the minimum.
./external/xls-bin/codegen_main \
    --generator=pipeline --delay_model=sky130 --clock_period_ps=1 --pipeline_stages=4 \
    --reset=rst --module_name=binner_top \
    --output_verilog_path=/tmp/probe.v \
    runs/sky130/binner_8x4.opt.ir 2>&1 | grep "Try"
```

**Expected:** `Error: INVALID_ARGUMENT: cannot achieve the specified clock period. Try --clock_period_ps=509;...`. Use that 509 number:

```bash
mkdir -p runs/sky130/pipe_s4_500ps/bw8_nb4
./external/xls-bin/codegen_main \
    --generator=pipeline \
    --delay_model=sky130 \
    --clock_period_ps=509 \
    --pipeline_stages=4 \
    --reset=rst \
    --module_name=binner_top \
    --output_verilog_path=runs/sky130/pipe_s4_500ps/bw8_nb4/binner.v \
    --output_schedule_path=runs/sky130/pipe_s4_500ps/bw8_nb4/binner.schedule.textproto \
    --block_metrics_path=runs/sky130/pipe_s4_500ps/bw8_nb4/binner.metrics.textproto \
    runs/sky130/binner_8x4.opt.ir
```

**Expected:** `flop_count: 154`, `max_reg_to_reg_delay_ps: 509`. Now run the same `awk` inspection on this schedule — you'll see comparators distributed across stages 0–3 instead of crammed into stage 0.

### 2f — M2 gate summary

| variant            | flops | path delay | stage layout                                        |
|--------------------|-------|------------|-----------------------------------------------------|
| combinational (2c) | 0     | feedthrough| all logic in one combinational cone                 |
| pipe @ 2000 ps (2d)| 80    | 1809 ps    | stage 0 has all logic; stages 1–3 are buffers       |
| pipe @ 509 ps (2e) | 154   | 509 ps     | comparators actually distributed across all 4 stages |

The gate passes: same IR, three architecturally distinct Verilogs by toggling codegen constraints alone. **Key methodology takeaway:** `--pipeline_stages` alone produces buffer stages if the clock is loose. To get a real distributed pipeline, drive `--clock_period_ps` near the minimum feasible for the chosen stage count.

## 3 — M3: one Verilog through librelane sky130 PnR

M2 generated Verilog optimised for *inspection*. None of those three variants drops directly into librelane Classic flow:

- The combinational one has no clock → librelane synthesises a `__VIRTUAL_CLK__`, then fails at CTS / timing repair (no real flops to register against).
- Both pipelined variants use SystemVerilog array-literal syntax (`'{...}`) by default → Yosys V2005 parser chokes.

So M3 uses a fourth codegen point — **one pipeline stage with registered I/O, emitted as plain V2005** — that fits librelane's expectations. This corresponds to the "parallel architecture, registered I/O" point that's PPA-meaningful in a real chip context.

### 3a — Codegen: registered-I/O parallel variant in plain V2005

```bash
mkdir -p runs/sky130/pipe_s1_2000ps/bw8_nb4
./external/xls-bin/codegen_main \
    --generator=pipeline \
    --delay_model=sky130 \
    --clock_period_ps=2000 \
    --pipeline_stages=1 \
    --reset=rst \
    --use_system_verilog=false \
    --module_name=binner_top \
    --output_verilog_path=runs/sky130/pipe_s1_2000ps/bw8_nb4/binner.v \
    --output_schedule_path=runs/sky130/pipe_s1_2000ps/bw8_nb4/binner.schedule.textproto \
    --block_metrics_path=runs/sky130/pipe_s1_2000ps/bw8_nb4/binner.metrics.textproto \
    runs/sky130/binner_8x4.opt.ir
```

**Expected:** exit 0; `flop_count: 50`; Verilog with input flops + one logic stage + output flops; no `'{...}` SV syntax (separate `assign` per element).

### 3b — Stage the Verilog next to the librelane config

The librelane config at `flows/librelane/binner_8x4/config.json` references `dir::binner.v`, which librelane resolves relative to the config's directory. Copy the Verilog into that directory.

```bash
cp runs/sky130/pipe_s1_2000ps/bw8_nb4/binner.v flows/librelane/binner_8x4/binner.v
```

The committed config:

```json
{
  "DESIGN_NAME": "binner_top",
  "VERILOG_FILES": ["dir::binner.v"],
  "CLOCK_PORT": "clk",
  "CLOCK_PERIOD": 10.0
}
```

Why these four keys (the absolute minimum for a clocked block):

- `DESIGN_NAME` — top module name in the Verilog (must match `--module_name` from XLS).
- `VERILOG_FILES` — list of source files; `dir::` is the librelane prefix for "relative to this config file's directory."
- `CLOCK_PORT` — name of the clock input port; XLS emits `clk` for pipelined variants. Set to `null` for combinational designs (which then won't pass through Classic — see the note above).
- `CLOCK_PERIOD` — STA target in nanoseconds. Note the unit mismatch with XLS (picoseconds) — be careful when reading. 10 ns here is the *PnR* target; XLS scheduled at 2 ns (codegen step 3a). Post-PnR wire RC + worst-corner derating push real delays above XLS's pre-PnR estimate; 10 ns gives clean closure at every PVT corner for this design.

We deliberately don't set anything else — no I/O pads, no PDN tweaks, no signoff overrides. Librelane Classic uses defaults for everything else (sky130A PDK, sky130_fd_sc_hd standard cells, all flow steps enabled). For the PPA sweep work later we'll tighten this, but the M3 baseline is "defaults except the four required keys."

### 3c — Run librelane Classic flow

```bash
librelane --flow classic --condensed --log-level WARNING \
    flows/librelane/binner_8x4/config.json
```

Useful flags:

- `--flow classic` — the standard ASIC flow (Yosys synthesis → OpenROAD floorplan → place → CTS → route → STA across corners → IR drop → power).
- `--condensed` — terse, parseable log output; subprocess logs suppressed unless something fails.
- `--log-level WARNING` — silences INFO chatter. Use `--log-level INFO` if you want to watch each step.

**Expected:** runs ~4–5 minutes wall-clock on a typical machine. Librelane writes everything under `flows/librelane/binner_8x4/runs/RUN_<timestamp>/` (gitignored).

The flow will likely exit non-zero with `[Checker.MaxSlewViolations] Max Slew violations found in the following corners: max_ss_100C_1v60, min_ss_100C_1v60, nom_ss_100C_1v60`. **This is not a toolchain failure** — it's a real signoff finding. The design has long-fanout broadcast nets (32-bit `lower_bin_boundaries` driving three comparators) that slew too slowly at the slow-slow corner. The deferred-error happens *after* the full flow completes, so all PnR artifacts and metrics are still produced. This is on the M8 work list to address with proper signoff tuning across the sweep.

Timing slack itself is clean at all corners (`WNS = 0 ns` everywhere) — the 10 ns clock has enough headroom to close.

### 3d — Extract PPA metrics

```bash
flows/extract_metrics.py \
    "$(ls -dt flows/librelane/binner_8x4/runs/RUN_* | head -1)/final/metrics.json"
```

The extractor (`flows/extract_metrics.py`, ~70 lines of Python) reads the `final/metrics.json` librelane writes for every successful or partially-successful run, and prints the keys that matter for this study. The full JSON has hundreds of keys; if you want to see them all, just `cat`/`jq` the file directly.

**Python environment for this script:** stdlib only (`json`, `sys`) — no third-party packages. Runs against whatever `python3` resolves to on PATH; inside the librelane nix-shell that's the bundled `/nix/store/.../bin/python3` (3.13.9). No conda/pip env needed today. That changes once M8 brings pandas/numpy/matplotlib for sweep aggregation and plotting (see PLAN.md M8 note) — at that point a project-level `environment.yml` lands at the repo root.

**Expected output** (numbers should be byte-identical given the same PDK version and tool revisions):

```
=== PPA summary: flows/librelane/binner_8x4/runs/RUN_<timestamp>/final/metrics.json ===

Timing (WNS = worst negative slack across all paths in the corner):
  setup, max_tt_025C_1v80 (typical):     +0.000 ns
  setup, max_ss_100C_1v60 (worst slow):  +0.000 ns
  setup, max_ff_n40C_1v95 (worst fast):  +0.000 ns
  hold,  max_ss_100C_1v60:               +0.000 ns

Area (post-route):
  core area:           5009.8 um^2
  die area:            7589.9 um^2
  stdcell utilization: 68.7%

Cell area breakdown (instance area by class, post-route):
  sequential_cell                         1063.5 um^2
  multi_input_combinational_cell          1388.8 um^2
  inverter                                  60.1 um^2
  clock_buffer                             270.3 um^2
  timing_repair_buffer                     569.3 um^2
  fill_cell                               1570.3 um^2
  tap_cell                                  87.6 um^2

Power (nominal corner):
  total:     0.820 mW
  internal:  0.579 mW
  switching: 0.241 mW
  leakage:   0.005 uW

IR drop (nominal corner):
  worst VPWR drop: 0.0004 V
  worst VGND drop: 0.0004 V
```

### 3e — M3 gate summary

Achieved: full DSLX → IR → V2005 Verilog → librelane Classic → sky130 PnR pipeline, end-to-end, with extracted PPA numbers for the `binner` parallel architecture at `BW_GLOBAL=8, N_BOUNDS=4`. Two structural lessons (folded into PLAN.md for the sweep work):

1. "Parallel architecture" for PPA must mean `--generator=pipeline --pipeline_stages=1` (one stage of logic between registered I/O), not `--generator=combinational`.
2. `--use_system_verilog=false` is mandatory for the Yosys path.

## 4 — Cleanup

To wipe everything regenerable (gitignored only):

```bash
rm -rf runs/ flows/librelane/binner_8x4/runs/ flows/librelane/binner_8x4/binner.v
```

To re-run from scratch, repeat sections 1–3.

## 5 — Where everything lives

Committed:

```
HOWTO.md                                 this file
README.md                                project intro + toolchain caveats
CLAUDE.md                                operational guidance for Claude Code
PLAN.md                                  study plan: parameters, architectures, milestones, gates
dslx/binner.x                            parametric DSLX function + tests
dslx/binner_top_8x4.x                    concrete top instantiation for BW=8, N=4
flows/librelane/binner_8x4/config.json   librelane Classic flow config for this design point
flows/extract_metrics.py                 PPA summary extractor
```

Gitignored (regenerated by following this HOWTO):

```
runs/sky130/binner_8x4.ir                XLS IR (step 2a)
runs/sky130/binner_8x4.opt.ir            optimised XLS IR (step 2b)
runs/sky130/{comb,pipe_s4_2000ps,pipe_s4_500ps,pipe_s1_2000ps}/bw8_nb4/
                                         per-codegen-variant Verilog + metrics
flows/librelane/binner_8x4/binner.v      copy of pipe_s1_2000ps Verilog (step 3b)
flows/librelane/binner_8x4/runs/         librelane run artifacts and metrics
```
