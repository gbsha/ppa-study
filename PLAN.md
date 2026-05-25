---
format: pdf
---

# PLAN.md

The PPA study plan: what is being swept, how the architectures are produced, and what limits we've already discovered. Update this file as the methodology evolves; keep `CLAUDE.md` for general repo guidance.

## Function under study

See `README.md` for the Python reference. Returns `(bin_index, local_index)` from a `global_index` and a runtime-programmable `upper_bin_boundaries` list. The refinement constrains each threshold to `threshold_i_m << threshold_e` with a shared exponent `threshold_e`, so comparators only need to compare `bw_threshold_m` bits.

## Build-time parameter sweep

The axes for the PPA characterization are all **buildtime** parameters of the DSLX module:

- `bw_global_index` — bitwidth of `global_index` and (in the unrefined version) of each threshold entry.
- `n_boundaries` — number of entries in `upper_bin_boundaries` (active count is runtime-set; inactive entries hold a sentinel).
- `bw_threshold_m` — mantissa bitwidth of `threshold_i_m` in the refined form. This is the comparison-width knob; sweeping it shows how much PPA is saved by the mantissa/exponent decomposition vs. the unrefined `bw_global_index`-wide compare.

`threshold_e` and the active-entry count are firmware-programmable and therefore *not* part of the buildtime sweep — they're inputs to the synthesized hardware.

## Architecture strategy: one DSLX source, multiple architectures via constraints

The intent is: write the binning algorithm once in DSLX and let XLS's scheduler produce different architectures by varying codegen constraints (`--delay_model`, `--clock_period_ps`, `--pipeline_stages`, `--period_relaxation_percent`). The `external/xls/docs_src/scheduling.md` §"Sweep the entire scheduling space" section documents exactly this pattern.

What this **can** produce from one feed-forward DSLX function:

- **Fully combinational / parallel** — `--generator=combinational`, or `--generator=pipeline --pipeline_stages=1` with a relaxed clock. All `n_boundaries` comparisons in one cycle.
- **N-stage pipelined** — `--generator=pipeline` with tighter `--clock_period_ps` and/or larger `--pipeline_stages`. The SDC scheduler partitions ops across stages to meet timing.

What this **cannot** produce from a single feed-forward function:

- **TDM (one comparator reused across cycles)** — XLS schedules a "sea of nodes" into feed-forward stages (`delay_estimation.md`: *"XLS currently supports feed-forward pipelines"*). It will not fold N parallel comparisons into one shared comparator over N cycles, because that requires state. TDM therefore needs to be written separately as a **proc with channels and state** (see `external/xls/docs_src/tutorials/how_to_use_procs.md` and `what_is_a_proc.md`). It's a different source file, not a different flag set.

Practical consequence: expect (at least) two DSLX implementations — a function for the parallel/pipelined family, and a proc for TDM. The function form covers most of the design space via scheduler sweeps; the proc form is needed only for the time-multiplexed point.

## Technology: phase 1 sky130, phase 2 asap7

The work is split in two phases so we move on the intersection of out-of-the-box support before stretching the toolchain.

### Phase 1 (current): sky130 only

`--delay_model=sky130` everywhere; full DSLX → IR → Verilog → librelane (Yosys + OpenROAD) → PPA flow with no toolchain modification. This is the intersection of what XLS, librelane, OpenROAD, and Yosys support out of the box and is what the rest of this plan assumes unless explicitly marked phase 2.

Even though phase 1 only uses one model, **don't hard-code `sky130` into directory layouts, filenames, or run-script defaults** — leave a `<delay_model>/` level (or equivalent column) in place so phase 2 lands additively rather than as a restructure.

### Phase 2 (deferred): add asap7 for technology-scaling trends

**Why:** the downstream interest is implementation in a recent advanced node (TSMC N2), for which no open-source PDK exists. sky130 → asap7 is used as an open-source proxy for "what shifts as geometry shrinks." Goal is **qualitative** scaling indications — does the TDM area penalty shrink at smaller nodes? does the fully-parallel architecture become more wiring-limited? — not quantitative N2 predictions; 130 nm → 7 nm → 2 nm is much too coarse an extrapolation for absolute numbers.

**Known status of asap7 across the stack:**

