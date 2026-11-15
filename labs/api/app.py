"""Tiny upstream API for the learnNginx labs.

The service intentionally has no third-party dependencies so the lab can be
built from a plain Python image. It exposes endpoints used by the chapters on
reverse proxying, load balancing, caching, rate limiting, timeouts, and logs.
"""

from __future__ import annotations

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

INSTANCE = os.environ.get("INSTANCE_NAME", "api")
STARTED_AT = time.time()
CACHE_COUNTER = 0


def encode_json(payload: object) -> bytes:
    return json.dumps(payload, ensure_ascii=False).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "LabAPI/1.0"
    sys_version = ""

    def _send(
        self,
        status: int,
        body: bytes,
        content_type: str = "application/json; charset=utf-8",
        extra_headers: dict[str, str] | None = None,
        head_only: bool = False,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Instance", INSTANCE)
        self.send_header("Cache-Control", "no-store")
        if extra_headers:
            for key, value in extra_headers.items():
                self.send_header(key, value)
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def _send_json(
        self,
        status: int,
        payload: object,
        extra_headers: dict[str, str] | None = None,
        head_only: bool = False,
    ) -> None:
        self._send(status, encode_json(payload), extra_headers=extra_headers, head_only=head_only)

    def do_GET(self) -> None:
        self._route(head_only=False)

    def do_HEAD(self) -> None:
        self._route(head_only=True)

    def do_OPTIONS(self) -> None:
        self._send(204, b"", extra_headers={"Allow": "GET, HEAD, POST, OPTIONS"})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path != "/echo":
            self._send_json(404, {"error": "not found", "instance": INSTANCE})
            return

        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            self._send_json(411, {"error": "content-length required", "instance": INSTANCE})
            return

        try:
            length = int(raw_length)
        except ValueError:
            self._send_json(400, {"error": "invalid content-length", "instance": INSTANCE})
            return

        body = self.rfile.read(length)
        preview = body[:200].decode("utf-8", errors="replace")
        self._send_json(
            200,
            {
                "instance": INSTANCE,
                "bytes": len(body),
                "preview": preview,
            },
        )

    def _route(self, head_only: bool) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path == "/health":
            self._send_json(
                200,
                {
                    "status": "ok",
                    "instance": INSTANCE,
                    "uptime_seconds": round(time.time() - STARTED_AT, 1),
                },
                head_only=head_only,
            )
            return

        if path == "/":
            self._send_json(
                200,
                {
                    "instance": INSTANCE,
                    "message": "learnNginx lab API",
                    "endpoints": [
                        "/health",
                        "/headers",
                        "/echo",
                        "/limited",
                        "/cache-test",
                        "/slow?ms=1000",
                        "/stream",
                    ],
                    "headers": dict(self.headers.items()),
                    "uptime_seconds": round(time.time() - STARTED_AT, 1),
                },
                head_only=head_only,
            )
            return

        if path == "/headers":
            self._send_json(200, {"instance": INSTANCE, "headers": dict(self.headers.items())}, head_only=head_only)
            return

        if path == "/limited":
            self._send_json(200, {"instance": INSTANCE, "message": "request accepted"}, head_only=head_only)
            return

        if path == "/cache-test":
            global CACHE_COUNTER
            CACHE_COUNTER += 1
            self._send_json(
                200,
                {
                    "instance": INSTANCE,
                    "generated_at": round(time.time(), 3),
                    "counter": CACHE_COUNTER,
                },
                head_only=head_only,
            )
            return

        if path == "/slow":
            try:
                milliseconds = int(query.get("ms", ["1000"])[0])
            except ValueError:
                self._send_json(400, {"error": "ms must be an integer", "instance": INSTANCE})
                return
            milliseconds = max(0, min(milliseconds, 10_000))
            time.sleep(milliseconds / 1000)
            self._send_json(
                200,
                {"instance": INSTANCE, "slept_ms": milliseconds},
                head_only=head_only,
            )
            return

        if path == "/stream":
            self._send_stream(head_only=head_only)
            return

        self._send_json(404, {"error": "not found", "instance": INSTANCE, "path": path}, head_only=head_only)

    def _send_stream(self, head_only: bool) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

        if head_only:
            return

        for index in range(5):
            self.wfile.write(f"{INSTANCE} chunk {index}\n".encode("utf-8"))
            self.wfile.flush()
            time.sleep(0.5)

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stderr.write(f"[{INSTANCE}] {self.address_string()} {fmt % args}\n")
        sys.stderr.flush()


def main() -> None:
    port = int(os.environ.get("PORT", "8000"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"{INSTANCE} listening on 0.0.0.0:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
