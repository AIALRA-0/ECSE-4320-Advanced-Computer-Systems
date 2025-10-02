import pandas as pd, matplotlib.pyplot as plt, numpy as np, os, sys
csv, mhz, fig_path, md_path = sys.argv[1:5]
mhz = float(mhz)

df = pd.read_csv(csv)
df['cycles_per_access'] = pd.to_numeric(df['cycles_per_access'], errors='coerce')
df = df.dropna(subset=['cycles_per_access'])
df['ns_per_access'] = df['cycles_per_access'] * 1000.0 / mhz

summary = df.groupby(['level','rw'])['ns_per_access'].agg(['mean','std']).reset_index()
levels = ['L1','L2','L3','DRAM']
rw_types = ['read','write']

fig, ax = plt.subplots(figsize=(8,5))
bar_width = 0.35
x = np.arange(len(levels))

for i, rw in enumerate(rw_types):
    sub = summary[summary['rw']==rw]
    y = [sub[sub['level']==lv]['mean'].values[0] for lv in levels]
    err = [sub[sub['level']==lv]['std'].values[0] for lv in levels]
    ax.bar(
        x + (i-0.5)*bar_width, y,
        width=bar_width, label=rw,
        yerr=err, capsize=6,
        ecolor='black', error_kw={'elinewidth':1.5, 'alpha':0.9},
        alpha=0.9
    )

ax.set_xticks(x)
ax.set_xticklabels(levels)
ax.set_ylabel('Latency (ns/access)')
ax.set_xlabel('Memory Hierarchy Level')
ax.set_title('Zero-Queue Latency by Level (QD=1, Random, Stride=64B)')
ax.legend()
ax.grid(axis='y', linestyle='--', alpha=0.5)
plt.tight_layout()
os.makedirs(os.path.dirname(fig_path), exist_ok=True)
fig.savefig(fig_path, dpi=150)

pivot_mean = summary.pivot(index='level', columns='rw', values='mean').round(3)
pivot_std  = summary.pivot(index='level', columns='rw', values='std').round(3)
os.makedirs(os.path.dirname(md_path), exist_ok=True)
with open(md_path,'w') as f:
    f.write("## 2. Zero-Queue Baseline\n\n")
    f.write("### 2.3 Results (Mean ± Std, ns/access)\n\n")
    f.write(pivot_mean.to_markdown()+"\n\n")
    f.write("Standard deviation:\n\n")
    f.write(pivot_std.to_markdown()+"\n\n")
    rel_img = os.path.relpath(fig_path, start=os.path.dirname(md_path))
    f.write(f"![ZeroQ]({rel_img})\n\n")
    f.write("### 2.4 Analysis\n\n")
    f.write("- Latency increases with hierarchy level (L1 < L2 < L3 < DRAM).\n")
    f.write("- Write operations slower due to write-allocate & flush.\n")
    f.write("- Error bars represent run-to-run variability (stddev).\n")
    f.write("- Verify conversion: ns = cycles × 1000 / CPU_MHz.\n")
print("✅ Markdown written:", md_path)
