# METRICS.md

Where every PPA number in this study comes from: which tool produces it, at
which abstraction layer, how faithful it is, what it costs to collect, and how
far down the fidelity ladder we go (and deliberately stop). Companion to
`HOWTO.md` (how to *run* the flow) and `PLAN.md` (what we sweep and why).

Numbers quoted are the M3 baseline: `binner`, parallel (1 stage),
`bw_global=8, n_boundaries=4`, sky130, librelane `CLOCK_PERIOD=10 ns`.
Toolchain: XLS @ `81ff4fdf7`, **LibreLane 3.0.3** (OpenROAD/OpenSTA/Yosys/Magic/
KLayout/Netgen from the nix-shell).

---

## 1. The abstraction-layer ladder

Each metric lives at one rung. Higher rungs are cheap and approximate (no
geometry); lower rungs are expensive and faithful (real cells, wires,
parasitics). We climb down only as far as signoff STA/power.

| # | Layer | Produced by | Models | Fidelity for PPA | Cost |
|---|-------|-------------|--------|------------------|------|
| 0 | DSLX behavior | `interpreter_main` | function correctness | none (functional only) | ms |
| 1 | XLS IR (dataflow) | `ir_converter_main`, `opt_main` | op graph, node counts | structure only | ms |
| 2 | XLS scheduled / codegen | `codegen_main`, `delay_info_main`, `benchmark_main` | flop count, critical path under a **delay model** (no cells, no wires) | optimistic estimate | ms–s |
| 3 | Logic synthesis | `Yosys.Synthesis` | real standard cells, pre-layout cell counts/area | gate-level, no placement | seconds |
| 4 | Floorplan / place / CTS / route | OpenROAD steps | die/core area, utilization, wirelength, clock tree | physical, pre-extraction | minutes |
| 5 | Parasitic extraction + signoff STA/power | `OpenROAD.RCX` → `STAPostPNR`, `IRDropReport` | timing & power with **extracted RC (SPEF)**, multi-corner | signoff-grade, **vectorless** power | minutes |
| 6 | *(not done)* transistor SPICE w/ stimulus | — | analog transient with real waveforms | most faithful | hours+ / not open at scale |

We **stop at layer 5** (see §6). A SPICE *netlist* is extracted at layer 5 for
LVS, but no analog simulation is run.

---

## 2. XLS-layer metrics (layers 1–2, pre-synthesis)

All delay-model based: `--delay_model={sky130,asap7,unit}`, no place-and-route.
Cheap enough to run on every sweep point, even with `--skip-pnr`.

| Tool | Invocation | Emits | Key fields |
|------|------------|-------|-----------|
| `codegen_main` | `--block_metrics_path=…` | `XlsMetricsProto.block_metrics` | `flop_count`, `feedthrough_path_exists`, `delay_model`, `max_reg_to_reg_delay_ps`, `max_input_to_reg_delay_ps`, `max_reg_to_output_delay_ps`, `bill_of_materials[]` |
| `codegen_main` | `--output_schedule_path=…` | `PackageScheduleProto` | per-stage node assignment + per-node `node_delay_ps`/`path_delay_ps` (see HOWTO §2e) |
| `delay_info_main` | `--delay_model=sky130 IR` | text | critical path (node-by-node, cumulative ps) + per-node delay (see HOWTO §2h) |
| `benchmark_main` | `--delay_model=sky130 IR` | text | node count, **critical-path delay**, contribution-by-op %, optimization-pass stats, JIT/interpreter throughput |
| `print_bom` | `--root_path=DIR --file_pattern='.*\.metrics\.textproto'` | table | bill of materials aggregated by `(kind, op, in/out width)` with counts |
| `pass_metrics_main` | pass-metrics proto from `opt_main` | text | which optimization passes ran and what they changed |

What these tell us (baseline `bw8_nb4`):

- **Area proxy** — `flop_count` (50) and the BOM: `3× uge` (8-bit compares),
  `1× add`, `1× sub` (8-bit), `2× sel`, `4× array_index`. This is the
  *functional-unit* count, the cheapest area signal, and it isolates the
  comparison-logic architecture the study is about.
