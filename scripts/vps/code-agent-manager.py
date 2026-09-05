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
    GET    /api/repos/<name>/branches   a repo's branches, default marked
    GET    /api/chats                   index merged with live container state
    POST   /api/chats                   {"repo","task"?,"title"?,"model"?,"base"?}
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
    NTFY_AGENT_TOPIC          the phone's AGENT channel: buzz when a turn ends
                              or an ask is parked. Empty (the default) disables
                              notification entirely. DELIBERATELY NOT the same
                              topic as NTFY_TOPIC, which carries failure alerts
                              — an ntfy topic name is a password in BOTH
                              directions, so subscribing a phone to this one
                              makes it a write channel onto a lock screen, and
                              the two must be burnable independently.
    NTFY_SERVER               ntfy base URL, default https://ntfy.sh (shared
                              with scripts/common/notify.sh, so self-hosting
                              later is a variable change, not a code change)

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
from typing import Any, ClassVar
from urllib.parse import parse_qs, quote, unquote, urlparse

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
# Comfortably above the phone app's 8 MB attachment cap (~10.7 MB base64 plus
# the JSON envelope), and low enough that a declared Content-Length is not an
# instruction to allocate arbitrary memory.
MAX_BODY_BYTES = int(os.environ.get("CODE_AGENT_MAX_BODY_MB", "32")) * 1024 * 1024

PASSWORD = os.environ.get("OPENCODE_SERVER_PASSWORD", "")
GH_PAT = os.environ.get("GITHUB_CODE_AGENT_PAT", "")
# Overridable so the GitHub integration can be exercised at all: the verify
# harness points this at a fake GitHub on localhost. Nothing else about the
# calls changes, so what the tests exercise is the real request-building and
# the real error mapping.
GH_API = os.environ.get("GITHUB_API_BASE", "https://api.github.com")
ZEN_KEY = os.environ.get("OPENCODE_ZEN_API_KEY", "")
TOGETHER_KEY = os.environ.get("TOGETHER_API_KEY", "")

# The phone's agent channel (docs/push-notifications.md stage 0). Read by NAME
# and never logged: the topic IS the credential. Absent = the feature is off,
# checked at send time rather than at startup so an existing deploy that has
# never heard of it keeps working unchanged (deploy-vps.sh's required-vars gate
# is deliberately NOT extended).
NTFY_AGENT_TOPIC = os.environ.get("NTFY_AGENT_TOPIC", "")
NTFY_SERVER = os.environ.get("NTFY_SERVER", "https://ntfy.sh")
# The sender runs on the reaper thread, so a stalled ntfy delays idle
# spin-down. notify_failure() can afford 30s because it runs on a request
# thread and fires once per incident; this cannot.
NTFY_TIMEOUT = 5

CONFIG_TEMPLATE = Path(__file__).resolve().parents[2] / "config" / "code-agents" / "opencode.json"

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


