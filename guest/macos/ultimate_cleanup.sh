#!/usr/bin/env bash

# ==============================================================================
# 💎 ultimate_cleanup.sh - The Ultimate macOS Dev VM Slimming & Optimization Script
# ==============================================================================
# A premium, robust, interactive, and safe script designed to optimize and
# slim down a macOS guest VM running under Apple's Virtualization.framework,
# UTM, Tart, VMware Fusion, or Parallels Desktop.
#
# Sections included:
#   1. System & User Caches & Logs (including var/folders & Unified Logging)
#   2. Developer Environment & Package Managers (Python/Poetry, Node, Brew)
#   3. Hardware & Graphics UI Optimizations (Motion & Transparency)
#   4. Deep OS Performance Tuning & Service Disabling (Spotlight, Telemetry, thermalmonitord)
#   5. Local APFS Snapshots Purge (Time Machine)
#   6. Disk Zero-Filling (APFS and HFS+ compatible fallbacks)
# ==============================================================================

# Exit immediately if a command exits with a non-zero status (except where expected)
# or if an unassigned variable is referenced.
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

# --- User Preferences Helper ---
# macOS preferences are stored per-user. When running the script via sudo (as root),
# direct "defaults write" commands modify root's plist files.
# This helper executes defaults under the original non-root user (stored in $SUDO_USER)
# to correctly target the active graphical session.
user_defaults() {
    if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        sudo -u "$SUDO_USER" defaults "$@"
    else
        defaults "$@"
    fi
}

# Restart processes as the original user to ensure GUI changes register.
user_killall() {
    if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        sudo -u "$SUDO_USER" killall "$@" >/dev/null 2>&1 || true
    else
        killall "$@" >/dev/null 2>&1 || true
    fi
}

# Safely gets the underlying GUI user's ID for launchctl bootout actions.
get_user_uid() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        id -u "$SUDO_USER"
    else
        id -u
    fi
}

# --- Header ---
clear
echo -e "${BOLD_BLUE}======================================================================${NC}"
echo -e "${BOLD_PURPLE}    💎  macOS Guest VM Ultimate Slimming & Performance Tuning  💎    ${NC}"
echo -e "${BOLD_BLUE}======================================================================${NC}"
echo -e "  This premium utility automates developer VM optimizations inside the"
echo -e "  guest OS to reclaim gigabytes of disk space and boost interface speed."
echo -e "  Ready to run on macOS guest virtual machines."
echo -e "${BOLD_BLUE}----------------------------------------------------------------------${NC}"

# --- Sudo Check ---
if [ "$EUID" -ne 0 ]; then
    log_warning "This script is not running as root (sudo)."
    echo -e "  Some advanced steps (system caches, system logs, local snapshots) may fail"
    echo -e "  or be skipped. We recommend running with: ${BOLD_CYAN}sudo ./ultimate_cleanup.sh${NC}\n"
    read -p "  Do you want to continue in user-only mode? (y/N): " confirm_continue
    if [[ ! "$confirm_continue" =~ ^[Yy]$ ]]; then
        log_error "Exiting to allow running with sudo."
        exit 1
    fi
    echo -e ""
fi

# ------------------------------------------------------------------------------
# 1. System & User Caches & Logs
# ------------------------------------------------------------------------------
echo -e "${BOLD_CYAN}[1/6] Purging System & User Caches/Logs...${NC}"

# User Caches (~/Library/Caches)
USER_CACHE_DIR="$HOME/Library/Caches"
if [ -d "$USER_CACHE_DIR" ]; then
    log_info "Purging items inside user caches (~/Library/Caches)..."
    # Keep the directory structure intact, delete only the contents
    find "$USER_CACHE_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || \
        log_warning "Some user cache files could not be removed (they may be in use)."
    log_success "User cache purge completed."
else
    log_warning "User cache directory not found."
fi

# User Logs (~/Library/Logs)
USER_LOG_DIR="$HOME/Library/Logs"
if [ -d "$USER_LOG_DIR" ]; then
    log_info "Purging user logs (~/Library/Logs)..."
    find "$USER_LOG_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || \
        log_warning "Some user logs could not be removed."
    log_success "User log purge completed."
fi

