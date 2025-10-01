#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Tail-processing performance impact analysis script

Function:
1. Filter aligned samples (misalign=0, verified=1) from data/simd.csv
2. Group by whether n % vector width (lanes) equals 0 (tail_flag)
   - tail_flag=0 → exact multiple
   - tail_flag=1 → has tail processing
3. Compute geometric mean performance metrics for each group (kernel,dtype,stride,tail_flag)
4. Compare tail=1 vs tail=0 and compute percentage performance difference Δ%
5. Output summary:
   - data/tail_delta_summary.csv
   - plots/tail/tail_delta_summary.md
   - Three charts (ΔGFLOP/s, ΔCPE, ΔGiB/s)
"""

import argparse
from pathlib import Path
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

# -----------------------------------------------------------
# Utility function: geometric mean (filter out non-positive values to avoid log errors)
# -----------------------------------------------------------
def geom_mean(series: pd.Series) -> float:
    s = series.dropna()
    s = s[s > 0]
    if s.empty:
        return np.nan
    return float(np.exp(np.mean(np.log(s))))

# -----------------------------------------------------------
# Step 1: Load CSV and mark tail_flag
# -----------------------------------------------------------
def load_and_flag_tail(simd_csv: Path, f32_lanes: int, f64_lanes: int) -> pd.DataFrame:
    df = pd.read_csv(simd_csv)
    # Handle different column name cases
    df = df.rename(columns={c: ("GiBps" if c.lower()=="gibps" else c) for c in df.columns})
    # Only use samples with verified=1 and misalign=0
    df = df[(df["verified"] == 1) & (df["misalign"] == 0)].copy()

    # Determine lanes based on dtype, and mark tail_flag
    df["lanes"] = df.apply(lambda r: f32_lanes if r["dtype"]=="f32" else f64_lanes, axis=1)
    df["tail_flag"] = (df["n"] % df["lanes"] != 0).astype(int)
    return df

# -----------------------------------------------------------
# Step 2: Compute geometric mean for each group (kernel,dtype,stride,tail_flag)
# -----------------------------------------------------------
def build_tail_flag_geo(df: pd.DataFrame) -> pd.DataFrame:
    return df.groupby(["kernel","dtype","stride","tail_flag"]).agg(
        samples=("gflops","count"),
        geo_gflops=("gflops",geom_mean),
        geo_cpe=("cpe",geom_mean),
        geo_gibps=("GiBps",geom_mean)
    ).reset_index().sort_values(["kernel","dtype","stride","tail_flag"])

# -----------------------------------------------------------
# Step 3: Compare tail=1 vs tail=0 and compute percentage change
# -----------------------------------------------------------
def build_tail_delta_summary(geo: pd.DataFrame) -> pd.DataFrame:
    exact = geo[geo["tail_flag"]==0]
    tail  = geo[geo["tail_flag"]==1]
    m = pd.merge(exact, tail, on=["kernel","dtype","stride"], suffixes=("_exact","_tail"))
    if m.empty:
        return pd.DataFrame()
    m["delta_gflops_%"] = (m["geo_gflops_tail"]/m["geo_gflops_exact"] - 1)*100
    m["delta_cpe_%"]    = (m["geo_cpe_tail"]/m["geo_cpe_exact"] - 1)*100
    m["delta_gibps_%"]  = (m["geo_gibps_tail"]/m["geo_gibps_exact"] - 1)*100
    return m[["kernel","dtype","stride","delta_gflops_%","delta_cpe_%","delta_gibps_%","samples_exact","samples_tail"]]

# -----------------------------------------------------------
# Step 4: Add overall row (overall average decline rate)
# -----------------------------------------------------------
def append_overall_mean(df: pd.DataFrame) -> pd.DataFrame:
    means = {c: df[c].mean() for c in ["delta_gflops_%","delta_cpe_%","delta_gibps_%"]}
    new_row = {"kernel":"ALL","dtype":"-","stride":0,**means,
               "samples_exact":df["samples_exact"].sum(),
               "samples_tail":df["samples_tail"].sum()}
    return pd.concat([df, pd.DataFrame([new_row])], ignore_index=True)

# -----------------------------------------------------------
# Step 5: Output Markdown table (for direct inclusion in reports)
# -----------------------------------------------------------
def save_markdown_table(df: pd.DataFrame, out_md: Path):
    lines = ["### Tail Processing (Tail) Performance Change Summary",
             "| kernel | dtype | stride | ΔGFLOP/s (%) | ΔCPE (%) | ΔGiB/s (%) | samples(exact/tail) |",
             "|---|---|---:|---:|---:|---:|---:|"]
    for _, r in df.iterrows():
        lines.append(f"| {r['kernel']} | {r['dtype']} | {int(r['stride'])} | "
                     f"{r['delta_gflops_%']:+.2f} | {r['delta_cpe_%']:+.2f} | {r['delta_gibps_%']:+.2f} | "
                     f"{int(r['samples_exact'])}/{int(r['samples_tail'])} |")
    out_md.write_text("\n".join(lines), encoding="utf-8")

# -----------------------------------------------------------
# Step 6: Plot bar charts (ΔGFLOP/s, ΔCPE, ΔGiB/s)
# -----------------------------------------------------------
def plot_bar(df, metric, ylabel, out_png):
    labels = df.apply(lambda r:f"{r['kernel']}-{r['dtype']}-s{int(r['stride'])}",axis=1)
    y=df[metric].values
    plt.figure(figsize=(12,4.5))
    plt.bar(range(len(y)), y)
    plt.xticks(range(len(y)), labels, rotation=60, ha="right")
    plt.ylabel(ylabel)
    plt.title("Tail (N%lanes!=0) vs Exact Multiples")
    plt.tight_layout()
    plt.savefig(out_png,dpi=160)
    plt.close()

# -----------------------------------------------------------
# Main function
# -----------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Generate Tail Processing Performance Impact Report")
    parser.add_argument("--simd_csv",default="data/simd.csv", help="Input SIMD result file path")
    parser.add_argument("--f32_lanes",type=int,default=8, help="f32 vector width (AVX2=8, AVX512=16)")
    parser.add_argument("--f64_lanes",type=int,default=4, help="f64 vector width (AVX2=4, AVX512=8)")
    args = parser.parse_args()

    # Output directory
    plots_dir = Path("plots") / "tail"
    plots_dir.mkdir(parents=True,exist_ok=True)

    # Execution flow
    df = load_and_flag_tail(Path(args.simd_csv), args.f32_lanes, args.f64_lanes)
    geo = build_tail_flag_geo(df)
    delta = build_tail_delta_summary(geo)
    delta = append_overall_mean(delta)

    # Save results
    delta.to_csv("data/tail_delta_summary.csv", index=False)
    save_markdown_table(delta, plots_dir / "tail_delta_summary.md")

    # Plot
    for m,y in [("delta_gflops_%","ΔGFLOP/s (%)"),
                ("delta_cpe_%","ΔCPE (%)"),
                ("delta_gibps_%","ΔGiB/s (%)")]:
        plot_bar(delta, m, y, plots_dir / f"tail_{m}.png")

    print("✅ Output completed: under plots/tail/")

# -----------------------------------------------------------
if __name__=="__main__":
    main()
