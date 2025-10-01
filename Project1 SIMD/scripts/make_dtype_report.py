#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Generate dtype comparison report (float32 vs float64; optional int32 if present)
- Join data/scalar.csv and data/simd.csv on (kernel, dtype, n, stride, misalign)
- Compute speedup = gflops_simd / gflops_scalar
- Tag memory regions by N (L1/L2/LLC/DRAM), consistent with §2.2
- Aggregate geometric means by (dtype, kernel, region)
- Save tables to data/dtype_summary.csv
- Plot figures to plots/dtype/
- Write Markdown report to plots/dtype/dtype_summary.md
"""

import os
import math
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt

# -----------------------------
# Setup
# -----------------------------
plt.rcParams["figure.dpi"] = 150
os.makedirs("plots/dtype", exist_ok=True)
os.makedirs("data", exist_ok=True)

# -----------------------------
# Helpers
# -----------------------------
def pick_col(df, names, default=None):
    """Pick a column by a list of candidate names (case-insensitive)."""
    for n in names:
        if n in df.columns:
            return n
        for c in df.columns:
            if c.lower() == n.lower():
                return c
    return default

def geomean(series):
    """Geometric mean ignoring non-positive / NaN entries."""
    s = series.dropna().astype(float)
    s = s[s > 0]
    if len(s) == 0:
        return np.nan
    return float(np.exp(np.log(s).mean()))

def load_csv(path):
    df = pd.read_csv(path)
    # Normalize common metric column names
    rename_map = {}
    if 'simd_or_scalar' in df.columns: rename_map['simd_or_scalar'] = 'version'
    if 'Version' in df.columns:        rename_map['Version'] = 'version'
    if 'gflops_per_s' in df.columns:   rename_map['gflops_per_s'] = 'gflops'
    if 'Gflops' in df.columns:         rename_map['Gflops'] = 'gflops'
    if 'cycles_per_element' in df.columns: rename_map['cycles_per_element'] = 'cpe'
    if 'CPE' in df.columns:            rename_map['CPE'] = 'cpe'
    if rename_map:
        df = df.rename(columns=rename_map)
    return df

def normalize(df):
    df = df.copy()
    # required keys
    for col in ["kernel", "dtype"]:
        if col in df.columns:
            df[col] = df[col].astype(str)
    for col in ["n", "stride", "misalign", "gflops", "cpe"]:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")
    return df

def region_by_n(n):
    """Map N to memory region (aligned with §2.2 selections)."""
    if n <= 8192:       return "L1"
    if n <= 131072:     return "L2"
    if n <= 4194304:    return "LLC"
    return "DRAM"

# -----------------------------
# Load inputs
# -----------------------------
scalar = normalize(load_csv("data/scalar.csv"))
simd   = normalize(load_csv("data/simd.csv"))

# Validate required columns
for need in ["kernel","dtype","n","stride","misalign","gflops","cpe"]:
    if pick_col(scalar, [need]) is None:
        raise SystemExit(f"[ERROR] Missing column '{need}' in data/scalar.csv")
    if pick_col(simd, [need]) is None:
        raise SystemExit(f"[ERROR] Missing column '{need}' in data/simd.csv")

# Canonical column handles
K = pick_col(scalar, ["kernel"])
D = pick_col(scalar, ["dtype"])
N = pick_col(scalar, ["n"])
S = pick_col(scalar, ["stride"])
M = pick_col(scalar, ["misalign"])
G = pick_col(scalar, ["gflops"])
C = pick_col(scalar, ["cpe"])

# -----------------------------
# Join scalar & simd
# -----------------------------
key = [K, D, N, S, M]
merged = pd.merge(
    simd[key + [G, C]].rename(columns={G: "gflops_simd", C: "cpe_simd"}),
    scalar[key + [G, C]].rename(columns={G: "gflops_scalar", C: "cpe_scalar"}),
    on=key, how="inner"
)

# Speedup via GFLOP/s ratio (equivalent to time speedup for same kernel & FLOPs)
merged["speedup"] = merged["gflops_simd"] / merged["gflops_scalar"]
merged["region"]  = merged[N].apply(region_by_n)

# -----------------------------
# Aggregations
# -----------------------------
# By dtype, kernel, region
agg = merged.groupby([D, K, "region"], as_index=False).agg(
    gmean_speedup        = ("speedup", geomean),
    gmean_gflops_simd    = ("gflops_simd", geomean),
    gmean_gflops_scalar  = ("gflops_scalar", geomean),
    gmean_cpe_simd       = ("cpe_simd", geomean),
    gmean_cpe_scalar     = ("cpe_scalar", geomean),
    samples              = ("speedup", "count"),
)

# Overall (ALL regions)
agg_overall = merged.groupby([D, K], as_index=False).agg(
    gmean_speedup        = ("speedup", geomean),
    gmean_gflops_simd    = ("gflops_simd", geomean),
    gmean_gflops_scalar  = ("gflops_scalar", geomean),
    gmean_cpe_simd       = ("cpe_simd", geomean),
    gmean_cpe_scalar     = ("cpe_scalar", geomean),
    samples              = ("speedup", "count"),
)
agg_overall["region"] = "ALL"

summary = pd.concat([agg, agg_overall], ignore_index=True)

# stride=1 only view
summary_s1 = (
    merged[merged[S] == 1]
      .groupby([D, K, "region"], as_index=False)
      .agg(
          gmean_speedup        = ("speedup", geomean),
          gmean_gflops_simd    = ("gflops_simd", geomean),
          gmean_gflops_scalar  = ("gflops_scalar", geomean),
          gmean_cpe_simd       = ("cpe_simd", geomean),
          gmean_cpe_scalar     = ("cpe_scalar", geomean),
          samples              = ("speedup", "count"),
      )
)
summary_s1["note"] = "stride=1 only"

# Final table for CSV
summary_out = pd.concat([summary, summary_s1], ignore_index=True, sort=False)
summary_out.to_csv("data/dtype_summary.csv", index=False)
print("[OK] saved data/dtype_summary.csv")

# -----------------------------
# Plots
# -----------------------------
def plot_speedup(dtype):
    df = summary[(summary[D]==dtype) & (summary["region"].isin(["L1","L2","LLC","DRAM"]))]
    if df.empty:
        return
    piv = df.pivot(index=K, columns="region", values="gmean_speedup")
    # Ensure region order if present
    cols = [c for c in ["L1","L2","LLC","DRAM"] if c in piv.columns]
    piv = piv[cols]
    ax = piv.plot(kind="bar")
    ax.set_title(f"SIMD Speedup vs Scalar — {dtype}")
    ax.set_ylabel("Geometric Mean Speedup")
    ax.set_xlabel("Kernel")
    ax.grid(alpha=0.3, linestyle="--")
    plt.tight_layout()
    plt.savefig(f"plots/dtype/speedup_{dtype}.png")
    plt.close()

for dt in sorted(summary[D].dropna().unique()):
    plot_speedup(dt)

def plot_gflops_simd_compare(kernel):
    dfk = summary[(summary[K]==kernel) & (summary["region"].isin(["L1","L2","LLC","DRAM"]))]
    if dfk.empty:
        return
    piv = dfk.pivot(index="region", columns=D, values="gmean_gflops_simd")
    # keep region order
    idx_order = [r for r in ["L1","L2","LLC","DRAM"] if r in piv.index]
    piv = piv.loc[idx_order]
    ax = piv.plot(kind="bar")
    ax.set_title(f"SIMD GFLOP/s by dtype — {kernel}")
    ax.set_ylabel("GFLOP/s (Geometric Mean)")
    ax.set_xlabel("Region")
    ax.grid(alpha=0.3, linestyle="--")
    plt.tight_layout()
    plt.savefig(f"plots/dtype/gflops_simd_{kernel}.png")
    plt.close()

def plot_cpe_simd_compare(kernel):
    dfk = summary[(summary[K]==kernel) & (summary["region"].isin(["L1","L2","LLC","DRAM"]))]
    if dfk.empty:
        return
    piv = dfk.pivot(index="region", columns=D, values="gmean_cpe_simd")
    idx_order = [r for r in ["L1","L2","LLC","DRAM"] if r in piv.index]
    piv = piv.loc[idx_order]
    ax = piv.plot(kind="bar")
    ax.set_title(f"SIMD CPE by dtype — {kernel}")
    ax.set_ylabel("CPE (Geometric Mean)")
    ax.set_xlabel("Region")
    ax.grid(alpha=0.3, linestyle="--")
    plt.tight_layout()
    plt.savefig(f"plots/dtype/cpe_simd_{kernel}.png")
    plt.close()

for kname in sorted(summary[K].dropna().unique()):
    plot_gflops_simd_compare(kname)
    plot_cpe_simd_compare(kname)

print("[OK] plots saved under plots/dtype/")

# -----------------------------
# Markdown report
# -----------------------------
md_path = "plots/dtype/dtype_summary.md"

def fmt(df):
    df = df.copy()
    for col in ["gmean_speedup","gmean_gflops_simd","gmean_gflops_scalar","gmean_cpe_simd","gmean_cpe_scalar"]:
        if col in df.columns:
            df[col] = df[col].map(lambda x: f"{x:.3f}" if pd.notnull(x) else "")
    return df

# Keep column order
cols_common = [
    D, K, "region",
    "gmean_speedup",
    "gmean_gflops_simd", "gmean_gflops_scalar",
    "gmean_cpe_simd", "gmean_cpe_scalar",
    "samples"
]

summary_show = fmt(summary_out[[c for c in cols_common if c in summary_out.columns]].copy())

# stride=1 view (pick rows with note tag)
summary_s1_show = summary_out.copy()
summary_s1_show = summary_s1_show[summary_s1_show.get("note","")=="stride=1 only"]
summary_s1_show = fmt(summary_s1_show[[c for c in cols_common if c in summary_s1_show.columns]])

lines = []
lines.append("# DType Comparison Summary\n")
lines.append("> Auto-generated by `scripts/make_dtype_report.py`\n")
lines.append("")
lines.append("## How to read")
lines.append("- **Speedup** = SIMD_GFLOP/s ÷ Scalar_GFLOP/s (for the same kernel, this equals time speedup since FLOPs are identical).")
lines.append("- **Region** is derived from `N`: L1 ≤ 8K; L2 ≤ 128K; LLC ≤ 4M; DRAM > 4M (aligned with §2.2).")
lines.append("- Metrics are **geometric means (Geomean)** across samples; `samples` indicates the count per group.")
lines.append("")

lines.append("## 1) All samples (all strides; aligned/misaligned mixed)")
lines.append("")
lines.append(summary_show.to_markdown(index=False))
lines.append("")

lines.append("## 2) stride=1 only")
lines.append("")
if len(summary_s1_show):
    lines.append(summary_s1_show.to_markdown(index=False))
else:
    lines.append("_No stride=1-only rows found in current CSV join._")
lines.append("")

# Figures
lines.append("## 3) Figures")
lines.append("")
# Speedup by dtype
for dt in sorted(summary[D].dropna().unique()):
    fig_rel = f"plots/dtype/speedup_{dt}.png"
    if os.path.exists(fig_rel):
        lines.append(f"### Speedup by Region — `{dt}`")
        lines.append(f"![speedup_{dt}]({fig_rel})")
        lines.append("")
# Per-kernel GFLOP/s & CPE
for kname in sorted(summary[K].dropna().unique()):
    fig_g = f"plots/dtype/gflops_simd_{kname}.png"
    if os.path.exists(fig_g):
        lines.append(f"### SIMD GFLOP/s by dtype — `{kname}`")
        lines.append(f"![gflops_simd_{kname}]({fig_g})")
        lines.append("")
    fig_c = f"plots/dtype/cpe_simd_{kname}.png"
    if os.path.exists(fig_c):
        lines.append(f"### SIMD CPE by dtype — `{kname}`")
        lines.append(f"![cpe_simd_{kname}]({fig_c})")
        lines.append("")

with open(md_path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))

print(f"[OK] markdown saved: {md_path}")