# System Caches (/Library/Caches)
SYS_CACHE_DIR="/Library/Caches"
if [ -d "$SYS_CACHE_DIR" ]; then
    if [ -w "$SYS_CACHE_DIR" ]; then
        log_info "Purging items inside system caches (/Library/Caches)..."
        find "$SYS_CACHE_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || \
            log_warning "Some system cache files could not be removed."
        log_success "System cache purge completed."
    else
        log_warning "No write permissions for $SYS_CACHE_DIR. Run with sudo to clear."
    fi
fi

# System Logs (/var/log)
SYS_LOG_DIR="/var/log"
if [ -d "$SYS_LOG_DIR" ]; then
    if [ -w "$SYS_LOG_DIR" ]; then
        log_info "Purging system logs (/var/log)..."
        find "$SYS_LOG_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || \
            log_warning "Some system logs could not be removed."
        log_success "System log purge completed."
    else
        log_warning "No write permissions for $SYS_LOG_DIR. Run with sudo to clear."
    fi
fi

# macOS Unified Logging Purge (requires root)
if [ "$EUID" -eq 0 ]; then
    log_info "Purging macOS Unified Logging diagnostics and uuidtext records..."
    log erase --all &>/dev/null || true
    log_success "Unified log records purged."
fi

# User Temporary and Sandbox Caches in /var/folders
if [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ]; then
    log_info "Purging user temporary files (\$TMPDIR)..."
    find "$TMPDIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    
    # Also purge the adjacent user cache directory
    user_var_cache="$(dirname "$TMPDIR")/C"
    if [ -d "$user_var_cache" ]; then
        log_info "Purging user system caches ($user_var_cache)..."
        find "$user_var_cache" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    fi
    log_success "User temporary and sandboxed caches purged."
fi

# ------------------------------------------------------------------------------
# 2. Developer Environment & Package Managers
# ------------------------------------------------------------------------------
echo -e "\n${BOLD_CYAN}[2/6] Cleaning Developer Artifacts & Package Caches...${NC}"

