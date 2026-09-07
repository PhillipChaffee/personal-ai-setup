#!/usr/bin/env python3
"""Talk to a running `goose serve` over ACP, and PROVE what it stored.

WHY THIS FILE EXISTS. goose serde-round-trips ~/.config/goose/config.yaml, so
editing that file is not a way to configure goose -- the next thing goose writes
erases the comments and can drop a key it did not understand. The supported
surface is the ACP config API, and that API is fail-open in two measured ways:

  * `config/extensions/add` accepts camelCase `availableTools`, answers
    `{"result":{}}`, and stores an entry with NO allowlist key at all. An absent
    allowlist means EVERY tool is allowed.
  * `config/extensions/remove` answers `{"result":{}}` for a configKey that has
    never existed.

Both mean the same thing: SUCCESS FROM THE CALL IS NOT EVIDENCE. Every write in
this module is followed by a read-back that has to agree, and the read-back is
the only thing any caller is allowed to believe. That is the whole design.

TWO LAYERS, SPELLED DIFFERENTLY (config/connectors/README.md has the full
table). The ACP wire says `type: mcp` with a nested `server` of `type: stdio |
http`, fields `command`/`url`, `envKeys`, and `headers` as a LIST of
{name, value}. config.yaml on disk says `type: stdio | streamable_http`, fields
`cmd`/`uri`, `env_keys`, and `headers` as a MAPPING. `to_wire` and
`LiveEntry.to_disk` are the two directions of that translation, and nothing
else in this repo should be doing it by hand.

`enabled` IS A SIBLING OF `extension` in the list response, not a field inside
it -- measured against 1.46.0. `to_disk()` merges it back, because every caller
compares against a template block where `enabled` sits with the rest.

`envs` IS A DOCUMENTED LOSSY FIELD, measured on 1.46.0:

    any ACP write leaves disk `envs: {}`; `envs` is not readable over ACP in
    either direction; sending `server.env: [{name, value}]` PROMOTES the value
    into goose's secret store, appends the name to `env_keys`, and still leaves
    disk `envs: {}`.

So an inline `envs` value cannot survive a write, and a caller that has one is
performing a one-way migration into the secret store, not an update. This
module proves the promotion landed with `config/read {key, isSecret: true}`
returning non-null -- it NEVER looks at, returns, or reports the value. (goose
masks it, but "masked" is still a prefix, and this repo's rule is that a secret
value never reaches a log or an assertion message.)

NO PRINTING, NO PROSE. Failures are typed exceptions carrying a machine-readable
`reason` from `Reason` plus a short structural `detail`. The sentences belong to
the callers -- scripts/verify/check-connectors.sh and, later, `pai doctor --fix`
-- because they are the ones with a reader.

Stdlib only, on purpose: `pai doctor` must run on a brain that has PyYAML and on
a Mac that may not, and this module is imported by a shell verifier over
PYTHONPATH. Callers pass dicts; nothing here parses YAML.

Offline test double: scripts/verify/fake-goose-acp.py reproduces every measured
behaviour above, including the ones that are bugs.
"""

from __future__ import annotations

import atexit
import contextlib
import json
import os
import queue
import re
import secrets
import signal
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any, Final

if TYPE_CHECKING:
    import types
    from collections.abc import Iterable, Iterator, Mapping, Sequence
    from typing import Self

# Exactly the ACP methods this module calls, and nothing it does not.
# scripts/verify/check-connectors.sh imports this tuple and asserts every entry
# is still in the vendored contract at the pinned tag, so the assertion and the
# caller cannot drift -- and so that SOMETHING offline actually executes
# `import goosecfg` (a PYTHONPATH typo would otherwise ship green).
ACP_METHODS: Final[tuple[str, ...]] = (
    "_goose/unstable/config/extensions/list",
    "_goose/unstable/config/extensions/add",
    "_goose/unstable/config/extensions/remove",
    "_goose/unstable/config/extensions/set-enabled",
    "_goose/unstable/config/read",
)

# The template fields a caller may have an opinion about. Deliberately the same
# vocabulary as doctor.py's DECLARED_FIELDS -- the harness asserts the two
# tuples are equal, because a field in one and not the other is drift nobody
# would see. They are not shared by import: doctor.py needs PyYAML and this
# module must not.
DISK_FIELDS: Final[tuple[str, ...]] = (
    "enabled",
    "type",
    "cmd",
    "args",
    "env_keys",
    "available_tools",
    "uri",
    "timeout",
)

# A template value equal to one of these, or wrapped in angle brackets, is a
# placeholder the reader was told to replace. THE TWIN OF doctor.is_placeholder,
# duplicated rather than imported for the dependency reason above; the harness
# asserts the two agree on the same inputs.
PLACEHOLDER_LITERALS: Final[frozenset[str]] = frozenset({"you@example.com"})

# goose serve opens a SECOND, opportunistic listener at port+1 (measured: P+1
# 404s on /status). These are the ports this repo has already spent -- the
# brain's goose, the local roundtrip recipe, and the code-agent manager's range
# -- so an ephemeral server must never land on one, or on the P+1 next to one.
RESERVED_PORTS: Final[frozenset[int]] = frozenset({3284, 3288, 4397, 4398, 4399})

