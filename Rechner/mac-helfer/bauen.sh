#!/bin/sh
# Compiles the Mac helper. Run once, and again after changes to main.swift.
set -e
cd "$(dirname "$0")"
swiftc -O -swift-version 5 -o heimaudio-helfer.neu main.swift

# Sign with the developer certificate from Xcode. That way macOS recognizes the program
# after rebuilding, and the permissions are kept. Keep the identifier unchanged for the same reason.
CERTIFICATE=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
if [ -n "$CERTIFICATE" ]; then
    codesign --force --sign "$CERTIFICATE" --identifier com.heimaudio.helfer heimaudio-helfer.neu
else
    echo "Hinweis: Kein Entwickler-Zertifikat gefunden. Nach jedem Bauen fragt macOS die Freigaben neu ab."
fi

# Only swap now: a running service keeps working with the old file undisturbed.
mv -f heimaudio-helfer.neu heimaudio-helfer
echo "Fertig: $(pwd)/heimaudio-helfer"
