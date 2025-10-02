#!/usr/bin/env bash
# =========================================================
# Section 5: Intensity Sweep (Throughput–Latency with MLC only)
# =========================================================
# - Use Intel MLC --loaded_latency ONLY (no fallback).
# - Run REPEAT times, parse (throughput, latency) samples, bucket & plot mean±std.
# - Outputs:
#     results/sec5/loaded_latency_raw.csv
#     figs/sec5/throughput_latency.png
#     out/section_5_intensity.md
# Requirements:
#     - config.env defines RESULT_ROOT, FIG_ROOT, OUT_ROOT, CPU_NODE, REPEAT, RUNTIME_SEC
#     - numpy/pandas/matplotlib available (in your venv from setup_env.sh)
# =========================================================

set -euo pipefail
export LC_ALL=C

# --------------- Load config ---------------
if [[ ! -f ./config.env ]]; then
  echo "[ERROR] Missing ./config.env. Run 'source ./config.env' first." >&2
  exit 2
fi
# shellcheck disable=SC1091
source ./config.env

mkdir -p "$RESULT_ROOT/sec5" "$FIG_ROOT/sec5" "$OUT_ROOT"

# --------------- Pick official MLC ---------------
pick_mlc() {
  local cand out
  for cand in ./mlc mlc mlc_avx512; do
    if command -v "$cand" >/dev/null 2>&1; then
      out="$({ "$cand" --help 2>&1 || true; } | tr -d '\r')"
      if echo "$out" | grep -qi -- "--loaded_latency"; then
        echo "$cand"; return 0
      fi
    fi
  done
  return 1
}

MLC_BIN="$(pick_mlc || true)"
if [[ -z "${MLC_BIN:-}" ]]; then
  echo "[ERROR] Found no MLC binary with '--loaded_latency' in its help output."
  echo "        Ensure official Intel MLC (e.g., v3.11b) is first in PATH."
  exit 1
fi

echo "[INFO] Using MLC: $MLC_BIN"
$MLC_BIN --version 2>/dev/null || true

RAW="$RESULT_ROOT/sec5/loaded_latency_raw.csv"
echo "repeat,bandwidth_gbs,latency_ns" > "$RAW"

