#!/usr/bin/env bash
# ==============================================================================
#  🍏 macOS Guest VM Boot Utility
#  Unified bootloader for macOS guest VMs with optional per-customer isolation.
#
#  Modes:
#    boot_macos.sh                              Boot base image directly
#    boot_macos.sh --customer acme              Stateful per-customer clone
#    boot_macos.sh --customer acme --stateless  Ephemeral session (OS discarded)
# ==============================================================================

set -euo pipefail

# --- Color Formatting ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGES_DIR="${WORKSPACE_DIR}/images"
RUNNERS_DIR="${SCRIPT_DIR}/runners"

RUNNER_SRC="${RUNNERS_DIR}/macos_runner.swift"
RUNNER_BIN="${RUNNERS_DIR}/macos_runner"
ENTITLEMENTS="${RUNNERS_DIR}/entitlements.plist"

BASE_IMAGE="${IMAGES_DIR}/macos_shared.img"
LEGACY_IMAGE="${IMAGES_DIR}/macos_shared_legacy.img"
LEGACY_GUEST_IMAGE="${IMAGES_DIR}/macos_guest.img"

# --- Help ---
show_help() {
    echo "Usage: $(basename "$0") [--customer <name>] [--stateless] [--retina]"
    echo ""
    echo "Modes:"
    echo "  (no flags)                    Boot the base macOS image directly"
    echo "  --customer <name>             Stateful per-customer APFS clone (persistent)"
    echo "  --customer <name> --stateless Ephemeral session (OS changes discarded on shutdown)"
    echo ""
    echo "Options:"
    echo "  --customer, -c <name>   Customer short name (e.g. 'acme', 'example-corp')"
    echo "  --stateless             Destroy OS changes on shutdown (requires --customer)"
    echo "  --retina                Retina High-DPI mode (220 PPI)"
    echo "  -h, --help              Show this help message"
}

# --- Parse Arguments ---
CUSTOMER=""
STATELESS=false
PPI=110

while [[ $# -gt 0 ]]; do
    case "$1" in
        --customer|-c) CUSTOMER="$2"; shift 2 ;;
        --stateless)   STATELESS=true; shift ;;
        --retina)      PPI=220; shift ;;
        -h|--help)     show_help; exit 0 ;;
        *)             log_error "Unknown argument: $1"; show_help; exit 1 ;;
    esac
done

if [[ "${STATELESS}" == "true" && -z "${CUSTOMER}" ]]; then
    log_error "--stateless requires --customer <name>"
    show_help
    exit 1
fi

if [[ -n "${CUSTOMER}" && ! "${CUSTOMER}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_error "Invalid customer name '${CUSTOMER}'. Only alphanumeric, dashes, and underscores are allowed."
    exit 1
fi

# --- Determine Mode & Paths ---
if [[ -z "${CUSTOMER}" ]]; then
    MODE="direct"
    DISK_IMAGE="${BASE_IMAGE}"
    SHARED_DIR="${WORKSPACE_DIR}"
elif [[ "${STATELESS}" == "true" ]]; then
    MODE="stateless"
    DISK_IMAGE="${IMAGES_DIR}/macos_session_${CUSTOMER}.img"
    SHARED_DIR="/Users/Shared/${CUSTOMER}"
else
    MODE="stateful"
    DISK_IMAGE="${IMAGES_DIR}/macos_${CUSTOMER}.img"
    SHARED_DIR="/Users/Shared/${CUSTOMER}"
fi

# --- Header ---
case "${MODE}" in
    direct)    echo -e "${BOLD}🍏 macOS Guest VM${NC}" ;;
    stateful)  echo -e "${BOLD}🍏 macOS Guest VM — Stateful (${CUSTOMER})${NC}" ;;
    stateless) echo -e "${BOLD}🍏 macOS Guest VM — Stateless (${CUSTOMER})${NC}" ;;
esac
echo "──────────────────────────────────────────────────"

# --- Helper: APFS Copy-on-Write Clone ---
clone_image() {
    local src="$1"
    local dst="$2"

    if cp -c "${src}" "${dst}" 2>/dev/null; then
        log_success "Cloned using native APFS copy-on-write (-c)."
    else
        rm -f "${dst}"
        if cp --reflink=auto "${src}" "${dst}" 2>/dev/null; then
            log_success "Cloned using GNU coreutils reflink (--reflink=auto)."
        else
            rm -f "${dst}"
            log_warning "APFS copy-on-write failed. Falling back to standard copy."
            log_warning "This will be slow and duplicate the full disk image."
            if ! cp "${src}" "${dst}"; then
                rm -f "${dst}"
                log_error "Failed to clone image."
                exit 1
            fi
        fi
    fi
}

# --- Helper: Copy VM Metadata Files ---
copy_metadata() {
    local src="$1"
    local dst="$2"

    for ext in aux id hw mac; do
        if [[ -f "${src}.${ext}" ]]; then
            cp -f "${src}.${ext}" "${dst}.${ext}"
        fi
    done
}

