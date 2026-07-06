#!/usr/bin/env bash
# isolate_home_setup.sh — Configures isolated customer home directories for Antigravity
# by symlinking critical credential and configuration folders from the main home directory.

set -euo pipefail

# Dynamic home directory resolution with fallback
REAL_HOME="${HOME}"

# Default strict mode setting
STRICT_MODE="${STRICT_MODE:-false}"


setup_isolation() {
  local target_dir="$1"
  local name="$2"
  
  echo "=================================================="
  echo "Setting up isolated home environment for: $name"
  echo "Target Directory: $target_dir"
  echo "=================================================="
  
  # Ensure the target home directory, .config, .local, and Library exist
  mkdir -p "$target_dir/.config"
  mkdir -p "$target_dir/.local"
  mkdir -p "$target_dir/Library"
  
  if [ "$STRICT_MODE" = "true" ]; then
    echo "  [Strict] Configuring strict isolation: independent directories for credentials..."
    
    # 1. Independent SSH
    if [ ! -e "$target_dir/.ssh" ]; then
      mkdir -p "$target_dir/.ssh"
      chmod 700 "$target_dir/.ssh"
      touch "$target_dir/.ssh/config"
      chmod 600 "$target_dir/.ssh/config"
      echo "  [+] Created independent, empty .ssh/ directory and config"
    else
      echo "  [~] Independent .ssh/ already exists"
    fi

    # 2. Independent GnuPG
    if [ ! -e "$target_dir/.gnupg" ]; then
      mkdir -p "$target_dir/.gnupg"
      chmod 700 "$target_dir/.gnupg"
      echo "  [+] Created independent, empty .gnupg/ directory"
    else
      echo "  [~] Independent .gnupg/ already exists"
    fi

    # 3. Independent GitConfig
    if [ ! -e "$target_dir/.gitconfig" ]; then
      touch "$target_dir/.gitconfig"
      echo "  [+] Created independent, empty .gitconfig"
    else
      echo "  [~] Independent .gitconfig already exists"
    fi
    
    local items=(
      ".zshrc"
      ".zshenv"
      ".nix-profile"
    )
  else
    # Crucial configurations to symlink from the real user home
    local items=(
      ".ssh"
      ".gnupg"
      ".password-store"
      ".gitconfig"
      ".zshrc"
      ".zshenv"
      ".nix-profile"
      "Library/Keychains"
    )
  fi
  
  for item in "${items[@]}"; do
    local src="$REAL_HOME/$item"
    local dest="$target_dir/$item"
    
    if [ -e "$src" ] || [ -L "$src" ]; then
      if [ -L "$dest" ]; then
        echo "  [~] Symlink for $item already exists in $target_dir"
      elif [ -e "$dest" ]; then
        echo "  [!] Warning: A physical file/directory already exists at $dest. Skipping."
      else
        # Nix-awareness: If the source is a symlink into the Nix store, copy it instead of symlinking
        # to allow for local modifications (e.g. by gcloud or path sanitization).
        if [[ -L "$src" && "$(readlink "$src")" =~ /nix/store/ ]] && [[ "$item" =~ \.zsh(rc|env)$ ]]; then
          echo "  [*] Detected Nix-managed $item. Creating a writable copy instead of symlinking..."
          cp "$src" "$dest"
          chmod +w "$dest"
          # Path sanitization: replace hardcoded REAL_HOME with $HOME
          sed -i '' "s|${REAL_HOME}|\$HOME|g" "$dest"
          echo "    [+] Created sanitized copy at $dest"
        else
          ln -s "$src" "$dest"
          echo "  [+] Successfully symlinked $item -> $src"
        fi
      fi
    else
      echo "  [-] Skipping $item: source $src does not exist"
    fi
  done
  
  # Link critical .config subdirectories
  local config_items=()
  if [ "$STRICT_MODE" = "true" ]; then
    config_items=(
      "direnv"
      "ohmyposh"
    )
  else
    config_items=(
      "git"
      "direnv"
      "gh"
      "ohmyposh"
      "pass-git-helper"
    )
  fi
  
  for c_item in "${config_items[@]}"; do
    local src_cfg="$REAL_HOME/.config/$c_item"
    local dest_cfg="$target_dir/.config/$c_item"
    
    if [ -e "$src_cfg" ] || [ -L "$src_cfg" ]; then
      if [ -L "$dest_cfg" ]; then
        echo "  [~] Symlink for .config/$c_item already exists in $target_dir/.config"
      elif [ -e "$dest_cfg" ]; then
        echo "  [!] Warning: A physical file/directory already exists at $dest_cfg. Skipping."
      else
        ln -s "$src_cfg" "$dest_cfg"
        echo "  [+] Successfully symlinked .config/$c_item -> $src_cfg"
      fi
    else
      echo "  [-] Skipping .config/$c_item: source $src_cfg does not exist"
    fi
  done
  
  # Link local bin directory (so that agy and other home-installed CLI tools are accessible)
  local src_bin="$REAL_HOME/.local/bin"
  local dest_bin="$target_dir/.local/bin"
  
  if [ -e "$src_bin" ] || [ -L "$src_bin" ]; then
    if [ -L "$dest_bin" ]; then
      echo "  [~] Symlink for .local/bin already exists in $target_dir/.local"
    elif [ -e "$dest_bin" ]; then
      echo "  [!] Warning: A physical file/directory already exists at $dest_bin. Skipping."
    else
      ln -s "$src_bin" "$dest_bin"
      echo "  [+] Successfully symlinked .local/bin -> $src_bin"
    fi
  else
    echo "  [-] Skipping .local/bin: source $src_bin does not exist"
  fi
  
  # Optional: Share global credentials if requested
  if [ "${SHARE_CREDS:-false}" = "true" ]; then
    echo "  [+] Sharing global credentials (Keychains, GPG, Pass) as requested..."
    local cred_items=(
      "Library/Keychains"
      ".gnupg"
      ".password-store"
    )
    for cred in "${cred_items[@]}"; do
      local src_cred="$REAL_HOME/$cred"
      local dest_cred="$target_dir/$cred"
      if [ -e "$src_cred" ] && [ ! -e "$dest_cred" ]; then
        mkdir -p "$(dirname "$dest_cred")"
        ln -s "$src_cred" "$dest_cred"
        echo "    [+] Linked $cred"
      fi
    done
  fi

  # Pin Antigravity apps to the isolated home's Dock plist
  local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${script_dir}/add_to_dock.py" ]]; then
    echo "  [+] Configuring Dock icons for the environment..."
    python3 "${script_dir}/add_to_dock.py" --no-kill --plist "${target_dir}/Library/Preferences/com.apple.dock.plist"
  fi
  
  echo ""
}

