#!/usr/bin/env bash
set -euo pipefail

# ===== Configurable Parameters =====
: "${TARGET:=/mnt/ssdtest/fio_testfile}"   # Test target: file or block device
: "${ENGINE:=io_uring}"                    # IO engine (fallback: libaio)
: "${REPEAT:=3}"                           # Number of repetitions per block size
: "${RUNTIME:=30}"                         # Test duration (seconds, must be > RAMP)
: "${RAMP:=5}"                             # Ramp-up time (seconds)
: "${IODEPTH:=32}"                         # Queue depth
: "${BSS:=4k 16k 32k 64k 128k 256k 512k 1m}"      # Block sizes to test
: "${FILESIZE:=64G}"                       # Used if TARGET is a file
OUTDIR="results/bs_sweep"
# ===================================

mkdir -p "$OUTDIR" tables figs tmp out

# ---- Basic sanity checks ----
if [[ "${RUNTIME}" -le "${RAMP}" ]]; then
  echo "[FATAL] RUNTIME(${RUNTIME}) must be greater than RAMP(${RAMP})."
  exit 1
fi
if [[ "${IODEPTH}" -lt 1 ]]; then
  echo "[FATAL] IODEPTH(${IODEPTH}) must be >= 1."
  exit 1
fi

# ---- Prepare TARGET ----
is_whole_disk() { local t; t="$(lsblk -no TYPE "$1" 2>/dev/null || true)"; [[ "$t" == "disk" ]]; }
if [[ -b "$TARGET" ]]; then
  if is_whole_disk "$TARGET"; then
    echo "[WARN] TARGET=$TARGET appears to be a whole disk; prefer a partition or test file."
  fi
else
  sudo mkdir -p "$(dirname "$TARGET")"
  if [[ ! -f "$TARGET" ]]; then
    echo "[PREP] Creating test file $TARGET ($FILESIZE)"
    sudo fallocate -l "$FILESIZE" "$TARGET"
    sudo chown "$USER:$USER" "$TARGET"
  fi
fi

# ---- Smoke test: ensure engine works and JSON output is valid ----
echo "[SMOKE] 2s validation test with JSON output..."
SMOKE_JSON="$OUTDIR/smoke.json"
SMOKE_ERR="$OUTDIR/smoke.err"
rm -f "$SMOKE_JSON" "$SMOKE_ERR"

fio --name=smoke --rw=read --bs=4k --filename="$TARGET" \
    --ioengine="$ENGINE" --direct=1 --time_based=1 --ramp_time=0 --runtime=2 \
    --numjobs=1 --iodepth=1 --group_reporting=1 --thread=1 \
    $([[ -b "$TARGET" ]] || echo "--size=$FILESIZE") \
    --output="$SMOKE_JSON" --output-format=json 1>/dev/null 2>"$SMOKE_ERR" || true

if [[ ! -s "$SMOKE_JSON" ]]; then
  echo "[FATAL] Smoke JSON was not generated: $SMOKE_JSON"
  sed -n '1,120p' "$SMOKE_ERR" || true
  exit 1
fi
echo "[OK] Smoke JSON valid: $(stat -c '%s bytes' "$SMOKE_JSON")"

