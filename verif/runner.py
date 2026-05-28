#!/usr/bin/env python3
"""cocotb runner — drive verif/test_binner.py against one codegen binner.v.

Reads `point.json` next to the verilog (when present) to pick up bw_global,
n_bounds, variant, and pipeline_stages. CLI flags override.

Self-contained: simulators (iverilog, verilator) live in the same conda env
as cocotb itself, so this script has no librelane / nix-shell dependency.
"""
import argparse
import json
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner, get_results


def main():
    here = Path(__file__).resolve().parent

    ap = argparse.ArgumentParser(description="cocotb runner for binner_top")
    ap.add_argument("--verilog", type=Path, required=True,
                    help="path to binner.v (one codegen point's output)")
    ap.add_argument("--bw-global", type=int, default=None,
                    help="override bw_global (default: read from point.json)")
    ap.add_argument("--n-bounds", type=int, default=None,
                    help="override n_bounds (default: read from point.json)")
    ap.add_argument("--stages", type=int, default=None,
                    help="override pipeline_stages (default: from point.json or 1)")
    ap.add_argument("--simulator", default="icarus", choices=("icarus", "verilator"))
    ap.add_argument("--num-bound-sets", type=int, default=256,
                    help="random bound configurations to try (default: 256)")
    ap.add_argument("--trials-per-set", type=int, default=16,
                    help="random global_index values per bound set (default: 16)")
    ap.add_argument("--seed", type=int, default=0, help="RNG seed (default: 0)")
    ap.add_argument("--build-dir", type=Path, default=None,
                    help="cocotb build dir (default: <verilog_dir>/verif_sim_build)")
    ap.add_argument("--waves", action="store_true", help="dump VCD/FST")
    args = ap.parse_args()

    if not args.verilog.exists():
        ap.error(f"--verilog path does not exist: {args.verilog}")

    point_json = args.verilog.parent / "point.json"
    p = json.load(open(point_json)) if point_json.exists() else {}
    bw = args.bw_global if args.bw_global is not None else p.get("bw_global")
    nb = args.n_bounds  if args.n_bounds  is not None else p.get("n_bounds")
    stages = args.stages if args.stages is not None else p.get("pipeline_stages", 1)
    if bw is None or nb is None:
        ap.error("--bw-global and --n-bounds required when no point.json sits "
                 f"next to {args.verilog}")

    build_dir = (args.build_dir or (args.verilog.parent / "verif_sim_build")).resolve()
    build_dir.mkdir(parents=True, exist_ok=True)

    print(f"[verif] simulator={args.simulator} verilog={args.verilog}")
    print(f"[verif] bw={bw} nb={nb} stages={stages} "
          f"sets={args.num_bound_sets} trials/set={args.trials_per_set} seed={args.seed}")

    # iverilog default precision is too coarse for a 10 ns clock; set timescale
    # explicitly so the 10 ns period is representable in 1 ps steps.
    timescale = ("1ns", "1ps")

    runner = get_runner(args.simulator)
    runner.build(
        verilog_sources=[args.verilog],
        hdl_toplevel="binner_top",
        build_dir=build_dir,
        waves=args.waves,
        timescale=timescale,
        always=True,
    )
    results_xml = runner.test(
        hdl_toplevel="binner_top",
        test_module="test_binner",
        test_dir=here,
        build_dir=build_dir,
        # Direct the xUnit results to the build dir so the verif/ source tree
        # stays clean (default would have put results.xml next to the runner).
        results_xml=str(build_dir / "results.xml"),
        extra_env={
            "BW_GLOBAL":       str(bw),
            "N_BOUNDS":        str(nb),
            "PIPELINE_STAGES": str(stages),
            "NUM_BOUND_SETS":  str(args.num_bound_sets),
            "TRIALS_PER_SET":  str(args.trials_per_set),
            "SEED":            str(args.seed),
        },
        waves=args.waves,
        timescale=timescale,
    )
    n_tests, n_failed = get_results(results_xml)
    if n_failed:
        print(f"[verif] FAIL — {n_failed}/{n_tests} tests failed (results: {results_xml})",
              file=sys.stderr)
        return 1
    print(f"[verif] OK — {n_tests}/{n_tests} tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
