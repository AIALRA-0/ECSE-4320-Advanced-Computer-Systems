#!/usr/bin/env bash
set -euo pipefail
source ./config.env
mkdir -p "$RESULT_ROOT/sec6" "$FIG_ROOT/sec6"

# 复用 sec2 的 pchase 可执行，如不存在则编译
[ -x ./pchase ] || gcc -O2 -march=native pchase.c -o pchase

CSV="$RESULT_ROOT/sec6/wss.csv"
echo "bytes,ns_per_access" > "$CSV"
MHZ=$(lscpu | awk -F: '/CPU MHz/ {gsub(/ /,"",$2); print $2; exit}')
[ -z "$MHZ" ] && MHZ=3000

for kb in 16 32 64 128 256 512 1024 2048 4096 8192 16384 32768 65536; do
  BYTES=$((kb*1024))
  out=$(numactl --cpunodebind=$CPU_NODE --membind=$CPU_NODE ./pchase $BYTES 64 200000 $REPEAT rand read 0)
  cyc=$(echo "$out" | awk -F, '/cycles_per_access/ {print $8}')
  ns=$(python3 - <<PY
mhz=$MHZ; cyc=float("$cyc"); print(round(cyc/mhz,3))
PY
)
  echo "$BYTES,$ns" >> "$CSV"
done

PY="$RESULT_ROOT/sec6/plot_sec6.py"
cat > "$PY" <<'PYCODE'
import pandas as pd, matplotlib.pyplot as plt, numpy as np, os, sys, re
csv = sys.argv[1]
df = pd.read_csv(csv)
df = df.sort_values('bytes')
plt.figure()
plt.plot(df['bytes']/1024.0, df['ns_per_access'], marker='o')
plt.xscale('log', basex=2)
plt.xlabel('Working set (KiB, log2)')
plt.ylabel('ns per access')
plt.title('Access time vs Working-set size')

# 自动标注层级
def read_size(path, pat, mult):
    import subprocess, re
    try:
        txt = subprocess.check_output(["bash","-lc", "lscpu"]).decode()
        m = re.search(pat, txt)
        if m: return int(m.group(1))*mult
    except: pass
    return None
L1 = read_size("","L1d cache:\\s*(\\d+)K",1024) or 32*1024
L2 = read_size("","L2 cache:\\s*(\\d+)K",1024) or 1024*1024
L3 = read_size("","L3 cache:\\s*(\\d+)M",1024*1024) or 16*1024*1024

for x,val,label in [(L1/1024.0, L1, 'L1'), (L2/1024.0, L2, 'L2'), (L3/1024.0, L3, 'L3')]:
    plt.axvline(x=x, linestyle='--')
    plt.text(x, plt.ylim()[1]*0.8, label, rotation=90)

outp = os.path.join(os.path.dirname(csv), '../../..', 'figs', 'sec6', 'wss_curve.png')
plt.savefig(outp, bbox_inches='tight')

md = os.path.join(os.path.dirname(csv), '../../..', 'out', 'section_6_wss.md')
with open(md,'w') as f:
    f.write("## 6. 工作集大小扫描\n\n")
    f.write("### 6.3 输出结果\n\n")
    f.write(df.to_markdown(index=False)+"\n\n")
    f.write("![wss](../figs/sec6/wss_curve.png)\n\n")
    f.write("### 6.4 结果分析\n\n")
    f.write("标注 L1/L2/L3 界点并解释转折；对比第 2 节零队列延迟，验证各区间量级一致。\n")
print("OK")
PYCODE

python3 "$PY" "$CSV"
echo "完成。将 out/section_6_wss.md 粘贴到报告。"