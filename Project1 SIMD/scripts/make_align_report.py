#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import math
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from pathlib import Path

def compute_summary_from_simd(simd_path: str) -> pd.DataFrame:
    cols = ["kernel","dtype","n","stride","misalign","reps",
            "time_ns_med","time_ns_p05","time_ns_p95","gflops","cpe","GiBps","verified","max_rel_err"]
    df = pd.read_csv(simd_path)

    # Fault tolerance: column name case
    rename = {}
    for c in df.columns:
        if c.lower() == "gibps": rename[c] = "GiBps"
    if rename:
        df = df.rename(columns=rename)

    # Keep only verified=1
    if "verified" in df.columns:
        df = df[df["verified"] == 1].copy()

    key_cols = ["kernel","dtype","stride","n"]
    aligned = df[df["misalign"] == 0][key_cols + ["gflops","cpe","GiBps"]].copy()
    misalgn = df[df["misalign"] == 1][key_cols + ["gflops","cpe","GiBps"]].copy()
    merged = pd.merge(aligned, misalgn, on=key_cols, suffixes=("_al","_mi"))
    if merged.empty:
        return pd.DataFrame(columns=[
            "kernel","dtype","stride",
            "geo_mean_delta_gflops_%","geo_mean_delta_cpe_%","geo_mean_delta_gibps_%","samples"
        ])

    # per-point difference
    for metric in ["gflops","cpe","GiBps"]:
        merged[f"delta_{metric}"] = (merged[f"{metric}_mi"] / merged[f"{metric}_al"]) - 1.0

    # Compute geometric mean by (kernel, dtype, stride)
    def gmean(series: pd.Series) -> float:
        s = series.dropna()
        if s.empty:
            return np.nan
        return np.exp(np.mean(np.log(1.0 + s))) - 1.0

    grouped = merged.groupby(["kernel","dtype","stride"]).agg(
        geo_mean_delta_gflops_ = ("delta_gflops", gmean),
        geo_mean_delta_cpe_    = ("delta_cpe",    gmean),
        geo_mean_delta_gibps_  = ("delta_GiBps",  gmean),
        samples                = ("delta_gflops", "count")
    ).reset_index()

    # Convert to percentage
    grouped["geo_mean_delta_gflops_%"] = grouped["geo_mean_delta_gflops_"] * 100.0
    grouped["geo_mean_delta_cpe_%"]    = grouped["geo_mean_delta_cpe_"]    * 100.0
    grouped["geo_mean_delta_gibps_%"]  = grouped["geo_mean_delta_gibps_"]  * 100.0
    grouped = grouped.drop(columns=["geo_mean_delta_gflops_","geo_mean_delta_cpe_","geo_mean_delta_gibps_"])

    return grouped.sort_values(by=["kernel","dtype","stride"]).reset_index(drop=True)

def append_overall_mean(df: pd.DataFrame, metric_cols: list[str]) -> pd.DataFrame:
    df2 = df.copy()
    means = {col: df[col].mean() for col in metric_cols}
    samples_total = df["samples"].sum()
    new_row = {
        "kernel": "ALL",
        "dtype": "-",
        "stride": 0,
        **means,
        "samples": samples_total
    }
    return pd.concat([df2, pd.DataFrame([new_row])], ignore_index=True)

def main():
    plots_dir = Path("plots") / "align"
    plots_dir.mkdir(parents=True, exist_ok=True)

    summary_path = Path("data/aln_vs_mis_summary.csv")
    if summary_path.exists():
        df = pd.read_csv(summary_path)
    else:
        simd_path = Path("data/simd.csv")
        if not simd_path.exists():
            raise FileNotFoundError("Cannot find data/simd.csv, nor data/aln_vs_mis_summary.csv")
        df = compute_summary_from_simd(str(simd_path))

    expected = ["kernel","dtype","stride","geo_mean_delta_gflops_%","geo_mean_delta_cpe_%","geo_mean_delta_gibps_%","samples"]
    df = df[expected].copy()
    df = append_overall_mean(df, ["geo_mean_delta_gflops_%","geo_mean_delta_cpe_%","geo_mean_delta_gibps_%"])

    # —— Markdown output ——
    md_lines = ["### Aligned vs Misaligned Overall Performance Change Summary",
                "| kernel | dtype | stride | ΔGFLOP/s (%) | ΔCPE (%) | ΔGiB/s (%) | samples |",
                "|---|---|---:|---:|---:|---:|---:|"]
    for _, r in df.iterrows():
        md_lines.append(
            f"| {r['kernel']} | {r['dtype']} | {int(r['stride'])} | "
            f"{r['geo_mean_delta_gflops_%']:+.2f} | {r['geo_mean_delta_cpe_%']:+.2f} | "
            f"{r['geo_mean_delta_gibps_%']:+.2f} | {int(r['samples'])} |"
        )
    (plots_dir / "aln_vs_mis_summary.md").write_text("\n".join(md_lines), encoding="utf-8")

    # —— Plotting ——
    def plot_metric(metric, ylabel, outfile):
        xlabels = df.apply(lambda r: f"{r['kernel']}-{r['dtype']}-s{int(r['stride'])}", axis=1)
        y = df[metric].values
        plt.figure(figsize=(12, 4.5))
        plt.bar(range(len(y)), y)
        plt.xticks(range(len(y)), xlabels, rotation=60, ha="right")
        plt.ylabel(ylabel)
        plt.title("Aligned vs Misaligned: Geometric-Mean Delta (%)")
        plt.tight_layout()
        plt.savefig(outfile, dpi=160)
        plt.close()

    plot_metric("geo_mean_delta_gflops_%", "ΔGFLOP/s (%)", plots_dir / "aln_vs_mis_delta_gflops.png")
    plot_metric("geo_mean_delta_cpe_%",    "ΔCPE (%)",     plots_dir / "aln_vs_mis_delta_cpe.png")
    plot_metric("geo_mean_delta_gibps_%",  "ΔGiB/s (%)",   plots_dir / "aln_vs_mis_delta_gibps.png")

    print("✅ Output completed: under plots/align/")

if __name__ == "__main__":
    main()
