#!/usr/bin/env python3
"""Aggregate a PPA sweep and plot its Pareto frontier(s).

Walks a runs/ tree for per-point directories — each holds `point.json` (XLS
provenance from run_point.sh) and, once PnR has run, `metrics.json` (librelane
PPA). Joins the two, writes a flat CSV table, prints it, and renders
Pareto-frontier scatter plots.

Data loading, the CSV, and the Pareto math are stdlib-only, so the table works
from a bare librelane nix-shell. Only plotting needs matplotlib (see
environment.yml); it is imported lazily, so `--no-plot` runs anywhere.

Usage:
    flows/plot_pareto.py [--runs runs] [--out results] [--no-plot]

Each plot minimises BOTH axes (down-and-left is better), so the highlighted
non-dominated points form the achievable frontier.
"""

import argparse
import csv
import json
import os
import sys

# librelane metric keys (same ones flows/extract_metrics.py reads), mapped to
# the flat column we expose. None-safe: missing keys just stay blank.
METRIC_KEYS = {
    "core_area_um2":   "design__core__area",
    "die_area_um2":    "design__die__area",
    "stdcell_util":    "design__instance__utilization__stdcell",
    "wns_ns_typical":  "timing__setup__wns__corner:max_tt_025C_1v80",
    # power__total is in watts; converted to mW on load.
    "_power_w":        "power__total",
}

# Column order for the CSV / printed table.
COLUMNS = [
    "arch_tag", "arch", "pipeline_stages", "bw_global", "n_bounds",
    "codegen_clock_ps", "flop_count",
    "core_area_um2", "die_area_um2", "stdcell_util", "power_mw",
    "wns_ns_typical", "has_pnr",
]

# Standard plots: (x_key, y_key, x_label, y_label, title, filename).
# All axes are lower-is-better. The flops-vs-clock view needs no PnR, so it
# renders even before/without librelane; the others need metrics.json.
PLOTS = [
    ("flop_count", "codegen_clock_ps",
     "flop count (proxy for area)", "XLS min clock period [ps] (lower = faster)",
     "Pre-PnR frontier: flops vs min clock", "pareto_flops_vs_clock.png"),
    ("core_area_um2", "codegen_clock_ps",
     "core area [um^2]", "XLS min clock period [ps] (lower = faster)",
     "Pareto: core area vs min clock", "pareto_area_vs_clock.png"),
    ("core_area_um2", "power_mw",
     "core area [um^2]", "total power [mW]",
     "Pareto: core area vs power", "pareto_area_vs_power.png"),
]


def find_point_dirs(runs_dir):
    """Yield directories under runs_dir that contain a point.json."""
    for dirpath, _dirnames, filenames in os.walk(runs_dir):
        if "point.json" in filenames:
            yield dirpath


def load_record(point_dir):
    """Merge point.json provenance with selected metrics.json PPA fields."""
    with open(os.path.join(point_dir, "point.json")) as f:
        p = json.load(f)
    rec = {
        "arch_tag":         p.get("arch_tag"),
        "arch":             p.get("arch"),
        "pipeline_stages":  p.get("pipeline_stages"),
        "bw_global":        p.get("bw_global"),
        "n_bounds":         p.get("n_bounds"),
        "codegen_clock_ps": p.get("codegen_clock_ps"),
        "flop_count":       p.get("flop_count"),
        "has_pnr":          False,
    }
    for col in ("core_area_um2", "die_area_um2", "stdcell_util",
                "power_mw", "wns_ns_typical"):
        rec[col] = None

    mpath = os.path.join(point_dir, "metrics.json")
    if os.path.exists(mpath):
        with open(mpath) as f:
            m = json.load(f)
        rec["has_pnr"] = True
        for col, key in METRIC_KEYS.items():
            val = m.get(key)
            if col == "_power_w":
                rec["power_mw"] = None if val is None else val * 1000.0
            else:
                rec[col] = val
    return rec