# --------------- One run (exec + parse) ---------------
run_one() {
  # Run one repetition of MLC --loaded_latency and parse its output.
  local rep="$1"
  local raw="$RESULT_ROOT/sec5/mlc_loaded_rep${rep}.raw"   # merged stdout+stderr
  echo "[RUN] $MLC_BIN --loaded_latency -t${RUNTIME_SEC} (rep=$rep)"

  # Try strict (no-space) form first: -tNN
  { timeout --preserve-status "$(( RUNTIME_SEC * 5 ))" \
      numactl --cpunodebind="$CPU_NODE" --membind="$CPU_NODE" \
      stdbuf -oL -eL "$MLC_BIN" --loaded_latency -t"$RUNTIME_SEC" -X \
      |& tee "$raw" >/dev/null; } || true

  # If MLC still complained and produced nothing useful, try the space form once.
  if ! grep -qi 'bandwidth\|latency' "$raw"; then
    echo "[WARN] No table detected with -t${RUNTIME_SEC}. Retrying with space form (-t $RUNTIME_SEC)..."
    { timeout --preserve-status "$(( RUNTIME_SEC * 5 ))" \
        numactl --cpunodebind="$CPU_NODE" --membind="$CPU_NODE" \
        stdbuf -oL -eL "$MLC_BIN" --loaded_latency -t "$RUNTIME_SEC" -X \
        |& tee "$raw" >/dev/null; } || true
  fi

  # If raw is empty, fail early with a diagnostic suggestion.
  if [[ ! -s "$raw" ]]; then
    echo "[ERROR] MLC produced no output (file empty): $raw"
    echo "        Try: stdbuf -oL -eL $MLC_BIN --loaded_latency -t$RUNTIME_SEC -X 2>&1 | head -n 80"
    exit 3
  fi

  # Python parser (stdlib only) – robust to multiple MLC formats.
  local PY_PARSE="$RESULT_ROOT/sec5/parse_loaded.py"
  cat > "$PY_PARSE" <<'PYCODE'
import re, sys, csv
from pathlib import Path

raw_file, rep_s, raw_csv = sys.argv[1], sys.argv[2], sys.argv[3]
rep = int(rep_s)

# Regex for inline units (Plan B/C)
RE_BW = re.compile(r'([0-9]+(?:\.[0-9]+)?)\s*(GB/s|GB/sec|GBps|MB/s|MB/sec|MBps)', re.I)
RE_LT = re.compile(r'([0-9]+(?:\.[0-9]+)?)\s*(ns|us|usec|ms|msec)', re.I)

def to_gbps(val, unit, assume_mb=False):
    v = float(val)
    if unit:
        u = unit.lower()
        return v/1000.0 if u.startswith('mb') else v
    return (v/1000.0) if assume_mb else v

def to_ns(val, unit, assume_ns=False):
    v = float(val)
    if unit:
        u = unit.lower()
        if u == 'ns': return v
        if u in ('us','usec'): return v*1_000.0
        if u in ('ms','msec'): return v*1_000_000.0
        return v
    return v if assume_ns else v

# Normalize CR -> LF (MLC uses \r for live progress), also drop tabs for simpler split.
content = Path(raw_file).read_text(errors='ignore').replace('\r', '\n').replace('\t', '    ')
lines = content.splitlines()

pairs = []

# ---- Plan A: header line that contains both “Bandwidth” and “Latency”; units are in header ----
hdr_idx, hdr = None, None
for i, ln in enumerate(lines):
    low = ln.lower()
    if 'bandwidth' in low and 'latency' in low:
        hdr_idx, hdr = i, ln
        break

if hdr_idx is not None:
    bw_is_mb = ('mb/s' in hdr.lower() or 'mbps' in hdr.lower())
    lat_is_ns = ('ns' in hdr.lower())
    for ln in lines[hdr_idx+1:]:
        if not ln.strip():
            if pairs: break
            else: continue
        nums = re.findall(r'[-+]?\d+(?:\.\d+)?', ln)
        if len(nums) >= 2:
            bw = to_gbps(nums[0], unit=None, assume_mb=bw_is_mb)
            lt = to_ns(  nums[1], unit=None, assume_ns=lat_is_ns)
            pairs.append((bw, lt))
        else:
            if pairs: break

# ---- Plan B: same-line pairing with explicit units ----
if not pairs:
    for ln in lines:
        m_bw = RE_BW.search(ln)
        m_lt = RE_LT.search(ln)
        if m_bw and m_lt:
            bw = to_gbps(m_bw.group(1), m_bw.group(2))
            lt = to_ns( m_lt.group(1), m_lt.group(2))
            pairs.append((bw, lt))

# ---- Plan C: cross-line pairing (nearest neighbor) ----
if not pairs:
    pending_bw = None
    for ln in lines:
        m_bw = RE_BW.search(ln)
        m_lt = RE_LT.search(ln)
        if m_bw and not m_lt:
            pending_bw = to_gbps(m_bw.group(1), m_bw.group(2))
            continue
        if m_lt and pending_bw is not None:
            lt = to_ns(m_lt.group(1), m_lt.group(2))
            pairs.append((pending_bw, lt))
            pending_bw = None

if not pairs:
    sys.stderr.write("No (throughput, latency) pairs parsed from MLC output.\n")
    preview = "\n".join(lines[:80])
    sys.stderr.write("=== MLC output preview (first 80 lines) ===\n" + preview + "\n===========================================\n")
    sys.exit(4)

with open(raw_csv, 'a', newline='') as out:
    w = csv.writer(out)
    for bw, lt in pairs:
        w.writerow([rep, f"{bw:.6f}", f"{lt:.6f}"])
PYCODE

  python3 "$PY_PARSE" "$raw" "$rep" "$RAW"
}



for r in $(seq 1 "$REPEAT"); do
  run_one "$r"
done

# --------------- Plot & Markdown (error bars with units) ---------------
PY_PLOT="$RESULT_ROOT/sec5/plot_sec5.py"
cat > "$PY_PLOT" <<'PYCODE'
import os, sys, numpy as np, pandas as pd, matplotlib.pyplot as plt
raw_csv, fig_dir, out_md = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(fig_dir, exist_ok=True); os.makedirs(os.path.dirname(out_md), exist_ok=True)

