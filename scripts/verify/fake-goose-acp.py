#!/usr/bin/env python3
"""A stand-in for `goose serve`'s ACP surface, including the parts that are bugs.

WHY IT EXISTS. scripts/pai/goosecfg.py is measured by .coveragerc the instant it
is tracked, and every interesting arm in it -- an allowlist goose silently
dropped, a remove that reports success and does nothing, a server that never
becomes ready, one that dies mid-apply -- only exists against a live server. A
pre-started server would also leave the whole spawn/readiness/teardown class
uncovered, so goosecfg SPAWNS THIS FILE the same way it would spawn goose:
`<binary> serve --host 127.0.0.1 --port P`.

Distinct from scripts/verify/fake-goose.sh ON PURPOSE. That one is a CLI
stand-in that dies on unknown argv and knows nothing about `serve`; merging them
would give one file two incompatible jobs.

EVERY DEFAULT BEHAVIOUR HERE WAS MEASURED against goose 1.46.0 (the transcripts
are in the issue #34 spec):

  * `config/extensions/list` returns `{"extension": {...}, "enabled": bool,
    "configKey": str}` -- `enabled` is a SIBLING of `extension`, not inside it.
  * `config/extensions/add` UPSERTS: an existing configKey is fully replaced.
  * camelCase `availableTools` is ACCEPTED, answers `{"result":{}}`, and the
    read-back then carries NO allowlist key at all.
  * `config/extensions/remove` answers `{"result":{}}` for a key that has never
    existed.
  * an unknown method answers JSON-RPC -32601.
  * `config/read {"key": k, "isSecret": true}` returns a MASKED, non-null value
    for a key in the store. (camelCase `isSecret`; snake_case returns null.)
  * `GOOSE_SERVER__SECRET_KEY` in the environment plus the `X-Secret-Key`
    header: no header 401, wrong key 401, right key 200. Plain http on loopback.
  * `serve --port P` opens TWO listeners, P and P+1.
  * a reply may arrive in the POST body OR on the `GET /acp` SSE channel.

MISBEHAVIOUR IS SELECTED BY $PAI_FAKE_MODE (comma-separated). Each mode is one
measured or one structurally possible failure; the list is in MODES below.

State persists write-through to $PAI_FAKE_CONFIG as JSON -- json rather than
yaml because goosecfg spawns this file with a bare `python3` that may not have
PyYAML, and this file must not acquire a dependency goosecfg refuses.

NEVER PRINTS A SECRET. The configured key is compared, never echoed; `config/read`
returns the same mask goose does and the client never looks at it.
"""

from __future__ import annotations

import json
import os
import queue
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

MODES = {
    "ok",  # the measured, correct behaviour
    "drop-allowlist",  # accept the add, store no allowlist key at all
    "empty-allowlist",  # store available_tools: []
    "camel-allowlist",  # store the allowlist under availableTools
    "truncate-allowlist",  # store all but the last tool
    "mangle-args",  # store the args reversed (a non-allowlist read-back diff)
    "drop-envkeys",  # store the entry without the envKeys it was sent
    "add-noop",  # accept the add and store nothing
    "remove-noop",  # accept the remove and keep the entry
    "ignore-enable",  # accept set-enabled and do not change it
    "no-secret",  # config/read returns a null value for every key
    "rpc-error",  # every config method answers -32601
    "http-500",  # every POST answers HTTP 500
    "auth-401",  # every request answers HTTP 401
    "no-conn-id",  # omit the acp-connection-id header (no SSE channel)
    "bad-init",  # answer initialize with a JSON-RPC error
    "bad-list",  # answer extensions/list without an `extensions` array
    "junk-list",  # put a non-dict and a malformed entry in the array
    "sse-reply",  # answer 202 with an empty body, reply on the SSE channel
    "no-reply",  # answer 202 with an empty body and never reply
    "sse-close",  # close the SSE channel as soon as it is opened
    "sse-401",  # refuse the SSE channel while POST keeps working
    "slow-start",  # bind late
    "never-ready",  # never bind at all
    "die-mid-apply",  # exit hard, without answering, on the first add
    "ignore-sigterm",  # force the SIGKILL escalation in stop()
    "tls",  # https with a self-signed certificate (the brain's shape)
}

