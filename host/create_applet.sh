#!/usr/bin/env bash
# create_applet.sh — Creates an isolated Antigravity launcher applet and pins it to the Dock.
#
# Automates the full 3-step process:
#   1. Creates the .app bundle from a template (or from scratch)
#   2. Sets CFBundleName in Info.plist
#   3. Compiles the AppleScript launcher that redirects HOME/GEMINI_HOME/user-data-dir
#   4. Optionally pins the applet to the host Dock
#
# Usage:
#   ./create_applet.sh --customer acme --home /Users/Shared/acme
#   ./create_applet.sh --customer "Example Corp" --home /Users/Shared/example-corp
#   ./create_applet.sh --customer acme --home /Users/Shared/acme --no-dock
#   ./create_applet.sh --customer acme --home /Users/Shared/acme --ide
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${HOME}/Applications"
BASE_APP="/Applications/Antigravity.app"
PIN_TO_DOCK="true"
USE_IDE="false"
CUSTOMER=""
CUSTOMER_HOME=""

show_help() {
  echo "Usage: $(basename "$0") --customer <name> --home <path> [options]"
  echo ""
  echo "Creates an isolated Antigravity launcher applet and optionally pins it to the Dock."
  echo ""
  echo "Required:"
  echo "  --customer <name>   Customer display name (e.g. 'Acme', 'Example Corp')"
  echo "  --home <path>       Path to the isolated home directory (e.g. /Users/Shared/acme)"
  echo ""
  echo "Options:"
  echo "  --ide               Create launcher for Antigravity IDE instead of Antigravity"
  echo "  --no-dock           Skip pinning the applet to the Dock"
  echo "  --apps-dir <path>   Directory to create the .app in (default: ~/Applications)"
  echo "  -h, --help          Show this help message"
  echo ""
  echo "Examples:"
  echo "  $(basename "$0") --customer acme --home /Users/Shared/acme"
  echo "  $(basename "$0") --customer \"Example Corp\" --home /Users/Shared/example-corp --ide"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) show_help; exit 0 ;;
    --customer) CUSTOMER="$2"; shift 2 ;;
    --home) CUSTOMER_HOME="$2"; shift 2 ;;
    --ide) USE_IDE="true"; shift ;;
    --no-dock) PIN_TO_DOCK="false"; shift ;;
    --apps-dir) APPS_DIR="$2"; shift 2 ;;
    *) echo "Error: Unknown option $1" >&2; show_help; exit 1 ;;
  esac
done

if [[ -z "$CUSTOMER" ]] || [[ -z "$CUSTOMER_HOME" ]]; then
  echo "Error: --customer and --home are required." >&2
  show_help
  exit 1
fi

# Sanitize customer name
if [[ ! "$CUSTOMER" =~ ^[a-zA-Z0-9\ _-]+$ ]]; then
  echo "Error: Customer name contains invalid characters. Use alphanumeric, spaces, hyphens, or underscores." >&2
  exit 1
fi

# Sanitize home directory path
if [[ ! "$CUSTOMER_HOME" =~ ^/[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+)*$ ]] || [[ "$CUSTOMER_HOME" == *".."* ]]; then
  echo "Error: Invalid home directory path '${CUSTOMER_HOME}'. Only clean absolute alphanumeric paths are allowed." >&2
  exit 1
fi

# Determine base app and applet name
if [[ "$USE_IDE" == "true" ]]; then
  BASE_APP="/Applications/Antigravity IDE.app"
  APPLET_NAME="Antigravity IDE ${CUSTOMER}"
  BASE_BINARY="Antigravity IDE"
else
  BASE_APP="/Applications/Antigravity.app"
  APPLET_NAME="Antigravity ${CUSTOMER}"
  BASE_BINARY="Antigravity"
fi

APPLET_PATH="${APPS_DIR}/${APPLET_NAME}.app"
CUSTOMER_HOME_ABS="$(cd "$CUSTOMER_HOME" 2>/dev/null && pwd || echo "$CUSTOMER_HOME")"

echo "==================================================="
echo "Creating Antigravity applet"
echo "  Customer:    ${CUSTOMER}"
echo "  Home:        ${CUSTOMER_HOME_ABS}"
echo "  Applet:      ${APPLET_PATH}"
echo "  Base app:    ${BASE_APP}"
echo "  Pin to Dock: ${PIN_TO_DOCK}"
echo "==================================================="

# Verify base app exists
if [[ ! -d "$BASE_APP" ]]; then
  echo "Error: Base application not found at ${BASE_APP}" >&2
  echo "Install Antigravity first." >&2
  exit 1
fi

# Create Applications directory
mkdir -p "$APPS_DIR"

# Step 1: Find a template applet or create one from scratch
TEMPLATE=""
for existing in "${APPS_DIR}"/Antigravity\ *.app; do
  if [[ -d "$existing" ]] && [[ "$existing" != "$APPLET_PATH" ]]; then
    TEMPLATE="$existing"
    break
  fi
done

if [[ -d "$APPLET_PATH" ]]; then
  echo "  [~] Applet already exists at ${APPLET_PATH}, updating..."
else
  if [[ -n "$TEMPLATE" ]]; then
    echo "  [+] Copying template from: ${TEMPLATE}"
    cp -R "$TEMPLATE" "$APPLET_PATH"
  else
    echo "  [+] Creating applet from scratch..."
    # Create minimal applet structure using osacompile (generates a proper .app bundle)
    osacompile -o "$APPLET_PATH" -e 'do shell script "echo placeholder"'
  fi
fi

# Step 2: Set CFBundleName in Info.plist
PLIST="${APPLET_PATH}/Contents/Info.plist"
if [[ -f "$PLIST" ]]; then
  plutil -replace CFBundleName -string "$APPLET_NAME" "$PLIST"
  echo "  [+] Set CFBundleName to '${APPLET_NAME}'"
else
  echo "Error: Info.plist not found at ${PLIST}" >&2
  exit 1
fi

# Step 3: Compile the launcher AppleScript
SCRIPT_PATH="${APPLET_PATH}/Contents/Resources/Scripts/main.scpt"
mkdir -p "$(dirname "$SCRIPT_PATH")"

APPLESCRIPT="do shell script \"HOME=\\\"${CUSTOMER_HOME_ABS}\\\" GEMINI_HOME=\\\"${CUSTOMER_HOME_ABS}/.gemini\\\" \\\"${BASE_APP}/Contents/MacOS/${BASE_BINARY}\\\" --user-data-dir=\\\"${CUSTOMER_HOME_ABS}/Library/Application Support/${BASE_BINARY}\\\" >/dev/null 2>&1 &\""

osacompile -o "$SCRIPT_PATH" -e "$APPLESCRIPT" 2>/dev/null || \
  osacompile -o "${APPLET_PATH}" -e "$APPLESCRIPT"

echo "  [+] Compiled launcher script"

# Step 4: Pin to Dock (optional)
if [[ "$PIN_TO_DOCK" == "true" ]]; then
  if [[ -f "${SCRIPT_DIR}/add_to_dock.py" ]]; then
    echo "  [+] Pinning to Dock..."
    python3 "${SCRIPT_DIR}/add_to_dock.py" --app "$APPLET_PATH" "$APPLET_NAME"
  else
    echo "  [!] add_to_dock.py not found, skipping Dock pinning"
  fi
fi

echo ""
echo "Done! '${APPLET_NAME}' is ready."
echo "  Launch it from: ${APPLET_PATH}"
