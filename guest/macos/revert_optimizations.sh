#!/bin/bash
set -euo pipefail

user_defaults() {
    if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        sudo -u "$SUDO_USER" defaults "$@"
    else
        defaults "$@"
    fi
}

echo "🔄 Reverting macOS Performance Optimizations to Defaults..."

# 1. Restore UI Transparency
echo "→ Restoring default UI transparency..."
user_defaults delete com.apple.universalaccess reduceTransparency 2>/dev/null || true

# 2. Restore UI Motion / Animations
echo "→ Restoring default motion & window animations..."
user_defaults delete com.apple.universalaccess reduceMotion 2>/dev/null || true
user_defaults delete NSGlobalDomain NSAutomaticWindowAnimationsEnabled 2>/dev/null || true

# 3. Restore window resizing / sheet modal animations
echo "→ Restoring default resize and sheet animations..."
user_defaults delete NSGlobalDomain NSWindowResizeTime 2>/dev/null || true

# 4. Restore Quick Look animations
echo "→ Restoring default Quick Look preview speed..."
user_defaults delete -g QLPanelAnimationDuration 2>/dev/null || true

# 5. Restore Finder animations
echo "→ Restoring Finder animations..."
user_defaults delete com.apple.finder DisableAllAnimations 2>/dev/null || true

# 6. Restore Dock autohide response and animation speed
echo "→ Restoring default Dock behavior..."
user_defaults delete com.apple.dock autohide-delay 2>/dev/null || true
user_defaults delete com.apple.dock autohide-time-modifier 2>/dev/null || true
user_defaults delete com.apple.dock launchanim 2>/dev/null || true

# 7. Restart affected system services
echo "🔄 Reloading Finder, Dock, and System UI Server..."
# Flush preference caching to force reload (Rule 11)
killall cfprefsd 2>/dev/null || true
user_defaults read com.apple.dock >/dev/null 2>&1 || true
killall Finder Dock SystemUIServer 2>/dev/null || true

echo "✅ All settings successfully reverted to macOS system defaults."
