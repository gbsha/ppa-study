# COCOTB.md — RTL functional verification plan

This is a working plan for adding a cocotb testbench that verifies the
generated `binner.v` against the Python reference from `README.md`. PLAN.md
M4 lists this as the deferred external-tool verification gate; the cocotb
+ iverilog/verilator path is the one we settled on because XLS deliberately
does *not* ship `simulate_module_main`.

The doc gets refined into a stable reference as we implement, mirroring
the THERMOMETER.md → implementation cadence.

---

## 1. Tools we already have, tools we still need

### 1.1 In the librelane nix-shell (verified 2026-05-28)

Both simulators are there — no install step needed:

```
iverilog --version  → Icarus Verilog 13.0 (devel)
verilator --version → Verilator 5.044 (2026-01-01)
vvp                 → iverilog's runtime; present
```

Build tools (`gcc 15.2`, `g++`, `make`) come from the host Ubuntu PATH,
which is the usual layering — cocotb's Makefile only needs them to
compile its small VPI shim against `vpi_user.h` from the simulator.

So the simulator question is settled: we pick one of iverilog / verilator
and go. (Sketch of the trade: iverilog is easier to drive but slower;
verilator is much faster but needs a `--trace` rebuild to dump waves and
is stricter about Verilog dialect. Start with **iverilog** — the
flow-generated RTL is small enough that simulation speed never bites,
and the relaxed dialect handling means fewer dead ends. Promote to
verilator if/when sweep-time becomes a concern.)

### 1.2 What needs to land in the conda env

The current `environment.yml` provides matplotlib + graphviz for the
analysis half. Cocotb itself is *not* installed in the nix-shell python
(verified: `import cocotb` raises `ModuleNotFoundError`), so it has to go
somewhere the nix-shell can see.

Recommended additions to `environment.yml`:

```yaml
dependencies:
  # … existing …
  - cocotb >=1.9              # conda-forge ships it; pip is a fallback
  - pytest >=8                # optional — only if we want pytest-style runners
```

Cocotb on conda-forge is fully packaged including the C extension; we
don't need pip+gcc for the install. The runtime invocation does shell
out to `iverilog`/`verilator` from the nix-shell PATH, so the activation
sequence is:

```
cd $LIBRELANE && nix-shell                 # gets iverilog/verilator
cd $PPA_STUDY                              # back here
mamba activate ppa-study                   # gets cocotb
```

The two stack cleanly because conda env activation only prepends to
PATH; the nix-shell binaries stay reachable. We will need to verify
this experimentally — there's a small risk that conda's Python shadows
nix-shell's Python in a way cocotb's VPI loader doesn't like.

**Fallback if the conda+nix layering breaks:** drop a tiny `verif/
requirements.txt` and `pip install --user cocotb` inside the nix-shell
python. Less clean but eliminates the cross-env handshake.

### 1.3 What cocotb does *not* solve

- **DSLX-level verification** — `interpreter_main` + `prove_quickcheck_main`
  already cover that (we used both for `binner_prio` equivalence). Cocotb
  is purely an RTL-and-below tool.
- **IR ↔ netlist formal equivalence** — that's `lec_main`'s job; lives
  alongside cocotb, not instead.
- **Post-PnR gate-level simulation** — same testbench can drive the
  synthesized netlist, but doing that needs the sky130 cell library
  Verilog and a slightly different invocation. **Sequence as M4b**, after
  M4a (RTL functional sim) is green.

---

## 2. Folder structure proposal

```
verif/
  binner_ref.py         canonical Python reference (the README snippet, made executable)
  test_binner.py        the cocotb test — parametric over BW_GLOBAL / N_BOUNDS
  runner.py             cocotb runner script (cocotb.runner API) — preferred
  Makefile              fallback: classical cocotb Makefile (only if runner.py blocks)
  README.md             one paragraph + the command to run a single point
flows/
  run_verif.sh          walks runs/<model>/<arch>/<point>/ and dispatches verif on each
```

Why a separate `verif/` directory and not `dslx/` or `flows/`:
- The reference is *not* DSLX (it's the Python source of truth that DSLX
  is built to match), so `dslx/` is the wrong home.
- The cocotb testbench is the only Python in the repo whose purpose is to
  drive a simulator binary, not produce flow artefacts. Mixing it into
  `flows/` would mean the metrics scripts pick up a hard cocotb dep.
- Keeping verif separable also keeps the `--skip-pnr` path lean —
  signoff-config people don't need to install cocotb.

### 2.1 The Python reference — single source of truth

Today the binning function lives twice in spirit:

- `README.md` — Python snippet, the human-readable spec
- `dslx/binner.x` — the hardware reference (fold form) and now `binner_prio`

We add a third, **executable** form: `verif/binner_ref.py`. Its job is to
*be* the README snippet (modulo a docstring and a function signature)
and to be importable from the cocotb testbench.

Proposed shape (sketch — not committed):

