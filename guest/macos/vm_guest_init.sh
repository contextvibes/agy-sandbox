#!/usr/bin/env bash
# ==============================================================================
# 🍏 vm_guest_init.sh - Persistent Guest-Side Optimization & Link Redirection
# ==============================================================================
# This script runs on boot inside the macOS guest VM. It automates system tuning,
# limits write-amplification, mitigates connection timeouts, and surgically
# redirects heavy developer cache directories to the VirtioFS shared folder
# (/Volumes/My Shared Files), adhering to the "Gold Standard" of VM optimization.
# ==============================================================================

set -euo pipefail

LOG_FILE="/var/log/antigravity_guest_init.log"
exec > >(tee -i "${LOG_FILE}") 2>&1

echo "======================================================================"
echo "🚀 Antigravity Guest Init Started: $(date)"
echo "======================================================================"

# --- 1. Identify the Primary GUI Developer User ---
# Finds the first human user (UID >= 501, excluding 'nobody')
DEV_USER=$(dscl . list /Users UniqueID | awk '$2 >= 501 {print $1}' | grep -v 'nobody' | head -n 1)
if [[ -z "${DEV_USER}" ]]; then
    echo "[ERROR] No human user (UID >= 501) found inside the guest VM. Exiting."
    exit 1
fi

DEV_HOME="/Users/${DEV_USER}"
echo "[INFO] Detected active developer user: ${DEV_USER} (${DEV_HOME})"

# --- 2. Mitigate Local Metadata Server Timeouts (Operational Guideline 6) ---
# Adds a blackhole route for GCP Metadata server (169.254.169.254)
# to prevent Electron/Go SDKs from hanging for 42+ seconds on boot.
echo "[INFO] Setting up blackhole route for GCP Metadata (169.254.169.254)..."
route -q -n add -host 169.254.169.254 127.0.0.1 -blackhole || \
    echo "[WARNING] Could not add blackhole route (it may already exist)."

# --- 3. Disable IPv6 to Prevent BPF Socket Kernel Panics (Operational Guideline 5) ---
# Disables IPv6 on all network services to avoid kernel null pointer dereferences.
echo "[INFO] Disabling IPv6 globally across all network services..."
networksetup -listallnetworkservices | grep -v '*' | while read -r service; do
    if [[ -n "${service}" ]]; then
        echo "  • Disabling IPv6 for service: ${service}"
        networksetup -setv6off "${service}" 2>/dev/null || true
    fi
done

# --- 4. Deep System Performance & Write-Amplification Tuning ---
# A. Disable macOS VM Disk Swap & force compressed-only RAM
# Mode 2 is VM_COMPRESSOR_COMPACT (Compression enabled, disk swap disabled)
echo "[INFO] Disabling virtual memory disk swap (enabling compressed-only RAM)..."
sysctl -w vm.compressor_mode=2 || true

# Append to sysctl.conf to persist across user-reboots
SYSCTL_CONF="/etc/sysctl.conf"
if [[ ! -f "${SYSCTL_CONF}" ]] || ! grep -q "vm.compressor_mode" "${SYSCTL_CONF}"; then
    echo "vm.compressor_mode=2" >> "${SYSCTL_CONF}"
    echo "[INFO] Persistent sysctl 'vm.compressor_mode=2' written to ${SYSCTL_CONF}."
fi

# B. Disable Sleepimage and Hibernation (Virtualization.framework manages sleep states)
echo "[INFO] Disabling hibernation and sleepimage writes..."
pmset -a hibernatemode 0
pmset -a standby 0
pmset -a autopoweroff 0
rm -f /var/vm/sleepimage || true

# C. Disable Spotlight Indexing globally
echo "[INFO] Suppressing Spotlight indexing globally..."
mdutil -a -i off || true
mdutil -E / || true

# D. Limit Unified Logging (Restricts logd to errors only, saving massive write cycles)
echo "[INFO] Configuring Unified Logging to write errors only..."
log config --mode "level:error" || true

# E. Disable Software Updates
echo "[INFO] Suppressing background software updates..."
defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool false
defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false

# --- 5. Surgical Developer Directory Redirections (Gold Standard) ---
# Keeps ~/Library local to the paravirtualized block storage for flock/socket safety,
# but redirects heavy, stateless, and high-write directories to VirtioFS.
SHARED_MOUNT="/Volumes/My Shared Files"
REDIRECTION_ROOT="${SHARED_MOUNT}/.agy_dev_cache"