def pareto_indices(rows, xk, yk):
    """Indices of rows not dominated on (xk, yk); lower is better on both."""
    cand = [i for i, r in enumerate(rows)
            if r.get(xk) is not None and r.get(yk) is not None]
    front = []
    for i in cand:
        xi, yi = rows[i][xk], rows[i][yk]
        dominated = any(
            rows[j][xk] <= xi and rows[j][yk] <= yi
            and (rows[j][xk] < xi or rows[j][yk] < yi)
            for j in cand if j != i
        )
        if not dominated:
            front.append(i)
    return set(front)


def write_csv(rows, path):
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS, extrasaction="ignore")
        w.writeheader()
        for r in sorted(rows, key=lambda r: (r["arch_tag"] or "", r["n_bounds"] or 0)):
            w.writerow(r)
    print(f"[csv] {path}")


def print_table(rows):
    print(f"\n{'arch_tag':<10}{'nb':>4}{'bw':>4}{'clk_ps':>8}{'flops':>7}"
          f"{'area_um2':>11}{'power_mW':>10}{'PnR':>5}")
    for r in sorted(rows, key=lambda r: (r["arch_tag"] or "", r["n_bounds"] or 0)):
        area = "-" if r["core_area_um2"] is None else f"{r['core_area_um2']:.1f}"
        pwr  = "-" if r["power_mw"] is None else f"{r['power_mw']:.3f}"
        print(f"{r['arch_tag'] or '?':<10}{r['n_bounds']:>4}{r['bw_global']:>4}"
              f"{r['codegen_clock_ps']:>8}{r['flop_count']:>7}"
              f"{area:>11}{pwr:>10}{'yes' if r['has_pnr'] else 'no':>5}")


def plot_pair(rows, xk, yk, xlabel, ylabel, title, out_path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    pts = [r for r in rows if r.get(xk) is not None and r.get(yk) is not None]
    if not pts:
        print(f"[skip] {os.path.basename(out_path)} — no data for {xk} vs {yk}")
        return
    front = pareto_indices(rows, xk, yk)

    fig, ax = plt.subplots(figsize=(7, 5))
    cmap = plt.get_cmap("tab10")
    for k, a in enumerate(sorted({r["arch_tag"] for r in pts})):
        g = [r for r in pts if r["arch_tag"] == a]
        ax.scatter([r[xk] for r in g], [r[yk] for r in g],
                   color=cmap(k), label=a, zorder=3)
    for r in pts:
        ax.annotate(f"nb{r['n_bounds']}", (r[xk], r[yk]),
                    fontsize=8, xytext=(4, 4), textcoords="offset points")

    fr = sorted((rows[i] for i in front), key=lambda r: r[xk])
    if fr:
        ax.plot([r[xk] for r in fr], [r[yk] for r in fr],
                "--", color="black", lw=1, zorder=2, label="Pareto frontier")
        ax.scatter([r[xk] for r in fr], [r[yk] for r in fr],
                   s=170, facecolors="none", edgecolors="black", zorder=4)

    ax.set_xlabel(xlabel)
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.legend(fontsize=8)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_path, dpi=130)
    plt.close(fig)
    print(f"[plot] {out_path}")


def main(argv=None):
    ap = argparse.ArgumentParser(description="Aggregate a PPA sweep and plot Pareto frontiers.")
    ap.add_argument("--runs", default="runs", help="runs/ tree to scan (default: runs)")
    ap.add_argument("--out", default="results", help="output dir for CSV/plots (default: results)")
    ap.add_argument("--no-plot", action="store_true", help="CSV + table only; skip matplotlib")
    args = ap.parse_args(argv)

    rows = [load_record(d) for d in find_point_dirs(args.runs)]
    if not rows:
        print(f"No point.json found under {args.runs}/ — run a sweep first.", file=sys.stderr)
        return 1

    os.makedirs(args.out, exist_ok=True)
    write_csv(rows, os.path.join(args.out, "ppa_sweep.csv"))
    print_table(rows)

    n_pnr = sum(1 for r in rows if r["has_pnr"])
    print(f"\n{len(rows)} points ({n_pnr} with PnR metrics).")

    if args.no_plot:
        return 0
    for xk, yk, xl, yl, title, fname in PLOTS:
        plot_pair(rows, xk, yk, xl, yl, title, os.path.join(args.out, fname))
    return 0


if __name__ == "__main__":
    sys.exit(main())
