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
INSTALL_DIR="$HOME/.local/lib/code-server"
BIN_DIR="$HOME/.local/bin"
TEMP_DIR="$HOME/.tmp"

# code-server version to install
CODE_SERVER_VERSION="4.98.2"

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

# Step 2: Install Dependencies
print_header "Step 2/6: Installing Dependencies"

print_step "Updating package lists..."
pkg update -y || { print_error "Failed to update packages"; exit 1; }

DEPS_TO_INSTALL=""
for dep in curl; do
    if ! check_command "$dep"; then
        DEPS_TO_INSTALL="$DEPS_TO_INSTALL $dep"
    fi
done

if [ -n "$DEPS_TO_INSTALL" ]; then
    print_step "Installing: $DEPS_TO_INSTALL"
    pkg install -y $DEPS_TO_INSTALL || { print_error "Failed to install dependencies"; exit 1; }
else
    print_success "All dependencies already installed"
fi

# Step 3: Download & Install code-server (Standalone Binary)
print_header "Step 3/6: Installing code-server (Standalone)"

if check_command code-server; then
    CURRENT_VERSION=$(code-server --version 2>/dev/null | head -1)
    print_success "code-server already installed: $CURRENT_VERSION"
    print_info "Location: $(which code-server)"
else
    print_step "Downloading code-server v${CODE_SERVER_VERSION} for ${ARCH}..."
    
    # Determine download URL based on architecture
    case "$ARCH" in
        aarch64|arm64)
            ARCHIVE_NAME="code-server-${CODE_SERVER_VERSION}-linux-arm64"
            ;;
        armv7l|armhf)
            ARCHIVE_NAME="code-server-${CODE_SERVER_VERSION}-linux-armv7l"
            ;;
        x86_64|amd64)
            ARCHIVE_NAME="code-server-${CODE_SERVER_VERSION}-linux-amd64"
            ;;
        *)
            print_error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
    
    DOWNLOAD_URL="https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/${ARCHIVE_NAME}.tar.gz"
    
    print_info "Download URL: $DOWNLOAD_URL"
    
    # Create directories
    mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$TEMP_DIR"
    
    # Download using curl (follows redirects)
    cd "$HOME"
    TAR_FILE="${ARCHIVE_NAME}.tar.gz"
    
    if ! curl -fsSL -o "$TAR_FILE" "$DOWNLOAD_URL"; then
        print_error "Download failed. Trying fallback version..."
        CODE_SERVER_VERSION="4.96.4"
        ARCHIVE_NAME="code-server-${CODE_SERVER_VERSION}-linux-arm64"
        DOWNLOAD_URL="https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/${ARCHIVE_NAME}.tar.gz"
        
        if ! curl -fsSL -o "$TAR_FILE" "$DOWNLOAD_URL"; then
            print_error "Fallback download also failed"
            exit 1
        fi
    fi
    
    print_success "Downloaded: $(ls -lh "$TAR_FILE" | awk '{print $5}')"
    print_step "Extracting (this may take a moment)..."
    
    # Clean up old install
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    
    # Extract to temp first, then copy with -L (follow symlinks, copy files instead of links)
    EXTRACT_TEMP="$TEMP_DIR/codeserver-extract-$$"
    rm -rf "$EXTRACT_TEMP"
    mkdir -p "$EXTRACT_TEMP"
    
    print_step "Extracting tarball..."
    tar -xzf "$TAR_FILE" -C "$EXTRACT_TEMP" --strip-components=1 2>/dev/null || {
        print_error "tar extraction failed"
        rm -f "$TAR_FILE"
        exit 1
    }
    
    print_step "Copying files (resolving links)..."
    # Use cp -rL to copy everything, dereferencing symlinks and hard links
    cp -rL "$EXTRACT_TEMP"/* "$INSTALL_DIR/" 2>/dev/null || {
        print_error "Copy failed"
        rm -rf "$EXTRACT_TEMP" "$TAR_FILE"
        exit 1
    }
    
    rm -rf "$EXTRACT_TEMP"
    rm -f "$TAR_FILE"
    
    # Verify node binary exists
    if [ ! -f "$INSTALL_DIR/lib/node" ]; then
        print_warn "Bundled node not found, checking for system node..."
        if check_command node; then
            print_info "Using system node: $(which node)"
            # Create a wrapper script
            cat > "$INSTALL_DIR/bin/code-server" << EOF
#!/data/data/com.termux/files/usr/bin/bash
exec $(which node) "$INSTALL_DIR/out/node/entry.js" "\$@"
EOF
            chmod +x "$INSTALL_DIR/bin/code-server"
        else
            print_error "No node runtime found. Please install nodejs-lts: pkg install nodejs-lts"
            exit 1
        fi
    fi
    
    # Create symlink
    ln -sf "$INSTALL_DIR/bin/code-server" "$BIN_DIR/code-server"
    
    # Add to PATH
    if ! echo "$PATH" | grep -q "$BIN_DIR"; then
        echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$HOME/.bashrc"
        export PATH="$BIN_DIR:$PATH"
    fi
    
    if check_command code-server; then
        print_success "code-server installed successfully!"
        code-server --version | head -1
    else
        print_error "Installation failed - binary not found"
        print_info "Checking $INSTALL_DIR/bin/"
        ls -la "$INSTALL_DIR/bin/" 2>/dev/null || print_error "Directory not found"
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
BIN_DIR="$HOME/.local/bin"
export PATH="$BIN_DIR:$PATH"

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
