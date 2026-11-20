#!/bin/sh
# Stops the HeimAudio service on Linux and removes the autostart.
systemctl --user disable --now heimaudio.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/heimaudio.service"
systemctl --user daemon-reload
echo "Autostart entfernt. Der Dienst läuft nicht mehr."
