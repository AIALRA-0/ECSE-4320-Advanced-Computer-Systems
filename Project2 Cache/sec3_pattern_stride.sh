#!/usr/bin/env bash
# =========================================================
# Section 3: Pattern & Stride Sweep (Latency & Bandwidth)
# =========================================================
# Goals:
#   - Sweep pattern × stride and measure BOTH latency (ns/access) and bandwidth (GB/s) in the SAME run.
#   - Repeat REPEAT times for each (mode, stride) to compute mean ± std; plot error bars.
#   - Pin CPU and memory to one NUMA node for isolation (via numactl).
#
# Outputs:
#   - CSV: $RESULT_ROOT/sec3/pattern_stride.csv (raw repeats with lat_ns and bw_gbs)
#   - PNG: $FIG_ROOT/sec3/latency_vs_stride.png and bandwidth_vs_stride.png (with error bars)
#   - MD : $OUT_ROOT/section_3_pattern_stride.md (tables + figures + analysis)
#
# Requirements:
#   - config.env defines RESULT_ROOT, FIG_ROOT, OUT_ROOT, CPU_NODE, CORES, REPEAT, RUNTIME_SEC
#   - gcc, python3, numpy, pandas, matplotlib installed (setup_env.sh already ensured)
# =========================================================

set -euo pipefail
export LC_ALL=C
source ./config.env

mkdir -p "$RESULT_ROOT/sec3" "$FIG_ROOT/sec3" "$OUT_ROOT"

# ---------- Helpers ----------
# Count threads from CORES="0-3" or "0,1,2,3"
calc_threads() {
  local c="$1"
  if [[ "$c" =~ ^[0-9]+-[0-9]+$ ]]; then
    local a b; a="${c%-*}"; b="${c#*-}"; echo $(( b - a + 1 ))
  else
    echo "$c" | tr ',' ' ' | awk '{print NF}'
  fi
}

# Read average CPU MHz (used to convert cycles→ns in C fallback if needed)
CPU_MHZ="$(awk '/^cpu MHz/ {sum+=$4; n++} END{if(n) printf("%.0f", sum/n)}' /proc/cpuinfo || true)"
[ -z "${CPU_MHZ:-}" ] && CPU_MHZ="$(lscpu | awk -F: '/CPU MHz/ {gsub(/ /,"",$2); print $2; exit}')"
[ -z "${CPU_MHZ:-}" ] && CPU_MHZ=3000

THREADS=$(calc_threads "$CORES")
[[ "$THREADS" -ge 1 ]] || THREADS=1

# Large array size: far beyond LLC (L3 + 512 MiB), 64B aligned
L3_RAW="$(lscpu | sed -n 's/^L3 cache:[[:space:]]*\(.*\)$/\1/p' | head -n1)"
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
L3_KiB=$(to_kib "${L3_RAW:-}")
[[ "$L3_KiB" -gt 0 ]] || L3_KiB=$((16*1024))
L3_MiB=$(( L3_KiB / 1024 ))
A_BYTES=$(( (L3_MiB + 512) * 1024 * 1024 ))
A_BYTES=$(( (A_BYTES / 64) * 64 ))

# =========================================================
# 1) Build microbenchmark that reports BOTH latency & bandwidth
# =========================================================
cat > membw_lat.c <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <x86intrin.h>
#include <omp.h>
#include <string.h>

// Read TSC
static inline uint64_t rdtsc() { unsigned aux; return __rdtscp(&aux); }

// Shuffle indices for random mode
static void shuffle(size_t *a, size_t n) {
  for (size_t i=n-1; i>0; --i) {
    size_t j = rand() % (i + 1);
    size_t t=a[i]; a[i]=a[j]; a[j]=t;
  }
}

