---
format: pdf
---

# HOWTO: reproduce the baseline

This walks through every command needed to take this repo from a clean clone to the baseline PPA numbers and verification results on sky130 — DSLX reference function, codegen from one source, cocotb RTL functional verification, one librelane Classic-flow run with extracted PPA metrics, and the scripted sweep producing the first Pareto frontier. Each tool call is shown with its full CLI; each config file is shown with its full content.

Read `PLAN.md` for the *why* (study methodology, milestones, optional extensions). `README.md` "Two entry paths" explains which sections need librelane and which don't:

| Section          | Milestone(s) | Path A (conda env) | Path B (+ librelane) |
| ---------------- | ------------ | ------------------ | -------------------- |
| §1 DSLX          | M1           | ✓                  | ✓                    |
| §2 codegen       | M2           | ✓                  | ✓                    |
| §3 PnR           | M3           |                    | ✓ (librelane needed) |
| §4 verification  | M4a          | ✓                  | ✓                    |
| §5 sweep + plots | M6, M8       | partial (`--skip-pnr` only) | ✓ (full)    |

## 0 — Prerequisites and sanity check

Path A users: `mamba activate ppa-study` is enough (env from `environment.yml`); skip the librelane check.

Path B users: be inside the librelane nix-shell *and* `mamba activate ppa-study`. The `external/xls-bin/bin/` directory must be populated with the XLS binaries (see `README.md` "Install Tools").

```bash
# Path B — confirm both toolchains are visible.
which librelane openroad yosys                  # /nix/store/... (Path B only)
ls external/xls-bin/bin/codegen_main            # executable (both paths)
mamba run -n ppa-study which iverilog cocotb-config   # conda env (both paths)
```

**Toolchain note** (see README "Toolchain status" for detail): `xls-bin` and `external/xls` are pinned to the same XLS revision, so `import std;` works and `dslx/binner.x` uses `std::clog2` directly — pass `--dslx_stdlib_path=external/xls/xls/dslx/stdlib` on every invocation so the import resolves. The binary set is nearly complete; `simulate_module_main` (RTL sim) is the one gap — covered by §4 (cocotb + iverilog from the conda env). See `COCOTB.md` for the verification framework.

**Harmless startup message:** the XLS binaries may print `[symbolize_elf.inc : 379] RAW: Unable to get high fd: rc=0, limit=1024` to stderr. This is just Abseil's crash-backtrace symbolizer failing to reserve a high file descriptor under a low open-files limit; it does not affect the result (it goes to stderr, not the `>`-redirected output file). To silence it, raise the limit in your shell first: `ulimit -n 4096`.

## 1 — M1: DSLX reference function (interpret + JIT cross-check)

**Source.** Two `.x` files in `dslx/`:

- `dslx/binner.x` — parametric `binner<BW_GLOBAL, N_BOUNDS, BW_BIN = {std::clog2(N_BOUNDS)}>` matching the Python in README.md, with six `#[test]` cases (basic 8-bit/4-bin, sentinel-for-inactive-entries, only-bin-0-active, non-zero `lbb[0]`, 2-bin minimal, 16-bit wider case). The tests pass `BW_BIN` explicitly to pin the bin-index width.
- `dslx/binner_top_8x4.x` — concrete top-level instantiation for `BW_GLOBAL=8, N_BOUNDS=4` (`BW_BIN` defaults to `clog2(4)=2`), required because parametric functions can't be top-level for IR conversion.

`BW_BIN` defaults to `std::clog2(N_BOUNDS)` now that `import std;` works (the `xls`/`xls-bin` revisions are in sync).

**Gate.** Run all DSLX tests and cross-check the DSLX interpreter against the IR JIT. The `--compare=jit` flag re-evaluates each test through the IR jitter and asserts equivalence — this is the strongest XLS-internal verification we have without `simulate_module_main`.

```bash
./external/xls-bin/bin/interpreter_main \
    --dslx_stdlib_path=external/xls/xls/dslx/stdlib \
    --compare=jit dslx/binner.x
```

**Expected:** all 6 tests print `[ OK ]`; final line `[===============] 6 test(s) ran; 0 failed; 0 skipped.`; exit code 0.