def _obj(raw: dict[str, Any], key: str) -> dict[str, Any]:
    """Return a nested JSON object, or an empty one.

    Written out rather than inlined as
    `raw.get(k) if isinstance(raw.get(k), dict) else {}` because that calls
    `.get` TWICE and mypy cannot narrow the second call from a check on the
    first — it stays `Any | dict[Any, Any] | None`, which is the six
    `--strict` errors this replaces. Binding once narrows, and it is one
    fewer dict lookup besides.
    """
    value = raw.get(key)
    return value if isinstance(value, dict) else {}


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
    # The ref this chat's branch was cut from. "" means "whatever the clone's
    # default HEAD was" — what every chat made before the base picker existed
    # says, so it is a default rather than a migration.
    base: str = ""
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
            base=_str(raw, "base"),
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
        except (json.JSONDecodeError, OSError) as e:
            # Everything below tolerates wrong-SHAPED json; this arm is the
            # INVALID kind. Without it a truncated index.json raises out of
            # every request thread and the reaper, and the client sees an empty
            # reply -- which reads as a network fault, not a corrupt file.
            # Degrade to "no chats" so /api/health still answers and says so.
            log(f"index.json is unreadable ({type(e).__name__}) -- treating as empty")
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
    # The ref the chat's branch is cut from. Absent or empty means the clone's
    # default HEAD, which is what every create did before this existed.
    base: str

    @classmethod
    def from_wire(cls, raw: dict[str, Any]) -> CreateChatRequest:
        model = raw.get("model")
        return cls(
            repo=_str(raw, "repo"),
            task=_str(raw, "task"),
            title=_str(raw, "title"),
            model=model if isinstance(model, str) and model else None,
            base=_str(raw, "base").strip(),
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


@dataclass
class ReaperMemory:
    """What the reaper carries from one pass to the next.

    In memory ON PURPOSE, never in index.json. index.json is guarded by
    `_lock`, which is non-reentrant and has already wedged this process once
    (see wake_chat's post-mortem); hanging notification bookkeeping off the
    container-lifecycle lock would be the same class of mistake, and there is
    nothing here worth a disk write.

    Empty after a restart is the CORRECT starting point, not merely a
    tolerable one, and it is asymmetric in exactly the right direction. The
    unit's ExecStopPost stops every chat container on the way down, which
    destroys opencode's in-memory pending-ask map — so a manager that has just
    started is looking at a plane with no parked asks on it and has nothing to
    re-announce. `armed` is empty too, and an unarmed chat cannot fire, so no
    phantom "turn finished" is possible on the first pass back either. (The
    same fact scopes what stage 0 may promise: an ask survives the phone
    sleeping and survives idle spin-down, but it does not survive a deploy or
    a crash loop. deploy-vps.sh says so in its own comment.)

    Only `armed` is touched by more than one thread — HTTP handler threads arm
    it, the reaper drains it — so only it takes `armed_lock`. `armed_lock` is
    its OWN lock and must never be nested with `_lock` in either order.
    """

    #: chat id -> when the manager proxied an accepted prompt for it.
    armed: dict[str, float] = field(default_factory=dict)
    armed_lock: threading.Lock = field(default_factory=threading.Lock)
    #: chat id -> ask ids already announced. Reaper thread only.
    seen_asks: dict[str, set[str]] = field(default_factory=dict)
    #: chats that were running at the PREVIOUS pass. Reaper thread only.
    prev_running: frozenset[str] = frozenset()
    #: chats parked on a permission ask, as of the last completed pass.
    #: Written by the reaper thread, read by admission (admission_count) and
    #: by /api/health. It is REBOUND rather than mutated, so a reader always
    #: sees one whole pass's answer and needs no lock to do it.
    blocked: frozenset[str] = frozenset()
    #: opaque handle -> the chats it stands for. Nothing redeems these yet —
    #: stage 3 adds the exchange endpoint the tap needs (§7). Bounded, because
    #: a map that only grows is a leak dressed as a feature.
    handles: dict[str, list[str]] = field(default_factory=dict)

    def mint_handle(self, chats: list[str]) -> str:
        handle = pysecrets.token_urlsafe(12)
        self.handles[handle] = chats
        while len(self.handles) > HANDLE_MEMORY:
            self.handles.pop(next(iter(self.handles)))
        return handle


HANDLE_MEMORY = 64

_reaper_memory = ReaperMemory()


def load_repos() -> dict[str, RepoEntry]:
    try:
        with REPOS_PATH.open(encoding="utf-8") as f:
            raw: Any = json.load(f)
    except FileNotFoundError:
        return {}
    except (json.JSONDecodeError, OSError) as e:
        # repos.json is the one state file a human is told to edit by hand
        # (docs/code-agents.md), so a trailing comma here is the realistic
        # corruption -- and an uncaught JSONDecodeError takes down every route
        # that resolves a repo, not just this one. An empty allowlist refuses
        # new chats, which is the safe direction for a trust boundary.
        log(f"repos.json is unreadable ({type(e).__name__}) -- allowlist is empty")
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


# ---------------------------------------------------- pending permissions


def pending_permissions(
    running: list[Chat] | None = None,
) -> tuple[list[dict[str, object]], list[str]]:
    """Every ask parked on a RUNNING chat, and the chats that would not say.

    Deliberately not "every chat": reaching a chat through the proxy wakes it,
    so asking all of them would hold every container open and defeat the idle
    spin-down the whole design rests on. It costs nothing to skip the stopped
    ones — a container that is down has no live turn, so it has nothing parked.

    A container that is running but will not answer is NAMED rather than
    silently dropped. The app treats a chat in neither list as "definitely
    nothing pending" and clears its card, so swallowing a failure here would
    erase a real ask from somebody's screen.

    `running` lets a caller that has ALREADY established which containers are
    up hand that in — the reaper has, and re-deriving it here would mean a
    second `container_state()` subprocess per chat on every pass. Passing None
    keeps the route's behaviour exactly as it was.
    """
    if running is None:
        index = Index.load()
        running = [c for c in index.chats.values() if container_state(c.id) == "running"]
    found: list[dict[str, object]] = []
    unreachable: list[str] = []
    lock = threading.Lock()

    def ask(chat: Chat) -> None:
        try:
            conn = http.client.HTTPConnection("127.0.0.1", chat.port, timeout=3)
            conn.request("GET", "/permission", headers={"Authorization": basic_auth_header()})
            resp = conn.getresponse()
            raw = resp.read().decode("utf-8", "replace")
            status = resp.status
            conn.close()
            parsed = json.loads(raw) if status == HTTPStatus.OK else None
        except (OSError, http.client.HTTPException, json.JSONDecodeError):
            parsed = None
        if not isinstance(parsed, list):
            with lock:
                unreachable.append(chat.id)
            return
        with lock:
            # The container's own object, verbatim, with the chat it belongs
            # to spliced in at the top level.
            found.extend({**row, "chatId": chat.id} for row in parsed if isinstance(row, dict))

    workers = [(c, threading.Thread(target=ask, args=(c,), daemon=True)) for c in running]
    for _, t in workers:
        t.start()
    for _, t in workers:
        t.join(timeout=5)
    # A join that TIMES OUT leaves the thread running and adds the chat to
    # neither list, which is the one outcome the docstring above forbids: the
    # app reads "in neither list" as "definitely nothing pending" and clears
    # the card. Without this the fan-out has a window it cannot see, because
    # the 3s timeout on the connection bounds connect, getresponse and read
    # INDEPENDENTLY — a container answering successfully at 5-9s total trips
    # none of them and still misses the 5s join.
    #
    # Measured, by running this function against an in-process fake connection:
    # two running chats, the slow one answering in 5.8s with one parked ask,
    # gave found=['fast-chat'], unreachable=[], and the slow chat in neither.
    # Its ask would have vanished from the phone.
    for chat, t in workers:
        if t.is_alive():
            with lock:
                unreachable.append(chat.id)
    return found, unreachable


# --------------------------------------------------------------- github

# The pull requests a chat has opened are the deliverable, so the app shows
# them. Every call here is made BY the manager, never proxied into the chat's
# container — listing pull requests must not wake a sleeping chat, and is not
# chat activity, so these routes never touch `touch()` either.


class GitHubError(RuntimeError):
    """A GitHub call the caller has to turn into a status for the app."""

    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


def gh(
    method: str,
    path: str,
    body: dict[str, Any] | None = None,
) -> Any:  # noqa: ANN401 -- parsed JSON is genuinely Any; every caller narrows it
    """One GitHub REST call, with this manager's error vocabulary."""
    url = urlparse(GH_API + path)
    payload = json.dumps(body).encode() if body is not None else None
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "code-agent-manager",
    }
    if GH_PAT:
        headers["Authorization"] = f"Bearer {GH_PAT}"
    if payload is not None:
        headers["Content-Type"] = "application/json"
    cls = http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection
    try:
        conn = cls(url.hostname or "", url.port, timeout=20)
        conn.request(method, url.path + (f"?{url.query}" if url.query else ""), payload, headers)
        resp = conn.getresponse()
        raw = resp.read().decode("utf-8", "replace")
        conn.close()
    except (OSError, http.client.HTTPException) as e:
        raise GitHubError(502, "GitHub is unreachable") from e
    if resp.status in (401, 403):
        raise GitHubError(502, "GitHub refused the credential - the PAT may have expired")
    if resp.status >= HTTP_SERVER_ERROR:
        raise GitHubError(502, "GitHub is unreachable")
    try:
        parsed = json.loads(raw) if raw else None
    except json.JSONDecodeError as e:
        raise GitHubError(502, "GitHub is unreachable") from e
    if resp.status >= HTTP_BAD_REQUEST:
        # GitHub's own sentence is the most useful thing we can show, so it
        # travels to the app unchanged rather than being replaced by ours.
        said = ""
        if isinstance(parsed, dict):
            said = _str(parsed, "message")
        raise GitHubError(resp.status, said or f"GitHub answered {resp.status}")
    return parsed


def slug_of(name: str, entry: RepoEntry | None) -> str:
    """`owner/name` for an allowlist entry, whatever URL shape it holds.

    Split out of `repo_slug` because the branches route and the base-branch
    check both need a slug from a repo NAME, before any chat exists — and two
    copies of this parsing is how the two would drift.
    """
    if entry is None:
        raise GitHubError(409, f"repo '{name}' is not in the allowlist any more")
    url = entry.url.removesuffix(".git")
    if not url:
        raise GitHubError(409, f"repo '{name}' has no GitHub remote to read")
    # Accept the shapes an allowlist actually holds: an https clone URL, an
    # scp-style ssh remote, or a bare owner/name.
    if url.startswith(("http://", "https://")):
        parts = [p for p in urlparse(url).path.split("/") if p]
    elif ":" in url and not url.startswith("/"):
        parts = [p for p in url.split(":", 1)[1].split("/") if p]
    else:
        parts = [p for p in url.split("/") if p]
    if len(parts) < SLUG_PARTS:
        raise GitHubError(409, f"repo '{name}' has no GitHub remote to read")
    return f"{parts[-2]}/{parts[-1]}"


