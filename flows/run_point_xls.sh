#!/usr/bin/env bash
# run_point_xls.sh — XLS half of one PPA design point: DSLX -> IR -> Verilog.
#
# Produces binner.v + binner.{ir,opt.ir,metrics.textproto,schedule.textproto}
# + top.x + point.json for a single (delay_model, arch, variant, bw, nb) point.
# **No librelane required.** Pair with run_point_pnr.sh for the PnR half (or
# use run_point.sh to chain both). See HOWTO §8 for the distributed
# (per-machine) workflow.
#
# Adapting to a different function: only the FUNCTION-SPECIFIC block below
# (the generated top) and the --bw-global/--n-bounds flags are binner-specific;
# the XLS chain is generic. See BLUEPRINT.md.
#
# Usage:
#   flows/run_point_xls.sh --bw-global 8 --n-bounds 4 [options]
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
#   --librelane-clock-ns N     PnR target clock — recorded in point.json so
#                        plot_pareto.py can compute pnr_crit_path; this script
#                        itself does NOT use it                (default: 10)
#   --delay-model NAME   XLS delay model: sky130|asap7|unit          (default: sky130)
#   --force              rebuild even if binner.v is already present
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
LL_CLK_NS="10"; DELAY_MODEL="sky130"; FORCE=0

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
    --delay-model)       DELAY_MODEL="$2"; shift 2 ;;
    --force)             FORCE=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "run_point_xls.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

die() { echo "run_point_xls.sh: $*" >&2; exit 1; }
[[ -n "$BW" && -n "$NB" ]] || die "--bw-global and --n-bounds are required (see --help)"
[[ -x "$XLS_BIN/codegen_main" ]] || die "XLS binaries not found in external/xls-bin/bin (see README 'Install Tools')"

# ---- resolve arch -> stages and directory tag --------------------------------
case "$ARCH" in
  parallel) STAGES=1; ARCH_TAG="parallel" ;;
  pipeline) STAGES="${STAGES:-4}"; ARCH_TAG="pipe_s${STAGES}" ;;
  *) die "--arch must be 'parallel' or 'pipeline' (got '$ARCH')" ;;
esac

# ---- resolve variant -> DSLX function call and directory tag -----------------
case "$VARIANT" in
  ref)  BINNER_FN="binner::binner" ;;
  prio) BINNER_FN="binner::binner_prio"; ARCH_TAG="${ARCH_TAG}_${VARIANT}" ;;
  *) die "--variant must be 'ref' or 'prio' (got '$VARIANT')" ;;
esac

POINT_DIR="$ROOT/runs/$DELAY_MODEL/$ARCH_TAG/bw${BW}_nb${NB}"
IR="$POINT_DIR/binner.ir"; OPT_IR="$POINT_DIR/binner.opt.ir"
VERILOG="$POINT_DIR/binner.v"

# ---- idempotency: skip if binner.v already exists ----------------------------
if [[ -f "$VERILOG" && $FORCE -eq 0 ]]; then
  echo "[skip] $POINT_DIR (binner.v present; pass --force to rebuild)"; exit 0
fi
mkdir -p "$POINT_DIR"

echo "[point] xls: model=$DELAY_MODEL arch=$ARCH_TAG variant=$VARIANT bw=$BW nb=$NB -> $POINT_DIR"

# ---- 1. generate the concrete DSLX top --------------------------------------
# === FUNCTION-SPECIFIC (binner) — to adapt to another design replace this block
# === plus the --bw-global/--n-bounds flags and the binner / binner_top names.
# === Everything else in this script is function-agnostic. See BLUEPRINT.md.
# binner is parametric; IR conversion needs a non-parametric top. BW_BIN is left
# to DSLX's std::clog2 so the bin-index width is never computed in bash.
cat > "$POINT_DIR/top.x" <<EOF
// AUTO-GENERATED by flows/run_point_xls.sh — do not edit.
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
# librelane_clock_ns is recorded here so plot_pareto.py has a complete record
# even after an XLS-only run (default 10 ns matches the librelane default and
# what run_point_pnr.sh will use unless overridden). If PnR runs later with a
# different --librelane-clock-ns, that script updates this field in place.
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

echo "[done] xls: $VERILOG"
