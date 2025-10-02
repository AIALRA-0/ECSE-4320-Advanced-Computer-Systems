import os, sys
import pandas as pd, numpy as np
import matplotlib.pyplot as plt

csv = sys.argv[1]
fig_dir = os.path.join(os.path.abspath(os.path.dirname(csv)), '../../figs/sec7')
out_md  = os.path.join(os.path.abspath(os.path.dirname(csv)), '../../out/section_7_cache_miss.md')
os.makedirs(fig_dir, exist_ok=True)
os.makedirs(os.path.dirname(out_md), exist_ok=True)

df = pd.read_csv(csv)
for col in ['stride','rep','secs','cache_misses','cache_references','LLC_load_misses','L1_dcache_load_misses']:
    df[col] = pd.to_numeric(df[col], errors='coerce').fillna(0)

df['miss_rate'] = np.where(df['cache_references']>0,
                           df['cache_misses']/df['cache_references'], 0.0)

agg = (df.groupby('stride', as_index=False)
         .agg(secs_mean=('secs','mean'),
              secs_std =('secs','std'),
              mr_mean  =('miss_rate','mean'),
              mr_std   =('miss_rate','std'),
              LLC_miss_avg=('LLC_load_misses','mean'),
              L1_miss_avg =('L1_dcache_load_misses','mean'))
         .sort_values('stride'))

plt.figure(figsize=(7,4.5))
plt.errorbar(agg['stride'], agg['secs_mean'], yerr=agg['secs_std'].fillna(0.0),
             fmt='-o', capsize=4)
plt.xlabel('Stride'); plt.ylabel('Runtime (s)')
plt.title('SAXPY runtime vs stride (mean ± std)')
plt.grid(True, linestyle='--', alpha=0.5)
outp1 = os.path.join(fig_dir, 'saxpy_runtime.png')
plt.savefig(outp1, bbox_inches='tight', dpi=150); plt.close()

plt.figure(figsize=(7,4.5))
plt.errorbar(agg['mr_mean'], agg['secs_mean'], yerr=agg['secs_std'].fillna(0.0),
             fmt='o', capsize=4)
plt.xlabel('Cache miss rate'); plt.ylabel('Runtime (s)')
plt.title('SAXPY runtime vs cache miss rate (mean ± std)')
plt.grid(True, linestyle='--', alpha=0.5)
outp2 = os.path.join(fig_dir, 'saxpy_runtime_vs_miss.png')
plt.savefig(outp2, bbox_inches='tight', dpi=150); plt.close()

show = agg.rename(columns={
    'stride':'Stride',
    'secs_mean':'Runtime_mean(s)',
    'secs_std':'Runtime_std(s)',
    'mr_mean':'miss_rate_mean',
    'mr_std':'miss_rate_std',
    'LLC_miss_avg':'LLC_load_misses(avg)',
    'L1_miss_avg':'L1_dcache_load_misses(avg)'
})
with open(out_md,'w') as f:
    f.write("## 7. Cache-Miss impact on a lightweight kernel (SAXPY)\n\n")
    f.write("### 7.3 Results (mean ± std)\n\n")
    f.write(show.to_markdown(index=False, floatfmt='.6f') + "\n\n")
    f.write("![rt_stride](../figs/sec7/saxpy_runtime.png)\n\n")
    f.write("![rt_miss](../figs/sec7/saxpy_runtime_vs_miss.png)\n\n")
    f.write("### 7.4 Discussion\n\n")
    f.write("- According to AMAT ≈ HitTime + MissRate × MissPenalty, increasing stride worsens locality, raises miss rate, and elongates runtime.\n")
    f.write("- Compare L1 vs LLC miss components: larger strides typically inflate LLC-load-misses, which dominates end-to-end time.\n")
print("OK:", outp1, outp2, out_md)
