# BLUEPRINT.md — adapting this study to a new PPA investigation

This repo characterizes one function (`binner`), but the *method* — DSLX →
XLS IR → codegen → librelane PnR → metrics, swept over build-time parameters at
a fixed 1-stage architecture — is reusable. This guide says exactly what to
change for a **new function**, **new parameters**, or **new technology**, and
(just as important) what to leave alone.

The split that matters: changing parameters or swapping in a similarly-shaped
function is **easy** (you already have a working point). The **hard, non-obvious**
part — the XLS codegen flags, the librelane quirks, the PDK reality, the metric
provenance — is captured in the docs below and **transfers unchanged**. Reuse it;
don't rediscover it.

---

## 1. What transfers unchanged (the hard-won knowledge — don't re-derive)

These are flow facts, not function facts. They are correct for any feed-forward
design and are the real value of this blueprint:

- **Codegen recipe** (`run_point.sh` step 4): `--generator=pipeline`,
  `--pipeline_stages=1` for the "parallel" point (pure `combinational` wedges
  librelane at CTS), `--use_system_verilog=false` (Yosys V2005), `--reset=rst`,
  and the **auto-probe** of the minimum clock (`--clock_period_ps=1` → parse the
  `Try --clock_period_ps=X` suggestion). See `HOWTO.md` §2–§3, `PLAN.md` M2/M3.
- **librelane deferred-exit handling**: the flow exits non-zero on a deferred
  signoff violation *after* writing `final/metrics.json`; judge success on the
  file, not `$?` (`run_point.sh` step 5).
- **`import std;` needs `--dslx_stdlib_path`** on every XLS invocation.
- **Metric provenance / layers / fidelity** — which tool produces which metric,
  vectorless power, where we stop: `METRICS.md`. The librelane metric keys in
  `extract_metrics.py` / `plot_pareto.py` are PDK/flow-specific, **not**
  function-specific, so they carry over as-is.
- **Concurrency** (OUTER points × INNER librelane `-j` ≈ nproc): `run_sweep.sh`.
- **Architecture reality**: the function family (parallel/pipelined) comes from
  codegen flags on one feed-forward source; a *stateful* design (TDM, or
  firmware-programmable registers) is a **proc**, not a flag — `DESIGN_NOTES.md`,
  `PLAN.md` M7.

---

## 2. Swap points for a NEW FUNCTION

The XLS→librelane chain is generic; only these binner-specific spots change.
In `run_point.sh` the function-specific block is fenced with
`# === FUNCTION-SPECIFIC … ===` markers.

| Where | What is binner-specific | Change to |
|-------|-------------------------|-----------|
| `dslx/binner.x` | the parametric DSLX function + `#[test]`s | your `dslx/<fn>.x` (parametric, with tests; the M1 gate is `interpreter_main --compare=jit`) |
| `run_point.sh` — FUNCTION-SPECIFIC block | the generated `top.x`: `import binner;`, the consts, the `binner_top` wrapper, the call `binner::binner<BW_GLOBAL,N_BOUNDS>(…)`, and the port signature `(uN[BW_GLOBAL], uN[BW_GLOBAL][N_BOUNDS]) -> (uN[BW_BIN], uN[BW_GLOBAL])` | your function's import, params, and port shape |
| `run_point.sh` — flags | `--bw-global` / `--n-bounds` (parse, the `BW`/`NB` vars, the required-args check) and the `bw${BW}_nb${NB}` dir tag, the `point.json` `bw_global`/`n_bounds` fields | your function's build-time parameters |
| `run_point.sh` — names | `binner.ir` / `binner.opt.ir` / `binner.v`, `--top=binner_top`, `--module_name=binner_top`, and the generated librelane `"DESIGN_NAME": "binner_top"` | your top name (keep them consistent) |
| `run_sweep.sh` | the `--bw-global`/`--n-bounds` axis flags + `BWS`/`NBS` defaults | your parameter axes |
| `plot_pareto.py` | the `bw_global`/`n_bounds` columns in `COLUMNS` and `load_record` | your parameter columns (METRIC_KEYS and Pareto math are generic) |

