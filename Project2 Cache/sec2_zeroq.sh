#!/usr/bin/env bash
# =========================================================
# Section 2: Zero-Queue Latency Baseline (L1/L2/L3/DRAM)
# =========================================================
# Goal:
#   - Measure per-level latency (cycles/access) using pointer chasing microbenchmark.
#   - Convert cycles to nanoseconds using CPU MHz.
#   - Plot results with error bars (mean ± std) for both read and write.
#   - Pin CPU and memory to a single NUMA node for isolation.
#   - Auto-detect cache sizes and CPU frequency.
#
# Output:
#   - CSV: per-run cycles_per_access results.
#   - PNG: bar chart (ns per access with error bars).
#   - MD : Markdown report snippet for inclusion.
#
# Requirements:
#   - gcc, python3, pandas, matplotlib
#   - config.env must define RESULT_ROOT, FIG_ROOT, OUT_ROOT, CPU_NODE, REPEAT
# =========================================================

set -euo pipefail
export LC_ALL=C
source ./config.env

mkdir -p "$RESULT_ROOT/sec2" "$FIG_ROOT/sec2" "$OUT_ROOT"

# =========================================================
# 1) Build pointer-chasing microbenchmark
# =========================================================
cat > pchase.c <<'EOF'
#define _GNU_SOURCE
#include <immintrin.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <x86intrin.h>
#include <unistd.h>
#include <sys/mman.h>

// Read timestamp counter
static inline uint64_t rdtsc() {
  unsigned aux;
  return __rdtscp(&aux);
}

// Fisher–Yates shuffle for random access order
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

  // Create a single-linked ring (pointer chasing list)
  for (size_t i=0; i<elems; ++i) {
    size_t next = (i + step_stride) % elems;
    buf[idx[i]] = (size_t)&buf[idx[next]];
  }

  // Warmup to stabilize caches
  volatile size_t *p = (volatile size_t*)&buf[idx[0]];
  for (size_t i=0; i<10000; ++i) p = (volatile size_t*)(*p);

  // Measure cycles/access across repeats
  for (int r=0; r<repeats; ++r) {
    _mm_mfence();
    uint64_t t0 = rdtsc();
    volatile size_t *x = (volatile size_t*)&buf[idx[0]];
    size_t sink=0;
    for (size_t k=0; k<access_per_iter; ++k) {
      if (strcmp(rw,"read")==0) {
        x = (volatile size_t*)(*x);
      } else {
        *((volatile size_t*)x) = (size_t)x;
        _mm_clflush((void*)x);  // flush to force store miss
        _mm_mfence();
        x = (volatile size_t*)(*x);
      }
      sink += (size_t)x;
    }
    uint64_t t1 = rdtsc();
    double cyc = (double)(t1 - t0) / access_per_iter;
    fprintf(stderr, "rep=%02d guard=%zu cycles_per_access=%.2f\n", r, sink, cyc);
    printf("level_repeat,%d,cycles_per_access,%.4f\n", r, cyc);
  }
  return 0;
}
EOF

gcc -O2 -march=native pchase.c -o pchase

# =========================================================
# 2) Detect cache sizes and CPU frequency
# =========================================================
parse_size_token_to_bytes() {
  local raw="$(echo "$1" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
  local num unit
  num="$(echo "$raw" | sed -E 's/[^0-9.]//g')"
  unit="$(echo "$raw" | sed -E 's/[0-9.]//g')"
  [ -z "$num" ] && { echo 0; return; }
  case "$unit" in
    k|kb|kib) echo "$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024}')" ;;
    m|mb|mib) echo "$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024}')" ;;
    g|gb|gib) echo "$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024*1024}')" ;;
    ""|b)     echo "$(awk -v n="$num" 'BEGIN{printf "%.0f", n}')" ;;
    *)        echo "$(awk -v n="$num" 'BEGIN{printf "%.0f", n}')" ;;
  esac
}