show_help() {
  echo "Usage: $(basename "$0") [target_directory] [display_name] [options]"
  echo ""
  echo "Configures isolated customer home directories for Antigravity"
  echo "by symlinking critical credential and configuration folders."
  echo ""
  echo "Options:"
  echo "  -h, --help    Show this help message"
  echo "  --strict      Strict isolation: create independent folders/credentials"
  echo "                instead of symlinking host keys and profiles"
  echo "  --share-creds Symlink Keychains, GPG, and Pass store even in strict mode"
}

# Command-line routing
STRICT_MODE="false"
TARGET_DIR=""
DISPLAY_NAME=""
SHARE_CREDS="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;

    --strict)
      STRICT_MODE="true"
      shift
      ;;
    --share-creds)
      SHARE_CREDS="true"
      shift
      ;;
    -*)
      echo "Error: Unknown option $1" >&2
      show_help
      exit 1
      ;;
    *)
      if [[ -z "$TARGET_DIR" ]]; then
        TARGET_DIR="$1"
      elif [[ -z "$DISPLAY_NAME" ]]; then
        DISPLAY_NAME="$1"
      else
        echo "Error: Unexpected argument $1" >&2
        show_help
        exit 1
      fi
      shift
      ;;
  esac
done



if [[ -z "$TARGET_DIR" ]] || [[ -z "$DISPLAY_NAME" ]]; then
  echo "Error: Both [target_directory] and [display_name] are required." >&2
  echo "Run '$(basename "$0") --help' for usage details." >&2
  exit 1
fi

if [[ ! "$TARGET_DIR" =~ ^/[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+)*$ ]]; then
  echo "Error: Invalid target directory path '$TARGET_DIR'. Only safe alphanumeric, hyphen, dot, and slash characters are allowed." >&2
  exit 1
fi

if [[ ! "$DISPLAY_NAME" =~ ^[a-zA-Z0-9\ _\(\)-]+$ ]]; then
  echo "Error: Invalid display name '$DISPLAY_NAME'. Only alphanumeric, spaces, hyphens, parentheses, and underscores are allowed." >&2
  exit 1
fi


setup_isolation "$TARGET_DIR" "$DISPLAY_NAME"
echo "Custom isolation environment successfully configured."

