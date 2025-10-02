import pandas as pd, matplotlib.pyplot as plt, numpy as np, os, sys

csv = sys.argv[1]
df = pd.read_csv(csv)
fig_dir = os.path.join(os.path.dirname(csv), '../../..', 'figs', 'sec3')
out_md = os.path.join(os.path.dirname(csv), '../../..', 'out', 'section_3_pattern_stride.md')
os.makedirs(fig_dir, exist_ok=True)

# Line charts: bandwidth vs stride for each mode
for mode in df['mode'].unique():
    sub = df[df.mode==mode].copy()
    sub['stride_B'] = sub['stride_B'].astype(int)
    sub = sub.sort_values('stride_B')
    plt.figure()
    plt.plot(sub['stride_B'], sub['bw_gbs'], marker='o')
    plt.xscale('log', base=2)
    plt.xlabel('Stride (bytes, log scale)')
    plt.ylabel('Bandwidth (GB/s)')
    plt.title(f'Bandwidth vs Stride [{mode}]')
    outp = os.path.join(fig_dir, f'bw_stride_{mode}.png')
    plt.savefig(outp, bbox_inches='tight')
    plt.close()

# Build Markdown with graceful fallback if tabulate is missing
pivot = df.pivot_table(index='stride_B', columns='mode', values='bw_gbs').round(2)
def md_table_fallback(pdf):
    # Simple GitHub-flavored markdown without tabulate
    cols = ['stride_B'] + list(pdf.columns)
    lines = []
    header = "| " + " | ".join(map(str, cols)) + " |"
    sep    = "| " + " | ".join(["---"]*len(cols)) + " |"
    lines.append(header); lines.append(sep)
    for idx, row in pdf.iterrows():
        lines.append("| " + " | ".join([str(idx)] + [str(row.get(c, "")) for c in pdf.columns]) + " |")
    return "\n".join(lines)

with open(out_md, 'w') as f:
    f.write("## 3. Pattern & Stride Sweep\n\n")
    f.write("### 3.3 Output Results\n\n")
    try:
        f.write(pivot.to_markdown()+"\n\n")  # requires 'tabulate'
    except Exception:
        f.write(md_table_fallback(pivot)+"\n\n")
    for mode in df['mode'].unique():
        f.write(f"![bw_{mode}](../figs/sec3/bw_stride_{mode}.png)\n\n")
    f.write("### 3.4 Result Analysis\n\n")
    f.write("Small strides and sequential access favor hardware prefetching and DRAM row-buffer hits; random access and large strides reduce prefetch and row hit rates, increasing TLB pressure, and thus bandwidth drops.")
print("OK")
