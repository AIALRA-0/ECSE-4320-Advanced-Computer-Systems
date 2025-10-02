#!/usr/bin/env bash
set -euo pipefail

# ===== Configurable Variables =====
: "${TARGET:=/mnt/ssdtest/fio_testfile}"   # Test target: file or block device
: "${ENGINE:=io_uring}"                    # I/O engine (fallback: libaio)
: "${REPEAT:=3}"                           # Number of repetitions per QD
: "${RUNTIME:=30}"                         # Runtime (seconds)
: "${RAMP:=5}"                             # Warm-up time (seconds)
: "${BSSL:=4k}"                            # Fixed block size (e.g., 4k for randread)
: "${QDS:=1 2 4 8 16 32 64 128}"           # Queue depths to sweep
: "${FILESIZE:=64G}"                       # Used when TARGET is a regular file

# Knee point detection thresholds (%)
: "${MARGINAL_GAIN_PCT:=5}"                # Minimum throughput gain threshold
: "${LATENCY_PENALTY_PCT:=20}"             # Minimum latency increase threshold
# ===================================

OUTDIR="results/qd_sweep"
mkdir -p "$OUTDIR" tables figs tmp out

# --- Sanity checks ---
if [[ "$RUNTIME" -le "$RAMP" ]]; then
  echo "[FATAL] RUNTIME ($RUNTIME) must be greater than RAMP ($RAMP)"
  exit 1
fi

# --- Prepare test target ---
is_whole_disk() {
  local t
  t="$(lsblk -no TYPE "$1" 2>/dev/null || true)"
  [[ "$t" == "disk" ]]
}

if [[ -b "$TARGET" ]]; then
  if is_whole_disk "$TARGET"; then
    echo "[WARN] TARGET=$TARGET appears to be a whole disk; prefer a partition or file"
  fi
else
  sudo mkdir -p "$(dirname "$TARGET")"
  if [[ ! -f "$TARGET" ]]; then
    echo "[PREP] Creating test file $TARGET ($FILESIZE)"
    sudo fallocate -l "$FILESIZE" "$TARGET"
    sudo chown "$USER:$USER" "$TARGET"
  fi
fi

# --- Smoke test (quick verification of engine, permission, and JSON output) ---
echo "[SMOKE] 2-second smoke test (4k read, QD=1)..."
SMOKE_JSON="$OUTDIR/smoke.json"
SMOKE_ERR="$OUTDIR/smoke.err"
rm -f "$SMOKE_JSON" "$SMOKE_ERR"

fio --name=smoke --rw=read --bs=4k --filename="$TARGET" \
    --ioengine="$ENGINE" --direct=1 --time_based=1 --ramp_time=0 --runtime=2 \
    --numjobs=1 --iodepth=1 --group_reporting=1 --thread=1 \
    $([[ -b "$TARGET" ]] || echo "--size=$FILESIZE") \
    --output="$SMOKE_JSON" --output-format=json \
    1>/dev/null 2>"$SMOKE_ERR" || true

if [[ ! -s "$SMOKE_JSON" ]]; then
  echo "[FATAL] Smoke test JSON missing or empty: $SMOKE_JSON"
  sed -n '1,120p' "$SMOKE_ERR" || true
  exit 1
fi
echo "[OK] Smoke test JSON OK: $(stat -c '%s bytes' "$SMOKE_JSON")"

