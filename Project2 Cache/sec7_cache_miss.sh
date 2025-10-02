#!/usr/bin/env bash
set -euo pipefail
source ./config.env
mkdir -p "$RESULT_ROOT/sec7" "$FIG_ROOT/sec7"

cat > saxpy.c <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <omp.h>
void saxpy(float a, float* x, float* y, size_t n, size_t stride){
  #pragma omp parallel for
  for(size_t i=0;i<n;i++){
    size_t idx = (i*stride) % n;
    y[idx] = a * x[idx] + y[idx];
  }
}
int main(int argc, char** argv){
  if(argc<6){fprintf(stderr,"usage: n stride threads reps a\n"); return 1;}
  size_t n = strtoull(argv[1],0,10);
  size_t stride = strtoull(argv[2],0,10);
  int threads = atoi(argv[3]);
  int reps = atoi(argv[4]);
  float a = atof(argv[5]);
  float *x = (float*)aligned_alloc(64, n*sizeof(float));
  float *y = (float*)aligned_alloc(64, n*sizeof(float));
  for(size_t i=0;i<n;i++){ x[i]=1.0f; y[i]=1.0f; }
  double t0 = omp_get_wtime();
  for(int r=0;r<reps;r++) saxpy(a,x,y,n,stride);
  double t1 = omp_get_wtime();
  printf("secs,%.6f\n",(t1-t0));
  return 0;
}
EOF

gcc -O3 -march=native -fopenmp saxpy.c -o saxpy

N=$(( 64*1024*1024 ))   # 元素个数（256MB）
THREADS=$(echo "$CORES" | awk -F- '{print $2-$1+1}')
REPS=5
STRIDES="1 4 8 16 32 64 128 256"

CSV="$RESULT_ROOT/sec7/saxpy_perf.csv"
echo "stride,secs,cache_misses,cache_references,LLC_load_misses,L1_dcache_load_misses" > "$CSV"

for s in $STRIDES; do
  echo "stride=$s"
  perf stat -x, -e cache-misses,cache-references,LLC-load-misses,L1-dcache-load-misses \
    numactl --cpunodebind=$CPU_NODE --membind=$CPU_NODE ./saxpy $N $s $THREADS $REPS 2 \
    1> "$RESULT_ROOT/sec7/saxpy_${s}.out" 2> "$RESULT_ROOT/sec7/saxpy_${s}.perf"
  SECS=$(awk -F, '/secs/ {print $2}' "$RESULT_ROOT/sec7/saxpy_${s}.out")
  MIS=$(awk -F, '$3=="cache-misses" {print $1}' "$RESULT_ROOT/sec7/saxpy_${s}.perf" | head -1)
  REF=$(awk -F, '$3=="cache-references" {print $1}' "$RESULT_ROOT/sec7/saxpy_${s}.perf" | head -1)
  LLC=$(awk -F, '$3=="LLC-load-misses" {print $1}' "$RESULT_ROOT/sec7/saxpy_${s}.perf" | head -1)
  L1M=$(awk -F, '$3=="L1-dcache-load-misses" {print $1}' "$RESULT_ROOT/sec7/saxpy_${s}.perf" | head -1)
  echo "$s,$SECS,$MIS,$REF,$LLC,$L1M" >> "$CSV"
done

PY="$RESULT_ROOT/sec7/plot_sec7.py"
cat > "$PY" <<'PYCODE'
import pandas as pd, matplotlib.pyplot as plt, numpy as np, os, sys
csv = sys.argv[1]
df = pd.read_csv(csv)
df['miss_rate'] = df['cache_misses'] / df['cache_references']
plt.figure()
plt.plot(df['stride'], df['secs'], marker='o')
plt.xlabel('Stride')
plt.ylabel('Runtime (s)')
plt.title('SAXPY runtime vs stride')
outp1 = os.path.join(os.path.dirname(csv), '../../..', 'figs', 'sec7', 'saxpy_runtime.png')
plt.savefig(outp1, bbox_inches='tight')

plt.figure()
plt.plot(df['miss_rate'], df['secs'], marker='o')
plt.xlabel('Cache miss rate')
plt.ylabel('Runtime (s)')
plt.title('SAXPY runtime vs cache miss rate')
outp2 = os.path.join(os.path.dirname(csv), '../../..', 'figs', 'sec7', 'saxpy_runtime_vs_miss.png')
plt.savefig(outp2, bbox_inches='tight')

md = os.path.join(os.path.dirname(csv), '../../..', 'out', 'section_7_cache_miss.md')
with open(md,'w') as f:
    f.write("## 7. Cache Miss 对轻量核函数的影响\n\n")
    f.write("### 7.3 输出结果\n\n")
    f.write(df[['stride','secs','miss_rate','LLC_load_misses','L1_dcache_load_misses']].round(6).to_markdown(index=False)+"\n\n")
    f.write("![rt_stride](../figs/sec7/saxpy_runtime.png)\n\n")
    f.write("![rt_miss](../figs/sec7/saxpy_runtime_vs_miss.png)\n\n")
    f.write("### 7.4 结果分析\n\n")
    f.write("结合 AMAT = HitTime + MissRate*MissPenalty，说明 stride 增大导致 miss_rate 上升进而拉长总时间；对比 LLC 与 L1 miss 的贡献。\n")
print("OK")
PYCODE

python3 "$PY" "$CSV"
echo "完成。将 out/section_7_cache_miss.md 粘贴到报告。"