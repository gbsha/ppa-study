#!/usr/bin/env bash
# run_sweep.sh — run a grid of PPA design points via run_point.sh, in parallel.
#
# Enumerates (arch × bw_global × n_bounds) for one delay model and dispatches
# each point through flows/run_point.sh. Because every point writes only to its
# own runs/<model>/<arch>/<params>/ dir and skips when already built, points run
# concurrently without colliding (re-run to resume; finished points are skipped).
#
# Two concurrency knobs share the machine's cores:
#   OUTER (--jobs)           how many points run at once
#   INNER (--librelane-jobs) threads each librelane run may use
# Aim for OUTER × INNER ≈ nproc. Defaults (4 × 4 = 16) suit a 16-core box; the
# librelane half multithreads unevenly (routing saturates, synth/STA don't), so
# this is deliberately conservative rather than OUTER=nproc.
#
# Dispatch uses GNU parallel when present (with --joblog for timing/resume),
# falling back to a dependency-free bash job pool (wait -n) otherwise. Both
# honour OUTER via -j and produce the same per-point logs and OK/FAIL statuses.
#
# Usage:
#   flows/run_sweep.sh [options]
#
# Options:
#   --arch "LIST"        space-separated arch tokens: parallel pipe_sN
#                                                  (default: "parallel pipe_s2 pipe_s4")
#   --bw-global "LIST"   space-separated bitwidths              (default: "8")
#   --n-bounds "LIST"    space-separated bin counts             (default: "2 4 8")
#   --delay-model NAME   sky130|asap7|unit                      (default: sky130)
#   --jobs N             OUTER: concurrent points               (default: 4)
#   --librelane-jobs N   INNER: threads per librelane run        (default: 4)
#   --skip-pnr           XLS-only (no librelane) — fast grid sanity check
#   --force              rebuild points even if cached
#   --dry-run            print the grid and the commands, run nothing
#   -h, --help           show this help
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_POINT="$ROOT/flows/run_point.sh"

# ---- defaults (grid is easy to edit / override) ------------------------------
ARCHS="parallel pipe_s2 pipe_s4"
BWS="8"
NBS="2 4 8"
DELAY_MODEL="sky130"
OUTER=4
INNER=4
SKIP_PNR=0; FORCE=0; DRY=0

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)           ARCHS="$2"; shift 2 ;;
    --bw-global)      BWS="$2"; shift 2 ;;
    --n-bounds)       NBS="$2"; shift 2 ;;
    --delay-model)    DELAY_MODEL="$2"; shift 2 ;;
    --jobs)           OUTER="$2"; shift 2 ;;
    --librelane-jobs) INNER="$2"; shift 2 ;;
    --skip-pnr)       SKIP_PNR=1; shift ;;
    --force)          FORCE=1; shift ;;
    --dry-run)        DRY=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "run_sweep.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -x "$RUN_POINT" ]] || { echo "run_sweep.sh: $RUN_POINT not executable" >&2; exit 1; }

# ---- translate an arch token into run_point.sh flags -------------------------
# "parallel" -> --arch parallel ; "pipe_sN" -> --arch pipeline --stages N
arch_flags() {
  case "$1" in
    parallel)  echo "--arch parallel" ;;
    pipe_s[1-9]*) echo "--arch pipeline --stages ${1#pipe_s}" ;;
    *) echo "run_sweep.sh: bad arch token '$1' (use parallel or pipe_sN)" >&2; return 1 ;;
  esac
}

# ---- build the point list ----------------------------------------------------
declare -a TAGS POINT_ARGS
for arch in $ARCHS; do
  af="$(arch_flags "$arch")"
  for bw in $BWS; do
    for nb in $NBS; do
      common="--delay-model $DELAY_MODEL --bw-global $bw --n-bounds $nb $af --librelane-jobs $INNER"
      [[ $SKIP_PNR -eq 1 ]] && common="$common --skip-pnr"
      [[ $FORCE   -eq 1 ]] && common="$common --force"
      TAGS+=("${arch}_bw${bw}_nb${nb}")
      POINT_ARGS+=("$common")
    done
  done
done

echo "Sweep: ${#TAGS[@]} points  | model=$DELAY_MODEL  archs=[$ARCHS]  bw=[$BWS]  nb=[$NBS]"
echo "Concurrency: OUTER=$OUTER points × INNER=$INNER librelane threads  (nproc=$(nproc))"

if [[ $DRY -eq 1 ]]; then
  for i in "${!TAGS[@]}"; do printf '  %-22s %s %s\n' "${TAGS[$i]}" "$RUN_POINT" "${POINT_ARGS[$i]}"; done
  echo "(dry run — nothing executed)"; exit 0
fi

# ---- assemble self-contained commands (each logs + records OK/FAIL) ----------
# Building the redirect + status into the command string keeps both dispatchers
# trivial and makes the summary read the same .status files either way.
SWEEP_LOG="$ROOT/runs/_sweeps/$(date -u +%Y-%m-%d_%H-%M-%S)"
mkdir -p "$SWEEP_LOG"
echo "Per-point logs: $SWEEP_LOG"

declare -a CMDS
for i in "${!TAGS[@]}"; do
  tag="${TAGS[$i]}"; log="$SWEEP_LOG/$tag.log"; st="$SWEEP_LOG/$tag.status"
  CMDS+=("if $RUN_POINT ${POINT_ARGS[$i]} > $log 2>&1; then echo OK > $st; else echo FAIL > $st; fi")
done

# ---- dispatch: GNU parallel if available, else a bounded bash job pool -------
set +e   # a failed point must not abort the sweep; we tally statuses below
if command -v parallel >/dev/null; then
  echo "Dispatcher: GNU parallel (-j $OUTER, --joblog)"
  printf '%s\n' "${CMDS[@]}" | parallel -j "$OUTER" --halt never --joblog "$SWEEP_LOG/joblog.tsv"
else
  echo "Dispatcher: bash job pool (-j $OUTER; GNU parallel not found)"
  running=0
  for cmd in "${CMDS[@]}"; do
    bash -c "$cmd" &
    if (( ++running >= OUTER )); then wait -n; (( running-- )); fi
  done
  wait
fi
set -e

# ---- summary -----------------------------------------------------------------
echo; echo "=== sweep summary ==="
fails=0
for tag in "${TAGS[@]}"; do
  st="$(cat "$SWEEP_LOG/$tag.status" 2>/dev/null || echo '??')"
  printf '  %-6s %s\n' "$st" "$tag"
  [[ "$st" == OK ]] || (( ++fails ))
done
echo "${#TAGS[@]} points, $fails not-OK. Metrics: runs/$DELAY_MODEL/<arch>/<params>/metrics.json"
[[ $fails -eq 0 ]]
