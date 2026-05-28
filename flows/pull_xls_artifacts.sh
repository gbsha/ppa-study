#!/usr/bin/env bash
# pull_xls_artifacts.sh — forward-only mailbox sync from an XLS+codegen source.
#
# Distributed workflow (see HOWTO §8): one machine ("machine A") runs the
# XLS+cocotb half — DSLX, codegen, RTL verification — and produces binner.v +
# provenance in its runs/ tree. Another machine ("machine B") runs the
# librelane PnR half. This script lives on B and pulls A's codegen output
# into B's local runs/ tree so librelane can work against local disk
# (running PnR over sshfs is slow and fragile).
#
# Forward-only: B pulls from A. Nothing flows back to A automatically — if
# you want A's plot_pareto.py to see B's PnR metrics, set up a second mount
# or scp them across. The common case is B does the aggregation locally.
#
# What this copies (the codegen output per point):
#   binner.v, top.x, binner.ir, binner.opt.ir,
#   binner.metrics.textproto, binner.schedule.textproto, point.json
#
# What this skips:
#   - librelane outputs (metrics.json, ppa_summary.txt, config.json,
#     per-point runs/RUN_*) — those live on whichever machine runs PnR.
#   - dispatcher logs (runs/_sweeps/, runs/_verif/) — local to whichever
#     machine ran the dispatcher.
#
# The source can be anything that mirrors this repo's runs/ layout —
# typically an sshfs mount of A's repo, but a local checkout works too.
#
# Usage:
#   flows/pull_xls_artifacts.sh <src>
#
# Example:
#   sshfs userA@machineA:~/ppa-study ~/mnt/ppa-xls
#   flows/pull_xls_artifacts.sh ~/mnt/ppa-xls
#   flows/run_sweep.sh                   # PnR runs locally on B
#   fusermount -u ~/mnt/ppa-xls          # when done
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SRC="${1:?usage: flows/pull_xls_artifacts.sh <path-to-source-repo>}"
SRC="${SRC%/}"  # strip trailing slash for consistent rsync semantics

[[ -d "$SRC/runs" ]] || {
  echo "pull_xls_artifacts.sh: '$SRC' has no runs/ directory — nothing to pull" >&2
  exit 1
}
command -v rsync >/dev/null || {
  echo "pull_xls_artifacts.sh: rsync not found on PATH" >&2; exit 1; }

mkdir -p "$ROOT/runs"

# rsync rule order matters — directory excludes must precede the --include='*/'
# that allows rsync to descend into subdirectories. The trailing --exclude='*'
# catches everything not explicitly included (metrics.json, RUN_*, etc).
rsync -av \
  --exclude='/_verif/' \
  --exclude='/_sweeps/' \
  --include='*/' \
  --include='binner.v' \
  --include='top.x' \
  --include='binner.ir' \
  --include='binner.opt.ir' \
  --include='binner.metrics.textproto' \
  --include='binner.schedule.textproto' \
  --include='point.json' \
  --exclude='*' \
  "$SRC/runs/" "$ROOT/runs/"

echo "[pull] sync complete: $SRC/runs/ → $ROOT/runs/"
