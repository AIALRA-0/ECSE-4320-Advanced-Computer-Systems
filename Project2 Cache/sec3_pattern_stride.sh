#!/usr/bin/env bash
# Section 3: Pattern & Stride Sweep (Bandwidth)
# - Robust cache-size parsing from lscpu (handles K/M/G)
# - Uses OpenMP kernel with proper reduction (no data races)
# - Creates figure/output directories if missing
# - MLC is optional and logged only; membw is the ground truth
# - English comments throughout

set -euo pipefail
source ./config.env

mkdir -p "$RESULT_ROOT/sec3" "$FIG_ROOT/sec3" "$OUT_ROOT"

# ---- Helpers: safely parse cache sizes (to KiB) ----
to_kib() {
  # Convert strings like "48 KiB", "2 MiB", "36 MB" -> KiB (integer)
  local s="$1"
  local num unit
  num="$(echo "$s" | grep -Eo '[0-9]+' | head -n1 || true)"
  unit="$(echo "$s" | tr '[:lower:]' '[:upper:]' | grep -Eo '(K|M|G)I?B' | head -n1 || true)"
  if [[ -z "$num" ]]; then echo 0; return; fi
  case "$unit" in
    K*|"") echo "$num" ;;
    M*) echo $(( num * 1024 )) ;;
    G*) echo $(( num * 1024 * 1024 )) ;;
    *) echo "$num" ;;
  esac
}

L1D_RAW="$(lscpu | sed -n 's/^L1d cache:[[:space:]]*\(.*\)$/\1/p' | head -n1)"
L2_RAW="$( lscpu | sed -n 's/^L2 cache:[[:space:]]*\(.*\)$/\1/p' | head -n1)"
L3_RAW="$( lscpu | sed -n 's/^L3 cache:[[:space:]]*\(.*\)$/\1/p' | head -n1)"

L1D_KiB=$(to_kib "${L1D_RAW:-}")
L2_KiB=$( to_kib "${L2_RAW:-}")
L3_KiB=$( to_kib "${L3_RAW:-}")

# Fallbacks if parsing fails
[[ "$L1D_KiB" -gt 0 ]] || L1D_KiB=32
[[ "$L2_KiB"  -gt 0 ]] || L2_KiB=1024
[[ "$L3_KiB"  -gt 0 ]] || L3_KiB=$((16*1024))

# Build a large array much bigger than LLC (L3 + 512 MiB)
L3_MiB=$(( L3_KiB / 1024 ))
[[ "$L3_MiB" -gt 0 ]] || L3_MiB=16   # fallback if parsing failed
A_BYTES=$(( (L3_MiB + 512) * 1024 * 1024 ))
A_BYTES=$(( (A_BYTES / 64) * 64 ))   # aligned to 64B

# ---- Derive thread count from CORES ("0-3" or "0,1,2,3") ----
calc_threads() {
  local c="$1"
  if [[ "$c" =~ ^[0-9]+-[0-9]+$ ]]; then
    local a b; a="${c%-*}"; b="${c#*-}"; echo $(( b - a + 1 ))
  else
    # comma or space separated
    echo "$c" | tr ',' ' ' | awk '{print NF}'
  fi
}
THREADS=$(calc_threads "$CORES")
[[ "$THREADS" -ge 1 ]] || THREADS=1

# ---- Build bandwidth micro-benchmark ----
cat > membw.c <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <x86intrin.h>
#include <omp.h>

static void fisher_yates(size_t *a, size_t n) {
  for (size_t i=n-1; i>0; --i) {
    size_t j = (size_t) (rand() % (int)(i + 1));
    size_t t = a[i]; a[i] = a[j]; a[j] = t;
  }
}

