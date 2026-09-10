#!/usr/bin/env python3
"""HTTP API להדלקה/כיבוי stream-relay (localhost + Docker socket)."""
from __future__ import annotations

import json
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

BIND_HOST = "127.0.0.1"
BIND_PORT = 8765
DOCKER_SOCK = "/var/run/docker.sock"

WATCHDOG_INTERVAL_SEC = 60
WATCHDOG_FAIL_THRESHOLD = 3

CONTAINERS = {str(i): f"mondial-stream-relay-{i}" for i in range(1, 21)}
ALIASES = {
    "kanbet": "1",
    "kan11": "2",
    "mondial": "2",
}
ENV_FILE = "/project/.env"


def resolve_channel(name: str) -> str | None:
    if name in ALIASES:
        return ALIASES[name]
    if name in CONTAINERS:
        return name
    return None


def configured_channels() -> set[str]:
    """שלוחות עם STREAM_N_URL או STREAM_N_URLS ב-.env."""
    configured: set[str] = set()
    try:
        with open(ENV_FILE, encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        return set(CONTAINERS)

    values: dict[str, str] = {}
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        values[key.strip()] = val.strip().strip("'\"")

    for i in range(1, 21):
        n = str(i)
        if values.get(f"STREAM_{n}_URL") or values.get(f"STREAM_{n}_URLS"):
            configured.add(n)
    return configured


def docker_request(method: str, path: str) -> tuple[int, str]:
    payload = (
        f"{method} {path} HTTP/1.0\r\n"
        "Host: localhost\r\n"
        "\r\n"
    ).encode()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(DOCKER_SOCK)
        sock.sendall(payload)
        chunks: list[bytes] = []
        while True:
            part = sock.recv(65536)
            if not part:
                break
            chunks.append(part)
    raw = b"".join(chunks).decode("utf-8", errors="replace")
    head, _, body = raw.partition("\r\n\r\n")
    status_line = head.split("\r\n", 1)[0]
    code = int(status_line.split(" ", 2)[1])
    return code, body.strip() or status_line


def container_running(name: str) -> bool:
    code, body = docker_request("GET", f"/containers/{name}/json")
    if code != 200:
        return False
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        return False
    return data.get("State", {}).get("Running") is True


def container_exists(name: str) -> bool:
    code, _ = docker_request("GET", f"/containers/{name}/json")
    return code == 200


def container_action(action: str, name: str) -> tuple[bool, str]:
    code, detail = docker_request("POST", f"/containers/{name}/{action}")
    ok = code in (204, 304)
    return ok, detail


def icecast_live(mount: str) -> bool:
    try:
        import urllib.request

        with urllib.request.urlopen("http://127.0.0.1:8000/status-json.xsl", timeout=3) as resp:
            data = json.loads(resp.read().decode())
    except Exception:
        return False

    sources = data.get("icestats", {}).get("source")
    if not sources:
        return False
    if isinstance(sources, dict):
        sources = [sources]
    mount = mount if mount.startswith("/") else f"/{mount}"
    for src in sources:
        url = src.get("listenurl") or ""
        if url.endswith(mount) or mount in url:
            return True
    return False


def status_payload() -> dict:
    out: dict = {}
    for channel, container in CONTAINERS.items():
        out[channel] = {
            "relay": "running" if container_running(container) else "stopped",
            "icecast": "live" if icecast_live(channel) else "off",
            "aliases": [a for a, n in ALIASES.items() if n == channel],
        }
    # כינויים נוחים בסטטוס
    out["kanbet"] = out["1"]
    out["kan11"] = out["2"]
    return out


def watchdog_loop() -> None:
    """Restart configured relays that are running but stuck with Icecast off."""
    fail_counts = {name: 0 for name in CONTAINERS}
    print(
        f"[watchdog] started (interval={WATCHDOG_INTERVAL_SEC}s, "
        f"threshold={WATCHDOG_FAIL_THRESHOLD})",
        flush=True,
    )
    while True:
        time.sleep(WATCHDOG_INTERVAL_SEC)
        active = configured_channels()
        for channel, container in CONTAINERS.items():
            if channel not in active:
                fail_counts[channel] = 0
                continue
            try:
                running = container_running(container)
                live = icecast_live(channel)
            except Exception as exc:
                print(f"[watchdog] {channel} check failed: {exc}", flush=True)
                continue

            if not running:
                fail_counts[channel] = 0
                continue

            if live:
                if fail_counts[channel]:
                    print(f"[watchdog] {channel} recovered (icecast live)", flush=True)
                fail_counts[channel] = 0
                continue

            fail_counts[channel] += 1
            print(
                f"[watchdog] {channel} relay running but icecast off "
                f"({fail_counts[channel]}/{WATCHDOG_FAIL_THRESHOLD})",
                flush=True,
            )
            if fail_counts[channel] < WATCHDOG_FAIL_THRESHOLD:
                continue

            print(f"[watchdog] {channel} stuck off — restarting {container}", flush=True)
            ok, detail = container_action("restart", container)
            fail_counts[channel] = 0
            print(
                f"[watchdog] restart {container}: {'ok' if ok else 'failed'} ({detail})",
                flush=True,
            )


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write(f"[stream-control] {self.address_string()} - {fmt % args}\n")

    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/status":
            self._json(200, {"ok": True, **status_payload()})
            return

        if path.startswith("/live/"):
            name = path.rsplit("/", 1)[-1]
            channel = resolve_channel(name)
            if not channel:
                self._json(404, {"ok": False, "error": f"unknown stream: {name}"})
                return
            live = icecast_live(channel)
            body = b"ok\n" if live else b"off\n"
            code = 200 if live else 503
            self.send_response(code)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self._json(404, {"ok": False, "error": "not found"})

    def do_POST(self) -> None:
        parts = [p for p in urlparse(self.path).path.split("/") if p]
        if len(parts) != 2 or parts[0] not in {"start", "stop"}:
            self._json(
                404,
                {"ok": False, "error": "use /start/{1-20|kanbet|kan11|all} or /stop/..."},
            )
            return

        action, target = parts
        docker_action = "start" if action == "start" else "stop"

        if target == "all":
            names = [c for c in CONTAINERS.values() if container_exists(c)]
        else:
            channel = resolve_channel(target)
            if not channel:
                self._json(400, {"ok": False, "error": f"unknown target: {target}"})
                return
            names = [CONTAINERS[channel]]

        details: list[str] = []
        ok = True
        for name in names:
            item_ok, detail = container_action(docker_action, name)
            ok = ok and item_ok
            details.append(f"{name}: {detail}")

        self._json(200 if ok else 500, {
            "ok": ok,
            "action": docker_action,
            "target": target,
            "detail": "; ".join(details),
            **status_payload(),
        })


def main() -> None:
    threading.Thread(target=watchdog_loop, name="stream-watchdog", daemon=True).start()
    server = HTTPServer((BIND_HOST, BIND_PORT), Handler)
    print(f"[stream-control] listening on http://{BIND_HOST}:{BIND_PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