// This benchmark does two things in one run:
// 1) Latency: time a single 64B (8×8B) load group per access (cycles per access).
// 2) Bandwidth: count total bytes moved over wall time (GB/s).
// We repeat "steps" accesses of size "stride" bytes each "loop", so bytes/loop = steps * stride.
// Inside each access we load only the first 64B chunk to measure latency cleanly,
// but for bandwidth we also sweep the whole "stride" in 64B chunks to get real bytes moved.
int main(int argc, char** argv){
  if(argc < 7){
    fprintf(stderr,"usage: %s bytes strideB threads secs mode(seq|rand) cpu_mhz\n", argv[0]);
    return 1;
  }
  size_t bytes   = strtoull(argv[1],0,10);
  size_t stride  = strtoull(argv[2],0,10);
  int threads    = atoi(argv[3]);
  int secs       = atoi(argv[4]);
  const char* mode = argv[5];
  double cpu_mhz = atof(argv[6]); // cycles→ns conversion

  if (stride==0 || bytes<stride) { fprintf(stderr,"bad size/stride\n"); return 2; }
  if (stride % 64 != 0) { fprintf(stderr,"stride must be multiple of 64B\n"); return 3; }

  size_t aligned = (bytes/64)*64; if (aligned<64) aligned=64;
  unsigned char* a = (unsigned char*)aligned_alloc(64, aligned);
  if(!a){perror("aligned_alloc"); return 4;}
  #pragma omp parallel for schedule(static)
  for(size_t i=0;i<aligned;i++) a[i]=(unsigned char)i;

  size_t steps = aligned/stride;
  if (!steps){ fprintf(stderr,"steps=0\n"); return 5; }

  size_t* idx = (size_t*)malloc(steps*sizeof(size_t));
  if(!idx){perror("malloc idx"); return 6;}
  for(size_t i=0;i<steps;i++) idx[i]=i;
  if(strcmp(mode,"rand")==0){ srand(12345); shuffle(idx, steps); }

  const size_t CHUNK = 64;
  volatile uint64_t sink=0;

  // Accumulators across threads: total cycles for the single 64B timing point + total accesses counted
  long double total_cyc = 0.0L;
  long long   access_cnt= 0LL;

  // For bandwidth: count iterations to derive total bytes moved (steps*stride per outer loop)
  long long loops_done = 0LL;
  double t0 = omp_get_wtime();

  #pragma omp parallel num_threads(threads) reduction(+:total_cyc,access_cnt,loops_done,sink)
  {
    while (omp_get_wtime() - t0 < (double)secs) {
      // One "loop": visit all steps once
      for (size_t i=0;i<steps;i++){
        size_t off = idx[i]*stride;

        // ---- Latency timing: measure one 64B group (8×8B) ----
        volatile uint64_t* p = (volatile uint64_t*)(a + off);
        uint64_t c0 = rdtsc();
        sink += p[0]+p[1]+p[2]+p[3]+p[4]+p[5]+p[6]+p[7];
        uint64_t c1 = rdtsc();
        total_cyc += (long double)(c1 - c0);
        access_cnt += 1;

        // ---- Bandwidth accounting: touch the entire stride in 64B chunks ----
        for(size_t b=CHUNK; b<stride; b+=CHUNK){
          volatile uint64_t* q = (volatile uint64_t*)(a + off + b);
          sink += q[0]+q[1]+q[2]+q[3]+q[4]+q[5]+q[6]+q[7];
        }
      }
      loops_done += 1;
    }
  }

  double t1 = omp_get_wtime();
  double secs_used = t1 - t0;

  // Derive metrics
  double cycles_per_access = (access_cnt>0) ? (double)(total_cyc / (long double)access_cnt) : 0.0;
  double ns_per_access = (cpu_mhz>0.0) ? (cycles_per_access * 1000.0 / cpu_mhz) : 0.0;

  long double bytes_moved = (long double)loops_done * (long double)steps * (long double)stride;
  double bw_gbs = (secs_used>0.0) ? (double)(bytes_moved / secs_used / 1e9) : 0.0;

  printf("mode,%s,stride,%zu,threads,%d,lat_ns,%.6f,bw_gbs,%.6f\n",
         mode, stride, threads, ns_per_access, bw_gbs);
  (void)sink;
  return 0;
}
EOF

gcc -O3 -march=native -fopenmp membw_lat.c -o membw_lat

# =========================================================
# 2) Sweep (pattern × stride × repeats)
# =========================================================
STRIDES="64 256 1024"    # bytes per access (multiples of 64B)
MODES="seq rand"
CSV="$RESULT_ROOT/sec3/pattern_stride.csv"
echo "mode,stride_B,threads,lat_ns,bw_gbs" > "$CSV"

for m in $MODES; do
  for s in $STRIDES; do
    echo "[$m][$s B] Running $REPEAT repeats..."
    for r in $(seq 1 "$REPEAT"); do
      echo "  ↳ Repeat $r/$REPEAT"
      numactl --cpunodebind="$CPU_NODE" --membind="$CPU_NODE" \
        ./membw_lat "$A_BYTES" "$s" "$THREADS" "$RUNTIME_SEC" "$m" "$CPU_MHZ" \
        | tee "$RESULT_ROOT/sec3/membw_${m}_${s}_rep${r}.log"

      # Parse one CSV-ish line emitted by membw_lat
      # Example line: mode,seq,stride,64,threads,4,lat_ns,12.345678,bw_gbs,123.456789
      awk -F, '/lat_ns/ {print $2","$4","$6","$8","$10}' \
        "$RESULT_ROOT/sec3/membw_${m}_${s}_rep${r}.log" >> "$CSV" || true
    done
  done
done

# =========================================================
# 3) Plot (error bars) + Markdown (tables + discussion)
#    Use FIG_ROOT / OUT_ROOT directly to avoid brittle relative paths
# =========================================================
PY="$RESULT_ROOT/sec3/plot_sec3.py"
cat > "$PY" <<'PYCODE'
import os, sys
import pandas as pd
import matplotlib.pyplot as plt

csv, fig_root, out_root = sys.argv[1:4]
fig_dir = os.path.join(fig_root, 'sec3')
out_md  = os.path.join(out_root,  'section_3_pattern_stride.md')
os.makedirs(fig_dir, exist_ok=True)
os.makedirs(os.path.dirname(out_md), exist_ok=True)

