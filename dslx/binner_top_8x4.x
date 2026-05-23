// Concrete top-level instantiation of `binner` for M2 (and the smallest sweep point):
//   BW_GLOBAL = 8, N_BOUNDS = 4, BW_BIN = ceil(log2(4)) = 2.
// IR conversion requires a non-parametric top; this file supplies it.
import binner;

pub fn binner_top(
    global_index: u8,
    lower_bin_boundaries: u8[4],
) -> (u2, u8) {
    binner::binner<u32:8, u32:4, u32:2>(global_index, lower_bin_boundaries)
}
