#!/usr/bin/env bash

# ==============================================================================
#  Antigravity Sandbox Asset Synchronizer & Version Tracker
#  Documents, validates, and performs idempotent updates on core VM downloads.
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

# --- Resolve Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOADS_DIR="${SCRIPT_DIR}/../downloads"
mkdir -p "${DOWNLOADS_DIR}"
PYTHON_BIN="python3"


log_info "Starting Sandbox Asset Synchronizer..."
log_info "Local Downloads Directory: ${BOLD}${DOWNLOADS_DIR}${NC}"
log_info "Using Python Host: ${BOLD}$(${PYTHON_BIN} --version 2>&1)${NC}"

# ==============================================================================
#  Embedded Python Synchronizer Script
# ==============================================================================
"${PYTHON_BIN}" -  "${DOWNLOADS_DIR}" << 'EOF'
import os
import sys
import urllib.request
import urllib.error
import re
import glob
import json
import fnmatch

# Colors for Python console output
GREEN = '\033[0;32m'
YELLOW = '\033[0;33m'
BLUE = '\033[0;34m'
BOLD = '\033[1m'
NC = '\033[0m'

def log_info(msg):
    print(f"{BLUE}[INFO]{NC} {msg}")

def log_success(msg):
    print(f"{GREEN}[SUCCESS]{NC} {msg}")

def log_warning(msg):
    print(f"{YELLOW}[WARNING]{NC} {msg}")

def log_error(msg):
    print(f"\033[0;31m[ERROR]\033[0m {msg}")

downloads_dir = sys.argv[1]
arch = "arm64" if os.uname().machine == "arm64" else "amd64"

# --- 1. Document Download Sources ---
DOCUMENTATION = """
================================================================================
 OFFICIAL DOWNLOAD SOURCES DOCUMENTATION
================================================================================
1. NixOS ISO Installation Images:
   - Latest Stable (26.05 minimal ARM64): https://channels.nixos.org/nixos-26.05/latest-nixos-minimal-aarch64-linux.iso

2. macOS IPSW System Restore Images:
   - Apple Silicon Restore Catalogs: https://ipsw.me/product/Mac

3. Google Chrome:
   - macOS Stable Installer DMG: https://dl.google.com/chrome/mac/stable/GGRO/googlechrome.dmg

4. Google Antigravity Platforms:
   - Custom internal platform and IDE builds (Antigravity.dmg, Antigravity IDE.dmg)
================================================================================
"""

print(DOCUMENTATION)

# --- Fetch API Helper ---
def fetch_json(url):
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=10) as response:
            return json.loads(response.read().decode('utf-8'))
    except Exception as e:
        log_warning(f"Failed to query API ({url}): {e}")
        return None