```python
# verif/binner_ref.py
from typing import Sequence

def binner(global_index: int, lower_bin_boundaries: Sequence[int]) -> tuple[int, int]:
    """The canonical binning function. Mirrors README.md and dslx/binner.x.

    Contract: lower_bin_boundaries is strictly monotonically increasing
    (firmware invariant). Inactive entries hold a sentinel global_index
    never reaches. See README.md for the full contract.
    """
    bin_index = 0
    for threshold in lower_bin_boundaries[1:]:
        if global_index >= threshold:
            bin_index += 1
    local_index = global_index - lower_bin_boundaries[bin_index]
    return bin_index, local_index
```

We then update README to say "the canonical executable form is
`verif/binner_ref.py`; the snippet below is illustrative." The README
still shows the code (readability), and the verif folder owns the
runnable copy.

---

## 3. Test design — what the testbench actually does

### 3.1 The RTL interface to drive

From `runs/sky130/parallel/bw8_nb4/binner.v` (1-stage flop-bracketed):

```
module binner_top(
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  global_index,
    input  wire [31:0] lower_bin_boundaries,    // packed: 4 × 8 bit
    output wire [9:0]  out                       // packed: {bin_index[1:0], local_index[7:0]}
);
```

Three shape facts the testbench must handle:

- `lower_bin_boundaries` is a **packed 1-D bus**, not an unpacked array.
  Width = `BW_GLOBAL × N_BOUNDS`. The packing order (which element is at
  bit 0?) needs to be confirmed empirically on one known-bounds test —
  XLS codegen tends to pack with element 0 at the LSB end, but worth
  verifying rather than assuming.
- `out` is a **packed tuple**: high bits = `bin_index`, low bits =
  `local_index`. Width = `BW_BIN + BW_GLOBAL`.
- Latency: registered I/O bracketed by one combinational stage means the
  output for the inputs presented at posedge N is sampled at posedge
  N+1 (for the `parallel` arch). For multi-stage variants, latency
  grows by `pipeline_stages - 1`.

### 3.2 Test parameterization

We do *not* generate one testbench per `(bw_global, n_bounds)` — that's
the wrong axis to copy. Instead the testbench reads `BW_GLOBAL` and
`N_BOUNDS` from environment variables and computes the bus slicing
accordingly. The runner injects them per point.

Pseudocode of the inner loop:

```python
# verif/test_binner.py (sketch)
@cocotb.test()
async def random_vectors(dut):
    bw = int(os.environ["BW_GLOBAL"])
    nb = int(os.environ["N_BOUNDS"])
    bw_bin = (nb - 1).bit_length() or 1

    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset(dut, cycles=2)

    for _ in range(N_VECS):
        bounds = monotonic_bounds(bw, nb, rng)        # firmware-style sorted array
        global_idx = rng.randrange(0, (1 << bw) - 1)  # sentinel-safe range
        drive(dut, global_idx, bounds, bw, nb)
        await ClockCycles(dut.clk, latency)
        bin_ref, loc_ref = binner_ref.binner(global_idx, bounds)
        bin_dut, loc_dut = unpack(dut.out.value, bw, bw_bin)
        assert (bin_dut, loc_dut) == (bin_ref, loc_ref), …
```

Three stimulus tiers, chosen by env or argv:

- **Exhaustive** — `2^BW` global indices × a handful of canonical bound
  arrays. Only feasible for `BW ≤ 12` (4096 vectors); for `BW ≤ 8` it's
  free.
- **Random** — seeded, e.g. `N_VECS = 10_000`. Bounds generated as a
  cumulative-sum of random positive deltas (then top-clipped to fit the
  sentinel). This is the default for `BW ≥ 12`.
- **Edge cases** — handful of pinned vectors: `global = 0`,
  `global = MAX-1`, exact-on-boundary, "all bins inactive except 0",
  etc.

### 3.3 Why we don't sweep bounds randomly across cycles inside one test

The bounds are programmable but rarely change in real firmware — they're
configuration, not data. So per-test fixing the bounds and varying
`global_index` matches the firmware mental model. We *do* vary bounds
across the test suite to cover the structural space.

---

## 4. Runner — Python-native, with Makefile as a fallback

Cocotb has two ways to launch a simulator:

- **Classical Makefile** — `verif/Makefile` declares `VERILOG_SOURCES`,
  `TOPLEVEL`, `MODULE`, etc. and `make` does the rest. Stable since
  cocotb 0.x, every tutorial assumes it, very portable. But: it's
  another paradigm island in a repo that's otherwise bash + Python.
- **`cocotb.runner` Python API** (stable since cocotb 1.7) — write a
  small Python script that builds the simulator command directly. Same
  capabilities as the Makefile, no make literacy required, integrates
  with the rest of `flows/`.

Plan: lead with `verif/runner.py` using `cocotb.runner`. If we hit a
version-pin or PATH snag, fall back to the Makefile — both are kept in
the same `verif/` directory so the swap is local.

`runner.py` sketch:

```python
# verif/runner.py
from cocotb.runner import get_runner

def run_one(verilog: Path, bw: int, nb: int, simulator="icarus"):
    runner = get_runner(simulator)
    runner.build(verilog_sources=[verilog], hdl_toplevel="binner_top")
    runner.test(
        hdl_toplevel="binner_top",
        test_module="test_binner",
        extra_env={"BW_GLOBAL": str(bw), "N_BOUNDS": str(nb)},
        # waves=True,  # opt-in: VCD/FST off by default to keep sweep cheap
    )
```

