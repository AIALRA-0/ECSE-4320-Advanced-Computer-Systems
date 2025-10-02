#!/usr/bin/env bash
# =========================================================
# Section 4: Read/Write Mix Sweep (Bandwidth with error bars)
# =========================================================
# Goals:
#   - Measure sustained bandwidth under different read/write ratios.
#   - Repeat REPEAT times to compute mean ± std and plot error bars.
#   - Pin CPU and memory to one NUMA node (numactl).
#
# Outputs:
#   - Raw CSV (all repeats):   $RESULT_ROOT/sec4/rwmix_raw.csv
#   - Summary CSV (mean/std):  $RESULT_ROOT/sec4/rwmix_summary.csv
#   - Figure (error bars):     $FIG_ROOT/sec4/bw_rwmix.png
#   - Markdown snippet:        $OUT_ROOT/section_4_rwmix.md
#
# Requirements:
#   - config.env defines RESULT_ROOT, FIG_ROOT, OUT_ROOT, CPU_NODE, CORES, REPEAT, RUNTIME_SEC
#   - gcc, python3, numpy, pandas, matplotlib
# =========================================================

set -euo pipefail
export LC_ALL=C
source ./config.env

mkdir -p "$RESULT_ROOT/sec4" "$FIG_ROOT/sec4" "$OUT_ROOT"

# ---------------- Helpers ----------------
# Count threads from CORES="0-3" or "0,1,2,3"
calc_threads() {
  local c="$1"
  if [[ "$c" =~ ^[0-9]+-[0-9]+$ ]]; then
    local a b; a="${c%-*}"; b="${c#*-}"; echo $(( b - a + 1 ))
  else
    echo "$c" | tr ',' ' ' | awk '{print NF}'
  fi
}

# Convert cache text like "36 MiB" to KiB
to_kib() {
  local s="$1"
  local num unit
  num="$(echo "$s" | grep -Eo '[0-9]+' | head -n1 || true)"
  unit="$(echo "$s" | tr '[:lower:]' '[:upper:]' | grep -Eo '(K|M|G)I?B' | head -n1 || true)"
  [[ -z "$num" ]] && { echo 0; return; }
  case "$unit" in
    K*|"") echo "$num" ;;
    M*)    echo $(( num * 1024 )) ;;
    G*)    echo $(( num * 1024 * 1024 )) ;;
    *)     echo "$num" ;;
  esac
}

THREADS=$(calc_threads "$CORES")
[[ "$THREADS" -ge 1 ]] || THREADS=1

# Derive a working-set >> LLC (L3 + 512 MiB), 64B aligned
L3_RAW="$(lscpu | sed -n 's/^L3 cache:[[:space:]]*\(.*\)$/\1/p' | head -n1)"
L3_KiB=$(to_kib "${L3_RAW:-}")
[[ "$L3_KiB" -gt 0 ]] || L3_KiB=$((16*1024))
L3_MiB=$(( L3_KiB / 1024 ))
A_BYTES=$(( (L3_MiB + 512) * 1024 * 1024 ))
A_BYTES=$(( (A_BYTES / 64) * 64 ))

# ---------------- Build benchmark ----------------
cat > rwmix.c <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <omp.h>
#include <x86intrin.h>