# Python Pip
for pip_bin in pip pip3; do
    if command -v "$pip_bin" &>/dev/null; then
        log_info "$pip_bin detected. Purging pip cache..."
        if ! "$pip_bin" cache purge &>/dev/null; then
            log_warning "'$pip_bin cache purge' unsupported or failed. Performing manual purge..."
            PIP_CACHE_DIR="$HOME/Library/Caches/pip"
            if [ -d "$PIP_CACHE_DIR" ]; then
                rm -rf "$PIP_CACHE_DIR"/* 2>/dev/null || true
            fi
        fi
        log_success "$pip_bin cache cleared."
    fi
done

# Poetry (Python Package Manager)
if command -v poetry &>/dev/null; then
    log_info "Poetry detected. Clearing Poetry package cache..."
    poetry cache clear --all --no-interaction . &>/dev/null || true
    POETRY_CACHE_DIR="$HOME/Library/Caches/pypoetry"
    if [ -d "$POETRY_CACHE_DIR" ]; then
        rm -rf "$POETRY_CACHE_DIR"/* 2>/dev/null || true
    fi
    log_success "Poetry caches cleared."
fi

# Android Studio & Gradle
GRADLE_DIR="$HOME/.gradle"
if [ -d "$GRADLE_DIR" ]; then
    log_info "Gradle environment detected. Clearing build caches..."
    if [ -d "$GRADLE_DIR/caches" ]; then
        rm -rf "$GRADLE_DIR/caches"/* 2>/dev/null || true
        log_success "Gradle build cache cleared."
    fi
fi

# Homebrew Package Manager
if command -v brew &>/dev/null; then
    log_info "Homebrew detected. Invoking cleanup..."
    brew cleanup -s &>/dev/null || log_warning "Homebrew cleanup command encountered errors."
    
    BREW_CACHE_DIR=$(brew --cache 2>/dev/null || echo "$HOME/Library/Caches/Homebrew")
    if [ -d "$BREW_CACHE_DIR" ]; then
        rm -rf "$BREW_CACHE_DIR"/* 2>/dev/null || true
    fi
    log_success "Homebrew packages and caches cleaned."
fi

# npm (Node Package Manager)
if command -v npm &>/dev/null; then
    log_info "npm detected. Purging global npm cache..."
    npm cache clean --force &>/dev/null || log_warning "npm cache clean failed."
    log_success "npm cache purged."
fi

# Yarn Package Manager
if command -v yarn &>/dev/null; then
    log_info "Yarn detected. Clearing global cache..."
    yarn cache clean &>/dev/null || log_warning "Yarn cache clean failed."
    log_success "Yarn cache cleared."
fi

# Trash Bin
TRASH_DIR="$HOME/.Trash"
if [ -d "$TRASH_DIR" ]; then
    log_info "Emptying user Trash bin..."
    rm -rf "$TRASH_DIR"/* 2>/dev/null || true
    log_success "Trash emptied."
fi

# --- Developer Terminal Optimization (Interactive) ---
echo -e "\n  ${BOLD_PURPLE}Terminal & Security Optimization:${NC}"
echo -e "    • Bypasses Gatekeeper security scans for compiled development binaries (Developer Mode)"
echo -e "    • Disables authorization password prompts for debugging tools (DevToolsSecurity)"
read -p "  Would you like to enable Developer Mode for your terminal session? (y/N) [n]: " run_dev_terminal
run_dev_terminal=$(echo "$run_dev_terminal" | tr '[:upper:]' '[:lower:]')
if [[ "$run_dev_terminal" == "y" || "$run_dev_terminal" == "yes" ]]; then
    log_info "Enabling Developer Mode for terminal & bypassing DevToolsSecurity..."
    spctl developer-mode enable-terminal 2>/dev/null || true
    DevToolsSecurity -enable 2>/dev/null || true
    log_success "Terminal developer bypass enabled."
fi

# --- Package Manager Profile Optimizations (Interactive) ---
echo -e "\n  ${BOLD_PURPLE}Package Manager Optimizations:${NC}"
echo -e "    Appends performance profiles to your shell and Gradle settings:"
echo -e "    • Homebrew: disable slow auto-updates, analytics, and cask quarantine"
echo -e "    • NPM: prefer offline, disable redundant progress bar rendering"
echo -e "    • Cargo (Rust): use unpacked split-debuginfo for fast linking"
echo -e "    • Gradle: daemon enabled, parallel builds, cache reuse, and tuned parallel GC"
read -p "  Would you like to apply these package manager profiles? (y/N) [n]: " run_pkg_profiles
run_pkg_profiles=$(echo "$run_pkg_profiles" | tr '[:upper:]' '[:lower:]')
if [[ "$run_pkg_profiles" == "y" || "$run_pkg_profiles" == "yes" ]]; then
    shell_configs=()
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        user_home=$(eval echo "~$SUDO_USER")
    else
        user_home="$HOME"
    fi
    
    [ -f "$user_home/.zshrc" ] && shell_configs+=("$user_home/.zshrc")
    [ -f "$user_home/.zprofile" ] && shell_configs+=("$user_home/.zprofile")
    [ -f "$user_home/.bash_profile" ] && shell_configs+=("$user_home/.bash_profile")
    [ -f "$user_home/.profile" ] && shell_configs+=("$user_home/.profile")
    
    if [ ${#shell_configs[@]} -eq 0 ]; then
        shell_configs+=("$user_home/.zprofile")
        touch "$user_home/.zprofile"
    fi
    
    log_info "Configuring environment variables in shell profile..."
    for config in "${shell_configs[@]}"; do
        if ! grep -q "# === macOS Dev VM Speedups ===" "$config" 2>/dev/null; then
            cat << 'EOF' >> "$config"

# === macOS Dev VM Speedups ===
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_EMOJI=1
export HOMEBREW_CASK_OPTS="--no-quarantine"
# === End macOS Dev VM Speedups ===
EOF
            log_success "Appended Homebrew speedups to $(basename "$config")."
        else
            log_info "Homebrew speedups already present in $(basename "$config")."
        fi
    done
    
    if command -v npm &>/dev/null; then
        log_info "Configuring npm offline preference and progress mute..."
        if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
            sudo -u "$SUDO_USER" npm config set progress false &>/dev/null || true
        else
            npm config set progress false &>/dev/null || true
        fi
    fi
    
    log_info "Configuring global Gradle optimized properties..."
    gradle_dir="$user_home/.gradle"
    mkdir -p "$gradle_dir"
    gradle_props="$gradle_dir/gradle.properties"
    
    if ! grep -q "# === macOS Dev VM Gradle Speedups ===" "$gradle_props" 2>/dev/null; then
        cat << 'EOF' >> "$gradle_props"

# === macOS Dev VM Gradle Speedups ===
org.gradle.daemon=true
org.gradle.parallel=true
org.gradle.caching=true
org.gradle.configuration-cache=true
org.gradle.jvmargs=-Xmx2048m -XX:+UseParallelGC -XX:MaxMetaspaceSize=512m -XX:+HeapDumpOnOutOfMemoryError
# === End macOS Dev VM Gradle Speedups ===
EOF
        log_success "Gradle options appended to $gradle_props."
    else
        log_info "Gradle options already present in $gradle_props."
    fi
    
    if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        for config in "${shell_configs[@]}"; do
            chown "$SUDO_USER" "$config" 2>/dev/null || true
        done
        chown -R "$SUDO_USER" "$gradle_dir" 2>/dev/null || true
    fi
fi

# ------------------------------------------------------------------------------
# 3. Hardware & Graphics UI Optimizations (Motion & Transparency)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD_CYAN}[3/6] Optimizing macOS UI Performance for Guest VM...${NC}"
log_info "disabling animations, motion, and transparency effects to minimize GPU overhead..."

# Accessibility (Reduce Motion & Reduce Transparency)
user_defaults write com.apple.Accessibility ReduceMotionEnabled -bool true
user_defaults write com.apple.Accessibility ReduceTransparencyEnabled -bool true

# Global Window Transitions & Speedups
user_defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false
user_defaults write NSGlobalDomain NSWindowResizeTime -float 0.001
user_defaults write NSGlobalDomain NSWindowAnimateTransformReps -bool false
user_defaults write NSGlobalDomain NSScrollAnimationEnabled -bool false

# Finder Transitions
user_defaults write com.apple.finder DisableAllAnimations -bool true

# Dock & Mission Control
user_defaults write com.apple.dock launchanim -bool false
user_defaults write com.apple.dock expose-animation-duration -float 0.1
user_defaults write com.apple.dock com.apple.dock.launchpad.gesture.showgesture -bool false

# --- Dock Optimization & Cleanup (Interactive) ---
echo -e "\n  ${BOLD_PURPLE}Dock Optimization & Cleanup Choices:${NC}"
echo -e "    1) Keep existing Dock settings (default)"
echo -e "    2) Show active/running apps ONLY (hides pinned icons, clean & reversible)"
echo -e "    3) Clear all pinned apps from Dock (wipes persistent default icons permanently)"
echo -e "    4) Reset Dock to macOS factory defaults"
read -p "  Enter your choice (1-4) [1]: " dock_choice
dock_choice=${dock_choice:-1}

case "$dock_choice" in
    2)
        log_info "Configuring Dock to display active/running apps only..."
        user_defaults write com.apple.dock static-only -bool true
        ;;
    3)
        log_info "Clearing all persistent pinned apps from Dock..."
        user_defaults write com.apple.dock persistent-apps -array
        ;;
    4)
        log_info "Resetting Dock to macOS factory defaults..."
        user_defaults delete com.apple.dock
        ;;
    *)
        log_info "Keeping existing Dock configuration."
        ;;
esac

# Ask to enable Instant Auto-Hide to reclaim VM screen space
read -p "  Would you like to enable Instant Auto-Hide for the Dock? (y/N) [n]: " run_autohide
run_autohide=$(echo "$run_autohide" | tr '[:upper:]' '[:lower:]')
if [[ "$run_autohide" == "y" || "$run_autohide" == "yes" ]]; then
    log_info "Enabling Instant Auto-Hide (0s delay, 0s animation duration)..."
    user_defaults write com.apple.dock autohide -bool true
    user_defaults write com.apple.dock autohide-delay -float 0
    user_defaults write com.apple.dock autohide-time-modifier -float 0
fi

# Restart UI-related processes to apply changes immediately
log_info "Restarting Finder, Dock, and System UI Server to apply optimizations..."
for app in "Finder" "Dock" "SystemUIServer"; do
    user_killall "$app"
done
log_success "UI performance enhancements and Dock configurations successfully applied."

# ------------------------------------------------------------------------------
# 4. Deep OS Performance Tuning & Service Disabling
# ------------------------------------------------------------------------------
echo -e "\n${BOLD_CYAN}[4/6] Tuning Deep Operating System Services...${NC}"

# --- Spotlight Indexing (Interactive) ---
echo -e "\n  ${BOLD_PURPLE}Spotlight Indexing Suppression:${NC}"
echo -e "    Spotlight indexing is highly intensive during compiles (scans new build artifacts)."
echo -e "    Disabling indexing globally saves massive CPU and SSD write overhead."
read -p "  Would you like to globally disable Spotlight indexing? (y/N) [n]: " run_spotlight
run_spotlight=$(echo "$run_spotlight" | tr '[:upper:]' '[:lower:]')
if [[ "$run_spotlight" == "y" || "$run_spotlight" == "yes" ]]; then
    if [ "$EUID" -eq 0 ]; then
        log_info "Globally disabling Spotlight indexing and purging metadata caches..."
        mdutil -a -i off &>/dev/null || true
        mdutil -a -E &>/dev/null || true
        log_success "Spotlight indexing disabled globally."
    else
        log_warning "Bypassing Spotlight suppression: Must run as root (sudo)."
    fi
fi

# --- Background Services Disable (Interactive) ---
echo -e "\n  ${BOLD_PURPLE}Background Services Optimization:${NC}"
echo -e "    In a guest VM, many background services loop trying to access hardware"
echo -e "    or waste CPU/RAM. We can persistently disable them."
read -p "  Would you like to disable non-essential services (Siri, Telemetry, Game Center, Handoff, iCloud, thermalmonitord)? (y/N) [n]: " run_services
run_services=$(echo "$run_services" | tr '[:upper:]' '[:lower:]')
if [[ "$run_services" == "y" || "$run_services" == "yes" ]]; then
    if [ "$EUID" -eq 0 ]; then
        user_uid=$(get_user_uid)
        
        log_info "Disabling guest VM thermal monitoring loop (thermalmonitord)..."
        launchctl bootout system/com.apple.thermalmonitord &>/dev/null || true
        launchctl disable system/com.apple.thermalmonitord &>/dev/null || true
        
        log_info "Disabling Siri & voice assistant services..."
        for svc in assistantd assistant_service assistant_cdmd siriactionsd siriinferenced siriknowledged sirittsd; do
            launchctl bootout gui/$user_uid/com.apple.$svc &>/dev/null || true
            launchctl disable gui/$user_uid/com.apple.$svc &>/dev/null || true
        done
        user_defaults write com.apple.Siri AssistantEnabled -bool false
        
        log_info "Disabling system-level diagnostics & telemetry..."
        for svc in SubmitDiagInfo ReportCrash.Root analyticsd diagnosticd diagnosticservicesd logd_reporter signpost.signpost_reporter bosreporter; do
            launchctl bootout system/com.apple.$svc &>/dev/null || true
            launchctl disable system/com.apple.$svc &>/dev/null || true
        done
        for svc in ReportCrash diagnostics_agent diagnosticspushd diagnosticextensionsd appleseed.fbahelperd pluginkit.pkreporter; do
            launchctl bootout gui/$user_uid/com.apple.$svc &>/dev/null || true
            launchctl disable gui/$user_uid/com.apple.$svc &>/dev/null || true
        done
        defaults write /Library/Preferences/com.apple.SubmitDiagInfo SubmitDiagInfo -bool false &>/dev/null || true
        
        log_info "Disabling Game Center & controller daemons..."
        launchctl bootout system/com.apple.gamepolicyd &>/dev/null || true
        launchctl disable system/com.apple.gamepolicyd &>/dev/null || true
        launchctl bootout system/com.apple.GameController.gamecontrollerd &>/dev/null || true
        launchctl disable system/com.apple.GameController.gamecontrollerd &>/dev/null || true
        for svc in gamed gamesaved GameController.gamecontrolleragentd; do
            launchctl bootout gui/$user_uid/com.apple.$svc &>/dev/null || true
            launchctl disable gui/$user_uid/com.apple.$svc &>/dev/null || true
        done
        
        log_info "Disabling sharing, Handoff & AirPlay receiver..."
        launchctl bootout gui/$user_uid/com.apple.sharingd &>/dev/null || true
        launchctl disable gui/$user_uid/com.apple.sharingd &>/dev/null || true
        user_defaults -currentHost write com.apple.controlcenter.plist AirplayRecieverEnabled -bool false
        user_defaults write com.apple.coreservices.useractivityd ClipboardSharingEnabled -bool false
        user_defaults write com.apple.coreservices.useractivityd HandoffEnabled -bool false
        
        log_info "Disabling iCloud syncing & map daemons..."
        for svc in cloudpaird cloudphotod icloudmailagent icloudwebd itunescloudd Maps.mapssyncd maps.destinationd icloud.findmydeviced.findmydevice-user-agent icloud.searchpartyuseragent; do
            launchctl bootout gui/$user_uid/com.apple.$svc &>/dev/null || true
            launchctl disable gui/$user_uid/com.apple.$svc &>/dev/null || true
        done
        launchctl bootout system/com.apple.icloud.findmydeviced &>/dev/null || true
        launchctl disable system/com.apple.icloud.findmydeviced &>/dev/null || true
        launchctl bootout system/com.apple.icloud.searchpartyd &>/dev/null || true
        launchctl disable system/com.apple.icloud.searchpartyd &>/dev/null || true
        
        log_success "Background services optimized persistently."
    else
        log_warning "Bypassing background services: Must run as root (sudo)."
    fi
fi

# --- Automatic Updates (Interactive) ---
echo -e "\n  ${BOLD_PURPLE}Automatic Software Updates:${NC}"
read -p "  Would you like to suppress background software update checks? (y/N) [n]: " run_updates
run_updates=$(echo "$run_updates" | tr '[:upper:]' '[:lower:]')
if [[ "$run_updates" == "y" || "$run_updates" == "yes" ]]; then
    if [ "$EUID" -eq 0 ]; then
        log_info "Disabling automatic background updates..."
        defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
        defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
        defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool false
        defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false
        log_success "Automatic update daemon checks disabled."
    else
        log_warning "Bypassing update suppression: Must run as root (sudo)."
    fi
fi

# ------------------------------------------------------------------------------
# 5. Local APFS Snapshots Purge (Time Machine)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD_CYAN}[5/6] Reclaiming Time Machine Local Snapshots...${NC}"

# Check for local snapshots on the root volume
snapshots=$(tmutil listlocalsnapshotdates / 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' || true)

if [ -n "$snapshots" ]; then
    count=$(echo "$snapshots" | wc -l | tr -d ' ')
    echo -e "  • Found ${YELLOW}${count}${NC} local APFS snapshot(s). Purging..."
    
    while read -r snapshot_date; do
        if [ -n "$snapshot_date" ]; then
            echo -n "    • Deleting snapshot: ${snapshot_date}... "
            if sudo tmutil deletelocalsnapshots "$snapshot_date" &>/dev/null; then
                echo -e "${GREEN}Done${NC}"
            else
                echo -e "${RED}Failed (sudo may be required)${NC}"
            fi
        fi
    done <<< "$snapshots"
    log_success "All local snapshots processed!"
else
    log_success "No local APFS snapshots found. Clean!"
fi

# ------------------------------------------------------------------------------
# 6. Disk Zero-Filling (APFS and HFS+ compatible fallbacks)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD_CYAN}[6/6] Reclaiming Unused Disk Space (Zero-Filling)...${NC}"
echo -e "  ${YELLOW}Warning: Zero-filling writes zeroes to all unused sectors on your drive.${NC}"
echo -e "  This allows the host VM app to shrink the virtual disk image on your physical SSD."
echo -e "  This step can take several minutes depending on your virtual drive's size.\n"

read -p "  Would you like to perform disk zero-filling now? (y/N): " run_zero
run_zero=$(echo "$run_zero" | tr '[:upper:]' '[:lower:]')

if [[ "$run_zero" == "y" || "$run_zero" == "yes" ]]; then
    root_device=$(df / | tail -1 | awk '{print $1}')
    root_volume=$(df / | tail -1 | awk '{print $NF}')
    fs_type=$(diskutil info / 2>/dev/null | grep "Type (Bundle):" | awk '{print $3}' || echo "apfs")
    
    echo -e "  • Active Root Device: ${BOLD_BLUE}${root_device}${NC}"
    echo -e "  • Active Mount Point: ${BOLD_BLUE}${root_volume}${NC}"
    echo -e "  • File System Type:   ${BOLD_BLUE}${fs_type}${NC}"
    
    available_kb=$(df -k / | tail -1 | awk '{print $4}')
    available_gb=$(echo "scale=2; $available_kb / 1024 / 1024" | bc 2>/dev/null || awk "BEGIN {print $available_kb/1024/1024}")
    echo -e "  • Available Free Space to Zero-fill: ${BOLD_GREEN}${available_gb} GB${NC}"
    
    if [[ $(echo "$fs_type" | tr '[:upper:]' '[:lower:]') == *"apfs"* || -z "$fs_type" ]]; then
        echo -e "\n  ⌛ APFS filesystem detected. Running safe APFS-compatible zero-fill..."
        echo -e "  ${YELLOW}Note: Your host machine's physical disk must have enough space if the VM's disk is thin-provisioned!${NC}"
        
        zero_file="/var/tmp/zero.fill"
        echo -e "  Writing zeros to: ${zero_file}..."
        
        if ! dd if=/dev/zero of="$zero_file" bs=1M 2>/dev/null; then
            echo -e "  Disk fully zero-filled (expected 'No space left' limit reached)."
        fi
        
        echo -n "  Synchronizing disk writes... "
        sync && sleep 2 && sync
        echo -e "${GREEN}Done${NC}"
        
        echo -n "  Removing temporary zero-fill file... "
        rm -f "$zero_file"
        sync && sleep 2 && sync
        echo -e "${GREEN}Done${NC}"
        
        log_success "APFS Zero-filling completed successfully!"
    else
        echo -e "\n  ⌛ HFS+ filesystem detected. Running traditional diskutil secureErase..."
        if diskutil secureErase freespace 0 "$root_volume"; then
            log_success "HFS+ Zero-filling completed successfully!"
        else
            log_error "Failed traditional zero-filling."
        fi
    fi
else
    log_warning "Skipped zero-filling."
fi

# --- Summary Instructions ---
echo -e "\n${BOLD_BLUE}======================================================================${NC}"
echo -e "${BOLD_GREEN}✨  Guest-side VM Cleanup & Optimization Complete!  ✨${NC}"
echo -e "${BOLD_BLUE}======================================================================${NC}"
echo -e "Next steps to compress the disk file on your host machine:\n"

echo -e "  1. Shut down this VM completely."
echo -e "  2. Run compaction on your Mac host machine depending on your hypervisor:\n"

echo -e "  📦 ${BOLD_PURPLE}UTM (QEMU):${NC}"
echo -e "     • CLI: Locate the disk image (typically inside the '.utm' bundle image folder)"
echo -e "       and convert/shrink it using qemu-img on your Mac host:"
echo -e "       ${CYAN}qemu-img convert -O qcow2 data.qcow2 data_shrunk.qcow2${NC}"
echo -e "       Then replace 'data.qcow2' with your new 'data_shrunk.qcow2'."
echo -e "     • GUI: Go to VM Settings -> Drives -> select your drive -> click ${CYAN}Compress${NC}."
echo -e ""
echo -e "  📦 ${BOLD_PURPLE}Tart (Apple Virtualization):${NC}"
echo -e "     • Tart manages disks as APFS sparse files. Space is reclaimed naturally"
echo -e "       by macOS once the zero-filled file is removed inside the guest."
echo -e "     • To force APFS compaction on the host disk immediately, clone the VM:"
echo -e "       ${CYAN}tart clone <vm-name> <new-vm-name>${NC} (which writes a fresh, sparse disk image)"
echo -e "       Then delete the original VM with: ${CYAN}tart delete <vm-name>${NC}"
echo -e ""
echo -e "  📦 ${BOLD_PURPLE}VMware Fusion:${NC}"
echo -e "     • GUI: In the VM Library, right-click the VM -> select ${CYAN}Settings${NC} ->"
echo -e "       select ${CYAN}General${NC} -> click ${CYAN}Clean Up Virtual Machine${NC}."
echo -e "     • CLI: Use the VMware disk manager tool on your host:"
echo -e "       ${CYAN}/Applications/VMware\\ Fusion.app/Contents/Library/vmware-vdiskmanager -k disk.vmdk${NC}"
echo -e ""
echo -e "  📦 ${BOLD_PURPLE}Parallels Desktop:${NC}"
echo -e "     • GUI: Go to VM Settings -> ${CYAN}Hardware${NC} -> ${CYAN}Hard Disk${NC} -> click ${CYAN}Reclaim...${NC}"
echo -e "     • Automation: Enable ${CYAN}'Reclaim disk space on shutdown'${NC} in the Hard Disk"
echo -e "       settings tab to automate this process on every VM shutdown."
echo -e "${BOLD_BLUE}======================================================================${NC}"
