#!/usr/bin/env bash
# run_point_pnr.sh — PnR half of one PPA design point: librelane + extract_metrics.
#
# Consumes the binner.v + point.json that run_point_xls.sh produced and runs
# librelane Classic on it, then extracts the PPA summary. Requires librelane
# on PATH (nix-shell) and the conda env for extract_metrics.py — though
# extract_metrics is stdlib-only so any python3 works.
#
# **No XLS binaries required.** This is the machine-B half of the distributed
# workflow (HOWTO §8). If binner.v is missing, this script tells you exactly
# how to produce it (run XLS half locally) or pull it (mailbox sync).
#
# Usage:
#   flows/run_point_pnr.sh --bw-global 8 --n-bounds 4 [options]
#
# Options:
#   --bw-global N        bitwidth of global_index / each threshold      (required)
#   --n-bounds N         number of boundary entries (bins)              (required)
#   --arch parallel|pipeline   architecture family            (default: parallel)
#   --variant ref|prio   binner source variant                 (default: ref)
#   --stages N           pipeline stages; forced to 1 for 'parallel'  (default: 4 for pipeline)
#   --librelane-clock-ns N     PnR (STA) target clock period         (default: 10)
#   --librelane-jobs N   cap librelane's internal threads (its -j)  (default: librelane's own)
#   --delay-model NAME   PDK / delay-model dir to look under          (default: sky130)
#   --force              rebuild even if metrics.json is already present
#   -h, --help           show this help
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ---- defaults ----------------------------------------------------------------
BW=""; NB=""; ARCH="parallel"; VARIANT="ref"; STAGES=""
LL_CLK_NS="10"; LL_JOBS=""; DELAY_MODEL="sky130"; FORCE=0

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bw-global)         BW="$2"; shift 2 ;;
    --n-bounds)          NB="$2"; shift 2 ;;
    --arch)              ARCH="$2"; shift 2 ;;
    --variant)           VARIANT="$2"; shift 2 ;;
    --stages)            STAGES="$2"; shift 2 ;;
    --librelane-clock-ns) LL_CLK_NS="$2"; shift 2 ;;
    --librelane-jobs)    LL_JOBS="$2"; shift 2 ;;
    --delay-model)       DELAY_MODEL="$2"; shift 2 ;;
    --force)             FORCE=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "run_point_pnr.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

die() { echo "run_point_pnr.sh: $*" >&2; exit 1; }
[[ -n "$BW" && -n "$NB" ]] || die "--bw-global and --n-bounds are required (see --help)"

# ---- resolve arch / variant -> directory tag (same logic as XLS half) -------
case "$ARCH" in
  parallel) STAGES=1; ARCH_TAG="parallel" ;;
  pipeline) STAGES="${STAGES:-4}"; ARCH_TAG="pipe_s${STAGES}" ;;
  *) die "--arch must be 'parallel' or 'pipeline' (got '$ARCH')" ;;
esac
case "$VARIANT" in
  ref)  ;;
  prio) ARCH_TAG="${ARCH_TAG}_${VARIANT}" ;;
  *) die "--variant must be 'ref' or 'prio' (got '$VARIANT')" ;;
esac

POINT_DIR="$ROOT/runs/$DELAY_MODEL/$ARCH_TAG/bw${BW}_nb${NB}"
VERILOG="$POINT_DIR/binner.v"; CONFIG="$POINT_DIR/config.json"

# ---- idempotency: skip if metrics.json already exists ------------------------
if [[ -f "$POINT_DIR/metrics.json" && $FORCE -eq 0 ]]; then
  echo "[skip] $POINT_DIR (metrics.json present; pass --force to rebuild)"; exit 0
fi

# ---- preflight: the XLS half must have run (or the mailbox been pulled) ------
if [[ ! -f "$VERILOG" ]]; then
  cat >&2 <<EOF
run_point_pnr.sh: missing $VERILOG

Run the XLS half first (locally if this machine has the XLS binaries):
  flows/run_point_xls.sh --bw-global $BW --n-bounds $NB \\
      --arch $ARCH --variant $VARIANT $([ -n "$STAGES" ] && echo "--stages $STAGES ")--delay-model $DELAY_MODEL

Or pull the codegen artifacts from a mounted XLS-side repo:
  flows/pull_xls_artifacts.sh <path-to-source>     # see HOWTO §8
EOF
  exit 1
fi
[[ -f "$POINT_DIR/point.json" ]] || die "missing $POINT_DIR/point.json — re-run the XLS half"
command -v librelane >/dev/null || die "librelane not on PATH — enter the librelane nix-shell first"

mkdir -p "$POINT_DIR"
echo "[point] pnr: model=$DELAY_MODEL arch=$ARCH_TAG variant=$VARIANT bw=$BW nb=$NB -> $POINT_DIR"

# ---- 1. librelane Classic flow ----------------------------------------------
cat > "$CONFIG" <<EOF
{
  "DESIGN_NAME": "binner_top",
  "VERILOG_FILES": ["dir::binner.v"],
  "CLOCK_PORT": "clk",
  "CLOCK_PERIOD": $LL_CLK_NS
}
EOF

# librelane defers signoff violations (e.g. MaxSlew) to a non-zero exit AFTER
# writing final/metrics.json — so don't let set -e abort here; judge success on
# whether the metrics file was produced. See HOWTO §3c.
echo "[librelane] running Classic flow (this is the slow step)…"
LL_ARGS=(--flow classic --condensed --log-level WARNING)
[[ -n "$LL_JOBS" ]] && LL_ARGS+=(--jobs "$LL_JOBS")
set +e
librelane "${LL_ARGS[@]}" "$CONFIG"
LL_EXIT=$?
set -e

LATEST="$(ls -dt "$POINT_DIR"/runs/RUN_* 2>/dev/null | head -1 || true)"
METRICS_SRC="${LATEST:+$LATEST/final/metrics.json}"
[[ -n "$METRICS_SRC" && -f "$METRICS_SRC" ]] \
  || die "librelane produced no final/metrics.json (exit $LL_EXIT) — see $LATEST"
[[ $LL_EXIT -ne 0 ]] && echo "[librelane] note: exit $LL_EXIT (likely a deferred signoff violation); metrics present, continuing"

# ---- 2. update point.json so plot_pareto.py sees the actual PnR clock --------
# The XLS half wrote a default librelane_clock_ns; rewrite it now in case the
# user passed a different --librelane-clock-ns to PnR than to XLS.
python3 -c "
import json
p = json.load(open('$POINT_DIR/point.json'))
p['librelane_clock_ns'] = $LL_CLK_NS
json.dump(p, open('$POINT_DIR/point.json', 'w'), indent=2)
"

# ---- 3. canonical per-point result + PPA summary ----------------------------
cp "$METRICS_SRC" "$POINT_DIR/metrics.json"
python3 "$ROOT/flows/extract_metrics.py" "$POINT_DIR/metrics.json" | tee "$POINT_DIR/ppa_summary.txt"
echo "[done] pnr: $POINT_DIR/metrics.json"
