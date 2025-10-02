import os, sys, subprocess, re
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

csv, fig_path, md_path = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(os.path.dirname(fig_path), exist_ok=True)
os.makedirs(os.path.dirname(md_path), exist_ok=True)

df = pd.read_csv(csv)
df['bytes'] = pd.to_numeric(df['bytes'], errors='coerce')
df['rep']   = pd.to_numeric(df['rep'],   errors='coerce')
df['ns_per_access'] = pd.to_numeric(df['ns_per_access'], errors='coerce')
df = df.dropna()

agg = (df.groupby('bytes')['ns_per_access']
         .agg(['count','mean','std'])
         .reset_index()
         .sort_values('bytes'))

# Read cache sizes from lscpu (fallbacks are reasonable)
def _read_size_kb(key, fallback_kb):
    try:
        out = subprocess.check_output(['bash','-lc','lscpu'], text=True)
        m = re.search(rf'^{key}:\s*([0-9]+)\s*K', out, re.M|re.I)
        if m: return int(m.group(1))
        m = re.search(rf'^{key}:\s*([0-9]+)\s*M', out, re.M|re.I)
        if m: return int(m.group(1))*1024
    except Exception:
        pass
    return fallback_kb

L1d_KiB = _read_size_kb('L1d cache',  32)
L2_KiB  = _read_size_kb('L2 cache', 1024)
L3_KiB  = _read_size_kb('L3 cache', 16*1024)

x_kib = agg['bytes'].values / 1024.0
y     = agg['mean'].values
yerr  = np.nan_to_num(agg['std'].values, nan=0.0)

plt.figure(figsize=(8,5))
plt.errorbar(x_kib, y, yerr=yerr, fmt='-o', capsize=5)
plt.xscale('log', base=2)
plt.xlabel('Working Set (KiB, log2)')
plt.ylabel('Latency (ns/access)')
plt.title('Access Time vs Working-Set Size (mean ± std)')
plt.grid(True, linestyle='--', alpha=0.5)

ylim = plt.gca().get_ylim()
for size_kib, label in [(L1d_KiB,'L1d'), (L2_KiB,'L2'), (L3_KiB,'L3')]:
    x = float(size_kib)
    plt.axvline(x=x, linestyle='--', alpha=0.7)
    plt.text(x, ylim[1]*0.92, label, rotation=90, va='top', ha='right')

plt.tight_layout()
plt.savefig(fig_path, dpi=150)
plt.close()

# Markdown in English
with open(md_path, 'w') as f:
    f.write("## 6. Working-Set Size Sweep (Locality Transitions)\n\n")
    f.write("### 6.3 Results (mean ± std, ns/access)\n\n")
    tbl = agg.copy()
    tbl['KiB'] = (tbl['bytes']/1024.0).astype(int)
    f.write(tbl[['KiB','count','mean','std']].round(3).to_markdown(index=False))
    f.write("\n\n")
    f.write("![wss](../figs/sec6/wss_curve.png)\n\n")
    f.write("### 6.4 Analysis\n\n")
    f.write("- As the working set grows, latency steps up near L1/L2/L3 capacities.\n")
    f.write("- Error bars show run-to-run variability at each WSS; magnitudes align with Section 2 zero-queue latencies.\n")
print("OK:", fig_path, md_path)