echo "[INFO] Checking for VirtioFS shared drive at ${SHARED_MOUNT}..."
if [[ -d "${SHARED_MOUNT}" ]]; then
    echo "[SUCCESS] VirtioFS shared drive found! COMMENCING SELECTIVE PROFILE REDIRECTION."
    
    # Define surgical directories to redirect
    # Format: "rel_path_from_home|cache_name_on_shared"
    # Keeping heavy, lock-free folders on VirtioFS means 0 physical disk growth for the COW clone!
    declare -a REDIRECTS=(
        "Library/Developer/Xcode/DerivedData|Xcode-DerivedData"
        "Library/Developer/Xcode/Archives|Xcode-Archives"
        "Library/Caches/Homebrew|Homebrew-Cache"
        "Library/Caches/pip|pip-Cache"
        "Library/Caches/yarn|yarn-Cache"
        "Library/Caches/CocoaPods|CocoaPods-Cache"
        ".npm|npm-Cache"
        ".cache|generic-cache"
        ".cargo/registry|cargo-registry"
        ".cargo/git|cargo-git-cache"
        ".gradle/caches|gradle-cache"
    )

    # Initialize redirection folder on host mount
    mkdir -p "${REDIRECTION_ROOT}"
    chown "${DEV_USER}:staff" "${REDIRECTION_ROOT}"
    chmod 775 "${REDIRECTION_ROOT}"

    for entry in "${REDIRECTS[@]}"; do
        IFS='|' read -r rel_path folder_name <<< "${entry}"
        target_symlink="${DEV_HOME}/${rel_path}"
        host_backed_dir="${REDIRECTION_ROOT}/${folder_name}"

        echo "  • Processing Redirection for: ~/${rel_path}"

        # 1. Create parent folders in guest if they don't exist
        mkdir -p "$(dirname "${target_symlink}")"

        # 2. Setup Host-Backed folder if missing
        if [[ ! -d "${host_backed_dir}" ]]; then
            mkdir -p "${host_backed_dir}"
            chown -R "${DEV_USER}:staff" "${host_backed_dir}"
            chmod -R 755 "${host_backed_dir}"
        fi

        # 3. If target is a real folder, migrate contents first so no developer data is lost!
        if [[ -d "${target_symlink}" && ! -L "${target_symlink}" ]]; then
            echo "    [MIGRATE] Migrating active guest files to host shared storage..."
            # Copy contents recursively to host-backed mount
            cp -a "${target_symlink}/." "${host_backed_dir}/" || true
            rm -rf "${target_symlink}"
        fi

        # 4. Create the symbolic link
        if [[ ! -L "${target_symlink}" ]]; then
            rm -f "${target_symlink}" # Remove any broken link or residual file
            ln -s "${host_backed_dir}" "${target_symlink}"
            chown -h "${DEV_USER}:staff" "${target_symlink}"
            echo "    [LINKED] Created symlink: ${target_symlink} -> ${host_backed_dir}"
        else
            echo "    [OK] Symlink already exists and is active."
        fi
    done

    # Set up customer project directory symlink
    # Redirects ~/Projects directly to the customer's root directory on VirtioFS
    PROJECTS_LINK="${DEV_HOME}/Projects"
    if [[ -d "${SHARED_MOUNT}" ]]; then
        if [[ -d "${PROJECTS_LINK}" && ! -L "${PROJECTS_LINK}" ]]; then
            echo "    [MIGRATE] Migrating local Projects folder to host shared folder..."
            cp -a "${PROJECTS_LINK}/." "${SHARED_MOUNT}/" || true
            rm -rf "${PROJECTS_LINK}"
        fi
        if [[ ! -L "${PROJECTS_LINK}" ]]; then
            rm -f "${PROJECTS_LINK}"
            ln -s "${SHARED_MOUNT}" "${PROJECTS_LINK}"
            chown -h "${DEV_USER}:staff" "${PROJECTS_LINK}"
            echo "    [LINKED] Redirected ~/Projects -> ${SHARED_MOUNT} (Host Directory)"
        fi
    fi
else
    echo "[WARNING] VirtioFS shared drive NOT found at ${SHARED_MOUNT}. Profile redirection skipped."
    echo "[WARNING] Guest VM is running on standalone local disk storage."
fi

echo "======================================================================"
echo "🎉 Antigravity Guest Init Completed Successfully: $(date)"
echo "======================================================================"