_SPAWN_TRIES: Final = 3
_PORT_TRIES: Final = 8
_POLL_S: Final = 0.02
_MARKER_DIR_NAME: Final = "pai-goosecfg"

# The one env var this module MINTS and hands to a child. Named here because the
# child's stderr is reported verbatim inside ServerError, and that exception is
# printed -- by check-connectors.sh today, by `pai doctor --fix` next. A server
# that panics with an environment dump would otherwise put a live key on a
# terminal, which this repo's rule forbids outright.
_MINTED_ENV: Final = "GOOSE_SERVER__SECRET_KEY"
_MINTED_ASSIGN: Final = re.compile(rf"{_MINTED_ENV}\s*[=:]\s*\S*")


def _redact(text: str, secret: str) -> str:
    """Strip the minted server key out of anything a child wrote, before reporting it.

    RESIDUAL, stated rather than hidden: `_spawn` gives the child a copy of this
    process's whole environment, so a crash dump can still carry a secret this
    module never chose. Nothing here can fix that; not running a goose that
    prints its environment is what fixes it.
    """
    scrubbed = _MINTED_ASSIGN.sub(f"{_MINTED_ENV}=<redacted>", text)
    # `or "\0"` because str.replace("") splices the marker between every single
    # character; a NUL is the one thing that cannot meaningfully appear in text
    # already decoded with errors="replace".
    return scrubbed.replace(secret or "\0", "<redacted>")


def _float_env(name: str, default: float) -> float:
    """Read a float tuning seam from the environment, ignoring nonsense."""
    try:
        return float(os.environ[name])
    except (KeyError, ValueError):
        return default


class Reason:
    """The `reason` codes on every exception below.

    Codes, not sentences: a caller that wants to say something different about
    a camelCase spelling than about an empty list has to be able to tell them
    apart without matching on English.
    """

    # transport / server
    TRANSPORT = "transport"
    AUTH = "auth"
    RPC_ERROR = "rpc-error"
    BAD_RESPONSE = "bad-response"
    NO_BINARY = "no-binary"
    NO_PORT = "no-port"
    NOT_READY = "not-ready"
    LEFT_RUNNING = "left-running"
    FOREIGN_GOOSE = "foreign-goose"
    # read-back
    NOT_LISTED = "not-listed"
    NOT_ENABLED = "not-enabled"
    STILL_LISTED = "still-listed"
    FIELD_DIFFERS = "field-differs"
    ENV_NOT_PROMOTED = "env-not-promoted"
    # allowlist (each one is a different remedy, so each one is its own code)
    NO_ALLOWLIST = "no-allowlist"
    ALLOWLIST_DROPPED = "allowlist-dropped"
    ALLOWLIST_EMPTY = "allowlist-empty"
    ALLOWLIST_MISSPELLED = "allowlist-misspelled"
    ALLOWLIST_DIFFERS = "allowlist-differs"


class GooseCfgError(RuntimeError):
    """Base class. `reason` is from `Reason`; `detail` is structural, never prose."""

    def __init__(self, reason: str, detail: str = "") -> None:
        super().__init__(f"{reason}: {detail}" if detail else reason)
        self.reason = reason
        self.detail = detail


class TransportError(GooseCfgError):
    """Nothing answered, or the answer never arrived."""


class AuthError(GooseCfgError):
    """HTTP 401/403 -- the secret key is absent or wrong for this server."""


class RpcError(GooseCfgError):
    """A JSON-RPC error frame. -32601 is the shape a renamed method takes."""

    def __init__(self, code: int, message: str) -> None:
        super().__init__(Reason.RPC_ERROR, f"{code} {message}")
        self.code = code
        self.message = message


class ReadBackError(GooseCfgError):
    """The write reported success and the read-back disagrees. See the module docstring."""


class AllowlistError(ReadBackError):
    """The allowlist specifically -- the one field whose failure mode is fail-OPEN.

    `spelling` is how the stored allowlist was keyed, when there was one at all:
    "available_tools", "availableTools", or None for absent.
    """

    def __init__(self, reason: str, detail: str = "", *, spelling: str | None = None) -> None:
        super().__init__(reason, detail)
        self.spelling = spelling


class ServerError(GooseCfgError):
    """Spawning, readiness or teardown of an ephemeral `goose serve`."""


# --------------------------------------------------------------------------
# The two-layer translation
# --------------------------------------------------------------------------


def looks_like_placeholder(value: object) -> bool:
    """Return True when a template value is meant to be replaced by the reader."""
    if not isinstance(value, str):
        return False
    if value in PLACEHOLDER_LITERALS:
        return True
    return value.startswith("<") and value.endswith(">")