// Simple R/W mix memory benchmark:
// - Access pattern: seq | rand
// - read_pct: 0..100 (% of load operations; 100 => all reads)
// - stride: byte step between touched elements
// - Bandwidth counts total bytes touched (reads + writes)
//   Unit reported: GB/s over wall-clock duration
int main(int argc, char** argv){
  if(argc<7){
    fprintf(stderr,"usage: %s bytes threads secs mode(seq|rand) read_pct strideB\n", argv[0]);
    return 1;
  }
  size_t bytes   = strtoull(argv[1],0,10);
  int threads    = atoi(argv[2]);
  int secs       = atoi(argv[3]);
  const char* mode = argv[4];         // "seq" or "rand"
  int read_pct   = atoi(argv[5]);     // 0..100
  size_t stride  = strtoull(argv[6],0,10);

  if (stride==0 || bytes<stride) { fprintf(stderr,"bad size/stride\n"); return 2; }
  if (read_pct<0) read_pct=0; if (read_pct>100) read_pct=100;

  // 64B-aligned region
  size_t aligned = (bytes/64)*64; if (aligned<64) aligned=64;
  uint8_t* a = (uint8_t*)aligned_alloc(64, aligned);
  if(!a){perror("aligned_alloc"); return 3;}
  memset(a, 1, aligned);

  // Build index vector
  size_t steps = aligned / stride;
  if (!steps) { fprintf(stderr,"steps=0\n"); return 4; }
  size_t* idx = (size_t*)malloc(sizeof(size_t)*steps);
  if(!idx){perror("malloc idx"); return 5;}
  for(size_t i=0;i<steps;i++) idx[i]=i;

  // Randomize if needed
  if(strcmp(mode,"rand")==0){
    for(size_t i=steps-1;i>0;i--){
      size_t j=(size_t)(rand()%(int)(i+1));
      size_t t=idx[i]; idx[i]=idx[j]; idx[j]=t;
    }
  }

  double t0 = omp_get_wtime();
  long long loops = 0;

  #pragma omp parallel num_threads(threads) reduction(+:loops)
  {
    unsigned seed = 1234 + omp_get_thread_num();
    volatile unsigned long long sink=0ULL;
    while(omp_get_wtime() - t0 < (double)secs){
      for(size_t i=0;i<steps;i++){
        size_t off = idx[i]*stride;
        int r = (int)(rand_r(&seed)%100);
        if (r < read_pct) {
          // 1B read models a load hit/miss decision; we could also widen loads if needed
          sink += a[off];
        } else {
          a[off] = (uint8_t)r;
          _mm_clflush(&a[off]); // stress writeback path a bit closer to realistic stores
          _mm_mfence();
        }
      }
      loops += 1;
    }
    (void)sink;
  }

  double t1 = omp_get_wtime();
  double secs_used = t1 - t0;

  // Total bytes touched = loops * steps * stride
  double bytes_touch = (double)loops * (double)steps * (double)stride;
  double bw_gbs = (secs_used>0.0) ? (bytes_touch / secs_used / 1e9) : 0.0;

  printf("mode,%s,read_pct,%d,stride,%zu,threads,%d,bw_gbs,%.6f\n",
         mode, read_pct, stride, threads, bw_gbs);
  return 0;
}
EOF

gcc -O3 -march=native -fopenmp rwmix.c -o rwmix

# ---------------- Sweep settings ----------------
# You can measure both patterns by setting: MODES="seq rand"
MODES="seq"
MIXES="100 0 70 50"   # 100%R, 0%R(=100%W), 70%R/30%W, 50/50
STRIDE=64             # access granularity (bytes), must be >=1
CSV_RAW="$RESULT_ROOT/sec4/rwmix_raw.csv"
CSV_SUM="$RESULT_ROOT/sec4/rwmix_summary.csv"

echo "mode,read_pct,stride_B,threads,bw_gbs" > "$CSV_RAW"

for m in $MODES; do
  for rpct in $MIXES; do
    echo "[$m][read=${rpct}%] stride=${STRIDE}B  REPEAT=$REPEAT  t=${RUNTIME_SEC}s"
    for r in $(seq 1 "$REPEAT"); do
      echo "  ↳ repeat $r/$REPEAT"
      numactl --cpunodebind="$CPU_NODE" --membind="$CPU_NODE" \
        ./rwmix "$A_BYTES" "$THREADS" "$RUNTIME_SEC" "$m" "$rpct" "$STRIDE" \
        | tee "$RESULT_ROOT/sec4/rwmix_${m}_${rpct}_rep${r}.log"
      # Extract clean CSV line
      awk -F, '/bw_gbs/ {print $2","$4","$6","$8","$10}' \
        "$RESULT_ROOT/sec4/rwmix_${m}_${rpct}_rep${r}.log" >> "$CSV_RAW" || true
    done
  done
done

# ---------------- Plot + Markdown (error bars, units) ----------------
PY="$RESULT_ROOT/sec4/plot_sec4.py"
cat > "$PY" <<'PYCODE'
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
PYCODE

python3 "$PY" "$CSV_RAW" "$FIG_ROOT" "$OUT_ROOT"

echo "✅ Done."
echo "  RAW : $CSV_RAW"
echo "  SUM : $CSV_SUM"
echo "  FIG : $FIG_ROOT/sec4/bw_rwmix.png"
echo "  MD  : $OUT_ROOT/section_4_rwmix.md"