The `--dslx_stdlib_path` flag is required: `binner.x` does `import std;` (for `std::clog2`), and the default stdlib path the binaries look for doesn't exist in this layout. Omitting it fails with `ImportError: Could not find DSLX file for import ... xls/dslx/stdlib/std.x`.

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
./external/xls-bin/bin/ir_converter_main \
    --dslx_stdlib_path=external/xls/xls/dslx/stdlib \
    --dslx_path=dslx \
    --top=binner_top \
    dslx/binner_top_8x4.x > runs/sky130/binner_8x4.ir
```

**Expected:** exit 0, `runs/sky130/binner_8x4.ir` produced (~30 lines). Inspect it — you'll see a `counted_for` node with `trip_count=3` (the loop over indices 1..N_BOUNDS, skipping index 0), an `array_index` + `uge` + `sel` inside the body, and a final `sub` for `local_index`.

### 2b — Optimize the IR

`opt_main` runs the standard XLS optimization pipeline (inlining, dead-code elimination, peepholes, …). For this tiny design it doesn't change much, but the codegen step expects optimized IR.

```bash
./external/xls-bin/bin/opt_main runs/sky130/binner_8x4.ir > runs/sky130/binner_8x4.opt.ir
```

**Expected:** exit 0, `runs/sky130/binner_8x4.opt.ir` produced.

### 2c — Codegen variant A: combinational (parallel architecture, zero flops)

This is the "parallel" architecture in pure combinational form — useful for inspection (one assign per logical step, easy to read). **Not usable directly in librelane Classic flow** (no clock; librelane wedges at CTS — see M3).

```bash
mkdir -p runs/sky130/comb/bw8_nb4
./external/xls-bin/bin/codegen_main \
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
./external/xls-bin/bin/codegen_main \
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
./external/xls-bin/bin/codegen_main \
    --generator=pipeline --delay_model=sky130 --clock_period_ps=1 --pipeline_stages=4 \
    --reset=rst --module_name=binner_top \
    --output_verilog_path=/tmp/probe.v \
    runs/sky130/binner_8x4.opt.ir 2>&1 | grep "Try"
```

**Expected:** `Error: INVALID_ARGUMENT: cannot achieve the specified clock period. Try --clock_period_ps=509;...`. Use that 509 number:

```bash
mkdir -p runs/sky130/pipe_s4_500ps/bw8_nb4
./external/xls-bin/bin/codegen_main \
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

**Expected:** `flop_count: 154`, `max_reg_to_reg_delay_ps: 509`. Run the same `awk` inspection on this schedule and you get (grouped by stage):

```
Stage 0:  global_index, lower_bin_boundaries, array_index.79/80, uge.81, uge.86, sel.88
Stage 1:  array_index.89, uge.91, concat.119/120, sel.90, bin_index (add)
Stage 2:  array_index.94            <- lbb[bin_index] lookup
Stage 3:  local_index (sub), tuple.96
```

Note what is *not* happening: the comparators do **not** spread evenly across all four stages. They cluster at the front (`uge.81`/`uge.86` in stage 0, `uge.91` in stage 1 — deferred there to save a pipeline register, not for timing). What the extra stages actually pipeline is the **serial chain after** the compares: the popcount collector finishes in stage 1, the data-dependent `lbb[bin_index]` lookup takes all of stage 2, and the subtraction takes all of stage 3 — those last two are single operations that each nearly fill a 509 ps stage. §2h shows why, from the per-node delay model.

### 2f — M2 gate summary

| variant            | flops | path delay | stage layout                                        |
|--------------------|-------|------------|-----------------------------------------------------|
| combinational (2c) | 0     | feedthrough| all logic in one combinational cone                 |
| pipe @ 2000 ps (2d)| 80    | 1809 ps    | stage 0 has all logic; stages 1–3 are buffers       |
| pipe @ 509 ps (2e) | 154   | 509 ps     | compares cluster in stages 0–1; lookup and subtract each own a late stage |

The gate passes: same IR, three architecturally distinct Verilogs by toggling codegen constraints alone. **Key methodology takeaway:** `--pipeline_stages` alone produces buffer stages if the clock is loose. To get a real distributed pipeline, drive `--clock_period_ps` near the minimum feasible for the chosen stage count.

### 2g — Inspect the computation graph (optional)