_ACP = "_goose/unstable/"
_STATE_LOCK = threading.Lock()
_SSE: queue.Queue[str | None] = queue.Queue()


def modes() -> set[str]:
    """Parse $PAI_FAKE_MODE into a set, rejecting a typo loudly."""
    raw = [m.strip() for m in os.environ.get("PAI_FAKE_MODE", "ok").split(",") if m.strip()]
    unknown = sorted(set(raw) - MODES)
    if unknown:
        sys.exit(f"fake-goose-acp: unknown PAI_FAKE_MODE {unknown}")
    return set(raw)


MODE = modes()


def state_path() -> Path | None:
    """Where write-through lands, or None when the fake is asked to be amnesiac."""
    raw = os.environ.get("PAI_FAKE_CONFIG", "")
    return Path(raw) if raw else None


def load_state() -> dict[str, Any]:
    path = state_path()
    if path is None or not path.is_file():
        return {"extensions": {}, "secrets": {}}
    try:
        data: Any = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"extensions": {}, "secrets": {}}
    if not isinstance(data, dict):
        return {"extensions": {}, "secrets": {}}
    data.setdefault("extensions", {})
    data.setdefault("secrets", {})
    return data


def save_state(state: dict[str, Any]) -> None:
    path = state_path()
    if path is not None:
        path.write_text(json.dumps(state, indent=2), encoding="utf-8")


def config_key_of(extension: dict[str, Any]) -> str:
    server = extension.get("server") or {}
    return str(server.get("name") or extension.get("name") or "unnamed")


def _apply_allowlist(stored: dict[str, Any], allow: object) -> None:
    """Store the allowlist the way the selected mode says goose stored it."""
    if allow is None:
        return
    if "drop-allowlist" in MODE:
        return  # accepted and discarded -- the camelCase failure, reproduced
    if "empty-allowlist" in MODE:
        stored["available_tools"] = []
    elif "camel-allowlist" in MODE:
        stored["availableTools"] = allow
    elif "truncate-allowlist" in MODE:
        stored["available_tools"] = list(allow)[:-1]  # type: ignore[call-overload]
    else:
        stored["available_tools"] = list(allow)  # type: ignore[call-overload]


def _promote_env(stored: dict[str, Any], server: dict[str, Any]) -> None:
    """Consume server.env into the secret store, append the NAMES to env_keys.

    Exactly what goose does, and the reason an inline `envs` value cannot
    survive a write: the values end up nowhere the config can see them.
    """
    promoted = []
    for item in server.pop("env", None) or []:
        if isinstance(item, dict) and item.get("name"):
            promoted.append(str(item["name"]))
            _remember_secret(str(item["name"]), str(item.get("value", "")))
    server["env"] = []
    if promoted:
        keys = [str(k) for k in stored.get("envKeys") or []]
        stored["envKeys"] = keys + [k for k in promoted if k not in keys]


def store_extension(extension: dict[str, Any], *, enabled: bool) -> None:
    """Upsert one extension, mangled according to the mode."""
    stored = json.loads(json.dumps(extension))
    allow = stored.pop("available_tools", None)
    stored.pop("availableTools", None)
    _apply_allowlist(stored, allow)
    if "drop-envkeys" in MODE:
        stored.pop("envKeys", None)
    server = stored.get("server")
    if isinstance(server, dict):
        if "mangle-args" in MODE and isinstance(server.get("args"), list):
            server["args"] = list(reversed(server["args"]))
        _promote_env(stored, server)
    with _STATE_LOCK:
        state = load_state()
        if "add-noop" not in MODE:
            state["extensions"][config_key_of(extension)] = {
                "extension": stored,
                "enabled": enabled,
            }
        save_state(state)


def _remember_secret(name: str, value: str) -> None:
    state = load_state()
    state["secrets"][name] = value
    save_state(state)


