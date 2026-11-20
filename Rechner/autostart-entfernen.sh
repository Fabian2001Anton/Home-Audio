#!/bin/sh
# Stops the automatically started HeimAudio service and removes the autostart.
for label in com.heimaudio.service com.heimaudio.dienst; do  # current and old name
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
echo "Autostart entfernt. Der Dienst läuft nicht mehr."