# ---- Clean old results ----
rm -f "$OUTDIR"/*.json "$OUTDIR"/*.err

# ---- Single block-size runner ----
run_one() {
  local mode="$1"   # randread | read
  local bs="$2"
  local rep="$3"
  local json="$OUTDIR/${mode}_bs${bs}_${rep}.json"
  local err="$OUTDIR/${mode}_bs${bs}_${rep}.err"

  local extra=""
  [[ "$mode" == "randread" ]] && extra="--offset_align=4k"

  local SIZE_OPT=""
  if [[ ! -b "$TARGET" ]]; then SIZE_OPT="--size=$FILESIZE"; fi

  echo "[RUN] $mode bs=$bs rep=$rep"
  echo "[CMD] fio --name=${mode}_bs${bs} --rw=$mode --bs=$bs --filename=$TARGET \\"
  echo "             --ioengine=$ENGINE --direct=1 --time_based=1 --ramp_time=$RAMP --runtime=$RUNTIME \\"
  echo "             --group_reporting=1 --numjobs=1 --iodepth=$IODEPTH --thread=1 $extra $SIZE_OPT \\"
  echo "             --output=$json --output-format=json 1>/dev/null 2>$err"

  # Execute fio and capture stderr to .err
  set +e
  fio --name="${mode}_bs${bs}" \
      --rw="$mode" --bs="$bs" \
      --filename="$TARGET" \
      --ioengine="$ENGINE" --direct=1 \
      --time_based=1 --ramp_time="$RAMP" --runtime="$RUNTIME" \
      --group_reporting=1 --numjobs=1 --iodepth="$IODEPTH" --thread=1 \
      --percentile_list=50:95:99:99.9 \
      $extra $SIZE_OPT \
      --output="$json" --output-format=json \
      1>/dev/null 2>"$err"
  rc=$?
  set -e

  # Validation
  if [[ $rc -ne 0 ]]; then
    echo "[ERROR] fio returned non-zero code ($rc). Stderr snippet:"
    sed -n '1,160p' "$err" || true
    exit 1
  fi
  if [[ ! -s "$json" ]]; then
    echo "[ERROR] JSON output file is empty: $json"
    sed -n '1,160p' "$err" || true
    exit 1
  fi
}

echo "[RUN] Starting block size sweep..."
for rep in $(seq 1 "$REPEAT"); do
  for bs in $BSS; do run_one "randread" "$bs" "$rep"; done
done
for rep in $(seq 1 "$REPEAT"); do
  for bs in $BSS; do run_one "read" "$bs" "$rep"; done
done

# ---- Parse and plot results ----
python3 - <<'PY'
import json, glob, re, os, sys
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt

OUTDIR="results/bs_sweep"
files=sorted(glob.glob(f"{OUTDIR}/*.json"))
if not files:
    print("[ERROR] No JSON files found in results/bs_sweep", file=sys.stderr)
    sys.exit(1)

def bs_from_name(path):
    m=re.search(r"_bs([0-9]+[kKmM]?)_", os.path.basename(path))
    return m.group(1).lower() if m else None

rows=[]
for f in files:
    try:
        j=json.load(open(f))
    except Exception as e:
        print(f"[WARN] Skipping bad JSON {f}: {e}", file=sys.stderr)
        continue
    jobs=j.get('jobs', [])
    if not jobs:
        print(f"[WARN] No jobs in {f}", file=sys.stderr)
        continue
    job=jobs[0]
    opt=job.get('job options', {})
    mode=opt.get('rw') or 'read'
    bs  =opt.get('bs') or bs_from_name(f) or 'unknown'
    rd=job.get('read', {})
    if rd.get('io_bytes', 0)==0:
        continue
    rows.append({
        'mode': mode,
        'bs': bs,
        'iops': rd.get('iops', 0.0),
        'bw_MBps': rd.get('bw_bytes', 0)/(1024*1024),
        'lat_ms': rd.get('lat_ns', {}).get('mean', 0.0)/1e6
    })

df=pd.DataFrame(rows)
if df.empty:
    print("[ERROR] Parsed DataFrame is empty. Check *.err files.", file=sys.stderr)
    sys.exit(1)

def to_k(x):
    s=str(x).lower()
    if s.endswith('k'): return float(s[:-1])
    if s.endswith('m'): return float(s[:-1])*1024.0
    return float(s)

df['bs_k']=df['bs'].apply(to_k)
g=df.groupby(['mode','bs_k']).agg(
    iops=('iops','mean'), iops_std=('iops','std'),
    bw=('bw_MBps','mean'), bw_std=('bw_MBps','std'),
    lat=('lat_ms','mean'), lat_std=('lat_ms','std')
).reset_index()

os.makedirs('tables', exist_ok=True); os.makedirs('figs', exist_ok=True)
rand=g[g['mode']=='randread'].sort_values('bs_k')
seq =g[g['mode']=='read'].sort_values('bs_k')
if not rand.empty: rand.to_csv('tables/bs_sweep_random.csv', index=False)
if not seq.empty:  seq.to_csv('tables/bs_sweep_sequential.csv', index=False)

def plot(d, title, prefix):
    if d.empty: return
    plt.figure(); plt.errorbar(d['bs_k'], d['iops'], yerr=d['iops_std'].fillna(0.0), marker='o')
    plt.xlabel('Block Size (KiB)'); plt.ylabel('IOPS'); plt.title(f'{title}: IOPS vs Block Size')
    plt.tight_layout(); plt.savefig(f'figs/{prefix}_iops.png'); plt.close()
    plt.figure(); plt.errorbar(d['bs_k'], d['bw'], yerr=d['bw_std'].fillna(0.0), marker='o')
    plt.xlabel('Block Size (KiB)'); plt.ylabel('Throughput (MB/s)'); plt.title(f'{title}: MB/s vs Block Size')
    plt.tight_layout(); plt.savefig(f'figs/{prefix}_mbps.png'); plt.close()
    plt.figure(); plt.errorbar(d['bs_k'], d['lat'], yerr=d['lat_std'].fillna(0.0), marker='o')
    plt.xlabel('Block Size (KiB)'); plt.ylabel('Mean Latency (ms)'); plt.title(f'{title}: Latency vs Block Size')
    plt.tight_layout(); plt.savefig(f'figs/{prefix}_lat.png'); plt.close()

plot(rand, "Random Read", "bs_randread")
plot(seq,  "Sequential Read", "bs_seqread")

with open('out/section_3_bs.md','w') as fh:
    fh.write("#### Block Size Sweep Results\n\n")
    if not rand.empty:
        fh.write("Random: `figs/bs_randread_iops.png`, `figs/bs_randread_mbps.png`, `figs/bs_randread_lat.png`\n\n")
    if not seq.empty:
        fh.write("Sequential: `figs/bs_seqread_iops.png`, `figs/bs_seqread_mbps.png`, `figs/bs_seqread_lat.png`\n")
PY

echo "[DONE] Tables: tables/bs_sweep_random.csv / tables/bs_sweep_sequential.csv"
echo "[DONE] Summary: out/section_3_bs.md"