Wired into the multi-point dispatcher in §5.

---

## 5. Multi-point execution — `flows/run_verif.sh`

A new flow script mirroring `run_sweep.sh` in spirit but lighter:

```
flows/run_verif.sh [--variants "ref prio"] [--bw-global "…"] [--n-bounds "…"]
                   [--jobs N] [--seed S] [--mode {fast,random,exhaustive}]
```

For each existing point under `runs/$DELAY_MODEL/$ARCH_TAG/bw${BW}_nb${NB}/`:

1. Read `point.json` to get `bw_global`, `n_bounds`, `variant`,
   `pipeline_stages`.
2. Resolve `binner.v` at that point.
3. Invoke `python verif/runner.py --verilog <…> --bw <…> --nb <…>
   --stages <…>` (or equivalent direct call).
4. Record OK/FAIL in a per-sweep log dir under `runs/_verif/$DATE/`
   (parallel to the existing `runs/_sweeps/`).

Concurrency: same OUTER/INNER discipline as `run_sweep.sh`. Cocotb
simulations don't multithread the simulator (iverilog is single-thread),
so OUTER can equal nproc here.

### 5.1 Verification *of* a point is decoupled from PnR *of* the point

We can run verif against `binner.v` even when the point hasn't been PnR'd
(SKIP_PNR), since the testbench reads only the codegen output. That
means verif is the natural follow-on to a `--skip-pnr` grid: fast XLS
codegen + fast cocotb sims, no librelane needed. Then we can layer
PnR + post-PnR verif (M4b) on top later.

---

## 6. Things we are explicitly deferring

- **Post-PnR (gate-level) simulation.** Same testbench, but
  `VERILOG_SOURCES` becomes the post-PnR netlist + the sky130 cell
  library Verilog views. iverilog can do this; verilator is harder.
  Sequenced as M4b after M4a is green and stable. The plan there is
  separate.
- **SAIF dump → vectored power.** Cocotb can write SAIF for OpenSTA to
  re-do `report_power` with real activity. That's METRICS.md §5's
  refinement path — separate work item.
- **CI integration.** No CI runner here yet. Easy to add once verif is
  scripted; deferred.
- **Coverage.** `cocotb-coverage` is a thing, but the binner is small
  enough that line/branch coverage in the testbench is trivial. Skip.

---

## 7. Open questions to converge before writing code

These are the items we need to settle so the first implementation
doesn't churn:

1. **Bounds packing order in the generated Verilog.** Element 0 at the
   LSB end (most likely) or MSB end? Write a 2-bin pinned test with
   distinguishable values and inspect — settle this before the test
   utility code is fixed.

2. **How to handle the pipeline variants in the same testbench.** The
   `parallel` (1-stage) point has latency 1; `pipe_s4` has latency 4 +
   I/O reg. Read it from `point.json` and pass via env, or hard-code per
   point? Probably the former.

3. **Random-bounds generator: cumulative deltas vs sorted draws.** Both
   produce monotonic outputs; deltas give better coverage of "tight
   clusters", sorted draws give better coverage of "even spread". Use
   both, with a 50/50 mix.

4. **Test isolation between vectors.** Do we reset the DUT between
   bound changes, or just wait `latency + 1` cycles for the input flops
   to capture the new bounds? Probably the latter (cheaper, matches
   real firmware behaviour: program once, run many).

5. **Reference Python: README synced to verif/ how?** Two ways:
   (a) the README has its own snippet, with a note pointing to
   `verif/binner_ref.py` as the executable form (and an unenforced
   manual sync); (b) a small generator that pulls the function body
   from `verif/binner_ref.py` into the README on regen. Recommend (a) —
   simpler, the function is short, drift will be obvious.

6. **Should `verif/binner_ref.py` also model the refined form (M5,
   `threshold_i_m << threshold_e`)?** Not now — let it land when
   M5 actually exists in DSLX. The reference module can grow a second
   function then.

7. **conda + nix layering: does cocotb's VPI load actually work with
   the conda Python while iverilog/verilator come from the nix
   environment?** This is the only "unknown" in the tooling stack; an
   empirical 30-min check on a single point is the right first step,
   not a paper analysis.

---

## 8. Implementation order, once we agree

1. Add `cocotb >=1.9` to `environment.yml`, `mamba env update`.
2. Create `verif/binner_ref.py` (just the function + tests).
3. Create `verif/test_binner.py` + `verif/runner.py` for one
   hard-coded point (`bw8_nb4` `parallel`/`ref`). Get one green
   simulation. This is the conda-vs-nix layering check.
4. Generalise: parameterise `BW_GLOBAL`/`N_BOUNDS`/`STAGES` from env;
   verify on a second point (`bw16_nb16` is good — exercises wide buses).
5. Add `flows/run_verif.sh`; run it over the existing sky130 grid.
6. Wire into PLAN.md M4 (mark M4a done; M4b stays deferred).
7. Update README to point at `verif/binner_ref.py`.

Each step is small and independently committable.
