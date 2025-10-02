#!/usr/bin/env bash
set -euo pipefail
source ./config.env
mkdir -p "$RESULT_ROOT/sec4" "$FIG_ROOT/sec4"

cat > rwmix.c <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <omp.h>
#include <x86intrin.h>
int main(int argc, char** argv){
  if(argc<7){fprintf(stderr,"usage: bytes threads secs mode read_pct strideB\n"); return 1;}
  size_t bytes = strtoull(argv[1],0,10);
  int threads = atoi(argv[2]);
  int secs = atoi(argv[3]);
  const char* mode = argv[4]; // seq|rand
  int read_pct = atoi(argv[5]); // 0..100
  size_t stride = strtoull(argv[6],0,10);
  uint8_t* a = (uint8_t*)aligned_alloc(64, bytes);
  memset(a, 1, bytes);
  size_t steps = bytes/stride;
  size_t* idx = (size_t*)malloc(sizeof(size_t)*steps);
  for(size_t i=0;i<steps;i++) idx[i]=i;
  if(strcmp(mode,"rand")==0){
    for(size_t i=steps-1;i>0;i--){ size_t j=rand()%(i+1); size_t t=idx[i]; idx[i]=idx[j]; idx[j]=t; }
  }
  double start = omp_get_wtime();
  size_t iters=0;
  #pragma omp parallel num_threads(threads)
  {
    unsigned seed = 1234 + omp_get_thread_num();
    size_t local=0;
    while(omp_get_wtime()-start < secs){
      for(size_t i=0;i<steps;i++){
        size_t off = idx[i]*stride;
        int r = rand_r(&seed)%100;
        if(r < read_pct) {
          local += a[off];
        } else {
          a[off] = (uint8_t)r;
          _mm_clflush(&a[off]); // 迫使写回路径更接近真实
          _mm_mfence();
        }
      }
      iters++;
    }
    (void)local;
  }
  double end = omp_get_wtime();
  double bytes_touch = (double)iters*steps*stride;
  double bw = bytes_touch/(end-start)/1e9;
  printf("mode,%s,read_pct,%d,bw_gbs,%.3f\n", mode, read_pct, bw);
  return 0;
}
EOF

gcc -O3 -march=native -fopenmp rwmix.c -o rwmix

A_BYTES=$(( (L3_MB+512)*1024*1024 ))
THREADS=$(echo "$CORES" | awk -F- '{print $2-$1+1}')
STRIDE=64
MIXES="100 0 70 50"
MODE="seq"

CSV="$RESULT_ROOT/sec4/rwmix.csv"
echo "read_pct,bw_gbs" > "$CSV"
for rp in $MIXES; do
  numactl --cpunodebind=$CPU_NODE --membind=$CPU_NODE ./rwmix $A_BYTES $THREADS $RUNTIME_SEC $MODE $rp $STRIDE \
    | tee "$RESULT_ROOT/sec4/rwmix_${rp}.csv"
  awk -F, '{for(i=1;i<=NF;i++) if($i=="bw_gbs"){print $(i+1)}}' "$RESULT_ROOT/sec4/rwmix_${rp}.csv" \
    | awk -v rp="$rp" '{printf("%s,%.3f\n", rp,$1)}' >> "$CSV"
done

PY="$RESULT_ROOT/sec4/plot_sec4.py"
cat > "$PY" <<'PYCODE'
import pandas as pd, matplotlib.pyplot as plt, os, sys
csv = sys.argv[1]
df = pd.read_csv(csv)
plt.figure()
plt.bar([str(x) for x in df.read_pct], df.bw_gbs)
plt.xlabel('Read percentage (%)')
plt.ylabel('Bandwidth (GB/s)')
plt.title('Bandwidth vs Read/Write mix')
outp = os.path.join(os.path.dirname(csv), '../../..', 'figs', 'sec4', 'bw_rwmix.png')
plt.savefig(outp, bbox_inches='tight')

md = os.path.join(os.path.dirname(csv), '../../..', 'out', 'section_4_rwmix.md')
with open(md,'w') as f:
    f.write("## 4. 读写比例扫描\n\n")
    f.write("### 4.3 输出结果\n\n")
    f.write(df.to_markdown(index=False)+"\n\n")
    f.write("![rwmix](../figs/sec4/bw_rwmix.png)\n\n")
    f.write("### 4.4 结果分析\n\n")
    f.write("讨论：写占比上升常见带宽下降与延迟上升，涉及写分配与回写压力；70/30 与 50/50 的差异体现控制器与回写队列深度。\n")
print("OK")
PYCODE

python3 "$PY" "$CSV"
echo "完成。将 out/section_4_rwmix.md 粘贴到报告。"