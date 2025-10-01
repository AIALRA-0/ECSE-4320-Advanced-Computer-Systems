#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Stride summary-based comprehensive bar chart generator
- Input: data/simd.csv
- Filter: verified=1, misalign=0, and stride ∈ {1,2,4,8}
- Continue generating summary (data/stride_abs.csv, data/stride_rel.csv, plots/stride/stride_summary.md)
- Representative N selection: for each dtype, choose the smallest N / median N / largest N (three levels, usually corresponding to L1/L2/DRAM)
- Output bar charts (for each kernel and each dtype, 2 charts each: GFLOP/s and CPE)
    Form: x = stride (1,2,4,8), within the same chart multiple bars distinguish different N (min/med/max)
- Additionally export aggregated CSV for plotting: data/stride_plotset.csv (for review)
"""

import argparse
from pathlib import Path
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt

plt.rcParams["figure.dpi"] = 120

# Read CSV
def load_df(path: Path) -> pd.DataFrame:
    if not path.exists():
        raise FileNotFoundError(f"Cannot find {path}")
    df = pd.read_csv(path)
    # Standardize GiBps column name (although this script doesn’t plot GiBps, keep naming consistent)
    df = df.rename(columns={c: ("GiBps" if c.lower()=="gibps" else c) for c in df.columns})
    return df

# Filter samples
def filter_ok(df: pd.DataFrame) -> pd.DataFrame:
    if "verified" in df.columns:
        df = df[df["verified"] == 1]
    if "misalign" in df.columns:
        df = df[df["misalign"] == 0]
    if "stride" in df.columns:
        df = df[df["stride"].isin([1,2,4,8])]
    cols_need = {"kernel","dtype","n","stride","gflops","cpe"}
    miss = cols_need - set(df.columns)
    if miss:
        raise ValueError(f"Missing columns: {miss}")
    return df.copy()

# Normalize (to stride=1)
def normalize_to_stride1(df: pd.DataFrame, col: str) -> pd.DataFrame:
    def _norm(g):
        if 1 not in set(g["stride"]):
            g[col + "_rel"] = np.nan
            return g
        base = g.loc[g["stride"]==1, col].values[0]
        g[col + "_rel"] = g[col] / base if (base and np.isfinite(base)) else np.nan
        return g
    return df.groupby(["kernel","dtype","n"], as_index=False).apply(_norm).reset_index(drop=True)

# Write Markdown summary
def write_md(df_abs: pd.DataFrame, df_rel: pd.DataFrame, out_md: Path):
    m = pd.merge(
        df_abs[["kernel","dtype","n","stride","gflops","cpe"]],
        df_rel[["kernel","dtype","n","stride","gflops_rel"]],
        on=["kernel","dtype","n","stride"],
        how="left"
    ).sort_values(["kernel","dtype","n","stride"])

    lines = []
    lines.append("### Stride Scan Summary (from data/simd.csv)")
    lines.append("")
    lines.append("| kernel | dtype | N | stride | GFLOP/s | CPE | GFLOP/s rel(s=1) |")
    lines.append("|---|---|---:|---:|---:|---:|---:|")
    for _, r in m.iterrows():
        lines.append(
            f"| {r['kernel']} | {r['dtype']} | {int(r['n'])} | {int(r['stride'])} | "
            f"{r['gflops']:.3f} | {r['cpe']:.3f} | "
            f"{(r['gflops_rel'] if pd.notna(r['gflops_rel']) else float('nan')):.3f} |"
        )
    out_md.write_text("\n".join(lines), encoding="utf-8")

# Select three representative N values for each dtype (min / median / max)
def pick_three_Ns(df: pd.DataFrame) -> dict:
    pick = {}
    for dt, g in df.groupby("dtype"):
        Ns = sorted(g["n"].unique().tolist())
        if not Ns:
            pick[dt] = []
            continue
        if len(Ns) == 1:
            pick[dt] = [Ns[0]]
        elif len(Ns) == 2:
            pick[dt] = [Ns[0], Ns[-1]]
        else:
            mid = Ns[len(Ns)//2]
            pick[dt] = [Ns[0], mid, Ns[-1]]
    return pick

# Generate grouped bar charts: show min/med/max three N values on same figure across strides for GFLOP/s or CPE
def plot_kernel_dtype_grouped_bars(df: pd.DataFrame, outdir: Path):
    outdir.mkdir(parents=True, exist_ok=True)

    # Select representative N
    Ns_by_dtype = pick_three_Ns(df)

    # Prepare a “visualization dataset” for plotting, also export to CSV for review
    plot_rows = []

    for (kernel, dtype), gkd in df.groupby(["kernel","dtype"]):
        Ns_pick = Ns_by_dtype.get(dtype, [])
        if not Ns_pick:
            continue
        # Keep only representative N
        part = gkd[gkd["n"].isin(Ns_pick)].copy()
        if part.empty:
            continue

        # Ensure stride order
        part = part.sort_values(["n","stride"])
        # Record into export set
        plot_rows.append(part)

        # Group by N, construct side-by-side bars
        Ns_sorted = sorted(part["n"].unique().tolist())
        strides = [1,2,4,8]
        x = np.arange(len(strides))
        width = 0.8 / max(1, len(Ns_sorted))  # bar width per group, leave some gap

        # GFLOP/s
        plt.figure(figsize=(7.8, 4.6))
        for i, N in enumerate(Ns_sorted):
            gi = part[(part["n"]==N) & (part["stride"].isin(strides))].sort_values("stride")
            y = gi["gflops"].to_numpy()
            # Align to strides sequence (avoid missing values)
            y_map = {int(s):v for s,v in zip(gi["stride"].astype(int).to_numpy(), y)}
            y_aligned = [y_map.get(s, np.nan) for s in strides]
            plt.bar(x + i*width, y_aligned, width=width, label=f"N={int(N)}")
            for xi, v in zip(x + i*width, y_aligned):
                if np.isfinite(v):
                    plt.text(xi, v, f"{v:.2f}", ha="center", va="bottom", fontsize=8)
        plt.xticks(x + (len(Ns_sorted)-1)*width/2, [str(s) for s in strides])
        plt.xlabel("Stride")
        plt.ylabel("GFLOP/s")
        plt.title(f"{kernel} {dtype} • GFLOP/s vs stride (per-N grouped)")
        plt.legend(title="N", fontsize=9)
        plt.tight_layout()
        plt.savefig(outdir / f"{kernel}_{dtype}_gflops_grouped_by_stride.png")
        plt.close()

        # CPE
        plt.figure(figsize=(7.8, 4.6))
        for i, N in enumerate(Ns_sorted):
            gi = part[(part["n"]==N) & (part["stride"].isin(strides))].sort_values("stride")
            y = gi["cpe"].to_numpy()
            y_map = {int(s):v for s,v in zip(gi["stride"].astype(int).to_numpy(), y)}
            y_aligned = [y_map.get(s, np.nan) for s in strides]
            plt.bar(x + i*width, y_aligned, width=width, label=f"N={int(N)}")
            for xi, v in zip(x + i*width, y_aligned):
                if np.isfinite(v):
                    plt.text(xi, v, f"{v:.2f}", ha="center", va="bottom", fontsize=8)
        plt.xticks(x + (len(Ns_sorted)-1)*width/2, [str(s) for s in strides])
        plt.xlabel("Stride")
        plt.ylabel("CPE")
        plt.title(f"{kernel} {dtype} • CPE vs stride (per-N grouped)")
        plt.legend(title="N", fontsize=9)
        plt.tight_layout()
        plt.savefig(outdir / f"{kernel}_{dtype}_cpe_grouped_by_stride.png")
        plt.close()

    # Export data used for plotting
    if plot_rows:
        plot_df = pd.concat(plot_rows, ignore_index=True)
        Path("data").mkdir(parents=True, exist_ok=True)
        plot_df.to_csv("data/stride_plotset.csv", index=False)

# Line chart (optionally kept for comparison; comment out if you don’t want it)
def plot_lines(pergrp, metric, ylabel, suffix, outdir):
    for (k, dt, N), g in pergrp.groupby(["kernel", "dtype", "n"]):
        g = g.sort_values("stride")
        if g.empty:
            continue
        x, y = g["stride"].to_numpy(), g[metric].to_numpy()
        plt.figure(figsize=(6.6, 4.0))
        plt.plot(x, y, marker="o")
        plt.xticks(x, [str(int(s)) for s in x])
        plt.xlabel("Stride")
        plt.ylabel(ylabel)
        plt.title(f"{k} {dt} N={int(N)}")
        plt.grid(True, ls="--", alpha=0.4)
        plt.tight_layout()
        fname = outdir / f"{k}_{dt}_N{int(N)}_{suffix}.png"
        plt.savefig(fname)
        plt.close()

def main():
    ap = argparse.ArgumentParser(description="stride summary + grouped bars")
    ap.add_argument("--simd_csv", default="data/simd.csv")
    ap.add_argument("--with_lines", action="store_true",
                    help="Also generate line charts for each (kernel,dtype,N)")
    args = ap.parse_args()

    outdir = Path("plots") / "stride"
    outdir.mkdir(parents=True, exist_ok=True)
    Path("data").mkdir(parents=True, exist_ok=True)

    raw = load_df(Path(args.simd_csv))
    df  = filter_ok(raw)

    # Continue generating summary (abs/rel/md)
    df_abs = df[["kernel","dtype","n","stride","gflops","cpe"]].copy()
    df_rel = normalize_to_stride1(df_abs.copy(), "gflops")
    df_abs.to_csv("data/stride_abs.csv", index=False)
    df_rel.to_csv("data/stride_rel.csv", index=False)
    write_md(df_abs, df_rel, outdir / "stride_summary.md")

    # Optional: keep line charts for each N
    if args.with_lines:
        plot_lines(df_abs, "gflops", "GFLOP/s", "gflops_vs_stride", outdir)
        plot_lines(df_abs, "cpe",    "CPE",      "cpe_vs_stride",    outdir)

    # Based on summary, generate “grouped bar charts across N per kernel” (GFLOP/s and CPE)
    plot_kernel_dtype_grouped_bars(df_abs, outdir)

    print("Done:")
    print("  data/stride_abs.csv, data/stride_rel.csv")
    print("  plots/stride/stride_summary.md")
    print("  plots/stride/<kernel>_<dtype>_gflops_grouped_by_stride.png")
    print("  plots/stride/<kernel>_<dtype>_cpe_grouped_by_stride.png")
    if args.with_lines:
        print("  plots/stride/*_N*_gflops_vs_stride.png, *_cpe_vs_stride.png")
    print("  data/stride_plotset.csv")

if __name__ == "__main__":
    main()
