---
format: pdf
---

# PLAN.md

The PPA study plan: what is being swept, how the architectures are produced, and what limits we've already discovered. Update this file as the methodology evolves; keep `CLAUDE.md` for general repo guidance.

## Function under study

See `README.md` for the Python reference. Returns `(bin_index, local_index)` from a `global_index` and a runtime-programmable `lower_bin_boundaries` list. The refinement constrains each threshold to `threshold_i_m << threshold_e` with a shared exponent `threshold_e`, so comparators only need to compare `bw_threshold_m` bits.

## Build-time parameter sweep

The axes for the PPA characterization are all **buildtime** parameters of the DSLX module:

- `bw_global_index` — bitwidth of `global_index` and (in the unrefined version) of each threshold entry.
- `n_boundaries` — number of entries in `lower_bin_boundaries` (active count is runtime-set; inactive entries hold a sentinel).
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

## Technology — sky130 (default) and asap7 (XLS layer only)

What's shipped works at the intersection of XLS, librelane, OpenROAD, and Yosys out-of-the-box support: **full DSLX → IR → Verilog → librelane → PPA on sky130**, and **XLS delay-model metrics on sky130 and asap7**. Even though only sky130 reaches the librelane layer, the directory layout has a `<delay_model>/` level so a second technology lands additively, not as a restructure — don't hard-code `sky130` into directory layouts, filenames, or run-script defaults.

### sky130 — the default

`--delay_model=sky130` everywhere; the full chain runs without toolchain modification.

### asap7 — XLS delay-model metrics only

`--delay_model=asap7` works in XLS today (smoke-tested 2026-05-23) — e.g. `bw8/nb4` is **767 ps on asap7 vs 1809 ps on sky130** on the same RTL. That gives a clean cross-node *trend* signal (critical path, flop count, BOM) at zero PDK cost. **librelane does *not* support asap7** (verified 2026-05-27, librelane 3.0.3: knows only `sky130` and `gf180mcu`); the PDK config (PDN/RC rules, Magic/KLayout/Netgen sign-off decks, per-corner liberty) ships inside the open_pdks build, and asap7 has neither an open_pdks build nor — being a predictive PDK — DRC/LVS sign-off decks. So asap7 in librelane is a large *and* incomplete port, not a config flag. (OpenROAD-flow-scripts ships an asap7 platform; using it would mean parallel infrastructure outside this blueprint — listed under "Optional extensions" below.)

The downstream interest is implementation in a recent advanced node (TSMC N2), for which no open-source PDK exists. sky130 → asap7 is used as an open-source proxy for "what shifts as geometry shrinks" — qualitative scaling, not quantitative N2 predictions (130 nm → 7 nm → 2 nm is much too coarse an extrapolation for absolute numbers).

See `BLUEPRINT.md` §4 and `METRICS.md` §7 for the metric-layer details.

## Execution plan

Vertical-slice-first: prove one parameter point through every layer before building sweep machinery or writing additional architectures. The milestones below are the historical record of the active path; "Optional extensions" further down lists directions that are intentionally not pursued (and need not be, to consider the blueprint complete).

**Shipping path: fix one architecture (1 pipeline stage), sweep the build-time parameters.** `flows/run_point.sh` + `flows/run_sweep.sh` drive the sweep, `flows/plot_pareto.py` aggregates and plots it, `flows/run_verif.sh` validates the generated Verilog with cocotb. The microarchitecture is fixed at a single pipeline stage (the registered-I/O "parallel" point) and the sweep focuses on how PPA scales with the **build-time parameters** `bw_global` and `n_boundaries`. Multi-stage pipelining is a **conditional lever**: the per-point critical path is reported (M8), and pipelining is revisited only if a path is too long for an eventual target. Rationale: with one stage the achievable clock *is* the critical path, so the study reduces to how area / power / critical-path scale with the build-time knobs — that scaling is the deliverable. Pipeline depth is a separate axis, added back only if needed.

### Repo layout

```
dslx/      binner.x (M1, includes fold ref + Sketch-B prio variant)
verif/     binner_ref.py, test_binner.py, runner.py (M4a, see COCOTB.md)
flows/     run_point.sh + run_sweep.sh (M6), plot_pareto.py (M8),
           run_verif.sh (M4a), extract_metrics.py, librelane/ configs
runs/      gitignored: runs/<delay_model>/<arch>/<params>/ (+ _sweeps/, _verif/ logs)
results/   committed: ppa_sweep.csv ; gitignored: *.png plots (regenerate via plot_pareto.py)
environment.yml   conda env (ppa-study): cocotb, iverilog, verilator,
                  matplotlib, graphviz — from conda-forge, no librelane needed
```

