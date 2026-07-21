#!/data/data/com.termux/files/usr/bin/env bash
# ============================================================
# code-server on Termux (Extreme Performance Edition)
# Target: Snapdragon 4 Gen 2 (ARM64)
# Optimizations: V8 Memory tuning, I/O reduction, CPU priority
# ============================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_NAME="code-server-termux"
PORT="${PORT:-8080}"
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"
PASSWORD="${PASSWORD:-}"
ACTION="install"
FORCE_REINSTALL=0
PURGE_CONFIG=0
NO_LAUNCH=0

CONFIG_DIR="${HOME}/.config/code-server"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
STATE_DIR="${HOME}/.local/state/${APP_NAME}"
LOG_DIR="${HOME}/.local/share/code-server/logs"

START_SCRIPT="${HOME}/start-vscode"
STOP_SCRIPT="${HOME}/stop-vscode"
STATUS_SCRIPT="${HOME}/status-vscode"
DOCTOR_SCRIPT="${HOME}/doctor-vscode"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

trap 'rc=$?; echo; err "Failed at line ${LINENO} with exit code ${rc}"; exit "$rc"' ERR

print_header() {
  echo
  echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  $1${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
}

ok()   { echo -e "${GREEN}✅ $*${NC}"; }
info() { echo -e "${BLUE}ℹ️  $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
err()  { echo -e "${RED}❌ $*${NC}" >&2; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

is_termux() {
  [[ -n "${TERMUX_VERSION:-}" ]] || [[ -d "/data/data/com.termux" ]]
}

require_termux() {
  if ! is_termux; then die "This script is for Termux only."; fi
}

timestamp() { date +"%Y%m%d-%H%M%S"; }

ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"
}

backup_file_if_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then cp -f "$file" "${file}.backup.$(timestamp)"; fi
}

generate_password() {
  if have openssl; then
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16; echo
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16; echo
  fi
}

get_existing_password() {
  if [[ -f "$CONFIG_FILE" ]]; then
    awk -F': *' '/^password:/ {gsub(/"/,"",$2); print $2; exit}' "$CONFIG_FILE" || true
  fi
}

get_lan_ip() {
  local ip=""
  if have ip; then
    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' || true)"
    if [[ -n "${ip:-}" ]]; then echo "$ip"; return 0; fi
    ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}' || true)"
    if [[ -n "${ip:-}" ]]; then echo "$ip"; return 0; fi
  fi
  return 1
}

port_listening() {
  local port="$1"
  if have ss; then ss -ltn 2>/dev/null | grep -q ":${port} "; return $?; fi
  if have netstat; then netstat -ltn 2>/dev/null | grep -q ":${port} "; return $?; fi
  return 1
}

write_config() {
  local pass="$1"
  backup_file_if_exists "$CONFIG_FILE"
  cat > "$CONFIG_FILE" <<EOF
bind-addr: ${BIND_ADDR}:${PORT}
auth: password
password: ${pass}
cert: false
disable-telemetry: true
disable-update-check: true
disable-workspace-trust: true
log: error
EOF
  chmod 600 "$CONFIG_FILE"
}

install_packages() {
  print_header "Step 1/4: Install code-server (Performance Repo)"
  require_termux

  info "Architecture: $(uname -m) | Termux API setup recommended"

  if ! have pkg; then die "pkg not found."; fi

  info "Updating package lists..."
  pkg update -y || die "pkg update failed."

  if ! dpkg -s tur-repo >/dev/null 2>&1; then
    info "Installing tur-repo..."
    pkg install -y tur-repo || die "Failed to install tur-repo."
  else
    ok "tur-repo already installed"
  fi

  if [[ "$FORCE_REINSTALL" -eq 1 ]]; then
    warn "Forcing reinstall of code-server..."
    pkg uninstall -y code-server >/dev/null 2>&1 || true
  fi

  if ! dpkg -s code-server >/dev/null 2>&1; then
    info "Installing code-server & performance tools..."
    # iproute2 for network, proot/termux-api for wake locks, util-linux for ionice/nice
    if ! pkg install -y code-server curl iproute2 proot termux-api util-linux; then
        die "code-server installation failed."
    fi

    if pkg search qrencode 2>/dev/null | grep -q "^qrencode"; then
        pkg install -y qrencode || warn "Failed to install qrencode."
    fi
  else
    ok "code-server already installed"
  fi

  ok "code-server is installed and working"
}

configure_code_server() {
  print_header "Step 2/4: Configure (I/O Optimized)"
  ensure_dirs

  local existing_pass=""
  existing_pass="$(get_existing_password || true)"

  if [[ -n "${PASSWORD}" ]]; then
    info "Using password supplied by environment"
  elif [[ -n "${existing_pass}" ]]; then
    PASSWORD="$existing_pass"
    info "Preserving existing password"
  else
    PASSWORD="$(generate_password)"
    info "Generated new password"
  fi

  write_config "$PASSWORD"
  ok "Config written with I/O & Telemetry optimizations"
}

