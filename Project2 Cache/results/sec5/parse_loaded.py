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
