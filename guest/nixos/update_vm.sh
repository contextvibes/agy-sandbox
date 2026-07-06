#!/usr/bin/env bash

# ==============================================================================
#  NixOS Guest Configuration Updater
#  Runs INSIDE the NixOS Guest VM to sync configuration from host shared
#  directory and trigger nixos-rebuild.
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

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Ensure the script is run with sudo inside the guest
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root (sudo)."
   exit 1
fi

SHARED_MOUNT="/home/nixos/shared"
NIXOS_CONFIG_DIR="/etc/nixos"
PROFILE_NAME="${1:-antigravity-nixos}"

echo -e "${BOLD}❄️  NixOS Configuration Updater [Profile: ${PROFILE_NAME}]${NC}"
echo "──────────────────────────────────────────────────"

# 1. Check if Host Shared Folder is mounted
if ! mountpoint -q "${SHARED_MOUNT}" 2>/dev/null; then
    log_info "Host shared workspace is not mounted. Mounting now..."
    mkdir -p "${SHARED_MOUNT}"
    mount -t virtiofs shared "${SHARED_MOUNT}"
    log_success "Host workspace mounted."
fi

HOST_CONFIG_DIR="${SHARED_MOUNT}/guest/nixos"

if [[ ! -d "${HOST_CONFIG_DIR}" ]]; then
    log_error "Host configuration directory not found at: ${HOST_CONFIG_DIR}"
    exit 1
fi

# 2. Sync & Generate Configuration Files
log_info "Syncing configuration files from host shared directory to ${NIXOS_CONFIG_DIR}..."
cp -f "${HOST_CONFIG_DIR}/configuration.nix" "${NIXOS_CONFIG_DIR}/"

# If the profile name wasn't explicitly passed as an argument, detect it from the local guest hostname
if [[ "${PROFILE_NAME}" == "antigravity-nixos" ]]; then
    DETECTED_NAME="$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo "antigravity-nixos")"
    if [[ -n "${DETECTED_NAME}" ]]; then
        PROFILE_NAME="${DETECTED_NAME}"
    fi
fi

log_info "Dynamically generating updated Flake with profile ${PROFILE_NAME}..."
cat <<EOF > "${NIXOS_CONFIG_DIR}/flake.nix"
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

# 3. Handle Git staging (needed for Nix Flakes evaluation)
log_info "Staging configuration updates in local Git repository..."
cd "${NIXOS_CONFIG_DIR}"
if [[ ! -d ".git" ]]; then
    git init
    git config user.email "updater@nixos.org"
    git config user.name "NixOS Updater"
fi
git add -A
git commit -m "Update config: $(date)" || true

# 4. Trigger NixOS Rebuild Switch
log_info "Executing nixos-rebuild switch for profile ${PROFILE_NAME}..."
if nixos-rebuild switch --flake "${NIXOS_CONFIG_DIR}#${PROFILE_NAME}"; then
    log_success "NixOS configuration updated and applied successfully!"
    echo "──────────────────────────────────────────────────"
    log_success "Your OpenSSH server is now active!"
    echo "You can now connect to this VM from your macOS host using:"
    echo -e "   ${BOLD}ssh nixos@<VM_IP>${NC} (password: ${BOLD}nixos${NC})"
else
    log_error "nixos-rebuild failed. Please inspect errors above."
    exit 1
fi
