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
