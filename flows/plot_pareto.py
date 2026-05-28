#!/usr/bin/env python3
"""Aggregate a PPA sweep: build-time-parameter scaling + a Pareto frontier.

Walks a runs/ tree for per-point directories — each holds `point.json` (XLS
provenance from run_point.sh) and, once PnR has run, `metrics.json` (librelane
PPA). Joins the two, writes a flat CSV, prints it, and renders plots.

The active study fixes one architecture (1 pipeline stage) and sweeps the
build-time parameters bw_global × n_boundaries (PLAN.md). So the views are:
  - scaling: area / critical-path / power vs one parameter, a line per value of
    the other (choose the x-axis with --x);
  - frontier: core area vs post-PnR critical path, and vs power, Pareto-marked.

Performance is reported as TWO critical-path numbers per point (METRICS.md §4):
  - xls_crit_path_ns   — XLS pre-PnR delay-model estimate (codegen_clock_ps/1000),
                         present even with --skip-pnr;
  - pnr_crit_path_*_ns — post-PnR, = librelane_clock_ns − register-to-register
                         worst setup slack (ws) at a corner; present once PnR ran.
The ss (worst-slow) value is the timing-binding one but can be inflated by
max-slew violations on high-fanout nets, so max_slew_viol_ss is reported too.

Data loading, the CSV, and the Pareto math are stdlib-only (so the table works
from a bare librelane nix-shell); only plotting imports matplotlib, lazily, so
`--no-plot` runs anywhere.

Usage:
    flows/plot_pareto.py [--runs runs] [--out results]
                         [--x n_boundaries|bw_global] [--no-plot]
"""

import argparse
import csv
import json
import math
import os
import sys

# sky130 signoff corner names. Other PDKs differ; all lookups are None-safe, so
# non-sky130 points simply leave the post-PnR columns blank.
CORNER_TT = "max_tt_025C_1v80"   # typical
CORNER_SS = "max_ss_100C_1v60"   # worst-slow (timing-binding)

# librelane metric keys read directly (same ones extract_metrics.py uses).
METRIC_KEYS = {
    "core_area_um2": "design__core__area",
    "die_area_um2":  "design__die__area",
    "stdcell_util":  "design__instance__utilization__stdcell",
    # power__total is watts; converted to mW on load.
    "_power_w":      "power__total",
}
# Register-to-register worst setup slack per corner (ns). clock − ws = critical
# path; r2r excludes assumed I/O delays (METRICS.md §4).
WS_R2R = {
    "tt": f"timing__setup_r2r__ws__corner:{CORNER_TT}",
    "ss": f"timing__setup_r2r__ws__corner:{CORNER_SS}",
}
SLEW_VIOL_SS = f"design__max_slew_violation__count__corner:{CORNER_SS}"

COLUMNS = [
    "delay_model", "arch_tag", "arch", "variant", "pipeline_stages",
    "bw_global", "n_bounds",
    "codegen_clock_ps", "xls_crit_path_ns", "flop_count",
    "core_area_um2", "die_area_um2", "stdcell_util", "power_mw",
    "pnr_crit_path_tt_ns", "pnr_crit_path_ss_ns", "max_slew_viol_ss",
    "has_pnr",
]


def find_point_dirs(runs_dir):
    for dirpath, _dirnames, filenames in os.walk(runs_dir):
        if "point.json" in filenames:
            yield dirpath


def load_record(point_dir):
    """Merge point.json provenance with metrics.json PPA, deriving crit paths."""
    with open(os.path.join(point_dir, "point.json")) as f:
        p = json.load(f)
    rec = {
        "delay_model":      p.get("delay_model"),
        "arch_tag":         p.get("arch_tag"),
        "arch":             p.get("arch"),
        # variant defaults to 'ref' so legacy point.json (pre-variant) loads cleanly.
        "variant":          p.get("variant", "ref"),
        "pipeline_stages":  p.get("pipeline_stages"),
        "bw_global":        p.get("bw_global"),
        "n_bounds":         p.get("n_bounds"),
        "codegen_clock_ps": p.get("codegen_clock_ps"),
        "flop_count":       p.get("flop_count"),
        "has_pnr":          False,
    }
    cc = p.get("codegen_clock_ps")
    rec["xls_crit_path_ns"] = None if cc is None else cc / 1000.0
    ll_clk = p.get("librelane_clock_ns")
    for col in ("core_area_um2", "die_area_um2", "stdcell_util", "power_mw",
                "pnr_crit_path_tt_ns", "pnr_crit_path_ss_ns", "max_slew_viol_ss"):
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
        for corner, key in WS_R2R.items():
            ws = m.get(key)
            # librelane can report ws = Infinity when a corner has no constrained
            # r2r path (tiny designs) — that yields a meaningless -inf, so drop it.
            ok = ws is not None and ll_clk is not None and math.isfinite(ws)
            rec[f"pnr_crit_path_{corner}_ns"] = (ll_clk - ws) if ok else None
        rec["max_slew_viol_ss"] = m.get(SLEW_VIOL_SS)
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


