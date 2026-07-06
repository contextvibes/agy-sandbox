#!/usr/bin/env bash

# ==============================================================================
#  NixOS Guest VM Persistent Boot Utility
#  Boots the installed NixOS guest directly from the persistent disk image
#  using direct kernel boot.
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

# --- 0. Profile and Argument Parsing ---
PROFILE_NAME="${1:-antigravity-nixos}"

# Map the profile name to corresponding image filename and boot cache directory
if [[ "${PROFILE_NAME}" == "antigravity-nixos" ]]; then
    DISK_NAME="nixos_guest.img"
    BOOT_SUBDIR="nixos"
else
    # Automatically derive for any other custom profile (e.g. "myproject-nixos" -> "nixos_myproject.img" and "nixos_myproject")
    SUFFIX_STRIP="${PROFILE_NAME%-nixos}"
    DISK_NAME="nixos_${SUFFIX_STRIP}.img"
    BOOT_SUBDIR="nixos_${SUFFIX_STRIP}"
fi

# --- Paths & Configurations ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOWNLOADS_DIR="${SCRIPT_DIR}/../downloads"
IMAGES_DIR="${SCRIPT_DIR}/../images"
BOOT_DIR="${SCRIPT_DIR}/../boot/${BOOT_SUBDIR}"
RUNNERS_DIR="${SCRIPT_DIR}/runners"

RUNNER_BIN="${RUNNERS_DIR}/nixos_runner"
DISK_PATH="${IMAGES_DIR}/${DISK_NAME}"
KERNEL_PATH="${BOOT_DIR}/vmlinux_guest"
INITRD_PATH="${BOOT_DIR}/initrd_guest.img"

echo -e "${BOLD}❄️  NixOS Persistent Boot Utility [Profile: ${PROFILE_NAME}]${NC}"
echo "──────────────────────────────────────────────────"

if [[ ! -f "${DISK_PATH}" ]]; then
    log_error "Persistent disk image not found at: ${DISK_PATH}"
    log_error "Please run './boot_nixos_installer.sh ${PROFILE_NAME}' first to install the system."
    exit 1
fi

# Ensure the compiled runner has the virtualization entitlement signed
ENTITLEMENTS_PATH="${RUNNERS_DIR}/entitlements.plist"
if [[ -f "${RUNNER_BIN}" ]]; then
    log_info "Verifying hypervisor codesignature & entitlements..."
    codesign --force --sign - --entitlements "${ENTITLEMENTS_PATH}" "${RUNNER_BIN}"
fi

# Function to extract guest boot assets from the disk image's EFI partition
extract_guest_assets() {
    log_info "Synchronizing bootloader and guest kernel/initrd from the disk image..."
    
    # Create temp mount directory
    local TEMP_MNT="${SCRIPT_DIR}/mnt_efi_sync"
    mkdir -p "${TEMP_MNT}"
    
    # Attach disk image using hdiutil
    log_info "Attaching disk image to locate boot partition..."
    local ATTACH_OUT
    if ! ATTACH_OUT=$(hdiutil attach -nomount "${DISK_PATH}" 2>&1); then
        log_error "Failed to attach disk image. Is the VM already running or locked?"
        log_error "Details: ${ATTACH_OUT}"
        exit 1
    fi
    
    # Find the EFI partition slice (usually ends with s1)
    local EFI_DEV
    EFI_DEV=$(echo "${ATTACH_OUT}" | grep -E "EFI|boot" | awk '{print $1}' | head -n 1)
    
    if [[ -z "${EFI_DEV}" ]]; then
        # fallback to looking for partition 1 on the disk that was attached
        local DISK_DEV
        DISK_DEV=$(echo "${ATTACH_OUT}" | head -n 1 | awk '{print $1}')
        EFI_DEV="${DISK_DEV}s1"
    fi
    
    log_info "Mounting EFI partition ${EFI_DEV} read-only..."
    if ! diskutil mount readOnly -mountPoint "${TEMP_MNT}" "${EFI_DEV}" >/dev/null 2>&1; then
        log_error "Failed to mount EFI partition ${EFI_DEV}."
        hdiutil detach "$(echo "${EFI_DEV}" | sed 's/s[0-9]*$//')" >/dev/null 2>&1 || true
        rmdir "${TEMP_MNT}" || true
        exit 1
    fi
    
    # Find the latest generation entry file (highest generation number)
    local GENERATION_CONF
    GENERATION_CONF=$(ls -v "${TEMP_MNT}/loader/entries/nixos-generation-"*.conf 2>/dev/null | tail -n 1)

    if [[ -z "${GENERATION_CONF}" || ! -f "${GENERATION_CONF}" ]]; then
        GENERATION_CONF="${TEMP_MNT}/loader/entries/nixos-generation-1.conf"
    fi

    log_info "Using bootloader configuration: $(basename "${GENERATION_CONF}")"
    if [[ ! -f "${GENERATION_CONF}" ]]; then
        log_error "Loader config not found at: ${GENERATION_CONF}"
        diskutil unmount "${TEMP_MNT}" >/dev/null 2>&1 || true
        hdiutil detach "$(echo "${EFI_DEV}" | sed 's/s[0-9]*$//')" >/dev/null 2>&1 || true
        rmdir "${TEMP_MNT}" || true
        exit 1
    fi
    
    # Parse filenames from config
    local KERNEL_FILE_REL
    local INITRD_FILE_REL
    KERNEL_FILE_REL=$(grep -E "^linux[[:space:]]" "${GENERATION_CONF}" | awk '{print $2}')
    INITRD_FILE_REL=$(grep -E "^initrd[[:space:]]" "${GENERATION_CONF}" | awk '{print $2}')
    
    # Resolve absolute paths inside the mount
    local KERNEL_SRC="${TEMP_MNT}/${KERNEL_FILE_REL#/}"
    local INITRD_SRC="${TEMP_MNT}/${INITRD_FILE_REL#/}"
    
    log_info "Copying guest kernel and initrd to host boot cache..."
    mkdir -p "${BOOT_DIR}"
    cp -f "${KERNEL_SRC}" "${KERNEL_PATH}"
    cp -f "${INITRD_SRC}" "${INITRD_PATH}"

    # Dynamically extract and update the system init path
    local EXTRACTED_INIT
    if EXTRACTED_INIT=$(grep -o 'init=/nix/store/[^ ]*/init' "${GENERATION_CONF}" | head -n 1); then
        echo "${EXTRACTED_INIT}" > "${SCRIPT_DIR}/../guest/nixos/init_path_${PROFILE_NAME}.txt"
        echo "${EXTRACTED_INIT}" > "${SCRIPT_DIR}/../guest/nixos/init_path.txt"
        log_success "Dynamically updated boot init path: ${EXTRACTED_INIT}"
    fi
    
    # Unmount and detach
    log_info "Cleaning up disk attachments..."
    diskutil unmount "${TEMP_MNT}" >/dev/null 2>&1 || true
    hdiutil detach "$(echo "${EFI_DEV}" | sed 's/s[0-9]*$//')" >/dev/null 2>&1 || true
    rmdir "${TEMP_MNT}" || true
    
    log_success "Guest kernel and initrd synchronized successfully!"
}

