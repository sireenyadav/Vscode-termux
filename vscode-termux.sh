#!/data/data/com.termux/files/usr/bin/env bash
# ============================================================
# code-server on Termux (phone-hosted, tablet/browser access)
# - Official Termux package path (tur-repo + code-server)
# - LAN URL auto-detection
# - Localhost URL for the phone itself
# - QR code optional
# - Start / stop / status / doctor / uninstall
# - No npm install path
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

have() {
  command -v "$1" >/dev/null 2>&1
}

is_termux() {
  [[ -n "${TERMUX_VERSION:-}" ]] || [[ -d "/data/data/com.termux" ]]
}

require_termux() {
  if ! is_termux; then
    die "This script is for Termux only."
  fi
}

timestamp() {
  date +"%Y%m%d-%H%M%S"
}

ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"
}

backup_file_if_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cp -f "$file" "${file}.backup.$(timestamp)"
  fi
}

generate_password() {
  if have openssl; then
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16
    echo
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16
    echo
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
    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '
      {
        for (i = 1; i <= NF; i++) {
          if ($i == "src") { print $(i+1); exit }
        }
      }' || true)"
    if [[ -n "${ip:-}" ]]; then
      echo "$ip"
      return 0
    fi

    for dev in wlan0 wlan1 eth0 rmnet_data0 rmnet_data1; do
      ip="$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}' || true)"
      if [[ -n "${ip:-}" ]]; then
        echo "$ip"
        return 0
      fi
    done

    ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}' || true)"
    if [[ -n "${ip:-}" ]]; then
      echo "$ip"
      return 0
    fi
  fi

  if have ifconfig; then
    ip="$(ifconfig 2>/dev/null | awk '
      /inet / && $2 != "127.0.0.1" { print $2; exit }
    ' || true)"
    [[ -n "${ip:-}" ]] && { echo "$ip"; return 0; }
  fi

  return 1
}

port_listening() {
  local port="$1"
  if have ss; then
    ss -ltn 2>/dev/null | grep -q ":${port} "
    return $?
  fi
  if have netstat; then
    netstat -ltn 2>/dev/null | grep -q ":${port} "
    return $?
  fi
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
EOF
  chmod 600 "$CONFIG_FILE"
}

install_packages() {
  print_header "Step 1/4: Install code-server"

  require_termux

  info "Termux detected"
  info "Architecture: $(uname -m)"
  info "Home: $HOME"

  if ! have pkg; then
    die "pkg not found."
  fi

  info "Updating package lists..."
  if ! pkg update -y; then
    die "pkg update failed. Fix your repository/mirror setup and rerun."
  fi

  if ! dpkg -s tur-repo >/dev/null 2>&1; then
    info "Installing tur-repo..."
    if ! pkg install -y tur-repo; then
      die "Failed to install tur-repo. Run termux-change-repo and rerun."
    fi
  else
    ok "tur-repo already installed"
  fi

  if [[ "$FORCE_REINSTALL" -eq 1 ]]; then
    warn "Forcing reinstall of code-server..."
    pkg uninstall -y code-server >/dev/null 2>&1 || true
  fi

  if ! dpkg -s code-server >/dev/null 2>&1; then
    info "Installing code-server from Termux repositories..."
    if ! pkg install -y code-server curl procps iproute2 qrencode; then
      err "code-server install failed."
      echo
      echo "Try:"
      echo "  pkg search code-server"
      echo "  termux-change-repo"
      echo
      die "Stopping here. I am not falling back to npm because that path broke on your device."
    fi
  else
    ok "code-server already installed"
  fi

  if ! have code-server; then
    die "code-server is installed but not on PATH."
  fi

  if ! code-server --version >/dev/null 2>&1; then
    die "code-server exists but does not run."
  fi

  ok "code-server is installed and working"
  info "Binary: $(command -v code-server)"
  info "Version: $(code-server --version 2>/dev/null | head -n1 || true)"
}

configure_code_server() {
  print_header "Step 2/4: Configure"

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
  ok "Config written: $CONFIG_FILE"
  info "Bind address: ${BIND_ADDR}:${PORT}"
  info "Password: ${PASSWORD}"
}

