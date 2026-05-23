# Readme

For power, performance, area (PPA) driven development, code is written in DSLX (part of google's XLS SDK, see below), compiled to verilog, synthesized by librelane, and then PPA metrics are collected.

## Study objective

Consider the following python code:
```python
def fun(global_index: int, upper_bin_boundaries: list[int]) -> int:
    bin_index: int = 0
    for threshold in upper_bin_boundaries:
        if global_index >= threshold:
            bin_index += 1
    local_index: int = global_index - upper_bin_boundaries[bin_index]
    return bin_index, local_index
```
The objective is to implement this function in hardware and do a detailed PPA analysis. 

### Constraints

The function is subject to the following constraints:

1. The buswidth `bw_global_index` of `global_index`, and thereby the buswidth of the entries of `upper_bin_boundaries` are buildtime parameters.
2. The thresholds in `upper_bin_boundaries` are runtime parameters programmable by firmware.
3. The number of entries `n_boundaries` of `upper_bin_boundaries` is defined at buildtime, and the number of active entries of `upper_bin_boundaries` is defined at runtime, so a sentinel has to be defined that is never surpassed by `global_index` for the inactive entries.
4. In a refinement, the thresholds in `upper_bin_boundaries` are constrained to be of the form `threshold_i_m << threshold_e`, where the maximum bitwidth `bw_threshold` of `threshold_i_m` is defined at buildtime, and the value of `threshold_i_m` and `threshold_e` are programmable by firmware. The value `threshold_e` is shared by all entries of `upper_bin_boundaries`. This refinement allows to reduce the cost of the comparison, as in each comparison only `bw_threshold` bits need to be compared.

### Analysis

The objective is to do a thorough analysis, to see how performance (throughput, latency, precision), power, and area scale with the buildtime parameters `bw_global_index`, `n_boundaries`, and `bw_threshold`.

For instance, one can imagine three realizations of the python loop:
* Time division multiplexing (TDM): one single comparator realizes all comparisons. Wet finger guess: Low throughput, high latency, low area.
* Pipelining: `n_boundaries` many comparators are used serially. Wet finger guess: High throughput, high latency, high area, moderate wiring.
* Parallelization: `n_boundaries` many comparators are used in parallel (thermometer code). Wet finger guess: high throughput, low latency, high area, high wiring.

The objective is to assess whether (qualitatively) and how much (quantitatively) these wet finger guesses manifest themselves in synthesized hardware.

## Enter the environment with your copilot

```
cd /PATH/TO/YOUR/LIBRELANE
nix-shell
cd /PATH/TO/THIS_REPOSITORY
claude
```

## Install Tools

### Librelane

Use nix-based librelane installation following
* https://librelane.readthedocs.io/en/latest/installation/nix_installation/installation_linux.html

### Google's XLS: Accelerated HW Synthesis

Documentation can be found at
* https://google.github.io/
* https://github.com/google/xls/

The `google/xls` github repository is locally cloned to `external/xls`, for locally having access to the documentation and dslx language specification. Note that `external/xls` does **not** contain the binaries.

Install the binaries statically compiled from https://github.com/gbsha/xls-bin/ by
```
mkdir -p ./external/xls-bin && cd ./external/xls-bin

curl -L -O https://github.com/gbsha/xls-bin/releases/download/v1.0-xls-oracle8/xls-oracle8-binaries.tar.gz
tar -xzf xls-oracle8-binaries.tar.gz
chmod +x *
```
