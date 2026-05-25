---
format: pdf
---

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This is a PPA (Power, Performance, Area) study. The hardware-under-study is the binning function described in `README.md`: given a `global_index` and a programmable `upper_bin_boundaries` list, return `(bin_index, local_index)`. The objective is to characterize how PPA scales with build-time parameters and microarchitecture.

For the **what** and **why** of the study, read `README.md` (problem statement and constraints) and `PLAN.md` (methodology, parameter sweep, architecture strategy, known XLS limits). Update `PLAN.md` as the methodology evolves — don't let CLAUDE.md drift into being a plan.

The repo is at initial-commit stage — no source, no test harness, no synthesis flow yet. Expect to create that structure as work proceeds.

## Toolchain — entered via librelane's nix-shell

Librelane, OpenROAD, and Yosys are provided by the librelane nix-shell, not installed in this repo. The expected workflow is:

```
cd /PATH/TO/YOUR/LIBRELANE && nix-shell
cd /PATH/TO/THIS_REPOSITORY && claude
```

Verify with `which librelane openroad yosys` — all three should resolve to `/nix/store/...` paths. If they don't, stop and tell the user; do not try to install them.

## XLS binaries and docs

Google XLS is split across two locations in this repo, both under `external/` and both gitignored:

- `external/xls-bin/` — statically-compiled binaries used to drive the DSLX → IR → Verilog flow: `interpreter_main`, `ir_converter_main`, `opt_main`, `codegen_main`, `eval_ir_main`, `dslx_fmt`, `proto_to_dslx_main`. Whether they're on `$PATH` is a downstream decision (e.g. via an install script) — don't assume either way; check with `command -v codegen_main` and fall back to the explicit `./external/xls-bin/...` path if needed.

  **This is a curated subset, not the full XLS tool set.** Upstream `xls/tools/` and `xls/dev_tools/` contain many more binaries (e.g. `simulate_module_main` for RTL simulation, `eval_proc_main` for procs, `benchmark_main` and `pass_metrics_main` for inspecting the scheduler, `delay_info_main`, `check_ir_equivalence_main`, …). If a missing tool would meaningfully help the task, **stop and tell the user** — they maintain `github.com/gbsha/xls-bin` and can publish additional binaries. Do **not** attempt to `bazel build` from source or install XLS from source as a workaround.
- `external/xls/` — a clone of the upstream `google/xls` repo, kept **only for documentation and the DSLX language/stdlib reference**. It contains no binaries. Key reading paths:
  - `external/xls/docs_src/dslx_reference.md`, `dslx_std.md`, `dslx_type_system.md` — DSLX language
  - `external/xls/docs_src/codegen_options.md`, `scheduling.md`, `delay_estimation.md` — codegen & scheduler flags relevant to the PPA sweep
  - `external/xls/docs_src/tutorials/` — including `intro_to_parametrics.md`, `how_to_use_procs.md`, `what_is_a_proc.md`, `dataflow_and_time.md`
  - `external/xls/xls/examples/` — runnable DSLX examples (e.g. `constraint.x` for `--io_constraints` usage)

When unsure about DSLX syntax, codegen flags, or what a particular scheduler knob does, consult `external/xls/` rather than guessing — that's why it's checked out locally.

### Known toolchain skew: avoid `import std;` for now

The `external/xls-bin/` binaries and the `external/xls/` source clone are from different XLS revisions, and the binary's typechecker rejects the current stdlib's `enumerate` function (`TypeInferenceError: uN[32][0] Zero-sized arrays cannot be indexed`) — meaning **any `import std;` will fail typecheck regardless of whether you actually use the imported items**. Verified 2026-05-23. Workaround: inline the few helpers needed (e.g. supply `BW_BIN` / `clog2(N)` as an explicit parametric at call sites rather than as a default expression). When `xls-bin` is regenerated to match `external/xls` (or vice versa), revisit and restore the stdlib import for cleaner code.

When invoking the binaries directly, pass `--dslx_stdlib_path=external/xls/xls/dslx/stdlib` — the default path the binaries look for doesn't exist here. (Even though we don't `import std;`, some tools still want the path; it's the easier flag to always pass.)
