# Readme

For power, performance, area (PPA) driven development, code is written in DSLX (part of google's XLS SDK, see below), compiled to verilog, synthesized by librelane, and then PPA metrics are collected.

## Where to start

To reproduce the current baseline (DSLX reference, multi-architecture codegen, and one librelane sky130 PnR run with PPA metrics), follow [HOWTO.md](./HOWTO.md). Every tool invocation and config file is documented there.

`CLAUDE.md` is operational guidance for Claude Code sessions in this repo. `PLAN.md` is the study plan (parameter sweep, architecture strategy, milestones, gates).

## Known toolchain caveats

Two issues with the bundled XLS binaries (`external/xls-bin/`) that you will hit immediately if you don't know about them. Both are real and impact every workflow in this repo until the maintainer addresses them.

### 1. `xls-bin` and `external/xls/` are version-skewed — `import std;` is broken

The statically-compiled binaries in `external/xls-bin/` (currently from `gbsha/xls-bin` release `v1.0-xls-oracle8`) and the upstream source clone in `external/xls/` (currently at commit `45e1f8884`) are not from the same XLS revision. The binary's type checker rejects the source clone's stdlib (`xls/dslx/stdlib/std.x`) with `TypeInferenceError: uN[32][0] Zero-sized arrays cannot be indexed` in the `enumerate` function — meaning **any `import std;` will fail typechecking, regardless of whether you actually use anything from the imported module.**

Workaround until the two are pinned to a matching revision: don't import std. Where you'd use a stdlib helper (e.g. `std::clog2(N)` to derive a bit-width), supply the value as an explicit parametric at the call site instead. See `dslx/binner.x` for an example (`BW_BIN` is an explicit parametric where it would naturally default to `std::clog2(N_BOUNDS)`).

Suggested fix on the maintainer side: tag each `xls-bin` release with the exact XLS commit it was built from, and pin `external/xls/` to that commit (e.g. as a git submodule). Then the binary and the source/stdlib it parses are guaranteed compatible.

### 2. `xls-bin` is a curated subset of the XLS toolchain — several useful binaries are missing

`external/xls-bin/` currently ships `interpreter_main`, `ir_converter_main`, `opt_main`, `codegen_main`, `eval_ir_main`, `dslx_fmt`, `proto_to_dslx_main`. The upstream `xls/tools/` and `xls/dev_tools/` trees contain many more. The ones most likely to come up in this project:

| missing binary           | what it does                                        | when we'll need it       |
|--------------------------|-----------------------------------------------------|--------------------------|
| `simulate_module_main`   | RTL-level functional verification of generated Verilog | **M4** — verifying Verilog matches DSLX semantics |
| `eval_proc_main`         | Execute/test XLS procs                               | **M7** — TDM (proc-based) architecture variant |
| `benchmark_main`         | Inspect scheduling under a delay model               | M8 — characterising scheduler behaviour over sweeps |
| `pass_metrics_main`      | Visualise scheduler/codegen pass metrics             | M8 — debugging the sweep |
| `delay_info_main`        | Per-node delay info                                  | situational              |
| `check_ir_equivalence_main` | IR-transform regression checking                  | situational              |

If you hit a tool not in `external/xls-bin/`, flag it to the maintainer (the user maintains `github.com/gbsha/xls-bin` and can publish additional binaries on request) — **do not try to build XLS from source as a workaround.**

## Study objective

Consider the following python code:
```python
def fun(global_index: int, lower_bin_boundaries: list[int]) -> int:
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

The `google/xls` github repository is locally cloned to `external/xls`, for locally having access to the documentation and dslx language specification. Note that `external/xls` does **not** contain the binaries.

Install the binaries statically compiled from https://github.com/gbsha/xls-bin/ by
```
mkdir -p ./external/xls-bin && cd ./external/xls-bin

curl -L -O https://github.com/gbsha/xls-bin/releases/download/v1.0-xls-oracle8/xls-oracle8-binaries.tar.gz
tar -xzf xls-oracle8-binaries.tar.gz
chmod +x *
```