def repo_slug(chat: Chat) -> str:
    """`owner/name` for a chat's repo, from the allowlist entry it was made from."""
    return slug_of(chat.repo, load_repos().get(chat.repo))


# http.client gives us ints; naming them keeps the comparisons readable.
HTTP_BAD_REQUEST = 400
HTTP_SERVER_ERROR = 500
SLUG_PARTS = 2

CHECKS_FAILING = {"failure", "timed_out", "action_required", "cancelled"}
CHECKS_PENDING = {"queued", "in_progress", "waiting", "pending", "requested"}
CHECKS_PASSING = {"success", "neutral", "skipped"}


def summarise_checks(slug: str, sha: str) -> str:
    """Check runs UNION commit statuses on one commit, as one word.

    `unknown` is a real answer, not a failure: check runs need `Checks: read`
    and commit statuses need `Commit statuses: read`, and the documented PAT
    carries neither, so a private repo answers 403 here. Degrading to
    "unknown" keeps the list working; granting the two scopes upgrades it with
    no change on either side.
    """
    outcomes: list[str] = []
    try:
        runs = gh("GET", f"/repos/{slug}/commits/{sha}/check-runs?per_page=100")
        listed = runs.get("check_runs", []) if isinstance(runs, dict) else []
        outcomes.extend(
            _str(run, "conclusion") or _str(run, "status")
            for run in listed
            if isinstance(run, dict)
        )
        combined = gh("GET", f"/repos/{slug}/commits/{sha}/status")
        if isinstance(combined, dict):
            state = _str(combined, "state")
            # A combined state of "pending" with no statuses behind it is
            # GitHub's way of saying nothing has reported, not that something
            # is running.
            if (state and state != "pending") or combined.get("statuses"):
                outcomes.append(state)
    except GitHubError:
        return "unknown"
    if not outcomes:
        return "none"
    if any(o in CHECKS_FAILING or o == "error" for o in outcomes):
        return "failing"
    if any(o in CHECKS_PENDING for o in outcomes):
        return "pending"
    if all(o in CHECKS_PASSING for o in outcomes):
        return "passing"
    return "unknown"


def pull_to_wire(slug: str, raw: dict[str, Any], *, with_checks: bool = True) -> dict[str, object]:
    """One pull request in the shape the app reads.

    `mergeable` is only present on the detail form, and GitHub computes it
    asynchronously — null means "not worked out yet", which the app treats as
    a wait rather than as a refusal. It is never coerced to false.
    """
    number = int(raw.get("number") or 0)
    merged = bool(raw.get("merged_at"))
    head = _obj(raw, "head")
    base = _obj(raw, "base")
    sha = _str(head, "sha")
    mergeable = raw.get("mergeable")
    checks = "unknown"
    if with_checks and sha:
        checks = summarise_checks(slug, sha)
    return {
        "number": number,
        "title": _str(raw, "title"),
        "state": "merged" if merged else _str(raw, "state", "open"),
        "draft": bool(raw.get("draft")),
        "mergeable": mergeable if isinstance(mergeable, bool) else None,
        "checks": checks,
        "url": _str(raw, "html_url"),
        "head": _str(head, "ref"),
        "base": _str(base, "ref"),
        "created_at": _str(raw, "created_at"),
        "updated_at": _str(raw, "updated_at"),
    }


def chat_pulls(chat: Chat) -> list[dict[str, object]]:
    """Every pull request off THIS chat's branch — never the repo's others."""
    slug = repo_slug(chat)
    owner = slug.split("/")[0]
    listed = gh(
        "GET",
        f"/repos/{slug}/pulls?head={owner}:{chat.branch}"
        "&state=all&per_page=20&sort=created&direction=desc",
    )
    out: list[dict[str, object]] = []
    for entry in listed if isinstance(listed, list) else []:
        if not isinstance(entry, dict):
            continue
        number = int(entry.get("number") or 0)
        # The list form omits `mergeable`, so without this every row would
        # arrive null and the Merge button could never appear. A flaky detail
        # call degrades one row rather than blanking the list.
        detail: dict[str, Any] = entry
        try:
            fetched = gh("GET", f"/repos/{slug}/pulls/{number}")
            if isinstance(fetched, dict):
                detail = fetched
        except GitHubError:
            pass
        out.append(pull_to_wire(slug, detail))
    return out


def merge_chat_pull(chat: Chat, number: int, method: str) -> dict[str, object]:
    """Merge one of this chat's pull requests, after proving it is one."""
    slug = repo_slug(chat)
    detail = gh("GET", f"/repos/{slug}/pulls/{number}")
    if not isinstance(detail, dict):
        raise GitHubError(502, "GitHub is unreachable")
    head = _obj(detail, "head")
    # Without this the route is "merge any pull request in the repo" with a
    # chat id in front of it.
    if _str(head, "ref") != chat.branch:
        raise GitHubError(404, f"pull {number} is not from this chat's branch")
    if detail.get("merged_at"):
        raise GitHubError(409, f"#{number} is already merged.")
    if _str(detail, "state") != "open":
        raise GitHubError(409, f"#{number} is closed.")
    if detail.get("draft"):
        raise GitHubError(409, f"#{number} is still a draft.")
    mergeable = detail.get("mergeable")
    if mergeable is None:
        raise GitHubError(409, f"GitHub has not finished computing whether #{number} can merge.")
    if mergeable is False:
        base = _str(_obj(detail, "base"), "ref")
        raise GitHubError(409, f"#{number} conflicts with {base} - it needs a rebase.")
    try:
        result = gh(
            "PUT",
            f"/repos/{slug}/pulls/{number}/merge",
            {"merge_method": method},
        )
    except GitHubError as e:
        # Branch protection, a required review, a required check, a head that
        # moved: GitHub says 405 or 409. One "GitHub said no" case for the
        # app, carrying GitHub's own sentence.
        if e.status in (405, 409, 422):
            raise GitHubError(422, e.message) from e
        raise
    # Re-read WITH checks. Skipping them saves two calls on an action the
    # reader just took deliberately, and costs the row its check status: it
    # repaints from "checks passing" to "checks unknown" the instant the merge
    # lands, which reads as information lost rather than work done.
    after = gh("GET", f"/repos/{slug}/pulls/{number}")
    return {
        "merged": True,
        "sha": _str(result if isinstance(result, dict) else {}, "sha"),
        "pull": pull_to_wire(slug, after) if isinstance(after, dict) else None,
    }


