import os, sys, numpy as np, pandas as pd, matplotlib.pyplot as plt
raw_csv, fig_dir, out_md = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(fig_dir, exist_ok=True); os.makedirs(os.path.dirname(out_md), exist_ok=True)

df = pd.read_csv(raw_csv)
df['bandwidth_gbs'] = pd.to_numeric(df['bandwidth_gbs'], errors='coerce')
df['latency_ns']    = pd.to_numeric(df['latency_ns'], errors='coerce')
df = df.dropna()

# Bucket throughput (0.25 GB/s) so multiple runs align; compute mean ± std of latency
df['bw_bucket'] = (df['bandwidth_gbs']/0.25).round()*0.25
agg = (df.groupby('bw_bucket')['latency_ns']
         .agg(['count','mean','std'])
         .reset_index()
         .rename(columns={'bw_bucket':'bandwidth_gbs'})).sort_values('bandwidth_gbs')

fig_path = os.path.join(fig_dir, 'throughput_latency.png')
knee_txt = "N/A"

if len(agg) >= 2:
    plt.figure(figsize=(7.5,5))
    plt.errorbar(agg['bandwidth_gbs'], agg['mean'],
                 yerr=agg['std'].fillna(0.0),
                 fmt='-o', capsize=5)
    plt.xlabel('Throughput (GB/s)')
    plt.ylabel('Latency (ns)')
    plt.title('Throughput–Latency (MLC loaded_latency, mean ± std)')
    plt.grid(True, linestyle='--', alpha=0.5)
    plt.savefig(fig_path, bbox_inches='tight', dpi=150)
    plt.close()

    # Knee via curvature on the mean curve
    x = agg['bandwidth_gbs'].values; y = agg['mean'].values
    order = np.argsort(x); x, y = x[order], y[order]
    if len(x) >= 3 and np.all(np.diff(x) > 0):
        try:
            d1 = np.gradient(y, x, edge_order=2)
            d2 = np.gradient(d1,  x, edge_order=2)
            curv = np.abs(d2) / (1 + d1**2)**1.5
            i = int(np.argmax(curv))
            knee_txt = f"BW≈{x[i]:.2f} GB/s, Lat≈{y[i]:.1f} ns"
        except Exception:
            knee_txt = "N/A"
else:
    # If we do not have enough buckets, show scatter (still with units)
    plt.figure(figsize=(7.5,5))
    plt.scatter(df['bandwidth_gbs'], df['latency_ns'], s=18)
    plt.xlabel('Throughput (GB/s)')
    plt.ylabel('Latency (ns)')
    plt.title('Throughput–Latency (scatter)')
    plt.grid(True, linestyle='--', alpha=0.5)
    plt.savefig(fig_path, bbox_inches='tight', dpi=150)
    plt.close()

# Markdown (no external deps)
with open(out_md, 'w') as f:
    f.write("## 5. Access Intensity Sweep (MLC Loaded Latency)\n\n")
    f.write("### 5.3 Output Results (bucketed by throughput)\n\n")
    if len(agg):
        f.write("| Throughput (GB/s) | Mean Latency (ns) | Std (ns) | Count |\n")
        f.write("| --- | --- | --- | --- |\n")
        for _, r in agg.iterrows():
            std = 0.0 if pd.isna(r['std']) else r['std']
            f.write(f"| {r['bandwidth_gbs']:.2f} | {r['mean']:.2f} | {std:.2f} | {int(r['count'])} |\n")
        f.write("\n")
    f.write(f"**Knee (approx.)**: {knee_txt}\n\n")
    f.write("![Throughput–Latency](../figs/sec5/throughput_latency.png)\n\n")
    f.write("### 5.4 Analysis\n\n")
    f.write("- As injected throughput rises, queueing delays increase, so average latency climbs; after the knee, returns diminish.\n")
    f.write("- Error bars denote standard deviation across REPEAT runs per throughput bucket.\n")
print("OK:", fig_dir, fig_path, out_md)
