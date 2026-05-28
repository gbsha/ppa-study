# THERMOMETER.md — exploiting monotonic thresholds in the binner

This document records the design space for **encoding the "thresholds are
strictly monotonically increasing" property into the DSLX so that the
resulting IR exploits it**, without descending to gate-level hand-coding.
**Sketch B is implemented** (`dslx/binner.x:binner_prio`) and PnR-verified
(see `HOWTO.md` §2h "Post-PnR comparison" — at `bw16_nb16` it drops the
critical path 9.02 → 7.98 ns and vectorless power 16.27 → 3.54 mW, with a
regression at `bw8_nb4`). Sketches A, C, D remain candidate follow-ons —
see §6.

The doc reads as: primer on the primitives, what XLS gives us, the four
candidate shapes (B shipped, A/C/D optional), best-practice rules, and
open questions to validate further.

Context: today's `dslx/binner.x` is a left-fold conditional-add over the
comparison vector. From `HOWTO.md §2h` the sky130 critical path for the small
`bw8_nb4` reference point is 1809 ps and the popcount chain alone burns 568 ps
of it (31 %). The comparisons are thermometer-coded by construction — that is
the structural fact we are leaving on the table.

The case for the rewrite gets *stronger* at scale, not weaker. Re-running
`delay_info_main` on `runs/sky130/parallel/bw16_nb16/binner.opt.ir` (16-bit
global index, 16 thresholds — the largest point in today's sweep) gives a
total of 4986 ps, of which **3327 ps (67 %) is the popcount**. The optimizer
keeps the first ~7 comparators in the fold's mux/add chain and switches to a
balanced adder tree for the rest, but the serial fold-arm is what bin_index
waits on. Comparators are 8 %, the lookup mux 12 %, the subtractor 13 %;
between `bw8_nb4` and `bw16_nb16` the popcount delay grew ~5.9× while every
other segment grew ≤1.4×. Post-PnR at 10 ns the nominal tt corner closes
comfortably (+0.977 ns setup ws, zero max-slew violations) — so the design
*works* at scale — but the popcount is the obvious structural target.

Working assumption throughout: **the firmware contract that
`lower_bin_boundaries` is strictly monotonically increasing always holds.**
Non-monotonic programming is a firmware bug, not a hardware concern. The
hardware does not need to degrade gracefully under contract violation.

---

## 1. Primer: the digital-design primitives we keep reaching for

Most of the "exploit monotonicity" moves boil down to four primitives. They're
all cheap (log-depth) trees on any modern cell library; the trick is getting the
IR to recognise the shape.

### Thermometer code

A bit vector that is set in a contiguous LSB-prefix:

```
t = 0b0000_0000   (bin 0 — nothing exceeded)
t = 0b0000_0001   (bin 1 — exceeded threshold[1])
t = 0b0000_0011   (bin 2 — exceeded thresholds[1..2])
t = 0b0000_0111   (bin 3)
...
```

Under our contract, the comparison vector `c[i] = (global_index >= lbb[i+1])`
for `i = 0 .. N_BOUNDS - 2` **is** a thermometer pattern. Monotonicity is the
reason: if `global_index ≥ lbb[i+1]` then `global_index ≥ lbb[i]` too.

### Popcount

Count of set bits. For arbitrary input it's a balanced reduction tree of
half/full-adders, depth `O(log N)`, gate count `O(N)`. For thermometer input it
just degenerates to "position of the leading zero" — which is a priority
encoder, not an adder tree.

### Priority encoder

Given any bit vector, return the index of (e.g.) the lowest set bit. Built as a
log-depth OR/AND tree (no adders). For a thermometer input, "first zero from
the LSB" is the bin index directly — no `+1`, no carries.

### One-hot encoding

A vector with exactly one bit set. The *boundary* bit of a thermometer pattern
(the lowest zero, or equivalently the bit at index `popcount(t)`) is a one-hot
mask of length `N_BOUNDS` that points to the active bin. One-hot is the natural
selector for a multi-way mux: `lbb[bin_index]` is the OR-reduction of
`lbb[i] AND h[i]` over all `i`, which is exactly `one_hot_sel(h, lbb)`.

The chain we want to exploit is therefore:

```
comparisons (thermometer) → one-hot boundary → bin_index   (via encode)
                                            → lbb_at_bin  (via one_hot_sel)
```

instead of today's:

```
comparisons → popcount (mux+adder chain) → bin_index → array_index mux
```

The "exploit monotonicity" payoff is twofold: a cheaper reduction (logical OR
tree instead of an adder tree), **and** the threshold lookup fuses with the
encoding (no separate `array_index` mux on `bin_index`).

---

## 2. What XLS / DSLX gives us

This is the toolbox we'll be picking from. Sources: `external/xls/docs_src/
ir_semantics.md` (IR ops) and `external/xls/docs_src/dslx_std.md` (DSLX
builtins). Where the IR op exists, the DSLX builtin lowers straight to it and
the optimizer has dedicated passes that recognise the shape.

| concept              | IR op            | DSLX builtin / stdlib  | notes                                              |
| -------------------- | ---------------- | ---------------------- | -------------------------------------------------- |
| popcount             | (adder tree)     | `std::popcount`        | currently a `for`-fold: balanced but no shortcut for thermometer input |
| count leading zeros  | `clz`            | `clz` / `std::clzt`    | builtin returns `clz(x)`; `clzt` is a tree variant |
| count trailing zeros | `ctz`            | `ctz`                  | symmetric to `clz`                                 |
| one-hot from bits    | `one_hot`        | `one_hot(x, lsb_prio)` | output is `N+1` bits — extra MSB flags "all zero"  |
| one-hot from binary  | `decode`         | `decode<uN[W]>(x)`     | binary → one-hot                                   |
| binary from one-hot  | `encode`         | `encode(x)`            | one-hot → binary (OR of indices if not one-hot)    |
| one-hot mux          | `one_hot_sel`    | `one_hot_sel(s, c)`    | OR-reduction over selected cases — log depth in cases |
| priority mux         | `priority_sel`   | `priority_sel(s, c, d)`| picks the lowest set bit's case                    |

Three of these are worth dwelling on:

**`one_hot` (builtin).** Takes any bit vector and emits a one-hot version,
picking the lowest set bit (`lsb_prio=true`) or the highest (`lsb_prio=false`).
The output is one bit wider than the input — the extra MSB is set iff the input
was all-zero. The XLS reference (`ir_semantics.md`:973–976) explicitly says: *once
this operation has been applied, the optimizer knows the output has the
one-hot property*. That's the structural information we want to pin in.

**`one_hot_sel` (IR op).** A multi-way mux whose selector is a one-hot vector;
the output is the OR of the selected cases. Its delay model
(`delay_estimation.md`:188–194) is `a*bitwidth + b*log2(bitwidth) + c*N_cases +
d*log2(N_cases) + e` — i.e. XLS models it as a **log-depth tree in the case
count**. That's a structurally cheaper lookup than `array_index` for our use,
because `array_index` on a runtime index lowers to a tree of binary muxes
driven by `bin_index` bits.

**`encode` / `decode` (IR ops).** Direct one-hot ↔ binary conversion as
single nodes. `encode` on a non-one-hot input is the OR of all set indices —
not what we want, so we should only feed it from a node the optimizer knows is
one-hot (i.e. the output of `one_hot`, or our constructed boundary mask once we
prove it's one-hot).

What's **not** in the toolbox: any contract / `assume!` form that the optimizer
turns into a IR-time guarantee about monotonicity. There is QuickCheck for
testing properties, and the optimizer does its own range/bit-set analysis, but
"thresholds are sorted" is not a declarable invariant. That means we *cannot*
just annotate the input and hope — we have to write code whose IR shape forces
the right hardware regardless of optimizer cleverness.

---

## 3. Candidate DSLX shapes for the binner

Four sketches, each highlighting a specific trade-off. **Sketch B is the one
that shipped** — `dslx/binner.x:binner_prio`, formally proved equivalent to
the fold reference via `prove_quickcheck_main` and RTL-verified via cocotb
(`COCOTB.md`). The other three are candidate follow-ons (see §6).

### Sketch A — flat popcount (no monotonicity exploited)

The smallest change from today's fold. We build the comparison vector
explicitly and let `std::popcount` do a balanced reduction.

```dslx
pub fn binner_popcount<
    BW_GLOBAL: u32, N_BOUNDS: u32, BW_BIN: u32 = {std::clog2(N_BOUNDS)},
    NM1: u32 = {N_BOUNDS - u32:1}
>(
    global_index: uN[BW_GLOBAL],
    lower_bin_boundaries: uN[BW_GLOBAL][N_BOUNDS],
) -> (uN[BW_BIN], uN[BW_GLOBAL]) {
    // c[i] = (global_index >= lbb[i+1])  for i in 0 .. N_BOUNDS-2
    let cmps = for (i, acc): (u32, uN[NM1]) in u32:0..NM1 {
        let bit = (global_index >= lower_bin_boundaries[i + u32:1]) as uN[NM1];
        acc | (bit << i)
    }(uN[NM1]:0);

    let bin_index = std::popcount(cmps) as uN[BW_BIN];
    let local_index = global_index - lower_bin_boundaries[bin_index];
    (bin_index, local_index)
}
```

What we expect:
- Comparisons are explicit and parallel.
- The popcount fold inside `std::popcount` *should* produce a more balanced
  adder tree than our left-fold currently does — but it's still arithmetic,
  not logical, so the per-level cost is full-adder-ish.
- Threshold lookup still goes through `array_index` on `bin_index`.

What we don't get: monotonicity, lookup fusion. This is the
"keep-it-conservative" baseline against which we measure the others.

### Sketch B — priority encoder, monotonicity exploited (no lookup fusion)

Use `ctz` on the *inverted* thermometer to find the boundary position directly.

```dslx
pub fn binner_prio<
    BW_GLOBAL: u32, N_BOUNDS: u32, BW_BIN: u32 = {std::clog2(N_BOUNDS)},
    NM1: u32 = {N_BOUNDS - u32:1}
>(
    global_index: uN[BW_GLOBAL],
    lower_bin_boundaries: uN[BW_GLOBAL][N_BOUNDS],
) -> (uN[BW_BIN], uN[BW_GLOBAL]) {
    // Same comparison vector as Sketch A.
    let cmps = /* ... as above ... */ uN[NM1]:0;

    // Under monotonicity, cmps is a thermometer with k=bin_index ones.
    // bin_index = ctz(!cmps). The boundary cases line up naturally:
    //   - all bins exceeded → cmps = 111…1 → !cmps = 0 → ctz returns NM1
    //     = N_BOUNDS - 1, which is exactly the top bin index;
    //   - no bins exceeded → cmps = 0 → !cmps = 111…1 → ctz returns 0.
    let bin_index = ctz(!cmps) as uN[BW_BIN];
    let local_index = global_index - lower_bin_boundaries[bin_index];
    (bin_index, local_index)
}
```

What we expect:
- `ctz` lowers to a log-depth OR/AND tree — cheaper per level than the popcount
  adder tree.
- The threshold lookup is still a separate `array_index`.

This is the simplest "exploit monotonicity" rewrite. It removes the popcount
chain but keeps everything else.

### Sketch C — one-hot boundary, fused threshold lookup

Compute the one-hot mask `h` whose set bit points at the active bin, then use
`one_hot_sel` to do the threshold lookup in one log-depth tree. `bin_index`
falls out via `encode(h)`.

```dslx
pub fn binner_onehot<
    BW_GLOBAL: u32, N_BOUNDS: u32, BW_BIN: u32 = {std::clog2(N_BOUNDS)},
    NM1: u32 = {N_BOUNDS - u32:1}
>(
    global_index: uN[BW_GLOBAL],
    lower_bin_boundaries: uN[BW_GLOBAL][N_BOUNDS],
) -> (uN[BW_BIN], uN[BW_GLOBAL]) {
    // c[i] = (global_index >= lbb[i+1])
    let cmps = /* as Sketch A */ uN[NM1]:0;

    // Boundary mask h of width N_BOUNDS:
    //   h[i] = (i == 0)        ? !cmps[0]
    //        : (i == N_BOUNDS-1) ? cmps[N_BOUNDS-2]
    //        :                     cmps[i-1] & !cmps[i]
    //
    // Construct by aligned shifts so the optimizer sees a pure AND-of-bits
    // pattern (no fold, no adder).
    let lsb_pad  = (cmps as uN[N_BOUNDS]) << u32:1 | uN[N_BOUNDS]:1;  // c[i-1] (with c[-1]:=1)
    let msb_pad  =  cmps as uN[N_BOUNDS];                              // c[i]   (with c[N-1]:=0)
    let h: uN[N_BOUNDS] = lsb_pad & !msb_pad;

    // Lookup via one_hot_sel: log-depth tree, no array_index mux.
    let lbb_at_bin = one_hot_sel(h, lower_bin_boundaries);
    let local_index = global_index - lbb_at_bin;
    let bin_index = encode(h) as uN[BW_BIN];
    (bin_index, local_index)
}
```

What we expect:
- `h` is built with two shift/mask layers (no carry chain at all).
- `one_hot_sel` and `encode` both lower to log-depth trees over `N_BOUNDS`.
- The `array_index` on `bin_index` disappears — saving the 423 ps lookup layer
  observed in the current 1809 ps path.
- We *may* want to call `one_hot(h, lsb_prio=true)` instead of using `h` raw to
  formally tag the value as one-hot for the optimizer. Open question: does the
  shift-and-mask form get inferred as one-hot by XLS's BDD analysis
  (`passes_list.md` says one-hot selectors get specialised treatment when
  proven). Cheapest experiment: build it both ways and compare opt.ir.

### Sketch D — fully fused (parallel subtractors, one_hot_sel of results)

The most aggressive: compute *all* candidate `(global_index - lbb[i])` values
in parallel and use `one_hot_sel(h, ...)` to pick the right one. This collapses
`bin_index → array_index → sub` into a single OR-reduction over the case
outputs.

```dslx
pub fn binner_fused<
    BW_GLOBAL: u32, N_BOUNDS: u32, BW_BIN: u32 = {std::clog2(N_BOUNDS)},
    NM1: u32 = {N_BOUNDS - u32:1}
>(
    global_index: uN[BW_GLOBAL],
    lower_bin_boundaries: uN[BW_GLOBAL][N_BOUNDS],
) -> (uN[BW_BIN], uN[BW_GLOBAL]) {
    let cmps = /* as A */ uN[NM1]:0;
    let h = /* as C */ uN[N_BOUNDS]:0;

    // N_BOUNDS parallel subtractors, then one_hot_sel.
    let candidates: uN[BW_GLOBAL][N_BOUNDS] =
        for (i, acc): (u32, uN[BW_GLOBAL][N_BOUNDS]) in u32:0..N_BOUNDS {
            update(acc, i, global_index - lower_bin_boundaries[i])
        }(zero!<uN[BW_GLOBAL][N_BOUNDS]>());
    let local_index = one_hot_sel(h, candidates);
    let bin_index = encode(h) as uN[BW_BIN];
    (bin_index, local_index)
}
```

What we expect:
- Critical path: max(`cmps + h` build-up, single subtractor) → one_hot_sel.
  The subtractors run in *parallel* with the comparator-to-boundary chain.
- Area cost is N_BOUNDS subtractors instead of one — a clear area-for-speed
  trade. This sketch matters most when N_BOUNDS is small and subtractor cost
  is modest; less attractive at N_BOUNDS=16, BW_GLOBAL=16.
- Open question: does XLS already do "speculative parallel arms" automatically
  given an array_index pattern? Worth checking by diffing opt.ir of Sketch C
  vs D.

---

## 4. Best-practice rules of thumb

A few principles that fall out of the above and that we should agree on before
writing the rewrite.

1. **Express the structure; do not rely on the optimizer to infer it.** XLS
   has no contract for "this array is sorted." The fold form of today's binner
   shows the cost: the optimizer reshapes it part-way but stops short of the
   tree we'd hand-build. The rule: if a property is load-bearing for the
   architecture, write code whose IR shape *forces* the right structure even
   without that property.

2. **Reach for IR ops with a known-good lowering before reaching for arithmetic.**
   `one_hot`, `one_hot_sel`, `priority_sel`, `encode`, `decode`, `clz`, `ctz`
   all have dedicated optimizer passes (`passes_list.md` lists multiple
   recognisers and rewriters per op) and a log-depth delay model. A
   `for`-fold with an `if` does *not* — it's a generic primitive that
   competes for the optimizer's attention with everything else.

3. **Keep the high-level reference, write the optimised version alongside.**
   The fold is the cleanest semantic definition of binning. Keep it (perhaps
   under a different name, e.g. `binner_ref`) as both the spec and a
   `quickcheck` against the optimised version. Then any rewrite carries its
   own equivalence proof.

4. **Trust the monotonicity contract.** Strict monotonicity of
   `lower_bin_boundaries` is a firmware-side invariant; non-monotonic
   programming is a firmware bug, not a hardware concern. The rewrite can
   assume `cmps` is thermometer-coded and `h` is one-hot without any
   defensive cap or fall-back. (This keeps the IR clean: a `std::min` cap or
   a saturating sub adds an unnecessary node on the critical path.)

5. **Stop at the IR shape you can read.** The rewrite is a success when
   `opt.ir` shows the primitives we expect (`one_hot_sel`, `encode`) with the
   case widths and operand widths that map to the obvious hardware. If the
   optimizer reshapes it into a tangle, that's a signal to either add an
   explicit `one_hot` call or accept that we're going lower than the
   abstraction wants to support.

6. **One axis at a time.** When we do implement, pick *one* sketch (C is the
   front-runner — biggest expected win without exploding area), rebuild
   `opt.ir`, rerun `delay_info_main`, and compare against the baseline. Only
   then introduce parallel subtractors (Sketch D) or other moves.

---

## 5. Things to validate before claiming a win

Open questions we should answer in the IR / delay_info before committing:

- **Does `one_hot_sel` on a non-`one_hot`-tagged selector still get the
  log-depth tree?** The op is *defined* as OR-of-cases, so it should — but
  the constant-folding and BDD passes may behave differently if the
  optimizer can't prove the selector is one-hot. Diffing opt.ir between
  Sketch C with and without an explicit `one_hot(h, lsb_prio=true)`
  preconditioning will answer this.

- **What does `std::popcount` actually generate for `N=3`?** Its source is
  another `for`-fold (`std.x:1072`). If it unrolls to a flat add-of-bits,
  good. If it produces the same left-fold pattern as our own code, then
  Sketch A is not the improvement we hope for and the comparison against
  Sketches B/C/D is the only thing that matters.

- **Are `ctz`/`clz` modeled with realistic delays in the sky130 model, or are
  they sampled from a synthetic netlist?** The relative ranking of Sketch B
  versus Sketch C depends on this. `delay_estimation.md` claims library
  characterisation, but specific op coverage varies.

- **Is the QuickCheck against the fold reference exhaustive enough?** A
  `#[quickcheck]` that compares the rewrite against `binner_ref` on
  *monotonic* inputs proves functional equivalence inside the contract. We
  don't validate behaviour outside the contract (that's firmware's job), so
  the generator just needs to produce sorted threshold arrays — likely by
  sampling a random prefix-sum or sorted draw.

- **Are we measuring the right thing?** XLS `delay_info_main` uses its own
  cell model. Yosys/ABC will techmap differently, and the post-PnR critical
  path includes interconnect. Our PPA pipeline already captures both layers
  (XLS estimate + post-PnR `ws`-derived path), so the comparison can be done
  end-to-end — that's the gold signal, not the IR estimate alone.

---

## 6. Status and optional follow-ons

### What shipped

- **Sketch B (`dslx/binner.x:binner_prio`).** `ctz(!cmps)` collapsed by the
  XLS optimizer into `one_hot(lsb_prio=true)` + `encode` — two canonical
  log-depth IR ops. The fold reference `binner` is kept alongside as the
  semantic anchor (`prove_quickcheck_main` proves equivalence over all
  256 / 65 536 `global_index` values for fixed monotonic bound arrays).
  Selected at codegen time via `flows/run_point.sh --variant prio`.
- **Post-PnR data** (`HOWTO.md` §2h "Post-PnR comparison" subsection): at
  `bw16_nb16`, critical path 9.02 → 7.98 ns (−11.6 %), vectorless power
  16.27 → 3.54 mW (−78 %), ss-corner failure halves. At `bw8_nb4` the
  rewrite *regresses* (5.32 vs 4.71 ns) — small-N synthesis prefers the
  fold's mux chain over a 4-output one_hot encoder. There is a crossover
  somewhere between `nb=4` and `nb=16`; locating it is the natural next
  sweep.

### Optional follow-ons (none required to consider this complete)

- **Sketch A** — flat `std::popcount`. Cheapest control point against
  Sketch B's win: shows whether the gain is the balanced reduction tree
  alone, or the priority-encoder structure on top.
- **Sketch C** — one-hot boundary + `one_hot_sel` fused threshold lookup.
  Predicted to drop the 423–585 ps `array_index` mux layer on top of
  Sketch B's gain. Requires verifying that `one_hot_sel` retains its
  log-depth tree when the selector isn't explicitly tagged one-hot.
- **Sketch D** — parallel subtractors + `one_hot_sel` over their results.
  Area-for-speed extreme; only attractive when subtractor cost is modest.

### Settled open questions

The §5 questions kept here as historical record:

- *Does `one_hot_sel` on a non-`one_hot`-tagged selector retain log-depth?* —
  Not directly probed: Sketch B sidesteps `one_hot_sel` by going through
  `one_hot` + `encode`. Still open for Sketch C.
- *Is the QuickCheck against the fold reference exhaustive enough?* —
  Resolved: `prove_quickcheck_main` proves the property symbolically
  (`dslx/binner.x:prop_prio_matches_ref_*`), not just samples it.
- *Are we measuring the right thing?* — Resolved: post-PnR comparison is
  done end-to-end (PLAN.md M8, HOWTO §2h).

The Yosys/ABC techmapping observation — at small N the fold's mux chain
maps better than `one_hot`'s priority encoder — is the new open question
that emerged from PnR. Worth a sweep across the full grid to map the
crossover.
