#!/usr/bin/env bash
set -euo pipefail

# ===== Configurable Variables =====
: "${TARGET:=/mnt/ssdtest/fio_testfile}"   # Test target (file or block device)
: "${ENGINE:=io_uring}"                    # I/O engine (fallback: libaio)
: "${REPEAT:=3}"                           # Repetitions per mix case
: "${RUNTIME:=30}"                          # Duration of each run (seconds)
: "${RAMP:=5}"                             # Warm-up time (seconds)
: "${IODEPTH:=32}"                         # Queue depth
: "${BS:=4k}"                              # Block size
: "${FILESIZE:=64G}"                       # Used when TARGET is a regular file
# ===================================

OUTDIR="results/rw_mix"
mkdir -p "$OUTDIR" tables figs tmp out

# --- Helper: run one mix case as an independent fio invocation ---
run_one() {
  # $1: label (R100W0 | R0W100 | R70W30 | R50W50)
  local label="$1"
  local rep="$2"

  local json="$OUTDIR/mix_${label}_${rep}.json"
  local log="$OUTDIR/mix_${label}_${rep}.log"

  # Compose fio args based on label
  local rw="" mixopt=""
  case "$label" in
    R100W0)  rw="randread"  ;;
    R0W100)  rw="randwrite" ;;
    R70W30)  rw="randrw"; mixopt="--rwmixread=70" ;;
    R50W50)  rw="randrw"; mixopt="--rwmixread=50" ;;
    *) echo "[ERROR] Unknown label: $label"; exit 1 ;;
  esac

  # Use --size only for file targets
  local SIZE_OPT=""; [[ -b "$TARGET" ]] || SIZE_OPT="--size=$FILESIZE"

  echo "[RUN] ${label} (rw=$rw) rep=$rep"
  echo "[CMD] fio --name=mix_${label} --rw=$rw --bs=$BS --filename=$TARGET \\"
  echo "             --ioengine=$ENGINE --direct=1 --time_based=1 --ramp_time=$RAMP --runtime=$RUNTIME \\"
  echo "             --group_reporting=1 --numjobs=1 --iodepth=$IODEPTH --thread=1 $mixopt $SIZE_OPT \\"
  echo "             --percentile_list=50:95:99:99.9 --output=$json --output-format=json"

  # Run fio; capture both stdout+stderr into the log for debugging
  set +e
  fio --name="mix_${label}" \
      --rw="$rw" --bs="$BS" --filename="$TARGET" \
      --ioengine="$ENGINE" --direct=1 --time_based=1 \
      --ramp_time="$RAMP" --runtime="$RUNTIME" \
      --group_reporting=1 --numjobs=1 --iodepth="$IODEPTH" --thread=1 \
      --percentile_list=50:95:99:99.9 \
      $mixopt $SIZE_OPT \
      --output="$json" --output-format=json \
      2>&1 | tee "$log"
  rc=$?
  set -e

  if [[ $rc -ne 0 || ! -s "$json" ]]; then
    echo "[ERROR] fio failed or empty JSON for $label. See $log"
    exit 1
  fi
}

# --- Execute 4 mixes independently ---
MIXES=("R100W0" "R0W100" "R70W30" "R50W50")
for r in $(seq 1 "$REPEAT"); do
  for m in "${MIXES[@]}"; do
    run_one "$m" "$r"
  done
done

# --- Parse and plot results (sum read+write throughput; latency = IO-count-weighted mean) ---
python3 - <<'PY'
import json, glob, os, re
import pandas as pd
import matplotlib.pyplot as plt

def parse_label(fn):
    # file name like: results/rw_mix/mix_R70W30_1.json -> R70W30
    m = re.search(r"mix_(R\d+W\d+)_\d+\.json$", fn)
    return m.group(1) if m else "UNKNOWN"

rows = []
for f in sorted(glob.glob("results/rw_mix/mix_*.json")):
    with open(f) as fh:
        j = json.load(fh)
    label = parse_label(f)
    jobs = j.get('jobs', [])
    if not jobs:
        continue
    job = jobs[0]
    rd = job.get('read',  {})
    wr = job.get('write', {})

    # Throughput in MB/s: sum of read+write
    bw_MBps = (rd.get('bw_bytes',0) + wr.get('bw_bytes',0)) / (1024*1024)

    # Weighted latency (by IO counts). If only one direction has IO, it naturally reduces to that side.
    r_ios = rd.get('total_ios', 0)
    w_ios = wr.get('total_ios', 0)
    total_ios = r_ios + w_ios
    r_lat_ms = rd.get('lat_ns', {}).get('mean', 0.0) / 1e6 if r_ios else 0.0
    w_lat_ms = wr.get('lat_ns', {}).get('mean', 0.0) / 1e6 if w_ios else 0.0
    if total_ios > 0:
        lat_ms = (r_lat_ms * r_ios + w_lat_ms * w_ios) / total_ios
    else:
        lat_ms = 0.0

    rows.append({
        'label': label,
        'throughput_MBps': bw_MBps,
        'latency_ms': lat_ms
    })

df = pd.DataFrame(rows)
if df.empty:
    print("[ERROR] No valid data parsed. Check results/rw_mix/*.log")
    raise SystemExit(1)

# Aggregate across repetitions (mean)
g = df.groupby('label', as_index=False).agg(
    throughput_MBps=('throughput_MBps', 'mean'),
    latency_ms=('latency_ms', 'mean')
).sort_values('label')

os.makedirs('tables', exist_ok=True)
g.to_csv('tables/rw_mix_summary.csv', index=False)

# Plot throughput (one bar per mix)
plt.figure()
plt.bar(g['label'], g['throughput_MBps'])
plt.ylabel('Throughput (MB/s)')
plt.title('R/W Mix: Total Throughput (Read+Write)')
plt.tight_layout()
plt.savefig('figs/mix_throughput.png')
plt.close()

# Plot latency (one bar per mix; IO-count-weighted)
plt.figure()
plt.bar(g['label'], g['latency_ms'])
plt.ylabel('Mean Latency (ms)')
plt.title('R/W Mix: Weighted Mean Latency')
plt.tight_layout()
plt.savefig('figs/mix_latency.png')
plt.close()

with open('out/section_4_mix.md', 'w') as fh:
    fh.write("#### Read/Write Mix Scan Results\n\n")
    fh.write("Table: `tables/rw_mix_summary.csv`\n\n")
    fh.write("Figures: `figs/mix_throughput.png`, `figs/mix_latency.png`\n")
PY

echo "[DONE] Table: tables/rw_mix_summary.csv"
echo "[DONE] Figures: figs/mix_throughput.png / figs/mix_latency.png"
echo "[DONE] Summary: out/section_4_mix.md"
