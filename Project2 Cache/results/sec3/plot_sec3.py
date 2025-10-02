import os, sys
import pandas as pd
import matplotlib.pyplot as plt

csv, fig_root, out_root = sys.argv[1:4]
fig_dir = os.path.join(fig_root, 'sec3')
out_md  = os.path.join(out_root,  'section_3_pattern_stride.md')
os.makedirs(fig_dir, exist_ok=True)
os.makedirs(os.path.dirname(out_md), exist_ok=True)

df = pd.read_csv(csv)
df['stride_B'] = pd.to_numeric(df['stride_B'], errors='coerce')
df['lat_ns']   = pd.to_numeric(df['lat_ns'],   errors='coerce')
df['bw_gbs']   = pd.to_numeric(df['bw_gbs'],   errors='coerce')
df = df.dropna(subset=['stride_B','lat_ns','bw_gbs'])

# Aggregate mean ± std
summary = df.groupby(['mode','stride_B']).agg(
    lat_mean=('lat_ns','mean'),
    lat_std =('lat_ns','std'),
    bw_mean =('bw_gbs','mean'),
    bw_std  =('bw_gbs','std'),
).reset_index()

# --- Plot: Latency with error bars (units) ---
plt.figure(figsize=(7,4.5))
for mode in summary['mode'].unique():
    sub = summary[summary['mode']==mode].sort_values('stride_B')
    plt.errorbar(sub['stride_B'], sub['lat_mean'], yerr=sub['lat_std'],
                 fmt='-o', capsize=5, label=mode)
plt.xscale('log', base=2)
plt.xlabel('Stride (Bytes, log scale)')
plt.ylabel('Latency (ns/access)')
plt.title('Latency vs Stride (mean ± std)')
plt.grid(True, linestyle='--', alpha=0.5)
plt.legend()
lat_png = os.path.join(fig_dir, 'latency_vs_stride.png')
plt.savefig(lat_png, bbox_inches='tight', dpi=150)
plt.close()

# --- Plot: Bandwidth with error bars (units) ---
plt.figure(figsize=(7,4.5))
for mode in summary['mode'].unique():
    sub = summary[summary['mode']==mode].sort_values('stride_B')
    plt.errorbar(sub['stride_B'], sub['bw_mean'], yerr=sub['bw_std'],
                 fmt='-o', capsize=5, label=mode)
plt.xscale('log', base=2)
plt.xlabel('Stride (Bytes, log scale)')
plt.ylabel('Bandwidth (GB/s)')
plt.title('Bandwidth vs Stride (mean ± std)')
plt.grid(True, linestyle='--', alpha=0.5)
plt.legend()
bw_png = os.path.join(fig_dir, 'bandwidth_vs_stride.png')
plt.savefig(bw_png, bbox_inches='tight', dpi=150)
plt.close()

# --- Markdown output (tables + figures + analysis) ---
def md_table(pdf, title):
    cols = ['stride_B'] + list(pdf.columns)
    lines = [f"**{title}**", "| " + " | ".join(map(str, cols)) + " |",
             "| " + " | ".join(["---"]*len(cols)) + " |"]
    for idx, row in pdf.iterrows():
        lines.append("| " + " | ".join([str(idx)] + [str(row[c]) for c in pdf.columns]) + " |")
    return "\n".join(lines)

pivot_lat_mean = summary.pivot(index='stride_B', columns='mode', values='lat_mean').round(3)
pivot_lat_std  = summary.pivot(index='stride_B', columns='mode', values='lat_std').round(3)
pivot_bw_mean  = summary.pivot(index='stride_B', columns='mode', values='bw_mean').round(3)
pivot_bw_std   = summary.pivot(index='stride_B', columns='mode', values='bw_std').round(3)

with open(out_md,'w') as f:
    f.write("## 3. Pattern & Stride Sweep (Latency & Bandwidth)\n\n")
    f.write("### 3.3 Results (Mean ± Std)\n\n")
    f.write(md_table(pivot_lat_mean, "Mean Latency (ns/access)") + "\n\n")
    f.write(md_table(pivot_lat_std,  "StdDev Latency (ns/access)") + "\n\n")
    f.write(md_table(pivot_bw_mean,  "Mean Bandwidth (GB/s)") + "\n\n")
    f.write(md_table(pivot_bw_std,   "StdDev Bandwidth (GB/s)") + "\n\n")
    f.write(f"![Latency](../figs/sec3/{os.path.basename(lat_png)})\n\n")
    f.write(f"![Bandwidth](../figs/sec3/{os.path.basename(bw_png)})\n\n")
    f.write("### 3.4 Result Analysis\n\n")
    f.write("- **Prefetch & stride effects**: smaller strides and sequential access enable HW prefetchers and DRAM row-buffer hits, reducing latency and boosting bandwidth.\n")
    f.write("- **Random & larger strides**: reduce prefetch efficacy, increase row misses and TLB pressure → higher latency and lower bandwidth.\n")
    f.write("- **Error bars** represent run-to-run variability (std) over REPEAT trials.\n")

print("✅ Wrote:", out_md)