### Milestones

- **M1 — DSLX reference (unrefined form).** Parametric `binner.x` matching the Python in `README.md`, with `#[test]` cases for boundary values, sentinel-for-inactive-entries, and mid-range points. **Gate:** `interpreter_main --compare=jit dslx/binner.x` exits 0.

- **M2 — Multi-architecture codegen from one source (load-bearing strategy check).** For one small point (`bw_global_index=8, n_boundaries=4`), generate Verilog twice from the same IR: `--generator=combinational` and `--generator=pipeline --delay_model=sky130 --clock_period_ps=2000 --pipeline_stages=4`. **Gate:** `--output_schedule_path` shows >1 stage for the pipelined case *and* register count is meaningfully higher than the combinational case. If this fails, the "one DSLX, scheduler-driven architectures" thesis is wrong — re-plan before continuing.

- **M3 — One Verilog through librelane on sky130 (load-bearing PnR check).** Take M2's combinational Verilog, write a minimal librelane config, run the Classic flow from the CLI. **Gate:** flow completes; final metrics (area, timing slack, power) are produced.

- **M4a — RTL functional verification via cocotb [done 2026-05-28; see COCOTB.md].** `simulate_module_main` is not shipped (can't be linked statically), so RTL functional sim uses **cocotb + iverilog/verilator** against the codegen `binner.v`. The full path is implemented and runs **self-contained on the XLS+cocotb side** with no librelane dependency: cocotb, iverilog, and verilator all come from the `ppa-study` conda env (conda-forge), so verif runs on any machine with a `mamba env update -f environment.yml`. `verif/binner_ref.py` is the executable Python reference (mirrors README + `dslx/binner.x:binner`); `verif/test_binner.py` is parametric over `BW_GLOBAL`/`N_BOUNDS`/`PIPELINE_STAGES`; `verif/runner.py` is a thin `cocotb_tools.runner` CLI; `flows/run_verif.sh` is the multi-point dispatcher mirroring `run_sweep.sh`. The 4 hot-grid points (ref+prio × bw{8,16}/nb{4,16}) pass cleanly — independent RTL-level confirmation of the THERMOMETER Sketch B rewrite (the formal `prove_quickcheck_main` proof was at the DSLX level). Bring-up surfaced one quirk worth keeping visible: cocotb-on-iverilog needs `latency = pipeline_stages + 2` (one extra edge beyond the naïve "I/O regs + stages" count) because `vpi_put_value` lands after the active region of the current edge — documented in COCOTB.md §3.2. **M4b (post-PnR gate-level sim + SAIF→vectored power)** stays deferred behind the librelane-side work (METRICS.md §5).

- **M5 — Refined (mantissa/exponent) threshold form.** Not pursued in the shipping path; see "Optional extensions" below.

- **M6 — Sweep runner. [done]** `flows/run_point.sh` builds one point end-to-end (generated DSLX top → `ir_converter` → `opt` → `codegen` → librelane → `extract_metrics`); `flows/run_sweep.sh` fans a `(arch × bw_global × n_boundaries)` grid out via GNU parallel (OUTER concurrent points × INNER librelane `-j`, default 4×4 for a 16-core box; bash job-pool fallback if `parallel` is absent). Each point writes only its own `runs/<model>/<arch>/<params>/` dir and skips when its result exists — dir/sentinel caching, which makes sweeps resumable; input-hash caching is a deferred refinement. **Gate met:** the parallel `bw8/nb4` point reproduces the M3 baseline metrics byte-for-byte (core 5009.8 µm², 0.820 mW, WNS clean). **Pipeline-knob choice (from M2):** `--pipeline_stages=N` alone produces pass-through buffer stages if the clock period is loose. To get an actually-distributed schedule, drive `--clock_period_ps` near the minimum-feasible value for the chosen stage count. XLS's "cannot achieve clock period; try X ps" error is the cheapest way to find that minimum — issue a deliberately-too-tight clock and parse the suggestion; `run_point.sh` does this automatically (`--codegen-clock-ps auto`). **The parallel (1-stage) arch auto-probes its clock too:** a fixed value doesn't scale — 8 comparators in one stage need ~2608 ps where 4 need ~1809 ps — and for a single stage the emitted RTL is clock-independent once feasible, so this leaves the baseline metrics unchanged.

- **M7 — TDM proc variant.** Not pursued in the shipping path; see "Optional extensions" below.

- **M8 — Small sweep + analysis (the first deliverable). [first frontier done]** A 3-arch × 3-`n_boundaries` sky130 sweep (`parallel`, `pipe_s2`, `pipe_s4` × `nb ∈ {2,4,8}` at `bw_global=8`) closed 9/9 on 2026-05-25. `flows/plot_pareto.py` wrote `results/ppa_sweep.csv` and the area-vs-clock / area-vs-power / flops-vs-clock plots. **Result:** the three `nb=2` points (`parallel` → `pipe_s2` → `pipe_s4`) form the area-vs-clock frontier — deeper pipelines buy a faster min clock (1168 → 659 → 509 ps) for more flops/area (3078 → 4000 → 5886 µm²), matching the README's wet-finger guess. Larger `nb` is strictly more expensive, so it sits off-frontier within a single plot. **Broadening (done 2026-05-27):** a 16-point sky130 grid at the fixed 1-stage architecture (`parallel × bw_global{4,8,12,16} × n_boundaries{2,4,8,16}`) closed 16/16; `flows/plot_pareto.py` charts how core area, power, and critical path scale with each parameter (area scales ~linearly in both; the XLS critical path grows mainly with `n_boundaries`). `bw_threshold_m` joins once the refined form (M5) exists; multi-stage pipelining and TDM remain separate axes, reintroduced only if a critical path forces pipelining / once M7 unblocks. **Signoff-config work to fold in (from M3):** address max-slew violations at the ss corner — likely needs explicit `MAX_TRANSITION_CONSTRAINT` tuning or resizer-repair iterations beyond defaults. Also, the performance metric is now **two critical-path numbers reported per point**: the XLS pre-PnR min clock (`codegen_clock_ps`, delay-model estimate, present even with `--skip-pnr`) and the post-PnR path from the EDA flow (`librelane_clock_ns − worst-corner register-to-register setup ws`; **ws not WNS**, which clamps to 0 once timing is met). No target frequency is enforced yet — they are reported to watch how the path lengthens with the build-time parameters. Now wired in `plot_pareto.py`; the ss-corner value can be inflated by max-slew violations on high-fanout nets (flagged by `max_slew_viol_ss` — see METRICS.md §4). Sweeping the librelane clock to find each design's true fastest-closing period remains a heavier, deferred refinement. **Deep-dive at the largest grid point — `bw16_nb16` (2026-05-28).** Inspecting `runs/sky130/parallel/bw16_nb16/binner.opt.ir` plus its `STAPostPNR/summary.rpt`: the design **functions at the tt corner** (nom_tt setup ws +0.977 ns at a 10 ns clock, zero max-slew violations; max_tt ws +0.848 ns with 11 max-slew warnings that don't break setup), while ss fails badly (~-7 ns setup ws, 121 max-slew violations) — the ss failure is a signoff-config problem (fanout-repair buffers degrading at low voltage), **not** a structural fanout limit. The XLS pre-PnR critical path at this point is 4986 ps with **67 % spent in the popcount** (vs 31 % at `bw8_nb4`); the optimizer keeps a 7-deep mux/add fold-arm and only balances the tail. That motivates the popcount rewrite tracked in `THERMOMETER.md` (thermometer/one-hot/`one_hot_sel` exploiting the monotonicity contract) — sequenced before any ss-corner signoff tuning, since the rewrite shortens the path the repairer has to absorb in the first place. **Python environment:** kept minimal — `environment.yml` (conda env `ppa-study`, created with miniforge `mamba`/`conda`) ships **matplotlib** (for plots) **and graphviz** (the `dot` binary `ir_to_dot.py` shells out to). `flows/plot_pareto.py` does its aggregation, CSV export, and Pareto math in stdlib (so the table runs from a bare nix-shell) and imports matplotlib lazily for plotting; `flows/extract_metrics.py` stays stdlib-only too. We skipped pandas: the data is small enough that stdlib + `csv` is cleaner — revisit if a much larger sweep wants groupby/merge ergonomics.

### Consolidation gate (after M3)

After M3, the repo went through a deliberate consolidation: `HOWTO.md` walks through M1–M3 from a clean clone with every command and config shown; `flows/librelane/binner_8x4/config.json` is the committed librelane config; `flows/extract_metrics.py` is the committed PPA extractor (replacing inline `python3 -c "..."` snippets); README's "Toolchain status" section documents the `xls`/`xls-bin` pinning and the `simulate_module_main` gap from the first time anyone opens the repo. **Don't advance past this gate without the user manually re-walking the HOWTO** — the consolidation exists to make sure every methodology choice is understood, not just demonstrated.

### M3 outcome — librelane sky130 PnR is validated

The full DSLX → IR → Verilog (pure V2005, `--use_system_verilog=false`) → librelane Classic flow → sky130 PnR pipeline works end-to-end. Baseline for `binner` parallel architecture, `bw_global_index=8, n_boundaries=4`, librelane CLOCK_PERIOD=10 ns: core area 5010 µm², die area 7590 µm², stdcell util 68.7%, power 0.82 mW, WNS clean at all PVT corners. Two structural lessons:
1. Pure-combinational (`--generator=combinational`) Verilog has no clock and librelane's Classic flow can't handle it — wedges at CTS/timing-repair with a synthetic `__VIRTUAL_CLK__`. "Parallel architecture" for PPA must mean *one pipeline stage with registered I/O* (`--generator=pipeline --pipeline_stages=1`), not zero-flop combinational.
2. `--use_system_verilog=false` is required for Yosys (V2005 parser chokes on SV array-literal `'{...}`). Cost is more verbose Verilog, no functional impact. Set this in the sweep runner's codegen defaults.

## Optional extensions

What the shipping path **doesn't** include, by deliberate scope rather than because it's blocked. These are directions a fork can pursue without first having to "finish" anything — the blueprint stands without them. Each entry says what it would add and why we stopped here.

- **M4b — Post-PnR gate-level simulation + vectored power.** What it would add: gate-level functional sim against the synthesized netlist (cocotb + sky130 cell library views), and switching activity from a SAIF dump fed into OpenSTA so `report_power` uses *measured* activity rather than the vectorless default (METRICS.md §5). Why we stopped: M4a + the in-flow `Yosys.EQY` (RTL-vs-gate logical equivalence, METRICS.md §3) already give strong functional confidence, and vectorless power is enough for *relative* comparisons across the sweep. M4b lives on the librelane side of the split — the testbench transfers over unchanged from `verif/`.
- **M5 — Refined (mantissa/exponent) threshold form.** What it would add: a third sweep axis `bw_threshold_m`, quantifying how much PPA the `threshold_i_m << threshold_e` decomposition saves vs the full-width compare. Adds `dslx/binner_refined.x`. Why we stopped: the unrefined form already characterises the comparison-logic family (parallel/pipelined/Sketch-B); the refinement is a separable axis. Open question: does `opt_main` recognise the `_m << _e` pattern as a narrower compare, or does DSLX need to extract the mantissa explicitly? This is the first thing to check.
- **M7 — TDM proc variant.** What it would add: time-division-multiplexed architecture — one comparator reused over N cycles — at the cost of throughput/latency. Requires a *proc* (state) rather than a function, so a separate `dslx/binner_tdm.x`. Toolchain unblocked: `eval_proc_main` is shipped, cocotb drives procs over channels. Why we stopped: the parallel family alone gives the area/clock scaling the study is about; TDM is a different point on the area-vs-throughput frontier, not a different point on the existing axes. Latency-vs-throughput metric definition needs to be decided before building so TDM numbers are apples-to-apples with the function variants.
- **THERMOMETER Sketches A, C, D.** What they would add: A (flat `std::popcount`) as a stricter control point; C (one-hot boundary + `one_hot_sel` fused lookup) — predicted to save the 423–585 ps lookup-mux layer on top of Sketch B; D (parallel subtractors + `one_hot_sel`) — area-for-speed extreme. Why we stopped: Sketch B already captures the popcount win (4986→2219 ps at `bw16_nb16`), and at the small end of the grid the rewrite *regresses* — the crossover sweep matters more than another sketch right now. See `THERMOMETER.md` §6.
- **asap7 physical PnR via ORFS.** What it would add: real area/power/post-route timing on asap7, not just the XLS delay-model trend. Why we stopped: ORFS is a separate flow framework (parallel infrastructure to this one), and the trend signal from the XLS layer is enough for the qualitative scaling question the study asks. asap7 also has no DRC/LVS sign-off decks regardless, so even an ORFS port can't reach signoff-grade — see METRICS.md §7.
- **Librelane `CLOCK_PERIOD` sweep for fastest-closing clock.** What it would add: each point's true fastest-closing clock (instead of `clock − ws` at a fixed 10 ns). Why we stopped: multiplies PnR runtime by however many clock samples; not load-bearing for the scaling shape the study reports (METRICS.md §4).
- **Programmable-threshold proc.** What it would add: explicit modelling of firmware-programmable threshold registers as part of the synthesized block — quantifies the cost of programmability itself. Reuses the existing pure function inside a proc. See `DESIGN_NOTES.md` "Modeling firmware-programmable thresholds".

## Open questions

- What's the right metric layer between XLS and librelane — feed Verilog straight in, or also export the XLS scheduling report / block metrics (`--block_metrics_file`) for cross-checking? (`METRICS.md` maps every metric to its producing tool, layer, and fidelity — the reference for this question.)
