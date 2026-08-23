#!/usr/bin/env python3
"""code-agent-manager — per-chat container lifecycle + gateway for code agents.

One code chat = one container (image `code-agent:local`, an `opencode serve`
instance) + one persistent volume dir under /data/code-agents/chats/<id>/
holding the repo workspace AND the chat's own opencode home (config, auth,
its SQLite transcript DB, caches). Idle chats are stopped (volume kept);
any request to a stopped chat wakes it. Concept + operations:
docs/code-agents.md. Acceptance criteria: repo issue #17 (B/C groups).

The manager is deliberately the ONLY cross-chat state: a small metadata
index (id, repo, title, port, timestamps) at /data/code-agents/index.json.
Chat content lives only in each chat's volume. After create-time setup the
manager performs NO git operations — commits, pushes, and PRs are the
agent's job inside its container, gated by opencode permission asks.

HTTP surface (all authed with HTTP Basic, password = OPENCODE_SERVER_PASSWORD,
username free-form; `?auth_token=<base64(user:pass)>` accepted for
EventSource/browser contexts; TLS via the brain's tailnet cert when present):

    GET    /api/health                  liveness + engine/image/chat counts
    GET    /api/repos                   the allowlist (names + flags)
    GET    /api/chats                   index merged with live container state
    POST   /api/chats                   {"repo","task"?,"title"?,"model"?}
    POST   /api/chats/<id>/wake         start a stopped chat's container
    POST   /api/chats/<id>/stop         stop a running chat's container
    DELETE /api/chats/<id>[?purge=1]    remove container (purge: volume too)
    *      /chat/<id>/<path>            reverse proxy to the chat's opencode
                                        server (wakes it first if stopped;
                                        SSE-safe streaming)

Environment (from /data/secrets.env via the systemd unit):
    OPENCODE_SERVER_PASSWORD  required — auth for this gateway AND the
                              per-chat opencode servers behind it
    GITHUB_CODE_AGENT_PAT     required — fine-grained PAT, allowlisted repos
                              only; passed into chat containers as GH_TOKEN
    OPENCODE_ZEN_API_KEY      seeds each chat's opencode auth.json (Zen models)
    TOGETHER_API_KEY          passed through for the together provider
Tunables (optional):
    CODE_AGENT_ROOT           default /data/code-agents
    CODE_AGENT_PORT           gateway port, default 4300
    CODE_AGENT_IDLE_SECONDS   spin-down after inactivity, default 900
    CODE_AGENT_MAX_ACTIVE     max concurrently RUNNING chats, default 2
    CODE_AGENT_MEM            per-container memory cap, default 1200m
    CODE_AGENT_CPUS           per-container cpu cap, default 1.5
    CODE_AGENT_ENGINE         container engine, default podman
    CODE_AGENT_IMAGE          default code-agent:local
    CODE_AGENT_TLS_CERT/KEY   default /data/tls/{cert,key}.pem (falls back
                              to plain HTTP with a loud warning)
    CODE_AGENT_BIND           testing/dev ONLY: bind this address instead of
                              the tailnet IP (never set on the brain)
    CODE_AGENT_REAPER_INTERVAL  idle-reaper cadence seconds, default 60

Conventions: dataclasses + full annotations, `mypy --strict` clean and
`ruff check` clean with the entire rule set enabled (mypy.ini, ruff.toml; CI
runs both). Wire boundaries (JSON in/out, subprocess) are the only places
`Any` appears, immediately validated into the dataclasses below.
"""

from __future__ import annotations

import base64
import contextlib
import http.client
import json
import os
import re
import secrets as pysecrets
import shutil
import ssl
import subprocess
import sys
import threading
import time
from dataclasses import asdict, dataclass, field
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

# ------------------------------------------------------------- configuration

ROOT = Path(os.environ.get("CODE_AGENT_ROOT", "/data/code-agents"))
CHATS_DIR = ROOT / "chats"
INDEX_PATH = ROOT / "index.json"
REPOS_PATH = ROOT / "repos.json"

