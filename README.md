# HeimAudio

Control the audio of a computer in your home network from your iPhone, and listen to it live.

- Volume and mute
- Play/pause, next and previous track (like the media keys on the keyboard)
- Open web pages (e.g. YouTube) in the computer's browser, and save links for later
- List and close the open browser tabs
- **Live audio**: stream whatever the computer is playing to the iPhone, also with the screen locked.
  Uncompressed over Wi-Fi, AAC (about 45 MB per hour) over cellular
- AirPods, lock screen, Control Center and CarPlay ("Now Playing") control the computer while the live audio runs

Works with **macOS** and **Linux** (tested on Arch Linux with Hyprland and PipeWire). The app's user interface is in German.

```
iPhone (app) ──VPN──▶ home router ──▶ computer (HeimAudio service, port 8765)
```

From outside, the app reaches the computer through a VPN into your home network
(e.g. WireGuard on a FRITZ!Box). The service itself is never exposed to the internet.

## How it works

| Part | What it does |
|---|---|
| `iOS/` | SwiftUI app (iOS 17+). Talks to the service over HTTP with a secret key. |
| `Rechner/heimaudio.py` | The service on the computer. Python 3 standard library only, no extra packages. |
| `Rechner/mac-helfer/` | Small Swift helper for macOS: media keys, system audio capture (ScreenCaptureKit), AAC encoding, autostart. |
| `Rechner/linux/` | Linux autostart (systemd user service), plus a Brave extension and a native messaging bridge for the tab list. |
| `iOS/Icon/` | Script that draws the app icon drafts. |

On macOS, the service uses AppleScript for volume and browser tabs and the helper for everything else.
On Linux it uses `wpctl` (PipeWire), `playerctl` (MPRIS), `xdg-open` and `ffmpeg`.

## Setup on the Mac

1. Build the helper (once, and again after changes to `main.swift`):

   ```bash
   Rechner/mac-helfer/bauen.sh
   ```

   It is signed with your Apple Development certificate if you have one. That way macOS keeps
   the permissions after rebuilding.

2. Set up the autostart. macOS then starts the service at every login and restarts it after a crash:

   ```bash
   Rechner/autostart-einrichten.sh
   ```

3. macOS asks for permissions for **heimaudio-helfer** the first time they are needed
   (*System Settings → Privacy & Security*):
   - **Accessibility**: media keys (play/pause, next, previous)
   - **Screen & System Audio Recording**: live audio
   - **Automation → Brave Browser / Google Chrome**: list of open tabs

   After granting a permission, restart the service:

   ```bash
   launchctl kickstart -k gui/$(id -u)/com.heimaudio.service
   ```

4. Address, port and key are in the log `~/Library/Logs/heimaudio.log`. Enter them in the app.

Remove the autostart with `Rechner/autostart-entfernen.sh`.

To run the service by hand instead (permissions are then asked for the Terminal):

```bash
python3 Rechner/heimaudio.py              # real system audio
python3 Rechner/heimaudio.py --test-tone  # beep every second instead, for testing
```

## Setup on Linux (Arch with Hyprland)

1. Install the programs:

   ```bash
   sudo pacman -S --needed python ffmpeg playerctl wireplumber pipewire-pulse xdg-utils
   ```

2. Copy the `Rechner` folder to the computer, e.g. to `~/heimaudio`.

3. Set up the autostart (also checks that everything is installed):

   ```bash
   ~/heimaudio/linux/autostart-einrichten.sh
   ```

   "Open web page" needs the graphical session. If the script asks for it, add this line to
   `~/.config/hypr/hyprland.conf` and log in again:

   ```
   exec-once = dbus-update-activation-environment --systemd --all
   ```

4. Show address, port and key:

   ```bash
   journalctl --user -u heimaudio -n 20
   ```

Remove it with `~/heimaudio/linux/autostart-entfernen.sh`.

### Open tabs on Linux (Brave)

Linux has no AppleScript, so a small browser extension provides the tabs:

