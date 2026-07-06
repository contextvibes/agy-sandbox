#!/usr/bin/env bash

# ==============================================================================
#  NixOS Guest App Launcher
#  Runs inside the NixOS XFCE environment to mount host files and launch
#  our target developer tools.
# ==============================================================================

set -euo pipefail

# --- Color Formatting ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

SHARED_MOUNT="/home/nixos/shared"

echo -e "${BOLD}🚀 NixOS Guest Developer Environment Launcher${NC}"
echo "──────────────────────────────────────────────────"

# 1. Mount Host Shared Folder
if mountpoint -q "${SHARED_MOUNT}" 2>/dev/null; then
    log_info "Host workspace already mounted at ${SHARED_MOUNT}"
else
    log_info "Mounting host shared workspace to ${SHARED_MOUNT}..."
    sudo mkdir -p "${SHARED_MOUNT}"
    sudo mount -t virtiofs shared "${SHARED_MOUNT}"
    log_success "Host workspace successfully mounted."
fi

# 2. Launch or Install Antigravity IDE
IDE_LAUNCHED=false
if [[ -x "/home/nixos/Antigravity IDE/antigravity-ide" ]]; then
    log_info "Launching local Antigravity IDE in the background..."
    "/home/nixos/Antigravity IDE/antigravity-ide" --no-sandbox --disable-gpu >/dev/null 2>&1 &
    IDE_LAUNCHED=true
elif command -v antigravity-ide >/dev/null 2>&1; then
    log_info "Launching system-wide Antigravity IDE in the background..."
    antigravity-ide --no-sandbox --disable-gpu >/dev/null 2>&1 &
    IDE_LAUNCHED=true
else
    log_warning "Antigravity IDE binary not found."
    echo -e "${YELLOW}[ACTION]${NC} Would you like to install Antigravity IDE automatically now? (y/n)"
    # Read response with 10s timeout, defaulting to 'y' in non-interactive environments
    if read -t 10 -r -n 1 RESP 2>/dev/null; then
        echo ""
    else
        RESP="y"
        log_info "Non-interactive shell or timeout; auto-installing..."
    fi
    
    if [[ "${RESP}" =~ ^[Yy]$ ]]; then
        log_info "Running native Antigravity dynamic installer..."
        LOCAL_INSTALLER_DIR="$(dirname "${BASH_SOURCE[0]:-$0}")"
        LOCAL_INSTALLER="${LOCAL_INSTALLER_DIR}/install_antigravity.sh"
        if [[ ! -f "${LOCAL_INSTALLER}" ]]; then
            LOCAL_INSTALLER="/home/nixos/shared/guest/nixos/install_antigravity.sh"
        fi
        
        if [[ -f "${LOCAL_INSTALLER}" ]]; then
            log_info "Using local installer script: ${LOCAL_INSTALLER}"
            sudo chmod +x "${LOCAL_INSTALLER}" 2>/dev/null || true
            if sudo bash "${LOCAL_INSTALLER}" --all; then
                log_success "Antigravity IDE successfully installed!"
                # Try launching again
                if [[ -x "/home/nixos/Antigravity IDE/antigravity-ide" ]]; then
                    log_info "Launching Antigravity IDE..."
                    "/home/nixos/Antigravity IDE/antigravity-ide" --no-sandbox --disable-gpu >/dev/null 2>&1 &
                    IDE_LAUNCHED=true
                elif command -v antigravity-ide >/dev/null 2>&1; then
                    log_info "Launching Antigravity IDE..."
                    antigravity-ide --no-sandbox --disable-gpu >/dev/null 2>&1 &
                    IDE_LAUNCHED=true
                fi
            else
                log_error "Installation failed. Falling back to Chromium browser..."
                chromium --no-sandbox >/dev/null 2>&1 &
            fi
        else
            log_error "Native installer script not found at ${LOCAL_INSTALLER}."
            log_info "Falling back to Chromium browser..."
            chromium --no-sandbox >/dev/null 2>&1 &
        fi
    else
        log_info "Skipping installation. Launching Google Chrome (Chromium) instead..."
        chromium --no-sandbox >/dev/null 2>&1 &
    fi
fi

echo "──────────────────────────────────────────────────"
log_success "Developer Environment initialized!"
echo "   - Host files mounted at: ${SHARED_MOUNT}"
if [ "$IDE_LAUNCHED" = true ]; then
    echo "   - Antigravity IDE launched."
else
    echo "   - Chrome/Chromium browser launched (fallback)."
fi
echo "   - Standard Electron libraries (GTK3, NSS, etc.) are ready."
