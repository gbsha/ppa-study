---
format: pdf
---

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This is a PPA (Power, Performance, Area) study. The hardware-under-study is the binning function described in `README.md`: given a `global_index` and a programmable `lower_bin_boundaries` list, return `(bin_index, local_index)`. The objective is to characterize how PPA scales with build-time parameters and microarchitecture.

For the **what** and **why** of the study, read `README.md` (problem statement, two-entry-paths panel, doc orientation table) and `PLAN.md` (methodology, parameter sweep, architecture strategy, optional extensions). Update `PLAN.md` as the methodology evolves — don't let CLAUDE.md drift into being a plan.

Current state (snapshot — for the authoritative version see `PLAN.md`): M1–M3, M6, M8 are done (DSLX reference, codegen, librelane sky130 PnR, sweep runner, Pareto plots). M4a (cocotb RTL functional verification) is done — see `COCOTB.md`. The THERMOMETER Sketch B (`binner_prio`, priority-encoder variant exploiting monotonicity) is implemented alongside the fold reference (`binner`) and verified both formally (`prove_quickcheck_main`) and at the RTL (cocotb). Optional next steps (M4b post-PnR sim, M5 refined form, M7 TDM proc, asap7 physical PnR) are explicitly framed as such in PLAN.md — not blockers.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/): `<type>(<optional scope>): <summary>`. Types in use here: `feat`, `fix`, `docs`, `refactor`, `chore`; scope is the top-level area when useful (e.g. `dslx`, `flows`). Keep the summary imperative and lower-case — e.g. `refactor(dslx): default BW_BIN to std::clog2(N_BOUNDS)`.

## Toolchain — two entry paths

The flow splits into a librelane-free half (DSLX + codegen + cocotb verif) and a librelane half (PnR + signoff). README.md's "Two entry paths" panel is the user-facing version; the operational rules:

- **Path A — conda env only.** `mamba activate ppa-study` (or `mamba run -n ppa-study …`). Provides cocotb, iverilog, verilator, matplotlib, graphviz from conda-forge. Sufficient for DSLX work, codegen (`flows/run_point.sh --skip-pnr`), and RTL functional verification (`flows/run_verif.sh`). No librelane needed.
- **Path B — Path A plus librelane nix-shell.** `cd $LIBRELANE && nix-shell`, then `mamba activate ppa-study` layers on top (conda activation only prepends to PATH; the nix-shell binaries stay reachable). Adds the full PnR + signoff chain — required by `flows/run_point.sh` (without `--skip-pnr`) and `flows/run_sweep.sh`.

`flows/run_point.sh` only requires librelane when running PnR; the `--skip-pnr` codegen path runs cleanly under Path A.

Verify Path B with `which librelane openroad yosys` — all three should resolve to `/nix/store/...` paths. If they don't and the user is trying to PnR, stop and tell them; do not try to install librelane.

## XLS binaries and docs

Google XLS is split across two locations in this repo, both under `external/` and both gitignored:

- `external/xls-bin/` — the cloned `gbsha/xls-bin` repo. The binaries live in `external/xls-bin/bin/` (not at the top level — invoke them as `./external/xls-bin/bin/codegen_main`); they are *not* on `$PATH` (check with `command -v codegen_main` and fall back to the explicit `bin/` path). The full list of 18 shipped binaries and the three deliberate omissions (`simulate_module_main` — covered by cocotb/M4a; `gather_design_stats`; `jit_wrapper_generator_main`) are documented in `README.md` "Toolchain status" — single source of truth, don't restate here. The repo also carries three markdowns worth reading: `README.md` (Docker cross-build recipe + authoritative release/tarball naming), `XLS_SUMMARY.md` (per-binary "what & why"), and `CLAUDE.md` (context for *their* build project, not ours).

  **`xls-bin` and `external/xls/` are pinned to the same XLS revision** (tag `v0.0.0-10042-g81ff4fdf7`, commit `81ff4fdf7`; the binary bundle is release tag `xls-81ff4fdf7-xlsbin-1`), so the binaries and the stdlib they parse are compatible — `import std;` works (see below). If a still-missing tool would meaningfully help, **stop and tell the user** — they maintain `github.com/gbsha/xls-bin` and can publish more. Do **not** `bazel build` or install XLS from source as a workaround.
- `external/xls/` — a clone of the upstream `google/xls` repo, kept **only for documentation and the DSLX language/stdlib reference**. It contains no binaries. Key reading paths:
  - `external/xls/docs_src/dslx_reference.md`, `dslx_std.md`, `dslx_type_system.md` — DSLX language
  - `external/xls/docs_src/codegen_options.md`, `scheduling.md`, `delay_estimation.md` — codegen & scheduler flags relevant to the PPA sweep
  - `external/xls/docs_src/tutorials/` — including `intro_to_parametrics.md`, `how_to_use_procs.md`, `what_is_a_proc.md`, `dataflow_and_time.md`
  - `external/xls/xls/examples/` — runnable DSLX examples (e.g. `constraint.x` for `--io_constraints` usage)

When unsure about DSLX syntax, codegen flags, or what a particular scheduler knob does, consult `external/xls/` rather than guessing — that's why it's checked out locally.

### `import std;` works; always pass `--dslx_stdlib_path`

Since `xls-bin` and `external/xls` are now on the same revision, `import std;` typechecks and runs cleanly (verified 2026-05-25). `dslx/binner.x` relies on this — `BW_BIN` defaults to `std::clog2(N_BOUNDS)`. The earlier skew that broke every stdlib import (`TypeInferenceError: ... Zero-sized arrays cannot be indexed` in `enumerate`) is resolved; no inline-helper workaround is needed.

When invoking the binaries directly, pass `--dslx_stdlib_path=external/xls/xls/dslx/stdlib` — the default path the binaries look for doesn't exist here, and `import std;` now needs it to resolve.
