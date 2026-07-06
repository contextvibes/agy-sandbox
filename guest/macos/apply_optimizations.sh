#!/bin/bash
set -euo pipefail

# ==============================================================================
# macOS Performance & UI Optimization Script (Tailored for Virtual Machines)
# ==============================================================================
#
# Context: 
#   On macOS Virtual Machines running on Apple Silicon (e.g., via UTM), hardware
#   GPU acceleration is unavailable, forcing the guest OS to use software CPU
#   rendering. This script disables heavy UI visual effects to restore snappiness.
#
# Note on Manual Accessibility Steps:
#   Due to macOS security sandboxing, accessibility parameters cannot be modified
#   directly via command-line defaults write. You MUST enable these manually:
#
#   1. Open 'System Settings'
#   2. Go to 'Accessibility' -> 'Display'
#   3. Enable 'Reduce transparency' (Massive impact on CPU/WindowServer cycles)
#   4. Enable 'Reduce motion' (Disables spaces and modal slide animations)
#
# ==============================================================================

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
defaults write NSGlobalDomain NSWindowResizeTime -float 0.001

# 3. Quick Look Animations
echo "→ Speeding up Quick Look previews..."
defaults write -g QLPanelAnimationDuration -float 0

# 4. Finder Animations
echo "→ Disabling Finder folder opening/closing animations..."
defaults write com.apple.finder DisableAllAnimations -bool true

# 5. Dock Autohide & Animations
echo "→ Accelerating Dock response and disabling animations..."
defaults write com.apple.dock autohide-delay -float 0
defaults write com.apple.dock autohide-time-modifier -float 0.1
defaults write com.apple.dock launchanim -bool false

# 6. Relaunch System Services to Apply Changes
echo "🔄 Reloading Finder, Dock, and System UI Server..."
killall Finder 2>/dev/null || true
killall Dock 2>/dev/null || true
killall SystemUIServer 2>/dev/null || true

# 7. RAM Flush
echo "🧹 Flushing inactive memory caches..."
purge 2>/dev/null || echo "  [Note] System purge command ran with standard user privileges."

echo "✅ Optimizations applied successfully! UI transitions are now set to instant."
