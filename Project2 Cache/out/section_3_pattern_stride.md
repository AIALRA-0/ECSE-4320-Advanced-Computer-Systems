## 3. Pattern & Stride Sweep (Latency & Bandwidth)

### 3.3 Results (Mean ± Std)

**Mean Latency (ns/access)**
| stride_B | rand | seq |
| --- | --- | --- |
| 64 | 90.189 | 6.495 |
| 256 | 118.741 | 5.974 |
| 1024 | 129.238 | 5.884 |

**StdDev Latency (ns/access)**
| stride_B | rand | seq |
| --- | --- | --- |
| 64 | 0.325 | 0.458 |
| 256 | 1.95 | 0.029 |
| 1024 | 7.54 | 0.055 |

**Mean Bandwidth (GB/s)**
| stride_B | rand | seq |
| --- | --- | --- |
| 64 | 2.165 | 14.492 |
| 256 | 5.505 | 41.451 |
| 1024 | 11.082 | 37.255 |

**StdDev Bandwidth (GB/s)**
| stride_B | rand | seq |
| --- | --- | --- |
| 64 | 0.007 | 0.445 |
| 256 | 0.08 | 1.023 |
| 1024 | 0.532 | 0.706 |

![Latency](../figs/sec3/latency_vs_stride.png)

![Bandwidth](../figs/sec3/bandwidth_vs_stride.png)

### 3.4 Result Analysis

- **Prefetch & stride effects**: smaller strides and sequential access enable HW prefetchers and DRAM row-buffer hits, reducing latency and boosting bandwidth.
- **Random & larger strides**: reduce prefetch efficacy, increase row misses and TLB pressure → higher latency and lower bandwidth.
- **Error bars** represent run-to-run variability (std) over REPEAT trials.
