#!/usr/bin/env bash

# ==============================================================================
#  NixOS Virtual Machine Boot & Orchestration Utility
#  Automates compilation of the Swift virtualization runner, performs
#  dynamic kernel/initrd extraction from the ISO, and boots the guest VM.
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

# --- Clean Exit/Error/Signal Trap ---
MOUNT_PATH=""
cleanup_done=0

cleanup() {
    if (( cleanup_done )); then
        return
    fi
    cleanup_done=1
    if [[ -n "${MOUNT_PATH:-}" ]]; then
        log_info "Cleaning up: unmounting ISO from ${MOUNT_PATH}..."
        hdiutil unmount "${MOUNT_PATH}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

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

RUNNER_SRC="${RUNNERS_DIR}/nixos_runner.swift"
RUNNER_BIN="${RUNNERS_DIR}/nixos_runner"
ENTITLEMENTS_PATH="${RUNNERS_DIR}/entitlements.plist"

ISO_PATH="${DOWNLOADS_DIR}/nixos-minimal-26.05.1947.a0374025a863-aarch64-linux.iso"
DISK_PATH="${IMAGES_DIR}/${DISK_NAME}"
KERNEL_PATH="${BOOT_DIR}/vmlinux"
INITRD_PATH="${BOOT_DIR}/initrd.img"
INIT_PATH_FILE="${BOOT_DIR}/init_path.txt"

echo -e "${BOLD}❄️  NixOS Apple Silicon Setup [Profile: ${PROFILE_NAME}]${NC}"
echo "──────────────────────────────────────────────────"

# --- 1. Compile and Sign the Swift Runner ---
if [[ ! -f "${RUNNER_BIN}" || "${RUNNER_SRC}" -nt "${RUNNER_BIN}" ]]; then
    log_info "Compiling Swift NixOS runner..."
    swiftc -O "${RUNNER_SRC}" -o "${RUNNER_BIN}"
    log_info "Signing binary with Virtualization entitlement..."
    codesign --force --sign - --entitlements "${ENTITLEMENTS_PATH}" "${RUNNER_BIN}"
    log_success "Swift runner compiled and signed successfully."
else
    # Always ensure the existing binary is signed just in case
    log_info "Swift runner binary exists. Verifying/signing virtualization entitlement..."
    codesign --force --sign - --entitlements "${ENTITLEMENTS_PATH}" "${RUNNER_BIN}"
    log_success "Swift runner verified and signed."
fi


# --- 2. Dynamic Kernel & Initrd Extraction ---
mkdir -p "${BOOT_DIR}"

if [[ ! -f "${KERNEL_PATH}" || ! -f "${INITRD_PATH}" || ! -f "${INIT_PATH_FILE}" ]]; then
    log_warning "Boot assets (kernel/initrd/init_path) not fully found locally. Initiating extraction..."
    
    if [[ ! -f "${ISO_PATH}" ]]; then
        log_error "NixOS ISO not found at: ${ISO_PATH}"
        log_error "Please run 'sync_downloads.sh' first to retrieve all dependencies."
        exit 1
    fi
    
    log_info "Mounting NixOS ISO dynamically..."
    # Mount ISO and capture mount point reliably
    MOUNT_OUT=$(hdiutil mount -nobrowse -readonly "${ISO_PATH}")
    MOUNT_PATH=$(echo "${MOUNT_OUT}" | grep -o '/Volumes/.*' | head -n 1)
    
    if [[ -z "${MOUNT_PATH}" ]]; then
        log_error "Failed to mount NixOS ISO."
        exit 1
    fi
    
    log_success "ISO mounted at: ${MOUNT_PATH}"
    
    # Locate kernel and initrd safely using bash globbing (avoiding ls / subshell parsing)
    log_info "Locating boot assets inside NixOS store..."
    
    shopt -s nullglob
    KERNEL_MATCHES=("${MOUNT_PATH}"/boot/nix/store/*-linux-*/Image)
    INITRD_MATCHES=("${MOUNT_PATH}"/boot/nix/store/*-initrd-*/initrd)
    shopt -u nullglob

    KERNEL_SRC=""
    INITRD_SRC=""
    if (( ${#KERNEL_MATCHES[@]} > 0 )); then
        KERNEL_SRC="${KERNEL_MATCHES[0]}"
    fi
    if (( ${#INITRD_MATCHES[@]} > 0 )); then
        INITRD_SRC="${INITRD_MATCHES[0]}"
    fi
    
    if [[ -z "${KERNEL_SRC}" || -z "${INITRD_SRC}" ]]; then
        log_error "Could not find kernel (Image) or ramdisk (initrd) inside the ISO."
        exit 1
    fi
    
    rm -f "${KERNEL_PATH}" "${INITRD_PATH}" 2>/dev/null || true

    log_info "Extracting Linux Kernel to: ${KERNEL_PATH}"
    cp "${KERNEL_SRC}" "${KERNEL_PATH}"
    chmod 444 "${KERNEL_PATH}"
    
    log_info "Extracting Initrd Ramdisk to: ${INITRD_PATH}"
    cp "${INITRD_SRC}" "${INITRD_PATH}"
    chmod 444 "${INITRD_PATH}"
    
    log_info "Extracting NixOS System init path from grub.cfg..."
    if [[ -f "${MOUNT_PATH}/EFI/BOOT/grub.cfg" ]]; then
        grep -o 'init=/nix/store/[^ ]*/init' "${MOUNT_PATH}/EFI/BOOT/grub.cfg" | head -n 1 > "${INIT_PATH_FILE}"
        log_success "Extracted Init Path: $(cat "${INIT_PATH_FILE}")"
    else
        log_error "grub.cfg not found inside mounted ISO."
        exit 1
    fi
    
    log_info "Unmounting ISO..."
    hdiutil unmount "${MOUNT_PATH}" >/dev/null 2>&1 || true
    MOUNT_PATH=""
    log_success "Boot assets successfully extracted!"
else
    log_info "Boot assets (kernel, initrd, and init path) already extracted and validated."
fi

# --- 3. Auto-Create Blank Sparse Virtual Disk ---
if [[ ! -f "${DISK_PATH}" ]]; then
    log_info "Creating a 32GB sparse virtual SSD image..."
    mkdir -p "${IMAGES_DIR}"
    truncate -s 32G "${DISK_PATH}"
    chmod 600 "${DISK_PATH}"
    log_success "Created guest SSD at: ${DISK_PATH}"
else
    log_info "Guest SSD validated at: ${DISK_PATH}"
fi

# --- 4. Boot the Virtual Machine ---
if [[ ! -f "${INIT_PATH_FILE}" ]]; then
    log_error "Init path file missing at: ${INIT_PATH_FILE}. Please delete boot assets and run again to trigger extraction."
    exit 1
fi
INIT_ARG=$(cat "${INIT_PATH_FILE}")

log_info "Booting NixOS Installation VM..."
echo "   - Virtual CPUs (vCPUs): 4"
echo "   - Memory Allocation:   8192 MB"
echo "   - Extracted Kernel:    ${KERNEL_PATH}"
echo "   - Extracted Initrd:    ${INITRD_PATH}"
echo "   - Target Installer ISO: ${ISO_PATH}"
echo "   - Destination SSD:     ${DISK_PATH}"
echo "   - Shared Directory:    ${SANDBOX_DIR}"
echo "   - Kernel Command Line:  ${INIT_ARG} root=fstab console=hvc0 rw"
echo "──────────────────────────────────────────────────"
log_info "VM booted. Automated guest installation is scheduled to trigger in 15 seconds."
log_info "Interactive serial console will activate immediately after trigger commands are sent."

(
    # Wait for the NixOS Installer guest to boot, initialize systemd, and display the hvc0 getty prompt
    sleep 15
    echo ""
    sleep 1
    
    # Send clean unmount signals for any stale/conflicting mounts
    echo "sudo umount /mnt/boot 2>/dev/null || true"
    echo "sudo umount /mnt 2>/dev/null || true"
    echo "sudo umount /mnt/shared 2>/dev/null || true"
    sleep 1
    
    # 1. Mount the host shared directory to /tmp/shared to prevent shadowing when mounting the guest's /mnt
    echo "sudo mkdir -p /tmp/shared && sudo mount -t virtiofs shared /tmp/shared"
    sleep 2
    
    # 2. Trigger the guest installation script
    echo "sudo /tmp/shared/guest/nixos/install_nixos.sh ${PROFILE_NAME}"
    
    # 3. Fall back to standard input so the user/agent can still interactively manage the console
    cat
) | "${RUNNER_BIN}" \
  --kernel "${KERNEL_PATH}" \
  --initrd "${INITRD_PATH}" \
  --disk "${ISO_PATH}" \
  --disk "${DISK_PATH}" \
  --cpus 4 \
  --memory 8192 \
  --cmdline "${INIT_ARG} root=fstab console=hvc0 rw" \
  --shared-dir "${SANDBOX_DIR}" \
  --gui
