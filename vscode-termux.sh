#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# code-server for Termux (tablet-friendly)
# - Installs from the official Termux tur repository
# - Avoids npm on Termux (native module build issues)
# - Idempotent install/repair/start/stop/status/uninstall
# - Safe config generation with password preservation
# ============================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_NAME="code-server-termux"
PORT="${PORT:-8080}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
PASSWORD="${PASSWORD:-}"
LAUNCH_AFTER_INSTALL=1
FORCE_REINSTALL=0
PURGE_CONFIG=0
DOCKER_MODE=0

CONFIG_DIR="${HOME}/.config/code-server"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
START_SCRIPT="${HOME}/start-vscode"
STOP_SCRIPT="${HOME}/stop-vscode"
STATUS_SCRIPT="${HOME}/status-vscode"
DOCTOR_SCRIPT="${HOME}/doctor-vscode"
LOG_DIR="${HOME}/.local/share/code-server/coder-logs"
STATE_DIR="${HOME}/.local/state/${APP_NAME}"
LAST_ERROR_LOG="${STATE_DIR}/last-error.log"

TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

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

die() {
  err "$*"
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

is_termux() {
  [[ -n "${TERMUX_VERSION:-}" ]] || [[ -d "/data/data/com.termux" ]]
}

timestamp() {
  date +"%Y%m%d-%H%M%S"
}

backup_file_if_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local backup="${file}.backup.$(timestamp)"
    cp -f "$file" "$backup"
    info "Backed up $(basename "$file") -> $(basename "$backup")"
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

ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$STATE_DIR"
  mkdir -p "$LOG_DIR" || true
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

ensure_bashrc_alias() {
  local marker_start="# >>> ${APP_NAME} >>>"
  local marker_end="# <<< ${APP_NAME} <<<"
  local block
  block="$(cat <<EOF
${marker_start}
function vs() { bash "${START_SCRIPT}" "\$@"; }
${marker_end}
EOF
)"
  if [[ -f "${HOME}/.bashrc" ]]; then
    if ! grep -Fq "$marker_start" "${HOME}/.bashrc"; then
      {
        echo
        echo "$block"
      } >> "${HOME}/.bashrc"
      ok "Added 'vs' helper to ~/.bashrc"
    fi
  fi
}

install_termux_deps() {
  print_header "Step 1/4: Termux setup"

  if ! is_termux; then
    die "This installer is for Termux only."
  fi

  info "Termux detected"
  info "Architecture: $(uname -m)"
  info "Prefix: ${TERMUX_PREFIX}"

  if ! have pkg; then
    die "Termux pkg tool not found."
  fi

  info "Updating package lists..."
  if ! pkg update -y; then
    die "pkg update failed. Fix your Termux repositories first, then rerun."
  fi

  if ! dpkg -s tur-repo >/dev/null 2>&1; then
    info "Installing tur-repo..."
    if ! pkg install -y tur-repo; then
      die "Failed to install tur-repo. Try 'termux-change-repo' and rerun."
    fi
  else
    ok "tur-repo already installed"
  fi

  if [[ "$FORCE_REINSTALL" -eq 1 ]]; then
    warn "Forcing reinstall of code-server package..."
    pkg uninstall -y code-server >/dev/null 2>&1 || true
  fi

  if ! dpkg -s code-server >/dev/null 2>&1; then
    info "Installing code-server from Termux repositories..."
    if ! pkg install -y code-server; then
      err "code-server package install failed."
      echo
      echo "Available matches:"
      pkg search code-server || true
      echo
      die "Stop here. This script will not fall back to npm on Termux because the native build path is what failed in your log."
    fi
  else
    ok "code-server package already installed"
  fi

  if ! have code-server; then
    die "code-server is installed but not on PATH."
  fi

  if ! code-server --version >/dev/null 2>&1; then
    die "code-server exists but does not run correctly."
  fi

  ok "code-server is installed and working"
  info "Binary: $(command -v code-server)"
  info "Version: $(code-server --version 2>/dev/null | head -n1 || true)"
}

