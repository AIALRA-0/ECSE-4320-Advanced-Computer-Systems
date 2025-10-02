#define _GNU_SOURCE
#include <immintrin.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <x86intrin.h>
#include <unistd.h>
#include <sys/mman.h>

static inline uint64_t rdtsc() {
  unsigned aux;
  return __rdtscp(&aux);
}

static void shuffle(size_t *a, size_t n) {
  for (size_t i = n - 1; i > 0; --i) {
    size_t j = rand() % (i + 1);
    size_t t = a[i]; a[i] = a[j]; a[j] = t;
  }
}

int main(int argc, char** argv) {
  if (argc < 7) {
    fprintf(stderr, "usage: %s bytes stride access_per_iter repeats mode readwrite [use_huge]\n", argv[0]);
    return 1;
  }
  size_t bytes = strtoull(argv[1], NULL, 10);
  size_t stride = strtoull(argv[2], NULL, 10);
  size_t access_per_iter = strtoull(argv[3], NULL, 10);
  int repeats = atoi(argv[4]);
  const char* mode = argv[5];    // "rand" or "seq"
  const char* rw = argv[6];      // "read" or "write"
  int use_huge = (argc > 7) ? atoi(argv[7]) : 0;

  size_t elems = bytes / sizeof(size_t);
  if (elems < 2) elems = 2;

  size_t pagesize = sysconf(_SC_PAGESIZE);
  size_t map_bytes = ((bytes + pagesize - 1) / pagesize) * pagesize;
  int flags = MAP_PRIVATE | MAP_ANONYMOUS;
#ifdef MAP_HUGETLB
  if (use_huge) flags |= MAP_HUGETLB;
#endif
  size_t* buf = mmap(NULL, map_bytes, PROT_READ|PROT_WRITE, flags, -1, 0);
  if (buf == MAP_FAILED) { perror("mmap"); return 2; }

  // Build index order
  size_t *idx = (size_t*)malloc(elems * sizeof(size_t));
  if (!idx) { perror("malloc"); return 3; }
  for (size_t i=0; i<elems; ++i) idx[i] = i;
  if (strcmp(mode, "rand")==0) shuffle(idx, elems);

  size_t step_stride = stride / sizeof(size_t);
  if (step_stride == 0) step_stride = 1;

  // Single-linked ring
  for (size_t i=0; i<elems; ++i) {
    size_t next = (i + step_stride) % elems;
    buf[idx[i]] = (size_t)&buf[idx[next]];
  }

  // Warmup
  volatile size_t *p = (volatile size_t*)&buf[idx[0]];
  for (size_t i=0; i<10000; ++i) p = (volatile size_t*)(*p);

  // Measure best-of-N
  double best_cycles = 1e100;
  for (int r=0; r<repeats; ++r) {
    _mm_mfence();
    uint64_t t0 = rdtsc();
    volatile size_t *x = (volatile size_t*)&buf[idx[0]];
    size_t sink=0;
    for (size_t k=0; k<access_per_iter; ++k) {
      if (strcmp(rw,"read")==0) {
        x = (volatile size_t*)(*x);
      } else {
        *((volatile size_t*)x) = (size_t)x;  // simple store
        _mm_clflush((void*)x);               // stress store path
        _mm_mfence();
        x = (volatile size_t*)(*x);
      }
      sink += (size_t)x;                     // defeat DCE
    }
    uint64_t t1 = rdtsc();
    double cyc = (double)(t1 - t0) / access_per_iter;
    if (cyc < best_cycles) best_cycles = cyc;
    fprintf(stderr, "rep=%02d guard=%zu cycles_per_access=%.2f\n", r, sink, cyc);
  }

  // Parse-friendly CSV (no spaces in keys)
  printf("bytes,%zu,stride,%zu,mode,%s,rw,%s,cycles_per_access,%.2f\n",
         bytes, stride, mode, rw, best_cycles);
  return 0;
}
