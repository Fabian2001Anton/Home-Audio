#!/bin/sh
# Sets up the HeimAudio service so it starts automatically at every login on the Mac
# and restarts by itself after a crash. Safe to run several times.
set -e
cd "$(dirname "$0")"
SERVICE_DIR="$(pwd)"
LABEL=com.heimaudio.service
OLD_LABEL=com.heimaudio.dienst  # name used by earlier versions
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_FILE="$HOME/Library/Logs/heimaudio.log"
DOMAIN="gui/$(id -u)"

./mac-helfer/bauen.sh

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$SERVICE_DIR/mac-helfer/heimaudio-helfer</string>
		<string>service</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<!-- Log readable only by you: it contains the key. -->
	<key>Umask</key>
	<integer>63</integer>
	<key>StandardOutPath</key>
	<string>$LOG_FILE</string>
	<key>StandardErrorPath</key>
	<string>$LOG_FILE</string>
</dict>
</plist>
PLIST
plutil -lint "$PLIST" >/dev/null

# Stop an older version of the autostart (also under its old name) ...
for label in "$OLD_LABEL" "$LABEL"; do
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
    while launchctl print "$DOMAIN/$label" >/dev/null 2>&1; do sleep 0.2; done
done
rm -f "$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
# ... and a service started by hand in the Terminal as well, otherwise the port is taken.
pkill -f "$SERVICE_DIR/heimaudio.py" 2>/dev/null || true
sleep 0.5

launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Autostart eingerichtet."
echo "Protokoll (mit Adresse, Port und Schlüssel): $LOG_FILE"
