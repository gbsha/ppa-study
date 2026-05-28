# COCOTB.md — RTL functional verification

cocotb testbench that drives the codegen `binner.v` and checks every cycle
against the Python reference in `verif/binner_ref.py`. PLAN.md M4 (the
external-tool verification gate) is satisfied by what's described here.

The verification layer is **self-contained on the XLS+cocotb side**: every
tool it needs (cocotb, iverilog, verilator) comes from the `ppa-study`
conda env. It has **no librelane / nix-shell dependency** — verif can run
on a machine that never sees the PnR side of the flow. This matches the
distributed-workflow model: codegen + verify on one machine, PnR on
another, transfer `binner.v` between them.

---

## 1. Toolchain — one conda env, no nix-shell

`environment.yml` (`mamba env update -f environment.yml`) pulls everything
from conda-forge:

| tool      | conda-forge version (verified 2026-05-28) | role                                  |
| --------- | ----------------------------------------- | ------------------------------------- |
| python    | 3.13.13                                   | host for cocotb and the runner script |
| cocotb    | 2.0.1                                     | the testbench framework               |
| iverilog  | 12.0 stable                               | default simulator (easy to drive)     |
| verilator | 5.046                                     | opt-in faster simulator               |

There is **no host build-tools requirement** — conda-forge cocotb is
fully prebuilt with its VPI shim. `gcc`/`make` are *not* on the path of
operation.

What this replaces vs the original plan: the earlier draft assumed
iverilog/verilator from the librelane nix-shell. Pulling them into
conda-forge instead removes the cross-environment handshake (no
`mamba activate` *on top of* `nix-shell`), and makes the verif step
runnable on any machine — particularly on a machine that doesn't have
a librelane install at all.

### 1.1 Running a single point

```
mamba run -n ppa-study python verif/runner.py \
    --verilog runs/sky130/parallel/bw8_nb4/binner.v
```

The runner reads `point.json` next to the verilog to pick up
`bw_global`, `n_bounds`, `pipeline_stages`. CLI flags (`--bw-global`,
`--n-bounds`, `--stages`, `--simulator`, `--seed`, …) override.

### 1.2 Running the whole grid

```
flows/run_verif.sh --variants "ref prio" --bw-global "4 8 12 16" --n-bounds "2 4 8 16"
```

This walks `runs/$DELAY_MODEL/$ARCH_TAG/bw${BW}_nb${NB}/`, dispatches
`verif/runner.py` for each, and writes per-point logs to
`runs/_verif/<timestamp>/`. Points whose `binner.v` doesn't exist
yet are reported `MISSING` (run codegen first); FAILures gate the
exit status, MISSING does not.

---

## 2. Folder layout

```
verif/
  binner_ref.py    canonical Python reference — mirrors README & dslx/binner.x:binner
  test_binner.py   the cocotb test — parametric over BW_GLOBAL / N_BOUNDS / STAGES
  runner.py        cocotb runner CLI (cocotb_tools.runner.get_runner)
flows/
  run_verif.sh     walks runs/<model>/<arch>/<point>/, dispatches verif on each
```

No Makefile — cocotb 2.0's `cocotb_tools.runner` API is stable and
integrates cleanly with the rest of `flows/`. If a future scenario
forces the classical Makefile path, it can land alongside `runner.py`
without disturbing anything else.

The Python reference (`verif/binner_ref.py`) is the **executable source
of truth**; the README snippet and `dslx/binner.x:binner` mirror it. The
README cross-links to `verif/binner_ref.py` (see §6 — manual sync, the
function is small enough that drift will be obvious in code review).

---

## 3. Testbench design

### 3.1 The RTL interface (1-stage parallel arch, both ref and prio variants)

```
module binner_top(
    input  wire        clk,
    input  wire        rst,
    input  wire [BW_GLOBAL-1:0]            global_index,
    input  wire [BW_GLOBAL*N_BOUNDS-1:0]   lower_bin_boundaries,  // packed LSB-first
    output wire [BW_BIN + BW_GLOBAL - 1:0] out                    // {bin_index, local_index}
);
```

Verified facts (read off the codegen output for `bw8_nb4` and confirmed
on `bw16_nb16`):

- `lower_bin_boundaries` is a **packed 1-D bus**. Element 0 lives at the
  LSB end: `lower_bin_boundaries[BW*(i+1)-1 : BW*i]` = `bounds[i]`. So
  `pack = sum(bounds[i] << (BW*i))`.
- `out` is `{bin_index[BW_BIN-1:0], local_index[BW_GLOBAL-1:0]}` —
  bin_index in the high bits.
- `rst` is synchronous (XLS codegen default with `--reset=rst`).

### 3.2 Latency — and the cocotb-iverilog timing quirk

XLS codegen with `--pipeline_stages=N` produces `N + 1` flop stages
(input flop + (N-1) inner flops + output flop). Naïvely that suggests
**latency = N + 1 edges** from driving an input to observing the
output.

In practice cocotb+iverilog needs **one more edge**: when cocotb writes
`dut.signal.value = X` right after a `RisingEdge`, iverilog's
`vpi_put_value` lands *after* the active region of that edge, so the
**next** rising edge still sees the old D. The flop captures the new
value only at the edge *after* that.

Concretely for the 1-stage parallel arch (this is what we ship today):

- `stages = 1` → `latency = 3` edges per drive
- General: `latency = stages + 2`

The probe (run during bring-up, captured in the commit history) traced
this directly: at posedge+1 the input flops still hold 0; at posedge+2
they hold the new bounds + global; at posedge+3 the output flop
finally reflects the comb output. `test_binner.py` uses
`latency = stages + 2` with a comment pointing here.

