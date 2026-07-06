#!/usr/bin/env bash

#  🍏❄️  APFS Virtual Disk Compactor & Space Reclamation Orchestrator
#  Automates host-side sparse disk compaction using APFS fcntl hole-punching
# ==============================================================================

set -euo pipefail

# --- Color Formatting ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
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

# --- Paths & Setup ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGES_DIR="${SANDBOX_DIR}/images"
RUNNERS_DIR="${SCRIPT_DIR}/runners"

COMPACTOR_SRC="${RUNNERS_DIR}/compact_image.swift"
COMPACTOR_BIN="${RUNNERS_DIR}/compact_image"

# Print Header
echo -e "${BOLD}❄️  APFS Virtual Disk Compactor Orchestrator${NC}"
echo "──────────────────────────────────────────────────"

# --- 1. Compile / Verify Compactor ---
if [[ ! -f "${COMPACTOR_SRC}" ]]; then
    log_error "Swift compactor source not found at: ${COMPACTOR_SRC}"
    exit 1
fi

if [[ ! -f "${COMPACTOR_BIN}" || "${COMPACTOR_SRC}" -nt "${COMPACTOR_BIN}" ]]; then
    log_info "Compiling native Swift compaction utility..."
    if ! swiftc -O -parse-as-library "${COMPACTOR_SRC}" -o "${COMPACTOR_BIN}"; then
        log_error "Failed to compile ${COMPACTOR_SRC}"
        exit 1
    fi
    log_success "Compactor compiled successfully: ${COMPACTOR_BIN}"
fi

# --- Helper: Print Guest Zero-Filling Instructions ---
print_guest_instructions() {
    echo -e "\n${BOLD}📝 GUEST-SIDE PRE-REQUISITES (How to Zero-Fill before Compacting):${NC}"
    echo "──────────────────────────────────────────────────"
    echo -e "To reclaim space, the VM guest operating system must first fill empty sectors"
    echo -e "with zeroes. Run these commands INSIDE the guest VM, then shut it down:\n"
    
    echo -e "🐧 ${BOLD}❄️  Inside NixOS Guest:${NC} ${CYAN}"
    echo -e "   # 1. Fill unused space with zeroes (will exit with 'No space left' error)"
    echo -e "   sudo dd if=/dev/zero of=/zero.fill bs=1M status=progress conv=fsync || true"
    echo -e "   # 2. Delete the zero file and sync"
    echo -e "   sudo rm -f /zero.fill"
    echo -e "   sync"
    echo -e "   # 3. Shut down VM"
    echo -e "   sudo poweroff"
    echo -e "${NC}"
    
    echo -e "🍏 ${BOLD}🍎  Inside macOS Guest (or run ultimate_cleanup.sh):${NC} ${CYAN}"
    echo -e "   # 1. Run the ultimate cleanup and zero-fill script"
    echo -e "   sudo ./guest/macos/ultimate_cleanup.sh"
    echo -e "   # 2. Shut down VM"
    echo -e "   sudo halt"
    echo -e "${NC}"
    echo "──────────────────────────────────────────────────"
}

# Ensure images folder exists
if [[ ! -d "${IMAGES_DIR}" ]]; then
    log_error "Images directory not found at: ${IMAGES_DIR}"
    exit 1
fi

# Check for .img files
cd "${IMAGES_DIR}"
ALL_IMAGES=()
while IFS= read -r line; do
    [[ -n "${line}" ]] && ALL_IMAGES+=("${line}")
done < <(find . -maxdepth 1 -name "*.img" | sed 's|^\./||' | sort)
cd "${SANDBOX_DIR}"

