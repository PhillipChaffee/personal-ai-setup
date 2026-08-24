#!/usr/bin/env python3
"""mock-opencode-server — a protocol-faithful fake of the OpenCode HTTP API.

It covers the slice the code-agent plane uses (manager proxying, the phone
app's opencode-client, and check scripts), so the whole plane can be tested
on any machine with no containers, no VPS, and no API key:

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

Conventions: `mypy --strict` and `ruff check` clean, same gates as the rest
of the repo's Python (mypy.ini, ruff.toml). Message *parts* stay wire-shaped
dicts by design — they are built by the typed helpers below and serialized
verbatim; everything else is dataclasses.
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
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

Wire = dict[str, object]


@dataclass(frozen=True)
class Config:
    port: int
    dir: Path
    password: str


# Placeholder until main() parses argv; --password (or the env var) supplies
# the real one. This is a test double that only ever listens on 127.0.0.1.
CONFIG = Config(port=0, dir=Path(), password="mock")  # noqa: S106

# Path shapes: /session/<id>/<verb> and /session/<id>/permissions/<pid>.
SESSION_PATH_PARTS = 3
PERMISSION_PATH_PARTS = 4
HEARTBEAT_SECONDS = 5.0

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


@dataclass
class Session:
    id: str
    title: str
    directory: str
    # What the last turn asked to run on. OpenCode records this when a TURN
    # IS SENT, not when a model is picked, and the session record is then the
    # server's answer to "what will the next turn use" — which is the thing a
    # client has to reconcile its own pending pick against.
    model: str = ""
    variant: str = ""

    def to_wire(self) -> Wire:
        wire: Wire = {"id": self.id, "title": self.title, "directory": self.directory}
        if self.model:
            provider, _, model_id = self.model.partition("/")
            entry: Wire = {"providerID": provider, "id": model_id}
            if self.variant:
                entry["variant"] = self.variant
            wire["model"] = entry
        return wire

    @classmethod
    def from_wire(cls, raw: dict[str, Any]) -> Session:
        model = raw.get("model")
        reference = variant = ""
        if isinstance(model, dict):
            provider = str(model.get("providerID", ""))
            model_id = str(model.get("id", ""))
            if provider and model_id:
                reference = f"{provider}/{model_id}"
            variant = str(model.get("variant", ""))
        return cls(
            id=str(raw.get("id", "")),
            title=str(raw.get("title", "")),
            directory=str(raw.get("directory", "")),
            model=reference,
            variant=variant,
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
        parts: list[Wire] = (
            [p for p in parts_raw if isinstance(p, dict)]
            if isinstance(
                parts_raw,
                list,
            )
            else []
        )
        return cls(
            info=MessageInfo.from_wire(info_raw if isinstance(info_raw, dict) else {}),
            parts=parts,
        )


@dataclass
class State:
    sessions: list[Session] = field(default_factory=list)
    messages: dict[str, list[StoredMessage]] = field(default_factory=dict)

    @classmethod
    def path(cls) -> Path:
        d = CONFIG.dir / "home"
        d.mkdir(parents=True, exist_ok=True)
        return d / "mock-opencode-state.json"

    @classmethod
    def load(cls) -> State:
        try:
            with cls.path().open(encoding="utf-8") as f:
                raw: Any = json.load(f)
        except FileNotFoundError:
            return cls()
        if not isinstance(raw, dict):
            return cls()
        sessions = [Session.from_wire(s) for s in raw.get("sessions", []) if isinstance(s, dict)]
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
                sid: [m.to_wire() for m in entries] for sid, entries in self.messages.items()
            },
        }
        path = self.path()
        tmp = path.with_name(path.name + ".tmp")
        with tmp.open("w", encoding="utf-8") as f:
            json.dump(payload, f, indent=1)
        tmp.replace(path)


# ------------------------------------------------------------- canned diff
#
# Shaped like the real thing rather than minimally: OpenCode's `Snapshot`
# asks jsdiff for `context: Number.MAX_SAFE_INTEGER`, so every entry is one
# `@@` hunk carrying the *whole* file. A client that renders this has to
# re-hunk it, and a one-line canned patch never exercises that — nor the
# per-file collapse, the gap expansion, the render cap, the binary case, or
# a deletion with nothing to show. This does.


def _whole_file_patch(
    path: str,
    lines: list[str],
    edits: dict[int, list[str] | None],
    status: str,
) -> tuple[str, int, int]:
    """Build a full-context unified patch, the way `Snapshot.diffFull` writes one.

    `edits` maps a 0-based index in `lines` to its replacement lines, or to
    `None` for a deletion. Everything else comes through as context. A file
    that was added has no old side at all, so `edits` is ignored for it and
    every line is an addition — a client that trusts the counts should never
    see an added file reporting deletions.
    """
    body: list[str] = []
    added = removed = 0
    if status == "added":
        body = [f"+{line}" for line in lines]
        added = len(lines)
        old_start, old_n = 0, 0
    else:
        for i, line in enumerate(lines):
            if i not in edits:
                body.append(f" {line}")
                continue
            body.append(f"-{line}")
            removed += 1
            for new in edits[i] or []:
                body.append(f"+{new}")
                added += 1
        old_start, old_n = 1, len(lines)
    new_n = len(lines) - removed + added if status != "added" else len(lines)
    new_start = 0 if new_n == 0 else 1
    head = (
        f"Index: {path}\n"
        "===================================================================\n"
        f"--- a/{path}\n+++ b/{path}\n"
        f"@@ -{old_start},{old_n} +{new_start},{new_n} @@\n"
    )
    return head + "\n".join(body) + "\n", added, removed


def _entry(
    path: str,
    lines: list[str],
    edits: dict[int, list[str] | None],
    status: str = "modified",
) -> Wire:
    patch, added, removed = _whole_file_patch(path, lines, edits, status)
    return {
        "path": path,
        "patch": patch,
        "additions": added,
        "deletions": removed,
        "status": status,
    }


# A short file with two separate edits far enough apart to leave a gap that
# has to be collapsed and can then be expanded.
_CONFIG = [
    "[package]",
    'name = "goose-mobile"',
    'version = "0.1.0"',
    'edition = "2021"',
    "",
    "[dependencies]",
    'dioxus = { version = "0.7", features = ["router"] }',
    'serde = { version = "1", features = ["derive"] }',
    'serde_json = "1"',
    'tokio = { version = "1", features = ["rt", "macros"] }',
    "",
    "[dev-dependencies]",
    'pretty_assertions = "1"',
    "",
    "[profile.release]",
    "lto = true",
    'panic = "abort"',
]

# Long enough to run past the renderer's cap, so the "not all of this is
# shown" path is reachable at all.
_LONG = [f"    let row_{i} = table.row({i});" for i in range(1200)]

DIFF: list[Wire] = [
    _entry(
        "Cargo.toml",
        _CONFIG,
        {2: ['version = "0.2.0"'], 15: ['lto = "fat"', "codegen-units = 1"]},
    ),
    _entry(
        "src/diff.rs",
        [
            "//! Re-hunking a whole-file patch.",
            "",
            "pub fn parse(patch: &str) -> Vec<DiffLine> {",
            "    patch.lines().skip(4).map(DiffLine::from).collect()",
            "}",
        ],
        {
            3: [
                "    patch",
                "        .lines()",
                '        .skip_while(|l| !l.starts_with("@@"))',
                "        .skip(1)",
                "        .map(DiffLine::from)",
                "        .collect()",
            ],
        },
        status="added",
    ),
    _entry(
        "src/legacy_tabs.rs",
        ["pub fn tab_bar() -> Element {", '    rsx! { nav { class: "tabs" } }', "}"],
        {0: None, 1: None, 2: None},
        status="deleted",
    ),
    _entry(
        "src/table.rs",
        _LONG,
        {
            40: ["    let row_40 = table.row(40).cached();"],
            900: ["    let row_900 = table.row(900).cached();"],
        },
    ),
    {"path": "assets/icon.png", "patch": "", "additions": 0, "deletions": 0, "status": "modified"},
]


# ------------------------------------------------------- model catalogue
#
# `GET /config/providers` and `GET /provider` carry the same providers under
# different keys; the client tries the first and falls back to the second, so
# both are served. Models are picked to cover what a client has to handle
# rather than to be realistic about any one vendor:
#
#   - a model with thinking-effort variants, and one with none at all (the
#     minimax/qwen/glm/kimi families genuinely return no variants)
#   - variants deliberately out of ladder order, since the wire shape is a
#     JSON object and a client sorting them alphabetically would put `high`
#     before `low`
#   - context windows spanning three orders of magnitude, including one
#     declared as a float
#   - a name long enough to overflow a chip, and a free model, which the app
#     must withhold from a repo that is not a public throwaway


def _model(
    name: str,
    context: float,
    variants: list[str] | None = None,
) -> Wire:
    return {
        "name": name,
        "limit": {"context": context},
        "variants": {v: {} for v in variants or []},
    }


PROVIDERS: list[Wire] = [
    {
        "id": "opencode",
        "models": {
            "deepseek-v4-flash": _model("DeepSeek V4 Flash", 128000),
            "claude-sonnet-4-5": _model(
                "Claude Sonnet 4.5",
                200000,
                ["high", "low", "medium", "none"],
            ),
            "qwen3-coder-480b": _model("Qwen3 Coder 480B A35B Instruct", 262144),
            "grok-code-fast-free": _model("Grok Code Fast (free)", 256000),
        },
    },
    {
        "id": "anthropic",
        "models": {
            "claude-opus-4-1": _model(
                "Claude Opus 4.1",
                1000000.0,
                ["max", "medium", "xhigh"],
            ),
        },
    },
]


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
            id=f"msg_{secrets.token_hex(4)}",
            role="user",
            session_id=session_id,
        )
        user_part = text_part(user_msg.id, session_id, prompt)
        with STATE_LOCK:
            state = State.load()
            state.messages.setdefault(session_id, []).append(
                StoredMessage(info=user_msg, parts=[user_part]),
            )
            state.save()
        publish("message.updated", {"info": user_msg.to_wire()})
        publish("message.part.updated", {"part": user_part})

        asst = MessageInfo(
            id=f"msg_{secrets.token_hex(4)}",
            role="assistant",
            session_id=session_id,
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
                StoredMessage(info=asst, parts=parts),
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

    def deny(self) -> None:
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="mock"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def handle_any(self) -> None:
        """Authenticate, then dispatch to one route (mirrors the real API)."""
        if not self.authed():
            self.deny()
            return
        path = urlparse(self.path).path
        verb = self.command
        parts = [p for p in path.split("/") if p]
        if (path, verb) == ("/event", "GET"):
            self.stream_events()
        elif (path, verb) == ("/session", "GET"):
            with STATE_LOCK:
                self.send_json(200, [s.to_wire() for s in State.load().sessions])
        elif (path, verb) == ("/session", "POST"):
            self.route_create_session()
        elif (path, verb) == ("/session/status", "GET"):
            self.send_json(200, {sid: {"type": "busy"} for sid in sorted(BUSY)})
        elif (path, verb) == ("/permission", "GET"):
            self.send_json(200, [entry.perm.to_wire() for entry in PENDING.values()])
        elif (path, verb) == ("/config/providers", "GET"):
            self.send_json(200, {"providers": PROVIDERS})
        elif (path, verb) == ("/provider", "GET"):
            self.send_json(200, {"all": PROVIDERS})
        elif len(parts) >= SESSION_PATH_PARTS and parts[0] == "session":
            self.route_session(parts)
        else:
            self.no_route()

    def no_route(self) -> None:
        path = urlparse(self.path).path
        self.send_json(404, {"error": f"mock: no route {self.command} {path}"})

    def route_create_session(self) -> None:
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

    def route_session(self, parts: list[str]) -> None:
        """Dispatch /session/<id>/... — the per-session half of the API."""
        sid, kind, verb = parts[1], parts[2], self.command
        if (kind, verb) == ("message", "GET"):
            with STATE_LOCK:
                entries = State.load().messages.get(sid, [])
                self.send_json(200, [m.to_wire() for m in entries])
        elif (kind, verb) == ("prompt_async", "POST"):
            self.route_prompt(sid)
        elif (kind, verb) == ("abort", "POST"):
            self.route_abort(sid)
        elif (kind, verb) == ("diff", "GET"):
            self.route_diff()
        elif kind == "permissions" and len(parts) == PERMISSION_PATH_PARTS and verb == "POST":
            self.route_permission_reply(parts[3])
        else:
            self.no_route()

    def route_prompt(self, sid: str) -> None:
        body = self.read_json()
        body_parts = body.get("parts", [])
        text = ""
        if isinstance(body_parts, list):
            for part in body_parts:
                if isinstance(part, dict) and part.get("type") == "text":
                    value = part.get("text", "")
                    if isinstance(value, str):
                        text += value
        # The turn carries the model; the session record follows it.
        model = body.get("model")
        if isinstance(model, dict):
            provider = str(model.get("providerID", ""))
            model_id = str(model.get("modelID", "") or model.get("id", ""))
            variant = body.get("variant")
            with STATE_LOCK:
                state = State.load()
                for session in state.sessions:
                    if session.id == sid and provider and model_id:
                        session.model = f"{provider}/{model_id}"
                        session.variant = variant if isinstance(variant, str) else ""
                        state.save()
                        break

        threading.Thread(target=run_turn, args=(sid, text), daemon=True).start()
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def route_abort(self, sid: str) -> None:
        # Resolve any blocked permission so the turn thread finishes.
        for entry in list(PENDING.values()):
            if entry.perm.session_id == sid:
                entry.response = "reject"
                entry.event.set()
        BUSY.discard(sid)
        publish("session.idle", {"sessionID": sid})
        self.send_json(200, obj=True)

    def route_diff(self) -> None:
        self.send_json(200, DIFF)

    def route_permission_reply(self, permission_id: str) -> None:
        entry = PENDING.get(permission_id)
        if entry is None:
            self.send_json(404, {"error": "unknown permission"})
            return
        response = self.read_json().get("response", "reject")
        entry.response = response if isinstance(response, str) else "reject"
        entry.event.set()
        self.send_json(200, obj=True)

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
                if time.time() - last_beat > HEARTBEAT_SECONDS:
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

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        pass  # quiet; the harness asserts on behavior, not logs


def main() -> None:
    # The config is process-wide and set exactly once, here.
    global CONFIG  # noqa: PLW0603
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--dir", required=True, help="the chat volume dir")
    ap.add_argument(
        "--password",
        default=os.environ.get("OPENCODE_SERVER_PASSWORD", "mock"),
    )
    args = ap.parse_args()
    CONFIG = Config(
        port=int(args.port),
        dir=Path(str(args.dir)),
        password=str(args.password),
    )
    server = ThreadingHTTPServer(("127.0.0.1", CONFIG.port), Handler)
    server.daemon_threads = True
    print(  # noqa: T201 — the harness greps stdout for this line
        f"mock-opencode-server: 127.0.0.1:{CONFIG.port} dir={CONFIG.dir}",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
