# Design notes

Design explorations, candidate approaches, and rationale we've discussed but
have **not** (or not yet) committed to. Kept separate from the other docs on
purpose:

- `PLAN.md` — the methodology and milestones we *are* executing.
- `HOWTO.md` — how to *run* the flow.
- `DESIGN_NOTES.md` (this file) — design questions and options, including ones
  we may never build. This keeps speculative work out of PLAN without losing the
  reasoning behind a choice.

---

## Modeling firmware-programmable thresholds

**Status:** not implemented; candidate, sequenced after the first Pareto frontier.

Today `dslx/binner.x` takes `lower_bin_boundaries` as a plain input port — both
it and `global_index` are just function inputs. The "firmware programs the
thresholds into registers, then they persist while data streams" nature is
abstracted away (the threshold storage is assumed to live in an upstream
CSR/register block driving the port). This note records how we'd model it for
real, what it actually costs, and why it's a meaningfully bigger step.

### The crux: programmable = stateful, and in XLS state means a proc

A pure function recomputes everything every evaluation and remembers nothing.
"Program once, persist across many data beats" is by definition **state that
outlives a single evaluation**, and in XLS state lives in a **proc** (functions
are stateless by construction). So modeling programmability is the same
architectural step as TDM: function → proc. That is why it belongs near M7, and
why `eval_proc_main` (now shipped) matters for verifying it.

### Separate what programmability *costs* from SoC glue

Be precise about what is part of the *core* versus integration plumbing:

| piece | model it? | why |
|---|---|---|
| threshold **registers** (`N_BOUNDS × BW_GLOBAL` flops) | **yes** | the real, often-dominant added area |
| **write decode** (route a write to register `addr`: a `clog2(N)`→`N` decoder + per-register load-enable) | **yes** | small but real |
| bus protocol (APB / AXI-lite handshake, address map) | **no** | SoC integration glue, not the binner's PPA |
| where the values *come from* | **testbench** | "firmware" is the agent that drives the writes |

The bus protocol is the unrealistic-to-bake-in part, so don't. Model the
**register file + write port**; the "firmware" is whatever drives the config
interface in the testbench. No filesystem, no CSV-in-`.v`.

### Shape of the proc (reuses the existing pure function)

```
proc binner_prog<BW_GLOBAL, N_BOUNDS, ...> {
    state:  thresholds: uN[BW_GLOBAL][N_BOUNDS]   // the programmable registers
    chans:  config_in : (addr: uN[clog2(N_BOUNDS)], value: uN[BW_GLOBAL])  in
            data_in   : uN[BW_GLOBAL]                                       in
            result_out: (uN[BW_BIN], uN[BW_GLOBAL])                         out

    next(state):
        # a config write updates one register (models firmware programming a mode)
        on config_in (addr, value):  state.thresholds[addr] = value
        # a data beat runs the EXISTING pure function against current state
        on data_in global_index:     result_out ! binner(global_index, state.thresholds)
}
```

Pseudocode — verify exact proc syntax against
`external/xls/.../tutorials/how_to_use_procs.md` before writing real `.x`. Three
properties make it clean:

- **The compute datapath is untouched** — `next` calls the *same* `binner`
  function from `binner.x`. The proc only adds storage + a write path, so there
  is no logic duplication and the function stays independently testable.
- **"Loading a mode" = a sequence of `config_in` sends, then `data_in` sends.**
  The firmware model is the test agent: `eval_proc_main` takes a stimulus script
  (send N config messages → send data → check results); cocotb drives the same
  channels and *that* Python can read a CSV of modes. The CSV lives in the
  testbench, never in the `.v`.
- **It isolates the programmability cost.** `PPA(binner_prog) − PPA(binner
  function)` ≈ registers + write-decode + channel ready/valid handshake — a
  clean, attributable experiment.

### Recommendation — two tiers

- **Tier 1 (current, recommended for the sweep): keep thresholds as a port; account
  for register storage separately.** The function captures the *comparison-logic*
  PPA — the axis the study is about (parallel / pipelined / TDM, refined vs
  unrefined). The threshold registers are a near-constant additive offset
  (`N_BOUNDS × BW_GLOBAL` flops, roughly independent of comparison architecture),
  so folding them into every point would just shift all curves up and blur the
  comparison. Estimate them analytically (flop area × bits), or as one separate
  point. A port is also trivial for cocotb to drive.
- **Tier 2 (when the programmable block is itself the deliverable): the proc above.**
  The realistic "register file + binner" as one synthesizable block, verified
  with `eval_proc_main`. It shares all the proc machinery TDM (M7) needs, so the
  two are natural neighbors — do it once past the first frontier, to quantify the
  cost of programmability itself.

### Related axis

The sentinel width is a neighboring design choice (now documented in
`dslx/binner.x` and the README reference): `BW_GLOBAL`-wide thresholds reserve
the top value as the sentinel via a firmware contract
(`global_index ≤ 2**BW_GLOBAL − 2`); widening thresholds to `BW_GLOBAL+1` bits
makes the sentinel safe across the full input range at a small PPA cost; an
explicit active-count/valid-mask avoids sentinels entirely with extra muxes.
A candidate sweep axis if compare-width cost (cf. the refined form, M5) turns out
to matter.
