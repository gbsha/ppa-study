#!/usr/bin/env python3
"""Print a compact PPA summary from a librelane Classic-flow final/metrics.json.

Usage:
    flows/extract_metrics.py <path-to-metrics.json>

The librelane Classic flow writes final/metrics.json under its run directory
(typically <design-dir>/runs/RUN_<timestamp>/final/metrics.json). This script
picks out the keys that matter for the M3 baseline and prints them in a
human-readable table. The full set of available keys is much larger; print the
raw JSON or grep it directly if you want more.
"""

import json
import sys


def get(metrics: dict, key: str, default=None):
    """Look up a metric key, returning `default` if it's absent.

    librelane's metric naming can drift across versions; treating missing keys
    as `None` rather than crashing keeps this script forward-compatible.
    """
    return metrics.get(key, default)


def signed(val, suffix: str = " ns", precision: int = 3) -> str:
    """Format a signed quantity (e.g. timing slack — negative means violation)."""
    if val is None:
        return "<missing>"
    return f"{val:+.{precision}f}{suffix}"


def unsigned(val, suffix: str = "", precision: int = 1, scale: float = 1.0) -> str:
    """Format a non-negative quantity (areas, powers, voltages)."""
    if val is None:
        return "<missing>"
    return f"{val * scale:.{precision}f}{suffix}"


def main(path: str) -> int:
    with open(path) as f:
        m = json.load(f)

    print(f"=== PPA summary: {path} ===")
    print()

    print("Timing (WNS = worst negative slack across all paths in the corner):")
    print(f"  setup, max_tt_025C_1v80 (typical):     {signed(get(m, 'timing__setup__wns__corner:max_tt_025C_1v80'))}")
    print(f"  setup, max_ss_100C_1v60 (worst slow):  {signed(get(m, 'timing__setup__wns__corner:max_ss_100C_1v60'))}")
    print(f"  setup, max_ff_n40C_1v95 (worst fast):  {signed(get(m, 'timing__setup__wns__corner:max_ff_n40C_1v95'))}")
    print(f"  hold,  max_ss_100C_1v60:               {signed(get(m, 'timing__hold__wns__corner:max_ss_100C_1v60'))}")
    print()

    print("Area (post-route):")
    print(f"  core area:           {unsigned(get(m, 'design__core__area'), ' um^2')}")
    print(f"  die area:            {unsigned(get(m, 'design__die__area'), ' um^2')}")
    util = get(m, 'design__instance__utilization__stdcell')
    print(f"  stdcell utilization: {f'{util:.1%}' if util is not None else '<missing>'}")
    print()

    print("Cell area breakdown (instance area by class, post-route):")
    for cls in ("sequential_cell", "multi_input_combinational_cell",
                "inverter", "clock_buffer", "timing_repair_buffer",
                "fill_cell", "tap_cell"):
        v = get(m, f'design__instance__area__class:{cls}')
        if v is not None:
            print(f"  {cls:<35} {v:>10.1f} um^2")
    print()

    print("Power (nominal corner):")
    print(f"  total:     {unsigned(get(m, 'power__total'),           ' mW', precision=3, scale=1_000)}")
    print(f"  internal:  {unsigned(get(m, 'power__internal__total'), ' mW', precision=3, scale=1_000)}")
    print(f"  switching: {unsigned(get(m, 'power__switching__total'),' mW', precision=3, scale=1_000)}")
    print(f"  leakage:   {unsigned(get(m, 'power__leakage__total'),  ' uW', precision=3, scale=1_000_000)}")
    print()

    print("IR drop (nominal corner):")
    print(f"  worst VPWR drop: {unsigned(get(m, 'design_powergrid__drop__worst__net:VPWR__corner:nom_tt_025C_1v80'), ' V', precision=4)}")
    print(f"  worst VGND drop: {unsigned(get(m, 'design_powergrid__drop__worst__net:VGND__corner:nom_tt_025C_1v80'), ' V', precision=4)}")

    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path-to-final/metrics.json>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