df = pd.read_csv(raw_csv)
df['bandwidth_gbs'] = pd.to_numeric(df['bandwidth_gbs'], errors='coerce')
df['latency_ns']    = pd.to_numeric(df['latency_ns'], errors='coerce')
df = df.dropna()

# Bucket throughput (0.25 GB/s) so multiple runs align; compute mean ± std of latency
df['bw_bucket'] = (df['bandwidth_gbs']/0.25).round()*0.25
agg = (df.groupby('bw_bucket')['latency_ns']
         .agg(['count','mean','std'])
         .reset_index()
         .rename(columns={'bw_bucket':'bandwidth_gbs'})).sort_values('bandwidth_gbs')

fig_path = os.path.join(fig_dir, 'throughput_latency.png')
knee_txt = "N/A"

if len(agg) >= 2:
    plt.figure(figsize=(7.5,5))
    plt.errorbar(agg['bandwidth_gbs'], agg['mean'],
                 yerr=agg['std'].fillna(0.0),
                 fmt='-o', capsize=5)
    plt.xlabel('Throughput (GB/s)')
    plt.ylabel('Latency (ns)')
    plt.title('Throughput–Latency (MLC loaded_latency, mean ± std)')
    plt.grid(True, linestyle='--', alpha=0.5)
    plt.savefig(fig_path, bbox_inches='tight', dpi=150)
    plt.close()

    # Knee via curvature on the mean curve
    x = agg['bandwidth_gbs'].values; y = agg['mean'].values
    order = np.argsort(x); x, y = x[order], y[order]
    if len(x) >= 3 and np.all(np.diff(x) > 0):
        try:
            d1 = np.gradient(y, x, edge_order=2)
            d2 = np.gradient(d1,  x, edge_order=2)
            curv = np.abs(d2) / (1 + d1**2)**1.5
            i = int(np.argmax(curv))
            knee_txt = f"BW≈{x[i]:.2f} GB/s, Lat≈{y[i]:.1f} ns"
        except Exception:
            knee_txt = "N/A"
else:
    # If we do not have enough buckets, show scatter (still with units)
    plt.figure(figsize=(7.5,5))
    plt.scatter(df['bandwidth_gbs'], df['latency_ns'], s=18)
    plt.xlabel('Throughput (GB/s)')
    plt.ylabel('Latency (ns)')
    plt.title('Throughput–Latency (scatter)')
    plt.grid(True, linestyle='--', alpha=0.5)
    plt.savefig(fig_path, bbox_inches='tight', dpi=150)
    plt.close()

# Markdown (no external deps)
with open(out_md, 'w') as f:
    f.write("## 5. Access Intensity Sweep (MLC Loaded Latency)\n\n")
    f.write("### 5.3 Output Results (bucketed by throughput)\n\n")
    if len(agg):
        f.write("| Throughput (GB/s) | Mean Latency (ns) | Std (ns) | Count |\n")
        f.write("| --- | --- | --- | --- |\n")
        for _, r in agg.iterrows():
            std = 0.0 if pd.isna(r['std']) else r['std']
            f.write(f"| {r['bandwidth_gbs']:.2f} | {r['mean']:.2f} | {std:.2f} | {int(r['count'])} |\n")
        f.write("\n")
    f.write(f"**Knee (approx.)**: {knee_txt}\n\n")
    f.write("![Throughput–Latency](../figs/sec5/throughput_latency.png)\n\n")
    f.write("### 5.4 Analysis\n\n")
    f.write("- As injected throughput rises, queueing delays increase, so average latency climbs; after the knee, returns diminish.\n")
    f.write("- Error bars denote standard deviation across REPEAT runs per throughput bucket.\n")
print("OK:", fig_dir, fig_path, out_md)
PYCODE

FIG_DIR="$FIG_ROOT/sec5"
OUT_MD="$OUT_ROOT/section_5_intensity.md"
python3 "$PY_PLOT" "$RAW" "$FIG_DIR" "$OUT_MD"

echo "✅ Done."
echo "RAW : $RAW"
echo "FIG : $FIG_DIR/throughput_latency.png"
echo "MD  : $OUT_MD"
