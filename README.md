---
format: pdf
---

# Readme

For power, performance, area (PPA) driven development, code is written in DSLX (part of google's XLS SDK, see below), compiled to verilog, synthesized by librelane, and then PPA metrics are collected.

## Where to start

To reproduce the current baseline (DSLX reference, multi-architecture codegen, and one librelane sky130 PnR run with PPA metrics), follow [HOWTO.md](./HOWTO.md). Every tool invocation and config file is documented there.

`CLAUDE.md` is operational guidance for Claude Code sessions in this repo. `PLAN.md` is the study plan (parameter sweep, architecture strategy, milestones, gates). `DESIGN_NOTES.md` collects design explorations and rationale we've discussed but not (yet) committed to building. `METRICS.md` documents where every PPA number comes from — which tool and abstraction layer produces it, how faithful it is, and how it could be refined. `BLUEPRINT.md` is the guide to reusing this repo as a template for a *different* PPA study — what to change for a new function, parameters, or technology, and what transfers unchanged.

## Toolchain status

`external/xls-bin/` (statically-compiled XLS binaries) and `external/xls/` (the upstream source/doc clone) are now pinned to the **same XLS revision** — tag `v0.0.0-10042-g81ff4fdf7` (commit `81ff4fdf7`). Two consequences worth knowing up front.

### `import std;` works

The earlier version skew that made every stdlib import fail typecheck (`TypeInferenceError: uN[32][0] Zero-sized arrays cannot be indexed` in `enumerate`) is gone now that the binary and the stdlib it parses come from one revision. `dslx/binner.x` uses `std::clog2(N_BOUNDS)` directly as a parametric default; no inline-helper workaround is needed.

### The binary set is complete for this flow — the one real gap is RTL simulation

The XLS binaries live in `external/xls-bin/bin/` (invoke them as `./external/xls-bin/bin/codegen_main`). The release ships **18 statically-linked C++ binaries**, covering the whole DSLX → IR → Verilog flow and then some: `interpreter_main`, `ir_converter_main`, `opt_main`, `codegen_main`, `eval_ir_main`, `eval_proc_main`, `delay_info_main`, `lec_main` (formal logic-equivalence checking), `prove_quickcheck_main`, `aot_compiler_main`, `dslx_fmt`, `dslx_ls`, `parse_and_typecheck_dslx_main`, `proto_to_dslx_main`, `type_layout_main`, `print_bom`, `benchmark_main`, `pass_metrics_main`. The cloned `xls-bin` repo also carries `README.md` (cross-build recipe) and `XLS_SUMMARY.md` (per-binary "what & why").

Three tools are deliberately **not** in the release:

| not shipped               | what it does                                         | how it's covered here    |
|---------------------------|------------------------------------------------------|--------------------------|
| `simulate_module_main`    | RTL functional sim of generated Verilog              | can't be linked statically; **use cocotb + iverilog/verilator** instead (`PLAN.md` M4) |
| `gather_design_stats`     | Yosys/OpenSTA logs → `DesignStats` metrics proto     | a Python script; runs from a source checkout on the synth machine (xls-bin `README.md` Appendix) |
| `jit_wrapper_generator_main` | Generates JIT-wrapper source from IR              | a Python build-time helper; not part of this flow |

The one absence that affects this study is **`simulate_module_main`** — see `PLAN.md` M4 for how the external-simulator path is scheduled (deferred behind the first Pareto-frontier result, by priority — not by a missing binary). `lec_main` is present and covers formal IR/netlist equivalence. `eval_proc_main` (proc evaluation, the **M7** gate) and `benchmark_main`/`pass_metrics_main` (pre-PnR scheduling metrics) are now all present. If a still-missing tool would meaningfully help, flag it to the maintainer (the user maintains `github.com/gbsha/xls-bin` and can publish additional binaries on request) — **do not try to build XLS from source as a workaround.**

## Study objective

Consider the following python code (the executable form lives at
[`verif/binner_ref.py`](./verif/binner_ref.py) and is what the cocotb
testbench checks every cycle against):
```python
def fun(global_index: int, lower_bin_boundaries: list[int]) -> int:
    # Contract: inactive entries hold a sentinel that global_index never reaches.
    # In a BW_GLOBAL-wide hardware realization the thresholds are the same width
    # as global_index, so the top value (2**BW_GLOBAL - 1) is reserved as that
    # sentinel and firmware must keep 0 <= global_index <= 2**BW_GLOBAL - 2.
    # (Or widen thresholds to BW_GLOBAL+1 bits to make the sentinel safe over the
    # full global_index range.)
    bin_index: int = 0
    for threshold in lower_bin_boundaries[1:]:
        if global_index >= threshold:
            bin_index += 1
    local_index: int = global_index - lower_bin_boundaries[bin_index]
    return bin_index, local_index
```
The objective is to implement this function in hardware and do a detailed PPA analysis. 

### Constraints

The function is subject to the following constraints:

1. The buswidth `bw_global_index` of `global_index`, and thereby the buswidth of the entries of `lower_bin_boundaries` are buildtime parameters.
2. The thresholds in `lower_bin_boundaries` are runtime parameters programmable by firmware.
3. The number of entries `n_boundaries` of `lower_bin_boundaries` is defined at buildtime, and the number of active entries of `lower_bin_boundaries` is defined at runtime, so a sentinel has to be defined that is never surpassed by `global_index` for the inactive entries.
4. In a refinement, the thresholds in `lower_bin_boundaries` are constrained to be of the form `threshold_i_m << threshold_e`, where the maximum bitwidth `bw_threshold` of `threshold_i_m` is defined at buildtime, and the value of `threshold_i_m` and `threshold_e` are programmable by firmware. The value `threshold_e` is shared by all entries of `lower_bin_boundaries`. This refinement allows to reduce the cost of the comparison, as in each comparison only `bw_threshold` bits need to be compared.

### Analysis

The objective is to do a thorough analysis, to see how performance (throughput, latency, precision), power, and area scale with the buildtime parameters `bw_global_index`, `n_boundaries`, and `bw_threshold`.

For instance, one can imagine three realizations of the python loop:
* Time division multiplexing (TDM): one single comparator realizes all comparisons. Wet finger guess: Low throughput, high latency, low area.
* Pipelining: `n_boundaries` many comparators are used serially. Wet finger guess: High throughput, high latency, high area, moderate wiring.
* Parallelization: `n_boundaries` many comparators are used in parallel (thermometer code). Wet finger guess: high throughput, low latency, high area, high wiring.

The objective is to assess whether (qualitatively) and how much (quantitatively) these wet finger guesses manifest themselves in synthesized hardware.

## Enter the environment with your copilot

```
cd /PATH/TO/YOUR/LIBRELANE
nix-shell
cd /PATH/TO/THIS_REPOSITORY
claude
```

## Install Tools

### Librelane

Use nix-based librelane installation following
* https://librelane.readthedocs.io/en/latest/installation/nix_installation/installation_linux.html

### Google's XLS: Accelerated HW Synthesis

Documentation can be found at
* https://google.github.io/
* https://github.com/google/xls/

The `google/xls` github repository is locally cloned to `external/xls`, for locally having access to the documentation and dslx language specification. Note that `external/xls` does **not** contain the binaries. It is pinned to tag `v0.0.0-10042-g81ff4fdf7` (commit `81ff4fdf7`); the `xls-bin` release below must be the one built from that same commit so the binaries and the stdlib they parse stay in sync.

Install the binaries statically compiled from https://github.com/gbsha/xls-bin/ by downloading the release matching the pinned commit above. The release tag is `xls-<commit>-xlsbin-<build>` — here `xls-81ff4fdf7-xlsbin-1`, built from the same `81ff4fdf7` that `external/xls` is checked out at (the `-xlsbin-N` suffix is the bundle build number; bump it for a rebuild of the same commit). The binaries extract into `external/xls-bin/bin/`:
```
mkdir -p ./external/xls-bin/bin && cd ./external/xls-bin/bin

curl -L -O https://github.com/gbsha/xls-bin/releases/download/xls-81ff4fdf7-xlsbin-1/xls-81ff4fdf7-xlsbin-1-linux-x86_64.tar.gz
tar -xzf xls-81ff4fdf7-xlsbin-1-linux-x86_64.tar.gz
chmod +x *
```