The optimized IR *is* the dataflow graph — every node lists its operands — so it answers structural questions directly: how many comparators, what collects their results, which nets fan out widely. XLS ships no graph exporter in the `xls-bin/bin/` release (the IR visualizers under `external/xls/xls/visualization/` are source-only and would need a Bazel build), so `flows/ir_to_dot.py` parses the IR into Graphviz and renders it.

Parsing and DOT emission are stdlib, so the DOT text needs no environment:

```bash
python3 flows/ir_to_dot.py runs/sky130/binner_8x4.opt.ir --format dot -o /tmp/binner.dot
```

Rendering to SVG/PNG shells out to `dot`, which the `ppa-study` conda env provides (`graphviz` is in `environment.yml` — see §5c for the env):

```bash
mamba run -n ppa-study python flows/ir_to_dot.py runs/sky130/binner_8x4.opt.ir
# -> runs/sky130/binner_8x4.opt.svg  (output defaults to the input path with the format extension)
```

Nodes are coloured by operation class (comparator / mux / arithmetic / array read / bit-op / literal / input / output) and edges run operand → consumer (`--rankdir TB` puts inputs at the top). For the `bw8_nb4` parallel point you see `global_index` fanning out to three `uge` comparators in parallel, a `sel`/`concat`/`add` cluster collapsing the thermometer bits into `bin_index` (a popcount), then the `lbb[bin_index]` lookup and the `sub` producing `local_index`. The script also prints a **fanout report**: here `global_index` and `lower_bin_boundaries` each have out-degree 4 — the high-fanout broadcast nets behind the M3 max-slew finding.

It renders the `top` function by default. For the *pre-optimisation* IR (where the loop is still a `counted_for` in a separate function) pass `--fn __binner__binner__2_8_4` to see that form. See `flows/ir_to_dot.py --help`.

### 2h — Where the clock goes (critical path, pre-PnR)

`delay_info_main` reports each node's delay and the critical path under a delay model — XLS's pre-PnR timing estimate, and the cheapest way to see what sets the clock before committing to a librelane run. It prints the critical path *and* every node's delay (long output — pipe it to a pager, or isolate the critical path with `sed`):

```bash
./external/xls-bin/bin/delay_info_main --delay_model=sky130 \
    runs/sky130/binner_8x4.opt.ir | sed -n '/# Critical path/,/# Delay of all/p'
# (drop the sed and pipe to `less` to also see the per-node delay list)
```

For the `bw8_nb4` binner the critical path is 1809 ps — exactly the §3a single-stage minimum clock — and reads (down the dependency chain):

```
uge.81             309 ps   <- one comparator (the only compare on the path)
  -> sel.88       +199 ps   ┐
  -> sel.90       +199 ps   ├ popcount collector
  -> bin_index    +170 ps   ┘
  -> array_index.94 +423 ps <- lbb[bin_index] lookup (a mux on bin_index)
  -> local_index  +509 ps   <- global_index - lbb[bin_index]
  = 1809 ps
```

Two things to read off it:

- **The parallel comparators are not the bottleneck.** In the full per-node list all three `uge` nodes are 309 ps *each* and run in parallel, so the path crosses only one of them (309 ps — 17 % of the total). The other 83 % is the *serial* chain after the compares: collect → look up → subtract. That is why the single-stage clock is long, and why pipelining (§2e) helps by slicing that *depth* — it does nothing to the already-parallel compares.
- **Pipelining can't beat the slowest single node.** `local_index`'s subtraction is 509 ps on its own, and the 4-stage minimum clock is *exactly* 509 ps: the scheduler cuts *between* nodes, never *through* one. This is the hard floor that the §2e stage map runs into (subtract alone owns stage 3).

This is the timing companion to §2g: the graph shows *what* is computed and how it fans out; this shows *how long* each step takes and what therefore bounds the clock. It also explains the §2e stage assignment — the cheap parallel compares pack into the early stages, while the expensive single nodes (lookup, subtract) each claim a stage of their own.

**Scaling check at the largest grid point — `bw16_nb16`.** Re-running `delay_info_main` on `runs/sky130/parallel/bw16_nb16/binner.opt.ir` gives 4986 ps with this profile (the `pos=` columns are elided here for readability):

