#!/usr/bin/env bash

# ==============================================================================
#  macOS Guest Virtual Machine Installation Utility
#  Automates compilation of the Swift virtualization runner, validates the
#  IPSW restore image, and launches the graphical macOS installation wizard.
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

# --- Paths & Configurations ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" # Project root (agy-sandbox)
DOWNLOADS_DIR="${SCRIPT_DIR}/../downloads"
IMAGES_DIR="${SCRIPT_DIR}/../images"
RUNNERS_DIR="${SCRIPT_DIR}/runners"

RUNNER_SRC="${RUNNERS_DIR}/macos_runner.swift"
RUNNER_BIN="${RUNNERS_DIR}/macos_runner"
ENTITLEMENTS_PATH="${RUNNERS_DIR}/entitlements.plist"

IPSW_PATH="${DOWNLOADS_DIR}/macos_restore.ipsw"
DISK_PATH="${IMAGES_DIR}/macos_guest.img"

echo -e "${BOLD}🍏 macOS Guest Virtualization Installer Setup${NC}"
echo "──────────────────────────────────────────────────"

# --- 1. Compile and Sign the Swift Runner ---
if [[ ! -f "${RUNNER_BIN}" || "${RUNNER_SRC}" -nt "${RUNNER_BIN}" ]]; then
    log_info "Compiling Swift macOS runner..."
    swiftc -O "${RUNNER_SRC}" -o "${RUNNER_BIN}"
    log_info "Signing binary with Virtualization entitlement..."
    codesign --force --sign - --entitlements "${ENTITLEMENTS_PATH}" "${RUNNER_BIN}"
    log_success "Swift runner compiled and signed successfully."
else
    log_info "Swift runner binary exists. Verifying/signing virtualization entitlement..."
    codesign --force --sign - --entitlements "${ENTITLEMENTS_PATH}" "${RUNNER_BIN}"
    log_success "Swift runner verified and signed."
fi

# --- 2. IPSW Validation ---
if [[ ! -f "${IPSW_PATH}" ]]; then
    log_error "macOS Restore Image (IPSW) not found at: ${IPSW_PATH}"
    log_error "Please download a macOS restore image first or place it in the downloads folder."
    log_info "Tip: You can use 'sync_downloads.sh' or download one from https://ipsw.me/product/Mac"
    exit 1
fi

# --- 3. Guest Disk Creation ---
if [[ ! -f "${DISK_PATH}" ]]; then
    log_info "Creating a 64GB sparse virtual SSD image..."
    mkdir -p "${IMAGES_DIR}"
    truncate -s 64G "${DISK_PATH}"
    chmod 600 "${DISK_PATH}"
    log_success "Created guest SSD at: ${DISK_PATH}"
else
    log_warning "Guest SSD already exists at: ${DISK_PATH}"
    log_warning "Proceeding will overwrite any partial installation if you run the installer."
fi

# --- 4. Launch the Installer VM ---
log_info "Launching macOS Installation VM..."
echo "   - Virtual CPUs (vCPUs): 4"
echo "   - Memory Allocation:   4096 MB"
echo "   - Restore Image (.ipsw): ${IPSW_PATH}"
echo "   - Guest SSD:           ${DISK_PATH}"
echo "   - Shared Directory:    ${WORKSPACE_DIR}"
echo "──────────────────────────────────────────────────"
log_info "VM booted. Follow the standard Apple macOS installation prompts in the GUI window."

"${RUNNER_BIN}" \
  --ipsw "${IPSW_PATH}" \
  --disk "${DISK_PATH}" \
  --cpus 4 \
  --memory 4096 \
  --shared-dir "${WORKSPACE_DIR}"
