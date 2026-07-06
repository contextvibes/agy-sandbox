#!/usr/bin/env bash
set -euo pipefail

echo "🍏 Starting macOS Aesthetic Transformation (XFCE Rice) for user nixos..."

# 1. Ensure directories exist
mkdir -p /home/nixos/.config/autostart
mkdir -p /home/nixos/.config/plank/dock1/launchers

# 2. Setup GTK & Window Manager Theme (WhiteSur-Dark and WhiteSur-dark icons)
echo "[INFO] Configuring XFCE themes via xfconf..."
xfconf-query -c xsettings -p /Net/ThemeName -s "WhiteSur-Dark" || xfconf-query -c xsettings -p /Net/ThemeName -n -t string -s "WhiteSur-Dark"
xfconf-query -c xsettings -p /Net/IconThemeName -s "WhiteSur-dark" || xfconf-query -c xsettings -p /Net/IconThemeName -n -t string -s "WhiteSur-dark"
xfconf-query -c xfwm4 -p /general/theme -s "WhiteSur-Dark" || xfconf-query -c xfwm4 -p /general/theme -n -t string -s "WhiteSur-Dark"

# 3. Setup macOS Window Control Button Layout (Close, Minimize, Maximize on the left)
echo "[INFO] Configuring macOS window button layout..."
xfconf-query -c xfwm4 -p /general/button_layout -s "CHM|" || xfconf-query -c xfwm4 -p /general/button_layout -n -t string -s "CHM|"

# 4. Move Panel 1 (Top Panel) to Top and Delete Panel 2 (Bottom Panel) to clear space for Plank
echo "[INFO] Configuring main panel position to Top..."
# Make panel 1 thin, semi-transparent, and set to top (should already be there, but lock it in)
xfconf-query -c xfce4-panel -p /panels/panel-1/position -s "p=6;x=0;y=0" || true

# Check if panel-2 exists, and if so, delete it
if xfconf-query -c xfce4-panel -p /panels/panel-2/position -v >/dev/null 2>&1; then
    echo "[INFO] Removing default bottom panel-2 to make room for Plank dock..."
    xfconf-query -c xfce4-panel -p /panels/panel-2 --reset --recursive || true
    # Remove panel-2 from the active panels list (reset list array to only contain 1)
    xfconf-query -c xfce4-panel -p /panels -t int -s 1 -a || true
fi

# 5. Configure Autostart for Plank
echo "[INFO] Creating Plank autostart shortcut..."
cat <<EOF > /home/nixos/.config/autostart/plank.desktop
[Desktop Entry]
Encoding=UTF-8
Version=0.9.4
Type=Application
Name=Plank
Comment=Sleek macOS dock
Exec=plank
OnlyShowIn=XFCE;
StartupNotify=false
Terminal=false
Hidden=false
EOF
chmod +x /home/nixos/.config/autostart/plank.desktop

# 6. Configure Plank Dock Settings
echo "[INFO] Configuring Plank settings..."
cat <<EOF > /home/nixos/.config/plank/dock1/settings
[Dock1]
# The double-value scale for zoom-percent.
ZoomPercent=135
# Whether to double-value scale the dock items.
ZoomEnabled=true
# The size of dock icons (48px looks crisp)
IconSize=48
# The position of the dock on the screen (3 = bottom)
Position=3
# The hide-mode of the dock (1 = intelligent hide)
HideMode=1
# The name of the theme (Matte or Transparent)
Theme=Matte
EOF

# 7. Setup Default Launchers in Plank
echo "[INFO] Adding default apps to Plank dock..."
# Clear any existing launchers
rm -f /home/nixos/.config/plank/dock1/launchers/*.dockitem

# Helper to create launcher items
create_launcher() {
    local name=$1
    local desktop_path=$2
    cat <<EOF2 > "/home/nixos/.config/plank/dock1/launchers/${name}.dockitem"
[PlankDockItemPreferences]
Launcher=file://${desktop_path}
EOF2
}

# Add terminal, Antigravity Desktop, and Antigravity IDE
create_launcher "terminal" "/run/current-system/sw/share/applications/xfce4-terminal.desktop"
create_launcher "antigravity" "/home/nixos/Desktop/antigravity.desktop"
create_launcher "antigravity-ide" "/home/nixos/Desktop/antigravity-ide.desktop"

# Ensure permissions and ownership are correct
chown -R nixos:users /home/nixos/.config/autostart /home/nixos/.config/plank

# 8. Set a beautiful macOS dark mode wallpaper if it exists or download/reference one
echo "[INFO] Setting a clean, sleek dark background..."
# XFCE default desktop setting
xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor0/workspace0/color-style -s "0" || true # Solid color
xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor0/workspace0/rgba1 -t double -s "0.1" -t double -s "0.1" -t double -s "0.12" -t double -s "1.0" || true # Elegant near-black (macOS dark style)

# 9. Apply changes instantly by restarting panel and window manager
if pgrep xfce4-session >/dev/null; then
    echo "[INFO] Restarting window components to apply themes instantly..."
    DISPLAY=:0.0 xfce4-panel --restart >/dev/null 2>&1 &
    DISPLAY=:0.0 xfwm4 --replace >/dev/null 2>&1 &
    # Launch plank if not already running in the session
    if ! pgrep plank >/dev/null; then
        DISPLAY=:0.0 plank >/dev/null 2>&1 &
    fi
fi

echo "🍏 [SUCCESS] macOS Transformation applied successfully!"
