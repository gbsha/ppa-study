// Binning function: classifies `global_index` into one of N_BOUNDS bins
// defined by `lower_bin_boundaries`, and returns the offset within that bin.
// See README.md for the semantic contract; in short:
//   - lower_bin_boundaries[0] is the lower edge of bin 0.
//   - N_BOUNDS array entries map 1:1 to N_BOUNDS bins; the last bin extends
//     to infinity.
//   - Inactive entries (per the runtime active-count) hold a sentinel value
//     strictly greater than any global_index the firmware will ever issue,
//     so the comparison never increments bin_index for them. The hardware has
//     no notion of a sentinel — this is just how firmware disables a bin.
//     Because thresholds are BW_GLOBAL-wide (same width as global_index), the
//     largest representable value 2**BW_GLOBAL - 1 is reserved as that sentinel,
//     making it a firmware contract:  0 <= global_index <= 2**BW_GLOBAL - 2.
//     (To make the sentinel safe across the FULL global_index range instead,
//     widen thresholds to BW_GLOBAL+1 bits — a deliberate PPA trade, see PLAN.)
//
// BW_BIN defaults to ceil(log2(N_BOUNDS)) via std::clog2; callers may override
// it (the tests below pass it explicitly to pin the bin-index width).
import std;

pub fn binner<BW_GLOBAL: u32, N_BOUNDS: u32, BW_BIN: u32 = {std::clog2(N_BOUNDS)}>(
    global_index: uN[BW_GLOBAL],
    lower_bin_boundaries: uN[BW_GLOBAL][N_BOUNDS],
) -> (uN[BW_BIN], uN[BW_GLOBAL]) {
    let bin_index = for (i, count): (u32, uN[BW_BIN]) in u32:1..N_BOUNDS {
        if global_index >= lower_bin_boundaries[i] {
            count + uN[BW_BIN]:1
        } else {
            count
        }
    }(uN[BW_BIN]:0);
    let local_index = global_index - lower_bin_boundaries[bin_index];
    (bin_index, local_index)
}

// THERMOMETER.md Sketch B: build the comparison vector explicitly, then derive
// bin_index via ctz(!cmps). Under the monotonicity contract on
// lower_bin_boundaries (a firmware invariant), cmps is thermometer-coded with
// k = bin_index ones, so ctz(!cmps) returns exactly the bin index — boundary
// cases line up naturally:
//   - all bins exceeded → cmps = 111…1 → !cmps = 0 → ctz returns NM1 = N_BOUNDS-1
//   - no bins exceeded  → cmps = 0     → !cmps = 111…1 → ctz returns 0.
// Trades the linear conditional-add fold for a log-depth priority-encoder tree.
// The threshold lookup (array_index) and the local_index subtract are unchanged.
pub fn binner_prio<
    BW_GLOBAL: u32, N_BOUNDS: u32,
    BW_BIN: u32 = {std::clog2(N_BOUNDS)},
    NM1: u32 = {N_BOUNDS - u32:1}
>(
    global_index: uN[BW_GLOBAL],
    lower_bin_boundaries: uN[BW_GLOBAL][N_BOUNDS],
) -> (uN[BW_BIN], uN[BW_GLOBAL]) {
    let cmps = for (i, acc): (u32, uN[NM1]) in u32:0..NM1 {
        let bit = (global_index >= lower_bin_boundaries[i + u32:1]) as uN[NM1];
        acc | (bit << i)
    }(uN[NM1]:0);
    let bin_index = ctz(!cmps) as uN[BW_BIN];
    let local_index = global_index - lower_bin_boundaries[bin_index];
    (bin_index, local_index)
}

#[test]
fn test_basic_8bit_4bins() {
    // bins: [0,10), [10,20), [20,30), [30,inf)
    let bounds = u8[4]:[0, 10, 20, 30];
    assert_eq(binner<u32:8, u32:4, u32:2>(u8:0,   bounds), (u2:0, u8:0));
    assert_eq(binner<u32:8, u32:4, u32:2>(u8:5,   bounds), (u2:0, u8:5));
    assert_eq(binner<u32:8, u32:4, u32:2>(u8:9,   bounds), (u2:0, u8:9));
    assert_eq(binner<u32:8, u32:4, u32:2>(u8:10,  bounds), (u2:1, u8:0));
    assert_eq(binner<u32:8, u32:4, u32:2>(u8:15,  bounds), (u2:1, u8:5));
    assert_eq(binner<u32:8, u32:4, u32:2>(u8:20,  bounds), (u2:2, u8:0));
    assert_eq(binner<u32:8, u32:4, u32:2>(u8:29,  bounds), (u2:2, u8:9));
    assert_eq(binner<u32:8, u32:4, u32:2>(u8:30,  bounds), (u2:3, u8:0));
    assert_eq(binner<u32:8, u32:4, u32:2>(u8:255, bounds), (u2:3, u8:225));
}

