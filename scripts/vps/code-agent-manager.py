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
                              to plain HTTP on 127.0.0.1 with a loud warning)
"""

import base64
import http.client
import json
import os
import re
import secrets as pysecrets
import shutil
import socket
import ssl
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# ------------------------------------------------------------- configuration

ROOT = os.environ.get("CODE_AGENT_ROOT", "/data/code-agents")
CHATS_DIR = os.path.join(ROOT, "chats")
INDEX_PATH = os.path.join(ROOT, "index.json")
REPOS_PATH = os.path.join(ROOT, "repos.json")

GATEWAY_PORT = int(os.environ.get("CODE_AGENT_PORT", "4300"))
IDLE_SECONDS = int(os.environ.get("CODE_AGENT_IDLE_SECONDS", "900"))
MAX_ACTIVE = int(os.environ.get("CODE_AGENT_MAX_ACTIVE", "2"))
MEM_LIMIT = os.environ.get("CODE_AGENT_MEM", "1200m")
CPU_LIMIT = os.environ.get("CODE_AGENT_CPUS", "1.5")
ENGINE = os.environ.get("CODE_AGENT_ENGINE", "podman")
IMAGE = os.environ.get("CODE_AGENT_IMAGE", "code-agent:local")
TLS_CERT = os.environ.get("CODE_AGENT_TLS_CERT", "/data/tls/cert.pem")
TLS_KEY = os.environ.get("CODE_AGENT_TLS_KEY", "/data/tls/key.pem")

PASSWORD = os.environ.get("OPENCODE_SERVER_PASSWORD", "")
GH_PAT = os.environ.get("GITHUB_CODE_AGENT_PAT", "")
ZEN_KEY = os.environ.get("OPENCODE_ZEN_API_KEY", "")
TOGETHER_KEY = os.environ.get("TOGETHER_API_KEY", "")

CONFIG_TEMPLATE = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "config", "code-agents", "opencode.json",
)

BASE_CHAT_PORT = 4310  # per-chat opencode ports: 4310, 4311, ... on 127.0.0.1

# Zen's free models train on user data (docs/privacy.md, hard rule 1). Refused
# unless the repo's allowlist entry sets public_throwaway. The explicit set
# tracks docs/model-routing.md; the "free" substring is a forward-compat net.
FREE_MODEL_IDS = {"big-pickle", "muse-spark-contributor"}


def log(msg):
    print(f"code-agent-manager: {msg}", flush=True)


# ------------------------------------------------------------- index / repos

_lock = threading.Lock()


def _load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def load_index():
    return _load_json(INDEX_PATH, {"chats": {}})


def save_index(index):
    tmp = INDEX_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(index, f, indent=1)
    os.replace(tmp, INDEX_PATH)


def load_repos():
    data = _load_json(REPOS_PATH, {"repos": []})
    return {r["name"]: r for r in data.get("repos", []) if "name" in r}


# ------------------------------------------------------------------ engine

def engine(*args, check=True, capture=True, timeout=120):
    cmd = [ENGINE, *args]
    return subprocess.run(
        cmd, check=check, timeout=timeout,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None, text=True,
    )


def container_name(chat_id):
    return f"code-agent-{chat_id}"


def container_state(chat_id):
    """running | stopped (exists, not running) | absent"""
    try:
        r = engine("container", "inspect", "--format", "{{.State.Status}}",
                   container_name(chat_id), check=False)
    except Exception:
        return "absent"
    if r.returncode != 0:
        return "absent"
    return "running" if r.stdout.strip() == "running" else "stopped"


def running_count(index):
    return sum(1 for cid in index["chats"] if container_state(cid) == "running")


def run_container(chat):
    """Create + start the chat's container (state lives in the volume)."""
    chat_dir = os.path.join(CHATS_DIR, chat["id"])
    args = [
        "run", "-d", "--name", container_name(chat["id"]),
        "--label", "code-agent=1",
        "--memory", MEM_LIMIT, "--cpus", CPU_LIMIT,
        "-p", f"127.0.0.1:{chat['port']}:4096",
        "-v", f"{chat_dir}:/chat",
        "-e", f"OPENCODE_SERVER_PASSWORD={PASSWORD}",
        "-e", "OPENCODE_DISABLE_AUTOUPDATE=1",
    ]
    if TOGETHER_KEY:
        args += ["-e", f"TOGETHER_API_KEY={TOGETHER_KEY}"]
    if GH_PAT and not chat.get("probe"):
        args += ["-e", f"GH_TOKEN={GH_PAT}"]
    args += [IMAGE, "serve", "--hostname", "0.0.0.0", "--port", "4096"]
    engine(*args)