int main(int argc, char** argv){
  if(argc < 6){
    fprintf(stderr,"usage: %s bytes strideB threads seconds mode(seq|rand)\n", argv[0]);
    return 1;
  }
  size_t bytes   = strtoull(argv[1],0,10);
  size_t stride  = strtoull(argv[2],0,10);
  int threads    = atoi(argv[3]);
  int secs       = atoi(argv[4]);
  const char* mode = argv[5]; // seq|rand

  if (stride == 0 || bytes < stride) {
    fprintf(stderr,"invalid size/stride\n");
    return 2;
  }

  // aligned_alloc requires size multiple of alignment
  size_t aligned = (bytes / 64) * 64;
  if (aligned < 64) aligned = 64;
  uint8_t* a = (uint8_t*)aligned_alloc(64, aligned);
  if (!a) { perror("aligned_alloc"); return 3; }

  // first-touch init (respect numactl policy)
  #pragma omp parallel for schedule(static)
  for (size_t i=0;i<aligned;i++) a[i] = (uint8_t)(i);

  size_t steps = aligned / stride;
  if (steps == 0) { fprintf(stderr,"steps=0\n"); return 4; }

  size_t* idx = (size_t*)malloc(sizeof(size_t)*steps);
  if (!idx) { perror("malloc idx"); return 5; }
  for(size_t i=0;i<steps;i++) idx[i]=i;

  if(strcmp(mode,"rand")==0){
    srand(12345);
    fisher_yates(idx, steps);
  }

  double start = omp_get_wtime();
  long long iters_total = 0;

  #pragma omp parallel num_threads(threads) reduction(+:iters_total)
  {
    volatile uint8_t sink = 0;
    while(omp_get_wtime() - start < (double)secs){
      for(size_t i=0;i<steps;i++){
        size_t off = idx[i]*stride;
        sink += a[off];
      }
      iters_total++;
    }
    (void)sink;
  }

  double end = omp_get_wtime();
  double seconds = end - start;
  long double bytes_read = (long double)iters_total * (long double)steps * (long double)stride;
  double bw = (double)(bytes_read / seconds / 1e9);

  printf("bytes,%zu,stride,%zu,threads,%d,secs,%d,mode,%s,bw_gbs,%.3f\n",
         aligned, stride, threads, secs, mode, bw);
  return 0;
}
EOF

gcc -O3 -march=native -fopenmp membw.c -o membw

STRIDES="64 256 1024"
MODES="seq rand"

CSV="$RESULT_ROOT/sec3/pattern_stride.csv"
echo "mode,stride_B,threads,bw_gbs" > "$CSV"

# ---- Optional MLC run (reference only) ----
USE_MLC=0
if command -v mlc >/dev/null 2>&1; then
  if mlc --help 2>&1 | grep -q -- "--max_bandwidth"; then
    USE_MLC=1
  fi
fi

for m in $MODES; do
  for s in $STRIDES; do
    if [ $USE_MLC -eq 1 ]; then
      echo "MLC reference: --max_bandwidth (duration=${RUNTIME_SEC}s) -> logged only"
      mlc --max_bandwidth -t "$THREADS" --time "$RUNTIME_SEC" \
        2> "$RESULT_ROOT/sec3/mlc_${m}_${s}.log" \
        | tee "$RESULT_ROOT/sec3/mlc_${m}_${s}.txt" || true
    fi
    
    echo "membw run: mode=$m, stride=${s}B, threads=$THREADS, size=${A_BYTES}B, t=${RUNTIME_SEC}s"
    numactl --cpunodebind="$CPU_NODE" --membind="$CPU_NODE" \
      ./membw "$A_BYTES" "$s" "$THREADS" "$RUNTIME_SEC" "$m" \
      | tee "$RESULT_ROOT/sec3/membw_${m}_${s}.csv"

    # Extract bw_gbs from the CSV line produced by membw
    awk -F, '
      { for(i=1;i<=NF;i++) if($i=="bw_gbs"){ print $(i+1) } }
    ' "$RESULT_ROOT/sec3/membw_${m}_${s}.csv" \
    | awk -v m="$m" -v s="$s" -v t="$THREADS" '{printf("%s,%s,%s,%.3f\n", m,s,t,$1)}' >> "$CSV"
  done
done

# ---- Plot & Markdown (robust to missing `tabulate`) ----
PY="$RESULT_ROOT/sec3/plot_sec3.py"
cat > "$PY" <<'PYCODE'
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
PYCODE

python3 "$PY" "$CSV"
echo "Done. Paste out/section_3_pattern_stride.md into your report."
