#!/usr/bin/env bash

# ==============================================================================
#  NixOS Guest VM Automatic Installation Script
#  This script runs INSIDE the NixOS Guest VM to partition/format /dev/vdb,
#  generate hardware config, copy the flake, and install the system.
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

# Ensure the script is run with sudo
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root (sudo)."
   exit 1
fi

# --- Disable IPv6 inside the live installer session ---
# This prevents silent packet corruption over Apple's Virtualization.framework NAT
# on large downloads from cache.nixos.org, which leads to "hash mismatch" errors.
log_info "Disabling IPv6 inside the live session to prevent NAT download corruption..."
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1 || true

# --- Disable TCP Checksum Offloading and optimize MTU dynamically ---
log_info "Disabling TCP checksum offloading on all active interfaces to prevent NAT packet corruption..."
for dev_path in /sys/class/net/*; do
    if [ -d "${dev_path}" ]; then
        dev=$(basename "${dev_path}")
        if [ "${dev}" != "lo" ]; then
            ethtool -K "${dev}" rx off tx off >/dev/null 2>&1 || true
            ip link set dev "${dev}" mtu 1400 >/dev/null 2>&1 || true
        fi
    fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISK="/dev/vdb"
PROFILE_NAME="${1:-antigravity-nixos}"

echo -e "${BOLD}❄️  NixOS Automated Target Disk Installation [Profile: ${PROFILE_NAME}]${NC}"
echo "──────────────────────────────────────────────────"

# --- 0. Clean Up Conflicting Stale Mounts ---
log_info "Ensuring any target mounts are cleanly unmounted..."
umount -R /mnt/boot 2>/dev/null || true
umount -R /mnt 2>/dev/null || true


# --- 1. Target Disk Verification ---
if [[ ! -b "${DISK}" ]]; then
    log_error "Target block device ${DISK} not found inside guest VM."
    exit 1
fi

log_info "Target installation disk found: ${DISK} (32 GB)"

# --- 2. Partitioning target disk ---
log_info "Partitioning ${DISK} into EFI (vdb1) and Root (vdb2)..."
parted -s "${DISK}" -- mklabel gpt
parted -s "${DISK}" -- mkpart ESP fat32 1MiB 512MiB
parted -s "${DISK}" -- set 1 esp on
parted -s "${DISK}" -- mkpart primary ext4 512MiB 100%

# Allow kernel to register partition table updates
udevadm settle
log_success "Partitioning completed successfully."

# --- 3. Formatting partitions ---
log_info "Formatting EFI partition (${DISK}1) as FAT32..."
mkfs.vfat -F 32 -n boot "${DISK}1"

log_info "Formatting Root partition (${DISK}2) as Ext4..."
mkfs.ext4 -F -L nixos "${DISK}2"
log_success "Formatting completed successfully."

# --- 4. Mounting filesystems ---
log_info "Mounting target root partition to /mnt..."
mount "${DISK}2" /mnt

log_info "Mounting target boot partition to /mnt/boot..."
mkdir -p /mnt/boot
mount "${DISK}1" /mnt/boot
log_success "Filesystems mounted at /mnt and /mnt/boot."

# --- 5. Generating Hardware Configuration ---
log_info "Generating NixOS hardware configuration..."
mkdir -p /mnt/etc/nixos
nixos-generate-config --root /mnt
log_success "Hardware configuration generated."

# --- 6. Copying & Generating Flake Assets ---
log_info "Copying generic NixOS configuration..."
cp "${SCRIPT_DIR}/configuration.nix" /mnt/etc/nixos/

log_info "Dynamically generating custom Flake with profile ${PROFILE_NAME}..."
cat <<EOF > /mnt/etc/nixos/flake.nix
{
  description = "Antigravity IDE NixOS VM Configuration Flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs, ... }@inputs: {
    nixosConfigurations.${PROFILE_NAME} = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        ./configuration.nix
        ({ lib, ... }: {
          networking.hostName = lib.mkForce "${PROFILE_NAME}";
        })
      ];
    };
  };
}
EOF

# Initialize as Git repo inside guest target to resolve plain-directory flake.lock modification mismatch
log_info "Initializing target directory as Git repository to bypass evaluation hash mismatches..."
cd /mnt/etc/nixos
git init
git config user.email "installer@nixos.org"
git config user.name "NixOS Installer"
git add -A
git commit -m "Initial commit for installation"
cd - >/dev/null

log_success "Flake assets staged in target root and tracked via Git."

# --- 7. Executing NixOS Installation ---
log_info "Running nixos-install with profile ${PROFILE_NAME}..."
nixos-install --flake "/mnt/etc/nixos#${PROFILE_NAME}" --no-root-passwd --option fallback true

# Dynamically extract and save System init path to host to allow seamless direct kernel boot
log_info "Extracting NixOS System init path from newly installed bootloader config..."
if [[ -f "/mnt/boot/loader/entries/nixos-generation-1.conf" ]]; then
    INIT_PATH_OUTPUT="${SCRIPT_DIR}/init_path_${PROFILE_NAME}.txt"
    grep -o 'init=/nix/store/[^ ]*/init' "/mnt/boot/loader/entries/nixos-generation-1.conf" | head -n 1 > "${INIT_PATH_OUTPUT}"
    # Also write a standard non-profile backup for legacy compat
    cp -f "${INIT_PATH_OUTPUT}" "${SCRIPT_DIR}/init_path.txt"
    log_success "Saved persistent init path: $(cat "${INIT_PATH_OUTPUT}")"