# ---------------------------------------------------------------- branches

# The app's new-session sheet offers a base branch, so it needs the repo's
# branches and needs to know which one is the default.
#
# SCOPES: every call in this section — GET /repos/{slug}/branches,
# GET /repos/{slug}/branches/{ref} and GET /repos/{slug} — needs only
# `Metadata: read`, which every fine-grained PAT carries whether you want it
# or not (GitHub turns Metadata on the moment any other repository permission
# is selected and will not let you turn it off). The documented PAT (Contents
# + Pull requests, docs/setup/70-code-agents.md) is a strict superset, so this
# needs NO new permission and no re-issued token. That is the opposite of
# summarise_checks() above, which really is short its scopes and degrades.

BRANCH_PAGE_SIZE = 100  # GitHub's maximum
BRANCH_MAX_PAGES = 5  # 500 branches is a sheet nobody scrolls; stop there

# What a base branch may look like before it is worth a round trip.
# Deliberately narrower than git's check-ref-format, because this string is
# interpolated into an outbound URL path: without the guard, a base of
# "../../../user" retargets the manager's authenticated GitHub call at another
# endpoint, and a newline in it is a request-line injection. The leading
# character is pinned to alphanumeric so it can never read as an option flag
# either, whatever git command it ends up in.
#
# `\Z` rather than `$`: Python's `$` also matches just before a trailing
# newline, so `main\n` would pass a `$`-anchored pattern — and a newline is
# the one character in an outbound request line that must never get through.
BRANCH_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}\Z")


def default_branch(slug: str) -> str:
    """Report the repo's default branch, or "" when GitHub would not say.

    Degrading is deliberate: a branch list that cannot mark its default is
    still a usable list, and losing the sheet over a label is the worse trade.
    """
    try:
        info = gh("GET", f"/repos/{slug}")
    except GitHubError:
        return ""
    return _str(info, "default_branch") if isinstance(info, dict) else ""


def list_branches(name: str, entry: RepoEntry) -> dict[str, object]:
    """Every branch of an allowlisted repo, default first and marked."""
    slug = slug_of(name, entry)
    head = default_branch(slug)
    names: list[str] = []
    truncated = False
    for page in range(1, BRANCH_MAX_PAGES + 1):
        listed = gh("GET", f"/repos/{slug}/branches?per_page={BRANCH_PAGE_SIZE}&page={page}")
        rows = listed if isinstance(listed, list) else []
        names.extend(_str(row, "name") for row in rows if isinstance(row, dict))
        if len(rows) < BRANCH_PAGE_SIZE:
            break
        truncated = page == BRANCH_MAX_PAGES
    # Default first, then case-insensitive alphabetical. The sheet renders
    # this in the order it arrives, and "whatever GitHub happened to return"
    # is not an order.
    unique = [n for n in dict.fromkeys(names) if n]
    unique.sort(key=lambda n: (n != head, n.lower()))
    return {
        "repo": name,
        "slug": slug,
        "default": head,
        "truncated": truncated,
        "branches": [{"name": n, "default": n == head} for n in unique],
    }


def base_shape_error(base: str) -> ApiError | None:
    """Refuse a ref name before it reaches a URL or a git argv."""
    if (
        not BRANCH_RE.match(base)
        or ".." in base
        or "//" in base
        or base.endswith(("/", ".", ".lock"))
    ):
        return ApiError(400, f"base branch '{base}' is not a valid branch name")
    return None


def validate_base(name: str, entry: RepoEntry, base: str) -> ApiError | None:
    """Refuse a base branch with NOTHING built yet, or return None.

    Only called for a non-empty base (create_chat guards it), so the absent
    case cannot accidentally acquire behaviour. Everything here happens before
    the index entry and the volume exist: an unknown ref has to be a 400 the
    picker can print, not a container that clones, dies on `--branch`, and is
    torn down as a 502.
    """
    shape = base_shape_error(base)
    if shape is not None:
        return shape
    if entry is PROBE_REPO:
        return ApiError(400, "the _probe repo is created empty and has no branch to base on")
    try:
        slug = slug_of(name, entry)
    except GitHubError as e:
        return ApiError(e.status, e.message)
    try:
        gh("GET", f"/repos/{slug}/branches/{quote(base, safe='/')}")
    except GitHubError as e:
        if e.status == HTTPStatus.NOT_FOUND:
            return ApiError(400, f"base branch '{base}' does not exist in {slug}")
        # Unverifiable is not the same as absent, and both are the caller's to
        # see: cloning anyway turns a GitHub outage into a half-built chat.
        return ApiError(e.status, f"could not check base branch '{base}': {e.message}")
    return None


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


def admission_count(index: Index) -> int:
    """Count the running chats that count against CODE_AGENT_MAX_ACTIVE.

    A chat parked on a permission ask is exempt, and that exemption is a bug
    fix rather than a tuning knob. A blocked session reports busy on
    /session/status, so the reaper's "working counts as activity" branch
    touches it on every pass and it can never cross IDLE_SECONDS again. With
    MAX_ACTIVE = 2 that means two asks nobody answered take the WHOLE code
    plane offline: create returns 409, wake returns 409, and the 409's own
    advice — "wait for idle spin-down" — is advice to wait for the one thing
    that provably cannot happen. Stage-0 notifications make that worse before
    they make it better, because the entire premise is that an ask now sits
    parked in a pocket for twenty minutes.

    The alternative bound — an ask older than N minutes stops counting as busy
    — was rejected: it hands the reaper permission to stop a container holding
    a real ask, which is the exact failure the notification exists to prevent
    (and pending_permissions() only fans out to RUNNING containers, so the ask
    would vanish from the app at the same moment).

    The price is that the number of running containers can exceed MAX_ACTIVE
    by the number of unanswered asks. That is bounded by the number of tasks
    the reader started, it is visible as `blocked` on /api/health, and driving
    it back to zero promptly is precisely what the buzz is for.
    """
    blocked = _reaper_memory.blocked
    return sum(
        1 for cid in index.chats if cid not in blocked and container_state(cid) == "running"
    )


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


def not_allowlisted(name: str, repos: dict[str, RepoEntry]) -> ApiError:
    """Build the one refusal the create route and the branches route both give.

    Shared rather than copied: the allowlist is the trust boundary, and two
    copies of a security message is how one of them gets softened later.
    """
    listed = ", ".join(sorted(repos)) or "(allowlist empty)"
    return ApiError(
        403,
        f"repo '{name}' is not in the allowlist "
        f"(/data/code-agents/repos.json). Allowed: {listed}",
    )


