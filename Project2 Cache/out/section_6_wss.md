## 6. Working-Set Size Sweep (Locality Transitions)

### 6.3 Results (mean ± std, ns/access)

|   KiB |   count |   mean |    std |
|------:|--------:|-------:|-------:|
|    16 |       3 |  3.459 |  0.022 |
|    32 |       3 |  3.775 |  0.076 |
|    64 |       3 |  3.783 |  0.066 |
|   128 |       3 |  5.162 |  0.09  |
|   256 |       3 |  7.049 |  0.179 |
|   512 |       3 |  6.372 |  2.032 |
|  1024 |       3 | 11.242 |  1.988 |
|  2048 |       3 |  8.926 |  0.064 |
|  4096 |       3 |  9.951 |  0.734 |
|  8192 |       3 | 16.042 |  1.601 |
| 16384 |       3 | 25.763 |  4.609 |
| 32768 |       3 | 52.641 | 21.87  |
| 65536 |       3 | 43.226 | 20.441 |

![wss](../figs/sec6/wss_curve.png)

### 6.4 Analysis

- As the working set grows, latency steps up near L1/L2/L3 capacities.
- Error bars show run-to-run variability at each WSS; magnitudes align with Section 2 zero-queue latencies.