get_cache_bytes_sysfs() {
  local want_level="$1" pref_type="$2" p="/sys/devices/system/cpu/cpu0/cache"
  local best=""
  for d in "$p"/index*; do
    [ -d "$d" ] || continue
    local lvl type size
    lvl="$(cat "$d/level" 2>/dev/null || echo "")"
    type="$(cat "$d/type"  2>/dev/null || echo "")"
    size="$(cat "$d/size"  2>/dev/null || echo "")"
    [ "$lvl" = "$want_level" ] || continue
    if [ -n "$size" ]; then
      if [ -z "$best" ] || [ "$type" = "$pref_type" ]; then
        best="$size"
        [ "$type" = "$pref_type" ] && break
      fi
    fi
  done
  [ -z "$best" ] && { echo 0; return; }
  parse_size_token_to_bytes "$best"
}

get_cache_bytes_lscpu() {
  local key="$1"
  local raw
  raw="$(lscpu | awk -F: -v k="$key" 'tolower($1) ~ tolower(k) {print $2; exit}')"
  [ -z "$raw" ] && { echo 0; return; }
  parse_size_token_to_bytes "$raw"
}

L1_SIZE_BYTES="$(get_cache_bytes_sysfs 1 Data)"
L2_SIZE_BYTES="$(get_cache_bytes_sysfs 2 Unified)"
L3_SIZE_BYTES="$(get_cache_bytes_sysfs 3 Unified)"
[ "${L1_SIZE_BYTES:-0}" -eq 0 ] && L1_SIZE_BYTES="$(get_cache_bytes_lscpu 'L1d cache')"
[ "${L2_SIZE_BYTES:-0}" -eq 0 ] && L2_SIZE_BYTES="$(get_cache_bytes_lscpu 'L2 cache')"
[ "${L3_SIZE_BYTES:-0}" -eq 0 ] && L3_SIZE_BYTES="$(get_cache_bytes_lscpu 'L3 cache')"
[ "${L1_SIZE_BYTES:-0}" -eq 0 ] && L1_SIZE_BYTES=$((32*1024))
[ "${L2_SIZE_BYTES:-0}" -eq 0 ] && L2_SIZE_BYTES=$((1024*1024))
[ "${L3_SIZE_BYTES:-0}" -eq 0 ] && L3_SIZE_BYTES=$((16*1024*1024))

L1_BYTES=$(( L1_SIZE_BYTES / 2 ))
L2_BYTES=$(( L2_SIZE_BYTES / 2 ))
L3_BYTES=$(( L3_SIZE_BYTES / 2 ))
DRAM_BYTES=$(( L3_SIZE_BYTES + 512*1024*1024 ))

CSV="$RESULT_ROOT/sec2/zeroq.csv"
echo "level,bytes,mode,rw,cycles_per_access" > "$CSV"

# =========================================================
# 3) Run pointer chasing and record all repeats
# =========================================================
run_point () {
  local level="$1"; local bytes="$2"; local mode="$3"; local rw="$4"
  local stride=64
  local per_iter=200000
  local repeats="$REPEAT"
  local log="$RESULT_ROOT/sec2/${level}_${mode}_${rw}.log"
  local tmp="$RESULT_ROOT/sec2/${level}_${mode}_${rw}.tmp"
  local cmd=(numactl --cpunodebind="$CPU_NODE" --membind="$CPU_NODE" ./pchase "$bytes" "$stride" "$per_iter" "$repeats" "$mode" "$rw" 0)

  echo "[$level][$mode][$rw] bytes=$bytes"
  # ✅ capture stdout (includes level_repeat lines) and stderr separately
  "${cmd[@]}" >"$tmp" 2>"$log"

  # ✅ Extract all per-repeat samples for stddev computation
  awk -F, '/level_repeat/ {print "'"$level"','"$bytes"','"$mode"','"$rw"'," $4}' "$tmp" >> "$CSV"
}

for lvl in L1 L2 L3 DRAM; do
  bytes_var="${lvl}_BYTES"
  run_point "$lvl" "${!bytes_var}" rand read
  run_point "$lvl" "${!bytes_var}" rand write
done

