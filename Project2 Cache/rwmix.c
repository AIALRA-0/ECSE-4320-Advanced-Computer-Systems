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
