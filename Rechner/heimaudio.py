#!/usr/bin/env python3
"""HeimAudio service: receives commands from the iPhone app and streams the computer's audio.

Start:
    python3 heimaudio.py               real system audio
    python3 heimaudio.py --test-tone   beep instead of system audio, for trying things out

API (every request needs the header "Authorization: Bearer <key>"):
    GET  /api/status       -> {"computer", "system", "volume", "muted"}
    POST /api/volume       {"value": 0..100}
    POST /api/mute         {"muted": true|false}
    POST /api/media-key    {"key": "play"|"next"|"previous"}
    POST /api/open         {"url": "https://..."}
    GET  /api/audio        endless stream: 16-bit PCM, 48 kHz, stereo (header X-Format: s16le)
    GET  /api/audio?format=aac&kbit=96   the same as AAC with ADTS headers (X-Format: aac-adts)
    GET  /api/tabs         -> {"tabs": [{"browser", "id", "title", "url", "window", "active"}]}
    POST /api/close-tab    {"browser": "Brave Browser", "id": 123} -> same as /api/tabs
Errors: {"error": "message for the user"}
"""

from __future__ import annotations

import argparse
import collections
import hmac
import json
import os
import platform
import re
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

SAMPLE_RATE = 48000
CHANNELS = 2
CHUNK_SIZE = 8192
HERE = Path(__file__).resolve().parent
CONFIG_DIR = Path.home() / ".config" / "heimaudio"
ALLOWED_KEYS = ("play", "next", "previous")
ALLOWED_KBIT = (64, 96, 128, 160, 192)  # AAC bit rates for the data-saving audio

# AppleScript for Chromium-based browsers (Brave, Chrome).
# Separators: ASCII 31 between fields, ASCII 30 between tabs.
LIST_TABS = """
set RS to character id 30
set US to character id 31
set output to ""
tell application "{browser}"
    set windowIndex to 0
    repeat with w in windows
        set windowIndex to windowIndex + 1
        set activeId to id of active tab of w
        set ids to id of tabs of w
        set titles to title of tabs of w
        set urls to URL of tabs of w
        repeat with i from 1 to count of ids
            set output to output & (item i of ids) & US & (item i of titles) & US & (item i of urls) & US & windowIndex & US & ((item i of ids) = activeId) & RS
        end repeat
    end repeat
end tell
return output
"""

CLOSE_TAB = """
tell application "{browser}"
    repeat with w in windows
        set ids to id of tabs of w
        repeat with i from 1 to count of ids
            -- Brave returns the id as text, so compare as text
            if (item i of ids as text) = "{tab_id}" then
                close tab i of w
                return "closed"
            end if
        end repeat
    end repeat
end tell
return "not found"
"""


class ServiceError(Exception):
    """An error whose message is shown to the user in the app (therefore German)."""

    def __init__(self, message: str, status: int = 500):
        super().__init__(message)
        self.status = status


# --------------------------------------------------------------------------- Key


def load_key(new: bool = False) -> str:
    """Reads the secret key, or creates a new one on first start."""
    key_file = CONFIG_DIR / "key"
    old_key_file = CONFIG_DIR / "schluessel"  # name used by earlier versions
    if not key_file.exists() and old_key_file.exists():
        old_key_file.rename(key_file)
    if key_file.exists() and not new:
        return key_file.read_text().strip()
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    key = secrets.token_urlsafe(24)
    key_file.write_text(key + "\n")
    key_file.chmod(0o600)
    return key


# --------------------------------------------------------------------------- Operating system
# Everything that depends on the operating system lives in MacSystem or LinuxSystem.
# Both classes have the same methods.


