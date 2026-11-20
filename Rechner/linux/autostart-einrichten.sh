#!/bin/sh
# Sets up the HeimAudio service on Linux as a systemd user service:
# it starts with your login and restarts by itself after a crash.
# Safe to run several times.
set -e
SERVICE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"

# Check required programs
MISSING=""
for program in python3 ffmpeg playerctl wpctl xdg-open; do
    command -v "$program" >/dev/null 2>&1 || MISSING="$MISSING $program"
done
if [ -n "$MISSING" ]; then
    echo "Es fehlen:$MISSING"
    echo "Unter Arch installieren mit:"
    echo "  sudo pacman -S --needed python ffmpeg playerctl wireplumber pipewire-pulse xdg-utils"
    exit 1
fi

mkdir -p "$UNIT_DIR"
cat > "$UNIT_DIR/heimaudio.service" <<UNIT
[Unit]
Description=HeimAudio-Dienst (Fernsteuerung per iPhone)
After=pipewire.service pipewire-pulse.service wireplumber.service

[Service]
ExecStart=$(command -v python3) -u $SERVICE_DIR/heimaudio.py
Restart=always
RestartSec=3
# Service files readable only by you (the key is in the log)
UMask=0077

[Install]
WantedBy=default.target
UNIT

# Stop a service started by hand, otherwise the port is taken.
pkill -f "$SERVICE_DIR/heimaudio.py" 2>/dev/null || true
systemctl --user daemon-reload
systemctl --user enable heimaudio.service
systemctl --user restart heimaudio.service

echo "Autostart eingerichtet."
echo "Adresse, Port und Schlüssel anzeigen:  journalctl --user -u heimaudio -n 20"

# "Webseite öffnen" needs access to the Hyprland session.
if ! systemctl --user show-environment | grep -q '^WAYLAND_DISPLAY='; then
    echo
    echo "Hinweis: Damit „Webseite öffnen“ funktioniert, diese Zeile in ~/.config/hypr/hyprland.conf ergänzen"
    echo "und dich neu anmelden:"
    echo "  exec-once = dbus-update-activation-environment --systemd --all"
fi
