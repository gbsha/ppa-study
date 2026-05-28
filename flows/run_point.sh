#!/usr/bin/env bash
# run_point.sh — build and measure ONE PPA design point, end to end.
#
# Thin wrapper that chains:
#   run_point_xls.sh  (DSLX -> IR -> Verilog;     needs XLS binaries)
#   run_point_pnr.sh  (librelane + PPA summary;   needs librelane)
#
# Use this on a single machine that has both halves. For the distributed
# (two-machine) workflow, invoke the two halves directly on their machines —
# see HOWTO §8.
#
# Each point writes ONLY to its own runs/<model>/<arch>/<params>/ directory and
# skips if its result already exists, so a sweep wrapper can fan many points out
# in parallel (e.g. GNU parallel) safely. See PLAN.md M6.
#
# Usage:
#   flows/run_point.sh --bw-global 8 --n-bounds 4 [options]
#
# Options:
#   --bw-global N        bitwidth of global_index / each threshold      (required)
#   --n-bounds N         number of boundary entries (bins)              (required)
#   --arch parallel|pipeline   architecture family            (default: parallel)
#   --variant ref|prio   binner source variant                 (default: ref)
#                        ref  = binner::binner (fold reference); prio = binner::binner_prio
#                        (Sketch B from THERMOMETER.md, ctz(!cmps) priority encoder)
#   --stages N           pipeline stages; forced to 1 for 'parallel'  (default: 4 for pipeline)
#   --codegen-clock-ps N|auto  XLS scheduling clock; 'auto' probes the minimum
#                        feasible clock for the stage count   (default: auto)
#   --librelane-clock-ns N     PnR (STA) target clock period         (default: 10)
#   --librelane-jobs N   cap librelane's internal threads (its -j)  (default: librelane's own)
#   --delay-model NAME   XLS delay model: sky130|asap7|unit          (default: sky130)
#   --skip-pnr           stop after codegen (run only run_point_xls.sh)
#   --force              rebuild even if a cached result is present
#   -h, --help           show this help
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XLS_SCRIPT="$ROOT/flows/run_point_xls.sh"
PNR_SCRIPT="$ROOT/flows/run_point_pnr.sh"

# ---- defaults / arg parsing --------------------------------------------------
# We re-parse here only to (a) route flags to the right child script and
# (b) honour --skip-pnr without invoking PnR. Unknown flags are an error here,
# matching the children's behaviour.
BW=""; NB=""; ARCH="parallel"; VARIANT="ref"; STAGES=""; CODEGEN_CLK=""
LL_CLK_NS="10"; LL_JOBS=""; DELAY_MODEL="sky130"; SKIP_PNR=0; FORCE=0

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bw-global)         BW="$2"; shift 2 ;;
    --n-bounds)          NB="$2"; shift 2 ;;
    --arch)              ARCH="$2"; shift 2 ;;
    --variant)           VARIANT="$2"; shift 2 ;;
    --stages)            STAGES="$2"; shift 2 ;;
    --codegen-clock-ps)  CODEGEN_CLK="$2"; shift 2 ;;
    --librelane-clock-ns) LL_CLK_NS="$2"; shift 2 ;;
    --librelane-jobs)    LL_JOBS="$2"; shift 2 ;;
    --delay-model)       DELAY_MODEL="$2"; shift 2 ;;
    --skip-pnr)          SKIP_PNR=1; shift ;;
    --force)             FORCE=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "run_point.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

# ---- assemble the flag set shared by both halves -----------------------------
COMMON_ARGS=(--bw-global "$BW" --n-bounds "$NB" --arch "$ARCH" --variant "$VARIANT"
             --delay-model "$DELAY_MODEL" --librelane-clock-ns "$LL_CLK_NS")
[[ -n "$STAGES" ]] && COMMON_ARGS+=(--stages "$STAGES")
[[ $FORCE -eq 1 ]] && COMMON_ARGS+=(--force)

# ---- 1. XLS half (codegen) ---------------------------------------------------
XLS_ARGS=("${COMMON_ARGS[@]}")
[[ -n "$CODEGEN_CLK" ]] && XLS_ARGS+=(--codegen-clock-ps "$CODEGEN_CLK")
"$XLS_SCRIPT" "${XLS_ARGS[@]}"

# ---- 2. PnR half (librelane) — unless --skip-pnr -----------------------------
if [[ $SKIP_PNR -eq 1 ]]; then
  exit 0
fi
PNR_ARGS=("${COMMON_ARGS[@]}")
[[ -n "$LL_JOBS" ]] && PNR_ARGS+=(--librelane-jobs "$LL_JOBS")
"$PNR_SCRIPT" "${PNR_ARGS[@]}"
