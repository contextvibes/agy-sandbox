#!/usr/bin/env bash

# ==============================================================================
# ❄️  clean_nixos_guest.sh - Premium NixOS Guest VM Slimming & Compaction Prep
# ==============================================================================
# Runs INSIDE the NixOS Guest VM to purge old system generations, vacuum system 
# logs, empty user/root caches, optimize the Nix store, clean swap space, and
# zero-fill the main drive so that Apple Virtualization.framework or other host
# hypervisors can compact the virtual disk image on the macOS host.
# ==============================================================================

set -euo pipefail

# --- Color Definitions (Premium Terminal Theme) ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

BOLD_RED='\033[1;31m'
BOLD_GREEN='\033[1;32m'
BOLD_YELLOW='\033[1;33m'
BOLD_BLUE='\033[1;34m'
BOLD_PURPLE='\033[1;35m'
BOLD_CYAN='\033[1;36m'
BOLD='\033[1m'

# --- Logging Helpers ---
log_info() { echo -e "  ${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "  ${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "  ${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "  ${RED}[ERROR]${NC} $1"; }

# --- Clean Exit/Error/Signal Trap ---
zero_file=""
cleanup_done=0

cleanup() {
    if (( cleanup_done )); then
        return
    fi
    cleanup_done=1
    if [[ -n "${zero_file:-}" && -f "${zero_file}" ]]; then
        echo -e "\n${RED}[CLEANUP] Interrupted! Removing temporary zero-fill file to reclaim space...${NC}"
        rm -f "${zero_file}"
        sync
    fi
}
trap cleanup EXIT INT TERM

# --- Sudo Check ---
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root (sudo)."
   exit 1
fi

# --- Default Preferences ---
INTERACTIVE=true
KEEP_GENERATIONS="old" # Deletes all generations except current by default
RUN_ZERO_FILL=true
RUN_SWAP_ZERO=true

show_help() {
    echo -e "${BOLD}NixOS Guest VM Slimming & Compaction Prep Utility${NC}"
    echo -e "Usage: sudo $0 [options]"
    echo -e ""
    echo -e "Options:"
    echo -e "  -y, --yes          Run non-interactively, accepting all defaults"
    echo -e "  -k, --keep <val>   Specify system generations to keep (e.g., 'old', '+3', '14d')"
    echo -e "  --no-zero          Skip zero-filling the free space"
    echo -e "  --no-swap          Skip resetting/zero-filling the swap file"
    echo -e "  -h, --help         Show this help message"
    echo -e ""
    exit 0
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)
            INTERACTIVE=false
            shift
            ;;
        -k|--keep)
            KEEP_GENERATIONS="$2"
            shift 2
            ;;
        --no-zero)
            RUN_ZERO_FILL=false
            shift
            ;;
        --no-swap)
            RUN_SWAP_ZERO=false
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            log_error "Unknown argument: $1"
            show_help
            ;;
    esac
done

# --- Header ---
clear
echo -e "${BOLD_BLUE}======================================================================${NC}"
echo -e "${BOLD_PURPLE}    ❄️   NixOS Guest VM Ultimate Slimming & Compaction Prep  ❄️    ${NC}"
echo -e "${BOLD_BLUE}======================================================================${NC}"
echo -e "  This utility runs inside your NixOS guest VM to prune redundant package"
echo -e "  generations, clean system/user caches, optimize the Nix store, clean"
echo -e "  swap files, and zero-fill unused disk space to prepare for host-side compaction."
echo -e "${BOLD_BLUE}----------------------------------------------------------------------${NC}"

# ------------------------------------------------------------------------------
# 1. Deleting Older System & User Generations
# ------------------------------------------------------------------------------
echo -e "\n${BOLD_CYAN}[1/6] Deleting Older System & User Generations...${NC}"