# --- Clean up old results ---
rm -f "$OUTDIR"/*.json "$OUTDIR"/*.log "$OUTDIR"/*.err

# --- Function: run one QD test (robust, per-job invocation) ---
run_one() {
  local qd="$1"
  local rep="$2"
  local json="$OUTDIR/qd${qd}_${rep}.json"
  local log="$OUTDIR/qd${qd}_${rep}.log"

  local SIZE_OPT=""
  [[ ! -b "$TARGET" ]] && SIZE_OPT="--size=$FILESIZE"

  echo "[RUN] randread QD=$qd (bs=${BSSL}) rep=$rep"
  echo "[CMD] fio --name=qd${qd} --rw=randread --bs=${BSSL} --filename=$TARGET \\"
  echo "             --ioengine=$ENGINE --direct=1 --time_based=1 --ramp_time=$RAMP --runtime=$RUNTIME \\"
  echo "             --group_reporting=1 --numjobs=1 --iodepth=$qd --thread=1 --offset_align=4k $SIZE_OPT \\"
  echo "             --output=$json --output-format=json --eta=always 1>/dev/null 2>$log"

  set +e
  fio --name="qd${qd}" \
      --rw=randread --bs="${BSSL}" \
      --filename="$TARGET" \
      --ioengine="$ENGINE" --direct=1 \
      --time_based=1 --ramp_time="$RAMP" --runtime="$RUNTIME" \
      --group_reporting=1 --numjobs=1 --iodepth="$qd" --thread=1 \
      --percentile_list=50:95:99:99.9 --offset_align=4k \
      $SIZE_OPT \
      --output="$json" --output-format=json --eta=always \
      1>/dev/null 2>"$log"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    echo "[ERROR] fio exit code=$rc; log excerpt:"
    sed -n '1,160p' "$log" || true
    exit 1
  fi
  if [[ ! -s "$json" ]]; then
    echo "[ERROR] Empty JSON file: $json"
    sed -n '1,160p' "$log" || true
    exit 1
  fi
}

# --- Run all queue depths (each separately) ---
echo "[RUN] Starting QD sweep..."
for rep in $(seq 1 "$REPEAT"); do
  for qd in $QDS; do
    run_one "$qd" "$rep"
  done
done
echo "[OK] All QD runs completed; parsing and plotting..."

# --- Python analysis ---
python3 - <<'PY'
import os, sys, json, glob
import pandas as pd
import matplotlib.pyplot as plt

OUTDIR = "results/qd_sweep"
rows = []

# --- Load JSONs ---
files = sorted(glob.glob(f"{OUTDIR}/qd*_*.json"))
if not files:
    print("[ERROR] No JSON files found", file=sys.stderr); sys.exit(1)

for f in files:
    try:
        j = json.load(open(f))
    except Exception as e:
        print(f"[WARN] Skipping bad JSON: {f} ({e})", file=sys.stderr)
        continue
    jobs = j.get('jobs', [])
    if not jobs:
        continue
    job = jobs[0]
    opt = job.get('job options', {})
    if 'rand' not in opt.get('rw', ''):
        continue
    qd = int(opt.get('iodepth', '1') or 1)
    rd = job.get('read', {})
    if rd.get('io_bytes', 0) == 0:
        continue
    rows.append({
        'iodepth': qd,
        'bw_MBps': rd.get('bw_bytes', 0) / (1024 * 1024),
        'lat_ms': rd.get('lat_ns', {}).get('mean', 0.0) / 1e6,
        'p50': rd.get('clat_ns', {}).get('percentile', {}).get('50.000000', 0.0) / 1e6,
        'p95': rd.get('clat_ns', {}).get('percentile', {}).get('95.000000', 0.0) / 1e6,
        'p99': rd.get('clat_ns', {}).get('percentile', {}).get('99.000000', 0.0) / 1e6,
        'p999': rd.get('clat_ns', {}).get('percentile', {}).get('99.900000', 0.0) / 1e6,
    })

df = pd.DataFrame(rows)
if df.empty:
    print("[ERROR] Parsed dataframe is empty; check logs", file=sys.stderr)
    sys.exit(1)

# --- Aggregate stats ---
g = df.groupby('iodepth').agg(
    bw=('bw_MBps', 'mean'), bw_std=('bw_MBps', 'std'),
    lat=('lat_ms', 'mean'), lat_std=('lat_ms', 'std'),
    p50=('p50', 'mean'), p95=('p95', 'mean'),
    p99=('p99', 'mean'), p999=('p999', 'mean')
).reset_index().sort_values('iodepth')

# Fill NaNs for std columns
g[['bw_std','lat_std']] = g[['bw_std','lat_std']].fillna(0.0)

os.makedirs('tables', exist_ok=True)
g.to_csv('tables/qd_sweep_summary.csv', index=False)

# --- Knee point detection ---
MARG = float(os.environ.get('MARGINAL_GAIN_PCT', '5'))
LPEN = float(os.environ.get('LATENCY_PENALTY_PCT', '20'))
knee_qd = None
for i in range(1, len(g)):
    prev, cur = g.iloc[i - 1], g.iloc[i]
    gain = (cur['bw'] - prev['bw']) / max(prev['bw'], 1e-9) * 100
    linc = (cur['lat'] - prev['lat']) / max(prev['lat'], 1e-9) * 100
    if gain < MARG and linc > LPEN:
        knee_qd = int(cur['iodepth'])
        break

os.makedirs('figs', exist_ok=True)

# ---------- Helpers: annotate values ----------
def annotate_points(ax, xs, ys, labels):
    """Put small numeric labels near points."""
    for x, y, lab in zip(xs, ys, labels):
        ax.annotate(lab, (x, y), textcoords="offset points", xytext=(5, 5), fontsize=5)

def annotate_bars(ax, rects, fmt=lambda v: f"{v:.3f}"):
    """Put numeric labels above bars."""
    for r in rects:
        h = r.get_height()
        ax.annotate(fmt(h), xy=(r.get_x() + r.get_width()/2, h),
                    xytext=(0, 3), textcoords="offset points",
                    ha='center', va='bottom', fontsize=5)

# ---------- 1) Throughput–Latency curve with numeric labels ----------
fig, ax = plt.subplots()
ax.errorbar(g['lat'], g['bw'],
            xerr=g['lat_std'], yerr=g['bw_std'],
            marker='o', linestyle='-')
# Label each point with both QD and numeric values
pt_labels = [f"QD{int(q)}\n{bw:.0f} MB/s, {lat:.3f} ms"
             for q, bw, lat in zip(g['iodepth'], g['bw'], g['lat'])]
annotate_points(ax, g['lat'], g['bw'], pt_labels)

title = "Throughput–Latency (4K randread)"
if knee_qd:
    title += f" | Knee≈QD{knee_qd}"
ax.set_xlabel('Mean Latency (ms)')
ax.set_ylabel('Throughput (MB/s)')
ax.set_title(title)
fig.tight_layout(); fig.savefig('figs/qd_tradeoff.png'); plt.close(fig)

# ---------- 2) Tail latency bars ----------
# Tail selection rule:
#   - Default: compare QD16 vs Knee-QD (or max if no knee)
#   - If TAIL_QDS=ALL: show all QDs
#   - If TAIL_QDS="1,2,4,..." : show that list
tail_env = os.environ.get("TAIL_QDS", "").strip().upper()

def pick(q):
    if q in set(g['iodepth']):
        return g[g['iodepth'] == q].iloc[0]
    return None

if tail_env in ("ALL", "*"):
    sel = g.copy()
elif tail_env:
    want = []
    for tok in tail_env.split(","):
        tok = tok.strip()
        if tok.isdigit():
            want.append(int(tok))
    sel = g[g['iodepth'].isin(want)].copy()
else:
    mid = pick(16)
    knee = pick(knee_qd) if knee_qd is not None else g.iloc[-1]
    base = [r for r in (mid, knee) if r is not None]
    sel = pd.DataFrame(base)

labels = [f"QD{int(q)}" for q in sel['iodepth']]

for p in ['p50','p95','p99','p999']:
    fig, ax = plt.subplots()
    bars = ax.bar(labels, sel[p])
    ax.set_ylabel(f'{p.upper()} Latency (ms)')
    ax.set_title(f'Tail Latency ({p.upper()})')
    annotate_bars(ax, bars, fmt=lambda v: f"{v:.3f}")
    fig.tight_layout(); fig.savefig(f'figs/tail_{p}.png'); plt.close(fig)

# ---------- 3) BW vs QD and Latency vs QD with numeric labels ----------
fig, ax = plt.subplots()
ax.errorbar(g['iodepth'], g['bw'], yerr=g['bw_std'], marker='o', linestyle='-')
ax.set_xlabel('Queue Depth'); ax.set_ylabel('Throughput (MB/s)'); ax.set_title('BW vs QD (4K randread)')
# Label points with MB/s
annotate_points(ax, g['iodepth'], g['bw'], [f"{bw:.0f}" for bw in g['bw']])
fig.tight_layout(); fig.savefig('figs/bw_vs_qd.png'); plt.close(fig)

fig, ax = plt.subplots()
ax.errorbar(g['iodepth'], g['lat'], yerr=g['lat_std'], marker='o', linestyle='-')
ax.set_xlabel('Queue Depth'); ax.set_ylabel('Mean Latency (ms)'); ax.set_title('Latency vs QD (4K randread)')
# Label points with ms
annotate_points(ax, g['iodepth'], g['lat'], [f"{lat:.3f}" for lat in g['lat']])
fig.tight_layout(); fig.savefig('figs/lat_vs_qd.png'); plt.close(fig)

# ---------- Markdown report ----------
with open('out/section_5_qd.md', 'w') as fh:
    fh.write("#### Queue Depth Sweep (4K Random Read) & Knee Point Detection\n\n")
    fh.write("Table: `tables/qd_sweep_summary.csv`\n\n")
    if knee_qd:
        fh.write(f"Knee detected at **QD={knee_qd}** (Gain < {MARG}%, Latency increase > {LPEN}%).\n\n")
    else:
        fh.write("No clear knee point detected; inspect curve manually.\n\n")
    fh.write("Figures: `figs/qd_tradeoff.png`, `figs/bw_vs_qd.png`, `figs/lat_vs_qd.png`,\n")
    fh.write("         `figs/tail_p50.png`, `figs/tail_p95.png`, `figs/tail_p99.png`, `figs/tail_p999.png`\n")

PY

echo "[DONE] Table: tables/qd_sweep_summary.csv"
echo "[DONE] Figures: figs/qd_tradeoff.png / figs/bw_vs_qd.png / figs/lat_vs_qd.png"
echo "[DONE] Tail Latency: figs/tail_*.png"
echo "[DONE] Summary: out/section_5_qd.md"