@dataclass(frozen=True)
class LiveEntry:
    """One element of `config/extensions/list`, as goose actually returns it."""

    config_key: str
    enabled: bool
    extension: dict[str, Any]

    def allowlist(self) -> tuple[list[str] | None, str | None]:
        """Return (stored allowlist, how it was spelled). (None, None) when absent.

        Both spellings are looked for because "goose stored nothing" and "goose
        stored it under a name that does nothing" are different findings with
        different remedies, and only this function can tell them apart.
        """
        for spelling in ("available_tools", "availableTools"):
            if spelling in self.extension:
                stored = self.extension[spelling]
                return (list(stored) if isinstance(stored, list) else []), spelling
        return None, None

    def to_disk(self) -> dict[str, Any]:
        """Project the wire entry into config.yaml's vocabulary (see DISK_FIELDS)."""
        server = self.extension.get("server") or {}
        # `enabled` is a SIBLING of `extension` on the wire. Merging it back is
        # not cosmetic: without it every comparison against a template block
        # false-FAILs on `enabled` and a --fix loop never converges.
        disk: dict[str, Any] = {"enabled": self.enabled}
        # `server.type` is not echoed, so the transport is inferred from the
        # shape. A builtin/platform entry (goose's own `apps`, `memory`) has
        # neither key and gets no `type` -- correct, since nothing declares one.
        if "command" in server:
            disk["type"] = "stdio"
            disk["cmd"] = server.get("command")
            disk["args"] = list(server.get("args") or ())
        elif "url" in server:
            disk["type"] = "streamable_http"
            disk["uri"] = server.get("url")
        # ABSENT MEANS EMPTY, and it is asymmetric: measured on one transcript,
        # `envKeys` is OMITTED when empty while a stdio server's `env` is echoed
        # as `[]`. Normalised here rather than at the comparison, or playwright
        # and tavily -- which declare `env_keys: []` -- read as drifted forever.
        disk["env_keys"] = list(self.extension.get("envKeys") or ())
        stored, _ = self.allowlist()
        if stored is not None:
            disk["available_tools"] = stored
        if "timeout" in self.extension:
            disk["timeout"] = self.extension["timeout"]
        return disk


def to_wire(name: str, disk: dict[str, Any], envs: Mapping[str, str]) -> dict[str, Any]:
    """Build the ACP `extension` payload for one config.yaml block.

    `envs` becomes `server.env` on a stdio server -- which is a MIGRATION, not
    an update: goose consumes those values into its secret store and writes
    `envs: {}` back to disk. The http variant has no `env` field at all, so a
    remote server's envs are silently not sendable and the caller's read-back
    is what says so.
    """
    server: dict[str, Any] = {"name": name}
    if disk.get("type") == "stdio" or "cmd" in disk:
        server["type"] = "stdio"
        server["command"] = disk.get("cmd")
        server["args"] = [str(a) for a in disk.get("args") or ()]
        server["env"] = [{"name": k, "value": envs[k]} for k in sorted(envs)]
    else:
        server["type"] = "http"
        server["url"] = disk.get("uri")
        # A mapping on disk, a LIST of {name, value} on the wire. goose cannot
        # deserialize the mapping form and rejects the whole add -- which is the
        # safe failure, but only if we never send it.
        headers = disk.get("headers") or {}
        server["headers"] = [{"name": k, "value": headers[k]} for k in sorted(headers)]
    extension: dict[str, Any] = {"type": "mcp", "server": server}
    if disk.get("env_keys"):
        extension["envKeys"] = [str(k) for k in disk["env_keys"]]
    if disk.get("available_tools"):
        extension["available_tools"] = [str(t) for t in disk["available_tools"]]
    if disk.get("timeout") is not None:
        extension["timeout"] = disk["timeout"]
    return extension


# --------------------------------------------------------------------------
# The client
# --------------------------------------------------------------------------


def _unverified_context() -> ssl.SSLContext:
    """Build a context that skips verification, written the way ruff accepts.

    `ssl._create_unverified_context()` is the same thing and costs SLF001+S323;
    this spelling lints clean. Needed because `goose serve`'s certificate is
    self-signed BY DESIGN -- real clients pin its fingerprint -- so a verified
    handshake fails against a correctly configured brain.
    """
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _is_tls_failure(exc: urllib.error.URLError) -> bool:
    """Report whether a URLError is a certificate problem rather than a dead socket."""
    return isinstance(exc.reason, ssl.SSLError)


def _load_object(text: str) -> dict[str, Any] | None:
    """Parse one JSON object, or None -- a frame that is neither is not a reply."""
    try:
        parsed: Any = json.loads(text)
    except ValueError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _parse_body(text: str) -> dict[str, Any] | None:
    """Parse a JSON-RPC frame from a POST body OR from a `data:` SSE line."""
    body = text.strip()
    if not body:
        return None
    if body.startswith("{"):
        return _load_object(body)
    for raw in body.splitlines():
        line = raw.strip()
        if line.startswith("data:"):
            found = _load_object(line[5:].strip())
            if found is not None:
                return found
    return None