- XLS scheduling: works out of the box. Smoke-tested 2026-05-23 — `./external/xls-bin/codegen_main` registry exposes `asap7, sky130, unit` (discoverable by passing a bogus `--delay_model`, which enumerates valid names). End-to-end `ir_converter_main → opt_main → codegen_main --generator=pipeline --delay_model={sky130,asap7,unit} --clock_period_ps=2000 --pipeline_stages=1 --reset=rst` on `fn add8(a:u8, b:u8) -> u8 { a + b }` produced valid SystemVerilog with exit 0 for each model.
- OpenROAD: reportedly supports asap7.
- Librelane (the nix-shell): unknown — likely needs custom configuration to register an asap7 PDK and flow. This is the actual phase 2 work item; don't attempt it during phase 1.

**Phase 2 entry criteria:** phase 1 is producing PPA numbers we trust on sky130, and we know what to compare across the two models. If librelane asap7 PnR turns out to need significant custom work, an interim fallback is to report asap7 results at the XLS scheduling level only (critical path, register count, scheduled stages from `--block_metrics_file`) — still useful for trend comparison even without place-and-route power/area.

## Execution plan — phase 1

Vertical-slice-first: prove one parameter point through every layer before building sweep machinery or writing additional architectures. Milestones below; gate = unambiguous yes/no check that must pass before the next milestone starts.

**Active path (decided 2026-05-25): first Pareto frontier before broadening.** M1–M3 are done. The immediate goal is the smallest end-to-end *result* that demonstrates the methodology — a small sweep (M6) over the parallel/pipelined architectures the single feed-forward source already produces, plotted as a two-axis Pareto frontier (M8): e.g. area vs. minimum closing clock period, or area vs. power. Everything that doesn't move that picture is sequenced after it: the refined form (M5), the TDM proc (M7), and external-tool functional verification (M4). Rationale: the deliverable of this study is the *shape* of the frontier; functional re-verification and extra architectures add confidence and breadth but don't change that shape, so they follow the first picture rather than precede it.

### Repo layout

```
dslx/      binner.x (M1), binner_refined.x (M5), binner_tdm.x (M7)
flows/     codegen.sh, run_point.sh (M6), librelane/ configs
runs/      gitignored: runs/<delay_model>/<arch>/<params>/
results/   committed metrics tables
```

Even though phase 1 uses only sky130, `<delay_model>/` is already a directory level so phase 2 lands additively.

### Milestones

- **M1 — DSLX reference (unrefined form).** Parametric `binner.x` matching the Python in `README.md`, with `#[test]` cases for boundary values, sentinel-for-inactive-entries, and mid-range points. **Gate:** `interpreter_main --compare=jit dslx/binner.x` exits 0.

- **M2 — Multi-architecture codegen from one source (load-bearing strategy check).** For one small point (`bw_global_index=8, n_boundaries=4`), generate Verilog twice from the same IR: `--generator=combinational` and `--generator=pipeline --delay_model=sky130 --clock_period_ps=2000 --pipeline_stages=4`. **Gate:** `--output_schedule_path` shows >1 stage for the pipelined case *and* register count is meaningfully higher than the combinational case. If this fails, the "one DSLX, scheduler-driven architectures" thesis is wrong — re-plan before continuing.

- **M3 — One Verilog through librelane on sky130 (load-bearing PnR check).** Take M2's combinational Verilog, write a minimal librelane config, run the Classic flow from the CLI. **Gate:** flow completes; final metrics (area, timing slack, power) are produced.

