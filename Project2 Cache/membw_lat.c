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
