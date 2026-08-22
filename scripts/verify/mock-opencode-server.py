#!/usr/bin/env python3
"""mock-opencode-server — a protocol-faithful fake of the slice of the
OpenCode HTTP API that the code-agent plane uses (manager proxying, the
phone app's opencode-client, and check scripts). Lets the whole plane be
tested on any machine with no containers, no VPS, and no API key:

    scripts/verify/test-code-agent-manager.sh

Implements (Basic auth required, any username + the --password value):
    GET  /session                          sessions (persisted in the chat dir)
    POST /session[?directory=...]          create session
    GET  /session/status                   busy map while a turn streams
    GET  /session/<id>/message             [{info, parts}]
    POST /session/<id>/prompt_async        204; scripted turn over SSE
    POST /session/<id>/abort               cancel the turn
    GET  /session/<id>/diff                canned FileDiff[]
    GET  /permission                       pending permission asks
    POST /session/<id>/permissions/<pid>   {"response": once|always|reject}
    GET  /event                            SSE (server.connected, heartbeats,
                                           message.part.updated deltas, ...)

Turn script: streams assistant text in deltas; a prompt containing "push"
raises a blocking `git push` permission ask (the turn waits for the reply,
like the real server); a prompt mentioning a PR ends with a fake PR URL.
State lives in <dir>/home/mock-opencode-state.json so stopping and
restarting the process — the stub engine's spin-down/wake — provably
preserves sessions and transcripts, mirroring the per-chat volume design.

Typing: mypy --strict clean (enforced by .github/workflows/python-types.yml).
Message *parts* stay wire-shaped dicts by design — they are built by the
typed helpers below and serialized verbatim; everything else is dataclasses.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import secrets
import threading
import time
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse

Wire = dict[str, object]


@dataclass(frozen=True)
class Config:
    port: int
    dir: str
    password: str


CONFIG = Config(port=0, dir=".", password="mock")

STATE_LOCK = threading.Lock()
SUB_LOCK = threading.Lock()
SUBSCRIBERS: list[list[Wire]] = []
BUSY: set[str] = set()


@dataclass(frozen=True)
class Permission:
    id: str
    session_id: str
    kind: str
    title: str
    metadata: Wire

    def to_wire(self) -> Wire:
        return {
            "id": self.id,
            "sessionID": self.session_id,
            "type": self.kind,
            "title": self.title,
            "metadata": self.metadata,
        }


@dataclass
class PendingPermission:
    perm: Permission
    event: threading.Event = field(default_factory=threading.Event)
    response: str = ""


PENDING: dict[str, PendingPermission] = {}


@dataclass(frozen=True)
class Session:
    id: str
    title: str
    directory: str

    def to_wire(self) -> Wire:
        return {"id": self.id, "title": self.title, "directory": self.directory}

    @classmethod
    def from_wire(cls, raw: dict[str, Any]) -> Session:
        return cls(
            id=str(raw.get("id", "")),
            title=str(raw.get("title", "")),
            directory=str(raw.get("directory", "")),
        )


@dataclass(frozen=True)
class MessageInfo:
    id: str
    role: str
    session_id: str

    def to_wire(self) -> Wire:
        return {"id": self.id, "role": self.role, "sessionID": self.session_id}

    @classmethod
    def from_wire(cls, raw: dict[str, Any]) -> MessageInfo:
        return cls(
            id=str(raw.get("id", "")),
            role=str(raw.get("role", "")),
            session_id=str(raw.get("sessionID", "")),
        )


@dataclass
class StoredMessage:
    info: MessageInfo
    parts: list[Wire]

    def to_wire(self) -> Wire:
        return {"info": self.info.to_wire(), "parts": self.parts}

    @classmethod
    def from_wire(cls, raw: dict[str, Any]) -> StoredMessage:
        info_raw = raw.get("info")
        parts_raw = raw.get("parts")
        parts: list[Wire] = [p for p in parts_raw if isinstance(p, dict)] if isinstance(
            parts_raw, list
        ) else []
        return cls(
            info=MessageInfo.from_wire(info_raw if isinstance(info_raw, dict) else {}),
            parts=parts,
        )


@dataclass
class State:
    sessions: list[Session] = field(default_factory=list)
    messages: dict[str, list[StoredMessage]] = field(default_factory=dict)

    @classmethod
    def path(cls) -> str:
        d = os.path.join(CONFIG.dir, "home")
        os.makedirs(d, exist_ok=True)
        return os.path.join(d, "mock-opencode-state.json")

    @classmethod
    def load(cls) -> State:
        try:
            with open(cls.path(), "r", encoding="utf-8") as f:
                raw: Any = json.load(f)
        except FileNotFoundError:
            return cls()
        if not isinstance(raw, dict):
            return cls()
        sessions = [
            Session.from_wire(s)
            for s in raw.get("sessions", [])
            if isinstance(s, dict)
        ]
        messages: dict[str, list[StoredMessage]] = {}
        raw_messages = raw.get("messages", {})
        if isinstance(raw_messages, dict):
            for sid, entries in raw_messages.items():
                if isinstance(sid, str) and isinstance(entries, list):
                    messages[sid] = [
                        StoredMessage.from_wire(e) for e in entries if isinstance(e, dict)
                    ]
        return cls(sessions=sessions, messages=messages)

    def save(self) -> None:
        payload: Wire = {
            "sessions": [s.to_wire() for s in self.sessions],
            "messages": {
                sid: [m.to_wire() for m in entries]
                for sid, entries in self.messages.items()
            },
        }
        tmp = self.path() + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=1)
        os.replace(tmp, self.path())


# ------------------------------------------------------- wire-part builders


def text_part(msg_id: str, session_id: str, text: str, part_id: str | None = None) -> Wire:
    return {
        "id": part_id or f"prt_{secrets.token_hex(4)}",
        "messageID": msg_id,
        "sessionID": session_id,
        "type": "text",
        "text": text,
    }


def tool_part(msg_id: str, session_id: str, status: str, title: str, output: str = "") -> Wire:
    state: Wire = {"status": status, "title": title}
    if output:
        state["output"] = output
    else:
        state["input"] = {"command": title}
    return {
        "id": f"prt_{secrets.token_hex(4)}",
        "messageID": msg_id,
        "sessionID": session_id,
        "type": "tool",
        "tool": "bash",
        "callID": f"call_{secrets.token_hex(3)}",
        "state": state,
    }


def publish(event_type: str, properties: Wire) -> None:
    evt: Wire = {"type": event_type, "properties": properties}
    with SUB_LOCK:
        for queue in SUBSCRIBERS:
            queue.append(evt)


# ------------------------------------------------------------- the turn


def run_turn(session_id: str, prompt: str) -> None:
    BUSY.add(session_id)
    try:
        user_msg = MessageInfo(
            id=f"msg_{secrets.token_hex(4)}", role="user", session_id=session_id
        )
        user_part = text_part(user_msg.id, session_id, prompt)
        with STATE_LOCK:
            state = State.load()
            state.messages.setdefault(session_id, []).append(
                StoredMessage(info=user_msg, parts=[user_part])
            )
            state.save()
        publish("message.updated", {"info": user_msg.to_wire()})
        publish("message.part.updated", {"part": user_part})

        asst = MessageInfo(
            id=f"msg_{secrets.token_hex(4)}", role="assistant", session_id=session_id
        )
        publish("message.updated", {"info": asst.to_wire()})

        # Streamed assistant text, in deltas like the real server.
        stream_id = f"prt_{secrets.token_hex(4)}"
        chunks = ["Working on it", " — checking the workspace", " now."]
        acc = ""
        for chunk in chunks:
            acc += chunk
            publish(
                "message.part.updated",
                {
                    "part": text_part(asst.id, session_id, acc, part_id=stream_id),
                    "delta": chunk,
                },
            )
            time.sleep(0.15)
        parts: list[Wire] = [text_part(asst.id, session_id, acc, part_id=stream_id)]

        # A push-flavored prompt exercises the blocking permission flow.
        rejected = False
        if "push" in prompt.lower():
            running = tool_part(asst.id, session_id, "running", "git push origin HEAD")
            publish("message.part.updated", {"part": running})
            perm = Permission(
                id=f"perm_{secrets.token_hex(4)}",
                session_id=session_id,
                kind="bash",
                title="Run: git push origin HEAD",
                metadata={"command": "git push origin HEAD"},
            )
            pending = PendingPermission(perm=perm)
            PENDING[perm.id] = pending
            publish("permission.updated", perm.to_wire())
            # Block until the client answers — the real semantics.
            pending.event.wait(timeout=120)
            PENDING.pop(perm.id, None)
            publish(
                "permission.replied",
                {"permissionID": perm.id, "response": pending.response or "timeout"},
            )
            rejected = pending.response not in ("once", "always")
            done = tool_part(
                asst.id,
                session_id,
                "error" if rejected else "completed",
                "git push origin HEAD",
                output="push rejected by user"
                if rejected
                else "To github.com: agent/branch pushed",
            )
            publish("message.part.updated", {"part": done})
            parts.append(done)

        wants_pr = "pull request" in prompt.lower() or " pr" in f" {prompt.lower()}"
        final_text = (
            "Push was rejected, so I stopped there."
            if rejected
            else "Opened the pull request: https://github.com/example/repo/pull/7"
            if wants_pr
            else "Done. The change is committed on the session branch."
        )
        final = text_part(asst.id, session_id, final_text)
        publish("message.part.updated", {"part": final})
        parts.append(final)

        with STATE_LOCK:
            state = State.load()
            state.messages.setdefault(session_id, []).append(
                StoredMessage(info=asst, parts=parts)
            )
            state.save()
    finally:
        BUSY.discard(session_id)
        publish("session.idle", {"sessionID": session_id})


# ------------------------------------------------------------------ HTTP


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def authed(self) -> bool:
        hdr = self.headers.get("Authorization", "") or ""
        cred = hdr[6:] if hdr.startswith("Basic ") else ""
        if not cred:
            q = parse_qs(urlparse(self.path).query)
            cred = (q.get("auth_token") or [""])[0]
        try:
            _, _, pw = base64.b64decode(cred).decode().partition(":")
        except (ValueError, UnicodeDecodeError):
            pw = ""
        return secrets.compare_digest(pw, CONFIG.password)

    def send_json(self, code: int, obj: object) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def read_json(self) -> dict[str, Any]:
        n = int(self.headers.get("Content-Length") or 0)
        try:
            raw: Any = json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            return {}
        return raw if isinstance(raw, dict) else {}

    def handle_any(self) -> None:
        if not self.authed():
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="mock"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        path = urlparse(self.path).path
        parts = [p for p in path.split("/") if p]

        if path == "/event" and self.command == "GET":
            self.stream_events()
            return
        if path == "/session" and self.command == "GET":
            with STATE_LOCK:
                self.send_json(200, [s.to_wire() for s in State.load().sessions])
            return
        if path == "/session" and self.command == "POST":
            q = parse_qs(urlparse(self.path).query)
            directory = (q.get("directory") or ["/chat/workspace"])[0]
            sess = Session(
                id=f"ses_{secrets.token_hex(5)}",
                title="mock session",
                directory=directory,
            )
            with STATE_LOCK:
                state = State.load()
                state.sessions.append(sess)
                state.save()
            self.send_json(200, sess.to_wire())
            return
        if path == "/session/status" and self.command == "GET":
            self.send_json(200, {sid: {"type": "busy"} for sid in sorted(BUSY)})
            return
        if path == "/permission" and self.command == "GET":
            self.send_json(200, [p.perm.to_wire() for p in PENDING.values()])
            return

        if len(parts) >= 3 and parts[0] == "session":
            sid = parts[1]
            if parts[2] == "message" and self.command == "GET":
                with STATE_LOCK:
                    entries = State.load().messages.get(sid, [])
                    self.send_json(200, [m.to_wire() for m in entries])
                return
            if parts[2] == "prompt_async" and self.command == "POST":
                body = self.read_json()
                body_parts = body.get("parts", [])
                text = ""
                if isinstance(body_parts, list):
                    for part in body_parts:
                        if isinstance(part, dict) and part.get("type") == "text":
                            value = part.get("text", "")
                            if isinstance(value, str):
                                text += value
                threading.Thread(
                    target=run_turn, args=(sid, text), daemon=True
                ).start()
                self.send_response(204)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if parts[2] == "abort" and self.command == "POST":
                # Resolve any blocked permission so the turn thread finishes.
                for pending in list(PENDING.values()):
                    if pending.perm.session_id == sid:
                        pending.response = "reject"
                        pending.event.set()
                BUSY.discard(sid)
                publish("session.idle", {"sessionID": sid})
                self.send_json(200, True)
                return
            if parts[2] == "diff" and self.command == "GET":
                self.send_json(
                    200,
                    [
                        {
                            "path": "README.md",
                            "additions": 3,
                            "deletions": 1,
                            "patch": (
                                "--- a/README.md\n+++ b/README.md\n@@ -1 +1,3 @@\n"
                                "-old\n+new line one\n+new line two\n+new line three\n"
                            ),
                        }
                    ],
                )
                return
            if parts[2] == "permissions" and len(parts) == 4 and self.command == "POST":
                entry = PENDING.get(parts[3])
                if entry is None:
                    self.send_json(404, {"error": "unknown permission"})
                    return
                response = self.read_json().get("response", "reject")
                entry.response = response if isinstance(response, str) else "reject"
                entry.event.set()
                self.send_json(200, True)
                return

        self.send_json(404, {"error": f"mock: no route {self.command} {path}"})

    def stream_events(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.close_connection = True
        self.end_headers()
        queue: list[Wire] = []
        with SUB_LOCK:
            SUBSCRIBERS.append(queue)
        try:
            self.write_event({"type": "server.connected", "properties": {}})
            last_beat = time.time()
            while True:
                while queue:
                    self.write_event(queue.pop(0))
                if time.time() - last_beat > 5:
                    self.write_event({"type": "server.heartbeat", "properties": {}})
                    last_beat = time.time()
                time.sleep(0.05)
        except OSError:
            pass
        finally:
            with SUB_LOCK:
                if queue in SUBSCRIBERS:
                    SUBSCRIBERS.remove(queue)

    def write_event(self, evt: Wire) -> None:
        data = json.dumps(evt)
        self.wfile.write(f"data: {data}\n\n".encode())
        self.wfile.flush()

    def do_GET(self) -> None:
        self.handle_any()

    def do_POST(self) -> None:
        self.handle_any()

    def log_message(self, format: str, *args: object) -> None:
        pass  # quiet; the harness asserts on behavior, not logs


def main() -> None:
    global CONFIG
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--dir", required=True, help="the chat volume dir")
    ap.add_argument(
        "--password", default=os.environ.get("OPENCODE_SERVER_PASSWORD", "mock")
    )
    args = ap.parse_args()
    CONFIG = Config(port=int(args.port), dir=str(args.dir), password=str(args.password))
    server = ThreadingHTTPServer(("127.0.0.1", CONFIG.port), Handler)
    server.daemon_threads = True
    print(
        f"mock-opencode-server: 127.0.0.1:{CONFIG.port} dir={CONFIG.dir}", flush=True
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