configure_code_server() {
  print_header "Step 2/4: Configure code-server"

  ensure_dirs

  local existing_pass
  existing_pass="$(get_existing_password || true)"

  if [[ -n "${PASSWORD}" ]]; then
    info "Using password supplied via environment/flag"
  elif [[ -n "${existing_pass}" ]]; then
    PASSWORD="$existing_pass"
    info "Preserving existing password from config"
  else
    PASSWORD="$(generate_password)"
    info "Generated a new password"
  fi

  write_config "$PASSWORD"
  ok "Config written: $CONFIG_FILE"
  info "Bind address: ${BIND_ADDR}:${PORT}"
  info "Password: ${PASSWORD}"
}

create_helper_scripts() {
  print_header "Step 3/4: Create shortcuts"

  cat > "$START_SCRIPT" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
CONFIG_FILE="$CONFIG_FILE"
DEFAULT_WORKSPACE="\${1:-\$PWD}"

if [[ ! -f "\$CONFIG_FILE" ]]; then
  echo "❌ Config not found: \$CONFIG_FILE"
  exit 1
fi

echo "🚀 Starting code-server..."
echo "   URL: http://${BIND_ADDR}:${PORT}"
echo "   Config: \$CONFIG_FILE"
echo

exec code-server --config "\$CONFIG_FILE" "\$DEFAULT_WORKSPACE"
EOF
  chmod +x "$START_SCRIPT"
  ok "Created: $START_SCRIPT"

  cat > "$STOP_SCRIPT" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
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
#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

echo "code-server status:"
if pgrep -af 'code-server' >/dev/null 2>&1; then
  echo "  Running"
  echo "  URL: http://${BIND_ADDR}:${PORT}"
else
  echo "  Not running"
fi

if [[ -f "$CONFIG_FILE" ]]; then
  echo "  Config: $CONFIG_FILE"
fi
EOF
  chmod +x "$STATUS_SCRIPT"
  ok "Created: $STATUS_SCRIPT"

  cat > "$DOCTOR_SCRIPT" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

echo "Doctor check:"
echo

if [[ -n "${TERMUX_VERSION:-}" ]] || [[ -d "/data/data/com.termux" ]]; then
  echo "✅ Termux detected"
else
  echo "❌ Not in Termux"
fi

if command -v code-server >/dev/null 2>&1; then
  echo "✅ code-server found: $(command -v code-server)"
  if code-server --version >/dev/null 2>&1; then
    echo "✅ code-server runs"
  else
    echo "❌ code-server binary exists but fails to run"
  fi
else
  echo "❌ code-server not on PATH"
fi

if [[ -f "$HOME/.config/code-server/config.yaml" ]]; then
  echo "✅ config exists: $HOME/.config/code-server/config.yaml"
else
  echo "❌ config missing"
fi

if [[ -d "$HOME/.local/share/code-server/coder-logs" ]]; then
  echo "✅ log directory exists"
else
  echo "ℹ️  log directory not found yet"
fi
EOF
  chmod +x "$DOCTOR_SCRIPT"
  ok "Created: $DOCTOR_SCRIPT"

  ensure_bashrc_alias
}

show_hints() {
  print_header "Step 4/4: Launch"

  echo "📱 Open your browser and go to:"
  echo "   http://${BIND_ADDR}:${PORT}"
  echo
  echo "🔑 Password:"
  echo "   ${PASSWORD}"
  echo
  echo "💡 Commands:"
  echo "   Start:   bash ~/start-vscode"
  echo "   Stop:    bash ~/stop-vscode"
  echo "   Status:  bash ~/status-vscode"
  echo "   Doctor:  bash ~/doctor-vscode"
  echo
}

tail_logs_if_any() {
  if [[ -d "$LOG_DIR" ]]; then
    local latest
    latest="$(find "$LOG_DIR" -type f 2>/dev/null | sort | tail -n 1 || true)"
    if [[ -n "${latest:-}" && -f "$latest" ]]; then
      echo
      info "Last log file: $latest"
      tail -n 40 "$latest" || true
    fi
  fi
}

launch_now() {
  if pgrep -af 'code-server' >/dev/null 2>&1; then
    warn "code-server is already running"
    info "Visit: http://${BIND_ADDR}:${PORT}"
    return 0
  fi

  show_hints
  exec code-server --config "$CONFIG_FILE" "$PWD"
}

