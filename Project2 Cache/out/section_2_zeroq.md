## 2. Zero-Queue Baseline

### 2.3 Results

| level   |   read |   write |
|:--------|-------:|--------:|
| DRAM    | 54.973 | 299.441 |
| L1      |  2.686 | 340.803 |
| L2      |  8.5   | 339.633 |
| L3      | 33.856 | 273.229 |

![ZeroQ](../figs/sec2/zeroq_latency_bar.png)

### 2.4 Analysis

- L1 < L2 < L3 < DRAM as expected; writes slower due to write-allocate & clflush.
- Cross-check ns ~= cycles * 1000 / CPU_MHz using Section 1 frequency snapshot.