class AcpClient:
    """One ACP session. Use as a context manager: `__enter__` does `initialize`.

    Replies to a request may arrive in the POST body OR on the separate
    `GET /acp` SSE channel, depending on how goose feels about the call. Both
    are read; the SSE pump is a daemon thread started only when goose issued a
    connection id, because without one there is no channel to read.
    """

    def __init__(self, url: str, secret: str = "", timeout_s: float = 30.0) -> None:
        self.url = url
        self.timeout_s = timeout_s
        self.downgraded = False
        # Never logged, never in an exception, never on an argv.
        self._secret = secret
        self._ctx: ssl.SSLContext | None = None
        self._conn = ""
        self._rid = 1
        self._replies: queue.Queue[dict[str, Any] | None] = queue.Queue()
        self._pump: threading.Thread | None = None

    def __enter__(self) -> Self:
        self._initialize()
        return self

    def __exit__(self, *exc: object) -> None:
        # The pump is a daemon thread blocked on a socket read; there is no
        # portable way to interrupt it and no reason to -- dropping the queue
        # sentinel is what a later call would have needed.
        self._pump = None

    # ---- transport --------------------------------------------------------

    def _headers(self, extra: Mapping[str, str] | None = None) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self._secret:
            headers["X-Secret-Key"] = self._secret
        if self._conn:
            headers["Acp-Connection-Id"] = self._conn
        headers.update(extra or {})
        return headers

    def _open(
        self,
        req: urllib.request.Request,
        timeout: float | None,
    ) -> Any:  # noqa: ANN401 -- http.client response
        """Open one connection, downgrading TLS verification at most once.

        `timeout` is None for the SSE channel and only for it: that stream is
        long-lived and IDLE BY NATURE, so giving it the per-request deadline
        tears it down after `timeout_s` of quiet and every reply that was going
        to arrive on it reads as "the channel closed".
        """
        try:
            return urllib.request.urlopen(  # noqa: S310 -- URL is ours, http/https only
                req, timeout=timeout, context=self._ctx,
            )
        except urllib.error.HTTPError:
            raise
        except urllib.error.URLError as exc:
            if not _is_tls_failure(exc) or self.downgraded:
                raise
            self._ctx = _unverified_context()
            self.downgraded = True
            return urllib.request.urlopen(  # noqa: S310 -- same URL, verification downgraded
                req, timeout=timeout, context=self._ctx,
            )

    def _post(self, frame: dict[str, Any]) -> tuple[int, dict[str, Any] | None, dict[str, str]]:
        req = urllib.request.Request(  # noqa: S310 -- loopback/tailnet ACP endpoint
            self.url, data=json.dumps(frame).encode(), headers=self._headers(), method="POST",
        )
        try:
            with self._open(req, self.timeout_s) as resp:
                text = resp.read().decode("utf-8", "replace")
                return int(resp.status), _parse_body(text), dict(resp.headers)
        except urllib.error.HTTPError as exc:
            return int(exc.code), None, dict(exc.headers or {})
        except (urllib.error.URLError, OSError, ValueError) as exc:
            raise TransportError(Reason.TRANSPORT, type(exc).__name__) from exc

    def _initialize(self) -> None:
        status, body, headers = self._post({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": 1,
                "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}},
            },
        })
        self._raise_for_status(status)
        if body is None or "error" in body:
            raise TransportError(Reason.BAD_RESPONSE, f"initialize -> HTTP {status}")
        self._conn = headers.get("acp-connection-id") or headers.get("Acp-Connection-Id") or ""
        if self._conn:
            self._pump = threading.Thread(target=self._sse_pump, daemon=True)
            self._pump.start()

    def _sse_pump(self) -> None:
        req = urllib.request.Request(  # noqa: S310 -- same endpoint as _post
            self.url, headers=self._headers({"Accept": "text/event-stream"}), method="GET",
        )
        try:
            with self._open(req, None) as resp:
                for raw in resp:
                    message = _parse_body(raw.decode("utf-8", "replace"))
                    if message is not None:
                        self._replies.put(message)
        except (urllib.error.URLError, OSError, ValueError):
            # A dead SSE channel is reported by the sentinel below, at the call
            # that needed it -- a thread has nobody to raise at.
            pass
        finally:
            self._replies.put(None)

    @staticmethod
    def _raise_for_status(status: int) -> None:
        if status in (401, 403):
            raise AuthError(Reason.AUTH, f"HTTP {status}")
        if status not in (200, 202):
            raise TransportError(Reason.TRANSPORT, f"HTTP {status}")

    def _await_reply(self, rid: int, method: str) -> dict[str, Any]:
        deadline = time.monotonic() + self.timeout_s
        while True:
            # Clamped at zero rather than pre-checked: a deadline already past
            # and a deadline that expires while waiting are the same failure,
            # and Queue.get raises ValueError on a negative timeout.
            remaining = max(deadline - time.monotonic(), 0.0)
            try:
                candidate = self._replies.get(timeout=remaining)
            except queue.Empty:
                raise TransportError(Reason.TRANSPORT, f"reply timeout: {method}") from None
            if candidate is None:
                raise TransportError(Reason.TRANSPORT, f"sse closed: {method}")
            if candidate.get("id") == rid:
                return candidate

    def call(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        """One JSON-RPC request. Returns `result`; every failure is an exception."""
        self._rid += 1
        rid = self._rid
        status, body, _ = self._post(
            {"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}},
        )
        self._raise_for_status(status)
        message = body if body is not None and body.get("id") == rid else self._await_reply(
            rid, method,
        )
        if "error" in message:
            error = message["error"] or {}
            raise RpcError(int(error.get("code", 0)), str(error.get("message", "")))
        result = message.get("result")
        return result if isinstance(result, dict) else {}

    # ---- the five calls ---------------------------------------------------

    def list_extensions(self) -> list[LiveEntry]:
        """Every configured extension. `enabled` is read from the SIBLING key."""
        result = self.call(ACP_METHODS[0])
        raw = result.get("extensions")
        if not isinstance(raw, list):
            raise TransportError(Reason.BAD_RESPONSE, "list: no extensions array")
        entries = []
        for item in raw:
            if not isinstance(item, dict):
                continue
            extension = item.get("extension")
            entries.append(
                LiveEntry(
                    config_key=str(item.get("configKey", "")),
                    enabled=bool(item.get("enabled")),
                    extension=extension if isinstance(extension, dict) else {},
                ),
            )
        return entries

    def get(self, config_key: str) -> LiveEntry | None:
        """Return the live entry for a configKey, or None. THE read-back primitive."""
        for entry in self.list_extensions():
            if entry.config_key == config_key:
                return entry
        return None

    def add(self, extension: dict[str, Any], *, enabled: bool) -> None:
        """Upsert. On an existing configKey this is a FULL REPLACE, not a merge."""
        self.call(ACP_METHODS[1], {"extension": extension, "enabled": enabled})

    def remove(self, config_key: str) -> None:
        """Delete. Returns success for a key that never existed -- see remove_extension."""
        self.call(ACP_METHODS[2], {"configKey": config_key})

    def set_enabled(self, config_key: str, *, enabled: bool) -> None:
        """Flip one extension. Proven to work on `apps`, the security-relevant one."""
        self.call(ACP_METHODS[3], {"configKey": config_key, "enabled": enabled})

    def secret_is_set(self, key: str) -> bool:
        """Report whether goose's secret store holds `key`. THE VALUE IS NEVER RETURNED.

        `isSecret` is camelCase; snake_case `is_secret` returns null, which
        would read as "absent" for every key that exists.
        """
        try:
            result = self.call(ACP_METHODS[4], {"key": key, "isSecret": True})
        except RpcError:
            return False
        return result.get("value") is not None


# --------------------------------------------------------------------------
# Apply / remove, with the read-back that is the point
# --------------------------------------------------------------------------


def prove_allowlist(entry: LiveEntry, sent: Sequence[str]) -> None:
    """Prove a live entry's allowlist is the one that was sent.

    Public because it has two callers: apply_extension below, and
    scripts/verify/check-connectors.sh --acp-roundtrip, which sends a manifest's
    wire payload rather than a config.yaml block and would otherwise carry its
    own copy of this proof.

    Four distinct failures, because each one has a different remedy.
    """
    stored, spelling = entry.allowlist()
    if stored is None:
        raise AllowlistError(Reason.ALLOWLIST_DROPPED, entry.config_key, spelling=None)
    if spelling != "available_tools":
        raise AllowlistError(Reason.ALLOWLIST_MISSPELLED, entry.config_key, spelling=spelling)
    if not stored:
        raise AllowlistError(Reason.ALLOWLIST_EMPTY, entry.config_key, spelling=spelling)
    if set(stored) != set(sent):
        missing = ",".join(sorted(set(sent) - set(stored))) or "-"
        extra = ",".join(sorted(set(stored) - set(sent))) or "-"
        raise AllowlistError(
            Reason.ALLOWLIST_DIFFERS,
            f"{entry.config_key} sent-not-stored={missing} stored-not-sent={extra}",
            spelling=spelling,
        )


def _prove_fields(entry: LiveEntry, disk: dict[str, Any], promoted: Iterable[str]) -> None:
    """Compare every declared field except the two that are proven elsewhere."""
    live = entry.to_disk()
    for field in DISK_FIELDS:
        if field in ("enabled", "available_tools") or field not in disk:
            continue
        want = disk[field]
        got = live.get(field)
        if field == "env_keys":
            # goose APPENDS the NAME of every promoted env value to env_keys, so
            # a successful migration legitimately widens this list. Equality here
            # would false-FAIL on exactly the operation that just worked.
            keys: set[Any] = set(got or ())
            if set(want) <= keys and keys - set(want) <= set(promoted):
                continue
            raise ReadBackError(Reason.FIELD_DIFFERS, f"{entry.config_key}.{field}")
        if got != want:
            raise ReadBackError(Reason.FIELD_DIFFERS, f"{entry.config_key}.{field}")


def _prove_envs(client: AcpClient, entry: LiveEntry, sent: Mapping[str, str]) -> None:
    """Require each promoted env NAME in env_keys and set in the secret store."""
    keys = entry.extension.get("envKeys") or []
    for key in sorted(sent):
        if key not in keys or not client.secret_is_set(key):
            raise ReadBackError(Reason.ENV_NOT_PROMOTED, f"{entry.config_key}.{key}")


def _prove_added(entry: LiveEntry | None, name: str) -> LiveEntry:
    if entry is None:
        raise ReadBackError(Reason.NOT_LISTED, name)
    return entry


def _prove_enabled(entry: LiveEntry | None, name: str) -> LiveEntry:
    if entry is None or not entry.enabled:
        raise ReadBackError(Reason.NOT_ENABLED, name)
    return entry


def apply_extension(
    client: AcpClient,
    name: str,
    disk: dict[str, Any],
    *,
    envs: Mapping[str, str],
    enable: bool,
) -> LiveEntry:
    """Write one config.yaml block through ACP and prove goose kept it.

    First failure wins, and NOTHING IS ENABLED UNTIL EVERYTHING IS PROVEN: the
    add is always `enabled: False`, and the enable is a second call after the
    read-back agreed. On any failure after the write, the pre-image's enabled
    state is restored -- a crash between the two otherwise leaves a working
    extension switched off.

    TWO REFUSALS, NOT ONE. An extension with no allowlist is APPLIED and left
    disabled; only `enable=True` is refused. playwright and tavily ship exactly
    that way, and collapsing the two would make them permanently unfixable.

    If the server dies mid-apply the restore cannot run either, so the window
    fails CLOSED: the extension is left disabled, which is the safe end.
    """
    pre = client.get(name)
    allow = disk.get("available_tools")
    declared = allow if isinstance(allow, list) and allow else None
    if enable and declared is None:
        raise AllowlistError(Reason.NO_ALLOWLIST, name, spelling=None)
    if "availableTools" in disk:
        # Accepted by goose, stored as nothing, every tool allowed. Refused here
        # rather than reported, which is a deliberate behaviour change from the
        # NOTE check-connectors.sh used to print.
        raise AllowlistError(Reason.ALLOWLIST_MISSPELLED, name, spelling="availableTools")
    sending = {k: v for k, v in envs.items() if not looks_like_placeholder(v)}
    client.add(to_wire(name, disk, sending), enabled=False)
    try:
        entry = _prove_added(client.get(name), name)
        if declared is not None:
            prove_allowlist(entry, declared)
        _prove_fields(entry, disk, sending)
        _prove_envs(client, entry, sending)
        if enable:
            client.set_enabled(name, enabled=True)
            entry = _prove_enabled(client.get(name), name)
    except GooseCfgError:
        with contextlib.suppress(GooseCfgError):
            client.set_enabled(name, enabled=bool(pre is not None and pre.enabled))
        raise
    return entry


def remove_extension(client: AcpClient, config_key: str) -> None:
    """Delete an extension and PROVE it is gone.

    The read-back is not belt-and-braces: `config/extensions/remove` answers
    `{"result":{}}` for a configKey that has never existed, so success from the
    call carries no information at all.
    """
    client.remove(config_key)
    if client.get(config_key) is not None:
        raise ReadBackError(Reason.STILL_LISTED, config_key)


# --------------------------------------------------------------------------
# The ephemeral server
# --------------------------------------------------------------------------


def _ephemeral_port() -> int:
    """One free port from the OS, released immediately."""
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _port_is_open(port: int) -> bool:
    with socket.socket() as sock:
        sock.settimeout(0.5)
        return sock.connect_ex(("127.0.0.1", port)) == 0


def _marker_dir() -> Path:
    directory = Path(tempfile.gettempdir()) / _MARKER_DIR_NAME
    directory.mkdir(mode=0o700, exist_ok=True)
    return directory


def _write_marker(pid: int, port: int, binary: str) -> Path:
    """Record a spawned server AT SPAWN, not after readiness.

    `Popen` fills `.pid` before it returns, so this lands immediately. A marker
    written after the readiness probe leaves the whole spawn->ready window
    unreapable, which is exactly the window a SIGKILL'd parent leaks in.
    """
    path = _marker_dir() / f"{pid}.json"
    payload = json.dumps({"pid": pid, "port": port, "binary": binary, "started": time.time()})
    path.write_text(payload, encoding="utf-8")
    path.chmod(0o600)
    return path


def _argv_is_goose(argv: str, binary: str) -> bool:
    """Report whether a process argv looks like the ACP server this module spawns."""
    words = argv.split()
    return "serve" in words and any(Path(binary).name in word for word in words)


def _pid_argv(pid: int) -> str:
    """Read the argv of a live pid, or '' -- so a recycled pid is never killed blind."""
    try:
        out = subprocess.run(  # noqa: S603 -- fixed argv, no shell
            ["/bin/ps", "-p", str(pid), "-o", "args="],
            check=False, capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip()


def _ps_lines() -> list[str]:
    """List `pid argv` for every process this uid owns, or [] when ps cannot run."""
    try:
        out = subprocess.run(  # noqa: S603 -- fixed argv, no shell
            ["/bin/ps", "-u", str(os.getuid()), "-o", "pid=,args="],
            check=False, capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    return out.stdout.splitlines()


def foreign_goose_pids(lines: Iterable[str]) -> list[int]:
    """Find the pids of a `goose serve` this process did not start.

    Two writers on one config.yaml is a lost update, not a race we can win, so
    the answer is to refuse and name the remedy (`GOOSE_ACP_URL`) rather than to
    spawn a second one. On the brain `goose-serve.service` is permanent, which
    is why --fix there must always be pointed at it.
    """
    mine = os.getpid()
    found = []
    for line in lines:
        head, _, rest = line.strip().partition(" ")
        if not head.isdigit() or int(head) == mine:
            continue
        if _argv_is_goose(rest, "goose"):
            found.append(int(head))
    return found


def _killpg(pid: int, sig: int) -> None:
    # start_new_session=True makes the child its own process-group leader, so
    # pgid == pid and killing the group takes both listeners with it. An already
    # dead child is not an error here, it is the goal.
    with contextlib.suppress(OSError):
        os.killpg(pid, sig)


# Every live server, so a signal or interpreter exit can reach one that no
# frame still holds. stop() is idempotent, which is what makes three
# independent teardown paths safe.
_LIVE: Final[list[EphemeralGoose]] = []
_SAVED: Final[dict[int, Any]] = {}
_SIGNALS: Final[tuple[int, ...]] = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)


def _reap_markers(binary: str) -> None:
    """Kill and forget every server a previous run left behind.

    Guarded by the recorded argv: pids are recycled, and killing a stranger's
    process because it inherited a number is a much worse bug than a leak. Also
    guarded by _LIVE, because start() reaps -- without it, a second ephemeral
    server would kill the first one this same process is still using.
    """
    ours = {server.proc.pid for server in _LIVE if server.proc is not None}
    for path in sorted(_marker_dir().glob("*.json")):
        try:
            data: Any = json.loads(path.read_text(encoding="utf-8"))
            pid = int(data["pid"])
        except (OSError, ValueError, KeyError, TypeError):
            path.unlink(missing_ok=True)
            continue
        if pid in ours:
            continue
        if _argv_is_goose(_pid_argv(pid), str(data.get("binary", binary))):
            _killpg(pid, signal.SIGKILL)
        path.unlink(missing_ok=True)


def _install_signals() -> None:
    for sig in _SIGNALS:
        if sig not in _SAVED:
            # Only the main thread may install handlers; a caller on a worker
            # thread still gets atexit and try/finally.
            with contextlib.suppress(ValueError):
                _SAVED[sig] = signal.signal(sig, _on_signal)


def _restore_signals() -> None:
    if _LIVE:
        return
    while _SAVED:
        sig, previous = _SAVED.popitem()
        with contextlib.suppress(ValueError):
            signal.signal(sig, previous)


def _on_signal(signum: int, frame: types.FrameType | None) -> None:
    """Stop every live server, restore the saved disposition, re-raise.

    SIGHUP is in the set on purpose: `start_new_session=True` detaches the child
    from the terminal, and bin/pai and cli.sh both `exec`, so no shell frame
    survives to trap anything on the way down.
    """
    del frame
    for server in _LIVE[:]:
        with contextlib.suppress(GooseCfgError):
            server.stop()
    _restore_signals()
    signal.raise_signal(signum)


def _stop_all() -> None:
    for server in _LIVE[:]:
        with contextlib.suppress(GooseCfgError):
            server.stop()


atexit.register(_stop_all)


class EphemeralGoose:
    """A `goose serve` this process owns, on loopback, for the length of one fix.

    NO `--dangerously-unauthenticated`. A fresh `secrets.token_hex(32)` goes
    into the child's environment as GOOSE_SERVER__SECRET_KEY and comes back as
    the `X-Secret-Key` header; measured against 1.46.0, no header is 401, a
    wrong key is 401, the right key is 200 over plain http on loopback. The
    secret is never printed, never logged and never on the argv -- where `ps`
    would show it. It IS in the child's environment, which the same uid can
    read; that is the residual, and it is strictly smaller than turning
    authentication off.
    """

    def __init__(self, binary: str | None = None, env: Mapping[str, str] | None = None) -> None:
        self.binary = binary or os.environ.get("PAI_GOOSE_BIN") or "goose"
        self.env = dict(env or {})
        self.url = ""
        self.port = 0
        self.secret = ""
        self.proc: subprocess.Popen[bytes] | None = None
        self._marker: Path | None = None
        self._stderr: Any = None

    def __enter__(self) -> Self:
        self.start()
        return self

    def __exit__(self, *exc: object) -> None:
        self.stop()

    @staticmethod
    def choose_port() -> int:
        """Pick a port P whose P+1 is also free, and neither of them reserved.

        goose opens a SECOND listener at P+1 (measured). Reserving both means we
        never steal a neighbour's port on the way up. The close-then-spawn window
        is a real TOCTOU; the answer is not a lock, it is the readiness probe
        plus a retry on a fresh port.
        """
        for _ in range(_PORT_TRIES):
            port = _ephemeral_port()
            if port in RESERVED_PORTS or port + 1 in RESERVED_PORTS:
                continue
            try:
                with socket.socket() as neighbour:
                    neighbour.bind(("127.0.0.1", port + 1))
            except OSError:
                continue
            return port
        raise ServerError(Reason.NO_PORT, f"{_PORT_TRIES} tries")

    def _guard_foreign(self) -> None:
        if os.environ.get("PAI_GOOSE_ALLOW_CONCURRENT"):
            return
        found = foreign_goose_pids(_ps_lines())
        if found:
            raise ServerError(Reason.FOREIGN_GOOSE, ",".join(str(p) for p in found))

    def _spawn(self, port: int, secret: str) -> subprocess.Popen[bytes]:
        child = dict(os.environ)
        child.update(self.env)
        child["GOOSE_SERVER__SECRET_KEY"] = secret
        # SIM115: the handle outlives this frame on purpose -- stop() closes it.
        self._stderr = tempfile.TemporaryFile()  # noqa: SIM115
        # Assigned through a local and returned, so the caller can record the
        # marker before anything else can observe a half-built object.
        return subprocess.Popen(  # noqa: S603 -- fixed argv, no shell
            [self.binary, "serve", "--host", "127.0.0.1", "--port", str(port)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=self._stderr,
            env=child,
            start_new_session=True,
        )

    def _wait_ready(self, port: int, proc: subprocess.Popen[bytes]) -> bool:
        deadline = time.monotonic() + _float_env("PAI_GOOSE_READY_S", 20.0)
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                return False
            if _port_is_open(port):
                return True
            time.sleep(_POLL_S)
        return False

    def _stderr_tail(self) -> str:
        """Read the child's last 20 stderr lines, for a ServerError that can be acted on.

        REDACTED on the way out. This string ends up in an exception a caller
        PRINTS, and the child was handed a freshly minted GOOSE_SERVER__SECRET_KEY
        -- a panic that dumps the environment would otherwise put a live key on
        someone's terminal.
        """
        if self._stderr is None:
            return ""
        with contextlib.suppress(OSError, ValueError):
            self._stderr.seek(0)
            text = self._stderr.read().decode("utf-8", "replace")
            return _redact(" | ".join(text.splitlines()[-20:]), self.secret)
        return ""

    def start(self) -> None:
        """Spawn, prove ready, or raise. Idempotent while a server is running."""
        if self.proc is not None:
            return
        self._guard_foreign()
        _reap_markers(self.binary)
        detail = ""
        for _ in range(_SPAWN_TRIES):
            port = self.choose_port()
            secret = secrets.token_hex(32)
            try:
                proc = self._spawn(port, secret)
            except OSError as exc:
                raise ServerError(
                    Reason.NO_BINARY, f"{self.binary} ({type(exc).__name__}); seam: PAI_GOOSE_BIN",
                ) from exc
            self.proc = proc
            self.port = port
            self.secret = secret
            self._marker = _write_marker(proc.pid, port, self.binary)
            _LIVE.append(self)
            _install_signals()
            if self._wait_ready(port, proc):
                self.url = f"http://127.0.0.1:{port}/acp"
                return
            detail = self._stderr_tail()
            self.stop()
        raise ServerError(Reason.NOT_READY, detail)

    def stop(self) -> None:
        """Kill the group, forget the marker, and PROVE the port is closed."""
        proc, self.proc = self.proc, None
        if proc is not None:
            _killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=_float_env("PAI_GOOSE_STOP_S", 5.0))
            except subprocess.TimeoutExpired:
                _killpg(proc.pid, signal.SIGKILL)
                with contextlib.suppress(subprocess.TimeoutExpired):
                    proc.wait(timeout=_float_env("PAI_GOOSE_STOP_S", 5.0))
        if self._marker is not None:
            self._marker.unlink(missing_ok=True)
            self._marker = None
        if self in _LIVE:
            _LIVE.remove(self)
        _restore_signals()
        if self._stderr is not None:
            with contextlib.suppress(OSError):
                self._stderr.close()
            self._stderr = None
        port, self.port, self.url = self.port, 0, ""
        # Killing the pid kills both listeners; this attests P only, which is
        # honest and is the one a later start() could collide with.
        if port and _port_is_open(port):
            raise ServerError(Reason.LEFT_RUNNING, str(port))


@contextmanager
def connect(
    url: str | None = None,
    *,
    binary: str | None = None,
    env: Mapping[str, str] | None = None,
    timeout_s: float = 30.0,
) -> Iterator[AcpClient]:
    """Yield an ACP session, spawning a server only when nothing else owns the config.

    GOOSE_ACP_URL wins and suppresses the spawn entirely. That is not a
    convenience: on the brain `goose-serve.service` holds a permanent server on
    the same config dir, and a second writer there is a lost update.
    """
    target = url or os.environ.get("GOOSE_ACP_URL", "")
    if target:
        with AcpClient(target, os.environ.get("GOOSE_SERVER__SECRET_KEY", ""), timeout_s) as client:
            yield client
        return
    with (
        EphemeralGoose(binary=binary, env=env) as server,
        AcpClient(server.url, server.secret, timeout_s) as client,
    ):
        yield client