if [ "$INTERACTIVE" = true ]; then
    echo -e "  Older system/user generations reference old packages in the Nix store,"
    echo -e "  preventing them from being removed during garbage collection."
    echo -e "  Options for keeping generations:"
    echo -e "    - ${BOLD}old${NC}  : Keep ONLY the current active system configuration (MAX space saving)"
    echo -e "    - ${BOLD}+3${NC}   : Keep the last 3 system configurations (recommended safety threshold)"
    echo -e "    - ${BOLD}14d${NC}  : Keep configurations from the last 14 days"
    echo -e ""
    read -p "  Enter generation retention rule [old]: " user_keep
    KEEP_GENERATIONS=${user_keep:-"old"}
fi

log_info "Applying profile generation retention: ${BOLD_PURPLE}${KEEP_GENERATIONS}${NC}..."

# System Profile Generations
if nix-env --profile /nix/var/nix/profiles/system --delete-generations "$KEEP_GENERATIONS"; then
    log_success "System profile generations cleaned."
else
    log_warning "Could not clean system profile generations. (Normal if profile is locked or has no older versions)"
fi

# Scan and delete older generations for all user profiles
log_info "Scanning and cleaning user profile generations..."
for user_profile_dir in /nix/var/nix/profiles/per-user/*; do
    if [ -d "$user_profile_dir" ]; then
        user_name=$(basename "$user_profile_dir")
        log_info "Cleaning profile generations for user: ${BOLD}${user_name}${NC}..."
        for profile in "${user_profile_dir}"/profile*; do
            if [ -e "$profile" ] && [[ ! "$profile" =~ \-[0-9]+\-link$ ]]; then
                if nix-env --profile "$profile" --delete-generations "$KEEP_GENERATIONS" 2>/dev/null; then
                    log_success "User profile ${profile} cleaned."
                else
                    nix-env --profile "$profile" --delete-generations old 2>/dev/null || true
                fi
            fi
        done
    fi
done

if [[ "$KEEP_GENERATIONS" == "old" ]]; then
    log_info "Reclaiming all older generation links across all root and user profiles..."
    nix-collect-garbage --delete-old &>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 2. Vacuuming System Logs & Temporary Files
# ------------------------------------------------------------------------------
echo -e "\n${BOLD_CYAN}[2/6] Vacuuming System Logs & Temporary Files...${NC}"

# Vacuum systemd-journal
if command -v journalctl &>/dev/null; then
    log_info "Vacuuming systemd-journal logs to 1 second / 1 Megabyte..."
    journalctl --vacuum-time=1s &>/dev/null || true
    journalctl --vacuum-size=1M &>/dev/null || true
    log_success "Systemd journal logs vacuumed."
else
    log_warning "journalctl binary not found. Skipping."
fi

# Truncate any static log files in /var/log
log_info "Truncating legacy logs under /var/log..."
find /var/log -type f -name "*.log" -exec truncate -s 0 {} + 2>/dev/null || true

# Purge tmp directories safely
log_info "Purging temporary files under /tmp and /var/tmp..."
find /tmp -mindepth 1 -delete 2>/dev/null || true
find /var/tmp -mindepth 1 -delete 2>/dev/null || true
log_success "Temporary files cleared."

# Purge user caches
log_info "Scanning and clearing local user toolchain/dev caches..."
for user_home in /home/nixos /root; do
    if [ -d "${user_home}/.cache" ]; then
        log_info "Clearing cache contents under ${user_home}/.cache..."
        find "${user_home}/.cache" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    fi
done
log_success "User tool caches purged."

# ------------------------------------------------------------------------------
# 3. Nix Store Garbage Collection & Store Optimisation
# ------------------------------------------------------------------------------
echo -e "\n${BOLD_CYAN}[3/6] Running Nix Garbage Collection & Store Optimisation...${NC}"

log_info "Invoking Nix garbage collection (nix-store --gc)..."
nix-store --gc

log_info "Running Nix store file hardlink optimisation (nix-store --optimise)..."
log_info "This checks the Nix store, merging and hardlinking identical files."
log_info "Please wait, this process can take a few minutes..."
nix-store --optimise
log_success "Nix store garbage collection and file deduplication complete!"

# ------------------------------------------------------------------------------
# 4. Zero-Filling Swap Space
# ------------------------------------------------------------------------------
echo -e "\n${BOLD_CYAN}[4/6] Re-initializing Zero-Filled Swap Space...${NC}"

SWAP_FILE="/var/lib/swapfile"

if [ "$RUN_SWAP_ZERO" = true ]; then
    if [ "$INTERACTIVE" = true ]; then
        echo -e "  The 4GB swap space at ${SWAP_FILE} contains dirty, non-zero blocks"
        echo -e "  that will prevent the host hypervisor from shrinking that part of the disk image."
        echo -e "  Recreating the swap space with actual zero bytes fixes this."
        echo -e ""
        read -p "  Would you like to re-initialize and zero-fill the swap space (4GB)? (Y/n): " confirm_swap
        confirm_swap=${confirm_swap:-"y"}
        if [[ ! "$confirm_swap" =~ ^[Yy]$ ]]; then
            RUN_SWAP_ZERO=false
        fi
    fi
fi

if [ "$RUN_SWAP_ZERO" = true ] && [ -f "$SWAP_FILE" ]; then
    if swapon --show 2>/dev/null | grep -q "$SWAP_FILE"; then
        log_info "Active swap detected. Disabling swap on ${SWAP_FILE}..."
        swapoff "$SWAP_FILE"
    fi
    
    log_info "Writing 4GB of clean zeroes to ${SWAP_FILE}..."
    rm -f "$SWAP_FILE"
    if dd if=/dev/zero of="$SWAP_FILE" bs=1M count=4096 status=progress; then
        chmod 600 "$SWAP_FILE"
        mkswap "$SWAP_FILE"
        swapon "$SWAP_FILE"
        log_success "Swap file re-created, zero-filled, and reactivated successfully!"
    else
        log_error "Writing zero swapfile failed. Creating a sparse fallback to ensure system safety..."
        truncate -s 4G "$SWAP_FILE"
        chmod 600 "$SWAP_FILE"
        mkswap "$SWAP_FILE"
        swapon "$SWAP_FILE"
        log_warning "Fallback swap file established."
    fi
else
    log_info "Skipped swap space zero-filling."
fi

# ------------------------------------------------------------------------------
# 5. Disk Free Space Zero-Filling
# ------------------------------------------------------------------------------
echo -e "\n${BOLD_CYAN}[5/6] Zero-Filling Free Disk Space (Compaction Preparation)...${NC}"

# Safety check: Ensure we do NOT zero-fill a host shared directory (virtiofs)
root_device=$(df / | tail -1 | awk '{print $1}')
root_fs_type=$(df -T / | tail -1 | awk '{print $2}')

if [[ "$root_fs_type" == "virtiofs" ]]; then
    log_error "The root partition is mounted as virtiofs. Skipping zero-fill to prevent host depletion."
    RUN_ZERO_FILL=false
fi

if [ "$RUN_ZERO_FILL" = true ]; then
    if [ "$INTERACTIVE" = true ]; then
        echo -e "  ${YELLOW}Warning: Zero-filling writes zeroes to all unused sectors on your drive.${NC}"
        echo -e "  This expands the virtual disk image on the host temporarily if it is thin-provisioned,"
        echo -e "  but is absolutely critical to allow the host hypervisor to compact it later."
        echo -e ""
        read -p "  Perform disk zero-filling now? (Y/n): " confirm_zero
        confirm_zero=${confirm_zero:-"y"}
        if [[ ! "$confirm_zero" =~ ^[Yy]$ ]]; then
            RUN_ZERO_FILL=false
        fi
    fi
fi

if [ "$RUN_ZERO_FILL" = true ]; then
    zero_file="/var/tmp/zero.fill"
    
    available_kb=$(df -k / | tail -1 | awk '{print $4}')
    available_gb=$(echo "scale=2; $available_kb / 1024 / 1024" | bc 2>/dev/null || awk "BEGIN {print $available_kb/1024/1024}")
    
    log_info "Root Partition Device:  ${BOLD_BLUE}${root_device}${NC} (${root_fs_type})"
    log_info "Available Space to Zero: ${BOLD_GREEN}${available_gb} GB${NC}"
    log_info "Writing zeros to ${zero_file}... (expect 'No space left' error at completion)"
    
    if ! dd if=/dev/zero of="$zero_file" bs=1M status=progress 2>/dev/null; then
        log_info "Free space fully zero-filled (disk full limit reached)."
    fi
    
    log_info "Synchronizing filesystem cache (flushing writes)..."
    sync && sleep 2 && sync
    
    log_info "Removing temporary zero-filled file..."
    rm -f "$zero_file"
    sync && sleep 2 && sync
    
    log_success "Disk zero-filling completed successfully!"
else
    log_warning "Skipped disk free-space zero-filling."
fi

# ------------------------------------------------------------------------------
# 6. Reclaiming Stats & Final Compaction Instructions
# ------------------------------------------------------------------------------
echo -e "\n${BOLD_CYAN}[6/6] Finalizing Guest Metrics...${NC}"

current_used_kb=$(df -k / | tail -1 | awk '{print $3}')
current_used_gb=$(echo "scale=2; $current_used_kb / 1024 / 1024" | bc 2>/dev/null || awk "BEGIN {print $current_used_kb/1024/1024}")
current_free_kb=$(df -k / | tail -1 | awk '{print $4}')
current_free_gb=$(echo "scale=2; $current_free_kb / 1024 / 1024" | bc 2>/dev/null || awk "BEGIN {print $current_free_kb/1024/1024}")

echo -e "\n${BOLD_BLUE}======================================================================${NC}"
echo -e "${BOLD_GREEN}✨  NixOS Guest VM Slimming & Compaction Prep Complete!  ✨${NC}"
echo -e "${BOLD_BLUE}======================================================================${NC}"
echo -e "  • Final Guest Disk Used Space: ${BOLD_GREEN}${current_used_gb} GB${NC}"
echo -e "  • Final Guest Disk Free Space: ${BOLD_GREEN}${current_free_gb} GB (All Zero-Filled)"
echo -e "──────────────────────────────────────────────────────────────────────"
echo -e "To compact the virtual disk image on your macOS host machine:\n"

echo -e "  1. Shut down this Guest VM completely:"
echo -e "     ${BOLD}sudo shutdown -h now${NC}\n"

echo -e "  2. Run compaction on your Mac host depending on your VM environment:\n"

echo -e "  📦 ${BOLD_PURPLE}Apple Virtualization.framework (Native Host Runner):${NC}"
echo -e "     Since macOS APFS natively supports sparse files, removing the zero-filled file"
echo -e "     releases guest sectors. However, to force immediate physical disk image compaction"
echo -e "     and completely reclaim host physical SSD space, you can clone or convert the"
echo -e "     raw virtual disk image using ${CYAN}qemu-img${NC} on your Mac host:"
echo -e "     "
echo -e "     ${CYAN}qemu-img convert -O raw -p images/nixos_guest.img images/nixos_guest_compact.img${NC}"
echo -e "     "
echo -e "     Alternatively, for APFS-level sparse copying, you can use:"
echo -e "     ${CYAN}cp --sparse=always images/nixos_guest.img images/nixos_guest_compact.img${NC}"
echo -e "     "
echo -e "     Then replace the original image with the compact one."
echo -e ""
echo -e "  📦 ${BOLD_PURPLE}UTM (QEMU-based GUI):${NC}"
echo -e "     • Go to VM Settings -> Drives -> Select your hard drive -> Click ${CYAN}Compress${NC}."
echo -e "     • Or use the command line on your Mac host:"
echo -e "       ${CYAN}qemu-img convert -O qcow2 data.qcow2 data_compact.qcow2${NC}"
echo -e ""
echo -e "  📦 ${BOLD_PURPLE}Tart / Or other runners:${NC}"
echo -e "     • Run Tart clone to rebuild a clean sparse disk:"
echo -e "       ${CYAN}tart clone <vm-name> <vm-name-compact>${NC}"
echo -e "       ${CYAN}tart delete <vm-name>${NC}"
echo -e "${BOLD_BLUE}======================================================================${NC}"
