#!/usr/bin/env python3
"""Bridge between the HeimAudio service and the Brave extension ("Offene Tabs" on Linux).

Brave starts this program itself as soon as the extension is running (native messaging)
and talks to it via stdin/stdout: per message 4 bytes of length, then JSON.

The service reaches the bridge through the socket file ~/.config/heimaudio/brave.sock,
which only your user may open. Per connection it sends one line of JSON (the request)
and gets one line of JSON back (the extension's answer).

Requests: {"type": "list"} and {"type": "close", "tab": 123}
"""

from __future__ import annotations

import json
import os
import queue
import socket
import struct
import sys
import threading
from pathlib import Path

SOCKET_PATH = Path.home() / ".config" / "heimaudio" / "brave.sock"
TIMEOUT = 10  # seconds to wait for Brave

answers: queue.Queue = queue.Queue()


def send_to_brave(message: dict) -> None:
    data = json.dumps(message).encode()
    sys.stdout.buffer.write(struct.pack("=I", len(data)) + data)
    sys.stdout.buffer.flush()


def read_from_brave(clean_up) -> None:
    """Reads the extension's answers. When Brave closes the connection, the bridge exits."""
    while True:
        header = sys.stdin.buffer.read(4)
        if len(header) < 4:
            break
        (length,) = struct.unpack("=I", header)
        try:
            answers.put(json.loads(sys.stdin.buffer.read(length)))
        except ValueError:
            pass
    clean_up()
    os._exit(0)


def validate(request) -> dict:
    """Only let the two known requests through."""
    if isinstance(request, dict):
        if request.get("type") == "list":
            return {"type": "list"}
        tab = request.get("tab")
        if request.get("type") == "close" and isinstance(tab, int) and not isinstance(tab, bool):
            return {"type": "close", "tab": tab}
    raise ValueError


def handle(connection: socket.socket, request_id: int) -> None:
    connection.settimeout(5)
    with connection, connection.makefile("rb") as incoming:
        try:
            request = validate(json.loads(incoming.readline()))
        except (ValueError, OSError):
            answer = {"error": "Unbekannter Auftrag", "status": 400}
        else:
            # Discard leftover answers to earlier requests
            while not answers.empty():
                answers.get_nowait()
            send_to_brave({**request, "requestId": request_id})
            answer = {"error": "Brave hat nicht rechtzeitig geantwortet", "status": 504}
            try:
                while True:
                    candidate = answers.get(timeout=TIMEOUT)
                    if candidate.get("requestId") == request_id:
                        answer = candidate
                        break
            except queue.Empty:
                pass
        try:
            connection.sendall(json.dumps(answer).encode() + b"\n")
        except OSError:
            pass


def main() -> None:
    SOCKET_PATH.parent.mkdir(parents=True, exist_ok=True)
    try:
        SOCKET_PATH.unlink()  # left over from an earlier bridge
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    old_umask = os.umask(0o177)  # socket only for you (rw-------)
    try:
        server.bind(str(SOCKET_PATH))
    finally:
        os.umask(old_umask)
    server.listen(4)
    own_inode = SOCKET_PATH.stat().st_ino

    def clean_up() -> None:
        # Only delete our own socket file, not the one of a newer bridge
        try:
            if SOCKET_PATH.stat().st_ino == own_inode:
                SOCKET_PATH.unlink()
        except OSError:
            pass

    threading.Thread(target=read_from_brave, args=(clean_up,), daemon=True).start()

    request_id = 0
    while True:
        connection, _ = server.accept()
        request_id += 1
        handle(connection, request_id)


if __name__ == "__main__":
    main()
