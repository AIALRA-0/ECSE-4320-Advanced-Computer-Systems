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
