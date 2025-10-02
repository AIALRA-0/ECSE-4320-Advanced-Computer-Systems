#!/usr/bin/env bash
# Detection + Auto Fix Installation (excluding MLC installation)
# - When run as root or with --fix: automatically install perf/numactl/msr-tools/python dependencies, and relax perf sysctl settings
# - When not root or with --detect-only: only detect, do not modify the system
# - Always: only detect MLC (requires official version), do not install/replace MLC
set -euo pipefail

# ====== Parse Run Mode ======
FIX=0
if [[ "${1:-}" == "--detect-only" ]]; then
  FIX=0
elif [[ "${1:-}" == "--fix" ]]; then
  FIX=1
elif [[ $EUID -eq 0 ]]; then
  FIX=1
fi

PROJECT_ROOT="$(pwd)"
OUT_DIR="$PROJECT_ROOT/out"
VENV_DIR="$PROJECT_ROOT/.venv"
mkdir -p "$OUT_DIR"

pass(){ echo "[PASS] $*"; }
fail(){ echo "[FAIL] $*"; }
info(){ echo "[INFO]  $*"; }
warn(){ echo "[WARN]  $*" >&2; }

EXIT_CODE=0

# ====== Record Basic Info (no system modification) ======
(lscpu || true) > "$OUT_DIR/sys_lscpu.txt"
(numactl --hardware || true) > "$OUT_DIR/sys_numactl.txt"
(uname -a || true) > "$OUT_DIR/sys_uname.txt"
(date -Is || true) > "$OUT_DIR/sys_datetime.txt"
if [[ -r /sys/kernel/mm/transparent_hugepage/enabled ]]; then
  {
    echo -n "enabled: "; cat /sys/kernel/mm/transparent_hugepage/enabled
    echo -n "defrag:  "; cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
  } > "$OUT_DIR/thp_status.txt"
fi

# ====== Detect Package Manager ======
PKG_TOOL=""
if command -v apt-get >/dev/null 2>&1; then
  PKG_TOOL="apt"
elif command -v dnf >/dev/null 2>&1; then
  PKG_TOOL="dnf"
elif command -v yum >/dev/null 2>&1; then
  PKG_TOOL="yum"
elif command -v pacman >/dev/null 2>&1; then
  PKG_TOOL="pacman"
fi

pkg_install() {
  local pkgs=("$@")
  case "$PKG_TOOL" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y --no-install-recommends "${pkgs[@]}"
      ;;
    dnf)  dnf -y install "${pkgs[@]}";;
    yum)  yum -y install "${pkgs[@]}";;
    pacman) pacman -Sy --noconfirm "${pkgs[@]}";;
    *) warn "No supported package manager detected, unable to auto-install: ${pkgs[*]}"; return 1;;
  esac
}

# ====== Auto Fix (executed only when FIX=1; excludes MLC) ======
if [[ $FIX -eq 1 ]]; then
  info "Entering auto-fix mode (root or --fix). Will install missing dependencies (excluding MLC)."
  case "$PKG_TOOL" in
    apt)
      # perf / headers matched to current kernel
      pkg_install build-essential gcc make git numactl msr-tools \
                  python3 python3-venv python3-pip ca-certificates \
                  linux-tools-common "linux-tools-$(uname -r)" "linux-headers-$(uname -r)" || true
      ;;
    dnf|yum)
      pkg_install gcc gcc-c++ make git numactl msr-tools \
                  python3 python3-pip perf kernel-tools ca-certificates || true
      ;;
    pacman)
      pkg_install base-devel git numactl msr-tools \
                  python python-pip python-virtualenv perf cpupower ca-certificates || true
      ;;
    *)
      warn "Unable to auto-fix system packages (unsupported package manager)"
      ;;
  esac

  # Relax perf sysctl (does not affect existing governor/frequency)
  SYSCTL_CONF="/etc/sysctl.d/99-ecse4320-perf.conf"
  echo "kernel.perf_event_paranoid=1" > "$SYSCTL_CONF"
  echo "kernel.kptr_restrict=0"      >> "$SYSCTL_CONF"
  sysctl -p "$SYSCTL_CONF" || warn "sysctl apply failed, can be ignored"

  # Python venv + scientific packages (no root needed; prefer project-local venv)
  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    info "Creating Python venv: $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi
  "$VENV_DIR/bin/python" -m pip install -U pip >/dev/null 2>&1 || true
  "$VENV_DIR/bin/python" -m pip install -U numpy pandas matplotlib >/dev/null 2>&1 || {
    warn "Project venv package installation failed, trying system pip --user"
    python3 -m pip install -U --user numpy pandas matplotlib || warn "System pip install also failed"
  }
else
  info "Detection-only mode: no dependencies will be installed or system modified. To auto-fix, run as root or append --fix"
fi

# ====== Detect perf ======
if command -v perf >/dev/null 2>&1; then
  (perf --version || true) > "$OUT_DIR/perf_version.txt"
  pass "perf available: $(perf --version 2>/dev/null | tr -d '\n')"
else
  fail "perf not available (suggest install: linux-tools-$(uname -r) / perf / kernel-tools)"
  EXIT_CODE=1
fi

# ====== Detect Python and Dependencies ======
PY_OK=0
if [[ -x "$VENV_DIR/bin/python" ]]; then
  PYBIN="$VENV_DIR/bin/python"
else
  PYBIN="$(command -v python3 || true)"
fi

if [[ -n "${PYBIN:-}" ]]; then
  N_OK="$("$PYBIN" - <<'PY'
try:
  import numpy, pandas, matplotlib
  print("OK")
except Exception as e:
  print("NO")
PY
)"
  if [[ "$N_OK" == "OK" ]]; then
    pass "Python dependencies available (numpy/pandas/matplotlib)"
    PY_OK=1
  else
    fail "Missing Python dependencies (numpy/pandas/matplotlib). Suggestion: create venv and install."
    EXIT_CODE=1
  fi
else
  fail "No python3 executable found"
  EXIT_CODE=1
fi

# ====== Detect MLC (detection only, no install/replace) ======
if ! command -v mlc >/dev/null 2>&1; then
  fail "mlc not found (please install official version: install_official_mlc.sh)"
  EXIT_CODE=2
else
  HELP_OUT="$(mlc --help 2>&1 || true)"
  echo "$HELP_OUT" > "$OUT_DIR/mlc_help_check.txt"
  if echo "$HELP_OUT" | grep -qE 'Intel\(R\) Memory Latency Checker|--latency_matrix|--max_bandwidth|--loaded_latency'; then
    pass "MLC check passed (appears to be official): $(command -v mlc)"
  else
    fail "Non-official MLC detected (help info lacks official identifiers/options). Path: $(command -v mlc)"
    EXIT_CODE=2
  fi
fi

# ====== Summary and Exit Code ======
info "Detection complete. Data and info written to: $OUT_DIR"
if [[ $EXIT_CODE -eq 0 ]]; then
  info "Conclusion: Environment meets requirements, you can directly run experiment scripts (sec2~sec8)."
else
  warn "Conclusion: Some requirements unmet (exit code=$EXIT_CODE). Please fix before running experiment scripts."
fi
exit $EXIT_CODE