# --- 1. Compile and Sign Runner ---
if [[ ! -f "${RUNNER_BIN}" || "${RUNNER_SRC}" -nt "${RUNNER_BIN}" ]]; then
    log_info "Compiling Swift macOS runner..."
    swiftc -O -parse-as-library "${RUNNER_SRC}" -o "${RUNNER_BIN}"
    codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${RUNNER_BIN}"
    log_success "Compiled and signed."
else
    codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${RUNNER_BIN}"
fi

# --- 2. Base Image Verification & Legacy Self-Healing ---
if [[ ! -f "${BASE_IMAGE}" ]]; then
    if [[ -f "${LEGACY_IMAGE}" ]]; then
        log_warning "Promoting legacy image to ${BASE_IMAGE}..."
        mv "${LEGACY_IMAGE}" "${BASE_IMAGE}"
        for ext in aux aux.bak id id.bak hw hw.bak mac; do
            if [[ -f "${LEGACY_IMAGE}.${ext}" ]]; then
                mv "${LEGACY_IMAGE}.${ext}" "${BASE_IMAGE}.${ext}"
            fi
        done
        log_success "Legacy image promoted."
    elif [[ -f "${LEGACY_GUEST_IMAGE}" && "${MODE}" == "direct" ]]; then
        # Support old macos_guest.img name for direct boot
        log_warning "Using legacy image name: ${LEGACY_GUEST_IMAGE}"
        DISK_IMAGE="${LEGACY_GUEST_IMAGE}"
    elif [[ "${MODE}" != "direct" ]]; then
        log_error "No base image found at: ${BASE_IMAGE}"
        log_error "Run './host/boot_macos_installer.sh' first to install macOS."
        exit 1
    fi
fi

if [[ ! -f "${DISK_IMAGE}" && "${MODE}" == "direct" ]]; then
    log_error "Disk image not found at: ${DISK_IMAGE}"
    log_error "Run './host/boot_macos_installer.sh' first to install macOS."
    exit 1
fi

# --- 3. Customer Setup (customer modes only) ---
if [[ -n "${CUSTOMER}" && ! -d "${SHARED_DIR}" ]]; then
    log_info "Creating customer workspace at: ${SHARED_DIR}..."
    mkdir -p "${SHARED_DIR}"
    if [[ "${MODE}" == "stateful" ]]; then
        "${SCRIPT_DIR}/isolate_home_setup.sh" "${SHARED_DIR}" "Stateful VM - ${CUSTOMER}"
    else
        "${SCRIPT_DIR}/isolate_home_setup.sh" "${SHARED_DIR}" "Stateless VM - ${CUSTOMER}"
    fi
fi

# --- 4. Create Clone (if needed) ---
if [[ "${MODE}" == "stateful" && ! -f "${DISK_IMAGE}" ]]; then
    log_info "Creating persistent clone for '${CUSTOMER}'..."
    clone_image "${BASE_IMAGE}" "${DISK_IMAGE}"
    copy_metadata "${BASE_IMAGE}" "${DISK_IMAGE}"
    log_success "Persistent clone ready."
fi

if [[ "${MODE}" == "stateless" ]]; then
    log_info "Creating ephemeral session clone for '${CUSTOMER}'..."
    rm -f "${DISK_IMAGE}"
    clone_image "${BASE_IMAGE}" "${DISK_IMAGE}"
    copy_metadata "${BASE_IMAGE}" "${DISK_IMAGE}"

    # Trap: destroy session image on exit
    cleanup_session() {
        echo -e "\n──────────────────────────────────────────────────"
        log_info "Session ended. Destroying ephemeral OS state..."
        rm -f "${DISK_IMAGE}" "${DISK_IMAGE}.aux" "${DISK_IMAGE}.id" "${DISK_IMAGE}.hw"
        log_success "OS changes discarded. Customer data preserved."
    }
    trap cleanup_session EXIT INT TERM
fi

# --- 5. Launch VM ---
# Customer mode gets more resources than direct mode
if [[ -n "${CUSTOMER}" ]]; then
    CPUS=6
    MEMORY=16384
else
    CPUS=4
    MEMORY=4096
fi

log_info "Booting macOS Guest VM..."
echo "   - Disk:       ${DISK_IMAGE}"
echo "   - Shared:     ${SHARED_DIR}"
echo "   - Resources:  ${CPUS} CPUs, $((MEMORY / 1024)) GB RAM"
echo "   - Display:    1280×800 @ ${PPI} PPI"
if [[ -n "${CUSTOMER}" ]]; then
    echo "   - Mode:       ${MODE}"
fi
echo "──────────────────────────────────────────────────"

# Session logging
mkdir -p "${HOME}/.config/antigravity"
echo "$(date '+%Y-%m-%d %H:%M:%S') - START - ${MODE} - ${CUSTOMER:-direct}" >> "${HOME}/.config/antigravity/vm_sessions.log"

"${RUNNER_BIN}" \
  --disk "${DISK_IMAGE}" \
  --cpus "${CPUS}" \
  --memory "${MEMORY}" \
  --width 1280 \
  --height 800 \
  --ppi "${PPI}" \
  --shared-dir "${SHARED_DIR}"

echo "$(date '+%Y-%m-%d %H:%M:%S') - END - ${MODE} - ${CUSTOMER:-direct} - Exit: $?" >> "${HOME}/.config/antigravity/vm_sessions.log"