# --- Redirect Resolver Helper ---
def get_redirect_url_and_headers(url):
    try:
        req = urllib.request.Request(url, method='HEAD', headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.geturl(), response.info()
    except Exception as e:
        log_warning(f"Failed to query headers ({url}): {e}")
        return None, None

# --- Idempotent Downloader Helper ---
def download_file(url, local_path):
    try:
        log_info(f"Downloading {os.path.basename(local_path)}...")
        log_info(f"Source URL: {url}")
        
        # Display progress without bloating logs
        last_percent = [-1]
        def report(count, block_size, total_size):
            percent = min(100, int(count * block_size * 100 / total_size)) if total_size > 0 else 0
            if percent != last_percent[0]:
                sys.stdout.write(f"\r  Download Progress: {percent}%")
                sys.stdout.flush()
                last_percent[0] = percent

        urllib.request.urlretrieve(url, local_path, reporthook=report)
        print() # New line after progress
        log_success(f"Downloaded successfully: {local_path}")
        return True
    except BaseException as e:
        log_error(f"Download failed or interrupted: {e}")
        if os.path.exists(local_path):
            try:
                os.remove(local_path)
            except Exception as remove_err:
                log_error(f"Failed to remove partial file {local_path}: {remove_err}")
        if isinstance(e, KeyboardInterrupt):
            raise
        return False

# ==============================================================================
#  TRACK AND SYNC INDIVIDUAL ASSETS
# ==============================================================================

# --- A. NixOS Installation Image ---
log_info("--------------------------------------------------")
log_info("A. Synchronizing NixOS Minimal ISO...")
nixos_channel_url = "https://channels.nixos.org/nixos-26.05/latest-nixos-minimal-aarch64-linux.iso"
nixos_resolved_url, nixos_headers = get_redirect_url_and_headers(nixos_channel_url)

if nixos_resolved_url:
    target_nixos_file = os.path.basename(nixos_resolved_url)
    target_nixos_path = os.path.join(downloads_dir, target_nixos_file)
    log_info(f"Latest NixOS ISO resolved file: {BOLD}{target_nixos_file}{NC}")
    
    if os.path.exists(target_nixos_path):
        log_success(f"NixOS is already at the latest version: {target_nixos_file}")
    else:
        if download_file(nixos_resolved_url, target_nixos_path):
            # Clean up older NixOS ISOs
            for old_file in glob.glob(os.path.join(downloads_dir, "nixos-*.iso")):
                if os.path.basename(old_file) != target_nixos_file:
                    log_info(f"Cleaning up older NixOS ISO: {os.path.basename(old_file)}")
                    os.remove(old_file)
else:
    # Fallback to local scans
    nixos_files = glob.glob(os.path.join(downloads_dir, "nixos-*.iso"))
    if nixos_files:
        log_success(f"NixOS ISO found locally: {os.path.basename(nixos_files[0])}")
    else:
        log_warning("NixOS ISO not found and could not resolve latest redirect.")

# --- B. macOS Restore Image (IPSW) ---
log_info("--------------------------------------------------")
log_info("B. Checking macOS Restore Image (IPSW)...")
ipsw_files = glob.glob(os.path.join(downloads_dir, "*.ipsw"))
if ipsw_files:
    log_success(f"macOS IPSW Restore Image found locally: {BOLD}{os.path.basename(ipsw_files[0])}{NC}")
else:
    log_warning("No macOS IPSW restore image found in downloads/ folder.")
    log_info("Note: IPSW files are ~20GB. To download one manually, go to: https://ipsw.me/product/Mac")

# --- C. Google Chrome ---
log_info("--------------------------------------------------")
log_info("C. Synchronizing Google Chrome Stable...")
chrome_dl_url = "https://dl.google.com/chrome/mac/stable/GGRO/googlechrome.dmg"
target_chrome_path = os.path.join(downloads_dir, "googlechrome.dmg")

chrome_resolved, chrome_headers = get_redirect_url_and_headers(chrome_dl_url)
if chrome_headers:
    remote_size = int(chrome_headers.get('Content-Length', 0))
    local_size = os.path.getsize(target_chrome_path) if os.path.exists(target_chrome_path) else 0
    if remote_size > 0 and local_size == remote_size:
        log_success(f"Google Chrome DMG is already at the latest version (Size matches: {local_size} bytes).")
    else:
        log_info(f"Update found for Google Chrome (Local size: {local_size}, Remote size: {remote_size}).")
        download_file(chrome_dl_url, target_chrome_path)
else:
    if os.path.exists(target_chrome_path):
        log_success("Google Chrome DMG exists locally.")
    else:
        download_file(chrome_dl_url, target_chrome_path)

# --- D. Antigravity System Installers ---
log_info("--------------------------------------------------")
log_info("D. Checking Antigravity Platform Installers...")
ide_dmg_exists = os.path.exists(os.path.join(downloads_dir, "Antigravity IDE.dmg"))
ide_tar_exists = os.path.exists(os.path.join(downloads_dir, "Antigravity IDE.tar.gz"))
platform_dmg_exists = os.path.exists(os.path.join(downloads_dir, "Antigravity.dmg"))
platform_tar_exists = os.path.exists(os.path.join(downloads_dir, "Antigravity.tar.gz"))

if ide_dmg_exists:
    log_success("Antigravity IDE installer DMG (macOS) exists.")
elif ide_tar_exists:
    log_success("Antigravity IDE installer tarball (Linux) exists.")
else:
    log_warning("Antigravity IDE installer (Antigravity IDE.dmg or Antigravity IDE.tar.gz) is missing from downloads/ folder.")

if platform_dmg_exists:
    log_success("Antigravity Core platform installer DMG (macOS) exists.")
elif platform_tar_exists:
    log_success("Antigravity Core platform installer tarball (Linux) exists.")
else:
    log_warning("Antigravity Core platform installer (Antigravity.dmg or Antigravity.tar.gz) is missing from downloads/ folder.")

# --- E. Bidirectional Downloads Audit ("Check Both Ways") ---
log_info("--------------------------------------------------")
log_info("E. Performing Bidirectional Integrity Audit (Both Ways Check)...")

# Define expected patterns and metadata
EXPECTED_SPECS = [
    {
        "name": "NixOS Minimal ISO",
        "pattern": "nixos-minimal-*.iso",
        "required": True,
        "source": "sync_downloads.sh [Section A]"
    },
    {
        "name": "macOS IPSW Restore Image",
        "pattern": "*.ipsw",
        "required": False,
        "source": "sync_downloads.sh [Section B] / Manual Download"
    },
    {
        "name": "Google Chrome Installer",
        "pattern": "googlechrome.dmg",
        "required": True,
        "source": "sync_downloads.sh [Section C]"
    },
    {
        "name": "Antigravity Platform Installer (macOS)",
        "pattern": "Antigravity.dmg",
        "required": False,
        "source": "sync_downloads.sh [Section D]"
    },
    {
        "name": "Antigravity Platform Installer (Linux/NixOS)",
        "pattern": "Antigravity.tar.gz",
        "required": False,
        "source": "sync_downloads.sh [Section D]"
    },
    {
        "name": "Antigravity IDE Installer (macOS)",
        "pattern": "Antigravity IDE.dmg",
        "required": False,
        "source": "sync_downloads.sh [Section D]"
    },
    {
        "name": "Antigravity IDE Installer (Linux/NixOS)",
        "pattern": "Antigravity IDE.tar.gz",
        "required": False,
        "source": "sync_downloads.sh [Section D]"
    },
    {
        "name": "NixOS ISO Machine Identifier",
        "pattern": "nixos-minimal-*.iso.id",
        "required": False,
        "source": "nixos_runner.swift [Generated on first run]"
    },
    {
        "name": "NixOS ISO Machine Identifier Backup",
        "pattern": "nixos-minimal-*.iso.id.bak",
        "required": False,
        "source": "nixos_runner.swift [Backup on run]"
    }
]

# 1. Scan filesystem for files in downloads/ (ignoring system files like .DS_Store)
physical_files = []
for root, dirs, files in os.walk(downloads_dir):
    for f in files:
        if f != ".DS_Store":
            rel_path = os.path.relpath(os.path.join(root, f), downloads_dir)
            physical_files.append(rel_path)

# --- Way 1: Script/Expected Assets -> Disk (Are they present?) ---
log_info("Way 1 check: Verifying physical presence of expected/tracked assets...")
missing_required = []
missing_optional = []
matched_specs_with_files = {} # pattern -> list of files

for spec in EXPECTED_SPECS:
    pattern = spec["pattern"]
    matched_files = [f for f in physical_files if fnmatch.fnmatch(f, pattern)]
    matched_specs_with_files[pattern] = matched_files
    
    if not matched_files:
        if spec["required"]:
            missing_required.append(spec)
        else:
            missing_optional.append(spec)

# Print Way 1 Summary
if not missing_required and not missing_optional:
    log_success("All expected/tracked assets (both required and optional) are physically present!")
elif not missing_required:
    log_success("All required assets are present.")
    if missing_optional:
        log_info("The following optional assets are not present on disk:")
        for spec in missing_optional:
            print(f"  - {BOLD}{spec['name']}{NC} (pattern: `{spec['pattern']}`), managed by {spec['source']}")
else:
    log_error("Missing REQUIRED assets on disk:")
    for spec in missing_required:
        print(f"  - {BOLD}{spec['name']}{NC} (pattern: `{spec['pattern']}`), managed by {spec['source']}")

# --- Way 2: Disk -> Script/Expected Assets (Are there any unmanaged/orphan files?) ---
print()
log_info("Way 2 check: Auditing all physical files against expected patterns...")
unmanaged_files = []

for f in physical_files:
    is_matched = False
    for spec in EXPECTED_SPECS:
        if fnmatch.fnmatch(f, spec["pattern"]):
            is_matched = True
            break
    if not is_matched:
        unmanaged_files.append(f)

if not unmanaged_files:
    log_success("Every physical file in the downloads folder is documented and managed by the environment!")
else:
    log_warning(f"Found {len(unmanaged_files)} unmanaged/orphan file(s) in the downloads directory:")
    for f in unmanaged_files:
        print(f"  - {BOLD}{f}{NC} (not matched by any expected download patterns)")
    log_info("If these files are necessary, please add them to the EXPECTED_SPECS list in sync_downloads.sh.")

# Print structured final report of all files and their matching specification
print()
log_info("──────────────────────────────────────────────────")
log_info("           DOWNLOADS FOLDER CONTENT STATUS        ")
log_info("──────────────────────────────────────────────────")
for spec in EXPECTED_SPECS:
    matches = matched_specs_with_files.get(spec["pattern"], [])
    status_str = f"{GREEN}PRESENT{NC}" if matches else (f"\033[0;31mMISSING (REQUIRED)\033[0m" if spec["required"] else f"{YELLOW}OPTIONAL (NOT GENERATED/DOWNLOADED){NC}")
    matched_files_str = ", ".join(matches) if matches else "N/A"
    print(f"• {BOLD}{spec['name']}{NC}")
    print(f"  - Pattern:  {spec['pattern']}")
    print(f"  - Status:   {status_str}")
    print(f"  - Files:    {matched_files_str}")
    print(f"  - Creator:  {spec['source']}")
    print()

log_success("--------------------------------------------------")
log_success("Synchronization and tracking task complete!")
log_success("--------------------------------------------------")
EOF