df = pd.read_csv(csv)
df['stride_B'] = pd.to_numeric(df['stride_B'], errors='coerce')
df['lat_ns']   = pd.to_numeric(df['lat_ns'],   errors='coerce')
df['bw_gbs']   = pd.to_numeric(df['bw_gbs'],   errors='coerce')
df = df.dropna(subset=['stride_B','lat_ns','bw_gbs'])

# Aggregate mean ± std
summary = df.groupby(['mode','stride_B']).agg(
    lat_mean=('lat_ns','mean'),
    lat_std =('lat_ns','std'),
    bw_mean =('bw_gbs','mean'),
    bw_std  =('bw_gbs','std'),
).reset_index()

# --- Plot: Latency with error bars (units) ---
plt.figure(figsize=(7,4.5))
for mode in summary['mode'].unique():
    sub = summary[summary['mode']==mode].sort_values('stride_B')
    plt.errorbar(sub['stride_B'], sub['lat_mean'], yerr=sub['lat_std'],
                 fmt='-o', capsize=5, label=mode)
plt.xscale('log', base=2)
plt.xlabel('Stride (Bytes, log scale)')
plt.ylabel('Latency (ns/access)')
plt.title('Latency vs Stride (mean ± std)')
plt.grid(True, linestyle='--', alpha=0.5)
plt.legend()
lat_png = os.path.join(fig_dir, 'latency_vs_stride.png')
plt.savefig(lat_png, bbox_inches='tight', dpi=150)
plt.close()

# --- Plot: Bandwidth with error bars (units) ---
plt.figure(figsize=(7,4.5))
for mode in summary['mode'].unique():
    sub = summary[summary['mode']==mode].sort_values('stride_B')
    plt.errorbar(sub['stride_B'], sub['bw_mean'], yerr=sub['bw_std'],
                 fmt='-o', capsize=5, label=mode)
plt.xscale('log', base=2)
plt.xlabel('Stride (Bytes, log scale)')
plt.ylabel('Bandwidth (GB/s)')
plt.title('Bandwidth vs Stride (mean ± std)')
plt.grid(True, linestyle='--', alpha=0.5)
plt.legend()
bw_png = os.path.join(fig_dir, 'bandwidth_vs_stride.png')
plt.savefig(bw_png, bbox_inches='tight', dpi=150)
plt.close()

# --- Markdown output (tables + figures + analysis) ---
def md_table(pdf, title):
    cols = ['stride_B'] + list(pdf.columns)
    lines = [f"**{title}**", "| " + " | ".join(map(str, cols)) + " |",
             "| " + " | ".join(["---"]*len(cols)) + " |"]
    for idx, row in pdf.iterrows():
        lines.append("| " + " | ".join([str(idx)] + [str(row[c]) for c in pdf.columns]) + " |")
    return "\n".join(lines)

pivot_lat_mean = summary.pivot(index='stride_B', columns='mode', values='lat_mean').round(3)
pivot_lat_std  = summary.pivot(index='stride_B', columns='mode', values='lat_std').round(3)
pivot_bw_mean  = summary.pivot(index='stride_B', columns='mode', values='bw_mean').round(3)
pivot_bw_std   = summary.pivot(index='stride_B', columns='mode', values='bw_std').round(3)

with open(out_md,'w') as f:
    f.write("## 3. Pattern & Stride Sweep (Latency & Bandwidth)\n\n")
    f.write("### 3.3 Results (Mean ± Std)\n\n")
    f.write(md_table(pivot_lat_mean, "Mean Latency (ns/access)") + "\n\n")
    f.write(md_table(pivot_lat_std,  "StdDev Latency (ns/access)") + "\n\n")
    f.write(md_table(pivot_bw_mean,  "Mean Bandwidth (GB/s)") + "\n\n")
    f.write(md_table(pivot_bw_std,   "StdDev Bandwidth (GB/s)") + "\n\n")
    f.write(f"![Latency](../figs/sec3/{os.path.basename(lat_png)})\n\n")
    f.write(f"![Bandwidth](../figs/sec3/{os.path.basename(bw_png)})\n\n")
    f.write("### 3.4 Result Analysis\n\n")
    f.write("- **Prefetch & stride effects**: smaller strides and sequential access enable HW prefetchers and DRAM row-buffer hits, reducing latency and boosting bandwidth.\n")
    f.write("- **Random & larger strides**: reduce prefetch efficacy, increase row misses and TLB pressure → higher latency and lower bandwidth.\n")
    f.write("- **Error bars** represent run-to-run variability (std) over REPEAT trials.\n")

print("✅ Wrote:", out_md)
PYCODE

# Pass FIG_ROOT and OUT_ROOT explicitly to Python (no relative path math)
python3 "$PY" "$CSV" "$FIG_ROOT" "$OUT_ROOT"

echo "✅ Done."
echo "  CSV : $CSV"
echo "  FIG : $FIG_ROOT/sec3/"
echo "  MD  : $OUT_ROOT/section_3_pattern_stride.md"
