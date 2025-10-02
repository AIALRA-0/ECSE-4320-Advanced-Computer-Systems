#!/usr/bin/env bash
set -euo pipefail

# ===== 变量区（可改） =====
: "${TARGET:=/mnt/ssdtest/fiofile}"   
: "${REPEAT:=5}"
: "${ENGINE:=io_uring}"                    # io_uring | libaio
: "${RUNTIME:=30}"
: "${RAMP:=5}"
# =========================

mkdir -p out results tables figs tmp

echo "[环境] 检查与安装依赖..."
if command -v apt >/dev/null 2>&1; then
  sudo apt update -y
  sudo apt install -y fio jq gnuplot python3 python3-pip smartmontools nvme-cli sysstat linux-tools-common || true
  python3 - <<'PY'
import sys, subprocess
def pipi(pkg):
    try:
        __import__(pkg)
    except Exception:
        subprocess.check_call([sys.executable,"-m","pip","install","--break-system-packages",pkg])
for p in ["matplotlib","numpy","pandas"]:
    pipi(p)
print("[环境] Python 依赖就绪")
PY
fi

echo "[环境] CPU 频率与系统噪声（尽力而为）..."
sudo systemctl stop ondemand 2>/dev/null || true
if command -v cpupower >/dev/null 2>&1; then
  sudo cpupower frequency-set -g performance || true
fi
sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

echo "[环境] WSL/原生检测与直通建议..."
if grep -qi microsoft /proc/version; then
  echo "检测到 WSL 环境。强烈建议："
  echo "1) 使用 wsl --mount 直通裸盘，并在 WSL 中对 /dev/* 设备测试；"
  echo "2) 避免 /mnt/c 等 DrvFs 路径；优先使用 ext4/xfs 本地文件系统；"
  echo "3) 若需 SMART/温度/节流观测，优先在原生 Ubuntu 运行。"
fi

echo "[环境] 设备与健康信息（可选）保存到 out/env.txt"
{
  echo "==== uname -a ===="; uname -a
  echo "==== lsblk ===="; lsblk -o NAME,MODEL,SIZE,TYPE,MOUNTPOINT
  echo "==== nvme list ===="; sudo nvme list 2>/dev/null || true
  echo "==== smartctl (nvme0) ===="; sudo smartctl -a /dev/nvme0 2>/dev/null || true
} | tee out/env.txt

# 引擎自检
if ! fio -enghelp 2>/dev/null | grep -q "$ENGINE"; then
  echo "[警告] $ENGINE 不可用，回退到 libaio"
  ENGINE=libaio
fi

# 若 TARGET 是文件路径，确保存在大文件（默认 64G）
if [[ "$TARGET" == /* && ! -b "$TARGET" && ! -f "$TARGET" ]]; then
  echo "[准备] 创建测试文件 $TARGET (64G)"
  sudo mkdir -p "$(dirname "$TARGET")"
  sudo fallocate -l 64G "$TARGET"
  sudo chown "$USER":"$USER" "$TARGET"
fi

# 记录本节方法学，生成可直接粘贴的片段
cat > out/section_1_methodology.md <<EOF
### 实验环境与方法学

硬件与系统：见 out/env.txt 摘要  
路径与介质：TARGET=$TARGET（文件系统/裸设备请据实描述；若为文件，已使用 direct=1 绕过页缓存）  
I/O 引擎：$ENGINE；运行策略：每点重复 $REPEAT 次，runtime=$RUNTIME s，ramp_time=$RAMP s  
主机隔离：已尝试固定 CPU governor、停止部分后台定时服务  
健康观测：nvme-cli / smartctl 见 out/env.txt（若在 WSL，指标可能不完整）

EOF

echo "[完成] 将 out/section_1_methodology.md 粘贴到本节“结果粘贴处”。"
