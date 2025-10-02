#!/usr/bin/env bash
# =========================================================
# Section 7: Cache-miss impact on a lightweight kernel (SAXPY)
# =========================================================
# What this script does
#   1) Build an OpenMP SAXPY micro-kernel.
#   2) Sweep strides and collect runtime + perf counters.
#   3) Robustly parse perf CSV; sum cpu_core/… and cpu_atom/… lines.
#   4) Aggregate mean±std and emit CSV, figures, and a markdown snippet.
#
# Why the previous run stopped early
#   Using: perf stat … bash -lc "run_on_node …"
#   The shell function run_on_node is not visible inside "bash -lc",
#   which causes "command not found" and exits under `set -e`.
#
# Outputs
#   - results/sec7/saxpy_perf.csv
#   - figs/sec7/saxpy_runtime.png
#   - figs/sec7/saxpy_runtime_vs_miss.png
#   - out/section_7_cache_miss.md
#
# Notes
#   - No Intel MLC needed for Section 7.
#   - Requires: gcc, perf, Python3 + matplotlib/pandas, (optional) numactl.
# =========================================================

set -euo pipefail
export LC_ALL=C

# ----- Load config: RESULT_ROOT, FIG_ROOT, OUT_ROOT, CPU_NODE, REPEAT, CORES
source ./config.env

mkdir -p "$RESULT_ROOT/sec7" "$FIG_ROOT/sec7" "$OUT_ROOT"

# ----- Resolve thread count from $CORES ("0-7" or "0,2,4,6")
calc_threads() {
  local c="${1:-}"
  if [[ -z "$c" ]]; then echo 1; return; fi
  if [[ "$c" =~ ^[0-9]+-[0-9]+$ ]]; then
    local a b; a="${c%-*}"; b="${c#*-}"; echo $(( b - a + 1 ))
  else
    echo "$c" | tr ',' ' ' | awk '{print NF}'
  fi
}
THREADS=$(calc_threads "${CORES:-}")
[[ "$THREADS" -ge 1 ]] || THREADS=1

export OMP_NUM_THREADS="$THREADS"
export OMP_PROC_BIND=TRUE
export OMP_PLACES=cores

# ----- Build SAXPY (keeps total work constant across strides)
cat > saxpy.c <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <omp.h>

/* Touch all elements exactly once per pass for any stride. */
static void saxpy_pass(float a, const float* x, float* y, size_t n, size_t stride) {
  for (size_t phase = 0; phase < stride; ++phase) {
    #pragma omp parallel for schedule(static)
    for (size_t i = phase; i < n; i += stride) {
      y[i] = a * x[i] + y[i];
    }
  }
}

int main(int argc, char** argv){
  if (argc < 6) { fprintf(stderr,"usage: n stride threads reps a\n"); return 1; }
  size_t n      = strtoull(argv[1], 0, 10);
  size_t stride = strtoull(argv[2], 0, 10);
  int    thr    = atoi(argv[3]);
  int    reps   = atoi(argv[4]);
  float  a      = (float)atof(argv[5]);
  if (stride == 0 || stride > n) { fprintf(stderr,"bad stride\n"); return 2; }

  float *x = (float*)aligned_alloc(64, n*sizeof(float));
  float *y = (float*)aligned_alloc(64, n*sizeof(float));
  if (!x || !y) { perror("aligned_alloc"); return 3; }
  #pragma omp parallel for schedule(static)
  for (size_t i=0;i<n;i++){ x[i]=1.0f; y[i]=1.0f; }

  omp_set_num_threads(thr);
  double t0 = omp_get_wtime();
  for (int r=0; r<reps; r++) saxpy_pass(a, x, y, n, stride);
  double t1 = omp_get_wtime();
  printf("secs,%.6f\n", (t1 - t0));
  free(x); free(y);
  return 0;
}
EOF

gcc -std=c11 -O3 -march=native -fopenmp saxpy.c -o saxpy

# ----- Work size + sweep setup
N=$(( 64*1024*1024 ))     # 64M elements => ~256MB per array; x+y ≈ 512MB (> LLC)
A_VAL=2
REPS_INNER=1              # one pass per run; outer REPEAT drives error bars
STRIDES="1 4 8 16 32 64 128"

CSV="$RESULT_ROOT/sec7/saxpy_perf.csv"
echo "stride,rep,secs,cache_misses,cache_references,LLC_load_misses,L1_dcache_load_misses" > "$CSV"

# ----- Helper: build the command array (with or without numactl)
build_cmd_array() {
  local stride="$1"
  if command -v numactl >/dev/null 2>&1; then
    echo numactl --cpunodebind="$CPU_NODE" --membind="$CPU_NODE" ./saxpy "$N" "$stride" "$THREADS" "$REPS_INNER" "$A_VAL"
  else
    echo ./saxpy "$N" "$stride" "$THREADS" "$REPS_INNER" "$A_VAL"
  fi
}

# ----- Sweep + collect
for s in $STRIDES; do
  for r in $(seq 1 "${REPEAT:-3}"); do
    echo "[RUN] stride=$s  rep=$r/${REPEAT:-3}"
    OUT_TXT="$RESULT_ROOT/sec7/saxpy_${s}_rep${r}.out"
    PERF_TXT="$RESULT_ROOT/sec7/saxpy_${s}_rep${r}.perf"

    # Build the actual argv for perf
    # shellcheck disable=SC2207
    CMD_ARR=($(build_cmd_array "$s"))

    # Run perf; stdout (program) -> OUT_TXT ; stderr (perf CSV) -> PERF_TXT
    perf stat --no-big-num -x, \
      -e cache-references,cache-misses,LLC-load-misses,L1-dcache-load-misses \
      -- "${CMD_ARR[@]}" \
      1> "$OUT_TXT" 2> "$PERF_TXT"

    # secs from program stdout
    SECS="$(awk -F, '/^secs/ {print $2; exit}' "$OUT_TXT")"
    [[ -z "$SECS" ]] && SECS=0

    # Sum values across any line containing the event substring
    val_sum() {
      local ev="$1"
      awk -F, -v ev="$ev" '
        index($0, ev) {
          gsub(/ /,"",$1);                  # strip spaces
          if ($1 ~ /^</ || $1 == "") next;  # skip <not supported>/blanks
          sum += $1 + 0
        }
        END { if (sum == 0 || sum == "") print 0; else printf("%.0f\n", sum) }
      ' "$PERF_TXT"
    }

    MIS="$(val_sum 'cache-misses')"
    REF="$(val_sum 'cache-references')"
    LLC="$(val_sum 'LLC-load-misses')"
    L1M="$(val_sum 'L1-dcache-load-misses')"

    echo "$s,$r,$SECS,$MIS,$REF,$LLC,$L1M" >> "$CSV"
  done
done

# ----- Plot & Markdown
PY="$RESULT_ROOT/sec7/plot_sec7.py"
cat > "$PY" <<'PYCODE'
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
PYCODE

python3 "$PY" "$CSV"

echo "Done."
echo "CSV : $CSV"
echo "FIG : $FIG_ROOT/sec7/saxpy_runtime.png"
echo "FIG : $FIG_ROOT/sec7/saxpy_runtime_vs_miss.png"
echo "MD  : $OUT_ROOT/section_7_cache_miss.md"
