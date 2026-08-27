#!/usr/bin/env python3
"""fake-ntfy.py — a recording stand-in for ntfy, for the verify harness.

Pointed at by NTFY_SERVER, it accepts the POST the manager's agent-notification
sender makes and appends what it received to a JSONL file, one object per
notification:

    {"topic": ..., "title": ..., "priority": ..., "headers": {...},
     "body": <the parsed JSON body, or the raw string if it did not parse>}

That shape is the point. The privacy rule for this channel (docs/privacy.md) is
that the payload is content-free BY CONSTRUCTION — a kind, an opaque handle and
a count — and the only way to hold a rule like that is to assert on the exact
bytes that left the box. So this records everything, including the topic and
every header, and the harness then asserts what is NOT in there: no chat id, no
repo name, no chat title, no tool arguments, no `Email:` header, and not the
failure channel's topic.

Same spirit as fake-github.py: no network, binds 127.0.0.1 only, stdlib only,
and clean under `mypy --strict` + the whole ruff rule set.

    fake-ntfy.py --port 4397 --out /tmp/ntfy.jsonl

Never point this at anything real: it answers 200 to everything and keeps a
plaintext record of every message, which is exactly what you do not want a
production notification path doing.
"""

from __future__ import annotations

import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, ClassVar
from urllib.parse import unquote, urlparse

# One writer lock: the server is threaded, and two notifications landing
# together must not interleave half-lines into the record.
WRITE_LOCK = threading.Lock()
OUT_PATH = Path("/dev/null")

MAX_BODY = 1 << 20


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "fake-ntfy"

    # ntfy carries the human-facing fields as headers, so they are what the
    # harness has to be able to read back.
    RECORDED_HEADERS: ClassVar[tuple[str, ...]] = (
        "Title",
        "Priority",
        "Tags",
        "Click",
        "Actions",
        "Email",
        "Content-Type",
    )

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(min(length, MAX_BODY)) if length else b""
        text = raw.decode("utf-8", "replace")
        try:
            body: Any = json.loads(text)
        except json.JSONDecodeError:
            body = text
        record = {
            # The path IS the topic, and recording it is how the harness
            # proves the agent channel is not the failure channel.
            "topic": unquote(urlparse(self.path).path).lstrip("/"),
            "headers": {
                name: self.headers.get(name)
                for name in self.RECORDED_HEADERS
                if self.headers.get(name) is not None
            },
            "body": body,
        }
        with WRITE_LOCK, OUT_PATH.open("a", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")
        payload = b'{"id":"fake"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        """Answer readiness probes, so the harness can wait for the port."""
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002, ARG002
        # Silent: the record file is the output, and the topic is in the path.
        return


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=4397)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    global OUT_PATH  # noqa: PLW0603 -- one process-wide sink, set once from argv
    OUT_PATH = Path(args.out)
    OUT_PATH.touch()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
