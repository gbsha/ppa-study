#!/usr/bin/env bash
# run_point.sh — build and measure ONE PPA design point, end to end.
#
# Drives the same CLI chain HOWTO.md walks by hand — generate a concrete DSLX
# top, ir_converter -> opt -> codegen -> librelane Classic -> extract_metrics —
# for a single (delay_model, arch, bw_global, n_bounds) point. No custom flow
# framework: just the provided XLS and librelane CLIs, orchestrated in bash.
#
# Each point writes ONLY to its own runs/<model>/<arch>/<params>/ directory and
# skips if its result already exists, so a sweep wrapper can fan many points out
# in parallel (e.g. GNU parallel) safely. See PLAN.md M6.
#
# Adapting to a different function: only the FUNCTION-SPECIFIC block below (the
# generated top) and the --bw-global/--n-bounds flags are binner-specific; the
# XLS -> librelane chain is generic. See BLUEPRINT.md for the full swap-point list.
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
#   --skip-pnr           stop after codegen (cheap XLS-only half; no librelane)
#   --force              rebuild even if a cached result is present
#   -h, --help           show this help
set -euo pipefail

# ---- locate repo root so the script works from any cwd -----------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
XLS_BIN="$ROOT/external/xls-bin/bin"
STDLIB="$ROOT/external/xls/xls/dslx/stdlib"
DSLX_DIR="$ROOT/dslx"
XLS_TAG="xls-81ff4fdf7-xlsbin-1"   # pinned xls commit + xls-bin bundle build (provenance only)

# ---- defaults ----------------------------------------------------------------
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

die() { echo "run_point.sh: $*" >&2; exit 1; }
[[ -n "$BW" && -n "$NB" ]] || die "--bw-global and --n-bounds are required (see --help)"
[[ -x "$XLS_BIN/codegen_main" ]] || die "XLS binaries not found in external/xls-bin/bin (see README 'Install Tools')"

# ---- resolve arch -> stages and directory tag --------------------------------
case "$ARCH" in
  parallel) STAGES=1; ARCH_TAG="parallel" ;;
  pipeline) STAGES="${STAGES:-4}"; ARCH_TAG="pipe_s${STAGES}" ;;
  *) die "--arch must be 'parallel' or 'pipeline' (got '$ARCH')" ;;
esac

# ---- resolve variant -> DSLX function call and directory tag -----------------
# 'ref' keeps the historical layout (no suffix); other variants get suffixed so
# their runs don't collide with the already-committed reference grid.
case "$VARIANT" in
  ref)  BINNER_FN="binner::binner" ;;
  prio) BINNER_FN="binner::binner_prio"; ARCH_TAG="${ARCH_TAG}_${VARIANT}" ;;
  *) die "--variant must be 'ref' or 'prio' (got '$VARIANT')" ;;
esac

POINT_DIR="$ROOT/runs/$DELAY_MODEL/$ARCH_TAG/bw${BW}_nb${NB}"
IR="$POINT_DIR/binner.ir"; OPT_IR="$POINT_DIR/binner.opt.ir"
VERILOG="$POINT_DIR/binner.v"; CONFIG="$POINT_DIR/config.json"

# ---- idempotency: skip if the result for this mode already exists ------------
SENTINEL="$POINT_DIR/metrics.json"; [[ $SKIP_PNR -eq 1 ]] && SENTINEL="$VERILOG"
if [[ -f "$SENTINEL" && $FORCE -eq 0 ]]; then
  echo "[skip] $POINT_DIR (result present; pass --force to rebuild)"; exit 0
fi
mkdir -p "$POINT_DIR"

echo "[point] model=$DELAY_MODEL arch=$ARCH_TAG variant=$VARIANT bw=$BW nb=$NB -> $POINT_DIR"

# ---- 1. generate the concrete DSLX top --------------------------------------
# === FUNCTION-SPECIFIC (binner) — to adapt to another design replace this block
# === plus the --bw-global/--n-bounds flags and the binner / binner_top names.
# === Everything else in this script is function-agnostic. See BLUEPRINT.md.
# binner is parametric; IR conversion needs a non-parametric top. BW_BIN is left
# to DSLX's std::clog2 so the bin-index width is never computed in bash.
cat > "$POINT_DIR/top.x" <<EOF
// AUTO-GENERATED by flows/run_point.sh — do not edit.
import binner;
import std;

const BW_GLOBAL = u32:${BW};
const N_BOUNDS = u32:${NB};
const BW_BIN = std::clog2(N_BOUNDS);