class MacSystem:
    name = "macOS"
    BROWSERS = ("Brave Browser", "Google Chrome")

    def __init__(self, test_tone: bool = False):
        self.helper = HERE / "mac-helfer" / "heimaudio-helfer"
        self.test_tone = test_tone

    def _applescript(self, script: str, timeout: float = 5) -> str:
        try:
            result = subprocess.run(
                ["osascript", "-"], input=script, capture_output=True, text=True, timeout=timeout
            )
        except subprocess.TimeoutExpired:
            raise ServiceError("Der Rechner hat nicht rechtzeitig geantwortet", 504)
        if result.returncode != 0:
            message = result.stderr.strip()
            if "-1743" in message:  # not allowed to control the browser
                raise ServiceError(
                    "Freigabe fehlt: Systemeinstellungen > Datenschutz & Sicherheit > Automation > heimaudio-helfer",
                    503,
                )
            raise ServiceError(message or "AppleScript fehlgeschlagen")
        return result.stdout.rstrip("\n")

    def _is_running(self, program: str) -> bool:
        return subprocess.run(["pgrep", "-xq", program]).returncode == 0

    def tabs(self) -> list[dict]:
        # Only ask browsers that are already running. Otherwise AppleScript would launch them.
        found = []
        for browser in self.BROWSERS:
            if not self._is_running(browser):
                continue
            # Generous timeout: the first time, macOS waits for the user to grant permission.
            text = self._applescript(LIST_TABS.format(browser=browser), timeout=60)
            for entry in text.split("\x1e"):
                fields = entry.split("\x1f")
                if len(fields) != 5:
                    continue
                tab_id, title, url, window, active = fields
                found.append({
                    "browser": browser,
                    "id": int(tab_id),
                    "title": title,
                    "url": url,
                    "window": int(window),
                    "active": active == "true",
                })
        return found

    def close_tab(self, browser: str, tab_id: int) -> None:
        if not self._is_running(browser):
            raise ServiceError(f"{browser} läuft nicht", 404)
        answer = self._applescript(CLOSE_TAB.format(browser=browser, tab_id=int(tab_id)), timeout=60)
        if answer != "closed":
            raise ServiceError("Diesen Tab gibt es nicht mehr", 404)

    def _helper_path(self) -> str:
        if not self.helper.exists():
            raise ServiceError("Hilfsprogramm fehlt. Bitte zuerst mac-helfer/bauen.sh ausführen.", 503)
        return str(self.helper)

    def status(self) -> dict:
        volume = self._applescript("output volume of (get volume settings)")
        muted = self._applescript("output muted of (get volume settings)")
        return {
            # Some output devices (e.g. HDMI) have no adjustable volume.
            "volume": int(volume) if volume.isdigit() else None,
            "muted": muted == "true",
        }

    def set_volume(self, value: int) -> None:
        self._applescript(f"set volume output volume {value}")

    def set_muted(self, muted: bool) -> None:
        self._applescript(f"set volume output muted {'true' if muted else 'false'}")

    def media_key(self, key: str) -> None:
        result = subprocess.run([self._helper_path(), "media-key", key], capture_output=True, text=True, timeout=5)
        if result.returncode != 0:
            raise ServiceError(result.stderr.strip() or "Medientaste fehlgeschlagen", 503)

    def open_url(self, url: str) -> None:
        subprocess.run(["open", url], check=True, timeout=10)

    def audio_command(self, aac_kbit: int | None = None) -> list[str]:
        command = [self._helper_path(), "test-tone" if self.test_tone else "capture"]
        if aac_kbit:
            command += ["--aac", str(aac_kbit * 1000)]
        return command

    def addresses(self) -> list[str]:
        found = []
        for interface in ("en0", "en1", "en2"):
            result = subprocess.run(["ipconfig", "getifaddr", interface], capture_output=True, text=True)
            if result.returncode == 0 and result.stdout.strip():
                found.append(result.stdout.strip())
        return found