def _list_extensions() -> dict[str, Any]:
    with _STATE_LOCK:
        state = load_state()
    if "bad-list" in MODE:
        return {"extensions": "not-an-array"}
    junk: list[Any] = ["not-a-dict", {"configKey": "junk", "extension": "not-a-dict"}] \
        if "junk-list" in MODE else []
    return {
        # `enabled` is a SIBLING of `extension`. This shape is the measured one
        # and it is why LiveEntry cannot just read extension["enabled"].
        "extensions": junk + [
            {"configKey": key, "enabled": bool(row.get("enabled")),
             "extension": row.get("extension") or {}}
            for key, row in sorted(state["extensions"].items())
        ],
    }


def _remove(params: dict[str, Any]) -> dict[str, Any]:
    with _STATE_LOCK:
        state = load_state()
        if "remove-noop" not in MODE:
            state["extensions"].pop(str(params.get("configKey", "")), None)
        save_state(state)
    # SUCCESS EVEN FOR A KEY THAT NEVER EXISTED. Measured; it is exactly why
    # remove_extension has to read back.
    return {}


def _set_enabled(params: dict[str, Any]) -> dict[str, Any]:
    with _STATE_LOCK:
        state = load_state()
        row = state["extensions"].get(str(params.get("configKey", "")))
        if row is not None and "ignore-enable" not in MODE:
            row["enabled"] = bool(params.get("enabled"))
        save_state(state)
    return {}


def _add(params: dict[str, Any]) -> dict[str, Any]:
    if "die-mid-apply" in MODE:
        os._exit(9)
    store_extension(params.get("extension") or {}, enabled=bool(params.get("enabled")))
    return {}


def _read(params: dict[str, Any]) -> dict[str, Any]:
    if not params.get("isSecret"):
        return {"value": None}  # snake_case is_secret lands here, as measured
    with _STATE_LOCK:
        state = load_state()
    value = state["secrets"].get(str(params.get("key", "")))
    if value is None or "no-secret" in MODE:
        return {"value": None}
    return {"value": mask(str(value))}


DISPATCH = {
    f"{_ACP}config/extensions/list": lambda _params: _list_extensions(),
    f"{_ACP}config/extensions/add": _add,
    f"{_ACP}config/extensions/remove": _remove,
    f"{_ACP}config/extensions/set-enabled": _set_enabled,
    f"{_ACP}config/read": _read,
}


def handle(method: str, params: dict[str, Any]) -> dict[str, Any]:
    """Dispatch one config method. Raises KeyError for an unknown one."""
    return DISPATCH[method](params)