- **Critical-path proxy** — `delay_info_main`/`benchmark_main` both report
  **1809 ps**, dominated by the serial chain *after* the parallel compares
  (`sub` 28%, `array_index` 23%, `sel` 22%, `uge` 17%, `add` 9%). For 1 stage
  this equals the codegen min clock (`codegen_clock_ps`, what `run_point.sh`
  auto-probes). See HOWTO §2h.

The `delay_model` is XLS's own estimator for the target tech (sky130/asap7); it
knows nothing about placement or wires, so it is **optimistic** vs. layer 5.

---

## 3. EDA-layer metrics (layers 3–5, LibreLane Classic)

The Classic flow is **80 ordered steps** (`Verilator.Lint` … `Misc.Report-
Manufacturability`). Each step appends to a single cumulative
`runs/RUN_*/final/metrics.json` — **307 keys** for the baseline. `flows/
extract_metrics.py` prints the subset that matters; the table below maps the
namespaces to the step (tool) that produces them.

| metrics.json namespace | Produced by (step) | Tool | Example keys / baseline value |
|------------------------|--------------------|------|-------------------------------|
| `design__lint_*` | `Verilator.Lint` (0) | Verilator | lint error/warning counts |
| `synthesis__*` | `Yosys.Synthesis` (5) | Yosys | `synthesis__check_error__count` = 0 |
| `design__instance__count*`, `…__area*` | post-route, attributed at signoff | OpenROAD | `…count__stdcell` = 367; `…count__class:sequential_cell` = 50; per-class area breakdown |
| `design__die__area`, `design__core__area`, `design__rows/sites` | `OpenROAD.Floorplan` (12) | OpenROAD | core **5009.8 µm²**, die **7589.94 µm²** |
| `design__instance__utilization*`, `…displacement*` | placement (23/27/33) | OpenROAD (RePlAce/OpenDP) | stdcell util **0.687** |
| `design_powergrid__*`, `design__power_grid_violation__count` | `GeneratePDN` (20), `IRDropReport` (58) | OpenROAD (pdngen/PSM) | drop/voltage worst per net+corner |
| `clock__skew__worst_{setup,hold}__corner:*` | `OpenROAD.CTS` (34) | OpenROAD (TritonCTS) | setup skew tt = 0.256 ns |
| `global_route__wirelength`, `…vias` | `GlobalRouting` (38) | OpenROAD (FastRoute) | wirelength 9936 |
| `route__wirelength*`, `route__vias*`, `route__drc_errors*` | `DetailedRouting` (46) | OpenROAD (TritonRoute) | total/max wirelength, single/multi-cut vias |
| `antenna__violating__*`, `route__antenna_violation__count` | `CheckAntennas` (39/48), `RepairAntennas` (43) | OpenROAD | antenna nets/pins |
| `timing__{setup,hold}__{wns,tns,ws}__corner:*`, `…_r2r…`, `…_vio__count` | `STAPostPNR` (57), after `RCX` (56) | OpenSTA + **SPEF** | setup `ws` tt 5.24 / ss 0.687 / ff 6.93 ns; WNS 0 |
| `design__max_{slew,cap,fanout}_violation__count__corner:*` | signoff STA + `Checker.*` (77/78) | OpenSTA | **max-slew ss = 11** (the known broadcast-net finding) |
| `power__{total,internal,switching,leakage}__total` | `STAPostPNR` (57) | OpenSTA `report_power` | total **0.820 mW** (int 0.579, sw 0.241, leak 0.0049 µW) — **vectorless**, see §5 |
| `ir__drop__{avg,worst}`, `ir__voltage__worst` | `IRDropReport` (58) | OpenROAD (PSM) | avg drop 0.000157 V |
| `magic__drc_error__count`, `klayout__drc_error__count` | `Magic.DRC` (66), `KLayout.DRC` (67) | Magic, KLayout | DRC counts |
| `design__lvs_*__count`, `…xor_difference…` | `Netgen.LVS` (72), `KLayout.XOR` (64) | Netgen, KLayout | LVS device/net/pin mismatches |
| `flow__{errors,warnings}__count` | flow-wide | LibreLane | bookkeeping |

