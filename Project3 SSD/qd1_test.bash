#!/usr/bin/env bash
set -euo pipefail

# ===== Variables Section (modifiable) =====
: "${TARGET:=/mnt/ssdtest/fiofile}"      # Recommend using an unmounted partition; if whole disk/unsafe, script switches to file.
: "${ENGINE:=io_uring}"
: "${REPEAT:=3}"
: "${RUNTIME:=30}"
: "${RAMP:=5}"
: "${FILESIZE:=8g}"                      # Test file size
# =========================

OUTDIR="results/qd1_test"
mkdir -p /mnt/ssdtest "$OUTDIR" tables figs tmp out

# === Whole disk fallback -> Use file ===
is_whole_disk() { local t; t="$(lsblk -no TYPE "$1" 2>/dev/null || true)"; [[ "$t" == "disk" ]]; }
if [[ -b "$TARGET" ]] && is_whole_disk "$TARGET"; then
  echo "[Safe] Detected whole disk device, switching to /mnt/ssdtest/fiofile"
  TARGET="/mnt/ssdtest/fiofile"
fi
# Create test file if needed
if [[ ! -b "$TARGET" && ! -f "$TARGET" ]]; then
  sudo mkdir -p "$(dirname "$TARGET")"
  sudo fallocate -l "$FILESIZE" "$TARGET"
  sudo chown "$USER":"$USER" "$TARGET"
fi

run_case() { # name rw bs extra_opts
  local name="$1" rw="$2" bs="$3" extra="${4:-}"
  for r in $(seq 1 "$REPEAT"); do
    echo "[RUN] $name $rw $bs (run $r)"
    fio --name="$name" \
        --filename="$TARGET" \
        --ioengine="$ENGINE" \
        --direct=1 \
        --time_based=1 \
        --ramp_time="$RAMP" \
        --runtime="$RUNTIME" \
        --group_reporting=1 \
        --numjobs=1 \
        --iodepth=1 \
        --thread=1 \
        --percentile_list=50:95:99:99.9 \
        --rw="$rw" --bs="$bs" $extra \
        ${TARGET/*\/mnt\/ssdtest\/*/--size=$FILESIZE} \
        --output="$OUTDIR/${name}_${r}.json" \
        --output-format=json --aux-path=tmp
  done
}

echo "[RUN] QD=1 baseline, 4 independent tasks..."

# 4k random requires 4K alignment
run_case randread_qd1  randread  4k   "--offset_align=4k"
run_case randwrite_qd1 randwrite 4k   "--offset_align=4k"
run_case read128k_qd1  read      128k ""
run_case write128k_qd1 write     128k ""

# === Parse and Plot Results ===
python3 - <<'PY'
import json,glob,pandas as pd,numpy as np,matplotlib.pyplot as plt,os

# Only scan results from qd1_test folder
files=sorted(glob.glob("results/qd1_test/*.json"))
rows=[]

for f in files:
    with open(f) as fh:
        j=json.load(fh)
    for job in j.get('jobs',[]):
        name=job.get('jobname')
        opt=job.get('job options',{})
        rw=opt.get('rw','')
        bs=opt.get('bs','')
        iodepth=int(opt.get('iodepth','1') or 1)

        # Collect only non-empty read/write branches
        for kind in ['read','write']:
            if kind not in job: 
                continue
            m=job[kind]
            if m.get('io_bytes',0)==0 and m.get('total_ios',0)==0:
                continue   # skip empty branches
            rows.append({
                'jobname':name,
                'mode':kind,
                'rw':rw,
                'bs':bs,
                'iodepth':iodepth,
                'bw_bytes':m.get('bw_bytes',0),
                'iops':m.get('iops',0.0),
                'lat_ns_mean':m.get('lat_ns',{}).get('mean',0.0),
                'p50':m.get('clat_ns',{}).get('percentile',{}).get('50.000000',None),
                'p95':m.get('clat_ns',{}).get('percentile',{}).get('95.000000',None),
                'p99':m.get('clat_ns',{}).get('percentile',{}).get('99.000000',None),
            })

# Convert into DataFrame
df=pd.DataFrame(rows)
for c in ['lat_ns_mean','p50','p95','p99']:
    df[c]=pd.to_numeric(df[c], errors='coerce')