```
app ──▶ heimaudio.py ──brave.sock──▶ brave-bruecke.py ◀──native messaging──▶ extension "HeimAudio Tabs"
```

1. Register the bridge with Brave:

   ```bash
   ~/heimaudio/linux/tabs-einrichten.sh
   ```

2. Load the extension once: open `brave://extensions`, turn on **Developer mode**,
   choose **Load unpacked** and select `~/heimaudio/linux/brave-erweiterung`.

3. While Brave is running, `~/.config/heimaudio/brave.sock` exists.

The extension may read the titles and addresses of your tabs and close tabs, nothing else.
It only talks to the bridge, and only your user can open the socket. Private windows are not visible to it.
After updating the extension files, click reload (⟳) on the extension in `brave://extensions`.
Remove it with `~/heimaudio/linux/tabs-entfernen.sh` and remove the extension in Brave.

## The iPhone app

1. Open `iOS/HeimAudio.xcodeproj` in Xcode.
2. Under *Signing & Capabilities*, choose your own team and, if needed, change the bundle identifier.
3. Connect the iPhone, select it as the run destination and press ⌘R.

A free Apple ID is enough to install the app on your own iPhone (it then has to be reinstalled every 7 days).

In the app's settings, add one entry per computer with address, port and key.
With more than one computer, a picker at the top switches between them.

### AirPods, lock screen and CarPlay

While the live audio is running, the app is the "Now Playing" app:

| Control | Effect on the computer |
|---|---|
| press once | play / pause |
| press twice / three times | next / previous track |
| take out an AirPod | pause (only if something is playing) |
| AirPods disconnected, headphones unplugged | pause, and the live audio stops |

The app tells from the incoming audio whether the computer is playing something. When it is silent,
the app pauses its own output too, so iOS shows "paused" and the next press resumes playback.
Pressing and holding an AirPod is reserved by iOS (noise control or Siri) and never reaches apps.

In the car, the live audio shows up under "Now Playing" in CarPlay and reacts to the steering wheel buttons.
A dedicated CarPlay app would need the CarPlay audio entitlement from Apple.

## Remote access

The app uses the same address at home and on the go. Outside your home network, turn on the
VPN to your router first (e.g. the WireGuard app with a FRITZ!Box "single device" connection).

## Security

- Every request needs the secret key (`Authorization: Bearer <key>`), compared in constant time.
  The key is in `~/.config/heimaudio/key` (readable only by you). Create a new one with
  `python3 heimaudio.py --new-key` and enter it in the app again.
- "Open web page" only accepts `http://` and `https://` addresses.
- Traffic between app and service is plain HTTP. Only use it inside your home network and the VPN.
  **Do not forward the port on your router.**

## API

All requests need the header `Authorization: Bearer <key>`. Errors return `{"error": "message"}`.

| Request | Body / parameters | Response |
|---|---|---|
| `GET /api/status` | | `{"computer", "system", "volume", "muted"}` |
| `POST /api/volume` | `{"value": 0–100}` | status |
| `POST /api/mute` | `{"muted": true\|false}` | status |
| `POST /api/media-key` | `{"key": "play"\|"next"\|"previous"}` | status |
| `POST /api/open` | `{"url": "https://…"}` | status |
| `GET /api/audio` | optional `?format=aac&kbit=96` | endless stream, header `X-Format: s16le` (16-bit PCM, 48 kHz, stereo) or `aac-adts` |
| `GET /api/tabs` | | `{"tabs": [{"browser", "id", "title", "url", "window", "active"}]}` |
| `POST /api/close-tab` | `{"browser", "id"}` | like `/api/tabs` |

## Notes

- Open tabs: macOS supports Brave and Google Chrome, Linux only Brave.
- On macOS, the media keys go to whichever app macOS considers the current player.
  If no player is open, macOS may start the Music app.
- Earlier versions of the app stored their data under German names. The app migrates it automatically
  on first start (`LegacyStoreMigration.swift`).

## License

MIT, see [LICENSE](LICENSE).
