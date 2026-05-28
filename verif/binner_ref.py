"""Canonical Python reference for the binner function.

Mirrors `README.md` (the spec) and `dslx/binner.x:binner` (the hardware
reference). Imported by `test_binner.py` for cycle-by-cycle DUT comparison.

Contract: `lower_bin_boundaries` is strictly monotonically increasing
(firmware invariant). Inactive entries hold a sentinel value strictly
greater than any global_index the firmware will ever issue — see the
README for the full contract.
"""
from typing import Sequence


def binner(global_index: int, lower_bin_boundaries: Sequence[int]) -> tuple[int, int]:
    bin_index = 0
    for threshold in lower_bin_boundaries[1:]:
        if global_index >= threshold:
            bin_index += 1
    local_index = global_index - lower_bin_boundaries[bin_index]
    return bin_index, local_index


if __name__ == "__main__":
    # Selftest mirrors a subset of dslx/binner.x test cases — run with
    # `python verif/binner_ref.py` to confirm the reference matches the spec.
    assert binner(0,   [0, 10, 20, 30]) == (0, 0)
    assert binner(9,   [0, 10, 20, 30]) == (0, 9)
    assert binner(10,  [0, 10, 20, 30]) == (1, 0)
    assert binner(15,  [0, 10, 20, 30]) == (1, 5)
    assert binner(255, [0, 10, 20, 30]) == (3, 225)
    assert binner(200, [0, 10, 255, 255]) == (1, 190)  # sentinel inactive entries
    assert binner(31,  [16, 32, 48])     == (0, 15)    # nonzero bin0 lower edge
    assert binner(1500, [0, 1000, 2000, 3000, 4000]) == (1, 500)
    print("binner_ref selftest OK")