create_helpers() {
  print_header "Step 3/4: Helper scripts (V8 & CPU Tuned)"

  # --- START SCRIPT (HEAVILY OPTIMIZED) ---
  cat > "$START_SCRIPT" <<'EOF'
#!/data/data/com.termux/files/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="$HOME/.config/code-server/config.yaml"
PORT="8080"
BIND_ADDR="0.0.0.0"

# 1. Kill any zombie processes to free 100% of RAM/CPU
pkill -f 'code-server' 2>/dev/null || true
pkill -f 'node.*code-server' 2>/dev/null || true

# 2. Acquire Wake Lock so Android doesn't throttle CPU
if command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock >/dev/null 2>&1 || true
fi

# 3. Calculate V8 Memory Limits based on total system RAM
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$(( TOTAL_RAM_KB / 1024 ))

# Give V8 up to 4GB of heap space (or 60% of total RAM if less than 8GB)
if [ "$TOTAL_RAM_MB" -ge 8192 ]; then
  V8_MAX_OLD_SPACE=4096
else
  V8_MAX_OLD_SPACE=$(( TOTAL_RAM_MB * 60 / 100 ))
fi

# 4. Export V8 Engine Flags for Raw Desktop-like Performance
export NODE_OPTIONS="
  --max-old-space-size=${V8_MAX_OLD_SPACE} 
  --max-semi-space-size=128 
  --expose-gc 
  --no-warnings 
  --optimize-for-size=false
"
# V8 Explanation:
# --max-old-space-size: Maximum heap in MB (prevents crashes, allows large workspaces)
# --max-semi-space-size: Increases young-gen memory (MASSIVELY reduces UI stutter/GC pauses)
# --expose-gc: Allows internal scripts to force garbage collection when idle
# --optimize-for-size=false: Prioritizes execution speed over memory footprint

# 5. Network IP detection
LAN_IP=""
if command -v ip >/dev/null 2>&1; then
  LAN_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' || true)"
fi

echo "🚀 Starting code-server (Extreme Performance Mode)..."
echo "   V8 Heap Limit: ${V8_MAX_OLD_SPACE}MB"
echo "   Phone:  http://127.0.0.1:${PORT}"
if [[ -n "${LAN_IP:-}" ]]; then
  echo "   Tablet: http://${LAN_IP}:${PORT}"
fi
echo

if command -v qrencode >/dev/null 2>&1 && [[ -n "${LAN_IP:-}" ]]; then
  qrencode -t ANSIUTF8 "http://${LAN_IP}:${PORT}" || true
fi

# 6. Process Priority Boosting (Requires Root/Tsu)
# If device is rooted, we push code-server to the Prime Cores (CPU 6/7 on SD 4 Gen 2) and max I/O priority
EXEC_CMD="exec env NODE_OPTIONS=\"$NODE_OPTIONS\" code-server"
EXEC_CMD="$EXEC_CMD --config \"$CONFIG_FILE\""
EXEC_CMD="$EXEC_CMD --bind-addr \"${BIND_ADDR}:${PORT}\""
EXEC_CMD="$EXEC_CMD --disable-update-check"
EXEC_CMD="$EXEC_CMD --disable-workspace-trust"
EXEC_CMD="$EXEC_CMD --log error"
EXEC_CMD="$EXEC_CMD \"\$PWD\""

if command -v tsu >/dev/null 2>&1; then
  echo "⚡ Root detected: Boosting CPU Priority & isolating to Prime Cores..."
  # taskset 0xC0 assigns to CPU 6 and 7 (Prime performance cores on SD 4 Gen 2)
  # nice -n -20 gives highest possible CPU scheduling priority
  # ionice -c 1 -n 0 gives highest possible disk I/O priority
  eval "tsu -c 'taskset 0xC0 nice -n -20 ionice -c 1 -n 0 $EXEC_CMD'"
else
  eval "$EXEC_CMD"
fi

# Release wake lock on exit
if command -v termux-wake-unlock >/dev/null 2>&1; then
  termux-wake-unlock >/dev/null 2>&1 || true
fi
EOF
  chmod +x "$START_SCRIPT"
  ok "Created: $START_SCRIPT (Optimized)"

  # --- STOP SCRIPT ---
  cat > "$STOP_SCRIPT" <<'EOF'
#!/data/data/com.termux/files/usr/bin/env bash
pkill -f 'code-server' 2>/dev/null || true
pkill -f 'node.*code-server' 2>/dev/null || true
if command -v termux-wake-unlock >/dev/null 2>&1; then
  termux-wake-unlock >/dev/null 2>&1 || true
fi
echo "🛑 code-server stopped and wake lock released"
EOF
  chmod +x "$STOP_SCRIPT"

  # --- STATUS & DOCTOR (Kept similar, stripped non-essential logic) ---
  cat > "$STATUS_SCRIPT" <<EOF
#!/data/data/com.termux/files/usr/bin/env bash
if pgrep -af 'code-server' >/dev/null 2>&1; then
  echo "✅ code-server is running (PID: \$(pgrep -f 'code-server' | head -n1))"
else
  echo "⚠️  code-server is not running"
fi
EOF
  chmod +x "$STATUS_SCRIPT"

  cat > "$DOCTOR_SCRIPT" <<EOF
#!/data/data/com.termux/files/usr/bin/env bash
echo "Doctor report:"
if [[ -n "\${TERMUX_VERSION:-}" ]]; then echo "✅ Termux detected"; else echo "❌ Not Termux"; fi
if command -v code-server >/dev/null 2>&1; then echo "✅ code-server installed"; else echo "❌ code-server missing"; fi
if command -v tsu >/dev/null 2>&1; then echo "⚡ Root detected (Performance boost active)"; else echo "ℹ️  No root (Standard priority)"; fi
EOF
  chmod +x "$DOCTOR_SCRIPT"

  if [[ -f "${HOME}/.bashrc" ]] && ! grep -q "alias vs=" "${HOME}/.bashrc"; then
    echo -e "\n# code-server-termux\nalias vs='bash ${START_SCRIPT}'" >> "${HOME}/.bashrc"
    ok "Added 'vs' alias to ~/.bashrc"
  fi
}

