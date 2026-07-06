#!/usr/bin/env bash
# ==============================================================================
#  🍏 Host-Level Non-VM Customer Sandbox Bootloader
#  Spawns an interactive shell session isolated to a customer's workspace
#  on the macOS host without a VM, utilizing HOME redirection.
# ==============================================================================

set -euo pipefail

# --- Color Formatting ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

show_help() {
    echo "Usage: $(basename "$0") --customer <customer_name> [--strict]"
    echo ""
    echo "Options:"
    echo "  --customer, -c <name>   The short name of the customer (e.g. 'acme', 'example-corp')"
    echo "  --strict                Enable strict isolation: independent keys and config folders"
    echo "  -h, --help              Show this help message"
}

# --- Parse Arguments ---
CUSTOMER=""
STRICT_MODE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --customer|-c)
            CUSTOMER="$2"
            shift 2
            ;;
        --strict)
            STRICT_MODE="true"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown option $1" >&2
            show_help
            exit 1
            ;;
    esac
done

if [[ -z "${CUSTOMER}" ]]; then
    echo "Error: Missing required argument --customer <customer_name>" >&2
    show_help
    exit 1
fi

if [[ ! "${CUSTOMER}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Invalid customer name '${CUSTOMER}'. Only alphanumeric, dashes, and underscores are allowed." >&2
    exit 1
fi

CUSTOMER_DIR="/Users/Shared/${CUSTOMER}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 1. Run Setup/Initialization if Missing ---
if [[ ! -d "${CUSTOMER_DIR}" ]]; then
    log_info "Customer home directory not found. Initializing profile at ${CUSTOMER_DIR}..."
    STRICT_FLAG=""
    if [[ "${STRICT_MODE}" == "true" ]]; then
        STRICT_FLAG="--strict"
    fi
    "${SCRIPT_DIR}/isolate_home_setup.sh" "${CUSTOMER_DIR}" "Bare-Metal - ${CUSTOMER}" ${STRICT_FLAG}
fi

# --- 2. Configure Welcome Greeting Banner ---
WELCOME_BANNER="
\${BOLD}🍏 Host-Level Non-VM Customer Sandbox\${NC}
──────────────────────────────────────────────────
   • Customer Profile:    \${BOLD}${CUSTOMER}\${NC}
   • Sandbox Home:        ${CUSTOMER_DIR}
   • Isolation Mode:      \$( [[ \"${STRICT_MODE}\" == \"true\" ]] && echo -e \"\${YELLOW}STRICT\${NC} (Independent Credentials)\" || echo -e \"\${GREEN}SHARED\${NC} (Host Credentials Symlinked)\" )
──────────────────────────────────────────────────
* Type 'exit' or press Ctrl+D to return to the host environment.
"

# --- 3. Compile Sandbox Environment Variables ---
# We selectively construct a clean environment using env -i to prevent host token leakage.
# We pass through standard terminal variables and PATH, but block personal host envs.
ENV_CMDS=(
    "HOME=${CUSTOMER_DIR}"
    "PATH=${PATH}"
    "TERM=${TERM}"
    "USER=${USER}"
    "LOGNAME=${LOGNAME}"
    "SHELL=/bin/zsh"
    "AGY_SANDBOX_CUSTOMER=${CUSTOMER}"
    "AGY_SANDBOX_STRICT=${STRICT_MODE}"
)

# Pass SSH authentication socket only in shared-credential mode
if [[ "${STRICT_MODE}" == "false" ]] && [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
    ENV_CMDS+=("SSH_AUTH_SOCK=${SSH_AUTH_SOCK}")
fi

# --- 4. Zsh Profile Overrides (ZDOTDIR strategy) ---
# Create a temporary ZDOTDIR to allow custom history files and prompt decorations
# to be sourced cleanly AFTER the user's .zshrc completes loading.
ZDOT_DIR=$(mktemp -d /tmp/agy_zdot_XXXXXX)
CUSTOM_ZSHRC="${ZDOT_DIR}/.zshrc"

# Clean up ZDOTDIR after the shell session terminates
cleanup_session() {
    rm -rf "${ZDOT_DIR}"
}
trap cleanup_session EXIT INT TERM

# Construct custom .zshrc
echo "if [[ -f \"${CUSTOMER_DIR}/.zshrc\" ]]; then" > "${CUSTOM_ZSHRC}"
echo "  source \"${CUSTOMER_DIR}/.zshrc\"" >> "${CUSTOM_ZSHRC}"
echo "fi" >> "${CUSTOM_ZSHRC}"

# Append overrides
echo "echo -e \"${WELCOME_BANNER}\"" >> "${CUSTOM_ZSHRC}"
echo "export HISTFILE=\"${CUSTOMER_DIR}/.zsh_history\"" >> "${CUSTOM_ZSHRC}"
echo "export HISTSIZE=2000" >> "${CUSTOM_ZSHRC}"
echo "export SAVEHIST=2000" >> "${CUSTOM_ZSHRC}"
echo "export PROMPT=\"[agy-sandbox:${CUSTOMER}] % \"" >> "${CUSTOM_ZSHRC}"
echo "export PS1=\"[agy-sandbox:${CUSTOMER}] % \"" >> "${CUSTOM_ZSHRC}"

# --- 5. Spawn the Interactive Sandbox Shell ---
log_info "Spawning isolated shell session for: ${CUSTOMER}..."
env -i "${ENV_CMDS[@]}" ZDOTDIR="${ZDOT_DIR}" /bin/zsh -i
