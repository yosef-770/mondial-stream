#!/usr/bin/env python3
"""
פרוקסי HTTP זמני להרצה ממחשב בישראל (לשידורי כאן).

הרצה:
  python3 israel-temp-proxy.py

ברירת מחדל: מאזין על 0.0.0.0:8888
מומלץ להגביל ל-IP של שרת השידור:
  ALLOW_IPS=91.98.89.80 python3 israel-temp-proxy.py

אחרי שהפרוקסי רץ — בשרת השידור:
  1. עדכן .env: STREAM_HTTP_PROXY=http://IP-הציבורי-שלך:8888
  2. docker compose --profile streams up -d --force-recreate stream-relay-kanbet stream-relay-kan11
"""
from __future__ import annotations

import os
import select
import socket
import socketserver
import threading

LISTEN_HOST = os.environ.get("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8888"))
ALLOW_IPS = {
    ip.strip()
    for ip in os.environ.get("ALLOW_IPS", "91.98.89.80").split(",")
    if ip.strip()
}
BUFFER = 65536


class ProxyHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        client_ip = self.client_address[0]
        if ALLOW_IPS and client_ip not in ALLOW_IPS and "0.0.0.0" not in ALLOW_IPS:
            print(f"[deny] {client_ip}")
            self.connection.close()
            return

        try:
            first = self.rfile.readline(65535)
        except Exception:
            return
        if not first:
            return

        line = first.decode("latin-1", errors="replace").rstrip("\r\n")
        parts = line.split(" ")
        if len(parts) < 2:
            return

        method, target = parts[0].upper(), parts[1]
        # דלג על שאר ה-headers
        while True:
            h = self.rfile.readline(65535)
            if not h or h in (b"\r\n", b"\n"):
                break

        if method == "CONNECT":
            self._https_tunnel(target, client_ip)
        else:
            self._http_forward(method, target, client_ip)

    def _https_tunnel(self, target: str, client_ip: str) -> None:
        host, _, port_s = target.partition(":")
        port = int(port_s or "443")
        try:
            remote = socket.create_connection((host, port), timeout=20)
        except OSError as exc:
            print(f"[fail] {client_ip} CONNECT {target}: {exc}")
            self.connection.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            return

        self.connection.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        print(f"[ok] {client_ip} CONNECT {target}")
        self._pipe(self.connection, remote)
        remote.close()

    def _http_forward(self, method: str, url: str, client_ip: str) -> None:
        # תמיכה בסיסית ב-HTTP רגיל (נדיר לשידורים שלנו — רובם HTTPS)
        if not url.startswith("http://"):
            self.connection.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
            return
        rest = url[len("http://") :]
        host_port, _, path = rest.partition("/")
        path = "/" + path
        host, _, port_s = host_port.partition(":")
        port = int(port_s or "80")
        try:
            remote = socket.create_connection((host, port), timeout=20)
        except OSError as exc:
            print(f"[fail] {client_ip} {method} {url}: {exc}")
            self.connection.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            return

        req = (
            f"{method} {path} HTTP/1.1\r\n"
            f"Host: {host_port}\r\n"
            f"Connection: close\r\n\r\n"
        ).encode()
        remote.sendall(req)
        print(f"[ok] {client_ip} {method} {url}")
        self._pipe(self.connection, remote)
        remote.close()

    def _pipe(self, a: socket.socket, b: socket.socket) -> None:
        a.setblocking(False)
        b.setblocking(False)
        sockets = [a, b]
        try:
            while True:
                readable, _, errored = select.select(sockets, [], sockets, 60)
                if errored or not readable:
                    break
                for src in readable:
                    dst = b if src is a else a
                    try:
                        data = src.recv(BUFFER)
                    except OSError:
                        return
                    if not data:
                        return
                    try:
                        dst.sendall(data)
                    except OSError:
                        return
        except Exception:
            return


class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> None:
    print(f"[proxy] listening on {LISTEN_HOST}:{LISTEN_PORT}")
    print(f"[proxy] allow IPs: {', '.join(sorted(ALLOW_IPS)) or '(all)'}")
    print("[proxy] Ctrl+C to stop")
    with ThreadedTCPServer((LISTEN_HOST, LISTEN_PORT), ProxyHandler) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