```
uge.241                399 ps    8 %   one 16-bit comparator (15 in parallel)
sel.246/.403/.628/.415/.634/.640/.646
  + interleaved add.328/.653/.657/.661/.665   serial mux/add chain over 7
  + bin_index merge: bin_index_assoc + bin_index               of 15 cmps (left fold)
                       =  3327 ps    67 %                +
                                                              balanced add-tree
                                                              over the other 8
array_index.319        585 ps   12 %   16:1 16-bit lookup mux on bin_index
local_index            675 ps   13 %   16-bit subtract
                      ─────────
                      4986 ps  100 %
```

Two reads:

- **The popcount went from 31 % of the budget at `bw8_nb4` to 67 % at `bw16_nb16`.** The optimizer keeps the first ~7 comparators in the fold's mux/add chain (the pattern from §2h above, just longer) and switches to a balanced adder tree for the remainder, then merges. The serial arm is what bin_index waits on, so the depth scales near-linearly with `n_boundaries`. The lookup mux (log-depth in cases) and the subtractor (width) both scale much more slowly.
- **Post-PnR, the tt corner still closes cleanly.** At a 10 ns clock the nom_tt setup ws is +0.977 ns with zero max-slew violations; max_tt setup ws is +0.848 ns with 11 max-slew warnings that don't break setup. The ss corner does *not* close (setup ws -7.16 ns, 121 max-slew violations on `global_index` broadcast nets) — that's a separate signoff-config problem, not a structural fanout failure. Yosys/OpenROAD spend ~22 % of all stdcells (472 timing_repair_buffer + 59 setup_buffer out of 2369) absorbing the fanout pressure that lets tt close at all.

Together these motivate the popcount rewrite tracked in `THERMOMETER.md`: the segment that dominates the budget at large `n_boundaries` is exactly the one whose structure ignores the monotonicity contract.

**Post-PnR comparison of the `prio` rewrite (THERMOMETER Sketch B).** `dslx/binner.x` ships two variants now — `binner` (the fold reference) and `binner_prio` (the `ctz(!cmps)` priority encoder that exploits the monotonicity contract). Select with `./flows/run_point.sh --variant {ref,prio}`; the prio runs land under `runs/sky130/parallel_prio/...` so they don't clobber the reference grid. The XLS opt pass collapses `ctz(!cmps)` into two canonical IR ops with log-depth delay models: `one_hot(c, lsb_prio=true)` followed by `encode(...)`. Running librelane Classic at a 10 ns clock on both points gives:

| metric                    | bw8_nb4 ref | bw8_nb4 prio | bw16_nb16 ref | bw16_nb16 prio |
| ------------------------- | ----------- | ------------ | ------------- | -------------- |
| XLS pre-PnR crit path     |  1809 ps    |   1510 ps    |  4986 ps      |  **2219 ps**   |
| post-PnR path (nom_tt)    |   4.71 ns   |   5.32 ns ⚠   |   9.02 ns     |  **7.98 ns**   |
| nom_ss setup ws           |  +0.77 ns   |  -0.39 ns ⚠   |  -6.96 ns     |  **-5.14 ns**  |
| core area (µm²)           |  5010       |   5107       | 32454         | 32619          |
| total power (mW, vectorless) | 0.82    |   0.77       | **16.27**     |  **3.54**      |
| max-slew viols (max_ss)   |   11        |    11        |   121         |   239 ⚠         |

Three reads:

- **At scale the rewrite delivers, in line with the XLS estimate.** `bw16_nb16` post-PnR critical path drops 9.02 → 7.98 ns (-11.6 %), the ss-corner failure halves, and vectorless power falls ~4.6×. The power swing follows from depth: activity propagation through the fold's 7-deep mux chain feeds many more switching events into the estimator than the prio variant's 2–3-level `one_hot + encode` tree.
- **At small scale the rewrite *regresses*.** `bw8_nb4` post-PnR path goes 4.71 → 5.32 ns (+13 %), and ss flips from +0.77 ns slack (passes!) to -0.39 ns (fails by 0.4 ns). The XLS estimate had prio faster (1510 < 1809 ps), but Yosys/ABC techmap a 4-bit `one_hot` priority encoder less efficiently than the fold's three 2-input muxes — there is a crossover in `n_boundaries` between 4 and 16 below which the fold is the right shape. Locating that crossover is what the next sweep is for.
- **Max-slew viols at scale are slightly worse with prio.** The `one_hot` mapping introduces some high-fanout broadcast nets the resizer doesn't fully tame at the ss corner (9 viols at nom_tt that prio didn't have either, 239 vs 121 at max_ss). Still doesn't break tt setup, but it's the new structural cost.

