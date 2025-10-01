#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_roofline_report.py
===========================================
Function:
- Read data/scalar.csv / data/simd.csv
- Compute Arithmetic Intensity (AI = FLOPs / Byte) for each (kernel, dtype)
- Based on measured or user-specified bandwidth B_mem (GiB/s) and peak compute performance P_peak (GFLOP/s),
  plot Roofline: y = min(P_peak, B_mem * AI)
- Overlay measured gmean(GFLOP/s) points for each (kernel, dtype, region)
- Automatically determine bottleneck type (Memory-bound / Compute-bound)
- Generate charts + Markdown report reports/roofline.md
"""

import os, math, argparse
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt

# Create output directories
os.makedirs("plots/roofline", exist_ok=True)
os.makedirs("reports", exist_ok=True)

# ---------- Utility functions ----------
def pick_col(df, names, default=None):
    """Column name tolerance"""
    for n in names:
        if n in df.columns:
            return n
        for c in df.columns:
            if c.lower() == n.lower():
                return c
    return default

def geomean(series):
    """Geometric mean"""
    s = pd.to_numeric(series, errors="coerce").dropna()
    s = s[s > 0]
    if len(s) == 0:
        return np.nan
    return float(np.exp(np.log(s).mean()))

def load_csv(path):
    """Read CSV and normalize column names"""
    df = pd.read_csv(path)
    rename_map = {}
    alias = [
        ('simd_or_scalar','version'),
        ('Version','version'),
        ('gflops_per_s','gflops'),
        ('Gflops','gflops'),
        ('cycles_per_element','cpe'),
        ('CPE','cpe'),
        ('bandwidth_gib_per_s','gibps'),
        ('GiBps','gibps'),
        ('gib_per_s','gibps'),
    ]
    for a,b in alias:
        if a in df.columns:
            rename_map[a] = b
    if rename_map:
        df = df.rename(columns=rename_map)
    return df

# ---------- AI definition table (FLOPs/Byte) ----------
FLOPs_PER_EL = {'saxpy': 2, 'dot': 2, 'mul': 1, 'stencil': 3}
BYTES_PER_EL = {
    'f32': {'saxpy':12, 'dot':8,  'mul':12, 'stencil':8},
    'f64': {'saxpy':24, 'dot':16, 'mul':24, 'stencil':16},
}

def get_ai(kernel, dtype, flops_override=None, bytes_override=None):
    """Compute Arithmetic Intensity (AI) by kernel/dtype"""
    k = kernel.lower()
    d = dtype.lower()
    fpe = FLOPs_PER_EL.get(k, 2) if flops_override is None else flops_override
    bel = BYTES_PER_EL.get(d, {}).get(k, 12)
    if bytes_override is not None:
        bel = bytes_override
    if bel <= 0:
        return np.nan
    return float(fpe) / float(bel)

# ---------- Argument parsing ----------
ap = argparse.ArgumentParser(description="Roofline analysis report generator")
ap.add_argument("--bmem", type=float, default=None,
                help="Measured or estimated memory bandwidth GiB/s (default: estimated from CSV 95th percentile)")
ap.add_argument("--peak_gflops", type=float, default=None,
                help="Single-thread peak GFLOP/s (default: small-N peak × 1.15)")
ap.add_argument("--stencil_flops", type=float, default=3.0,
                help="FLOPs per element for stencil (default 3, can be set to 2/4)")
ap.add_argument("--pick", type=str, default="stride=1",
                help="Filter condition (e.g. 'stride=1;misalign=0')")
ap.add_argument("--regionize", action="store_true",
                help="Automatically tag regions (L1/L2/LLC/DRAM) by N")
args = ap.parse_args()

# Apply stencil FLOPs override
FLOPs_PER_EL['stencil'] = float(args.stencil_flops)

# ---------- Read CSV ----------
simd = load_csv("data/simd.csv")
scalar = load_csv("data/scalar.csv")

K = pick_col(simd, ["kernel"]) or "kernel"
D = pick_col(simd, ["dtype"]) or "dtype"
N = pick_col(simd, ["n"]) or "n"
S = pick_col(simd, ["stride"]) or "stride"
M = pick_col(simd, ["misalign"]) or "misalign"
G = pick_col(simd, ["gflops"]) or "gflops"
C = pick_col(simd, ["cpe"]) or "cpe"
B = pick_col(simd, ["gibps"])

# Type conversion
for df in (simd, scalar):
    for col in [K, D]:
        df[col] = df[col].astype(str)
    for col in [N, S, M, G, C]:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")

# ---------- Filtering ----------
def apply_filters(df, expr):
    if not expr:
        return df
    out = df.copy()
    for tok in expr.split(";"):
        tok = tok.strip()
        if not tok:
            continue
        if "=" in tok:
            key, val = tok.split("=", 1)
            key, val = key.strip(), val.strip()
            col = pick_col(out, [key]) or key
            if col in out.columns:
                if val.isdigit():
                    out = out[out[col] == int(val)]
                else:
                    out = out[out[col].astype(str) == val]
    return out

simd_f = apply_filters(simd, args.pick)

# ---------- Region tagging ----------
def region_by_n(n):
    if n <= 8192: return "L1"
    if n <= 131072: return "L2"
    if n <= 4194304: return "LLC"
    return "DRAM"

if args.regionize:
    simd_f = simd_f.copy()
    simd_f["region"] = simd_f[N].apply(region_by_n)
else:
    simd_f["region"] = "ALL"

# ---------- Compute AI ----------
simd_f["ai"] = [get_ai(k, d) for k, d in zip(simd_f[K], simd_f[D])]

# ---------- Estimate bandwidth / peak ----------
if args.bmem is not None:
    B_mem = float(args.bmem)
elif B and B in simd_f.columns:
    B_mem = float(simd_f[B].quantile(0.95))
else:
    tmp = simd_f[(simd_f["ai"] > 0) & (simd_f[N] >= 8_000_000)]
    if len(tmp):
        B_mem = float((tmp[G] / tmp["ai"]).quantile(0.5))
    else:
        B_mem = 30.0

if args.peak_gflops is not None:
    P_peak = float(args.peak_gflops)
else:
    small = simd_f[simd_f["region"].isin(["L1","L2"])] if "region" in simd_f.columns else simd_f[simd_f[N]<=8192]
    P_peak = float(small[G].quantile(0.98) * 1.15 if len(small) else simd_f[G].quantile(0.98)*1.15)

# ---------- Aggregation ----------
grp = simd_f.groupby([K, D, "region"], dropna=False).agg(
    gmean_gflops=(G, geomean),
    gmean_ai=("ai", geomean),
    samples=(G, "count")
).reset_index()

# ---------- Roofline plotting ----------
def plot_roofline(points, title, out_png):
    xs = points["gmean_ai"].replace([np.inf, -np.inf], np.nan).dropna()
    if xs.empty:
        return
    xmin = max(xs.min()/2, 1e-3)
    xmax = max(xs.max()*2, 1e1)
    X = np.logspace(np.log10(xmin), np.log10(xmax), 200)
    roof_y = np.minimum(P_peak, B_mem * X)

    plt.figure()
    plt.xscale("log"); plt.yscale("log")
    plt.plot(X, roof_y, label=f"Roof: min(P={P_peak:.1f}, B*AI), B={B_mem:.1f}GiB/s")
    plt.axhline(P_peak, linestyle="--", linewidth=1, color='gray')

    for _, row in points.iterrows():
        lbl = f"{row[K]}-{row[D]}-{row['region']}"
        plt.scatter(max(row["gmean_ai"], 1e-6), max(row["gmean_gflops"], 1e-6), s=36)
        plt.text(max(row["gmean_ai"], 1e-6)*1.05, max(row["gmean_gflops"], 1e-6)*1.05, lbl, fontsize=8)

    plt.xlabel("Arithmetic Intensity (FLOPs / Byte)")
    plt.ylabel("GFLOP/s (measured)")
    plt.title(title)
    plt.legend()
    plt.tight_layout()
    plt.savefig(out_png, dpi=150)
    plt.close()

# Plot overview and per-kernel Rooflines
plot_roofline(grp, "Roofline Overview (SIMD, gmean)", "plots/roofline/roofline_overview.png")
for k in sorted(grp[K].unique()):
    pts = grp[grp[K] == k]
    if len(pts):
        plot_roofline(pts, f"Roofline — {k}", f"plots/roofline/roofline_{k}.png")

# ---------- Bottleneck classification ----------
def predict_cap(ai):
    if not np.isfinite(ai) or ai <= 0:
        return np.nan
    return min(P_peak, B_mem * ai)

grp["pred_cap"] = grp["gmean_ai"].map(predict_cap)
grp["bottleneck"] = np.where(grp["gmean_ai"] * B_mem < P_peak * 0.98, "Memory-bound", "Compute-bound")
grp["util_%"] = 100.0 * grp["gmean_gflops"] / grp["pred_cap"]

# ---------- Markdown report ----------
md = []
md.append("# Roofline Analysis Report\n")
md.append(f"- Peak performance (P_peak): {P_peak:.2f} GFLOP/s")
md.append(f"- Memory bandwidth (B_mem): {B_mem:.2f} GiB/s")
md.append(f"- Filter condition: `{args.pick or '(none)'}`, region tagging: `{'on' if args.regionize else 'off'}`\n")

md.append("## 1) Overview Roofline Plot")
md.append("![roofline_overview](../plots/roofline/roofline_overview.png)\n")

md.append("## 2) Per-Kernel Roofline Plots")
for k in sorted(grp[K].unique()):
    path = f"../plots/roofline/roofline_{k}.png"
    if os.path.exists(path.replace('..','plots')) or os.path.exists(path):
        md.append(f"### {k}")
        md.append(f"![roofline_{k}]({path})\n")

md.append("## 3) Measured vs Theoretical Cap and Bottleneck Classification\n")
show = grp[[K, D, "region", "gmean_ai", "gmean_gflops", "pred_cap", "util_%", "bottleneck", "samples"]].copy()
for c in ["gmean_ai", "gmean_gflops", "pred_cap", "util_%"]:
    show[c] = show[c].map(lambda x: f"{x:.3f}" if pd.notnull(x) else "")
md.append(show.to_markdown(index=False))
md.append("\n")
md.append("Key Points:\n")
md.append("- Points near `y = B*AI`: Memory-bound; improve data reuse, optimize stride.\n")
md.append("- Points near `y = P_peak`: Compute-bound; increase SIMD issue rate or parallelism.\n")
md.append("- `util_%` indicates utilization; DRAM region typically below 50%, focus on cache reuse and access pattern optimization.\n")

with open("reports/roofline.md", "w", encoding="utf-8") as f:
    f.write("\n".join(md))

print("[OK] Roofline completed: plots/roofline/* + reports/roofline.md")