# Unit conversions
df['lat_ms_mean']=df['lat_ns_mean']/1e6
df['p50_ms']=df['p50']/1e6
df['p95_ms']=df['p95']/1e6
df['p99_ms']=df['p99']/1e6
df['bw_MBps']=df['bw_bytes']/(1024*1024)

# Group by jobname + mode + parameters
agg=df.groupby(['jobname','mode','bs','rw','iodepth'], dropna=False).agg(
    iops_mean=('iops','mean'),
    iops_std=('iops','std'),
    lat_ms_mean=('lat_ms_mean','mean'),
    lat_ms_std=('lat_ms_mean','std'),
    p50_ms=('p50_ms','mean'),
    p95_ms=('p95_ms','mean'),
    p99_ms=('p99_ms','mean'),
    bw_MBps=('bw_MBps','mean')
).reset_index()

# Fill missing std with 0
agg[['iops_std','lat_ms_std']]=agg[['iops_std','lat_ms_std']].fillna(0.0)

# Save to CSV
os.makedirs('tables',exist_ok=True)
agg.to_csv('tables/qd1_baseline.csv',index=False)

# === Plot: Mean Latency ===
labels=agg['jobname']+"-"+agg['mode']; x=np.arange(len(labels))
plt.figure(figsize=(8,6))
bars=plt.bar(x, agg['lat_ms_mean'], yerr=agg['lat_ms_std'], capsize=5)
plt.xticks(x, labels, rotation=45, ha='right')
plt.ylabel('Mean Latency (ms)')
plt.title('QD=1 Baseline: Mean Latency')

for b,m,s,p in zip(bars,agg['lat_ms_mean'],agg['lat_ms_std'],agg['p50_ms']):
  m=0 if pd.isna(m) else m; s=0 if pd.isna(s) else s; p=0 if pd.isna(p) else p
  plt.text(b.get_x()+b.get_width()/2, m,
           f"{m:.5f}±{s:.5f}\n(p50={p:.5f})",
           ha='center', va='bottom', fontsize=8)

plt.tight_layout()
os.makedirs('figs',exist_ok=True)
plt.savefig('figs/qd1_mean_latency.png')
plt.close()

# === Plot: IOPS ===
plt.figure(figsize=(8,6))
bars=plt.bar(x, agg['iops_mean'], yerr=agg['iops_std'], capsize=5)
plt.xticks(x, labels, rotation=45, ha='right')
plt.ylabel('IOPS')
plt.title('QD=1 Baseline: IOPS')

for b,v,s in zip(bars,agg['iops_mean'],agg['iops_std']):
  v=0 if pd.isna(v) else v; s=0 if pd.isna(s) else s
  plt.text(b.get_x()+b.get_width()/2, v,
           f"{v:.5f}±{s:.5f}",
           ha='center', va='bottom', fontsize=8)

plt.tight_layout()
plt.savefig('figs/qd1_iops.png')
plt.close()

# === Markdown Table Output ===
def md_table(t):
  cols=['Mode','Block Size','Read/Write','Avg Latency(ms)',
        'p50(ms)','p95(ms)','p99(ms)','IOPS','MB/s']
  lines=["| "+" | ".join(cols)+" |",
         "| -- | -- | -- | --: | --: | --: | --: | --: | --: |"]
  for _,r in t.iterrows():
    mode = 'Random' if 'rand' in (r['rw'] or '') else 'Sequential'
    rw   = 'Read' if r['mode']=='read' else ('Write' if r['mode']=='write' else r['mode'])
    lines.append(
      f"| {mode} | {r['bs']} | {rw} "
      f"| {r['lat_ms_mean']:.5f}±{r['lat_ms_std']:.5f} "
      f"| {r['p50_ms']:.5f} | {r['p95_ms']:.5f} | {r['p99_ms']:.5f} "
      f"| {r['iops_mean']:.5f}±{r['iops_std']:.5f} "
      f"| {r['bw_MBps']:.5f} |"
    )
  return "\n".join(lines)

with open('out/section_2_qd1.md','w') as fh:
    fh.write("#### QD=1 Baseline Table\n\n")
    fh.write(md_table(agg)+"\n\n")
    fh.write("Figures: `figs/qd1_mean_latency.png`, `figs/qd1_iops.png`\n")

print("[DONE] Clean results saved: tables/qd1_baseline.csv, figs/qd1_mean_latency.png, figs/qd1_iops.png, out/section_2_qd1.md")
PY