The XLS rewrite is in `dslx/binner.x:binner_prio` with mirrored deterministic tests; `prove_quickcheck_main` symbolically proves `binner_prio == binner` over all 256 (u8) and 65 536 (u16) `global_index` values for fixed monotonic bound arrays.

## 3 — M3: one Verilog through librelane sky130 PnR

M2 generated Verilog optimised for *inspection*. None of those three variants drops directly into librelane Classic flow:

- The combinational one has no clock → librelane synthesises a `__VIRTUAL_CLK__`, then fails at CTS / timing repair (no real flops to register against).
- Both pipelined variants use SystemVerilog array-literal syntax (`'{...}`) by default → Yosys V2005 parser chokes.

So M3 uses a fourth codegen point — **one pipeline stage with registered I/O, emitted as plain V2005** — that fits librelane's expectations. This corresponds to the "parallel architecture, registered I/O" point that's PPA-meaningful in a real chip context.

### 3a — Codegen: registered-I/O parallel variant in plain V2005

```bash
mkdir -p runs/sky130/pipe_s1_2000ps/bw8_nb4
./external/xls-bin/bin/codegen_main \
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
python3 flows/extract_metrics.py \
    "$(ls -dt flows/librelane/binner_8x4/runs/RUN_* | head -1)/final/metrics.json"
```

The extractor (`flows/extract_metrics.py`, ~70 lines of Python) reads the `final/metrics.json` librelane writes for every successful or partially-successful run, and prints the keys that matter for this study. The full JSON has hundreds of keys; if you want to see them all, just `cat`/`jq` the file directly.

**Python environment for this script:** stdlib only (`json`, `sys`) — no third-party packages. Runs against whatever `python3` resolves to on PATH; the conda env `ppa-study` python and the nix-shell python both work. Aggregation + plotting (§5) needs the conda env for matplotlib; functional verification (§4) needs it for cocotb + iverilog.

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

## 4 — M4a: cocotb RTL functional verification

This section runs **without librelane** — pure Path A. Drives the codegen `binner.v` cycle-by-cycle with random stimulus and checks against the Python reference in `verif/binner_ref.py`. The full design rationale is in `COCOTB.md`; here is the reproduction.

### 4a — A single point

```bash
mamba run -n ppa-study python verif/runner.py \
    --verilog runs/sky130/parallel/bw8_nb4/binner.v
```

The runner reads `point.json` next to the verilog to pick up `bw_global`, `n_bounds`, `pipeline_stages`. CLI flags (`--bw-global`, `--n-bounds`, `--stages`, `--simulator {icarus,verilator}`, `--seed`, `--num-bound-sets`, `--trials-per-set`) override. Build/results land under `runs/_verif/build/<tag>/` so the runs tree consumed by `plot_pareto.py` stays clean.

**Expected:** the final line reads `[verif] OK — 1/1 tests passed`. Wall time ~0.13 s at `bw16_nb16`; ~4096 vectors per point.

### 4b — The whole grid

`flows/run_verif.sh` mirrors `run_sweep.sh` in shape: it enumerates `variants × archs × bw_global × n_bounds`, looks up `runs/<model>/<arch_tag>/bw<bw>_nb<nb>/binner.v`, and dispatches `verif/runner.py` per point.

```bash
./flows/run_verif.sh --variants "ref prio" --bw-global "4 8 12 16" --n-bounds "2 4 8 16"
```

Per-point logs land in `runs/_verif/<timestamp>/<tag>.{log,status}`; the summary tallies `OK` / `FAIL` / `MISSING (codegen first)`. Only `FAIL` gates the exit status — `MISSING` is a soft skip for points whose codegen hasn't been run yet (`run_sweep.sh --skip-pnr` produces those without needing librelane).