Two structural facts about the flow worth knowing:

- **`OpenROAD.RCX` (step 56)** runs parasitic extraction → **SPEF**, so the
  `STAPostPNR` timing *and* power use real routed-wire RC, not estimates. This
  is the difference between layer 2 and layer 5.
- **`Yosys.EQY` (step 74)** already performs RTL-vs-gate **logical equivalence**
  inside the flow — relevant to M4: gate-level *functional* equivalence is
  partly covered here; `lec_main` and cocotb add to it rather than being the
  only option.

---

## 4. The performance metric — two critical-path numbers

Because we fix one pipeline stage (`PLAN.md` active path), the achievable clock
*is* the critical path. We report it from both ends of the flow; no target
frequency is enforced yet — the point is to watch how it lengthens with the
build-time parameters.

| | Pre-PnR (XLS) | Post-PnR (EDA) |
|---|---------------|----------------|
| source | `codegen_clock_ps` (auto-probe) = `delay_info`/`benchmark` critical path | `CLOCK_PERIOD − timing__setup__ws` (worst corner) |
| baseline | **1809 ps** | tt **4.76 ns**, ss **9.31 ns**, ff **3.07 ns** (= 10 ns − ws) |
| includes | delay model only | cells + placement + routed-wire RC + corner derating |
| in `point.json`? | yes (`codegen_clock_ps`) | derivable (`librelane_clock_ns` + `ws` from metrics.json) |

Caveats to bake into the eventual `plot_pareto.py` wiring (the next work item):

- Use the **register-to-register** slack (`timing__setup_r2r__ws`) for the
  internal logic path; for this design it equals `timing__setup__ws`, but in
  general port-to-port paths fold in assumed I/O delays.
- The huge ss figure (9.31 ns vs the 1809 ps estimate) is **inflated by the
  unresolved max-slew violations** on the high-fanout broadcast nets — a real
  signoff effect, not a tool artifact. It's why the post-PnR number is the one
  to watch, and why fixing slew (M8 signoff TODO) will move it.
- The *true fastest-closing* clock needs a librelane `CLOCK_PERIOD` sweep
  (multiple PnR runs); `clock − ws` at a loose 10 ns is a one-run proxy.

---

## 5. Power — vectorless today, activity-annotated later

**Today:** `power__*` comes from OpenSTA `report_power -corner` inside
`STAPostPNR`. LibreLane 3.0.3 sets **no switching activity** (confirmed: no
`set_power_activity`/`read_vcd`/`read_saif`/SAIF anywhere in the package), so
OpenSTA uses its **default/propagated activity** — a fixed assumed toggle rate
driven from the clock, *not* measured switching. The split we report
(internal/switching/leakage) is real per-cell power × that assumed activity.
Leakage and internal power are fairly trustworthy; **switching power is only as
good as the assumed activity**.

**Refinement path (ties to M4, not yet built):**

1. Run a gate-level (or RTL) sim with **realistic stimulus** — cocotb driving
   iverilog/verilator on the post-synth or post-route netlist (this is the M4
   bench; `simulate_module_main` is not shipped, so cocotb is the route).
2. Dump a **VCD** (or distill a **SAIF**) of per-net toggle activity.
3. Feed it to OpenSTA: `read_vcd`/`read_power_activity` (or `set_power_activity`
   from SAIF) before `report_power`, so switching power uses *measured* rates.

LibreLane 3.0.3 has **no built-in step** for this, so it would be a custom step
or a standalone OpenSTA script we add — a deliberate extension, sequenced after
the first frontier with M4. Until then, treat switching power as a vectorless
estimate and compare points *relatively* (same assumed activity for all).

---

## 6. Where we stop, and why

