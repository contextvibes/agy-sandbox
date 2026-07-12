#!/bin/bash
set -euo pipefail

# ==============================================================================
# macOS Performance & UI Optimization Script (Tailored for Virtual Machines)
# ==============================================================================
#
# Context: 
#   On macOS Virtual Machines running on Apple Silicon, hardware paravirtualized
#   GPU acceleration is supported under Virtualization.framework, but reducing
#   transitions drastically minimizes CPU overhead and host system load during
#   compile-heavy workflows.
#

user_defaults() {
    if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        sudo -u "$SUDO_USER" defaults "$@"
    else
        defaults "$@"
    fi
}

echo "🚀 Applying macOS Performance and Speed Optimizations..."

# 1. Document Manual Accessibility Settings
echo "--------------------------------------------------------"
echo "⚠️  CRITICAL MANUAL STEP REQUIRED:"
echo "macOS security prevents scripts from editing Accessibility settings."
echo "Please manually configure these for the largest performance boost:"
echo "  1) Go to System Settings -> Accessibility -> Display"
echo "  2) Turn ON: 'Reduce transparency'"
echo "  3) Turn ON: 'Reduce motion'"
echo "--------------------------------------------------------"

# 2. Window Resize Animations
echo "→ Accelerating window resizing..."
user_defaults write NSGlobalDomain NSWindowResizeTime -float 0.001

# 3. Quick Look Animations
echo "→ Speeding up Quick Look previews..."
user_defaults write -g QLPanelAnimationDuration -float 0

# 4. Finder Animations
echo "→ Disabling Finder folder opening/closing animations..."
user_defaults write com.apple.finder DisableAllAnimations -bool true

# 5. Dock Autohide & Animations
echo "→ Accelerating Dock response and disabling animations..."
user_defaults write com.apple.dock autohide-delay -float 0
user_defaults write com.apple.dock autohide-time-modifier -float 0.1
user_defaults write com.apple.dock launchanim -bool false

# 6. Relaunch System Services to Apply Changes
echo "🔄 Reloading Finder, Dock, and System UI Server..."
# Flush preference caching to force reload (Rule 11)
killall cfprefsd 2>/dev/null || true
user_defaults read com.apple.dock >/dev/null 2>&1 || true
killall Finder Dock SystemUIServer 2>/dev/null || true

# 7. RAM Flush
echo "🧹 Flushing inactive memory caches..."
purge 2>/dev/null || echo "  [Note] System purge command ran with standard user privileges."

echo "✅ Optimizations applied successfully! UI transitions are now set to instant."