This is decoupled from PnR: verif only needs `binner.v`, so it can chase `run_sweep.sh --skip-pnr` without ever touching librelane. That matches the distributed-workflow model (codegen + verify on machine A, PnR on machine B).

## 5 — Sweep and Pareto frontier (M6, M8)

Sections 1–3 walk the flow by hand for one point. `flows/run_point.sh` automates exactly that chain (generated DSLX top → `ir_converter` → `opt` → `codegen` → librelane → `extract_metrics`) for any `(arch, bw_global, n_bounds, variant)`; `flows/run_sweep.sh` runs a grid of points in parallel; and `flows/plot_pareto.py` turns the results into a CSV table and Pareto plots.

### 5a — One point via the script

```bash
# Reproduces the section-3 baseline, into runs/sky130/parallel/bw8_nb4/.
./flows/run_point.sh --bw-global 8 --n-bounds 4
```

Each point writes only to `runs/<delay_model>/<arch>/bw<BW>_nb<NB>/` and skips if its result already exists (`--force` rebuilds, `--skip-pnr` does the fast XLS-only half). `--arch pipeline --stages N` selects a deeper pipeline; the codegen clock is auto-probed by default. See `./flows/run_point.sh --help`.

### 5b — The grid

```bash
./flows/run_sweep.sh --dry-run                    # print the grid, run nothing
./flows/run_sweep.sh                              # default: parallel (1 stage) × bw {4,8,12,16} × nb {2,4,8,16}
./flows/run_sweep.sh --arch "parallel pipe_s4"    # opt back into a pipelined point if a critical path is too long
./flows/run_sweep.sh --jobs 4 --librelane-jobs 4  # OUTER points × INNER librelane threads (≈ nproc)
```

The default grid fixes one architecture (1 pipeline stage) and sweeps the build-time parameters `bw_global` × `n_boundaries` — that's the active focus (see `PLAN.md`); multi-stage pipelining is an opt-in via `--arch`. It dispatches points through GNU parallel when present (else a dependency-free bash job pool), logs each point under `runs/_sweeps/<timestamp>/`, and prints an OK/FAIL summary. Re-run to resume — finished points are skipped. librelane is ~5 min/point; the 16-point default grid is roughly 20 minutes at 4×4 on a 16-core box.

### 5c — Aggregate and plot the frontier

Only plotting needs matplotlib; aggregation, the CSV, and the Pareto math are stdlib. Create the env once (miniforge `mamba`, or `conda`):

```bash
mamba env create -f environment.yml                    # or: conda env create -f environment.yml
mamba run -n ppa-study python flows/plot_pareto.py     # or: conda activate ppa-study && python flows/plot_pareto.py
```

`plot_pareto.py` walks `runs/` (keeping one delay model — `--delay-model sky130` by default, since PnR metrics are sky130-only; see METRICS.md §7) and writes:

- `results/ppa_sweep.csv` — the flat table (committed; one row per point: provenance + area/power + **two critical-path numbers**, `xls_crit_path_ns` pre-PnR and `pnr_crit_path_{tt,ss}_ns` post-PnR = `librelane_clock − r2r setup ws`, plus `max_slew_viol_ss`).
- scaling plots `results/scaling_{area,critpath,power}_vs_n_bounds.png` — each metric vs `n_boundaries`, one line per `bw_global` (the critical-path plot overlays the XLS estimate dashed and the post-PnR ss solid, so the optimism gap is visible); pass `--x bw_global` to put bitwidth on the x-axis instead.
- frontier plots `results/pareto_area_vs_critpath.png` and `…_area_vs_power.png` — all points with the Pareto front marked (gitignored).

To **regenerate** at any time, re-run that `plot_pareto.py` line — it re-reads whatever is under `runs/`. The CSV and printed table need no env: `flows/plot_pareto.py --no-plot` runs from the bare nix-shell; only the PNGs require the `ppa-study` env. Note the ss critical path can be inflated by max-slew violations on high-fanout nets (`max_slew_viol_ss` flags it) until signoff is tuned — see METRICS.md §4.

## 6 — Cleanup

To wipe everything regenerable (gitignored only):

```bash
rm -rf runs/ flows/librelane/binner_8x4/runs/ flows/librelane/binner_8x4/binner.v results/*.png
```

