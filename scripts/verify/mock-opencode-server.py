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
"""

import argparse
import base64
import json
import os
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ARGS = None
STATE_LOCK = threading.Lock()
SUBSCRIBERS = []  # list[queue-like lists] guarded by SUB_LOCK
SUB_LOCK = threading.Lock()
PENDING = {}  # permission id -> {"perm": {...}, "event": threading.Event, "response": str}
BUSY = set()  # session ids with a turn in flight


def state_path():
    d = os.path.join(ARGS.dir, "home")
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, "mock-opencode-state.json")


def load_state():
    try:
        with open(state_path(), "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {"sessions": [], "messages": {}}


def save_state(state):
    tmp = state_path() + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=1)
    os.replace(tmp, state_path())


def publish(event_type, properties):
    evt = {"type": event_type, "properties": properties}
    with SUB_LOCK:
        for q in SUBSCRIBERS:
            q.append(evt)


# ------------------------------------------------------------- the turn

def run_turn(session_id, prompt):
    BUSY.add(session_id)
    try:
        with STATE_LOCK:
            state = load_state()
            msgs = state["messages"].setdefault(session_id, [])
            user_msg_id = f"msg_{secrets.token_hex(4)}"
            user_part = {
                "id": f"prt_{secrets.token_hex(4)}", "messageID": user_msg_id,
                "sessionID": session_id, "type": "text", "text": prompt,
            }
            msgs.append({"info": {"id": user_msg_id, "role": "user",
                                  "sessionID": session_id},
                         "parts": [user_part]})
            save_state(state)
        publish("message.updated",
                {"info": {"id": user_msg_id, "role": "user", "sessionID": session_id}})
        publish("message.part.updated", {"part": user_part})

        asst_msg_id = f"msg_{secrets.token_hex(4)}"
        publish("message.updated",
                {"info": {"id": asst_msg_id, "role": "assistant", "sessionID": session_id}})

        # Streamed assistant text, in deltas like the real server.
        text_part_id = f"prt_{secrets.token_hex(4)}"
        chunks = ["Working on it", " — checking the workspace", " now."]
        acc = ""
        for c in chunks:
            acc += c
            publish("message.part.updated", {
                "part": {"id": text_part_id, "messageID": asst_msg_id,
                         "sessionID": session_id, "type": "text", "text": acc},
                "delta": c,
            })
            time.sleep(0.15)
        parts = [{"id": text_part_id, "messageID": asst_msg_id,
                  "sessionID": session_id, "type": "text", "text": acc}]

        # A push-flavored prompt exercises the blocking permission flow.
        rejected = False
        if "push" in prompt.lower():
            tool_part = {
                "id": f"prt_{secrets.token_hex(4)}", "messageID": asst_msg_id,
                "sessionID": session_id, "type": "tool", "tool": "bash",
                "callID": f"call_{secrets.token_hex(3)}",
                "state": {"status": "running", "title": "git push origin HEAD",
                          "input": {"command": "git push origin HEAD"}},
            }
            publish("message.part.updated", {"part": tool_part})
            perm_id = f"perm_{secrets.token_hex(4)}"
            perm = {"id": perm_id, "sessionID": session_id, "type": "bash",
                    "title": "Run: git push origin HEAD",
                    "metadata": {"command": "git push origin HEAD"}}
            entry = {"perm": perm, "event": threading.Event(), "response": ""}
            PENDING[perm_id] = entry
            publish("permission.updated", perm)
            # Block until the client answers — the real semantics.
            entry["event"].wait(timeout=120)
            PENDING.pop(perm_id, None)
            publish("permission.replied", {"permissionID": perm_id,
                                           "response": entry["response"] or "timeout"})
            rejected = entry["response"] not in ("once", "always")
            tool_part["state"] = {
                "status": "error" if rejected else "completed",
                "title": "git push origin HEAD",
                "output": "push rejected by user" if rejected
                          else "To github.com: agent/branch pushed",
            }
            publish("message.part.updated", {"part": tool_part})
            parts.append(tool_part)

        final_id = f"prt_{secrets.token_hex(4)}"
        wants_pr = "pull request" in prompt.lower() or " pr" in f" {prompt.lower()}"
        final_text = (
            "Push was rejected, so I stopped there." if rejected
            else "Opened the pull request: https://github.com/example/repo/pull/7"
            if wants_pr
            else "Done. The change is committed on the session branch."
        )
        publish("message.part.updated", {
            "part": {"id": final_id, "messageID": asst_msg_id,
                     "sessionID": session_id, "type": "text", "text": final_text},
        })
        parts.append({"id": final_id, "messageID": asst_msg_id,
                      "sessionID": session_id, "type": "text", "text": final_text})

        with STATE_LOCK:
            state = load_state()
            state["messages"].setdefault(session_id, []).append(
                {"info": {"id": asst_msg_id, "role": "assistant",
                          "sessionID": session_id},
                 "parts": parts})
            save_state(state)
    finally:
        BUSY.discard(session_id)
        publish("session.idle", {"sessionID": session_id})


# ------------------------------------------------------------------ HTTP

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def authed(self):
        hdr = self.headers.get("Authorization", "")
        cred = hdr[6:] if hdr.startswith("Basic ") else ""
        if not cred:
            q = parse_qs(urlparse(self.path).query)
            cred = (q.get("auth_token") or [""])[0]
        try:
            _, _, pw = base64.b64decode(cred).decode().partition(":")
        except Exception:
            pw = ""
        return secrets.compare_digest(pw, ARGS.password)

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def read_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            return {}

    def handle_any(self):
        if not self.authed():
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="mock"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        path = urlparse(self.path).path
        parts = [p for p in path.split("/") if p]

        if path == "/event" and self.command == "GET":
            return self.stream_events()
        if path == "/session" and self.command == "GET":
            with STATE_LOCK:
                return self.send_json(200, load_state()["sessions"])
        if path == "/session" and self.command == "POST":
            q = parse_qs(urlparse(self.path).query)
            directory = (q.get("directory") or ["/chat/workspace"])[0]
            sess = {"id": f"ses_{secrets.token_hex(5)}", "title": "mock session",
                    "directory": directory}
            with STATE_LOCK:
                state = load_state()
                state["sessions"].append(sess)
                save_state(state)
            return self.send_json(200, sess)
        if path == "/session/status" and self.command == "GET":
            return self.send_json(
                200, {sid: {"type": "busy"} for sid in sorted(BUSY)})
        if path == "/permission" and self.command == "GET":
            return self.send_json(200, [e["perm"] for e in PENDING.values()])

        if len(parts) >= 3 and parts[0] == "session":
            sid = parts[1]
            if parts[2] == "message" and self.command == "GET":
                with STATE_LOCK:
                    return self.send_json(
                        200, load_state()["messages"].get(sid, []))
            if parts[2] == "prompt_async" and self.command == "POST":
                body = self.read_json()
                text = "".join(
                    p.get("text", "") for p in body.get("parts", [])
                    if p.get("type") == "text")
                threading.Thread(target=run_turn, args=(sid, text),
                                 daemon=True).start()
                self.send_response(204)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if parts[2] == "abort" and self.command == "POST":
                # Resolve any blocked permission so the turn thread finishes.
                for e in list(PENDING.values()):
                    if e["perm"]["sessionID"] == sid:
                        e["response"] = "reject"
                        e["event"].set()
                BUSY.discard(sid)
                publish("session.idle", {"sessionID": sid})
                return self.send_json(200, True)
            if parts[2] == "diff" and self.command == "GET":
                return self.send_json(200, [{
                    "path": "README.md", "additions": 3, "deletions": 1,
                    "patch": "--- a/README.md\n+++ b/README.md\n@@ -1 +1,3 @@\n-old\n+new line one\n+new line two\n+new line three\n",
                }])
            if parts[2] == "permissions" and len(parts) == 4 and self.command == "POST":
                pid = parts[3]
                entry = PENDING.get(pid)
                if not entry:
                    return self.send_json(404, {"error": "unknown permission"})
                entry["response"] = self.read_json().get("response", "reject")
                entry["event"].set()
                return self.send_json(200, True)

        return self.send_json(404, {"error": f"mock: no route {self.command} {path}"})

    def stream_events(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.close_connection = True
        self.end_headers()
        queue = []
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

    def write_event(self, evt):
        data = json.dumps(evt)
        self.wfile.write(f"data: {data}\n\n".encode())
        self.wfile.flush()

    def do_GET(self):
        self.handle_any()

    def do_POST(self):
        self.handle_any()

    def log_message(self, fmt, *args):
        pass  # quiet; the harness asserts on behavior, not logs


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--dir", required=True, help="the chat volume dir")
    ap.add_argument("--password", default=os.environ.get("OPENCODE_SERVER_PASSWORD", "mock"))
    ARGS = ap.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler)
    server.daemon_threads = True
    print(f"mock-opencode-server: 127.0.0.1:{ARGS.port} dir={ARGS.dir}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
