#!/usr/bin/env python3
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import os

# Ensure output directory exists
os.makedirs("plots", exist_ok=True)

# Read scalar and SIMD experimental result CSVs
sc = pd.read_csv("data/scalar.csv")
si = pd.read_csv("data/simd.csv")

# Key columns: used to align during merge
key = ["kernel", "dtype", "n", "stride", "misalign"]

# Merge the two datasets for comparison (scalar vs SIMD)
m = pd.merge(sc, si, on=key, suffixes=("_sc", "_si"))

# Compute speedup = scalar_time / simd_time
m["speedup"] = m["time_ns_med_sc"] / m["time_ns_med_si"]

# Avoid division by zero / numerical instability
eps = 1e-12


# -------------------------------
# Cache annotation function
# -------------------------------
def add_cache_lines(dtype, kernel):
    bpe = {
        "saxpy": {"f32": 12, "f64": 24},
        "dot": {"f32": 8, "f64": 16},
        "mul": {"f32": 12, "f64": 24},
        "stencil": {"f32": 8, "f64": 16},
    }[kernel][dtype]

    # Machine cache capacities (bytes) — according to report: 48KiB / 2MiB / 36MiB
    L1 = 48 * 1024
    L2 = 2 * 1024 * 1024
    L3 = 36 * 1024 * 1024

    pts = {
        "L1->L2": max(1, L1 // bpe),
        "L2->LLC": max(1, L2 // bpe),
        "LLC->DRAM": max(1, L3 // bpe),
    }

    ytop = plt.ylim()[1]
    for lvl, n_pt in pts.items():
        plt.axvline(x=n_pt, color="red", ls="--", alpha=0.6)
        plt.text(
            n_pt,
            ytop * 0.9,
            lvl,
            rotation=90,
            color="red",
            ha="center",
            va="top",
            fontsize=8,
        )


# -------------------------------
# Plot speedup curve (Speedup vs N)
# -------------------------------
def plot_speedup(kernel, dtype):
    df = m[
        (m.kernel == kernel)
        & (m.dtype == dtype)
        & (m.stride == 1)
        & (m.misalign == 0)
    ].sort_values("n")
    if df.empty:
        return

    x = df["n"].to_numpy()
    y_med = df["speedup"].to_numpy()

    # Worst speedup = scalar_p95 / simd_p05
    # Best speedup = scalar_p05 / simd_p95
    y_low = (df["time_ns_p95_sc"].to_numpy()) / (df["time_ns_p05_si"].to_numpy() + eps)
    y_high = (df["time_ns_p05_sc"].to_numpy()) / (df["time_ns_p95_si"].to_numpy() + eps)

    # Numeric cleanup
    y_low = np.clip(y_low, 0, np.inf)
    y_high = np.clip(y_high, 0, np.inf)
    y_low[~np.isfinite(y_low)] = y_med[~np.isfinite(y_low)]
    y_high[~np.isfinite(y_high)] = y_med[~np.isfinite(y_high)]

    # ---- Order correction: ensure low <= high ----
    lo = np.minimum(y_low, y_high)
    hi = np.maximum(y_low, y_high)
    y_low, y_high = lo, hi

    # Print diagnostics
    print(f"\n[Speedup {kernel} {dtype}]")
    for i in range(len(x)):
        print(
            f"N={int(x[i])}, median={y_med[i]:.3f}, "
            f"low={y_low[i]:.3f}, high={y_high[i]:.3f}"
        )

    # Construct asymmetric error bars
    yerr = np.vstack([
        np.maximum(0.0, y_med - y_low),
        np.maximum(0.0, y_high - y_med),
    ])

    plt.figure()
    plt.title(f"Speedup SIMD vs Scalar ({kernel}, {dtype}, stride=1, aligned)")
    plt.xlabel("N (elements)")
    plt.ylabel("Speedup (scalar_time / simd_time)")
    plt.xscale("log")

    plt.errorbar(
        x, y_med, yerr=yerr,
        fmt="o-", capsize=4, elinewidth=1.2, markeredgewidth=1.2,
        color="blue", label="median ± (p05,p95)"
    )

    # Annotate key points (avoid cluttering with all)
    step = max(1, len(x)//6)  # pick around 6 points
    for xi, ym, yl, yh in zip(x[::step], y_med[::step], y_low[::step], y_high[::step]):
        plt.annotate(f"{ym:.2f}\n[{yl:.2f},{yh:.2f}]",
                     (xi, ym), textcoords="offset points", xytext=(0,5),
                     ha="center", fontsize=4, alpha=0.8)

    plt.grid(True, which="both", ls="--")
    add_cache_lines(dtype, kernel)
    plt.legend()
    plt.savefig(f"plots/speedup_{kernel}_{dtype}.png", dpi=160, bbox_inches="tight")
    plt.close()



# -------------------------------
# Plot GFLOP/s curve (GFLOP/s vs N)
# -------------------------------
def plot_gflops(kernel, dtype):
    d_sc = sc[
        (sc.kernel == kernel)
        & (sc.dtype == dtype)
        & (sc.stride == 1)
        & (sc.misalign == 0)
    ].sort_values("n")
    d_si = si[
        (si.kernel == kernel)
        & (si.dtype == dtype)
        & (si.stride == 1)
        & (si.misalign == 0)
    ].sort_values("n")
    if d_sc.empty or d_si.empty:
        return

    x_sc = d_sc["n"].to_numpy()
    x_si = d_si["n"].to_numpy()
    y_sc = d_sc["gflops"].to_numpy()
    y_si = d_si["gflops"].to_numpy()

    # From time percentiles, estimate gflops upper/lower bounds:
    # gflops = FLOPs / time
    # smaller time → higher gflops → upper bound from p05(time), lower bound from p95(time)
    # approximate upper bound: median * (med_time / p05_time), lower bound: median * (med_time / p95_time)
    y_low_sc = y_sc * d_sc["time_ns_med"].to_numpy() / (d_sc["time_ns_p95"].to_numpy() + eps)
    y_high_sc = y_sc * d_sc["time_ns_med"].to_numpy() / (d_sc["time_ns_p05"].to_numpy() + eps)
    y_low_si = y_si * d_si["time_ns_med"].to_numpy() / (d_si["time_ns_p95"].to_numpy() + eps)
    y_high_si = y_si * d_si["time_ns_med"].to_numpy() / (d_si["time_ns_p05"].to_numpy() + eps)

    # Numeric cleanup & protection
    for arr in (y_low_sc, y_high_sc, y_low_si, y_high_si):
        np.clip(arr, 0, np.inf, out=arr)
        bad = ~np.isfinite(arr)
        arr[bad] = (y_sc if arr is y_low_sc or arr is y_high_sc else y_si)[bad]

    # Print diagnostics
    print(f"\n[GFLOPS {kernel} {dtype}]")
    for i in range(len(x_sc)):
        print(
            f"N={int(x_sc[i])}, scalar median={y_sc[i]:.3f}, "
            f"low={y_low_sc[i]:.3f}, high={y_high_sc[i]:.3f}"
        )
    for i in range(len(x_si)):
        print(
            f"N={int(x_si[i])}, simd   median={y_si[i]:.3f}, "
            f"low={y_low_si[i]:.3f}, high={y_high_si[i]:.3f}"
        )

    # Error bars: lower/upper, ensure non-negative
    yerr_sc = np.vstack(
        [
            np.maximum(0.0, y_sc - y_low_sc),
            np.maximum(0.0, y_high_sc - y_sc),
        ]
    )
    yerr_si = np.vstack(
        [
            np.maximum(0.0, y_si - y_low_si),
            np.maximum(0.0, y_high_si - y_si),
        ]
    )

    plt.figure()
    plt.title(f"GFLOP/s vs N ({kernel}, {dtype})")
    plt.xlabel("N (elements)")
    plt.ylabel("GFLOP/s")
    plt.xscale("log")

    plt.errorbar(
        x_sc,
        y_sc,
        yerr=yerr_sc,
        fmt="o-",
        capsize=4,
        color="orange",
        label="scalar median ± (p05,p95)",
    )
    plt.errorbar(
        x_si,
        y_si,
        yerr=yerr_si,
        fmt="o-",
        capsize=4,
        color="blue",
        label="simd median ± (p05,p95)",
    )

    # Annotate scalar points
    for xi, ym, yl, yh in zip(x_sc, y_sc, y_low_sc, y_high_sc):
        plt.text(
            xi, ym * 1.05, f"{ym:.2f}\n[{yl:.2f},{yh:.2f}]",
            ha="center", va="bottom", fontsize=4, color="orange"
        )

    # Annotate SIMD points
    for xi, ym, yl, yh in zip(x_si, y_si, y_low_si, y_high_si):
        plt.text(
            xi, ym * 1.05, f"{ym:.2f}\n[{yl:.2f},{yh:.2f}]",
            ha="center", va="bottom", fontsize=5, color="blue"
        )


    plt.grid(True, which="both", ls="--")
    add_cache_lines(dtype, kernel)
    plt.legend()
    plt.savefig(f"plots/gflops_{kernel}_{dtype}.png", dpi=160, bbox_inches="tight")
    plt.close()


# -------------------------------
# Main loop
# -------------------------------
for k in ["saxpy", "dot", "mul", "stencil"]:
    for dt in ["f32", "f64"]:
        plot_speedup(k, dt)
        plot_gflops(k, dt)

print("Plots saved to plots/*.png with median ± (p05,p95) error bars")
