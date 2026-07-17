#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# VS Code: Server One-Command Setup for Termux (Tablet Edition)
# Usage: bash <(curl -sL https://raw.githubusercontent.com/sireenyadav/Vscode-termux/main/vscode-termux.sh)
# ============================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
PORT=8080
BIND_ADDR="127.0.0.1"
PASSWORD="12345678"
CONFIG_DIR="$HOME/.config/code-server"
CONFIG_FILE="$CONFIG_DIR/config.yaml"

# Helper Functions
print_header() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
}

print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error()   { echo -e "${RED}❌ $1${NC}"; }
print_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_step()    { echo -e "${CYAN}→ $1${NC}"; }

check_command() {
    command -v "$1" &> /dev/null
}

# Step 1: System Check
print_header "Step 1/6: System Environment Check"

if [ -z "$TERMUX_VERSION" ] && [ ! -d "/data/data/com.termux" ]; then
    print_warn "Not running in Termux. Some features may not work."
else
    print_success "Termux environment detected"
fi

ARCH=$(uname -m)
print_info "Architecture: $ARCH"

STORAGE=$(df -h $HOME | tail -1 | awk '{print $4}')
print_info "Available storage: $STORAGE"

# Step 2: Update & Install Dependencies
print_header "Step 2/6: Installing Dependencies"

print_step "Updating package lists..."
pkg update -y || { print_error "Failed to update packages"; exit 1; }

DEPS_TO_INSTALL=""
for dep in tur-repo code-server curl; do
    if ! pkg list-installed 2>/dev/null | grep -q "^$dep/"; then
        DEPS_TO_INSTALL="$DEPS_TO_INSTALL $dep"
    fi
done

if [ -n "$DEPS_TO_INSTALL" ]; then
    print_step "Installing: $DEPS_TO_INSTALL"
    pkg install -y $DEPS_TO_INSTALL || { print_error "Failed to install dependencies"; exit 1; }
else
    print_success "All dependencies already installed"
fi

# Step 3: Verify code-server
print_header "Step 3/6: Verifying code-server"

if check_command code-server; then
    CURRENT_VERSION=$(code-server --version 2>/dev/null | head -1)
    print_success "code-server found: $CURRENT_VERSION"
    print_info "Location: $(which code-server)"
else
    print_error "code-server not found after installation"
    print_step "Trying to locate..."
    FOUND=$(find "$PREFIX" -name "code-server" -type f 2>/dev/null | head -1)
    if [ -n "$FOUND" ]; then
        print_success "Found at: $FOUND"
        export PATH="$(dirname "$FOUND"):$PATH"
    else
        print_error "Could not find code-server. Please check tur-repo installation."
        exit 1
    fi
fi

# Step 4: Configure code-server
print_header "Step 4/6: Configuring code-server"

mkdir -p "$CONFIG_DIR"

if [ -f "$CONFIG_FILE" ]; then
    cp "$CONFIG_FILE" "$CONFIG_FILE.backup.$(date +%s)"
    print_info "Old config backed up"
fi

if [ -f "$CONFIG_FILE" ]; then
    EXISTING_PASS=$(grep "password:" "$CONFIG_FILE" | awk '{print $2}' | tr -d '"')
    if [ -n "$EXISTING_PASS" ]; then
        PASSWORD="$EXISTING_PASS"
        print_info "Using existing password from config"
    fi
fi

cat > "$CONFIG_FILE" << EOF
bind-addr: ${BIND_ADDR}:${PORT}
auth: password
password: ${PASSWORD}
cert: false
EOF

print_success "Config written to $CONFIG_FILE"
print_info "Port: $PORT"
print_info "Password: $PASSWORD"

# Step 5: Create Shortcuts
print_header "Step 5/6: Creating Shortcuts"

START_SCRIPT="$HOME/start-vscode"
cat > "$START_SCRIPT" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
CONFIG_FILE="$HOME/.config/code-server/config.yaml"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Config not found. Run the setup script first."
    exit 1
fi

PORT=$(grep "bind-addr:" "$CONFIG_FILE" | cut -d':' -f3 | tr -d ' ')
PASS=$(grep "password:" "$CONFIG_FILE" | awk '{print $2}' | tr -d '"')

echo "🚀 Starting VS Code: Server..."
echo "   URL: http://127.0.0.1:${PORT:-8080}"
echo "   Password: $PASS"
echo ""

code-server --config "$CONFIG_FILE"
EOF
chmod +x "$START_SCRIPT"
print_success "Created: $START_SCRIPT"

if ! grep -q "alias vs=" "$HOME/.bashrc"; then
    echo "" >> "$HOME/.bashrc"
    echo "# VS Code: Server alias" >> "$HOME/.bashrc"
    echo "alias vs='bash $START_SCRIPT'" >> "$HOME/.bashrc"
    print_success "Added 'vs' alias to ~/.bashrc"
fi

STOP_SCRIPT="$HOME/stop-vscode"
cat > "$STOP_SCRIPT" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
pkill -f code-server && echo "🛑 VS Code: Server stopped" || echo "ℹ️  Not running"
EOF
chmod +x "$STOP_SCRIPT"
print_success "Created: $STOP_SCRIPT"

# Step 6: Launch
print_header "Step 6/6: Launching VS Code: Server"

if pgrep -f "code-server" > /dev/null; then
    print_warn "code-server is already running!"
    print_info "Visit: http://${BIND_ADDR}:${PORT}"
    print_info "Password: $PASSWORD"
    echo ""
    print_step "To stop: $STOP_SCRIPT"
    print_step "To restart: $START_SCRIPT"
    exit 0
fi

print_step "Starting server..."
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  🎉 VS Code: Server is starting!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  📱 Open your tablet browser and go to:"
echo -e "  ${CYAN}http://${BIND_ADDR}:${PORT}${NC}"
echo ""
echo -e "  🔑 Password: ${YELLOW}$PASSWORD${NC}"
echo ""
echo -e "  💡 Quick commands:"
echo -e "     Start: ${CYAN}~/start-vscode${NC} or ${CYAN}vs${NC}"
echo -e "     Stop:  ${CYAN}~/stop-vscode${NC}"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""

code-server --config "$CONFIG_FILE"