def oneshot(chat_dir, script, env_extra=(), timeout=600):
    """Run a shell one-shot inside a throwaway container on the chat volume
    (used for clone/branch/setup so git + gh + the token never need to exist
    on the host side of this service)."""
    args = ["run", "--rm", "--entrypoint", "/bin/sh",
            "-v", f"{chat_dir}:/chat"]
    for kv in env_extra:
        args += ["-e", kv]
    args += [IMAGE, "-c", script]
    return engine(*args, timeout=timeout)


def wait_for_chat(port, timeout_s=90):
    """Poll the chat's opencode server until it answers (auth'd or 401)."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
            conn.request("GET", "/session",
                         headers={"Authorization": basic_auth_header()})
            resp = conn.getresponse()
            resp.read()
            conn.close()
            if resp.status in (200, 401):
                return True
        except OSError:
            pass
        time.sleep(1.5)
    return False


def basic_auth_header():
    tok = base64.b64encode(f"opencode:{PASSWORD}".encode()).decode()
    return f"Basic {tok}"


# ------------------------------------------------------------ chat lifecycle

def next_port(index):
    used = {c["port"] for c in index["chats"].values()}
    port = BASE_CHAT_PORT
    while port in used:
        port += 1
    return port


def is_free_model(model):
    if not model:
        return False
    bare = model.split("/", 1)[-1].lower()
    return bare in FREE_MODEL_IDS or "free" in bare


def render_chat_config(chat_dir, model, allow_push):
    """Render the per-chat opencode config from the repo template."""
    with open(CONFIG_TEMPLATE, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    cfg.pop("_readme", None)
    if model:
        cfg["model"] = model
    if allow_push:
        cfg.setdefault("permission", {}).setdefault("bash", {})["git push*"] = "allow"
    dst_dir = os.path.join(chat_dir, "home", ".config", "opencode")
    os.makedirs(dst_dir, exist_ok=True)
    with open(os.path.join(dst_dir, "opencode.json"), "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)


def seed_auth(chat_dir):
    """Seed opencode's auth.json so Zen models work headlessly.
    NOTE: shape mirrors what `opencode auth login` writes as of the pinned
    version — check-code-agents.sh --probe verifies models actually resolve;
    if upstream changes the schema, fix it here."""
    if not ZEN_KEY:
        return
    d = os.path.join(chat_dir, "home", ".local", "share", "opencode")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "auth.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"opencode": {"type": "api", "key": ZEN_KEY}}, f)
    os.chmod(path, 0o600)


def create_chat(body):
    repos = load_repos()
    repo_name = body.get("repo", "")
    probe = repo_name == "_probe"
    if not probe and repo_name not in repos:
        listed = ", ".join(sorted(repos)) or "(allowlist empty)"
        return None, (403, f"repo '{repo_name}' is not in the allowlist "
                           f"(/data/code-agents/repos.json). Allowed: {listed}")
    repo = repos.get(repo_name, {"name": "_probe", "url": "", "setup": "",
                                 "allow_push": False, "public_throwaway": False})

    model = body.get("model") or ""
    if is_free_model(model) and not repo.get("public_throwaway"):
        return None, (403, f"model '{model}' is a zen-free model — free models "
                           "train on your data (docs/privacy.md hard rule 1) and "
                           "are refused unless the repo is flagged public_throwaway.")

    with _lock:
        index = load_index()
        if running_count(index) >= MAX_ACTIVE:
            return None, (409, f"{MAX_ACTIVE} chats already active (CODE_AGENT_MAX_ACTIVE) "
                               "— stop one or wait for idle spin-down.")
        suffix = pysecrets.token_hex(3)
        chat_id = re.sub(r"[^a-zA-Z0-9-]", "-", f"{repo_name}-{suffix}").strip("-")
        port = next_port(index)
        chat = {
            "id": chat_id, "repo": repo_name,
            "title": body.get("title") or (body.get("task") or chat_id)[:80],
            "model": model or None, "port": port,
            "branch": f"agent/{chat_id}", "probe": probe,
            "created": time.time(), "last_active": time.time(),
        }
        index["chats"][chat_id] = chat
        save_index(index)

    chat_dir = os.path.join(CHATS_DIR, chat_id)
    os.makedirs(os.path.join(chat_dir, "workspace"), exist_ok=True)
    os.makedirs(os.path.join(chat_dir, "home"), exist_ok=True)
    render_chat_config(chat_dir, model, repo.get("allow_push", False))
    seed_auth(chat_dir)

    try:
        if probe:
            # Self-contained scratch repo: lets the verify script exercise the
            # whole lifecycle with no network and no credential.
            oneshot(chat_dir,
                    "cd /chat/workspace && git init -q -b main && "
                    "git -c user.email=probe@localhost -c user.name=probe "
                    "commit -q --allow-empty -m init && "
                    f"git checkout -q -b {chat['branch']}")
        else:
            # Clone + branch in-container: gh's credential helper turns
            # GH_TOKEN into the HTTPS credential; nothing token-shaped is
            # ever written to the volume. Commits get a distinct identity —
            # never the owner's personal one (issue #17 C4).
            script = (
                f"cd /chat/workspace && "
                f"git clone {shquote(repo['url'])} . && "
                f"git checkout -b {chat['branch']} && "
                f"git config user.name 'code-agent' && "
                f"git config user.email 'code-agent@brain.invalid'"
            )
            oneshot(chat_dir, script, env_extra=[f"GH_TOKEN={GH_PAT}"])
            setup = (repo.get("setup") or "").strip()
            if setup:
                oneshot(chat_dir, f"cd /chat/workspace && {setup}",
                        timeout=1800)
        run_container(chat)
        if not wait_for_chat(port):
            raise RuntimeError("opencode server did not come up in 90s")
    except Exception as e:
        log(f"create {chat_id} failed: {e}")
        notify_failure(f"chat create failed ({chat_id}): launch/setup error")
        with _lock:
            index = load_index()
            index["chats"].pop(chat_id, None)
            save_index(index)
        engine("rm", "-f", container_name(chat_id), check=False)
        shutil.rmtree(chat_dir, ignore_errors=True)
        return None, (502, f"chat create failed: {e}")

    return chat, None


def shquote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def wake_chat(chat_id):
    with _lock:
        index = load_index()
        chat = index["chats"].get(chat_id)
        if not chat:
            return 404, "unknown chat"
        state = container_state(chat_id)
        if state == "running":
            touch(chat_id)
            return 200, "already running"
        if running_count(index) >= MAX_ACTIVE:
            return 409, (f"{MAX_ACTIVE} chats already active — stop one or "
                         "wait for idle spin-down.")
    try:
        if state == "stopped":
            engine("start", container_name(chat_id))
        else:  # absent (e.g. removed after an image upgrade) — volume has it all
            run_container(chat)
        if not wait_for_chat(chat["port"]):
            return 502, "chat container started but opencode did not answer"
    except Exception as e:
        notify_failure(f"chat wake failed ({chat_id})")
        return 502, f"wake failed: {e}"
    touch(chat_id)
    return 200, "woken"


def touch(chat_id):
    with _lock:
        index = load_index()
        if chat_id in index["chats"]:
            index["chats"][chat_id]["last_active"] = time.time()
            save_index(index)


def chat_busy(chat):
    """True if any session on this chat's server is mid-work — a busy chat is
    never stopped by the idle reaper, whatever the clock says."""
    try:
        conn = http.client.HTTPConnection("127.0.0.1", chat["port"], timeout=5)
        conn.request("GET", "/session/status",
                     headers={"Authorization": basic_auth_header()})
        resp = conn.getresponse()
        body = resp.read().decode("utf-8", "replace")
        conn.close()
        if resp.status != 200:
            return True  # can't tell — err on the side of not stopping
        data = json.loads(body or "{}")
        blob = json.dumps(data).lower()
        return '"busy"' in blob or '"retry"' in blob
    except Exception:
        return True


def reaper_loop():
    while True:
        time.sleep(60)
        try:
            index = load_index()
            now = time.time()
            for cid, chat in list(index["chats"].items()):
                if container_state(cid) != "running":
                    continue
                if now - chat.get("last_active", 0) < IDLE_SECONDS:
                    continue
                if chat_busy(chat):
                    touch(cid)  # working counts as activity
                    continue
                log(f"idle spin-down: {cid}")
                engine("stop", container_name(cid), check=False, timeout=90)
        except Exception as e:
            log(f"reaper error: {e}")


def notify_failure(reason):
    """Failure alerts ride the standard channel (notify.sh -> ntfy). Component
    + failure class only — never model output (docs/automations.md)."""
    notify = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                          "common", "notify.sh")
    try:
        subprocess.run([notify, "-t", "Code agent failure", "-p", "high", reason],
                       check=False, timeout=30)
    except Exception:
        pass


# ------------------------------------------------------------------ HTTP

HOP_HEADERS = {"connection", "keep-alive", "transfer-encoding", "upgrade",
               "proxy-authenticate", "proxy-authorization", "te", "trailers",
               "host", "authorization"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "code-agent-manager"

    # ---- auth ----
    def authed(self):
        hdr = self.headers.get("Authorization", "")
        cred = ""
        if hdr.startswith("Basic "):
            cred = hdr[6:]
        else:
            q = parse_qs(urlparse(self.path).query)
            cred = (q.get("auth_token") or [""])[0]
        try:
            _, _, pw = base64.b64decode(cred).decode().partition(":")
        except Exception:
            pw = ""
        return PASSWORD and pysecrets.compare_digest(pw, PASSWORD)

    def deny(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="code-agents"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def send_json(self, code, obj):
        body = json.dumps(obj, indent=1).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    # ---- routing ----
    def handle_any(self):
        if not self.authed():
            return self.deny()
        path = urlparse(self.path).path
        m = re.match(r"^/chat/([a-zA-Z0-9-]+)(/.*|$)", path)
        if m:
            return self.proxy(m.group(1), m.group(2) or "/")
        if path == "/api/health" and self.command == "GET":
            index = load_index()
            return self.send_json(200, {
                "ok": True, "engine": ENGINE, "image": IMAGE,
                "chats": len(index["chats"]),
                "active": running_count(index), "max_active": MAX_ACTIVE,
                "idle_seconds": IDLE_SECONDS,
            })
        if path == "/api/repos" and self.command == "GET":
            return self.send_json(200, {"repos": list(load_repos().values())})
        if path == "/api/chats" and self.command == "GET":
            index = load_index()
            out = []
            for cid, chat in sorted(index["chats"].items(),
                                    key=lambda kv: -kv[1].get("last_active", 0)):
                c = dict(chat)
                c["status"] = container_state(cid)
                c["url"] = f"/chat/{cid}"
                out.append(c)
            return self.send_json(200, {"chats": out})
        if path == "/api/chats" and self.command == "POST":
            try:
                body = json.loads(self.read_body() or b"{}")
            except json.JSONDecodeError:
                return self.send_json(400, {"error": "invalid JSON body"})
            chat, err = create_chat(body)
            if err:
                return self.send_json(err[0], {"error": err[1]})
            chat = dict(chat)
            chat["status"] = "running"
            chat["url"] = f"/chat/{chat['id']}"
            return self.send_json(201, chat)
        m = re.match(r"^/api/chats/([a-zA-Z0-9-]+)/(wake|stop)$", path)
        if m and self.command == "POST":
            cid, action = m.group(1), m.group(2)
            if action == "wake":
                code, msg = wake_chat(cid)
                return self.send_json(code, {"status": msg})
            engine("stop", container_name(cid), check=False, timeout=90)
            return self.send_json(200, {"status": "stopped"})
        m = re.match(r"^/api/chats/([a-zA-Z0-9-]+)$", path)
        if m and self.command == "DELETE":
            cid = m.group(1)
            purge = "purge=1" in (urlparse(self.path).query or "")
            with _lock:
                index = load_index()
                if cid not in index["chats"]:
                    return self.send_json(404, {"error": "unknown chat"})
                index["chats"].pop(cid)
                save_index(index)
            engine("rm", "-f", container_name(cid), check=False)
            if purge:
                shutil.rmtree(os.path.join(CHATS_DIR, cid), ignore_errors=True)
            return self.send_json(200, {"status": "deleted",
                                        "volume": "purged" if purge else "kept"})
        return self.send_json(404, {"error": f"no route: {self.command} {path}"})

    # ---- reverse proxy (wake-on-request, SSE-safe) ----
    def proxy(self, chat_id, subpath):
        index = load_index()
        chat = index["chats"].get(chat_id)
        if not chat:
            return self.send_json(404, {"error": "unknown chat"})
        if container_state(chat_id) != "running":
            code, msg = wake_chat(chat_id)
            if code != 200:
                return self.send_json(code, {"error": f"wake failed: {msg}"})
        touch(chat_id)

        q = urlparse(self.path).query
        target = subpath + (f"?{q}" if q else "")
        body = self.read_body()
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in HOP_HEADERS}
        headers["Authorization"] = basic_auth_header()
        headers["Host"] = f"127.0.0.1:{chat['port']}"
        try:
            conn = http.client.HTTPConnection("127.0.0.1", chat["port"], timeout=20)
            conn.request(self.command, target, body=body or None, headers=headers)
            # Headers can be slow on blocking endpoints (a synchronous prompt
            # runs the whole agent turn before answering); the 20s above only
            # guards the connect.
            conn.sock.settimeout(600)
            resp = conn.getresponse()
        except OSError as e:
            return self.send_json(502, {"error": f"chat unreachable: {e}"})

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
        # SSE heartbeats arrive every ~10s; 60s of silence means a dead stream.
        conn.sock.settimeout(60)
        try:
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
                touch_maybe(chat_id)
        except (OSError, ssl.SSLError):
            pass
        finally:
            conn.close()

    def do_GET(self): self.handle_any()          # noqa: E704
    def do_POST(self): self.handle_any()         # noqa: E704
    def do_PUT(self): self.handle_any()          # noqa: E704
    def do_PATCH(self): self.handle_any()        # noqa: E704
    def do_DELETE(self): self.handle_any()       # noqa: E704

    def log_message(self, fmt, *args):
        # journald gets one concise line; never log query strings (auth_token).
        log(f"{self.command} {urlparse(self.path).path}")


_last_touch = {}


def touch_maybe(chat_id, min_interval=30):
    """Rate-limited activity marker for long streams."""
    now = time.time()
    if now - _last_touch.get(chat_id, 0) > min_interval:
        _last_touch[chat_id] = now
        touch(chat_id)


# ------------------------------------------------------------------- main

def tailnet_ip():
    try:
        out = subprocess.run(["tailscale", "ip", "-4"], check=True,
                             stdout=subprocess.PIPE, text=True, timeout=10)
        return out.stdout.strip().splitlines()[0]
    except Exception:
        return ""


def main():
    if not PASSWORD:
        log("FATAL: OPENCODE_SERVER_PASSWORD is empty — refusing to serve "
            "an unauthenticated code plane. Set it in /data/secrets.env.")
        sys.exit(1)
    if not GH_PAT:
        log("WARNING: GITHUB_CODE_AGENT_PAT is empty — private clones and "
            "agent-side push/PR will fail until it is set.")
    os.makedirs(CHATS_DIR, exist_ok=True)
    if not os.path.exists(REPOS_PATH):
        log(f"WARNING: {REPOS_PATH} missing — the allowlist is empty; copy "
            "config/code-agents/repos.example.json there and edit it.")

    host = tailnet_ip()
    have_tls = os.path.exists(TLS_CERT) and os.path.exists(TLS_KEY)
    if not host:
        # Tailnet-only rule (docs/security.md): the socket must exist on the
        # tailnet interface or not at all. Exit nonzero; the unit's
        # Restart=always retries every 5s until tailscaled has an IPv4 —
        # the same wait-for-the-tailnet pattern goose-serve.service uses.
        log("no Tailscale IPv4 yet — exiting for systemd to retry")
        sys.exit(1)
    if not have_tls:
        log("WARNING: no TLS cert at /data/tls — serving PLAIN HTTP. Run "
            "scripts/vps/renew-tls-cert.sh (docs/setup/50-vps-brain.md).")

    server = ThreadingHTTPServer((host, GATEWAY_PORT), Handler)
    server.daemon_threads = True
    if have_tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(TLS_CERT, TLS_KEY)
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=reaper_loop, daemon=True).start()
    log(f"listening on {host}:{GATEWAY_PORT} "
        f"(tls={'yes' if have_tls else 'NO'}, engine={ENGINE}, image={IMAGE}, "
        f"idle={IDLE_SECONDS}s, max_active={MAX_ACTIVE})")
    server.serve_forever()


if __name__ == "__main__":
    main()
