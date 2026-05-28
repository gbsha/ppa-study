"""cocotb testbench for binner_top — compares each cycle against binner_ref.

Parametric via env vars (set by verif/runner.py per design point):
  BW_GLOBAL        — bitwidth of global_index and each threshold
  N_BOUNDS         — number of bins (>= 2)
  PIPELINE_STAGES  — pipeline_stages parameter (1 = 'parallel' arch); latency
                     from input drive to output sample is PIPELINE_STAGES + 1.
  NUM_BOUND_SETS   — number of random bound configurations  (default 256)
  TRIALS_PER_SET   — random global_index values per bound set (default 16)
  SEED             — RNG seed (default 0)

Bus packing (verified against the XLS codegen output, see COCOTB.md §3.1):
  lower_bin_boundaries — packed LSB-first, element i at bits[BW*(i+1)-1 : BW*i].
  out                  — {bin_index[BW_BIN-1:0], local_index[BW_GLOBAL-1:0]}.
"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

import binner_ref


# --- bus packing / unpacking -------------------------------------------------

def pack_bounds(bounds, bw):
    mask = (1 << bw) - 1
    word = 0
    for i, b in enumerate(bounds):
        word |= (b & mask) << (bw * i)
    return word


def unpack_out(value, bw_global, bw_bin):
    v = int(value)
    local_index = v & ((1 << bw_global) - 1)
    bin_index = (v >> bw_global) & ((1 << bw_bin) - 1)
    return bin_index, local_index


# --- stimulus ---------------------------------------------------------------

def bounds_via_deltas(bw, nb, rng):
    """Cumulative-sum of positive deltas — gives clustered patterns."""
    max_val = (1 << bw) - 2  # firmware contract: global_index <= 2^bw - 2
    span = max(1, max_val // max(1, nb))
    bounds = [rng.randint(0, span)]
    for _ in range(nb - 1):
        nxt = bounds[-1] + rng.randint(1, span)
        bounds.append(min(nxt, max_val))
    # Strict monotonicity: if a delta got clipped, sentinel-fill the rest.
    sentinel = (1 << bw) - 1
    for i in range(1, len(bounds)):
        if bounds[i] <= bounds[i - 1]:
            bounds[i] = sentinel
    return bounds


def bounds_via_sorted(bw, nb, rng):
    """Sorted unique draws — gives evenly-spread patterns."""
    universe = (1 << bw) - 1  # 0 .. max_val inclusive
    if nb <= universe:
        sample = sorted(rng.sample(range(universe), nb))
    else:
        # Degenerate at tiny bw — pad with sentinel.
        sample = sorted(range(universe)) + [(1 << bw) - 1] * (nb - universe)
    return sample


def gen_bounds(bw, nb, rng):
    """50/50 mix of deltas (clustered) and sorted draws (even spread)."""
    return (bounds_via_deltas if rng.random() < 0.5 else bounds_via_sorted)(bw, nb, rng)


# --- the test ---------------------------------------------------------------

@cocotb.test()
async def binner_random_vectors(dut):
    bw = int(os.environ["BW_GLOBAL"])
    nb = int(os.environ["N_BOUNDS"])
    stages = int(os.environ.get("PIPELINE_STAGES", "1"))
    n_sets = int(os.environ.get("NUM_BOUND_SETS", "256"))
    trials = int(os.environ.get("TRIALS_PER_SET", "16"))
    seed = int(os.environ.get("SEED", "0"))
    bw_bin = max(1, (nb - 1).bit_length())  # clog2(nb), floor 1 for the degenerate nb<=1
    # Effective latency from `dut.X.value = ...` to a settled `dut.out.value` read:
    # XLS codegen has stages+1 flop stages (input + (stages-1) inner + output);
    # cocotb-on-iverilog adds one extra edge because vpi_put_value lands AFTER the
    # current edge's active region, so the very next RisingEdge captures the OLD
    # input value. One more edge to compensate (verified empirically — see commit
    # message). For stages=1 this gives latency=3 edges per drive.
    latency = stages + 2

    rng = random.Random(seed)
    dut._log.info(
        f"bw={bw} nb={nb} bw_bin={bw_bin} stages={stages} latency={latency} "
        f"sets={n_sets} trials/set={trials} seed={seed}"
    )

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # Synchronous reset (XLS --reset=rst convention).
    dut.rst.value = 1
    dut.global_index.value = 0
    dut.lower_bin_boundaries.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    n_pass = 0
    for s in range(n_sets):
        bounds = gen_bounds(bw, nb, rng)
        packed = pack_bounds(bounds, bw)
        dut.lower_bin_boundaries.value = packed
        for _ in range(trials):
            # Firmware contract (README): bounds[0] <= global_index <= sentinel-1.
            # Below bounds[0] the local_index wraps around (modular sub) on the
            # hardware side but Python returns a negative int — pulling stimulus
            # into the contract avoids the apples-vs-oranges mismatch.
            gi = rng.randint(bounds[0], (1 << bw) - 2)
            dut.global_index.value = gi
            await ClockCycles(dut.clk, latency)
            ref_bin, ref_loc = binner_ref.binner(gi, bounds)
            got_bin, got_loc = unpack_out(dut.out.value, bw, bw_bin)
            assert (got_bin, got_loc) == (ref_bin, ref_loc), (
                f"set={s} trial: bw={bw} nb={nb} global={gi} bounds={bounds}\n"
                f"  ref=(bin={ref_bin}, loc={ref_loc})\n"
                f"  dut=(bin={got_bin}, loc={got_loc})"
            )
            n_pass += 1
    dut._log.info(f"PASS — {n_pass} vectors checked")