# Perform the dynamic extraction of guest kernel/initrd from disk on every boot
extract_guest_assets

log_info "Booting persistent NixOS Guest VM..."
echo "   - Virtual CPUs (vCPUs): 4"
echo "   - Memory Allocation:   8192 MB"
echo "   - Kernel:              ${KERNEL_PATH}"
echo "   - Initrd:              ${INITRD_PATH}"
echo "   - Disk Image:          ${DISK_PATH} (Mapped to /dev/vda)"
echo "   - Shared Directory:    ${SANDBOX_DIR}"
echo "   - Console Mode:        Native macOS GUI Window"
echo "──────────────────────────────────────────────────"

# Read custom init path if it exists
INIT_PATH="init=/init"
INIT_PATH_FILE="${SCRIPT_DIR}/../guest/nixos/init_path_${PROFILE_NAME}.txt"
if [[ -f "${INIT_PATH_FILE}" ]]; then
    INIT_PATH_CONTENT="$(cat "${INIT_PATH_FILE}" | tr -d '\r\n ')"
    if [[ -n "${INIT_PATH_CONTENT}" ]]; then
        INIT_PATH="${INIT_PATH_CONTENT}"
        log_info "Using dynamic profile init path: ${INIT_PATH}"
    fi
else
    # Fallback to standard init_path.txt
    INIT_PATH_FALLBACK="${SCRIPT_DIR}/../guest/nixos/init_path.txt"
    if [[ -f "${INIT_PATH_FALLBACK}" ]]; then
        INIT_PATH_CONTENT="$(cat "${INIT_PATH_FALLBACK}" | tr -d '\r\n ')"
        if [[ -n "${INIT_PATH_CONTENT}" ]]; then
            INIT_PATH="${INIT_PATH_CONTENT}"
            log_info "Using legacy fallback init path: ${INIT_PATH}"
        fi
    else
        log_warning "No init_path configuration found. Defaulting to init=/init."
    fi
fi

# Define ISO path to satisfy hardware-configuration CD-ROM mount dependency
ISO_PATH="${DOWNLOADS_DIR}/nixos-minimal-26.05.1947.a0374025a863-aarch64-linux.iso"

# Run compiled hypervisor with GUI, graphics acceleration, shared dir, and direct kernel boot pointing to labeled root partition
"${RUNNER_BIN}" \
  --kernel "${KERNEL_PATH}" \
  --initrd "${INITRD_PATH}" \
  --disk "${DISK_PATH}" \
  --disk "${ISO_PATH}" \
  --cpus 4 \
  --memory 8192 \
  --cmdline "${INIT_PATH} root=fstab console=hvc0 rw" \
  --shared-dir "${SANDBOX_DIR}" \
  --gui
