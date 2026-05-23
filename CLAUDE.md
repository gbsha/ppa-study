# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This is a PPA (Power, Performance, Area) study. The hardware-under-study is the binning function described in `README.md`: given a `global_index` and a programmable `upper_bin_boundaries` list, return `(bin_index, local_index)`. The study sweeps three build-time parameters — `bw_global_index`, `n_boundaries`, `bw_threshold` — across three microarchitectures (TDM, pipelined, fully-parallel/thermometer) and compares the resulting PPA numbers from synthesis.

Read `README.md` before adding any implementation; the constraints section there is the source of truth (notably: `upper_bin_boundaries` entries are runtime-programmable, inactive entries use a sentinel, and the refinement constrains thresholds to `mantissa << shared_exponent` form).

The repo is at initial-commit stage — there is no source code, no test harness, and no synthesis flow yet. Expect to create that structure as work proceeds.

## Toolchain — must be entered via nix-shell

Librelane, OpenROAD, and Yosys are provided by the librelane nix-shell, not installed in this repo. The expected workflow is:

```
cd /PATH/TO/YOUR/LIBRELANE && nix-shell
cd /PATH/TO/THIS_REPOSITORY && claude
```

Verify you are inside the shell with `which librelane openroad yosys` — all three should resolve to `/nix/store/...` paths. If they don't, stop and tell the user; do not try to install them.

## XLS binaries and docs

Google XLS is split across two locations in this repo, both under `external/` and both gitignored:

- `external/xls-bin/` — statically-compiled binaries used to drive the DSLX → IR → Verilog flow: `interpreter_main`, `ir_converter_main`, `opt_main`, `codegen_main`, `eval_ir_main`, `dslx_fmt`, `proto_to_dslx_main`. Invoke these directly (e.g. `./external/xls-bin/codegen_main --help`); they are not on `$PATH`.
- `external/xls/` — a clone of the upstream `google/xls` repo, kept **only for documentation and the DSLX language/stdlib reference**. It contains no binaries. Key reading paths: `external/xls/docs_src/dslx_reference.md`, `dslx_std.md`, `codegen_options.md`, `tutorials/`.

When unsure about DSLX syntax, semantics, or codegen flags, consult `external/xls/docs_src/` rather than guessing — that mirror is the reason it's checked out locally.

## Expected end-to-end flow

DSLX source → `ir_converter_main` → unoptimized IR → `opt_main` → optimized IR → `codegen_main` → Verilog → librelane (Yosys synth + OpenROAD PnR) → PPA metrics. The three microarchitectures (TDM, pipelined, parallel) will differ in their DSLX and in the `codegen_main` flags (combinational vs. pipeline generator, pipeline stages, etc.). When adding a new variant, keep build-time parameters (`bw_global_index`, `n_boundaries`, `bw_threshold`) parameterized in DSLX rather than hardcoded, so a single source can drive the sweep.