if [[ ${#ALL_IMAGES[@]} -eq 0 ]]; then
    log_warning "No virtual disk (.img) files found in: ${IMAGES_DIR}"
    print_guest_instructions
    exit 0
fi

# --- Helper: Check if file is locked (VM is running) ---
is_file_locked() {
    local target="$1"
    # Try running compactor in dry-run mode. If it fails with flock, the file is locked!
    if ! "${COMPACTOR_BIN}" "${target}" --dry-run >/dev/null 2>&1; then
        return 0 # True (locked)
    else
        return 1 # False (unlocked)
    fi
}

# --- Helper: Format Bytes ---
format_bytes_sh() {
    local size="$1"
    if [[ $size -ge 1099511627776 ]]; then
        awk 'BEGIN {printf "%.2f TB\n", '"$size"'/1024/1024/1024/1024}'
    elif [[ $size -ge 1073741824 ]]; then
        awk 'BEGIN {printf "%.2f GB\n", '"$size"'/1024/1024/1024}'
    elif [[ $size -ge 1048576 ]]; then
        awk 'BEGIN {printf "%.2f MB\n", '"$size"'/1024/1024}'
    else
        echo "$size B"
    fi
}


# --- Helper: Compact Image ---
compact_single_image() {
    local img_name="$1"
    local path="${IMAGES_DIR}/${img_name}"
    
    echo -e "\n💎 ${BOLD}Starting Compaction for ${img_name}...${NC}"
    if is_file_locked "${path}"; then
        log_error "Skipped: Image is locked (VM is actively running!). Please stop the VM first."
        return 1
    fi
    
    "${COMPACTOR_BIN}" "${path}"
}

# --- Action Dispatcher ---
TARGET="${1:-}"

# Check for direct arguments (e.g. "./compact_disk_images.sh all" or profile/file name)
if [[ -n "${TARGET}" ]]; then
    if [[ "${TARGET}" == "all" ]]; then
        log_info "Target 'all' specified. Compacting all unlocked disk images sequentially..."
        for img in "${ALL_IMAGES[@]}"; do
            compact_single_image "${img}" || true
        done
        exit 0
    fi
    
    # Check if target is a known profile name or file name
    DISK_NAME=""
    if [[ -f "${IMAGES_DIR}/${TARGET}" ]]; then
        DISK_NAME="${TARGET}"
    elif [[ -f "${TARGET}" ]]; then
        DISK_NAME="$(basename "${TARGET}")"
        IMAGES_DIR="$(dirname "$(realpath "${TARGET}")")"
    else
        # Normalize dash to underscore for standard profile file matching
        # e.g., "example-corp" -> "example_corp"
        local norm_target="${TARGET//-/_}"
        
        # Well-known profile aliases
        if [[ "${TARGET}" == "antigravity-nixos" ]]; then
            DISK_NAME="nixos_guest.img"
        # Dynamic lookup by prefixes/suffixes in IMAGES_DIR
        elif [[ -f "${IMAGES_DIR}/nixos_${norm_target}.img" ]]; then
            DISK_NAME="nixos_${norm_target}.img"
        elif [[ -f "${IMAGES_DIR}/macos_${norm_target}.img" ]]; then
            DISK_NAME="macos_${norm_target}.img"
        elif [[ -f "${IMAGES_DIR}/macos_session_${norm_target}.img" ]]; then
            DISK_NAME="macos_session_${norm_target}.img"
        else
            # Try strip NixOS/macOS suffixes dynamically (e.g. "myproject-nixos" -> "myproject")
            local clean_target="${norm_target%_nixos}"
            clean_target="${clean_target%_macos}"
            if [[ -f "${IMAGES_DIR}/nixos_${clean_target}.img" ]]; then
                DISK_NAME="nixos_${clean_target}.img"
            elif [[ -f "${IMAGES_DIR}/macos_${clean_target}.img" ]]; then
                DISK_NAME="macos_${clean_target}.img"
            fi
        fi
        
        # Fallback to search exact list if not resolved yet
        if [[ -z "${DISK_NAME}" ]]; then
            for img in "${ALL_IMAGES[@]}"; do
                if [[ "${img}" == "${TARGET}" ]]; then
                    DISK_NAME="${img}"
                    break
                fi
            done
        fi
    fi
    
    if [[ -n "${DISK_NAME}" && -f "${IMAGES_DIR}/${DISK_NAME}" ]]; then
        compact_single_image "${DISK_NAME}"
        exit 0
    else
        log_error "Unknown target or profile: ${TARGET}"
        echo "Please provide a valid image name in 'images/', a valid NixOS profile name, 'all', or run interactively."
        exit 1
    fi
fi


# --- Interactive Mode ---
print_guest_instructions

echo -e "\n${BOLD}🔍 DETECTED VIRTUAL DISK IMAGES:${NC}"
echo -e "----------------------------------------------------------------------"
printf "%-3s | %-28s | %-10s | %-10s | %-8s\n" "ID" "Image Filename" "Logical" "Physical" "Status"
echo -e "----------------------------------------------------------------------"

declare -a IMG_MAP
idx=1
for img in "${ALL_IMAGES[@]}"; do
    img_path="${IMAGES_DIR}/${img}"
    
    # Sizes
    logical_bytes=$(stat -f "%z" "${img_path}")
    blocks=$(stat -f "%b" "${img_path}")
    physical_bytes=$(( blocks * 512 ))
    
    logical_formatted=$(format_bytes_sh "${logical_bytes}")
    physical_formatted=$(format_bytes_sh "${physical_bytes}")
    
    # Status (Locked check)
    status_str="${GREEN}Stopped${NC}"
    if is_file_locked "${img_path}"; then
        status_str="${RED}RUNNING${NC}"
    fi
    
    printf "%-3d | %-28s | %-10s | %-10s | %-8s\n" "${idx}" "${img}" "${logical_formatted}" "${physical_formatted}" "${status_str}"
    
    IMG_MAP[${idx}]="${img}"
    idx=$(( idx + 1 ))
done
echo -e "----------------------------------------------------------------------"

echo -e "\n📝 Enter the ${BOLD}ID${NC} of the disk image to compact, ${BOLD}all${NC} to do all stopped, or ${BOLD}q${NC} to quit:"
read -p "👉 Selection: " CHOICE

if [[ "${CHOICE}" == "q" || -z "${CHOICE}" ]]; then
    log_info "Exiting. No changes made."
    exit 0
elif [[ "${CHOICE}" == "all" ]]; then
    log_info "Compacting all stopped images..."
    for img in "${ALL_IMAGES[@]}"; do
        if ! is_file_locked "${IMAGES_DIR}/${img}"; then
            compact_single_image "${img}" || true
        else
            log_warning "Bypassing ${img}: VM is running."
        fi
    done
elif [[ -n "${IMG_MAP[${CHOICE}]:-}" ]]; then
    compact_single_image "${IMG_MAP[${CHOICE}]}"
else
    log_error "Invalid selection: ${CHOICE}"
    exit 1
fi