#[test]
fn test_sentinel_inactive_entries() {
    // Two active bins; entries [2] and [3] are inactive (sentinel=255,
    // global_index < 255 by contract).
    let bounds = u8[4]:[0, 10, 255, 255];
    assert_eq(binner<u32:8, u32:4, u32:2>(u8:5,   bounds), (u2:0, u8:5));
    assert_eq(binner<u32:8, u32:4, u32:2>(u8:15,  bounds), (u2:1, u8:5));
    assert_eq(binner<u32:8, u32:4, u32:2>(u8:200, bounds), (u2:1, u8:190));
}

#[test]
fn test_only_bin0_active() {
    // Only bin 0 active; everything maps to bin 0 and local_index == global_index.
    let bounds = u8[4]:[0, 255, 255, 255];
    assert_eq(binner<u32:8, u32:4, u32:2>(u8:0,   bounds), (u2:0, u8:0));
    assert_eq(binner<u32:8, u32:4, u32:2>(u8:100, bounds), (u2:0, u8:100));
    assert_eq(binner<u32:8, u32:4, u32:2>(u8:254, bounds), (u2:0, u8:254));
}

#[test]
fn test_nonzero_bin0_lower_edge() {
    // lower_bin_boundaries[0] is not required to be zero; it's just the lower
    // edge of bin 0. global_index < that edge still lands in bin 0 with a
    // wrap-around local_index (firmware contract: don't issue global < lbb[0]).
    let bounds = u8[3]:[16, 32, 48];
    assert_eq(binner<u32:8, u32:3, u32:2>(u8:16, bounds), (u2:0, u8:0));
    assert_eq(binner<u32:8, u32:3, u32:2>(u8:31, bounds), (u2:0, u8:15));
    assert_eq(binner<u32:8, u32:3, u32:2>(u8:32, bounds), (u2:1, u8:0));
    assert_eq(binner<u32:8, u32:3, u32:2>(u8:47, bounds), (u2:1, u8:15));
    assert_eq(binner<u32:8, u32:3, u32:2>(u8:48, bounds), (u2:2, u8:0));
}

#[test]
fn test_2bins_minimal() {
    // Smallest non-trivial: 2 entries -> 2 bins, clog2(2)=1 -> u1 bin_index.
    let bounds = u8[2]:[0, 100];
    assert_eq(binner<u32:8, u32:2, u32:1>(u8:0,   bounds), (u1:0, u8:0));
    assert_eq(binner<u32:8, u32:2, u32:1>(u8:99,  bounds), (u1:0, u8:99));
    assert_eq(binner<u32:8, u32:2, u32:1>(u8:100, bounds), (u1:1, u8:0));
    assert_eq(binner<u32:8, u32:2, u32:1>(u8:200, bounds), (u1:1, u8:100));
}

#[test]
fn test_wider_global_index() {
    // 16-bit global_index with 5 bins to exercise wider arithmetic.
    let bounds = u16[5]:[0, 1000, 2000, 3000, 4000];
    assert_eq(binner<u32:16, u32:5, u32:3>(u16:0,    bounds), (u3:0, u16:0));
    assert_eq(binner<u32:16, u32:5, u32:3>(u16:1500, bounds), (u3:1, u16:500));
    assert_eq(binner<u32:16, u32:5, u32:3>(u16:3999, bounds), (u3:3, u16:999));
    assert_eq(binner<u32:16, u32:5, u32:3>(u16:4000, bounds), (u3:4, u16:0));
    assert_eq(binner<u32:16, u32:5, u32:3>(u16:5000, bounds), (u3:4, u16:1000));
}

// Equivalence tests for binner_prio: same inputs as the reference tests above,
// asserting binner_prio produces the same (bin_index, local_index) as binner.

#[test]
fn test_prio_basic_8bit_4bins() {
    let bounds = u8[4]:[0, 10, 20, 30];
    assert_eq(binner_prio<u32:8, u32:4, u32:2>(u8:0,   bounds), (u2:0, u8:0));
    assert_eq(binner_prio<u32:8, u32:4, u32:2>(u8:5,   bounds), (u2:0, u8:5));
    assert_eq(binner_prio<u32:8, u32:4, u32:2>(u8:9,   bounds), (u2:0, u8:9));
    assert_eq(binner_prio<u32:8, u32:4, u32:2>(u8:10,  bounds), (u2:1, u8:0));
    assert_eq(binner_prio<u32:8, u32:4, u32:2>(u8:15,  bounds), (u2:1, u8:5));
    assert_eq(binner_prio<u32:8, u32:4, u32:2>(u8:20,  bounds), (u2:2, u8:0));
    assert_eq(binner_prio<u32:8, u32:4, u32:2>(u8:29,  bounds), (u2:2, u8:9));
    assert_eq(binner_prio<u32:8, u32:4, u32:2>(u8:30,  bounds), (u2:3, u8:0));
    assert_eq(binner_prio<u32:8, u32:4, u32:2>(u8:255, bounds), (u2:3, u8:225));
}