| Fidelity step | Done? | Note |
|---------------|-------|------|
| Extracted RC parasitics (SPEF) for STA/power | **yes** | `OpenROAD.RCX` → signoff STA/power |
| Multi-corner signoff (tt/ss/ff, setup+hold) | **yes** | 3 corners in metrics.json |
| Activity-annotated (vector-based) power | **no** | §5 — needs cocotb→VCD/SAIF→OpenSTA |
| SPICE netlist extraction | **yes, for LVS only** | `Magic.SpiceExtraction` (70) → `Netgen.LVS` (72); not simulated |
| Transistor-level SPICE transient w/ stimulus | **no** | most faithful power/timing, but huge effort and not practical at sweep scale on these PDKs |

So the floor is **signoff STA/power with extracted parasitics**. We do *not*
convert GDS back to an R/C-annotated transistor netlist and run SPICE with
realistic waveforms — that is the one rung below us, deliberately out of scope.
The cheapest meaningful accuracy gain available to us is **vector-based power**
(§5), not SPICE.

---

## 7. sky130 now vs asap7 later

| Metric group | sky130 (now) | asap7 (later) |
|--------------|-------------|---------------|
| XLS layer 2 (flop count, BOM, critical path) | ✅ `--delay_model=sky130` | ✅ `--delay_model=asap7` (XLS estimator supports it) |
| Synthesis cell counts/area (layer 3) | ✅ | ⚠️ needs librelane asap7 PDK/flow config |
| Area / utilization / wirelength / CTS (layer 4) | ✅ | ⚠️ same |
| Signoff STA / power / IR-drop (layer 5) | ✅ | ⚠️ same |

So **all XLS-layer metrics are available for both** technologies today; the
LibreLane PnR layers are sky130-only until the asap7 PDK/flow is configured
(PLAN.md Phase 2). The interim asap7 fallback is therefore **layer-2 only**
(critical path, flop count, BOM from the XLS delay model) — still useful for
*trend* comparison without place-and-route.

---

## 8. Aggregation tooling — who collects across tools

| Aggregator | Scope | Status here |
|------------|-------|-------------|
| LibreLane `final/metrics.json` | all 80 flow steps, one JSON | **what we use** (read by `extract_metrics.py` / `plot_pareto.py`) |
| `flows/extract_metrics.py` | curated PPA subset, human-readable | ours, stdlib |
| `flows/plot_pareto.py` | join `point.json` (XLS) + `metrics.json` (EDA) → CSV + plots | ours, stdlib + matplotlib |
| `flows/ir_to_dot.py` | XLS IR → graph + fanout report | ours, stdlib + graphviz |
| XLS `benchmark_main` / `pass_metrics_main` / `print_bom` | XLS-internal only (IR/codegen) | available, ad-hoc |
| XLS `gather_design_stats` | **cross-tool**: parses Yosys + OpenSTA logs → `DesignStats` proto (`area_um2`, `levels`, `flops`, `cells`, `crit_path_delay_ps`, `wns`, `tns`, per-stage) | **not used** — Python, not in `xls-bin/bin/` (runs from a source checkout on the synth machine, see xls-bin README appendix) |

`gather_design_stats` is XLS's own answer to "normalize OpenROAD/Yosys output
into a PPA proto," but since LibreLane already aggregates everything into
`metrics.json`, we read that directly — it's richer (307 keys, multi-corner)
and needs no extra tool. Worth revisiting only if we want XLS's normalized
schema for cross-project comparison.

---

## 9. What we collect today vs. gaps

**Collected now (per point):** XLS `flop_count`, BOM, `codegen_clock_ps`
(pre-PnR critical path); LibreLane core/die area, utilization, per-class cell
area, multi-corner timing (WNS/TNS/WS, setup+hold), vectorless power
(total/internal/switching/leakage), IR drop, DRC/LVS/antenna/slew counts.

**Immediate gap (next work item):** wire the **post-PnR critical path**
(`clock − ws`) and surface **both** critical-path numbers in `plot_pareto.py`
(§4), and add area/power-vs-(`bw_global`,`n_boundaries`) views.

**Deferred refinements:** vector-based power via cocotb→SAIF→OpenSTA (§5, with
M4); a librelane `CLOCK_PERIOD` sweep for true fastest-closing clock (§4);
asap7 PnR (§7, Phase 2).