def mask(value: str) -> str:
    """Mask like goose does: a prefix in clear, the rest starred. Never the value."""
    keep = min(len(value) // 2, 8)
    return value[:keep] + "*" * (len(value) - keep)


class Handler(BaseHTTPRequestHandler):
    """POST /acp for requests, GET /acp for the SSE reply channel."""

    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        """Silence: the harness reads goosecfg's assertions, not an access log."""

    def _authorised(self) -> bool:
        if "auth-401" in MODE:
            return False
        want = os.environ.get("GOOSE_SERVER__SECRET_KEY", "")
        # Never logged, never echoed, compared only.
        return not want or self.headers.get("X-Secret-Key") == want

    def _send(self, status: int, body: bytes, extra: dict[str, str] | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if "sse-401" in MODE:
            # Only the SSE channel is refused. A client whose reply pump dies
            # must still work for every call answered in the POST body.
            self._send(401, b"{}")
            return
        if not self._authorised():
            self._send(401, b"{}")
            return
        if not self.path.startswith("/acp"):
            self._send(404, b"{}")
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        if "sse-close" in MODE:
            # `Connection: close` AND close_connection: without both, HTTP/1.1
            # keep-alive holds the socket open and the client sees an idle
            # stream rather than the EOF this mode exists to produce.
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            return
        self.end_headers()
        while True:
            line = _SSE.get()
            if line is None:
                return
            try:
                self.wfile.write(f"data: {line}\n\n".encode())
                self.wfile.flush()
            except OSError:
                return

    def do_POST(self) -> None:
        if not self._authorised():
            self._send(401, b"{}")
            return
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        if "http-500" in MODE:
            self._send(500, b"{}")
            return
        try:
            frame = json.loads(raw.decode("utf-8"))
        except ValueError:
            self._send(400, b"{}")
            return
        method = str(frame.get("method", ""))
        rid = frame.get("id")
        if method == "initialize":
            extra = {} if "no-conn-id" in MODE else {"acp-connection-id": "fake-conn-1"}
            result: dict[str, Any] = {"jsonrpc": "2.0", "id": rid}
            if "bad-init" in MODE:
                result["error"] = {"code": -32600, "message": "Invalid Request"}
            else:
                result["result"] = {"protocolVersion": 1}
            self._send(200, json.dumps(result).encode(), extra)
            return
        self._reply(rid, method, frame.get("params") or {})

    def _reply(self, rid: object, method: str, params: dict[str, Any]) -> None:
        if "rpc-error" in MODE:
            payload = {"jsonrpc": "2.0", "id": rid,
                       "error": {"code": -32601, "message": "Method not found"}}
        else:
            try:
                payload = {"jsonrpc": "2.0", "id": rid, "result": handle(method, params)}
            except KeyError:
                payload = {"jsonrpc": "2.0", "id": rid,
                           "error": {"code": -32601, "message": "Method not found"}}
        if "no-reply" in MODE:
            self._send(202, b"")
            return
        if "sse-reply" in MODE:
            # The reply arrives on the OTHER channel. goose does this for some
            # calls and not others, so a client that only reads POST bodies
            # hangs against a real server.
            self._send(202, b"")
            # A notification first: a client that assumes the next SSE frame is
            # its answer breaks against a real server, which interleaves both.
            _SSE.put(json.dumps({"jsonrpc": "2.0", "method": "session/update"}))
            _SSE.put(json.dumps(payload))
            return
        self._send(200, json.dumps(payload).encode())


def self_signed(directory: Path) -> ssl.SSLContext:
    """Mint a throwaway certificate so the `tls` mode looks like the brain.

    The brain's `goose serve` is https with a SELF-SIGNED certificate by design,
    so a verified handshake fails there and goosecfg has a one-time downgrade
    for it. Without this mode that downgrade is only ever exercised in
    production, which is the wrong place to find out.
    """
    cert, key = directory / "cert.pem", directory / "key.pem"
    subprocess.run(  # noqa: S603 -- fixed argv, no shell
        ["/usr/bin/env", "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=127.0.0.1"],
        check=True, capture_output=True,
    )
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(str(cert), str(key))
    return ctx


def serve_forever(host: str, port: int) -> None:
    """Bind P (and opportunistically P+1, exactly as goose does) and serve."""
    if "never-ready" in MODE:
        while True:  # bound to nothing; the readiness deadline is the assertion
            time.sleep(3600)
    if "slow-start" in MODE:
        time.sleep(float(os.environ.get("PAI_FAKE_SLOW_S", "5")))
    main = ThreadingHTTPServer((host, port), Handler)
    if "tls" in MODE:
        with tempfile.TemporaryDirectory() as tmp:
            main.socket = self_signed(Path(tmp)).wrap_socket(main.socket, server_side=True)
            _open_neighbour(host, port + 1)
            main.serve_forever()
            return
    _open_neighbour(host, port + 1)
    main.serve_forever()


def _open_neighbour(host: str, port: int) -> None:
    """Open the second listener goose opens at P+1; when P+1 is taken, it just does not."""
    try:
        extra = ThreadingHTTPServer((host, port), Handler)
    except OSError:
        return
    threading.Thread(target=extra.serve_forever, daemon=True).start()


def main(argv: list[str]) -> int:
    """Accept real goose's argv: `serve --host H --port P`, extra flags ignored."""
    if not argv or argv[0] != "serve":
        sys.stderr.write(f"fake-goose-acp: unsupported argv {argv}\n")
        return 2
    host, port = "127.0.0.1", 0
    rest = argv[1:]
    for index, word in enumerate(rest):
        if word == "--host" and index + 1 < len(rest):
            host = rest[index + 1]
        elif word == "--port" and index + 1 < len(rest):
            port = int(rest[index + 1])
    if not port:
        sys.stderr.write("fake-goose-acp: --port is required\n")
        return 2
    if "ignore-sigterm" in MODE:
        # Forces stop()'s wait->SIGKILL escalation, which is otherwise only
        # reachable against a server that hangs on shutdown.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    socket.setdefaulttimeout(None)
    serve_forever(host, port)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
