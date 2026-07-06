#!/usr/bin/env bash
set -euo pipefail
# ==============================================================================
#  NixOS SPICE Display Auto-Resizer for XFCE (X11)
#  Listens for host window resize events by detecting RandR display mode updates
#  and automatically scales the desktop resolution to match.
# ==============================================================================

# Allow some time for X11/XFCE environment to fully load
sleep 3

echo "[Display Auto-Resizer] Started daemon. Monitoring display..."

last_modes=""

while true; do
    # Dynamically find the active virtual display output name (e.g., Virtual-1 or Virtual1)
    DISPLAY_OUTPUT=$(xrandr 2>/dev/null | grep -E "^Virtual-?[0-9]+ connected" | awk '{print $1}' | head -n 1)
    
    if [[ -n "${DISPLAY_OUTPUT}" ]]; then
        # Extract all available display resolution modes for this output
        current_modes=$(xrandr 2>/dev/null | sed -n "/^${DISPLAY_OUTPUT} connected/,/^[A-Za-z]/p" | grep -E "^[[:space:]]+[0-9]+x[0-9]+")
        modes_hash=$(echo "${current_modes}" | md5sum | awk '{print $1}')
        
        if [[ -z "${last_modes}" ]]; then
            last_modes="${modes_hash}"
        elif [[ "${modes_hash}" != "${last_modes}" ]]; then
            echo "[Display Auto-Resizer] Host window resize detected! Automatically adjusting resolution..."
            xrandr --output "${DISPLAY_OUTPUT}" --auto
            last_modes="${modes_hash}"
        fi
    fi
    sleep 1
done
