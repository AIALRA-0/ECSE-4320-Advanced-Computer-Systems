## 2. Zero-Queue Baseline

### 2.3 Results (Mean ± Std, ns/access)

| level   |    read |   write |
|:--------|--------:|--------:|
| DRAM    | 103.573 | 216.993 |
| L1      |   4.543 | 250.833 |
| L2      |   6.208 | 246.193 |
| L3      |  25.218 | 203.929 |

Standard deviation:

| level   |   read |   write |
|:--------|-------:|--------:|
| DRAM    | 58.856 |   1.122 |
| L1      |  0.02  |   9.432 |
| L2      |  0.035 |  23.467 |
| L3      |  0.25  |   2.202 |

![ZeroQ](../figs/sec2/zeroq_latency_bar.png)

### 2.4 Analysis

- Latency increases with hierarchy level (L1 < L2 < L3 < DRAM).
- Write operations slower due to write-allocate & flush.
- Error bars represent run-to-run variability (stddev).
- Verify conversion: ns = cycles × 1000 / CPU_MHz.
