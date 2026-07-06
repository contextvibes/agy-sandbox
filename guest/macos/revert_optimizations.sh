#!/bin/bash
set -euo pipefail

echo "🔄 Reverting macOS Performance Optimizations to Defaults..."

# 1. Restore UI Transparency
echo "→ Restoring default UI transparency..."
defaults delete com.apple.universalaccess reduceTransparency 2>/dev/null || true

# 2. Restore UI Motion / Animations
echo "→ Restoring default motion & window animations..."
defaults delete com.apple.universalaccess reduceMotion 2>/dev/null || true
defaults delete NSGlobalDomain NSAutomaticWindowAnimationsEnabled 2>/dev/null || true

# 3. Restore window resizing / sheet modal animations
echo "→ Restoring default resize and sheet animations..."
defaults delete NSGlobalDomain NSWindowResizeTime 2>/dev/null || true

# 4. Restore Quick Look animations
echo "→ Restoring default Quick Look preview speed..."
defaults delete -g QLPanelAnimationDuration 2>/dev/null || true

# 5. Restore Finder animations
echo "→ Restoring Finder animations..."
defaults delete com.apple.finder DisableAllAnimations 2>/dev/null || true

# 6. Restore Dock autohide response and animation speed
echo "→ Restoring default Dock behavior..."
defaults delete com.apple.dock autohide-delay 2>/dev/null || true
defaults delete com.apple.dock autohide-time-modifier 2>/dev/null || true
defaults delete com.apple.dock launchanim 2>/dev/null || true

# 7. Restart affected system services
echo "🔄 Reloading Finder, Dock, and System UI Server..."
killall Finder 2>/dev/null || true
killall Dock 2>/dev/null || true
killall SystemUIServer 2>/dev/null || true

echo "✅ All settings successfully reverted to macOS system defaults."