#[test]
fn test_prio_sentinel_inactive_entries() {
    let bounds = u8[4]:[0, 10, 255, 255];
    assert_eq(binner_prio<u32:8, u32:4, u32:2>(u8:5,   bounds), (u2:0, u8:5));
    assert_eq(binner_prio<u32:8, u32:4, u32:2>(u8:15,  bounds), (u2:1, u8:5));
    assert_eq(binner_prio<u32:8, u32:4, u32:2>(u8:200, bounds), (u2:1, u8:190));
}

#[test]
fn test_prio_only_bin0_active() {
    let bounds = u8[4]:[0, 255, 255, 255];
    assert_eq(binner_prio<u32:8, u32:4, u32:2>(u8:0,   bounds), (u2:0, u8:0));
    assert_eq(binner_prio<u32:8, u32:4, u32:2>(u8:100, bounds), (u2:0, u8:100));
    assert_eq(binner_prio<u32:8, u32:4, u32:2>(u8:254, bounds), (u2:0, u8:254));
}

#[test]
fn test_prio_nonzero_bin0_lower_edge() {
    let bounds = u8[3]:[16, 32, 48];
    assert_eq(binner_prio<u32:8, u32:3, u32:2>(u8:16, bounds), (u2:0, u8:0));
    assert_eq(binner_prio<u32:8, u32:3, u32:2>(u8:31, bounds), (u2:0, u8:15));
    assert_eq(binner_prio<u32:8, u32:3, u32:2>(u8:32, bounds), (u2:1, u8:0));
    assert_eq(binner_prio<u32:8, u32:3, u32:2>(u8:47, bounds), (u2:1, u8:15));
    assert_eq(binner_prio<u32:8, u32:3, u32:2>(u8:48, bounds), (u2:2, u8:0));
}

#[test]
fn test_prio_2bins_minimal() {
    let bounds = u8[2]:[0, 100];
    assert_eq(binner_prio<u32:8, u32:2, u32:1>(u8:0,   bounds), (u1:0, u8:0));
    assert_eq(binner_prio<u32:8, u32:2, u32:1>(u8:99,  bounds), (u1:0, u8:99));
    assert_eq(binner_prio<u32:8, u32:2, u32:1>(u8:100, bounds), (u1:1, u8:0));
    assert_eq(binner_prio<u32:8, u32:2, u32:1>(u8:200, bounds), (u1:1, u8:100));
}

#[test]
fn test_prio_wider_global_index() {
    let bounds = u16[5]:[0, 1000, 2000, 3000, 4000];
    assert_eq(binner_prio<u32:16, u32:5, u32:3>(u16:0,    bounds), (u3:0, u16:0));
    assert_eq(binner_prio<u32:16, u32:5, u32:3>(u16:1500, bounds), (u3:1, u16:500));
    assert_eq(binner_prio<u32:16, u32:5, u32:3>(u16:3999, bounds), (u3:3, u16:999));
    assert_eq(binner_prio<u32:16, u32:5, u32:3>(u16:4000, bounds), (u3:4, u16:0));
    assert_eq(binner_prio<u32:16, u32:5, u32:3>(u16:5000, bounds), (u3:4, u16:1000));
}

// Equivalence properties (random global_index, fixed monotonic bound arrays).
// Generating sorted arrays with quickcheck would need a sort or prefix-sum
// helper; pinning the bounds and varying global_index gives strong coverage
// of the bin_index/ctz boundary cases for the cost of a single property.

#[quickcheck]
fn prop_prio_matches_ref_8bit_4bins(global_index: u8) -> bool {
    let bounds = u8[4]:[0, 10, 20, 30];
    binner_prio<u32:8, u32:4, u32:2>(global_index, bounds) ==
        binner<u32:8, u32:4, u32:2>(global_index, bounds)
}

#[quickcheck]
fn prop_prio_matches_ref_16bit_5bins(global_index: u16) -> bool {
    let bounds = u16[5]:[0, 1000, 2000, 3000, 4000];
    binner_prio<u32:16, u32:5, u32:3>(global_index, bounds) ==
        binner<u32:16, u32:5, u32:3>(global_index, bounds)
}