To re-run from scratch, repeat sections 1–3 (hand-walked) or section 5 (scripted); section 4 is independent and re-runs against whatever Verilog is currently under `runs/`.

## 7 — Where everything lives

Committed:

```
HOWTO.md                                 this file
README.md                                project intro + entry paths + orientation
CLAUDE.md                                operational guidance for Claude Code
PLAN.md                                  study plan: parameters, milestones, optional extensions
BLUEPRINT.md                             guide to reusing this repo for a different PPA study
METRICS.md                               where every PPA number comes from (tool, layer, fidelity)
COCOTB.md                                cocotb RTL functional verification (M4a)
THERMOMETER.md                           monotonic-threshold design space (Sketch B = binner_prio)
DESIGN_NOTES.md                          candidate designs we discussed but didn't build
dslx/binner.x                            parametric DSLX function (fold + prio variants) + tests
dslx/binner_top_8x4.x                    concrete top instantiation for §2 (BW=8, N=4)
verif/binner_ref.py                      canonical Python reference (M4a)
verif/test_binner.py                     parametric cocotb test (M4a)
verif/runner.py                          cocotb runner CLI (M4a)
flows/librelane/binner_8x4/config.json   librelane Classic flow config (§3 baseline)
flows/extract_metrics.py                 PPA summary extractor (stdlib-only)
flows/run_point.sh                       one design point, end to end — wrapper (M6, §8)
flows/run_point_xls.sh                   one point, XLS half only — needs XLS binaries (§8 machine A)
flows/run_point_pnr.sh                   one point, PnR half only — needs librelane (§8 machine B)
flows/run_sweep.sh                       grid of points in parallel; --phase {xls,pnr,both} (M6, §8)
flows/run_verif.sh                       grid of cocotb verifications (M4a)
flows/pull_xls_artifacts.sh              forward-only mailbox sync (§8 distributed)
flows/plot_pareto.py                     sweep aggregation + Pareto plots (M8)
flows/ir_to_dot.py                       XLS IR -> Graphviz computation graph + fanout report
environment.yml                          conda env (cocotb, iverilog, verilator, matplotlib, graphviz)
results/ppa_sweep.csv                    aggregated PPA table (committed)
```

Gitignored (regenerated by following this HOWTO):

```
runs/sky130/binner_8x4*.ir               XLS IR from the hand-walked sections 2a/2b
runs/sky130/{comb,pipe_s4_2000ps,pipe_s4_500ps,pipe_s1_2000ps}/bw8_nb4/
                                         per-codegen-variant Verilog + metrics (sections 2c–3a)
flows/librelane/binner_8x4/{binner.v,runs/}   hand-walked librelane input + artifacts (section 3)
runs/<model>/<arch>/bw<BW>_nb<NB>/        scripted points: top.x, IR, Verilog, metrics.json, point.json
runs/_sweeps/<timestamp>/                 run_sweep.sh dispatch logs + joblog
runs/_verif/<timestamp>/                  run_verif.sh dispatch logs + per-point build dirs
results/*.png                            Pareto plots (regenerate via plot_pareto.py)
```

## 8 — Distributed: codegen on one machine, PnR on another

When the XLS+cocotb half (Path A) and the librelane half (Path B) live on different machines, the forward-only **mailbox** pattern keeps the workflow simple: machine A produces `binner.v` and provenance in its `runs/` tree; machine B mounts A's repo read-only, pulls codegen artifacts into its own `runs/`, and invokes librelane locally. PnR runs entirely against local disk — never over the network.

### Machine roles and per-machine scripts

The flow is split into three entry-point scripts so it's structurally impossible to run an XLS-binary-needing step on B (or a librelane-needing step on A):

| Script                       | Needs        | Machine | Runs                       |
| ---------------------------- | ------------ | ------- | -------------------------- |
| `flows/run_point_xls.sh`     | XLS binaries | **A**   | DSLX → IR → opt → Verilog  |
| `flows/run_point_pnr.sh`     | librelane    | **B**   | librelane Classic + metrics |
| `flows/run_point.sh`         | both         | local   | wrapper chaining XLS + PnR (single-machine convenience) |
| `flows/run_verif.sh`         | conda env    | **A**   | cocotb RTL verification    |
| `flows/run_sweep.sh --phase` | per phase    | A or B  | grid of points; `--phase {xls,pnr,both}` |
| `flows/pull_xls_artifacts.sh`| rsync        | **B**   | mailbox sync from a mounted A |

