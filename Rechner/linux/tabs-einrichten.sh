#!/bin/sh
# Sets up "Offene Tabs" for Brave on Linux:
# registers the bridge (brave-bruecke.py) with Brave. Safe to run several times.
# Afterwards, load the extension itself into Brave once by hand (instructions at the end).
set -e
LINUX_DIR="$(cd "$(dirname "$0")" && pwd)"
HOSTS_DIR="$HOME/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts"
# ID of the extension (fixed by the key in brave-erweiterung/manifest.json)
EXTENSION_ID="jbacfmjagfbdmjfbhahnjnapolnjdggd"

if [ -d "$HOME/.var/app/com.brave.Browser" ] && [ ! -d "$HOME/.config/BraveSoftware/Brave-Browser" ]; then
    echo "Brave ist als Flatpak installiert. Damit funktioniert die Brücke nicht."
    echo "Bitte Brave aus dem AUR (brave-bin) verwenden."
    exit 1
fi

chmod +x "$LINUX_DIR/brave-bruecke.py"
mkdir -p "$HOSTS_DIR"
cat > "$HOSTS_DIR/com.heimaudio.brave.json" <<JSON
{
  "name": "com.heimaudio.brave",
  "description": "HeimAudio: offene Tabs für die iPhone-App",
  "path": "$LINUX_DIR/brave-bruecke.py",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
JSON

echo "Brücke bei Brave angemeldet."
echo
echo "Jetzt die Erweiterung einmalig in Brave laden:"
echo "  1. In Brave die Adresse  brave://extensions  öffnen"
echo "  2. Oben rechts den „Entwicklermodus“ einschalten"
echo "  3. „Entpackte Erweiterung laden“ und diesen Ordner wählen:"
echo "     $LINUX_DIR/brave-erweiterung"
echo
echo "Prüfen: Diese Datei muss dann existieren:  ls ~/.config/heimaudio/brave.sock"
