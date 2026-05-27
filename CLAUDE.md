---
format: pdf
---

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This is a PPA (Power, Performance, Area) study. The hardware-under-study is the binning function described in `README.md`: given a `global_index` and a programmable `upper_bin_boundaries` list, return `(bin_index, local_index)`. The objective is to characterize how PPA scales with build-time parameters and microarchitecture.

For the **what** and **why** of the study, read `README.md` (problem statement and constraints) and `PLAN.md` (methodology, parameter sweep, architecture strategy, known XLS limits). Update `PLAN.md` as the methodology evolves — don't let CLAUDE.md drift into being a plan.

The M1–M3 vertical slice is in place: `dslx/binner.x` (parametric reference + tests), `dslx/binner_top_8x4.x` (concrete top), `flows/librelane/binner_8x4/config.json` (librelane config), and `flows/extract_metrics.py` (PPA extractor). `HOWTO.md` reproduces the sky130 baseline end-to-end. The active work (per `PLAN.md`) is the sweep runner and first Pareto-frontier plot; the refined/TDM architectures and asap7 come later.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/): `<type>(<optional scope>): <summary>`. Types in use here: `feat`, `fix`, `docs`, `refactor`, `chore`; scope is the top-level area when useful (e.g. `dslx`, `flows`). Keep the summary imperative and lower-case — e.g. `refactor(dslx): default BW_BIN to std::clog2(N_BOUNDS)`.

## Toolchain — entered via librelane's nix-shell

Librelane, OpenROAD, and Yosys are provided by the librelane nix-shell, not installed in this repo. The expected workflow is:

```
cd /PATH/TO/YOUR/LIBRELANE && nix-shell
cd /PATH/TO/THIS_REPOSITORY && claude
```

Verify with `which librelane openroad yosys` — all three should resolve to `/nix/store/...` paths. If they don't, stop and tell the user; do not try to install them.

## XLS binaries and docs

Google XLS is split across two locations in this repo, both under `external/` and both gitignored:

- `external/xls-bin/` — the cloned `gbsha/xls-bin` repo. The binaries live in `external/xls-bin/bin/` (not at the top level — invoke them as `./external/xls-bin/bin/codegen_main`); they are *not* on `$PATH` (check with `command -v codegen_main` and fall back to the explicit `bin/` path). The release ships **18 statically-linked C++ binaries**: `interpreter_main`, `ir_converter_main`, `opt_main`, `codegen_main`, `eval_ir_main`, `eval_proc_main`, `delay_info_main`, `lec_main` (formal logic-equivalence), `prove_quickcheck_main`, `aot_compiler_main`, `dslx_fmt`, `dslx_ls`, `parse_and_typecheck_dslx_main`, `proto_to_dslx_main`, `type_layout_main`, `print_bom`, `benchmark_main`, `pass_metrics_main`. The repo also carries three markdowns worth reading: `README.md` (the Docker cross-build recipe + authoritative release/tarball naming), `XLS_SUMMARY.md` (per-binary "what & why"), and `CLAUDE.md` (context for *their* build project, not ours).

  **`xls-bin` and `external/xls/` are pinned to the same XLS revision** (tag `v0.0.0-10042-g81ff4fdf7`, commit `81ff4fdf7`; the binary bundle is release tag `xls-81ff4fdf7-xlsbin-1`), so the binaries and the stdlib they parse are compatible — `import std;` works (see below). Three tools are deliberately **not** in the release: `simulate_module_main` (RTL functional sim — can't be linked statically; replaced by an external simulator, cocotb + iverilog/verilator, so don't wait on it), and the two Python tools `gather_design_stats` (Yosys/OpenSTA log → metrics proto; run from a source checkout on the synth machine — see xls-bin `README.md` Appendix) and `jit_wrapper_generator_main` (build-time helper, unused here). If a still-missing tool would meaningfully help, **stop and tell the user** — they maintain `github.com/gbsha/xls-bin` and can publish more. Do **not** `bazel build` or install XLS from source as a workaround.
- `external/xls/` — a clone of the upstream `google/xls` repo, kept **only for documentation and the DSLX language/stdlib reference**. It contains no binaries. Key reading paths:
  - `external/xls/docs_src/dslx_reference.md`, `dslx_std.md`, `dslx_type_system.md` — DSLX language
  - `external/xls/docs_src/codegen_options.md`, `scheduling.md`, `delay_estimation.md` — codegen & scheduler flags relevant to the PPA sweep
  - `external/xls/docs_src/tutorials/` — including `intro_to_parametrics.md`, `how_to_use_procs.md`, `what_is_a_proc.md`, `dataflow_and_time.md`
  - `external/xls/xls/examples/` — runnable DSLX examples (e.g. `constraint.x` for `--io_constraints` usage)

When unsure about DSLX syntax, codegen flags, or what a particular scheduler knob does, consult `external/xls/` rather than guessing — that's why it's checked out locally.

### `import std;` works; always pass `--dslx_stdlib_path`

Since `xls-bin` and `external/xls` are now on the same revision, `import std;` typechecks and runs cleanly (verified 2026-05-25). `dslx/binner.x` relies on this — `BW_BIN` defaults to `std::clog2(N_BOUNDS)`. The earlier skew that broke every stdlib import (`TypeInferenceError: ... Zero-sized arrays cannot be indexed` in `enumerate`) is resolved; no inline-helper workaround is needed.

When invoking the binaries directly, pass `--dslx_stdlib_path=external/xls/xls/dslx/stdlib` — the default path the binaries look for doesn't exist here, and `import std;` now needs it to resolve.
