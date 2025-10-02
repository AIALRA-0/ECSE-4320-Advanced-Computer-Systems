#!/usr/bin/env bash
set -euo pipefail
source ./config.env
mkdir -p "$RESULT_ROOT/sec8" "$FIG_ROOT/sec8"

cat > tlb_kernel.c <<'EOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <sys/mman.h>
#include <string.h>
#include <omp.h>
#include <unistd.h>
#ifndef MADV_HUGEPAGE
#define MADV_HUGEPAGE 14
#endif
int main(int argc, char** argv){
  if(argc<7){fprintf(stderr,"usage: bytes strideB threads secs use_thp rand\n"); return 1;}
  size_t bytes = strtoull(argv[1],0,10);
  size_t stride = strtoull(argv[2],0,10);
  int threads = atoi(argv[3]);
  int secs = atoi(argv[4]);
  int use_thp = atoi(argv[5]);
  int use_rand = atoi(argv[6]);
  uint8_t* a = (uint8_t*)aligned_alloc(4096, bytes);
  memset(a, 1, bytes);
  if(use_thp){ madvise(a, bytes, MADV_HUGEPAGE); }
  size_t steps = bytes/stride;
  size_t* idx = (size_t*)malloc(sizeof(size_t)*steps);
  for(size_t i=0;i<steps;i++) idx[i]=i;
  if(use_rand){
    for(size_t i=steps-1;i>0;i--){ size_t j=rand()%(i+1); size_t t=idx[i]; idx[i]=idx[j]; idx[j]=t; }
  }
  double start = omp_get_wtime();
  size_t iters=0;
  #pragma omp parallel num_threads(threads)
  {
    size_t local=0;
    while(omp_get_wtime()-start < secs){
      for(size_t i=0;i<steps;i++){
        size_t off = idx[i]*stride;
        local += a[off];
      }
      iters++;
    }
    (void)local;
  }
  double end = omp_get_wtime();
  double bytes_touch = (double)iters*steps*stride;
  double bw = bytes_touch/(end-start)/1e9;
  printf("bw_gbs,%.3f\n", bw);
  return 0;
}
EOF

gcc -O3 -march=native -fopenmp tlb_kernel.c -o tlb_kernel

A_BYTES=$(( 2*1024*1024*1024 ))  # 2 GiB，确保超出 TLB reach
THREADS=$(echo "$CORES" | awk -F- '{print $2-$1+1}')
SECS=$RUNTIME_SEC
STRIDES="4096 8192 16384 32768 65536"   # 按页或多页跨步
MODES="0 1"   # THP off/on

CSV="$RESULT_ROOT/sec8/tlb.csv"
echo "strideB,thp,bw_gbs,dtlb_load_misses" > "$CSV"

for thp in $MODES; do
  for s in $STRIDES; do
    echo "THP=$thp stride=$s"
    perf stat -x, -e dTLB-load-misses \
      numactl --cpunodebind=$CPU_NODE --membind=$CPU_NODE ./tlb_kernel $A_BYTES $s $THREADS $SECS $thp 1 \
      1> "$RESULT_ROOT/sec8/tlb_${thp}_${s}.out" 2> "$RESULT_ROOT/sec8/tlb_${thp}_${s}.perf"
    BW=$(awk -F, '/bw_gbs/ {print $2}' "$RESULT_ROOT/sec8/tlb_${thp}_${s}.out")
    DTLB=$(awk -F, '$3=="dTLB-load-misses" {print $1}' "$RESULT_ROOT/sec8/tlb_${thp}_${s}.perf" | head -1)
    echo "$s,$thp,$BW,$DTLB" >> "$CSV"
  done
done

PY="$RESULT_ROOT/sec8/plot_sec8.py"
cat > "$PY" <<'PYCODE'
import pandas as pd, matplotlib.pyplot as plt, numpy as np, os, sys
csv = sys.argv[1]
df = pd.read_csv(csv)
plt.figure()
for thp,label in [(0,'THP off'),(1,'THP on')]:
    sub = df[df.thp==thp].copy()
    sub = sub.sort_values('strideB')
    plt.plot(sub['strideB'], sub['bw_gbs'], marker='o', label=label)
plt.xscale('log', basex=2)
plt.xlabel('Stride (B, log2)')
plt.ylabel('Bandwidth (GB/s)')
plt.title('Bandwidth vs stride with/without THP')
plt.legend()
out1 = os.path.join(os.path.dirname(csv), '../../..', 'figs', 'sec8', 'tlb_bw.png')
plt.savefig(out1, bbox_inches='tight')

plt.figure()
for thp,label in [(0,'THP off'),(1,'THP on')]:
    sub = df[df.thp==thp].copy()
    sub = sub.sort_values('strideB')
    plt.plot(sub['strideB'], sub['dtlb_load_misses'], marker='o', label=label)
plt.xscale('log', basex=2)
plt.yscale('log', basey=10)
plt.xlabel('Stride (B, log2)')
plt.ylabel('dTLB-load-misses (log)')
plt.title('dTLB misses vs stride with/without THP')
plt.legend()
out2 = os.path.join(os.path.dirname(csv), '../../..', 'figs', 'sec8', 'tlb_miss.png')
plt.savefig(out2, bbox_inches='tight')

md = os.path.join(os.path.dirname(csv), '../../..', 'out', 'section_8_tlb.md')
with open(md,'w') as f:
    f.write("## 8. TLB Miss 对轻量核函数的影响\n\n")
    f.write("### 8.3 输出结果\n\n")
    f.write(df.to_markdown(index=False)+"\n\n")
    f.write("![tlb_bw](../figs/sec8/tlb_bw.png)\n\n")
    f.write("![tlb_miss](../figs/sec8/tlb_miss.png)\n\n")
    f.write("### 8.4 结果分析\n\n")
    f.write("讨论：THP 提升 TLB 覆盖范围，降低 dTLB miss；跨页 stride 越大，常见 miss 上升与带宽下降更明显。结合 DTLB reach 计算进行解释。\n")
print("OK")
PYCODE

python3 "$PY" "$CSV"
echo "完成。将 out/section_8_tlb.md 粘贴到报告。"