This is purely a simulator-driver thing — synthesis sees `stages + 1`
flops and the post-PnR critical path is computed accordingly. We are
not adding any extra register stages to the design.

### 3.3 Stimulus respects the firmware contract

The README contract: `lower_bin_boundaries[0] <= global_index <=
2^BW_GLOBAL - 2` (the top value is reserved as the sentinel; firmware
must never issue `global_index < lower_bin_boundaries[0]`).

The testbench's stimulus generator matches the contract:

```python
gi = rng.randint(bounds[0], (1 << bw) - 2)
```

Why this matters: below `bounds[0]` the hardware does a modular 8-bit
subtract (e.g. `local_index = -6 wraps to 250`), while the pure-Python
reference returns a negative int. That's not a real mismatch — it's an
out-of-contract input — so the cleanest fix is to keep stimulus inside
the contract.

`dslx/binner.x` tests respect the same contract; this is the cocotb
testbench mirroring that discipline.

### 3.4 Stimulus tiers

Two parameters control stimulus volume (env vars, defaults in
`verif/runner.py`):

- `NUM_BOUND_SETS` — distinct random bound configurations per test
  (default 256).
- `TRIALS_PER_SET` — random `global_index` values for each bound set
  (default 16). Amortizes the latency cost of programming new bounds.

Total = `NUM_BOUND_SETS × TRIALS_PER_SET` vectors per point. The default
4096 takes ~0.13 s wall time at `bw16_nb16` on iverilog. Raise either
parameter for thorough sweeps; lower them for quick smoke.

Random bounds are a 50/50 mix of:

- **Cumulative deltas** (`bounds_via_deltas`) — clustered patterns, good
  at exercising "all bins active, narrow range".
- **Sorted unique draws** (`bounds_via_sorted`) — even spread, good at
  exercising "bins fill the dynamic range".

Bounds are programmed *once* per set and reused across the
`TRIALS_PER_SET` global_index draws. That mirrors firmware behaviour
("configure once, run many") and avoids reset-flush overhead between
vectors.

---

## 4. Multi-point dispatch — `flows/run_verif.sh`

Mirrors `flows/run_sweep.sh` in style but lighter:

- enumerates `variants × archs × bw_global × n_bounds`
- per point: looks up `runs/<model>/<arch_tag>/bw<bw>_nb<nb>/binner.v`,
  invokes `mamba run -n ppa-study python verif/runner.py …`
- records `OK` / `FAIL` / `MISSING (…)` per point in
  `runs/_verif/<timestamp>/<tag>.status`
- summary on stdout; exit non-zero iff any `FAIL`

Concurrency: `--jobs N` runs N points in parallel (iverilog is
single-threaded, so OUTER can equal `nproc`). GNU parallel is used when
available; a bash job pool is the fallback.

Verif is decoupled from PnR: it only needs `binner.v`, so it can run
after `run_sweep.sh --skip-pnr` without librelane. That matches the
distributed-workflow assumption — XLS codegen + verif on machine A,
PnR on machine B.

---

## 5. Deferred items

Sequenced for later, in priority order:

- **M4b — Post-PnR (gate-level) simulation.** Same `test_binner.py`,
  but `VERILOG_SOURCES` becomes the post-PnR netlist + the sky130 cell
  library Verilog views. iverilog handles this; verilator is harder. The
  post-PnR netlist lives on the librelane-side machine, so M4b is the
  one verification step that *does* live alongside librelane. The
  cocotb env + testbench transfer over cleanly.
- **SAIF dump → vectored power.** cocotb writes SAIF; OpenSTA's
  `report_power` re-uses it with real activity instead of the
  vectorless default. That's METRICS.md §5's refinement path —
  separable work, also librelane-side.
- **CI integration.** Easy to add — `flows/run_verif.sh --jobs 4`
  on the latest committed grid is the smoke gate. Out of scope for now.
- **Coverage / cocotb-coverage.** Binner is small enough that line and
  branch coverage in the testbench is trivial; skip.

---

## 6. Conventions established during bring-up

- **Python reference is the source of truth.** `verif/binner_ref.py`
  has a `__main__` selftest mirroring a subset of the
  `dslx/binner.x` deterministic cases. README points at the file via
  relative hyperlink; the README snippet is illustrative, not
  canonical.
- **Stay inside the firmware contract in stimulus.** Below
  `bounds[0]` is undefined-by-spec; don't test it.
- **`latency = stages + 2`** in the testbench (cocotb+iverilog
  drive-after-`RisingEdge` quirk). Comment in the testbench cross-references
  here.
- **Build dirs go to `runs/_verif/build/<tag>/`.** Per-point
  `verif_sim_build/` next to `binner.v` is avoided so the runs tree
  used by `plot_pareto.py` stays clean.
- **One refined-form deferral**: when M5 lands (DSLX refined form
  `threshold_i_m << threshold_e`), `verif/binner_ref.py` grows a
  second function alongside `binner`. Not now.

---

## 7. What was learned, briefly

For the project's purpose as a blueprint, two things are worth keeping
visible:

1. **The cocotb + iverilog drive timing has a single-edge quirk** that
   off-by-one's any "obvious" latency formula. The testbench documents
   it in-line; future ports to other functions can reuse the
   `stages + 2` pattern.

2. **The verif side legitimately decouples from PnR.** That means a
   blueprint study can do its DSLX/IR/codegen/verify loop on a laptop
   and only reach for the larger PnR machine to collect the metrics —
   useful when iterating on RTL correctness.
