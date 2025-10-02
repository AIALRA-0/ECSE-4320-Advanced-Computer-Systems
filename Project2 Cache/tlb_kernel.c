/*
 * TLB stress kernel:
 * - Accesses memory with page-scale or multi-page strides to modulate dTLB pressure.
 * - Optional THP hint via madvise(MADV_HUGEPAGE).
 * - Optional randomization of access order to defeat simple HW prefetchers.
 * - Reports effective bandwidth (GB/s) as 64B/access * accesses / elapsed_time.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <sys/mman.h>
#include <omp.h>
#include <unistd.h>

#ifndef MADV_HUGEPAGE
#define MADV_HUGEPAGE 14
#endif

static void fisher_yates(size_t *a, size_t n) {
  for (size_t i=n-1; i>0; --i) {
    size_t j = (size_t)(rand() % (int)(i + 1));
    size_t t = a[i]; a[i] = a[j]; a[j] = t;
  }
}

static size_t round_up(size_t x, size_t a) {
  return (x + a - 1) / a * a;
}

int main(int argc, char** argv){
  if(argc < 7){
    fprintf(stderr,"usage: %s bytes strideB threads secs use_thp use_rand\n", argv[0]);
    return 1;
  }
  size_t bytes   = strtoull(argv[1],0,10);
  size_t stride  = strtoull(argv[2],0,10);
  int threads    = atoi(argv[3]);
  int secs       = atoi(argv[4]);
  int use_thp    = atoi(argv[5]);   // 0=off, 1=on (madvise)
  int use_rand   = atoi(argv[6]);   // 0=seq, 1=rand

  if (stride == 0) { fprintf(stderr,"invalid stride\n"); return 2; }

  // Page-aligned allocation; size is a multiple of page size
  size_t page = (size_t)sysconf(_SC_PAGESIZE);
  size_t need = round_up(bytes, page);
  uint8_t* a = (uint8_t*)aligned_alloc(page, need);
  if (!a) { perror("aligned_alloc"); return 3; }

  // First-touch initialization and THP hint (if requested)
  #pragma omp parallel for schedule(static)
  for (size_t i=0;i<need;i++) a[i] = 1;
  if (use_thp) (void)madvise(a, need, MADV_HUGEPAGE);

  // Build visitation order
  size_t steps = need / stride;
  if (steps == 0) { fprintf(stderr,"steps=0\n"); return 4; }

  size_t* idx = (size_t*)malloc(sizeof(size_t)*steps);
  if (!idx) { perror("malloc idx"); return 5; }
  for(size_t i=0;i<steps;i++) idx[i]=i;
  if(use_rand){ srand(12345); fisher_yates(idx, steps); }

  double start = omp_get_wtime();
  long long iters_total = 0;

  #pragma omp parallel num_threads(threads) reduction(+:iters_total)
  {
    volatile uint8_t sink = 0;
    while(omp_get_wtime() - start < (double)secs){
      for(size_t i=0;i<steps;i++){
        size_t off = idx[i]*stride;
        sink += a[off];  // touch 1 byte; at least 1 CL (64B) fetched
      }
      iters_total++;
    }
    (void)sink;
  }

  double end = omp_get_wtime();
  double seconds = end - start;

  // 64B per access approximation (one cache line per unique touch)
  long double touches = (long double)iters_total * (long double)steps;
  double bw_gbs = (double)(touches * 64.0 / seconds / 1e9);

  printf("secs,%.6f\n", seconds);
  printf("touches,%.0Lf\n", touches);
  printf("bw_gbs,%.6f\n", bw_gbs);
  return 0;
}