stop_server() {
  if pgrep -af 'code-server' >/dev/null 2>&1; then
    pkill -f 'code-server' && ok "Stopped code-server"
  else
    info "code-server is not running"
  fi
}

status_server() {
  if pgrep -af 'code-server' >/dev/null 2>&1; then
    ok "code-server is running"
    info "URL: http://${BIND_ADDR}:${PORT}"
  else
    warn "code-server is not running"
  fi
}

doctor() {
  echo "Doctor:"
  echo
  if is_termux; then
    ok "Termux detected"
  else
    warn "Not running inside Termux"
  fi
  echo "code-server: $(command -v code-server 2>/dev/null || echo 'missing')"
  if have code-server; then
    code-server --version 2>/dev/null | head -n1 || true
  fi
  echo "config: ${CONFIG_FILE}"
  [[ -f "$CONFIG_FILE" ]] && ok "present" || warn "missing"
  echo "logs: ${LOG_DIR}"
  [[ -d "$LOG_DIR" ]] && ok "present" || warn "not created yet"
  echo
  tail_logs_if_any
}

uninstall_generated_files() {
  print_header "Uninstall generated files"

  rm -f "$START_SCRIPT" "$STOP_SCRIPT" "$STATUS_SCRIPT" "$DOCTOR_SCRIPT"
  rm -f "${HOME}/.bashrc.tmp" >/dev/null 2>&1 || true

  if [[ "$PURGE_CONFIG" -eq 1 ]]; then
    rm -rf "$CONFIG_DIR"
    ok "Removed config directory"
  else
    warn "Kept config directory. Use --purge-config to remove it."
  fi

  ok "Removed helper scripts"
}

usage() {
  cat <<EOF
Usage:
  bash setup-code-server-termux.sh [options]

Options:
  --port PORT            Default: ${PORT}
  --bind-addr ADDR       Default: ${BIND_ADDR}
  --password PASS        Use a fixed password
  --no-launch            Install and configure, but do not start server
  --force-reinstall      Reinstall code-server package
  --purge-config         Uninstall config files when using --uninstall
  --install              Install mode (default)
  --start                Start code-server using existing config
  --stop                 Stop running code-server
  --status               Show running status
  --doctor               Run checks
  --uninstall            Remove generated scripts/config
  -h, --help             Show this help

Examples:
  bash <(curl -fsSL https://raw.githubusercontent.com/yourname/yourrepo/main/setup.sh)
  PORT=9090 bash setup-code-server-termux.sh
  bash setup-code-server-termux.sh --no-launch
EOF
}

parse_args() {
  local cmd="install"

  while [[ $# -gt 0 ]]; do
    case "$1" in
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
      --no-launch)
        LAUNCH_AFTER_INSTALL=0
        shift
        ;;
      --force-reinstall)
        FORCE_REINSTALL=1
        shift
        ;;
      --purge-config)
        PURGE_CONFIG=1
        shift
        ;;
      --install)
        cmd="install"
        shift
        ;;
      --start)
        cmd="start"
        shift
        ;;
      --stop)
        cmd="stop"
        shift
        ;;
      --status)
        cmd="status"
        shift
        ;;
      --doctor)
        cmd="doctor"
        shift
        ;;
      --uninstall)
        cmd="uninstall"
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

  echo "$cmd"
}

main() {
  local cmd
  cmd="$(parse_args "$@")"

  case "$cmd" in
    install)
      install_termux_deps
      configure_code_server
      create_helper_scripts
      if [[ "$LAUNCH_AFTER_INSTALL" -eq 1 ]]; then
        launch_now
      else
        ok "Install complete"
        info "Start later with: bash ~/start-vscode"
      fi
      ;;
    start)
      if [[ ! -f "$CONFIG_FILE" ]]; then
        die "Config not found. Run the installer first."
      fi
      exec code-server --config "$CONFIG_FILE" "$PWD"
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
      uninstall_generated_files
      ;;
    *)
      die "Unknown command"
      ;;
  esac
}

trap 'rc=$?; echo; err "Failed at line ${LINENO} with exit code ${rc}"; tail_logs_if_any; exit "$rc"' ERR
main "$@"