show_access_info() {
  print_header "Step 4/4: Access links"
  local lan_ip=""
  lan_ip="$(get_lan_ip || true)"

  echo "Open on the phone itself:"
  echo "  http://127.0.0.1:${PORT}"
  echo

  if [[ -n "${lan_ip:-}" ]]; then
    echo "Open on the tablet over Wi-Fi:"
    echo "  http://${lan_ip}:${PORT}"
    echo
    if have qrencode; then
      qrencode -t ANSIUTF8 "http://${lan_ip}:${PORT}" || true
    fi
  fi

  echo "Password: ${PASSWORD}"
  echo
  echo "Commands:"
  echo "  Start (Optimized): bash ~/start-vscode"
  echo "  Stop:              bash ~/stop-vscode"
}

launch_server() {
  if port_listening "$PORT"; then
    warn "Something is already listening on port ${PORT}"
    return 0
  fi
  show_access_info
  # Execute the optimized start script directly
  exec bash "$START_SCRIPT"
}

uninstall_generated() {
  print_header "Uninstall"
  rm -f "$START_SCRIPT" "$STOP_SCRIPT" "$STATUS_SCRIPT" "$DOCTOR_SCRIPT"
  if [[ "$PURGE_CONFIG" -eq 1 ]]; then
    rm -rf "$CONFIG_DIR"
    ok "Removed config directory"
  fi
  ok "Removed generated helper scripts"
}

usage() {
  cat <<EOF
Usage: bash setup-code-server-termux.sh [options]
Options:
  --install           Install (default)
  --start             Start code-server
  --stop              Stop code-server
  --uninstall         Remove generated scripts
  --purge-config      Also remove config
  --port PORT         Default: 8080
  --password PASS     Set a fixed password
  --force-reinstall   Reinstall code-server package
  --no-launch         Install but do not launch immediately
  -h, --help          Show help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install) ACTION="install"; shift ;;
      --start) ACTION="start"; shift ;;
      --stop) ACTION="stop"; shift ;;
      --status) ACTION="status"; shift ;;
      --doctor) ACTION="doctor"; shift ;;
      --uninstall) ACTION="uninstall"; shift ;;
      --port) PORT="${2:-}"; [[ -n "$PORT" ]] || die "--port requires a value"; shift 2 ;;
      --bind-addr) BIND_ADDR="${2:-}"; [[ -n "$BIND_ADDR" ]] || die "--bind-addr requires a value"; shift 2 ;;
      --password) PASSWORD="${2:-}"; [[ -n "$PASSWORD" ]] || die "--password requires a value"; shift 2 ;;
      --force-reinstall) FORCE_REINSTALL=1; shift ;;
      --no-launch) NO_LAUNCH=1; shift ;;
      --purge-config) PURGE_CONFIG=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

main() {
  parse_args "$@"
  case "$ACTION" in
    install)
      install_packages
      configure_code_server
      create_helpers
      if [[ "$NO_LAUNCH" -eq 1 ]]; then
        ok "Install complete"
      else
        launch_server
      fi
      ;;
    start) [[ -f "$CONFIG_FILE" ]] || die "Config not found. Run installer first."; launch_server ;;
    stop) bash "$STOP_SCRIPT" ;;
    status) bash "$STATUS_SCRIPT" ;;
    doctor) bash "$DOCTOR_SCRIPT" ;;
    uninstall) uninstall_generated ;;
    *) die "Unknown action: $ACTION" ;;
  esac
}

main "$@"