GATEWAY_PORT = int(os.environ.get("CODE_AGENT_PORT", "4300"))
IDLE_SECONDS = int(os.environ.get("CODE_AGENT_IDLE_SECONDS", "900"))
MAX_ACTIVE = int(os.environ.get("CODE_AGENT_MAX_ACTIVE", "2"))
MEM_LIMIT = os.environ.get("CODE_AGENT_MEM", "1200m")
CPU_LIMIT = os.environ.get("CODE_AGENT_CPUS", "1.5")
ENGINE = os.environ.get("CODE_AGENT_ENGINE", "podman")
IMAGE = os.environ.get("CODE_AGENT_IMAGE", "code-agent:local")
TLS_CERT = Path(os.environ.get("CODE_AGENT_TLS_CERT", "/data/tls/cert.pem"))
TLS_KEY = Path(os.environ.get("CODE_AGENT_TLS_KEY", "/data/tls/key.pem"))
BIND_OVERRIDE = os.environ.get("CODE_AGENT_BIND", "")
REAPER_INTERVAL = int(os.environ.get("CODE_AGENT_REAPER_INTERVAL", "60"))

PASSWORD = os.environ.get("OPENCODE_SERVER_PASSWORD", "")
GH_PAT = os.environ.get("GITHUB_CODE_AGENT_PAT", "")
ZEN_KEY = os.environ.get("OPENCODE_ZEN_API_KEY", "")
TOGETHER_KEY = os.environ.get("TOGETHER_API_KEY", "")

CONFIG_TEMPLATE = (
    Path(__file__).resolve().parents[2] / "config" / "code-agents" / "opencode.json"
)

BASE_CHAT_PORT = 4310  # per-chat opencode ports: 4310, 4311, ... on 127.0.0.1
WAIT_FOR_CHAT_SECONDS = 90  # opencode boot budget, create and wake alike

# Zen's free models train on user data (docs/privacy.md, hard rule 1). Refused
# unless the repo's allowlist entry sets public_throwaway. The explicit set
# tracks docs/model-routing.md; the "free" substring is a forward-compat net.
FREE_MODEL_IDS = frozenset({"big-pickle", "muse-spark-contributor"})


def log(msg: str) -> None:
    # stdout IS the log sink here: systemd routes it to journald.
    print(f"code-agent-manager: {msg}", flush=True)  # noqa: T201


# ----------------------------------------------------------------- the model


def _str(raw: dict[str, Any], key: str, default: str = "") -> str:
    value = raw.get(key, default)
    return value if isinstance(value, str) else default


def _bool(raw: dict[str, Any], key: str) -> bool:
    return bool(raw.get(key, False))


def _float(raw: dict[str, Any], key: str) -> float:
    value = raw.get(key, 0.0)
    return float(value) if isinstance(value, (int, float)) else 0.0


@dataclass
class Chat:
    """One code chat's metadata — the index entry.

    Content lives in the chat's volume; this is everything the manager (and
    the app's list view) needs without waking anything.
    """

    id: str
    repo: str
    title: str
    port: int
    branch: str
    model: str | None = None
    probe: bool = False
    created: float = 0.0
    last_active: float = 0.0

    def to_wire(self) -> dict[str, object]:
        return asdict(self)

    @classmethod
    def from_wire(cls, raw: dict[str, Any]) -> Chat:
        model = raw.get("model")
        return cls(
            id=_str(raw, "id"),
            repo=_str(raw, "repo"),
            title=_str(raw, "title"),
            port=int(raw.get("port", 0)),
            branch=_str(raw, "branch"),
            model=model if isinstance(model, str) else None,
            probe=_bool(raw, "probe"),
            created=_float(raw, "created"),
            last_active=_float(raw, "last_active"),
        )


@dataclass
class Index:
    """The manager's only cross-chat state, persisted atomically."""

    chats: dict[str, Chat] = field(default_factory=dict)

    @classmethod
    def load(cls) -> Index:
        try:
            with INDEX_PATH.open(encoding="utf-8") as f:
                raw: Any = json.load(f)
        except FileNotFoundError:
            return cls()
        chats_raw = raw.get("chats", {}) if isinstance(raw, dict) else {}
        chats: dict[str, Chat] = {}
        if isinstance(chats_raw, dict):
            for cid, entry in chats_raw.items():
                if isinstance(cid, str) and isinstance(entry, dict):
                    chats[cid] = Chat.from_wire(entry)
        return cls(chats=chats)

    def save(self) -> None:
        tmp = INDEX_PATH.with_name(INDEX_PATH.name + ".tmp")
        payload = {"chats": {cid: chat.to_wire() for cid, chat in self.chats.items()}}
        with tmp.open("w", encoding="utf-8") as f:
            json.dump(payload, f, indent=1)
        tmp.replace(INDEX_PATH)


