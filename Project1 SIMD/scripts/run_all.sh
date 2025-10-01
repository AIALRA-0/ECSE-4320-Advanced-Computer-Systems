#!/usr/bin/env bash
set -euo pipefail

PIN=1
REPS=7

KERNELS=("saxpy" "dot" "mul" "stencil")
DTYPES=("f32" "f64")
STRIDES=(1 2 4 8)
MISALIGNS=(0 1)

# Original N (mostly 2^k, easy to be multiples, keep them)
Ns=( 512 1024 2048 4096 8192 65536 1048576 8388608 33554432 67108864 )

Ns_tail_f32=()
Ns_tail_f64=()

for n in "${Ns[@]}"; do
  Ns_tail_f32+=($((n+1)))
  Ns_tail_f64+=($((n+2))) # ensure not multiple of 4
done

outdir="data"
mkdir -p "$outdir"

logfile="run.log"
: > "$logfile"

run(){ exe=$1; tag=$2

  # 1) First run “regular N”
  for k in "${KERNELS[@]}"; do
    for dt in "${DTYPES[@]}"; do
      for n in "${Ns[@]}"; do
        # stencil restriction
        if [[ "$k" == "stencil" && $n -lt 1024 ]]; then continue; fi
        if [[ "$k" == "stencil" ]]; then strides=(1); else strides=("${STRIDES[@]}"); fi

        for s in "${strides[@]}"; do
          for m in "${MISALIGNS[@]}"; do
            echo "$tag,$k,$dt,N=$n,stride=$s,mis=$m" | tee -a "$logfile"
            args=(--kernel $k --dtype $dt --n $n --stride $s --reps $REPS --pin $PIN --verify)
            if [[ $m -eq 1 ]]; then args+=(--misalign); fi
            ./$exe "${args[@]}" >> "$outdir/${tag}.csv"
          done
        done
      done
    done
  done

  # 2) Then run “non-multiple N” (only to generate tail-processing samples; still cover stride/misalign)
  for k in "${KERNELS[@]}"; do
    for dt in "${DTYPES[@]}"; do
      if [[ "$dt" == "f32" ]]; then Ns_tail=("${Ns_tail_f32[@]}"); else Ns_tail=("${Ns_tail_f64[@]}"); fi

      for n in "${Ns_tail[@]}"; do
        if [[ "$k" == "stencil" && $n -lt 1024 ]]; then continue; fi
        if [[ "$k" == "stencil" ]]; then strides=(1); else strides=("${STRIDES[@]}"); fi

        for s in "${strides[@]}"; do
          for m in "${MISALIGNS[@]}"; do
            echo "$tag,$k,$dt,N=$n,stride=$s,mis=$m (TAIL)" | tee -a "$logfile"
            args=(--kernel $k --dtype $dt --n $n --stride $s --reps $REPS --pin $PIN --verify)
            if [[ $m -eq 1 ]]; then args+=(--misalign); fi
            ./$exe "${args[@]}" >> "$outdir/${tag}.csv"
          done
        done
      done
    done
  done
}

cd "$(dirname "$0")/.."

# CSV header (keep your original column order)
echo "kernel,dtype,n,stride,misalign,reps,time_ns_med,time_ns_p05,time_ns_p95,gflops,cpe,GiBps,verified,max_rel_err" > data/simd.csv
echo "kernel,dtype,n,stride,misalign,reps,time_ns_med,time_ns_p05,time_ns_p95,gflops,cpe,GiBps,verified,max_rel_err" > data/scalar.csv

# Run SIMD & scalar
run build/bench simd
run build_scalar/bench scalar