def _sort_key(r):
    return (r["arch_tag"] or "", r["bw_global"] or 0, r["n_bounds"] or 0)


def write_csv(rows, path):
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS, extrasaction="ignore")
        w.writeheader()
        for r in sorted(rows, key=_sort_key):
            w.writerow(r)
    print(f"[csv] {path}")


def print_table(rows):
    print(f"\n{'arch_tag':<10}{'bw':>4}{'nb':>4}{'flops':>7}{'area_um2':>11}"
          f"{'power_mW':>10}{'xls_cp':>8}{'pnr_ss':>8}{'slew':>6}{'PnR':>5}")
    for r in sorted(rows, key=_sort_key):
        def f(v, p=1):
            return "-" if v is None else f"{v:.{p}f}"
        slew = "-" if r["max_slew_viol_ss"] is None else str(r["max_slew_viol_ss"])
        print(f"{r['arch_tag'] or '?':<10}{r['bw_global'] or 0:>4}{r['n_bounds'] or 0:>4}"
              f"{r['flop_count'] or 0:>7}{f(r['core_area_um2']):>11}{f(r['power_mw'], 3):>10}"
              f"{f(r['xls_crit_path_ns'], 2):>8}{f(r['pnr_crit_path_ss_ns'], 2):>8}"
              f"{slew:>6}{'yes' if r['has_pnr'] else 'no':>5}")


# ---- plotting (matplotlib imported lazily) ----------------------------------

def _mpl():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    return plt


def plot_scaling(rows, xk, series_k, ycols, ylabel, xlabel, title, out_path):
    """Line plot: each ycol vs xk, one colour per distinct series_k value.

    ycols: list of (column, linestyle, legend_suffix) — e.g. an XLS (dashed) and
    a post-PnR (solid) critical-path line share a colour per series value.
    """
    plt = _mpl()
    pts = [r for r in rows if r.get(xk) is not None and r.get(series_k) is not None]
    series_vals = sorted({r[series_k] for r in pts})
    cmap = plt.get_cmap("tab10")
    fig, ax = plt.subplots(figsize=(7, 5))
    drew = False
    for i, sv in enumerate(series_vals):
        grp = sorted((r for r in pts if r[series_k] == sv), key=lambda r: r[xk])
        for col, ls, suf in ycols:
            xs = [r[xk] for r in grp if r.get(col) is not None]
            ys = [r[col] for r in grp if r.get(col) is not None]
            if xs:
                ax.plot(xs, ys, ls, color=cmap(i % 10), marker="o",
                        label=f"{series_k}={sv}{suf}")
                drew = True
    if not drew:
        print(f"[skip] {os.path.basename(out_path)} — no plottable data")
        plt.close(fig)
        return
    ax.set_xlabel(xlabel)
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.legend(fontsize=8)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_path, dpi=130)
    plt.close(fig)
    print(f"[plot] {out_path}")