What does **not** change: codegen flags, clock auto-probe, librelane invocation
+ exit handling, `extract_metrics.py`, the metric keys, `ir_to_dot.py`.

A function whose parameters happen to be `(bw, count)` is nearly a drop-in (just
the DSLX + names). A different parameter *shape* (e.g. three build-time params,
or different I/O) means editing the flags + the generated top, but still only
inside the fenced block + the flag plumbing.

---

## 3. Swap points for NEW PARAMETER VALUES (easy)

No code change — `run_sweep.sh` already takes the axes as lists:

```bash
flows/run_sweep.sh --bw-global "4 8 12 16 24 32" --n-bounds "2 4 8 16 32"
```

Widen/narrow the grid, add `--arch pipeline --stages N` points only if a
critical path forces pipelining (`PLAN.md` active path). This is "standard once
one point works" — the cheap, expected kind of extension.

---

## 4. New TECHNOLOGY / PDK

Two very different layers — know which one you need.

**XLS delay-model layer (critical path, flop count, BOM): trivial, any model.**
`--delay-model {sky130,asap7,unit}` works out of the box for all of them today.
Example: the binner is **767 ps on asap7 vs 1809 ps on sky130** on the same RTL —
a clean cross-node *trend* with zero PDK work. Use this for technology-scaling
questions that only need relative timing/area-proxy.

**librelane PnR layer (real area, power, post-route timing): sky130 / gf180mcu only.**
Verified 2026-05-27 on librelane 3.0.3: it knows `sky130` and `gf180mcu`, nothing
else. The PnR config (PDN/RC rules, Magic/KLayout/Netgen **sign-off decks**,
per-corner liberty, ~100 cell/geometry bindings) ships *inside* the
open_pdks-built PDK at `<pdk>/libs.tech/openlane/`, fetched via `ciel` into
`~/.ciel`.

- **gf180mcu**: supported — install it via `ciel` and set `PDK`; the flow should
  run with minor config (it has an open_pdks build).
- **asap7**: **not a config flag.** asap7 has no open_pdks build, and as a
  predictive PDK it has **no DRC/LVS sign-off decks at all**, so a librelane port
  would be large *and* incomplete (no physical signoff). **Recommendation: report
  XLS layer-2 metrics for asap7** (above) rather than porting. If asap7 *physical*
  PPA is truly required, OpenROAD-flow-scripts ships an asap7 platform — but it's
  a separate flow framework (parallel infrastructure), not this blueprint. See
  `METRICS.md` §7 and `PLAN.md` Phase 2.

The `<delay_model>/` directory level already exists in `runs/` so a second
technology lands additively, not as a restructure.

---

## 5. Constraints a new function must satisfy

For the function-family flow to work without surprises:

- **Feed-forward** (a function, not a proc) for the parallel/pipelined family;
  state ⇒ proc (`PLAN.md` M7, `DESIGN_NOTES.md`).
- A **non-parametric top** with the I/O you want as ports (the generated `top.x`
  monomorphizes the parametric body) — pipelined codegen adds the `clk`/`rst`.
- **DSLX `#[test]`s** so M1's `interpreter_main --compare=jit` gate means
  something (this, plus the in-flow `Yosys.EQY`, is your functional safety net
  until cocotb/M4).
- Emit **plain V2005** (`--use_system_verilog=false`) for Yosys.

---

## 6. Order of operations (mirror the milestones)

1. Write `dslx/<fn>.x` + tests → gate: `interpreter_main --compare=jit` (M1).
2. Edit the `run_point.sh` swap points (§2); run one point `--skip-pnr` → check
   the generated `top.x`, IR, and `flop_count` (M2). `ir_to_dot.py` helps here.
3. Run one full point (with PnR) → confirm `final/metrics.json` + the PPA summary
   (M3).
4. Set `run_sweep.sh` axes; sweep; `plot_pareto.py` (M6/M8).
5. New technology: decide layer-2-only (asap7) vs full PnR (sky130/gf180) per §4.

If steps 1–3 pass for your function, the rest is the easy, parameter-turning
kind of work — which is the whole point of having a blueprint.
