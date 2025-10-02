#!/usr/bin/env bash
set -euo pipefail

# ===== Config (edit as needed; comments in EN) =====
: "${TARGET:=/mnt/ssdtest/fio_testfile}"   # file or block device
: "${ENGINE:=io_uring}"                    # fallback: libaio
: "${RUNTIME_SHORT:=30}"                   # seconds (burst)
: "${RUNTIME_LONG:=600}"                   # seconds (steady)
: "${RAMP:=5}"                             # warm-up seconds
: "${QD:=32}"                              # iodepth
: "${BS:=4k}"                              # block size
: "${HOT_SIZE:=2G}"                        # hotspot working set size
: "${FULL_SIZE:=64G}"                      # full-span size (match your file)
OUT="results/sect6"; mkdir -p "$OUT" tables figs tmp out

# ---- smoke test ----
fio --name=smoke --rw=read --bs=$BS --filename="$TARGET" \
    --ioengine=$ENGINE --direct=1 --time_based=1 --runtime=2 --ramp_time=0 \
    --iodepth=1 --numjobs=1 --group_reporting=1 --thread=1 \
    $([[ -b "$TARGET" ]] || echo "--size=$HOT_SIZE") \
    --output="$OUT/smoke.json" --output-format=json >/dev/null 2>&1 || true

# ---- Hotset vs Full (randread) ----
run_rr() {
  local label="$1" size="$2" rt="$3"
  fio --name="rr_${label}" --rw=randread --bs=$BS --filename="$TARGET" \
      --ioengine=$ENGINE --direct=1 --time_based=1 --ramp_time=$RAMP --runtime=$rt \
      --iodepth=$QD --numjobs=1 --group_reporting=1 --thread=1 \
      --percentile_list=50:95:99:99.9 \
      $([[ -b "$TARGET" ]] || echo "--size=$size") \
      --output="$OUT/rr_${label}.json" --output-format=json >/dev/null 2>&1
}
run_rr hot "$HOT_SIZE" 30
run_rr full "$FULL_SIZE" 30

# ---- Burst vs Steady (randwrite; WARNING: wear!) ----
run_rw() {
  local label="$1" rt="$2"
  fio --name="rw_${label}" --rw=randwrite --bs=$BS --filename="$TARGET" \
      --ioengine=$ENGINE --direct=1 --time_based=1 --ramp_time=$RAMP --runtime=$rt \
      --iodepth=$QD --numjobs=1 --group_reporting=1 --thread=1 \
      --percentile_list=50:95:99:99.9 \
      $([[ -b "$TARGET" ]] || echo "--size=$FULL_SIZE") \
      --output="$OUT/rw_${label}.json" --output-format=json >/dev/null 2>&1
}
run_rw burst $RUNTIME_SHORT
run_rw steady $RUNTIME_LONG

# ---- Parse & plot (matplotlib; no seaborn; default colors) ----
python3 - <<'PY'
import json,glob,pandas as pd,matplotlib.pyplot as plt,os
OUT="results/sect6"; os.makedirs("tables",exist_ok=True); os.makedirs("figs",exist_ok=True)

def pick(fn):
    j=json.load(open(fn)); job=j['jobs'][0]; rd=job.get('read',{}); wr=job.get('write',{})
    kind='read' if rd.get('io_bytes',0)>0 else 'write'
    m=rd if kind=='read' else wr
    return dict(label=os.path.splitext(os.path.basename(fn))[0],
                kind=kind,
                bw_MBps=m['bw_bytes']/(1024*1024),
                lat_ms=m['lat_ns']['mean']/1e6,
                p50=m['clat_ns']['percentile'].get('50.000000',0.0)/1e6,
                p95=m['clat_ns']['percentile'].get('95.000000',0.0)/1e6,
                p99=m['clat_ns']['percentile'].get('99.000000',0.0)/1e6,
                p999=m['clat_ns']['percentile'].get('99.900000',0.0)/1e6)

rows=[pick(f) for f in sorted(glob.glob(f"{OUT}/*.json"))]
df=pd.DataFrame(rows)
if not df.empty: df.to_csv("tables/sect6_summary.csv",index=False)

# Hotset vs Full (randread)
rr=df[df['label'].str.startswith('rr_')].copy()
if not rr.empty:
    rr['case']=rr['label'].str.replace('rr_','',regex=False)
    plt.figure(); plt.bar(rr['case'], rr['bw_MBps']); plt.ylabel('MB/s'); plt.title('Hotset vs Full (randread, BW)')
    plt.tight_layout(); plt.savefig('figs/sect6_rr_bw.png'); plt.close()
    plt.figure(); plt.bar(rr['case'], rr['lat_ms']); plt.ylabel('Mean Latency (ms)'); plt.title('Hotset vs Full (randread, latency)')
    plt.tight_layout(); plt.savefig('figs/sect6_rr_lat.png'); plt.close()
    for p in ['p50','p95','p99','p999']:
        plt.figure(); plt.bar(rr['case'], rr[p]); plt.ylabel(f'{p.upper()} (ms)'); plt.title(f'Hotset vs Full (randread, {p})')
        plt.tight_layout(); plt.savefig(f'figs/sect6_rr_{p}.png'); plt.close()

# Burst vs Steady (randwrite)
rw=df[df['label'].str.startswith('rw_')].copy()
if not rw.empty:
    rw['case']=rw['label'].str.replace('rw_','',regex=False)
    plt.figure(); plt.bar(rw['case'], rw['bw_MBps']); plt.ylabel('MB/s'); plt.title('Burst vs Steady (randwrite, BW)')
    plt.tight_layout(); plt.savefig('figs/sect6_rw_bw.png'); plt.close()
    plt.figure(); plt.bar(rw['case'], rw['lat_ms']); plt.ylabel('Mean Latency (ms)'); plt.title('Burst vs Steady (randwrite, latency)')
    plt.tight_layout(); plt.savefig('figs/sect6_rw_lat.png'); plt.close()
    for p in ['p50','p95','p99','p999']:
        plt.figure(); plt.bar(rw['case'], rw[p]); plt.ylabel(f'{p.upper()} (ms)'); plt.title(f'Burst vs Steady (randwrite, {p})')
        plt.tight_layout(); plt.savefig(f'figs/sect6_rw_{p}.png'); plt.close()

with open('out/section_6_wss_burst.md','w') as fh:
    fh.write("#### Working Set & Burst vs Steady (qualitative with optional quant.)\\n\\n")
    fh.write("Table: `tables/sect6_summary.csv`\\n\\n")
    fh.write("Figures (if generated): `figs/sect6_rr_*`, `figs/sect6_rw_*`\\n")
PY
echo "[DONE] sect6: tables/sect6_summary.csv; figs/sect6_*.png; out/section_6_wss_burst.md"