else
    log_warning "nixos-generation-1.conf not found. Cannot automatically extract init path."
fi

# --- 8. Installing Antigravity IDE ---
log_info "Installing Antigravity IDE inside the NixOS guest..."
if [[ -f "/tmp/shared/downloads/Antigravity IDE.tar.gz" ]]; then
    mkdir -p /mnt/home/nixos
    tar -xzf "/tmp/shared/downloads/Antigravity IDE.tar.gz" -C /mnt/home/nixos/
    
    # Create Desktop shortcut for easy launching
    mkdir -p /mnt/home/nixos/Desktop
    cat << 'EOF' > /mnt/home/nixos/Desktop/antigravity-ide.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Antigravity IDE
Comment=Launch Antigravity IDE
Exec="/home/nixos/Antigravity IDE/antigravity-ide" --no-sandbox
Icon=system-file-manager
Path="/home/nixos/Antigravity IDE"
Terminal=false
Categories=Development;IDE;
EOF

    # Configure autostart for Display Auto-Resizer to automatically adapt desktop size on boot
    mkdir -p /mnt/home/nixos/.config/autostart
    cat << 'EOF' > /mnt/home/nixos/.config/autostart/display-auto-resizer.desktop
[Desktop Entry]
Type=Application
Name=Display Auto-Resizer
Comment=Automatically fits NixOS desktop resolution to the host Cocoa window
Exec=/home/nixos/shared/guest/nixos/auto_resize.sh
StartupNotify=false
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

    # Set correct ownership and execution permissions for nixos user (UID 1000, GID 100)
    chown -R 1000:100 "/mnt/home/nixos/Antigravity IDE" /mnt/home/nixos/Desktop /mnt/home/nixos/.config
    chmod +x "/mnt/home/nixos/Desktop/antigravity-ide.desktop" 2>/dev/null || true
    chmod +x "/mnt/home/nixos/.config/autostart/display-auto-resizer.desktop" 2>/dev/null || true
    log_success "Antigravity IDE and Display Auto-Resizer successfully installed inside the guest."
else
    # Even if Antigravity IDE is skipped, configure autostart for Display Auto-Resizer to automatically adapt desktop size on boot
    mkdir -p /mnt/home/nixos/.config/autostart
    cat << 'EOF' > /mnt/home/nixos/.config/autostart/display-auto-resizer.desktop
[Desktop Entry]
Type=Application
Name=Display Auto-Resizer
Comment=Automatically fits NixOS desktop resolution to the host Cocoa window
Exec=/home/nixos/shared/guest/nixos/auto_resize.sh
StartupNotify=false
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
    chown -R 1000:100 /mnt/home/nixos/.config
    chmod +x "/mnt/home/nixos/.config/autostart/display-auto-resizer.desktop" 2>/dev/null || true
    log_warning "Antigravity IDE.tar.gz not found at /tmp/shared/downloads/Antigravity IDE.tar.gz. Skipping IDE guest installation, but Display Auto-Resizer is configured."
fi

echo "──────────────────────────────────────────────────"
log_success "NixOS has been successfully installed on ${DISK}!"
log_success "You can now safely power off the VM, unmount the ISO, and boot directly from your virtual disk."