If you ever see "XLS binaries not found" on B, you ran an XLS-half script there. If you see "librelane not on PATH" on A, you ran a PnR-half script there. The split prevents accidents; the error messages tell you the right command.

### On machine A — codegen + verify

```bash
mamba activate ppa-study                  # the conda env (Path A)

# 1. Codegen the whole grid (no librelane needed).
./flows/run_sweep.sh --phase xls

# 2. Verify every Verilog functionally with cocotb.
./flows/run_verif.sh
```

For a single point during iteration:

```bash
./flows/run_point_xls.sh --bw-global 8 --n-bounds 4
python verif/runner.py --verilog runs/sky130/parallel/bw8_nb4/binner.v
```

### On machine B — mount, pull, PnR, aggregate

```bash
cd /PATH/TO/YOUR/LIBRELANE && nix-shell    # Path B: librelane available
cd /PATH/TO/PPA_STUDY
mamba activate ppa-study                   # for extract_metrics + plot_pareto

# 1. Mount A's repo read-only.
mkdir -p ~/mnt/ppa-xls
sshfs -o ro userA@machineA:/PATH/TO/PPA_STUDY ~/mnt/ppa-xls

# 2. Pull the codegen artifacts (idempotent; re-run as A produces more).
./flows/pull_xls_artifacts.sh ~/mnt/ppa-xls

# 3. Run PnR for the grid (no XLS binaries needed).
./flows/run_sweep.sh --phase pnr

# 4. Aggregate. B has A's point.json (pulled) and B's metrics.json (just
#    produced) so the join is complete.
mamba run -n ppa-study python flows/plot_pareto.py

# 5. Unmount.
fusermount -u ~/mnt/ppa-xls
```

For a single point during iteration:

```bash
./flows/run_point_pnr.sh --bw-global 8 --n-bounds 4
```

### What the mailbox transfers

`pull_xls_artifacts.sh` uses `rsync` with explicit include rules: only the codegen output transfers (`binner.v`, `top.x`, `binner.ir`, `binner.opt.ir`, `binner.metrics.textproto`, `binner.schedule.textproto`, `point.json`). librelane outputs (`metrics.json`, `RUN_*` dirs), per-point summaries (`ppa_summary.txt`, `config.json`), and dispatch logs (`_sweeps/`, `_verif/`) stay local to whichever machine produced them. No structural change to the repo, no shared mutable state, no PnR-over-sshfs.

### Notes

- **Single-machine workflows are unchanged.** `flows/run_point.sh` and `flows/run_sweep.sh` (default `--phase both`) keep working exactly as before — they chain the XLS half and the PnR half on one machine. The split scripts are *additional* entry points, not replacements.
- **`--librelane-clock-ns` should match between machines.** The XLS script writes this value to `point.json` so `plot_pareto.py` can compute the post-PnR critical path; the PnR script rewrites it with whatever value PnR actually used, so a mismatch self-heals after PnR runs. Default `10` on both is fine for the common case.
- **HOWTO §3 hand-walked path on B.** The hand-walked path expects `flows/librelane/binner_8x4/binner.v` (a copy of one specific point's Verilog into the librelane config dir). After the pull, that file is *not* there — it's at `runs/sky130/pipe_s1_2000ps/bw8_nb4/binner.v` instead. Either copy it manually (`cp runs/sky130/pipe_s1_2000ps/bw8_nb4/binner.v flows/librelane/binner_8x4/`) or just use the scripted path (`flows/run_point_pnr.sh`) which doesn't need that copy.
- **Reverse direction (B → A).** Not handled by this script. If you want A to see B's metrics (e.g., A is also running aggregation), the simplest is to mount B on A and `rsync` `metrics.json`/`ppa_summary.txt`. The forward-only design fits the common A=dev/codegen, B=headless-worker split.
- **Concurrent runs.** Don't run librelane against the same point dir on both machines at once. The mailbox keeps codegen artifacts read-only on A while B does PnR, so the natural ownership is unambiguous.