def create_chat(request: CreateChatRequest) -> Chat | ApiError:
    repos = load_repos()
    probe = request.repo == "_probe"
    if not probe and request.repo not in repos:
        return not_allowlisted(request.repo, repos)
    repo = repos.get(request.repo, PROBE_REPO)

    if is_free_model(request.model) and not repo.public_throwaway:
        return ApiError(
            403,
            f"model '{request.model}' is a zen-free model — free models train on "
            "your data (docs/privacy.md hard rule 1) and are refused unless the "
            "repo is flagged public_throwaway.",
        )

    # Before the index entry, the volume, or any container: an unknown ref is
    # a 400 the picker can print, not a clone that dies half-built.
    if request.base:
        refusal = validate_base(request.repo, repo, request.base)
        if refusal is not None:
            return refusal

    with _lock:
        index = Index.load()
        if admission_count(index) >= MAX_ACTIVE:
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
            base=request.base,
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
            #
            # `--branch` only when one was asked for, so the default path is
            # the exact string it has always been. `git clone --branch X` still
            # fetches every branch, so `git checkout -b` right after cuts the
            # chat's branch from the right commit and the agent can still diff
            # against the repo's default. The ref was proved to exist above;
            # the clone is the second authority, and a disagreement still takes
            # the cleanup path below.
            at_base = f"--branch {shquote(chat.base)} " if chat.base else ""
            script = (
                f"cd /chat/workspace && "
                f"git clone {at_base}{shquote(repo.url)} . && "
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
            # NOT touch(): we already hold `_lock` (:270) and touch() re-acquires
            # it. `threading.Lock` is not reentrant, so that call parks this
            # thread forever WHILE IT STILL OWNS the lock, and `_lock` is never
            # released again for the life of the process. Every route that needs
            # it then blocks behind a holder that is itself blocked on it: the
            # proxy, every later wake, create_chat, route_delete_chat and the
            # idle reaper. The routes that take no lock — /api/chats,
            # /api/permissions, /api/health, /api/repos — keep answering, which
            # is what makes the wedge present as a slow backend rather than a
            # dead one. Only a restart clears it.
            #
            # Reproduced, not theorised. `route_wake_or_stop` performs
            # POST /api/chats/<id>/wake with no check of the current state, so
            # one wake against a running chat is enough. A `sample` of a wedged
            # manager showed 14 request threads parked in
            # `lock_PyThread_acquire_lock`, the main thread healthy in `poll`,
            # and no thread holding the lock inside a syscall — the signature of
            # an owner blocked on its own lock.
            #
            # The proxy reaches the same branch by a race, and that race is
            # WIDER in production than under the test harness: the state is read
            # outside the lock and re-read inside it, `wake_chat` releases the
            # lock before `engine("start")` and the up-to-90s `wait_for_chat`,
            # and `podman container inspect` reports "running" as soon as start
            # returns — long before opencode answers. That is the whole window
            # the client's concurrent open-chat requests land in.
            #
            # The same work, inline, against the index this block already
            # loaded, which is also one fewer read of index.json.
            chat.last_active = time.time()
            index.save()
            return 200, "already running"
        if admission_count(index) >= MAX_ACTIVE:
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


def session_state(chat: Chat) -> str:
    """Sample this chat's server: "busy", "idle" or "unknown".

    Three states rather than two because the reaper and the notifier want
    OPPOSITE defaults for the third one. A wrong "idle" costs the reaper a
    running turn, so it reads unknown as busy. A wrong
    "busy" costs the notifier nothing, but a wrong "idle" would manufacture a
    "turn finished" out of a container hiccup — so the notifier fires on the
    literal "idle" and on nothing else. Collapsing this back to a bool would
    give one of the two callers the wrong answer.

    "busy" and "retry" are the two non-idle states /session/status reports;
    idle sessions are absent from the map entirely, so `{}` is idle.
    """
    try:
        conn = http.client.HTTPConnection("127.0.0.1", chat.port, timeout=5)
        conn.request(
            "GET",
            "/session/status",
            headers={"Authorization": basic_auth_header()},
        )
        resp = conn.getresponse()
        body = resp.read().decode("utf-8", "replace")
        conn.close()
        if resp.status != HTTPStatus.OK:
            return "unknown"
        data: Any = json.loads(body or "{}")
        blob = json.dumps(data).lower()
    except (OSError, ValueError):
        return "unknown"
    return "busy" if ('"busy"' in blob or '"retry"' in blob) else "idle"


def notify_new_asks(
    index: Index,
    asks: list[dict[str, object]],
    unreachable: list[str],
    running: frozenset[str],
) -> None:
    """Buzz once for every ask that has not been announced before.

    NEW means "an ask id absent from what we announced last time", keyed on
    (chat, permission id). The id is opaque server state — treat it as a
    string, never parse it — and opencode never reuses one, so a set membership
    test is the whole rule. No quiet window and no coalescing across passes: a
    blocked agent is doing nothing at all until it is answered.

    The pruning is the subtle half. A chat only gets to REVISE the set of asks
    we believe are parked on it if it actually answered this pass — a chat in
    `unreachable`, or one whose container is not running, said nothing, and
    dropping its ids on that silence would re-announce every one of them next
    pass. A chat gone from the index entirely is dropped, or the map grows
    forever.
    """
    by_chat: dict[str, set[str]] = {}
    for row in asks:
        cid, ask_id = row.get("chatId"), row.get("id")
        if isinstance(cid, str) and isinstance(ask_id, str) and ask_id:
            by_chat.setdefault(cid, set()).add(ask_id)

    seen = _reaper_memory.seen_asks
    for cid in list(seen):
        if cid not in index.chats:
            seen.pop(cid, None)
        elif cid in running and cid not in unreachable:
            seen[cid] &= by_chat.get(cid, set())

    fresh = 0
    chats: list[str] = []
    for cid, ask_ids in sorted(by_chat.items()):
        chat = index.chats.get(cid)
        # A probe chat is check-code-agents.sh --probe and the verify harness:
        # unattended verification, by definition nobody's pocket.
        if chat is None or chat.probe:
            continue
        new = ask_ids - seen.get(cid, set())
        seen.setdefault(cid, set()).update(ask_ids)
        if new:
            fresh += len(new)
            chats.append(cid)

    # The MAX_ACTIVE exemption (admission_count), off the same fan-out, so
    # there is one definition of "parked on an ask" rather than two that drift.
    # A chat that would not answer this pass contributes no rows and so is
    # absent here — which errs toward ENFORCING the cap rather than toward
    # exempting a container the manager cannot currently see.
    _reaper_memory.blocked = frozenset(by_chat)
    if fresh:
        notify_agent("ask", fresh, chats)


def notify_finished_turns(
    index: Index, status: dict[str, str], running: frozenset[str], sampled_at: float,
) -> None:
    """Buzz once for every chat whose turn has ended since we armed it.

    NOT a busy->idle edge, which is the tempting reading and is wrong twice
    over at a 60-second sampling interval: a turn that starts and finishes
    between two samples is never observed busy, so it produces no edge and no
    buzz, and a container hiccup that recovers produces an edge with no turn
    behind it. Instead the manager ARMS a chat when it proxies an accepted
    prompt — every prompt goes through proxy(), because the chat port is
    published on 127.0.0.1 only — and fires when that armed chat reports idle.
    A between-samples turn is still armed at the next sample, so it still
    buzzes; and one prompt yields at most one buzz by construction, which is
    why a five-tool turn needs no debounce timer to stay one notification.

    Three things withhold the buzz:
      * the chat was not running at BOTH this sample and the last one, which
        covers a user Stop, an idle spin-down, a delete and a crash;
      * the prompt was accepted less than ARM_SETTLE_SECONDS ago, because
        prompt_async returns before the server has necessarily marked the
        session busy, and reading that gap as "already finished" would buzz
        the instant the work started;
      * `status` is anything but the literal "idle" (see session_state).
    An abort disarms without firing: a cancelled turn ended because you said
    so, and it is indistinguishable from a natural completion on the wire.
    """
    # AGAINST `sampled_at`, NOT `time.time()`. The `status` map judged below was
    # taken at the top of the pass, before a `pending_permissions` fan-out that
    # can block a full 5s and before an ntfy POST. Measuring arm->NOW instead of
    # arm->SAMPLE lets a slow pass declare a turn finished using a status read
    # before that turn began: sample X idle at T0, press send at T0+1, notify at
    # T0+25, and 24 >= 5 fires "turn ended" 24 seconds INTO a twenty-minute run.
    # One bug, two symptoms — it also pops the arm, so the real ending is lost
    # and never buzzes at all.
    ended: list[str] = []
    with _reaper_memory.armed_lock:
        for cid, armed_at in sorted(_reaper_memory.armed.items()):
            if cid not in index.chats or cid not in running:
                _reaper_memory.armed.pop(cid, None)
                continue
            if sampled_at - armed_at < ARM_SETTLE_SECONDS:
                continue
            if status.get(cid) != "idle" or cid not in _reaper_memory.prev_running:
                continue
            _reaper_memory.armed.pop(cid, None)
            ended.append(cid)
    if ended:
        notify_agent("turn", len(ended), ended)


def spin_down_idle(index: Index, status: dict[str, str], running: frozenset[str]) -> None:
    """Stop the chats that have gone quiet, reading the sample already taken."""
    now = time.time()
    for cid in sorted(running):
        chat = index.chats[cid]
        if now - chat.last_active < IDLE_SECONDS:
            continue
        if status.get(cid, "unknown") != "idle":
            touch(cid)  # working — or unknowable, which counts the same — is activity
            continue
        log(f"idle spin-down: {cid}")
        engine("stop", container_name(cid), check=False, timeout=90)


def reaper_pass() -> None:
    """One sweep: sample every running chat once, notify, then spin down.

    Sampling before notifying and reaping is what makes the pass cheap: the
    container states, the /session/status reads and the permission fan-out are
    each done ONCE and shared. Every one of those goes direct to
    127.0.0.1:<chat.port>, never through proxy() — proxying would call
    touch_maybe() and pin every container open, which is the failure mode the
    whole idle spin-down design exists to avoid.
    """
    # STAMPED BEFORE THE SAMPLE, NOT AFTER. `sampled_at` answers "the readings
    # below are no older than when?", and only a stamp taken first can. Taken
    # after, it dates the readings to the END of a walk that is `container_state`
    # plus `session_state` per chat — each a subprocess or a socket with
    # timeout=5, serially, over a running set that is NOT bounded by MAX_ACTIVE
    # because admission_count exempts blocked chats. Two wedged siblings put ten
    # seconds between the first chat's reading and the stamp, which is larger
    # than ARM_SETTLE_SECONDS, so a turn armed one second after that reading
    # looked settled: notify_finished_turns buzzed "turn ended" nine seconds
    # INTO the turn and popped the arm, so the real ending never buzzed at all.
    # Stamping first can only ever be too early, and too early merely withholds
    # a buzz until the next pass — which is what the withhold is for.
    sampled_at = time.time()
    index = Index.load()
    states = {cid: container_state(cid) for cid in index.chats}
    running = frozenset(cid for cid, state in states.items() if state == "running")
    status = {cid: session_state(index.chats[cid]) for cid in sorted(running)}

    # The ask fan-out is the slowest step in the pass and the only one that
    # spawns threads, so it is also the likeliest to raise something the loop's
    # narrow except does not catch — `RuntimeError: can't start new thread`
    # being the one that matters. Uncaught it would kill the reaper THREAD, not
    # just the pass, and spin-down would stop forever while every lock-free
    # route kept answering. On failure the asks are simply unknown this pass:
    # notify_new_asks is skipped rather than fed an empty map, because it ends
    # by assigning `_reaper_memory.blocked` and an empty map there would revoke
    # every blocked chat's MAX_ACTIVE exemption on a fan-out hiccup.
    asks: list[dict[str, object]] | None = None
    unreachable: list[str] = []
    try:
        asks, unreachable = pending_permissions([index.chats[cid] for cid in sorted(running)])
    except Exception as e:  # noqa: BLE001 - an ask probe must never cost a spin-down
        log(f"reaper ask probe failed: {type(e).__name__}: {e}")

    # SPIN DOWN BEFORE NOTIFYING, and never let notifying break the pass.
    #
    # The reaper's real job is stopping idle containers; the buzz is a courtesy
    # on top of it. Ordered the other way, an ntfy outage delayed every
    # spin-down — and worse, `notify_agent` suppressed only OSError and
    # HTTPException, while a malformed NTFY_SERVER raises ValueError from
    # `url.port` and a non-ASCII topic raises UnicodeEncodeError from
    # putrequest. Neither was caught there and both were caught by the loop, so
    # the pass logged "reaper error" and returned BEFORE spin_down_idle — on
    # every pass, forever. Idle spin-down would stop dead while every lock-free
    # route kept answering, which is precisely the shape of failure this file
    # has already shipped once.
    #
    # LOGGED, NEVER SUPPRESSED SILENTLY. `notify_failure` suppresses two NAMED
    # types; this catches Exception, which is a wider net and so has to say when
    # it caught something. A blanket silent suppress would let the buzz die
    # permanently with no log line and no health field — and worse, an early
    # raise inside notify_new_asks leaves `_reaper_memory.blocked` frozen at the
    # last good pass, and `blocked` is the MAX_ACTIVE exemption that stops two
    # unanswered asks taking the whole code plane offline.
    spin_down_idle(index, status, running)
    if asks is not None:
        try:
            notify_new_asks(index, asks, unreachable, running)
        except Exception as e:  # noqa: BLE001 - a buzz must never cost a spin-down
            log(f"reaper notify failed (asks): {type(e).__name__}: {e}")
    try:
        notify_finished_turns(index, status, running, sampled_at)
    except Exception as e:  # noqa: BLE001 - a buzz must never cost a spin-down
        log(f"reaper notify failed (turns): {type(e).__name__}: {e}")
    _reaper_memory.prev_running = running


def reaper_loop() -> None:
    while True:
        time.sleep(REAPER_INTERVAL)
        try:
            reaper_pass()
        except (OSError, subprocess.SubprocessError, ValueError) as e:
            log(f"reaper error: {e}")


# The ONE place an agent notification is assembled (docs/privacy.md). Two
# kinds, and only two. The ask is `high` because a blocked agent is doing
# nothing at all until it is answered; a turn end is ordinary news.
#
# "a turn ended", not "done": stage 0 cannot tell a clean completion from a
# provider error or a context overflow without reading message content
# server-side, which is exactly what it must not do. The honest title is the
# one that does not claim success.
NOTIFY_TITLES = {
    "ask": ("A code agent is waiting on you", "high"),
    "turn": ("A code agent turn ended", "default"),
}
# The prompt and abort subpaths, as they arrive at proxy(). Matched against the
# subpath alone, never the query string.
PROMPT_PATH = re.compile(r"^/session/[^/]+/prompt(_async)?$")
ABORT_PATH = re.compile(r"^/session/[^/]+/abort$")
# How long after an accepted prompt the chat must be armed before an "idle"
# reading is believed. prompt_async answers 204 and the server marks the
# session busy a moment later; without this floor a sample landing in that gap
# would report the turn finished before it began.
ARM_SETTLE_SECONDS = 5.0


def notify_agent(kind: str, count: int, chats: list[str]) -> None:
    """Buzz the phone. Content-free BY CONSTRUCTION — a kind, a handle, a count.

    Nothing derived from the work travels. The traps are specific and every
    one of them is a field a careful implementer reaches for first:

      * `chat.id` is `re.sub(r"[^a-zA-Z0-9-]", "-", f"{repo}-{suffix}")` —
        it EMBEDS the repository name, one private repo per notification.
      * `chat.title` defaults to `(task or chat_id)[:80]`: the first eighty
        characters of the reader's own prompt, verbatim.
      * an ask's `metadata` is the tool's arguments — for a bash ask, the
        literal shell command.

    So the wire gets `{"kind": ..., "handle": ..., "count": N}` and a fixed
    title, and the app fetches the truth back over the tailnet once it is open.
    That is sufficient, not a compromise: /api/permissions is already the
    app's authority and it reconciles on every poll. The bar here is the LOCK
    SCREEN, not the app — a body that is safe behind Face ID is not safe
    rendered on a locked phone, and no header we can send changes that.

    `handle` is opaque random, minted per notification and kept only in
    memory; nothing redeems it yet (stage 3 adds the exchange endpoint, and
    the deep link it needs is dead today). It is here so the payload the app
    will one day parse is the payload shipping now.

    Delivery never touches the work — notify.sh's rule, inherited verbatim.
    Everything is suppressed and logged; a dead ntfy costs a buzz, never a
    turn, an ask or a spin-down. Deliberately NOT notify.sh itself: that
    script attaches an `Email:` header whenever NTFY_EMAIL is set, which would
    burn the ~5/day free-tier forwarding cap the failure-alert backstop
    depends on.
    """
    if not NTFY_AGENT_TOPIC or count <= 0:
        return
    title, priority = NOTIFY_TITLES[kind]
    body = json.dumps({"kind": kind, "handle": _reaper_memory.mint_handle(chats), "count": count})
    # OFF THE REAPER THREAD. `NTFY_TIMEOUT` does not bound this call: http.client
    # hands the timeout to socket.create_connection, which calls getaddrinfo()
    # BEFORE applying it, so a stalled resolver blocks for the resolver's own
    # budget (glibc: timeout x attempts x nameservers, tens of seconds); and once
    # connected the timeout applies INDEPENDENTLY to connect, send, getresponse
    # and read, so one POST can reach ~20s and a pass makes two.
    #
    # The payload and the handle are computed on THIS thread, so what is sent is
    # decided by the pass that decided to send it. Only the socket work moves.
    # Fire and forget: nothing reads the result, a daemon thread cannot hold the
    # process open, and the alternative — joining with a timeout — reintroduces
    # the stall it exists to remove.
    threading.Thread(
        target=_post_ntfy,
        args=(kind, title, priority, body),
        daemon=True,
    ).start()


def _post_ntfy(kind: str, title: str, priority: str, body: str) -> None:
    """Send one notification. The socket half of `notify_agent`, off its thread.

    CATCHES Exception, and it has to. This runs on a daemon thread, where
    anything uncaught goes to threading.excepthook and prints a full traceback
    to stderr and so to journald. Two live paths escape a narrower net:
    `url.port` raises ValueError on a malformed NTFY_SERVER, and putrequest
    raises UnicodeEncodeError on a non-ASCII topic — and that one's message
    quotes the offending character of the topic AND its offset, verbatim, in
    the log the topic must stay out of. Narrowing this to named types is what
    puts the secret in the log.
    """
    url = urlparse(NTFY_SERVER)
    conn_cls = http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection
    try:
        conn = conn_cls(url.hostname or "", url.port, timeout=NTFY_TIMEOUT)
        conn.request(
            "POST",
            f"{url.path.rstrip('/')}/{NTFY_AGENT_TOPIC}",
            body.encode(),
            {"Title": title, "Priority": priority, "Content-Type": "application/json"},
        )
        resp = conn.getresponse()
        resp.read()
        status = resp.status
        conn.close()
    except Exception as e:  # noqa: BLE001 - see the docstring: a narrower net logs the topic
        # The exception TYPE only: an ntfy error string can quote the request
        # line, and the topic is in the request line. The topic is a password.
        log(f"agent notification lost ({kind}): {type(e).__name__}")
        return
    if status >= HTTP_BAD_REQUEST:
        log(f"agent notification refused ({kind}): HTTP {status}")


def arm_from_proxy(chat: Chat, subpath: str, status: int) -> None:
    """Note that a turn was started (or cancelled) on this chat.

    Called from a request thread with the upstream's answer in hand, so only a
    prompt the chat's own server ACCEPTED arms it — a prompt it rejected with a
    400 never started a turn, and arming on it would fire "a turn ended" at the
    next sample. Probe chats are never armed at all: they are unattended
    verification runs, and nobody is waiting on one.

    Takes `armed_lock` and nothing else. It must never be reached while `_lock`
    is held, and it never is: proxy() has released it by here.
    """
    if chat.probe or status >= HTTP_BAD_REQUEST:
        return
    if PROMPT_PATH.match(subpath):
        with _reaper_memory.armed_lock:
            _reaper_memory.armed[chat.id] = time.time()
    elif ABORT_PATH.match(subpath):
        # Stopping the turn yourself is not news; you are holding the phone.
        # On the wire an abort and a natural completion are byte-identical, so
        # this is the only chance to tell them apart.
        with _reaper_memory.armed_lock:
            _reaper_memory.armed.pop(chat.id, None)


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

    def read_body(self) -> bytes | None:
        """Read the request body, or refuse one too large to hold in memory.

        Returns None when it has already answered 413, so a caller that keeps
        going would be writing a second response onto the same request.

        The phone can attach files, so a prompt is no longer a sentence: it
        caps a message at 8 MB of attachment, which is ~10.7 MB once base64'd
        plus the JSON around it. The limit here is well clear of that and
        exists for the other direction — without one, a declared
        Content-Length is an instruction to allocate that much.
        """
        n = int(self.headers.get("Content-Length") or 0)
        if n > MAX_BODY_BYTES:
            self.send_json(
                413,
                {"error": f"request body is larger than {MAX_BODY_BYTES // (1024 * 1024)} MB"},
            )
            return None
        return self.rfile.read(n) if n else b""

    # ---- routing ----
    ROUTE_CHAT = re.compile(r"^/chat/([a-zA-Z0-9-]+)(/.*|$)")
    ROUTE_LIFECYCLE = re.compile(r"^/api/chats/([a-zA-Z0-9-]+)/(wake|stop)$")
    ROUTE_ONE_CHAT = re.compile(r"^/api/chats/([a-zA-Z0-9-]+)$")
    # Plain reads, dispatched from a table so adding one does not make
    # handle_any harder to follow.
    API_READS: ClassVar[dict[str, str]] = {
        "/api/health": "route_health",
        "/api/repos": "route_repos",
        "/api/chats": "route_list_chats",
        "/api/permissions": "route_permissions",
    }
    ROUTE_PULLS = re.compile(r"^/api/chats/([a-zA-Z0-9-]+)/pulls$")
    ROUTE_MERGE = re.compile(r"^/api/chats/([a-zA-Z0-9-]+)/pulls/([0-9]+)/merge$")
    # `[^/]+` is permissive on purpose: the captured name is looked up in the
    # allowlist and never concatenated into an outbound URL — only the slug
    # derived from the allowlist ENTRY is. The allowlist is the gate, not the
    # charset, so a repo name the owner chose can never be rejected by one we
    # guessed at.
    ROUTE_BRANCHES = re.compile(r"^/api/repos/([^/]+)/branches$")

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
        pulls = self.ROUTE_PULLS.match(path)
        merge = self.ROUTE_MERGE.match(path)
        branches = self.ROUTE_BRANCHES.match(path)
        if chat:
            self.proxy(chat.group(1), chat.group(2) or "/")
        elif verb == "GET" and path in self.API_READS:
            getattr(self, self.API_READS[path])()
        elif branches and verb == "GET":
            self.route_branches(unquote(branches.group(1)))
        elif (path, verb) == ("/api/chats", "POST"):
            self.route_create_chat()
        elif lifecycle and verb == "POST":
            self.route_wake_or_stop(lifecycle.group(1), lifecycle.group(2))
        elif one_chat and verb == "DELETE":
            self.route_delete_chat(one_chat.group(1))
        elif pulls or merge:
            self.route_pull_requests(pulls, merge, verb)
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
                # `active` is every running container; `blocked` is how many of
                # them are only running because they are parked on an ask and
                # so do not count against max_active (admission_count). Without
                # this field, "active: 3, max_active: 2" reads as a bug.
                "blocked": sum(1 for cid in index.chats if cid in _reaper_memory.blocked),
                "max_active": MAX_ACTIVE,
                "idle_seconds": IDLE_SECONDS,
            },
        )

    def route_permissions(self) -> None:
        """Asks parked on running chats — the app's way of seeing them all."""
        found, unreachable = pending_permissions()
        self.send_json(200, {"permissions": found, "unreachable": unreachable})

    def route_repos(self) -> None:
        self.send_json(200, {"repos": [repo.to_wire() for repo in load_repos().values()]})

    def route_branches(self, name: str) -> None:
        """One allowlisted repo's branches, for the app's base picker.

        A manager call, not a proxy: choosing a base happens before any chat
        exists, so there is nothing here to wake and nothing to mark active.
        The allowlist check comes first so a caller can never name a repo the
        owner did not list.
        """
        repos = load_repos()
        entry = repos.get(name)
        if entry is None:
            refusal = not_allowlisted(name, repos)
            self.send_json(refusal.status, {"error": refusal.message})
            return
        try:
            self.send_json(200, list_branches(name, entry))
        except GitHubError as e:
            self.send_json(e.status, {"error": e.message})

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
            raw_body = self.read_body()
            if raw_body is None:
                return
            raw: Any = json.loads(raw_body or b"{}")
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

    def route_pull_requests(
        self,
        pulls: re.Match[str] | None,
        merge: re.Match[str] | None,
        verb: str,
    ) -> None:
        """Dispatch the two pull-request routes, kept out of handle_any."""
        if pulls and verb == "GET":
            self.route_pulls(pulls.group(1))
        elif merge and verb == "POST":
            self.route_merge(merge.group(1), int(merge.group(2)))
        else:
            self.send_json(404, {"error": f"no route: {verb} {urlparse(self.path).path}"})

    def chat_or_404(self, chat_id: str) -> Chat | None:
        """Return the index entry, or send a 404 and return None."""
        chat = Index.load().chats.get(chat_id)
        if chat is None:
            self.send_json(404, {"error": "unknown chat"})
        return chat

    def route_pulls(self, chat_id: str) -> None:
        """List this chat's pull requests.

        Deliberately not a proxy: these are GitHub calls the manager makes, so
        listing them never wakes a sleeping chat, and it is not chat activity
        so it never defers the reaper either.
        """
        chat = self.chat_or_404(chat_id)
        if chat is None:
            return
        try:
            self.send_json(200, {"pulls": chat_pulls(chat)})
        except GitHubError as e:
            self.send_json(e.status, {"error": e.message})

    def route_merge(self, chat_id: str, number: int) -> None:
        chat = self.chat_or_404(chat_id)
        if chat is None:
            return
        try:
            raw_body = self.read_body()
            if raw_body is None:
                return
            raw: Any = json.loads(raw_body or b"{}")
        except json.JSONDecodeError:
            raw = {}
        method = _str(raw, "method") if isinstance(raw, dict) else ""
        # An agent branch is a pile of work-in-progress commits, so the
        # default flattens it rather than pouring all of them onto the base.
        if method not in ("merge", "squash", "rebase"):
            method = "squash"
        try:
            self.send_json(200, merge_chat_pull(chat, number, method))
        except GitHubError as e:
            self.send_json(e.status, {"error": e.message})

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
        if body is None:
            return
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

        arm_from_proxy(chat, subpath, resp.status)
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
