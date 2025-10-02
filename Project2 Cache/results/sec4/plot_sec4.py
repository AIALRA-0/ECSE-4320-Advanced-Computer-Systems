import os, sys
import pandas as pd
import matplotlib.pyplot as plt
import numpy as np

csv_raw, fig_root, out_root = sys.argv[1:4]
fig_dir = os.path.join(fig_root, 'sec4')
out_md  = os.path.join(out_root,  'section_4_rwmix.md')
os.makedirs(fig_dir, exist_ok=True)
os.makedirs(os.path.dirname(out_md), exist_ok=True)

df = pd.read_csv(csv_raw)
df['read_pct'] = pd.to_numeric(df['read_pct'], errors='coerce')
df['bw_gbs']   = pd.to_numeric(df['bw_gbs'], errors='coerce')
df['stride_B'] = pd.to_numeric(df['stride_B'], errors='coerce')
df = df.dropna(subset=['read_pct','bw_gbs','stride_B'])

# Summary: mean ± std by (mode, read_pct)
summary = df.groupby(['mode','read_pct']).agg(
    bw_mean=('bw_gbs','mean'),
    bw_std =('bw_gbs','std'),
    samples=('bw_gbs','size'),
).reset_index()

# Save summary CSV for auditing
csv_sum = os.path.join(os.path.dirname(csv_raw), 'rwmix_summary.csv')
summary.to_csv(csv_sum, index=False)

modes = summary['mode'].unique()
read_levels = sorted(summary['read_pct'].unique())

# Prepare bar plot with error bars, grouped by read_pct, series by mode
x = np.arange(len(read_levels))
barw = 0.35 if len(modes)>1 else 0.6

plt.figure(figsize=(7,4.5))
for i, m in enumerate(modes):
    sub = summary[summary['mode']==m].set_index('read_pct').reindex(read_levels)
    y = sub['bw_mean'].values
    e = sub['bw_std'].values
    plt.bar(x + (i-(len(modes)-1)/2)*barw, y, width=barw, label=m, yerr=e, capsize=5)

plt.xticks(x, [f"{int(v)}%" for v in read_levels])
plt.xlabel('Read percentage (%)')
plt.ylabel('Bandwidth (GB/s)')
ttl_modes = " & ".join(modes)
plt.title(f'Bandwidth vs Read/Write Mix ({ttl_modes})')
plt.grid(axis='y', linestyle='--', alpha=0.5)
if len(modes)>1: plt.legend()

fig_path = os.path.join(fig_dir, 'bw_rwmix.png')
plt.savefig(fig_path, bbox_inches='tight', dpi=150)
plt.close()

# Markdown (no tabulate dependency; plain GFM)
def md_table(pdf, title):
    cols = list(pdf.columns)
    lines = [f"**{title}**", "| " + " | ".join(map(str, cols)) + " |",
             "| " + " | ".join(["---"]*len(cols)) + " |"]
    for _,row in pdf.iterrows():
        lines.append("| " + " | ".join(str(row[c]) for c in cols) + " |")
    return "\n".join(lines)

# Build per-mode tables for clarity
tables = []
for m in modes:
    sub = summary[summary['mode']==m][['read_pct','bw_mean','bw_std','samples']].copy()
    sub = sub.sort_values('read_pct').round({'bw_mean':3,'bw_std':3})
    sub['read_pct'] = sub['read_pct'].astype(int)
    tables.append( md_table(sub, f"{m} — Bandwidth (GB/s) mean ± std (samples)") )

with open(out_md,'w') as f:
    f.write("## 4. Read/Write Mix Sweep\n\n")
    f.write("### 4.3 Results (Mean ± Std)\n\n")
    for t in tables:
        f.write(t + "\n\n")
    f.write("![rwmix](../figs/sec4/bw_rwmix.png)\n\n")
    f.write("### 4.4 Analysis\n\n")
    f.write("- As write ratio increases, bandwidth commonly drops due to write-allocate, store buffering pressure, and writeback bandwidth constraints.\n")
    f.write("- 70/30 and 50/50 often expose controller and memory subsystem differences (e.g., write-combining efficiency, eviction overhead).\n")
    f.write("- Random access (if enabled) typically lowers BW versus sequential due to reduced prefetch and poorer row-buffer locality.\n")
    f.write("- Error bars show run-to-run variance (std) across REPEAT trials; ensure repeats are sufficient for stable estimates.\n")

print("✅ Wrote:", out_md)