- **M4 [deferred by priority — external-tool verification].** `simulate_module_main` is not shipped and never will be (it can't be linked statically), so RTL- and gate-level functional verification uses **cocotb** driving iverilog/verilator against the generated `.v` and the post-synthesis netlist — not a missing XLS binary. This is a correctness gate, not an exploration gate: it doesn't change PPA numbers or the shape of the frontier, so it is deliberately sequenced *after* the first Pareto result (M6→M8). Until then: M1's DSLX `#[test]` + `--compare=jit` give DSLX↔IR equivalence, XLS's IR→Verilog codegen is upstream-tested, and `lec_main` (now present) offers a cheap formal RTL-vs-netlist equivalence check if a gate-level sanity gate is wanted before the full cocotb effort. A parametric cocotb bench is build-once-reuse-across-sweep-points, so the eventual cost is bounded.

- **M5 — Refined (mantissa/exponent) form.** Add `binner_refined.x`; re-run M1–M3 gates. **Gate:** refined-form area/timing measurably differs from unrefined; if not, investigate whether `opt_main` recognises the `_m << _e` pattern as a narrower compare, or whether DSLX needs to extract the mantissa explicitly.

- **M6 — Sweep runner.** Shell script wrapping M1–M3 for `(arch_knobs, params, delay_model)` → metrics JSON, with input-hash caching. **Gate:** re-running M2's point reproduces M2's metrics byte-identically. **Pipeline-knob choice (from M2):** `--pipeline_stages=N` alone produces pass-through buffer stages if the clock period is loose. To get an actually-distributed schedule, drive `--clock_period_ps` near the minimum-feasible value for the chosen stage count. XLS's "cannot achieve clock period; try X ps" error is the cheapest way to find that minimum — issue a deliberately-too-tight clock and parse the suggestion.

- **M7 [proc verification gated on `eval_proc_main`].** TDM proc variant `binner_tdm.x`. Writing + codegen + librelane works with the current tools; full proc-level verification needs `eval_proc_main`, which is still absent from `xls-bin` (flag to the maintainer when reached) — or, alternatively, the cocotb bench from M4 once it exists. Latency-vs-throughput metric definition must be decided before building so TDM numbers are apples-to-apples with the function variants.

- **M8 — Small sweep + analysis (the first deliverable).** Run a small parameter grid (start ~3×3×3 per architecture; iterate width if interesting trends warrant) across the unblocked architectures. The concrete first output is a **two-axis Pareto plot** of the design points (e.g. area vs. minimum closing clock period, or area vs. power) so the frontier is visible. **Gate:** trends are monotonic where expected; parallel/pipelined tradeoff visible. TDM joins once M7 unblocks. **Signoff-config work to fold in here (from M3):** address max-slew violations at the ss corner — likely needs explicit `MAX_TRANSITION_CONSTRAINT` tuning or resizer-repair iterations beyond defaults. Also, the librelane clock period should be deliberately swept (not just relaxed to make signoff pass); each architecture has a different fastest closing clock and that's part of the PPA story. **Python environment lands here:** stdlib has been sufficient through M3 (see `flows/extract_metrics.py`), but M8 brings pandas/numpy/matplotlib for sweep aggregation and plotting. Create `environment.yml` at the repo root (conda-forge first, pip for anything missing), document the `conda env create -f environment.yml && conda activate ppa-study` step in HOWTO, and run all analysis code from that env. Keep `flows/extract_metrics.py` stdlib-only so the per-point extraction stays usable from a bare nix-shell without env activation.

### Consolidation gate (between M3 and M5)

After M3, the repo went through a deliberate consolidation: `HOWTO.md` walks through M1–M3 from a clean clone with every command and config shown; `flows/librelane/binner_8x4/config.json` is the committed librelane config; `flows/extract_metrics.py` is the committed PPA extractor (replacing inline `python3 -c "..."` snippets); README's "Toolchain status" section documents the `xls`/`xls-bin` pinning and the `simulate_module_main` gap from the first time anyone opens the repo. **Don't advance past this gate without the user manually re-walking the HOWTO** — the consolidation exists to make sure every methodology choice is understood, not just demonstrated.

### M3 outcome — librelane sky130 PnR is validated

The full DSLX → IR → Verilog (pure V2005, `--use_system_verilog=false`) → librelane Classic flow → sky130 PnR pipeline works end-to-end. Baseline for `binner` parallel architecture, `bw_global_index=8, n_boundaries=4`, librelane CLOCK_PERIOD=10 ns: core area 5010 µm², die area 7590 µm², stdcell util 68.7%, power 0.82 mW, WNS clean at all PVT corners. Two structural lessons:
1. Pure-combinational (`--generator=combinational`) Verilog has no clock and librelane's Classic flow can't handle it — wedges at CTS/timing-repair with a synthetic `__VIRTUAL_CLK__`. "Parallel architecture" for PPA must mean *one pipeline stage with registered I/O* (`--generator=pipeline --pipeline_stages=1`), not zero-flop combinational.
2. `--use_system_verilog=false` is required for Yosys (V2005 parser chokes on SV array-literal `'{...}`). Cost is more verbose Verilog, no functional impact. Set this in the sweep runner's codegen defaults.

Phase 2 (asap7 via librelane) starts after M8.

## Open questions

(All scoped to phase 1; the librelane-asap7 question lives in the Phase 2 section above.)

- For the refined threshold form, is a clean DSLX expression possible that lets the scheduler exploit the reduced-bitwidth compare (i.e., does `opt_main` recognise the `_m << _e` pattern as a narrower compare), or does the DSLX need to explicitly extract the mantissa before comparing?
- What's the right metric layer between XLS and librelane — feed Verilog straight in, or also export the XLS scheduling report / block metrics (`--block_metrics_file`) for cross-checking?
- For the proc-based TDM variant: latency is measured how — total cycles per result, or steady-state throughput? Decide before building so the comparison across architectures is apples-to-apples.