pub fn binner_top(
    global_index: uN[BW_GLOBAL],
    lower_bin_boundaries: uN[BW_GLOBAL][N_BOUNDS],
) -> (uN[BW_BIN], uN[BW_GLOBAL]) {
    ${BINNER_FN}<BW_GLOBAL, N_BOUNDS>(global_index, lower_bin_boundaries)
}
EOF
# === end function-specific ===

# ---- 2. DSLX -> IR -> optimised IR ------------------------------------------
"$XLS_BIN/ir_converter_main" --dslx_stdlib_path="$STDLIB" --dslx_path="$DSLX_DIR" \
    --top=binner_top "$POINT_DIR/top.x" > "$IR"
"$XLS_BIN/opt_main" "$IR" > "$OPT_IR"

# ---- 3. resolve the codegen (XLS scheduling) clock --------------------------
# 'auto' probes the minimum feasible clock for the requested stage count by
# asking for an impossible 1 ps and parsing the scheduler's suggestion. This is
# the right default for both families: for parallel (1 stage) the emitted RTL is
# clock-independent as long as the clock is feasible, and a fixed value doesn't
# scale (8 comparators in one stage need a looser clock than 4); for pipeline it
# packs the logic tightly across stages. Override with an explicit value if you
# want extra slack at codegen time.
CODEGEN_CLK="${CODEGEN_CLK:-auto}"
if [[ "$CODEGEN_CLK" == "auto" ]]; then
  probe_err="$("$XLS_BIN/codegen_main" --generator=pipeline --delay_model="$DELAY_MODEL" \
        --clock_period_ps=1 --pipeline_stages="$STAGES" --reset=rst \
        --module_name=binner_top --output_verilog_path=/dev/null "$OPT_IR" 2>&1 >/dev/null || true)"
  CODEGEN_CLK="$(grep -oP 'Try .*?clock_period_ps=\K[0-9]+' <<<"$probe_err" | head -1)"
  [[ -n "$CODEGEN_CLK" ]] || die "could not parse minimum feasible clock from scheduler:\n$probe_err"
  echo "[clock] auto-probed minimum feasible clock for $STAGES stage(s): ${CODEGEN_CLK} ps"
fi

# ---- 4. codegen: pipeline Verilog in plain V2005 (Yosys-friendly) -----------
SCHED_ARG=(); [[ $STAGES -gt 1 ]] && SCHED_ARG=(--output_schedule_path="$POINT_DIR/binner.schedule.textproto")
"$XLS_BIN/codegen_main" \
    --generator=pipeline --delay_model="$DELAY_MODEL" \
    --clock_period_ps="$CODEGEN_CLK" --pipeline_stages="$STAGES" \
    --reset=rst --use_system_verilog=false --module_name=binner_top \
    --output_verilog_path="$VERILOG" \
    --block_metrics_path="$POINT_DIR/binner.metrics.textproto" \
    "${SCHED_ARG[@]}" "$OPT_IR"
FLOPS="$(grep -oP 'flop_count:\s*\K[0-9]+' "$POINT_DIR/binner.metrics.textproto" | head -1 || true)"
echo "[codegen] clock=${CODEGEN_CLK}ps stages=$STAGES flop_count=${FLOPS:-?}"

# ---- provenance: record exactly how this point was produced -----------------
cat > "$POINT_DIR/point.json" <<EOF
{
  "delay_model": "$DELAY_MODEL",
  "arch": "$ARCH", "arch_tag": "$ARCH_TAG", "pipeline_stages": $STAGES,
  "variant": "$VARIANT",
  "bw_global": $BW, "n_bounds": $NB,
  "codegen_clock_ps": $CODEGEN_CLK,
  "librelane_clock_ns": $LL_CLK_NS,
  "flop_count": ${FLOPS:-null},
  "xls_revision": "$XLS_TAG",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

if [[ $SKIP_PNR -eq 1 ]]; then
  echo "[done] XLS-only (--skip-pnr): $VERILOG"; exit 0
fi

# ---- 5. librelane Classic flow ----------------------------------------------
command -v librelane >/dev/null || die "librelane not on PATH — enter the librelane nix-shell first"
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

# ---- 6. canonical per-point result + PPA summary ----------------------------
cp "$METRICS_SRC" "$POINT_DIR/metrics.json"
"$ROOT/flows/extract_metrics.py" "$POINT_DIR/metrics.json" | tee "$POINT_DIR/ppa_summary.txt"
echo "[done] $POINT_DIR/metrics.json"
