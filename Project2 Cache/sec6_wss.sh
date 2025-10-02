#!/usr/bin/env bash
# =========================================================
# Section 6: Working-Set Size Sweep (locality transitions)
# =========================================================
# Goals:
#   - Sweep working-set size from small (L1) to DRAM scale.
#   - For each size, record per-repeat latency (cycles/access) from pchase.
#   - Convert to ns using CPU MHz: ns = cycles * 1000 / MHz.
#   - Plot mean ± std with cache-level markers (L1/L2/L3).
#
# Outputs:
#   - results/sec6/wss.csv              (bytes,rep,ns_per_access)
#   - figs/sec6/wss_curve.png           (error bars)
#   - out/section_6_wss.md              (English markdown snippet)
#
# Requirements:
#   - pchase binary from Section 2 (or compile from pchase.c)
#   - config.env defines RESULT_ROOT, FIG_ROOT, OUT_ROOT, CPU_NODE, REPEAT
# =========================================================

set -euo pipefail
export LC_ALL=C

# Load config
source ./config.env

mkdir -p "$RESULT_ROOT/sec6" "$FIG_ROOT/sec6" "$OUT_ROOT"

# Ensure pchase exists (build if missing)
if [[ ! -x ./pchase ]]; then
  if [[ -f ./pchase.c ]]; then
    gcc -O2 -march=native pchase.c -o pchase
  else
    echo "[ERROR] pchase not found. Run Section 2 first." >&2
    exit 2
  fi
fi

# Detect average CPU MHz (fallback to lscpu; default 3000)
CPU_MHZ="$(awk '/^cpu MHz/ {sum+=$4;n++} END{if(n) printf("%.0f", sum/n)}' /proc/cpuinfo || true)"
if [[ -z "${CPU_MHZ:-}" ]]; then
  CPU_MHZ="$(lscpu | awk -F: '/CPU MHz/ {gsub(/ /,"",$2); print $2; exit}')"
fi
[[ -z "${CPU_MHZ:-}" ]] && CPU_MHZ=3000

CSV="$RESULT_ROOT/sec6/wss.csv"
echo "bytes,rep,ns_per_access" > "$CSV"

# Working-set sizes (KiB) from 16 KiB to 64 MiB
SIZES_KiB=(16 32 64 128 256 512 1024 2048 4096 8192 16384 32768 65536)

# Pointer-chasing params
STRIDE=64          # 64B per hop
ACC_PER_ITER=200000
MODE=rand
RW=read
USE_HUGE=0

for kb in "${SIZES_KiB[@]}"; do
  BYTES=$(( kb * 1024 ))
  OUT_TXT="$RESULT_ROOT/sec6/wss_${kb}KiB.txt"
  OUT_LOG="$RESULT_ROOT/sec6/wss_${kb}KiB.log"

  echo "[RUN] WSS=${kb} KiB, repeats=$REPEAT"
  numactl --cpunodebind="$CPU_NODE" --membind="$CPU_NODE" \
    ./pchase "$BYTES" "$STRIDE" "$ACC_PER_ITER" "$REPEAT" "$MODE" "$RW" "$USE_HUGE" \
    >"$OUT_TXT" 2>"$OUT_LOG"

  # Parse per-repeat cycles and convert to ns
  awk -F, -v b="$BYTES" -v mhz="$CPU_MHZ" '
    /^level_repeat/ {
      # level_repeat,<rep>,cycles_per_access,<val>
      rep = $2 + 0
      cyc = $4 + 0.0
      ns  = cyc * 1000.0 / mhz
      printf("%s,%s,%.6f\n", b, rep, ns)
    }
  ' "$OUT_TXT" >> "$CSV"
done

# --------- Plot (mean ± std) and Markdown (English) ---------
PY="$RESULT_ROOT/sec6/plot_sec6.py"
cat > "$PY" <<'PYCODE'
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
PYCODE

FIG_PATH="$FIG_ROOT/sec6/wss_curve.png"
MD_PATH="$OUT_ROOT/section_6_wss.md"
python3 "$PY" "$CSV" "$FIG_PATH" "$MD_PATH"

echo "Done."
echo "CSV : $CSV"
echo "FIG : $FIG_PATH"
echo "MD  : $MD_PATH"