class LinuxSystem:
    """Linux with PipeWire (wpctl), players with an MPRIS interface (playerctl) and ffmpeg for audio.

    Required packages on Arch:
        sudo pacman -S --needed python ffmpeg playerctl wireplumber pipewire-pulse xdg-utils
    """

    name = "Linux"
    BROWSERS = ("Brave",)
    BRAVE_SOCKET = CONFIG_DIR / "brave.sock"

    def __init__(self, test_tone: bool = False):
        self.test_tone = test_tone

    def _run(self, command: list[str], timeout: float = 5) -> str:
        # Neutral locale: numbers always with a dot (0.45), never with a comma (0,45).
        # Otherwise wpctl might read "0.45" as 0 with a German locale.
        environment = {**os.environ, "LC_ALL": "C"}
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, env=environment)
        except FileNotFoundError:
            raise ServiceError(f"Programm fehlt auf dem Rechner: {command[0]}", 503)
        except subprocess.TimeoutExpired:
            raise ServiceError("Der Rechner hat nicht rechtzeitig geantwortet", 504)
        if result.returncode != 0:
            raise ServiceError(result.stderr.strip() or f"{command[0]} ist fehlgeschlagen")
        return result.stdout.strip()

    def status(self) -> dict:
        # Output e.g. "Volume: 0.45" or "Volume: 0.45 [MUTED]"
        text = self._run(["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"])
        # Search right after "Volume:": wpctl sometimes prints warnings with timestamps before it.
        number = re.search(r"Volume:\s*(\d+[.,]\d+)", text)
        volume = min(100, round(float(number.group(1).replace(",", ".")) * 100)) if number else None
        return {"volume": volume, "muted": "[MUTED]" in text}

    def set_volume(self, value: int) -> None:
        self._run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", f"{value / 100:.2f}"])

    def set_muted(self, muted: bool) -> None:
        self._run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "1" if muted else "0"])

    def media_key(self, key: str) -> None:
        command = {"play": "play-pause", "next": "next", "previous": "previous"}[key]
        try:
            self._run(["playerctl", command])
        except ServiceError as error:
            if "No players found" in str(error):
                raise ServiceError("Kein Player gefunden. Läuft gerade ein Video oder Musik?", 404)
            raise

    # A browser needs these variables to appear on the screen.
    SESSION_VARIABLES = (
        "WAYLAND_DISPLAY", "DISPLAY", "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE",
        "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS",
    )

    def _session_environment(self) -> dict:
        """Environment with the current values of the graphical session.

        The service starts at boot, before Hyprland is running. Hyprland reports its values to
        systemd later (exec-once = dbus-update-activation-environment ...). So ask freshly each
        time instead of using the environment from startup.
        """
        environment = dict(os.environ)
        try:
            text = subprocess.run(
                ["systemctl", "--user", "show-environment"], capture_output=True, text=True, timeout=3
            ).stdout
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return environment
        for line in text.splitlines():
            name, _, value = line.partition("=")
            if name in self.SESSION_VARIABLES and value:
                environment[name] = value
        return environment

    def open_url(self, url: str) -> None:
        environment = self._session_environment()
        if not environment.get("WAYLAND_DISPLAY") and not environment.get("DISPLAY"):
            raise ServiceError(
                "Der Dienst kennt die Hyprland-Sitzung nicht. In ~/.config/hypr/hyprland.conf die Zeile "
                "„exec-once = dbus-update-activation-environment --systemd --all“ ergänzen und neu anmelden.",
                503,
            )
        # Error output goes to a file instead of a pipe: a browser that is just starting writes a lot
        # and would block as soon as the pipe is full.
        with tempfile.TemporaryFile() as error_output:
            try:
                process = subprocess.Popen(
                    ["xdg-open", url],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=error_output,
                    env=environment,
                    start_new_session=True,
                )
            except FileNotFoundError:
                raise ServiceError("Programm fehlt auf dem Rechner: xdg-open", 503)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                return  # Still running: the browser was just launched. That is fine.
            if process.returncode != 0:
                error_output.seek(0)
                text = error_output.read().decode(errors="replace").strip()
                raise ServiceError(
                    text or f"Der Browser ließ sich nicht öffnen (xdg-open: Code {process.returncode})", 503
                )

    def audio_command(self, aac_kbit: int | None = None) -> list[str]:
        if self.test_tone:
            source = ["-re", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000"]
        else:
            # The "monitor" of the default output: exactly what is coming out of the speakers.
            source = ["-f", "pulse", "-fragment_size", "3840", "-i", "@DEFAULT_MONITOR@"]
        if aac_kbit:
            output = ["-c:a", "aac", "-b:a", f"{aac_kbit}k", "-f", "adts"]
        else:
            output = ["-c:a", "pcm_s16le", "-f", "s16le"]
        return [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-fflags", "nobuffer",
            *source, "-ac", str(CHANNELS), "-ar", str(SAMPLE_RATE), *output, "-flush_packets", "1", "pipe:1",
        ]

    # Open tabs: the extension linux/brave-erweiterung provides them through the bridge
    # linux/brave-bruecke.py, which Brave starts itself. Setup: linux/tabs-einrichten.sh

    def _ask_brave(self, request: dict) -> dict:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(15)
                connection.connect(str(self.BRAVE_SOCKET))
                connection.sendall(json.dumps(request).encode() + b"\n")
                with connection.makefile("rb") as incoming:
                    line = incoming.readline()
        except (FileNotFoundError, ConnectionRefusedError):
            raise ServiceError("Brave läuft nicht oder die Erweiterung „HeimAudio Tabs“ ist nicht geladen", 503)
        except socket.timeout:
            raise ServiceError("Brave hat nicht rechtzeitig geantwortet", 504)
        try:
            answer = json.loads(line)
        except ValueError:
            raise ServiceError("Keine Antwort von der Erweiterung „HeimAudio Tabs“", 503)
        if "error" in answer:
            raise ServiceError(str(answer["error"]), int(answer.get("status", 503)))
        return answer

    def tabs(self) -> list[dict]:
        return [
            {
                "browser": "Brave",
                "id": int(tab["id"]),
                "title": str(tab.get("title", "")),
                "url": str(tab.get("url", "")),
                "window": int(tab.get("window", 1)),
                "active": bool(tab.get("active")),
            }
            for tab in self._ask_brave({"type": "list"}).get("tabs", [])
        ]

    def close_tab(self, browser: str, tab_id: int) -> None:
        self._ask_brave({"type": "close", "tab": int(tab_id)})

    def addresses(self) -> list[str]:
        try:
            text = self._run(["ip", "-4", "-o", "addr", "show", "scope", "global"])
        except ServiceError:
            return []
        # Lines like "2: enp3s0    inet 192.168.178.30/24 brd ..."
        return [line.split()[3].split("/")[0] for line in text.splitlines() if len(line.split()) > 3]


# --------------------------------------------------------------------------- HTTP


class RequestHandler(BaseHTTPRequestHandler):
    server_version = "HeimAudio/1"

    def log_message(self, format: str, *args) -> None:
        sys.stderr.write(f"{self.address_string()}  {format % args}\n")

    # Helpers

    def _send_json(self, status: int, data: dict) -> None:
        body = json.dumps(data, ensure_ascii=False).encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # The app stopped waiting for the answer (e.g. switched screens).

    def _is_authorized(self) -> bool:
        expected = f"Bearer {self.server.key}".encode()
        received = self.headers.get("Authorization", "").encode()
        if hmac.compare_digest(received, expected):
            return True
        self._send_json(401, {"error": "Falscher oder fehlender Schlüssel"})
        return False

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if length > 10_000:
            raise ServiceError("Anfrage zu groß", 413)
        try:
            data = json.loads(self.rfile.read(length) if length else b"{}")
        except ValueError:
            raise ServiceError("Ungültiges JSON", 400)
        if not isinstance(data, dict):
            raise ServiceError("JSON-Objekt erwartet", 400)
        return data

    def _status(self) -> dict:
        return {"computer": socket.gethostname(), "system": self.server.system.name, **self.server.system.status()}

    # Requests

    def do_GET(self) -> None:
        if not self._is_authorized():
            return
        path, _, query = self.path.partition("?")
        try:
            if path == "/api/status":
                self._send_json(200, self._status())
            elif path == "/api/audio":
                self._send_audio(self._aac_kbit(parse_qs(query)))
            elif path == "/api/tabs":
                self._send_json(200, {"tabs": self.server.system.tabs()})
            else:
                raise ServiceError("Unbekannter Pfad", 404)
        except ServiceError as error:
            self._send_json(error.status, {"error": str(error)})

    def do_POST(self) -> None:
        if not self._is_authorized():
            return
        try:
            data = self._read_json()
            system = self.server.system

            if self.path == "/api/volume":
                value = data.get("value")
                if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 100:
                    raise ServiceError("„value“ muss eine Zahl von 0 bis 100 sein", 400)
                system.set_volume(value)

            elif self.path == "/api/mute":
                muted = data.get("muted")
                if not isinstance(muted, bool):
                    raise ServiceError("„muted“ muss true oder false sein", 400)
                system.set_muted(muted)

            elif self.path == "/api/media-key":
                key = data.get("key")
                if key not in ALLOWED_KEYS:
                    raise ServiceError("„key“ muss play, next oder previous sein", 400)
                system.media_key(key)

            elif self.path == "/api/open":
                url = data.get("url")
                parts = urlparse(url) if isinstance(url, str) else None
                # Only web pages, no files or other programs
                if not parts or parts.scheme not in ("http", "https") or not parts.netloc:
                    raise ServiceError("Nur Adressen mit http:// oder https:// sind erlaubt", 400)
                system.open_url(url)

            elif self.path == "/api/close-tab":
                browser = data.get("browser")
                tab_id = data.get("id")
                if browser not in system.BROWSERS or isinstance(tab_id, bool) or not isinstance(tab_id, int):
                    raise ServiceError("„browser“ und „id“ eines offenen Tabs erwartet", 400)
                system.close_tab(browser, tab_id)
                self._send_json(200, {"tabs": system.tabs()})
                return

            else:
                raise ServiceError("Unbekannter Pfad", 404)

            self._send_json(200, self._status())
        except ServiceError as error:
            self._send_json(error.status, {"error": str(error)})

    @staticmethod
    def _aac_kbit(parameters: dict) -> int | None:
        """None = uncompressed, otherwise the requested AAC bit rate in kbit/s."""
        if parameters.get("format") != ["aac"]:
            return None
        try:
            kbit = int(parameters.get("kbit", ["96"])[0])
        except ValueError:
            kbit = 0
        if kbit not in ALLOWED_KBIT:
            raise ServiceError("„kbit“ muss 64, 96, 128, 160 oder 192 sein", 400)
        return kbit

    def _send_audio(self, aac_kbit: int | None) -> None:
        command = self.server.system.audio_command(aac_kbit)
        try:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except FileNotFoundError:
            raise ServiceError(f"Programm fehlt auf dem Rechner: {command[0]}", 503)

        # Collect the helper's error messages in the background
        messages: collections.deque = collections.deque(maxlen=20)

        def collect_messages() -> None:
            for line in process.stderr:
                messages.append(line.decode(errors="replace").strip())

        threading.Thread(target=collect_messages, daemon=True).start()

        try:
            # Wait for the first chunk: if e.g. a permission is missing, the app learns about it right away.
            chunk = process.stdout.read1(CHUNK_SIZE)
            if not chunk:
                process.wait(timeout=5)
                raise ServiceError(" ".join(messages) or "Tonquelle konnte nicht starten", 503)

            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Sample-Rate", str(SAMPLE_RATE))
            self.send_header("X-Channels", str(CHANNELS))
            self.send_header("X-Format", "aac-adts" if aac_kbit else "s16le")
            self.end_headers()

            while chunk:
                self.wfile.write(chunk)
                chunk = process.stdout.read1(CHUNK_SIZE)
        except (BrokenPipeError, ConnectionResetError):
            pass  # The app stopped the audio.
        finally:
            process.kill()
            process.wait()


class Service(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, key: str, system):
        super().__init__(address, RequestHandler)
        self.key = key
        self.system = system


# --------------------------------------------------------------------------- Start


def main() -> None:
    parser = argparse.ArgumentParser(description="HeimAudio-Dienst für die iPhone-App")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--address", default="0.0.0.0", help="Netzwerkadresse, auf der gelauscht wird")
    parser.add_argument("--test-tone", action="store_true", help="Piepton statt Systemton senden")
    parser.add_argument("--new-key", action="store_true", help="einen neuen geheimen Schlüssel erzeugen")
    args = parser.parse_args()

    operating_system = platform.system()
    if operating_system == "Darwin":
        system = MacSystem(test_tone=args.test_tone)
    elif operating_system == "Linux":
        system = LinuxSystem(test_tone=args.test_tone)
    else:
        sys.exit(f"{operating_system} wird nicht unterstützt, nur macOS und Linux.")
    key = load_key(new=args.new_key)
    service = Service((args.address, args.port), key, system)

    # Output for the user (German)
    print("HeimAudio-Dienst läuft" + (" (Testton)" if args.test_tone else ""))
    for address in system.addresses() or ["(keine Netzwerkadresse gefunden)"]:
        print(f"  Adresse:   {address}")
    print(f"  Port:      {args.port}")
    print(f"  Schlüssel: {key}")
    print("Diese drei Angaben in der App eintragen. Beenden mit Ctrl+C.\n", flush=True)

    try:
        service.serve_forever()
    except KeyboardInterrupt:
        print("\nBeendet.")


if __name__ == "__main__":
    main()
