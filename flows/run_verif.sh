#!/usr/bin/env bash
# run_verif.sh — cocotb-verify every binner.v under the current grid.
#
# Enumerates (variant × arch × bw_global × n_bounds), looks up
# runs/<model>/<arch_tag>/bw${BW}_nb${NB}/binner.v, and invokes verif/runner.py
# against each. Skips points whose binner.v doesn't exist (run --skip-pnr or
# the full sweep first to produce them).
#
# Self-contained on the XLS+cocotb side: no librelane / nix-shell dependency.
# Both iverilog and cocotb come from the ppa-study conda env. See COCOTB.md.
#
# Usage:
#   flows/run_verif.sh [options]
#
# Options:
#   --arch "LIST"        space-separated arch tokens: parallel pipe_sN
#                                                  (default: "parallel")
#   --variants "LIST"    space-separated DSLX variants: ref prio (default: "ref")
#   --bw-global "LIST"   space-separated bitwidths           (default: "4 8 12 16")
#   --n-bounds "LIST"    space-separated bin counts          (default: "2 4 8 16")
#   --delay-model NAME   PDK dir to look under              (default: sky130)
#   --simulator NAME     icarus|verilator                    (default: icarus)
#   --num-bound-sets N   random bound configurations / point (default: 256)
#   --trials-per-set N   global_index trials per bound set   (default: 16)
#   --seed N             RNG seed (deterministic)            (default: 0)
#   --jobs N             OUTER: concurrent points            (default: 4)
#   --dry-run            print the grid and the commands, run nothing
#   -h, --help           show this help
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
RUNNER="$ROOT/verif/runner.py"

# ---- defaults ----------------------------------------------------------------
ARCHS="parallel"
VARIANTS="ref"
BWS="4 8 12 16"
NBS="2 4 8 16"
DELAY_MODEL="sky130"
SIM="icarus"
SETS=256
TRIALS=16
SEED=0
OUTER=4
DRY=0

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)             ARCHS="$2"; shift 2 ;;
    --variants)         VARIANTS="$2"; shift 2 ;;
    --bw-global)        BWS="$2"; shift 2 ;;
    --n-bounds)         NBS="$2"; shift 2 ;;
    --delay-model)      DELAY_MODEL="$2"; shift 2 ;;
    --simulator)        SIM="$2"; shift 2 ;;
    --num-bound-sets)   SETS="$2"; shift 2 ;;
    --trials-per-set)   TRIALS="$2"; shift 2 ;;
    --seed)             SEED="$2"; shift 2 ;;
    --jobs)             OUTER="$2"; shift 2 ;;
    --dry-run)          DRY=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "run_verif.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -x "$RUNNER" ]] || { echo "run_verif.sh: $RUNNER not executable" >&2; exit 1; }

# Cocotb / iverilog live in the ppa-study conda env. We don't activate it here;
# we invoke `mamba run -n ppa-study python …` per point so this script can be
# launched from any shell. If mamba isn't on PATH, complain early.
command -v mamba >/dev/null || command -v conda >/dev/null || {
  echo "run_verif.sh: neither 'mamba' nor 'conda' on PATH — install miniforge first" >&2; exit 1; }
RUN_IN_ENV=(mamba run -n ppa-study python)

# arch_tag: 'parallel' stays bare; non-ref variants get '_<variant>' suffix.
# (Mirrors run_point.sh's resolution so dirs line up.)
arch_tag() {
  local arch="$1" variant="$2" t
  case "$arch" in
    parallel)     t="parallel" ;;
    pipe_s[1-9]*) t="$arch" ;;
    *) echo "run_verif.sh: bad arch token '$arch' (use parallel or pipe_sN)" >&2; return 1 ;;
  esac
  [[ "$variant" != "ref" ]] && t="${t}_${variant}"
  echo "$t"
}

# ---- build the point list ----------------------------------------------------
declare -a TAGS VERILOGS
for variant in $VARIANTS; do
  for arch in $ARCHS; do
    at="$(arch_tag "$arch" "$variant")"
    for bw in $BWS; do
      for nb in $NBS; do
        v="$ROOT/runs/$DELAY_MODEL/$at/bw${bw}_nb${nb}/binner.v"
        TAGS+=("${at}_bw${bw}_nb${nb}")
        VERILOGS+=("$v")
      done
    done
  done
done

echo "Verif: ${#TAGS[@]} points | model=$DELAY_MODEL archs=[$ARCHS] variants=[$VARIANTS]"
echo "       bw=[$BWS] nb=[$NBS] sim=$SIM sets=$SETS trials/set=$TRIALS seed=$SEED"
echo "Concurrency: OUTER=$OUTER  (iverilog is single-thread per run)"

if [[ $DRY -eq 1 ]]; then
  for i in "${!TAGS[@]}"; do
    printf '  %-32s %s\n' "${TAGS[$i]}" "${VERILOGS[$i]}"
  done
  echo "(dry run — nothing executed)"; exit 0
fi

# ---- log dir + per-point commands -------------------------------------------
VERIF_LOG="$ROOT/runs/_verif/$(date -u +%Y-%m-%d_%H-%M-%S)"
mkdir -p "$VERIF_LOG"
echo "Per-point logs: $VERIF_LOG"

declare -a CMDS
for i in "${!TAGS[@]}"; do
  tag="${TAGS[$i]}"; v="${VERILOGS[$i]}"
  log="$VERIF_LOG/$tag.log"; st="$VERIF_LOG/$tag.status"
  if [[ ! -f "$v" ]]; then
    # Record the skip and continue — don't fail the whole sweep.
    echo "MISSING ($v)" > "$st"
    continue
  fi
  build="$VERIF_LOG/build/$tag"
  cmd=("${RUN_IN_ENV[@]}" "$RUNNER" --verilog "$v" --simulator "$SIM" \
       --num-bound-sets "$SETS" --trials-per-set "$TRIALS" --seed "$SEED" \
       --build-dir "$build")
  CMDS+=("if ${cmd[*]} > $log 2>&1; then echo OK > $st; else echo FAIL > $st; fi")
done

# ---- dispatch: GNU parallel if available, else bash pool --------------------
set +e
if [[ ${#CMDS[@]} -gt 0 ]]; then
  if command -v parallel >/dev/null; then
    printf '%s\n' "${CMDS[@]}" | parallel -j "$OUTER" --halt never --joblog "$VERIF_LOG/joblog.tsv"
  else
    running=0
    for cmd in "${CMDS[@]}"; do
      bash -c "$cmd" &
      if (( ++running >= OUTER )); then wait -n; (( running-- )); fi
    done
    wait
  fi
fi
set -e

# ---- summary ----------------------------------------------------------------
# OK = pass, FAIL = cocotb failure, MISSING = no binner.v (run codegen first).
# Only FAIL gates the exit status; MISSING is a soft skip.
echo; echo "=== verif summary ==="
fails=0; missing=0
for tag in "${TAGS[@]}"; do
  st="$(cat "$VERIF_LOG/$tag.status" 2>/dev/null || echo '??')"
  printf '  %-12s %s\n' "${st%% *}" "$tag"
  case "$st" in
    OK)        ;;
    MISSING*)  (( ++missing )) ;;
    *)         (( ++fails )) ;;
  esac
done
echo "${#TAGS[@]} points, $fails FAIL, $missing MISSING (codegen first). Logs: $VERIF_LOG/"
[[ $fails -eq 0 ]]