create_helpers() {
  print_header "Step 3/4: Helper scripts"

  cat > "$START_SCRIPT" <<EOF
#!/data/data/com.termux/files/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="$CONFIG_FILE"
PORT="$PORT"
BIND_ADDR="$BIND_ADDR"

if [[ ! -f "\$CONFIG_FILE" ]]; then
  echo "❌ Config not found: \$CONFIG_FILE"
  exit 1
fi

LAN_IP=""
if command -v ip >/dev/null 2>&1; then
  LAN_IP="\$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if (\$i=="src") {print \$(i+1); exit}}' || true)"
fi

echo "🚀 Starting code-server..."
echo "   Phone:  http://127.0.0.1:\${PORT}"
if [[ -n "\${LAN_IP:-}" ]]; then
  echo "   Tablet: http://\${LAN_IP}:\${PORT}"
fi
echo
if command -v qrencode >/dev/null 2>&1 && [[ -n "\${LAN_IP:-}" ]]; then
  echo "QR for tablet:"
  qrencode -t ANSIUTF8 "http://\${LAN_IP}:\${PORT}" || true
  echo
fi

if command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock >/dev/null 2>&1 || true
fi

cleanup() {
  if command -v termux-wake-unlock >/dev/null 2>&1; then
    termux-wake-unlock >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

exec code-server --config "\$CONFIG_FILE" --bind-addr "\${BIND_ADDR}:\${PORT}" "\$PWD"
EOF
  chmod +x "$START_SCRIPT"
  ok "Created: $START_SCRIPT"

  cat > "$STOP_SCRIPT" <<'EOF'
#!/data/data/com.termux/files/usr/bin/env bash
set -Eeuo pipefail

if pgrep -af 'code-server' >/dev/null 2>&1; then
  pkill -f 'code-server' && echo "🛑 code-server stopped"
else
  echo "ℹ️  code-server not running"
fi
EOF
  chmod +x "$STOP_SCRIPT"
  ok "Created: $STOP_SCRIPT"

  cat > "$STATUS_SCRIPT" <<EOF
#!/data/data/com.termux/files/usr/bin/env bash
set -Eeuo pipefail

PORT="$PORT"
CONFIG_FILE="$CONFIG_FILE"

if pgrep -af 'code-server' >/dev/null 2>&1; then
  echo "✅ code-server is running"
else
  echo "⚠️  code-server is not running"
fi

if command -v ip >/dev/null 2>&1; then
  LAN_IP="\$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if (\$i=="src") {print \$(i+1); exit}}' || true)"
  if [[ -n "\${LAN_IP:-}" ]]; then
    echo "🌐 Tablet URL: http://\${LAN_IP}:\${PORT}"
  fi
fi

echo "🏠 Phone URL:   http://127.0.0.1:\${PORT}"
echo "⚙️  Config:      \$CONFIG_FILE"

if command -v ss >/dev/null 2>&1; then
  echo
  ss -ltn 2>/dev/null | grep ":${PORT} " || true
fi
EOF
  chmod +x "$STATUS_SCRIPT"
  ok "Created: $STATUS_SCRIPT"

  cat > "$DOCTOR_SCRIPT" <<EOF
#!/data/data/com.termux/files/usr/bin/env bash
set -Eeuo pipefail

PORT="$PORT"
CONFIG_FILE="$CONFIG_FILE"

echo "Doctor report:"
echo

if [[ -n "\${TERMUX_VERSION:-}" ]] || [[ -d "/data/data/com.termux" ]]; then
  echo "✅ Termux detected"
else
  echo "❌ Not running inside Termux"
fi

if command -v code-server >/dev/null 2>&1; then
  echo "✅ code-server: \$(command -v code-server)"
  code-server --version 2>/dev/null | head -n1 || true
else
  echo "❌ code-server missing from PATH"
fi

if [[ -f "\$CONFIG_FILE" ]]; then
  echo "✅ config exists: \$CONFIG_FILE"
else
  echo "❌ config missing: \$CONFIG_FILE"
fi

if command -v ip >/dev/null 2>&1; then
  LAN_IP="\$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if (\$i=="src") {print \$(i+1); exit}}' || true)"
  if [[ -n "\${LAN_IP:-}" ]]; then
    echo "✅ LAN IP detected: \${LAN_IP}"
    echo "   Tablet URL: http://\${LAN_IP}:\${PORT}"
  else
    echo "⚠️  LAN IP not detected"
  fi
fi

if command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | grep -q ":${PORT} "; then
    echo "✅ Port ${PORT} is listening"
  else
    echo "⚠️  Port ${PORT} is not listening"
  fi
fi

echo
echo "If your tablet still cannot open the URL, the problem is usually:"
echo "  - phone and tablet are not on the same Wi-Fi"
echo "  - AP/client isolation is enabled on the router"
echo "  - hotspot blocks device-to-device traffic"
echo "  - battery optimization killed Termux"
EOF
  chmod +x "$DOCTOR_SCRIPT"
  ok "Created: $DOCTOR_SCRIPT"

  if [[ -f "${HOME}/.bashrc" ]] && ! grep -q "alias vs=" "${HOME}/.bashrc"; then
    {
      echo
      echo "# ${APP_NAME}"
      echo "alias vs='bash ${START_SCRIPT}'"
    } >> "${HOME}/.bashrc"
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
      echo "QR code:"
      qrencode -t ANSIUTF8 "http://${lan_ip}:${PORT}" || true
      echo
    fi
  else
    warn "Could not auto-detect a LAN IP."
    echo "Run:"
    echo "  ip addr show wlan0"
    echo
  fi

  echo "Password:"
  echo "  ${PASSWORD}"
  echo
  echo "Commands:"
  echo "  Start:  bash ~/start-vscode"
  echo "  Stop:   bash ~/stop-vscode"
  echo "  Status: bash ~/status-vscode"
  echo "  Doctor: bash ~/doctor-vscode"
  echo
}

launch_server() {
  if port_listening "$PORT"; then
    warn "Something is already listening on port ${PORT}"
    info "Run: bash ~/status-vscode"
    return 0
  fi

  if have termux-wake-lock; then
    termux-wake-lock >/dev/null 2>&1 || true
  fi

  show_access_info
  exec code-server --config "$CONFIG_FILE" --bind-addr "${BIND_ADDR}:${PORT}" "$PWD"
}

stop_server() {
  if pgrep -af 'code-server' >/dev/null 2>&1; then
    pkill -f 'code-server' && ok "Stopped code-server"
  else
    info "code-server is not running"
  fi
}

status_server() {
  bash "$STATUS_SCRIPT"
}

doctor() {
  bash "$DOCTOR_SCRIPT"
}

uninstall_generated() {
  print_header "Uninstall"

  rm -f "$START_SCRIPT" "$STOP_SCRIPT" "$STATUS_SCRIPT" "$DOCTOR_SCRIPT"

  if [[ "$PURGE_CONFIG" -eq 1 ]]; then
    rm -rf "$CONFIG_DIR"
    ok "Removed config directory"
  else
    warn "Kept config directory. Use --purge-config to remove it."
  fi

  ok "Removed generated helper scripts"
}

usage() {
  cat <<EOF
Usage:
  bash setup-code-server-termux.sh [options]

Options:
  --install           Install (default)
  --start             Start code-server
  --stop              Stop code-server
  --status            Show status
  --doctor            Run checks
  --uninstall         Remove generated helper scripts
  --purge-config      Also remove ~/.config/code-server on uninstall
  --port PORT         Default: ${PORT}
  --bind-addr ADDR    Default: ${BIND_ADDR}
  --password PASS     Set a fixed password
  --force-reinstall   Reinstall code-server package
  --no-launch         Install but do not launch immediately
  -h, --help          Show help

Examples:
  PORT=8080 bash setup-code-server-termux.sh
  bash setup-code-server-termux.sh --no-launch
  bash setup-code-server-termux.sh --status
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
      --port)
        PORT="${2:-}"
        [[ -n "$PORT" ]] || die "--port requires a value"
        shift 2
        ;;
      --bind-addr)
        BIND_ADDR="${2:-}"
        [[ -n "$BIND_ADDR" ]] || die "--bind-addr requires a value"
        shift 2
        ;;
      --password)
        PASSWORD="${2:-}"
        [[ -n "$PASSWORD" ]] || die "--password requires a value"
        shift 2
        ;;
      --force-reinstall)
        FORCE_REINSTALL=1
        shift
        ;;
      --no-launch)
        NO_LAUNCH=1
        shift
        ;;
      --purge-config)
        PURGE_CONFIG=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
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
        info "Start later with: bash ~/start-vscode"
      else
        launch_server
      fi
      ;;
    start)
      [[ -f "$CONFIG_FILE" ]] || die "Config not found. Run the installer first."
      launch_server
      ;;
    stop)
      stop_server
      ;;
    status)
      status_server
      ;;
    doctor)
      doctor
      ;;
    uninstall)
      uninstall_generated
      ;;
    *)
      die "Unknown action: $ACTION"
      ;;
  esac
}

main "$@"