@dataclass(frozen=True)
class RepoEntry:
    """One allowlist entry — the trust boundary (docs/code-agents.md)."""

    name: str
    url: str
    setup: str = ""
    edit_only: bool = False
    allow_push: bool = False
    public_throwaway: bool = False

    @classmethod
    def from_wire(cls, raw: dict[str, Any]) -> RepoEntry:
        return cls(
            name=_str(raw, "name"),
            url=_str(raw, "url"),
            setup=_str(raw, "setup"),
            edit_only=_bool(raw, "edit_only"),
            allow_push=_bool(raw, "allow_push"),
            public_throwaway=_bool(raw, "public_throwaway"),
        )

    def to_wire(self) -> dict[str, object]:
        return asdict(self)


PROBE_REPO = RepoEntry(name="_probe", url="")


@dataclass(frozen=True)
class CreateChatRequest:
    repo: str
    task: str
    title: str
    model: str | None

    @classmethod
    def from_wire(cls, raw: dict[str, Any]) -> CreateChatRequest:
        model = raw.get("model")
        return cls(
            repo=_str(raw, "repo"),
            task=_str(raw, "task"),
            title=_str(raw, "title"),
            model=model if isinstance(model, str) and model else None,
        )


@dataclass(frozen=True)
class ApiError:
    status: int
    message: str


class ConfigTemplateError(TypeError):
    """The opencode config template on disk is not a JSON object."""

    def __init__(self, path: Path) -> None:
        super().__init__(f"config template is not a JSON object: {path}")


class ChatLaunchError(RuntimeError):
    """A chat's container started but its opencode server never answered."""

    def __init__(self, seconds: int) -> None:
        super().__init__(f"opencode server did not come up in {seconds}s")


_lock = threading.Lock()


def load_repos() -> dict[str, RepoEntry]:
    try:
        with REPOS_PATH.open(encoding="utf-8") as f:
            raw: Any = json.load(f)
    except FileNotFoundError:
        return {}
    repos: dict[str, RepoEntry] = {}
    entries = raw.get("repos", []) if isinstance(raw, dict) else []
    if isinstance(entries, list):
        for entry in entries:
            if isinstance(entry, dict) and isinstance(entry.get("name"), str):
                repo = RepoEntry.from_wire(entry)
                repos[repo.name] = repo
    return repos


# ------------------------------------------------------------------ engine


def engine(
    *args: str,
    check: bool = True,
    capture: bool = True,
    timeout: int = 120,
) -> subprocess.CompletedProcess[str]:
    cmd = [ENGINE, *args]
    # Fixed argv, never a shell string; the engine binary is resolved from
    # PATH on purpose so CODE_AGENT_ENGINE can swap podman for docker.
    return subprocess.run(  # noqa: S603
        cmd,
        check=check,
        timeout=timeout,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
        text=True,
    )


def container_name(chat_id: str) -> str:
    return f"code-agent-{chat_id}"