def plot_frontier(rows, xk, yk, xlabel, ylabel, title, out_path):
    """Scatter of all points with the (lower-is-better) Pareto front marked."""
    plt = _mpl()
    pts = [r for r in rows if r.get(xk) is not None and r.get(yk) is not None]
    if not pts:
        print(f"[skip] {os.path.basename(out_path)} — no data for {xk} vs {yk}")
        return
    front = pareto_indices(rows, xk, yk)
    fig, ax = plt.subplots(figsize=(7, 5))
    ax.scatter([r[xk] for r in pts], [r[yk] for r in pts], color="tab:blue", zorder=3)
    for r in pts:
        ax.annotate(f"bw{r['bw_global']}/nb{r['n_bounds']}", (r[xk], r[yk]),
                    fontsize=7, xytext=(4, 4), textcoords="offset points")
    fr = sorted((rows[i] for i in front), key=lambda r: r[xk])
    if fr:
        ax.plot([r[xk] for r in fr], [r[yk] for r in fr],
                "--", color="black", lw=1, zorder=2, label="Pareto frontier")
        ax.scatter([r[xk] for r in fr], [r[yk] for r in fr],
                   s=170, facecolors="none", edgecolors="black", zorder=4)
        ax.legend(fontsize=8)
    ax.set_xlabel(xlabel)
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_path, dpi=130)
    plt.close(fig)
    print(f"[plot] {out_path}")


def make_plots(rows, out, xchoice):
    xk = "n_bounds" if xchoice == "n_boundaries" else "bw_global"
    series_k = "bw_global" if xk == "n_bounds" else "n_bounds"
    xlabel = "n_boundaries" if xk == "n_bounds" else "bw_global [bits]"

    plot_scaling(rows, xk, series_k, [("core_area_um2", "-", "")],
                 "core area [um^2]", xlabel, f"Core area vs {xlabel}",
                 os.path.join(out, f"scaling_area_vs_{xk}.png"))
    plot_scaling(rows, xk, series_k,
                 [("xls_crit_path_ns", "--", " (XLS)"),
                  ("pnr_crit_path_ss_ns", "-", " (PnR ss)")],
                 "critical path [ns]", xlabel,
                 f"Critical path vs {xlabel} (dashed = XLS est., solid = post-PnR ss)",
                 os.path.join(out, f"scaling_critpath_vs_{xk}.png"))
    plot_scaling(rows, xk, series_k, [("power_mw", "-", "")],
                 "total power [mW]", xlabel, f"Power vs {xlabel}",
                 os.path.join(out, f"scaling_power_vs_{xk}.png"))

    plot_frontier(rows, "core_area_um2", "pnr_crit_path_ss_ns",
                  "core area [um^2]", "post-PnR critical path (ss) [ns]",
                  "Pareto: area vs post-PnR critical path",
                  os.path.join(out, "pareto_area_vs_critpath.png"))
    plot_frontier(rows, "core_area_um2", "power_mw",
                  "core area [um^2]", "total power [mW]",
                  "Pareto: area vs power", os.path.join(out, "pareto_area_vs_power.png"))


def main(argv=None):
    ap = argparse.ArgumentParser(description="Aggregate a PPA sweep; scaling + Pareto plots.")
    ap.add_argument("--runs", default="runs", help="runs/ tree to scan (default: runs)")
    ap.add_argument("--out", default="results", help="output dir (default: results)")
    ap.add_argument("--x", default="n_boundaries", choices=["n_boundaries", "bw_global"],
                    help="x-axis for the scaling plots (default: n_boundaries)")
    ap.add_argument("--delay-model", default="sky130",
                    help="keep only this delay model — don't mix techs in one plot "
                         "(default: sky130; PnR metrics are sky130-only, see METRICS.md §7)")
    ap.add_argument("--no-plot", action="store_true", help="CSV + table only; skip matplotlib")
    args = ap.parse_args(argv)

    rows = [load_record(d) for d in find_point_dirs(args.runs)]
    if not rows:
        print(f"No point.json found under {args.runs}/ — run a sweep first.", file=sys.stderr)
        return 1
    rows = [r for r in rows if r["delay_model"] == args.delay_model]
    if not rows:
        print(f"No points with delay_model={args.delay_model} under {args.runs}/.", file=sys.stderr)
        return 1

    os.makedirs(args.out, exist_ok=True)
    write_csv(rows, os.path.join(args.out, "ppa_sweep.csv"))
    print_table(rows)
    n_pnr = sum(1 for r in rows if r["has_pnr"])
    print(f"\n{len(rows)} points ({n_pnr} with PnR metrics).")

    if args.no_plot:
        return 0
    make_plots(rows, args.out, args.x)
    return 0


if __name__ == "__main__":
    sys.exit(main())