# =========================================================
# 4) Plot with error bars (mean ± std)
# =========================================================
CPU_MHZ="$(awk '/^cpu MHz/ {sum+=$4; n++} END{if(n) printf("%.0f", sum/n)}' /proc/cpuinfo || true)"
[ -z "${CPU_MHZ:-}" ] && CPU_MHZ="$(lscpu | awk -F: '/^CPU MHz:/ {gsub(/ /,"",$2); print $2; exit}')"
[ -z "${CPU_MHZ:-}" ] && CPU_MHZ=3000

PY="$RESULT_ROOT/sec2/plot_sec2.py"
cat > "$PY" <<'PYCODE'
import pandas as pd, matplotlib.pyplot as plt, numpy as np, os, sys
csv, mhz, fig_path, md_path = sys.argv[1:5]
mhz = float(mhz)

df = pd.read_csv(csv)
df['cycles_per_access'] = pd.to_numeric(df['cycles_per_access'], errors='coerce')
df = df.dropna(subset=['cycles_per_access'])
df['ns_per_access'] = df['cycles_per_access'] * 1000.0 / mhz

summary = df.groupby(['level','rw'])['ns_per_access'].agg(['mean','std']).reset_index()
levels = ['L1','L2','L3','DRAM']
rw_types = ['read','write']

fig, ax = plt.subplots(figsize=(8,5))
bar_width = 0.35
x = np.arange(len(levels))

for i, rw in enumerate(rw_types):
    sub = summary[summary['rw']==rw]
    y = [sub[sub['level']==lv]['mean'].values[0] for lv in levels]
    err = [sub[sub['level']==lv]['std'].values[0] for lv in levels]
    ax.bar(
        x + (i-0.5)*bar_width, y,
        width=bar_width, label=rw,
        yerr=err, capsize=6,
        ecolor='black', error_kw={'elinewidth':1.5, 'alpha':0.9},
        alpha=0.9
    )

ax.set_xticks(x)
ax.set_xticklabels(levels)
ax.set_ylabel('Latency (ns/access)')
ax.set_xlabel('Memory Hierarchy Level')
ax.set_title('Zero-Queue Latency by Level (QD=1, Random, Stride=64B)')
ax.legend()
ax.grid(axis='y', linestyle='--', alpha=0.5)
plt.tight_layout()
os.makedirs(os.path.dirname(fig_path), exist_ok=True)
fig.savefig(fig_path, dpi=150)

pivot_mean = summary.pivot(index='level', columns='rw', values='mean').round(3)
pivot_std  = summary.pivot(index='level', columns='rw', values='std').round(3)
os.makedirs(os.path.dirname(md_path), exist_ok=True)
with open(md_path,'w') as f:
    f.write("## 2. Zero-Queue Baseline\n\n")
    f.write("### 2.3 Results (Mean ± Std, ns/access)\n\n")
    f.write(pivot_mean.to_markdown()+"\n\n")
    f.write("Standard deviation:\n\n")
    f.write(pivot_std.to_markdown()+"\n\n")
    rel_img = os.path.relpath(fig_path, start=os.path.dirname(md_path))
    f.write(f"![ZeroQ]({rel_img})\n\n")
    f.write("### 2.4 Analysis\n\n")
    f.write("- Latency increases with hierarchy level (L1 < L2 < L3 < DRAM).\n")
    f.write("- Write operations slower due to write-allocate & flush.\n")
    f.write("- Error bars represent run-to-run variability (stddev).\n")
    f.write("- Verify conversion: ns = cycles × 1000 / CPU_MHz.\n")
print("✅ Markdown written:", md_path)
PYCODE

FIG_PATH="$FIG_ROOT/sec2/zeroq_latency_bar.png"
MD_PATH="$OUT_ROOT/section_2_zeroq.md"
python3 "$PY" "$CSV" "$CPU_MHZ" "$FIG_PATH" "$MD_PATH"

echo "✅ Done."
echo "CSV : $CSV"
echo "FIG : $FIG_PATH"
echo "MD  : $MD_PATH"