def container_state(chat_id: str) -> str:
    """Report the container's state: running, stopped (exists) or absent."""
    try:
        result = engine(
            "container",
            "inspect",
            "--format",
            "{{.State.Status}}",
            container_name(chat_id),
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return "absent"
    if result.returncode != 0:
        return "absent"
    return "running" if result.stdout.strip() == "running" else "stopped"


def running_count(index: Index) -> int:
    return sum(1 for cid in index.chats if container_state(cid) == "running")


def run_container(chat: Chat) -> None:
    """Create + start the chat's container (state lives in the volume)."""
    chat_dir = CHATS_DIR / chat.id
    args: list[str] = [
        "run",
        "-d",
        "--name",
        container_name(chat.id),
        "--label",
        "code-agent=1",
        "--memory",
        MEM_LIMIT,
        "--cpus",
        CPU_LIMIT,
        "-p",
        f"127.0.0.1:{chat.port}:4096",
        "-v",
        f"{chat_dir}:/chat",
        "-e",
        f"OPENCODE_SERVER_PASSWORD={PASSWORD}",
        "-e",
        "OPENCODE_DISABLE_AUTOUPDATE=1",
    ]
    if TOGETHER_KEY:
        args += ["-e", f"TOGETHER_API_KEY={TOGETHER_KEY}"]
    if GH_PAT and not chat.probe:
        args += ["-e", f"GH_TOKEN={GH_PAT}"]
    # 0.0.0.0 is inside the container's own netns; the host side is published
    # to 127.0.0.1 only (-p above) and the gateway is the only way in.
    args += [IMAGE, "serve", "--hostname", "0.0.0.0", "--port", "4096"]  # noqa: S104
    engine(*args)


def oneshot(
    chat_dir: Path,
    script: str,
    env_extra: tuple[str, ...] = (),
    timeout: int = 600,
) -> subprocess.CompletedProcess[str]:
    """Run a shell one-shot inside a throwaway container on the chat volume.

    Used for clone/branch/setup so git + gh + the token never need to exist on
    the host side of this service.
    """
    args: list[str] = ["run", "--rm", "--entrypoint", "/bin/sh", "-v", f"{chat_dir}:/chat"]
    for kv in env_extra:
        args += ["-e", kv]
    args += [IMAGE, "-c", script]
    return engine(*args, timeout=timeout)


def wait_for_chat(port: int, timeout_s: int = WAIT_FOR_CHAT_SECONDS) -> bool:
    """Poll the chat's opencode server until it answers (auth'd or 401)."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
            conn.request("GET", "/session", headers={"Authorization": basic_auth_header()})
            resp = conn.getresponse()
            resp.read()
            conn.close()
            if resp.status in (HTTPStatus.OK, HTTPStatus.UNAUTHORIZED):
                return True
        except OSError:
            pass
        time.sleep(1.5)
    return False


def basic_auth_header() -> str:
    tok = base64.b64encode(f"opencode:{PASSWORD}".encode()).decode()
    return f"Basic {tok}"


# ------------------------------------------------------------ chat lifecycle


def next_port(index: Index) -> int:
    used = {chat.port for chat in index.chats.values()}
    port = BASE_CHAT_PORT
    while port in used:
        port += 1
    return port


def is_free_model(model: str | None) -> bool:
    if not model:
        return False
    bare = model.split("/", 1)[-1].lower()
    return bare in FREE_MODEL_IDS or "free" in bare


def render_chat_config(chat_dir: Path, model: str | None, *, allow_push: bool) -> None:
    """Render the per-chat opencode config from the repo template."""
    with CONFIG_TEMPLATE.open(encoding="utf-8") as f:
        cfg: Any = json.load(f)
    if not isinstance(cfg, dict):
        raise ConfigTemplateError(CONFIG_TEMPLATE)
    cfg.pop("_readme", None)
    if model:
        cfg["model"] = model
    if allow_push:
        cfg.setdefault("permission", {}).setdefault("bash", {})["git push*"] = "allow"
    dst_dir = chat_dir / "home" / ".config" / "opencode"
    dst_dir.mkdir(parents=True, exist_ok=True)
    with (dst_dir / "opencode.json").open("w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)


def seed_auth(chat_dir: Path) -> None:
    """Seed opencode's auth.json so Zen models work headlessly.

    NOTE: shape mirrors what `opencode auth login` writes as of the pinned
    version — check-code-agents.sh --probe verifies models actually resolve;
    if upstream changes the schema, fix it here.
    """
    if not ZEN_KEY:
        return
    d = chat_dir / "home" / ".local" / "share" / "opencode"
    d.mkdir(parents=True, exist_ok=True)
    path = d / "auth.json"
    with path.open("w", encoding="utf-8") as f:
        json.dump({"opencode": {"type": "api", "key": ZEN_KEY}}, f)
    path.chmod(0o600)


def shquote(s: str) -> str:
    return "'" + s.replace("'", "'\\''") + "'"


def create_chat(request: CreateChatRequest) -> Chat | ApiError:
    repos = load_repos()
    probe = request.repo == "_probe"
    if not probe and request.repo not in repos:
        listed = ", ".join(sorted(repos)) or "(allowlist empty)"
        return ApiError(
            403,
            f"repo '{request.repo}' is not in the allowlist "
            f"(/data/code-agents/repos.json). Allowed: {listed}",
        )
    repo = repos.get(request.repo, PROBE_REPO)

    if is_free_model(request.model) and not repo.public_throwaway:
        return ApiError(
            403,
            f"model '{request.model}' is a zen-free model — free models train on "
            "your data (docs/privacy.md hard rule 1) and are refused unless the "
            "repo is flagged public_throwaway.",
        )

    with _lock:
        index = Index.load()
        if running_count(index) >= MAX_ACTIVE:
            return ApiError(
                409,
                f"{MAX_ACTIVE} chats already active (CODE_AGENT_MAX_ACTIVE) "
                "— stop one or wait for idle spin-down.",
            )
        suffix = pysecrets.token_hex(3)
        chat_id = re.sub(r"[^a-zA-Z0-9-]", "-", f"{request.repo}-{suffix}").strip("-")
        now = time.time()
        chat = Chat(
            id=chat_id,
            repo=request.repo,
            title=request.title or (request.task or chat_id)[:80],
            port=next_port(index),
            branch=f"agent/{chat_id}",
            model=request.model,
            probe=probe,
            created=now,
            last_active=now,
        )
        index.chats[chat_id] = chat
        index.save()

    chat_dir = CHATS_DIR / chat_id
    (chat_dir / "workspace").mkdir(parents=True, exist_ok=True)
    (chat_dir / "home").mkdir(parents=True, exist_ok=True)
    render_chat_config(chat_dir, request.model, allow_push=repo.allow_push)
    seed_auth(chat_dir)

    try:
        if probe:
            # Self-contained scratch repo: lets the verify script exercise the
            # whole lifecycle with no network and no credential.
            oneshot(
                chat_dir,
                "cd /chat/workspace && git init -q -b main && "
                "git -c user.email=probe@localhost -c user.name=probe "
                "commit -q --allow-empty -m init && "
                f"git checkout -q -b {chat.branch}",
            )
        else:
            # Clone + branch in-container: gh's credential helper turns
            # GH_TOKEN into the HTTPS credential; nothing token-shaped is
            # ever written to the volume. Commits get a distinct identity —
            # never the owner's personal one (issue #17 C4).
            script = (
                f"cd /chat/workspace && "
                f"git clone {shquote(repo.url)} . && "
                f"git checkout -b {chat.branch} && "
                f"git config user.name 'code-agent' && "
                f"git config user.email 'code-agent@brain.invalid'"
            )
            oneshot(chat_dir, script, env_extra=(f"GH_TOKEN={GH_PAT}",))
            setup = repo.setup.strip()
            if setup:
                oneshot(chat_dir, f"cd /chat/workspace && {setup}", timeout=1800)
        run_container(chat)
        if not wait_for_chat(chat.port):
            # Deliberate: a launch that never answers takes exactly the same
            # cleanup path as the exceptions below.
            raise ChatLaunchError(WAIT_FOR_CHAT_SECONDS)
    except (OSError, subprocess.SubprocessError, RuntimeError, ValueError) as e:
        log(f"create {chat_id} failed: {e}")
        notify_failure(f"chat create failed ({chat_id}): launch/setup error")
        with _lock:
            index = Index.load()
            index.chats.pop(chat_id, None)
            index.save()
        engine("rm", "-f", container_name(chat_id), check=False)
        shutil.rmtree(chat_dir, ignore_errors=True)
        return ApiError(502, f"chat create failed: {e}")

    return chat


def wake_chat(chat_id: str) -> tuple[int, str]:
    with _lock:
        index = Index.load()
        chat = index.chats.get(chat_id)
        if chat is None:
            return 404, "unknown chat"
        state = container_state(chat_id)
        if state == "running":
            touch(chat_id)
            return 200, "already running"
        if running_count(index) >= MAX_ACTIVE:
            return 409, (
                f"{MAX_ACTIVE} chats already active — stop one or wait for idle spin-down."
            )
    # Mark activity BEFORE starting: a stale last_active would let the idle
    # reaper stop the container in the middle of this very wake.
    touch(chat_id)
    try:
        if state == "stopped":
            engine("start", container_name(chat_id))
        else:  # absent (e.g. removed after an image upgrade) — volume has it all
            run_container(chat)
        if not wait_for_chat(chat.port):
            return 502, "chat container started but opencode did not answer"
    except (OSError, subprocess.SubprocessError) as e:
        notify_failure(f"chat wake failed ({chat_id})")
        return 502, f"wake failed: {e}"
    touch(chat_id)
    return 200, "woken"


def touch(chat_id: str) -> None:
    with _lock:
        index = Index.load()
        chat = index.chats.get(chat_id)
        if chat is not None:
            chat.last_active = time.time()
            index.save()


def chat_busy(chat: Chat) -> bool:
    """Report whether any session on this chat's server is mid-work.

    A busy chat is never stopped by the idle reaper, whatever the clock says.
    Anything that makes the answer unknowable counts as busy — the cost of a
    wrong "idle" is killing a running turn.
    """
    try:
        conn = http.client.HTTPConnection("127.0.0.1", chat.port, timeout=5)
        conn.request(
            "GET", "/session/status", headers={"Authorization": basic_auth_header()},
        )
        resp = conn.getresponse()
        body = resp.read().decode("utf-8", "replace")
        conn.close()
        if resp.status != HTTPStatus.OK:
            return True
        data: Any = json.loads(body or "{}")
        blob = json.dumps(data).lower()
    except (OSError, ValueError):
        return True
    return '"busy"' in blob or '"retry"' in blob


def reaper_loop() -> None:
    while True:
        time.sleep(REAPER_INTERVAL)
        try:
            index = Index.load()
            now = time.time()
            for cid, chat in list(index.chats.items()):
                if container_state(cid) != "running":
                    continue
                if now - chat.last_active < IDLE_SECONDS:
                    continue
                if chat_busy(chat):
                    touch(cid)  # working counts as activity
                    continue
                log(f"idle spin-down: {cid}")
                engine("stop", container_name(cid), check=False, timeout=90)
        except (OSError, subprocess.SubprocessError, ValueError) as e:
            log(f"reaper error: {e}")


def notify_failure(reason: str) -> None:
    """Send failure alerts on the standard channel (notify.sh -> ntfy).

    Component + failure class only — never model output (docs/automations.md).
    """
    notify = Path(__file__).resolve().parents[1] / "common" / "notify.sh"
    with contextlib.suppress(OSError, subprocess.SubprocessError):
        subprocess.run(  # noqa: S603
            [str(notify), "-t", "Code agent failure", "-p", "high", reason],
            check=False,
            timeout=30,
        )


# ------------------------------------------------------------------ HTTP

HOP_HEADERS = frozenset(
    {
        "connection",
        "keep-alive",
        "transfer-encoding",
        "upgrade",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailers",
        "host",
        "authorization",
    },
)

_last_touch: dict[str, float] = {}


def touch_maybe(chat_id: str, min_interval: float = 30.0) -> None:
    """Rate-limited activity marker for long streams."""
    now = time.time()
    if now - _last_touch.get(chat_id, 0.0) > min_interval:
        _last_touch[chat_id] = now
        touch(chat_id)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "code-agent-manager"

    # ---- auth ----
    def authed(self) -> bool:
        hdr = self.headers.get("Authorization", "") or ""
        cred = ""
        if hdr.startswith("Basic "):
            cred = hdr[6:]
        else:
            q = parse_qs(urlparse(self.path).query)
            cred = (q.get("auth_token") or [""])[0]
        try:
            _, _, pw = base64.b64decode(cred).decode().partition(":")
        except (ValueError, UnicodeDecodeError):
            pw = ""
        return bool(PASSWORD) and pysecrets.compare_digest(pw, PASSWORD)

    def deny(self) -> None:
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="code-agents"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def send_json(self, code: int, obj: object) -> None:
        body = json.dumps(obj, indent=1).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_body(self) -> bytes:
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    # ---- routing ----
    ROUTE_CHAT = re.compile(r"^/chat/([a-zA-Z0-9-]+)(/.*|$)")
    ROUTE_LIFECYCLE = re.compile(r"^/api/chats/([a-zA-Z0-9-]+)/(wake|stop)$")
    ROUTE_ONE_CHAT = re.compile(r"^/api/chats/([a-zA-Z0-9-]+)$")

    def handle_any(self) -> None:
        """Authenticate, then dispatch the request to exactly one route."""
        if not self.authed():
            self.deny()
            return
        path = urlparse(self.path).path
        verb = self.command
        chat = self.ROUTE_CHAT.match(path)
        lifecycle = self.ROUTE_LIFECYCLE.match(path)
        one_chat = self.ROUTE_ONE_CHAT.match(path)
        if chat:
            self.proxy(chat.group(1), chat.group(2) or "/")
        elif (path, verb) == ("/api/health", "GET"):
            self.route_health()
        elif (path, verb) == ("/api/repos", "GET"):
            self.route_repos()
        elif (path, verb) == ("/api/chats", "GET"):
            self.route_list_chats()
        elif (path, verb) == ("/api/chats", "POST"):
            self.route_create_chat()
        elif lifecycle and verb == "POST":
            self.route_wake_or_stop(lifecycle.group(1), lifecycle.group(2))
        elif one_chat and verb == "DELETE":
            self.route_delete_chat(one_chat.group(1))
        else:
            self.send_json(404, {"error": f"no route: {verb} {path}"})

    def route_health(self) -> None:
        index = Index.load()
        self.send_json(
            200,
            {
                "ok": True,
                "engine": ENGINE,
                "image": IMAGE,
                "chats": len(index.chats),
                "active": running_count(index),
                "max_active": MAX_ACTIVE,
                "idle_seconds": IDLE_SECONDS,
            },
        )

    def route_repos(self) -> None:
        self.send_json(200, {"repos": [repo.to_wire() for repo in load_repos().values()]})

    def route_list_chats(self) -> None:
        index = Index.load()
        out: list[dict[str, object]] = []
        for cid, chat in sorted(index.chats.items(), key=lambda kv: -kv[1].last_active):
            entry = chat.to_wire()
            entry["status"] = container_state(cid)
            entry["url"] = f"/chat/{cid}"
            out.append(entry)
        self.send_json(200, {"chats": out})

    def route_create_chat(self) -> None:
        try:
            raw: Any = json.loads(self.read_body() or b"{}")
        except json.JSONDecodeError:
            self.send_json(400, {"error": "invalid JSON body"})
            return
        if not isinstance(raw, dict):
            self.send_json(400, {"error": "body must be a JSON object"})
            return
        result = create_chat(CreateChatRequest.from_wire(raw))
        if isinstance(result, ApiError):
            self.send_json(result.status, {"error": result.message})
            return
        entry = result.to_wire()
        entry["status"] = "running"
        entry["url"] = f"/chat/{result.id}"
        self.send_json(201, entry)

    def route_wake_or_stop(self, chat_id: str, action: str) -> None:
        if action == "wake":
            code, msg = wake_chat(chat_id)
            self.send_json(code, {"status": msg})
            return
        engine("stop", container_name(chat_id), check=False, timeout=90)
        self.send_json(200, {"status": "stopped"})

    def route_delete_chat(self, chat_id: str) -> None:
        purge = "purge=1" in (urlparse(self.path).query or "")
        with _lock:
            index = Index.load()
            if chat_id not in index.chats:
                self.send_json(404, {"error": "unknown chat"})
                return
            index.chats.pop(chat_id)
            index.save()
        engine("rm", "-f", container_name(chat_id), check=False)
        if purge:
            shutil.rmtree(CHATS_DIR / chat_id, ignore_errors=True)
        self.send_json(200, {"status": "deleted", "volume": "purged" if purge else "kept"})

    # ---- reverse proxy (wake-on-request, SSE-safe) ----
    def proxy(self, chat_id: str, subpath: str) -> None:
        index = Index.load()
        chat = index.chats.get(chat_id)
        if chat is None:
            self.send_json(404, {"error": "unknown chat"})
            return
        if container_state(chat_id) != "running":
            code, msg = wake_chat(chat_id)
            if code != HTTPStatus.OK:
                self.send_json(code, {"error": f"wake failed: {msg}"})
                return
        touch(chat_id)

        q = urlparse(self.path).query
        target = subpath + (f"?{q}" if q else "")
        body = self.read_body()
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_HEADERS}
        headers["Authorization"] = basic_auth_header()
        headers["Host"] = f"127.0.0.1:{chat.port}"
        try:
            conn = http.client.HTTPConnection("127.0.0.1", chat.port, timeout=20)
            conn.request(self.command, target, body=body or None, headers=headers)
            # Headers can be slow on blocking endpoints (a synchronous prompt
            # runs the whole agent turn before answering); the 20s above only
            # guards the connect.
            if conn.sock is not None:
                conn.sock.settimeout(600)
            resp = conn.getresponse()
        except OSError as e:
            self.send_json(502, {"error": f"chat unreachable: {e}"})
            return

        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() in HOP_HEADERS or k.lower() == "content-length":
                continue
            self.send_header(k, v)
        # Close-delimited streaming: correct for both fixed bodies and SSE,
        # at the cost of one TCP connection per request (fine on a tailnet).
        self.send_header("Connection", "close")
        self.close_connection = True
        self.end_headers()
        self.relay_body(conn, resp, chat_id)

    def relay_body(
        self,
        conn: http.client.HTTPConnection,
        resp: http.client.HTTPResponse,
        chat_id: str,
    ) -> None:
        """Stream an upstream body downstream as it arrives (SSE-safe)."""
        # SSE heartbeats arrive every ~10s; 60s of silence means a dead
        # stream. On a `Connection: close` upstream response http.client
        # detaches conn.sock (None) — the response still reads from the
        # underlying socket, which keeps the 600s timeout set by the caller;
        # tighten only when the handle is still exposed.
        if conn.sock is not None:
            conn.sock.settimeout(60)
        try:
            while True:
                # read1: return whatever is available NOW. A plain read(8192)
                # waits for the full 8KB and silently turns SSE into a
                # buffered batch (caught by test-code-agent-manager.sh's
                # live-arrival check).
                chunk = resp.read1(8192)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
                touch_maybe(chat_id)
        except (OSError, ssl.SSLError):
            pass
        finally:
            conn.close()

    def do_GET(self) -> None:
        self.handle_any()

    def do_POST(self) -> None:
        self.handle_any()

    def do_PUT(self) -> None:
        self.handle_any()

    def do_PATCH(self) -> None:
        self.handle_any()

    def do_DELETE(self) -> None:
        self.handle_any()

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002, ARG002
        # journald gets one concise line; never log query strings (auth_token).
        log(f"{self.command} {urlparse(self.path).path}")


# ------------------------------------------------------------------- main


def tailnet_ip() -> str:
    try:
        # The tailscale CLI is resolved from PATH by design (it is the
        # system's, not ours), with a fixed argv and no shell.
        out = subprocess.run(
            ["tailscale", "ip", "-4"],  # noqa: S607
            check=True,
            stdout=subprocess.PIPE,
            text=True,
            timeout=10,
        )
        lines = out.stdout.strip().splitlines()
        return lines[0] if lines else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def main() -> None:
    if not PASSWORD:
        log(
            "FATAL: OPENCODE_SERVER_PASSWORD is empty — refusing to serve "
            "an unauthenticated code plane. Set it in /data/secrets.env.",
        )
        sys.exit(1)
    if not GH_PAT:
        log(
            "WARNING: GITHUB_CODE_AGENT_PAT is empty — private clones and "
            "agent-side push/PR will fail until it is set.",
        )
    CHATS_DIR.mkdir(parents=True, exist_ok=True)
    if not REPOS_PATH.exists():
        log(
            f"WARNING: {REPOS_PATH} missing — the allowlist is empty; copy "
            "config/code-agents/repos.example.json there and edit it.",
        )

    host = BIND_OVERRIDE or tailnet_ip()
    have_tls = TLS_CERT.exists() and TLS_KEY.exists()
    if not host:
        # Tailnet-only rule (docs/security.md): the socket must exist on the
        # tailnet interface or not at all. Exit nonzero; the unit's
        # Restart=always retries every 5s until tailscaled has an IPv4 —
        # the same wait-for-the-tailnet pattern goose-serve.service uses.
        log("no Tailscale IPv4 yet — exiting for systemd to retry")
        sys.exit(1)
    if not have_tls:
        log(
            "WARNING: no TLS cert at /data/tls — serving PLAIN HTTP. Run "
            "scripts/vps/renew-tls-cert.sh (docs/setup/50-vps-brain.md).",
        )

    server = ThreadingHTTPServer((host, GATEWAY_PORT), Handler)
    server.daemon_threads = True
    if have_tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(TLS_CERT, TLS_KEY)
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=reaper_loop, daemon=True).start()
    log(
        f"listening on {host}:{GATEWAY_PORT} "
        f"(tls={'yes' if have_tls else 'NO'}, engine={ENGINE}, image={IMAGE}, "
        f"idle={IDLE_SECONDS}s, max_active={MAX_ACTIVE})",
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
