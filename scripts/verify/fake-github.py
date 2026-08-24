#!/usr/bin/env python3
"""fake-github — the slice of GitHub's REST API the session manager calls.

The manager's GitHub integration had no test, because testing it meant either
talking to real GitHub with a real token or not testing it at all. Pointing
`GITHUB_API_BASE` at this instead exercises the real request building and the
real error mapping against answers we control:

    GITHUB_API_BASE=http://127.0.0.1:4398 python3 scripts/vps/code-agent-manager.py

Implements, for owner/repo `testowner/testrepo`:
    GET /repos/:owner/:repo/pulls?head=&state=      list (no `mergeable`,
                                                    exactly like the real one)
    GET /repos/:owner/:repo/pulls/:n                detail (with `mergeable`)
    PUT /repos/:owner/:repo/pulls/:n/merge          merge
    GET /repos/:owner/:repo/commits/:sha/check-runs
    GET /repos/:owner/:repo/commits/:sha/status

The fixture set is chosen to cover what a client has to render and what a
manager has to refuse, not to look like one repo's real pull requests:

    #12  open,   mergeable,      checks passing   -> the mergeable row
    #11  open,   mergeable,      checks failing   -> merge must be refused
    #10  open,   mergeable null, checks pending   -> "not worked out yet"
     #9  open,   DRAFT                            -> refused as a draft
     #8  merged                                   -> already merged
     #7  open on ANOTHER branch                   -> must never be listed,
                                                     and merging it must 404

Set FAKE_GITHUB_MODE to make it misbehave on purpose:
    down    every call fails at the socket    -> manager should say 502
    denied  every call answers 403            -> "PAT may have expired"
    noscope check endpoints alone answer 403  -> checks degrade to "unknown"
    blocked the merge answers 405             -> normalised to 422, message
                                                 carried through
"""

from __future__ import annotations

import argparse
import json
import os
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse

Wire = dict[str, Any]

BRANCH = os.environ.get("FAKE_GITHUB_BRANCH", "agent/testrepo-fixture")
MODE = os.environ.get("FAKE_GITHUB_MODE", "")

STATE_LOCK = threading.Lock()


def _pull(number: int, title: str, **over: object) -> Wire:
    """One pull request, with the fixture's defaults overridden by keyword."""
    merged = bool(over.get("merged"))
    return {
        "number": number,
        "title": title,
        "state": over.get("state", "open"),
        "draft": bool(over.get("draft")),
        "merged_at": "2026-08-20T10:00:00Z" if merged else None,
        "mergeable": over.get("mergeable", True),
        "html_url": f"https://github.com/testowner/testrepo/pull/{number}",
        "head": {"ref": over.get("head", BRANCH), "sha": over.get("sha", f"sha{number}")},
        "base": {"ref": "main"},
        "created_at": "2026-08-19T09:00:00Z",
        "updated_at": "2026-08-20T09:30:00Z",
    }


PULLS: dict[int, Wire] = {
    12: _pull(12, "Tighten the README quickstart"),
    11: _pull(11, "Rework the retry loop"),
    10: _pull(10, "Add a smoke test", mergeable=None),
    9: _pull(9, "WIP: spike the parser", draft=True),
    8: _pull(8, "Bump the toolchain", state="closed", merged=True),
    7: _pull(7, "Someone else's work", head="feature/unrelated"),
}

# sha -> (check-run conclusions, combined status state)
CHECKS: dict[str, tuple[list[str], str]] = {
    "sha12": (["success", "skipped"], "success"),
    "sha11": (["success", "failure"], "failure"),
    "sha10": (["in_progress"], "pending"),
    "sha9": ([], "pending"),
    "sha8": (["success"], "success"),
    "sha7": (["success"], "success"),
}


class Handler(BaseHTTPRequestHandler):
    PULLS_LIST = re.compile(r"^/repos/([^/]+)/([^/]+)/pulls$")
    PULL_ONE = re.compile(r"^/repos/([^/]+)/([^/]+)/pulls/([0-9]+)$")
    PULL_MERGE = re.compile(r"^/repos/([^/]+)/([^/]+)/pulls/([0-9]+)/merge$")
    CHECK_RUNS = re.compile(r"^/repos/([^/]+)/([^/]+)/commits/([^/]+)/check-runs$")
    COMMIT_STATUS = re.compile(r"^/repos/([^/]+)/([^/]+)/commits/([^/]+)/status$")

    def send(self, code: int, obj: object) -> None:
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:
        self.route()

    def do_PUT(self) -> None:
        self.route()

    def route(self) -> None:
        if MODE == "denied":
            self.send(403, {"message": "Resource not accessible by personal access token"})
            return
        parsed = urlparse(self.path)
        path = parsed.path
        if m := self.PULLS_LIST.match(path):
            self.route_list(parse_qs(parsed.query))
        elif m := self.PULL_ONE.match(path):
            self.route_one(int(m.group(3)))
        elif m := self.PULL_MERGE.match(path):
            self.route_merge(int(m.group(3)))
        elif m := self.CHECK_RUNS.match(path):
            self.route_check_runs(m.group(3))
        elif m := self.COMMIT_STATUS.match(path):
            self.route_status(m.group(3))
        else:
            self.send(404, {"message": "Not Found"})

    def route_list(self, query: dict[str, list[str]]) -> None:
        want = (query.get("head") or [""])[0]
        branch = want.split(":", 1)[1] if ":" in want else want
        states = (query.get("state") or ["open"])[0]
        rows = []
        for number in sorted(PULLS, reverse=True):
            pull = PULLS[number]
            if branch and pull["head"]["ref"] != branch:
                continue
            if states != "all" and pull["state"] != states:
                continue
            # The real list endpoint does NOT carry `mergeable`. A manager
            # that skips the per-PR detail call gets nulls, and no Merge
            # button ever appears — which is the whole point of testing here.
            rows.append({k: v for k, v in pull.items() if k != "mergeable"})
        self.send(200, rows)

    def route_one(self, number: int) -> None:
        pull = PULLS.get(number)
        if pull is None:
            self.send(404, {"message": "Not Found"})
            return
        self.send(200, pull)

    def route_merge(self, number: int) -> None:
        pull = PULLS.get(number)
        if pull is None:
            self.send(404, {"message": "Not Found"})
            return
        if MODE == "blocked":
            self.send(405, {"message": "At least 1 approving review is required."})
            return
        with STATE_LOCK:
            pull["state"] = "closed"
            pull["merged_at"] = "2026-08-24T11:00:00Z"
        self.send(200, {"merged": True, "sha": f"merged{number}", "message": "Pull Request merged"})

    def route_check_runs(self, sha: str) -> None:
        if MODE == "noscope":
            self.send(403, {"message": "Resource not accessible by personal access token"})
            return
        runs, _ = CHECKS.get(sha, ([], ""))
        self.send(200, {"check_runs": [{"conclusion": c, "status": "completed"} for c in runs]})

    def route_status(self, sha: str) -> None:
        if MODE == "noscope":
            self.send(403, {"message": "Resource not accessible by personal access token"})
            return
        _, state = CHECKS.get(sha, ([], "pending"))
        self.send(200, {"state": state, "statuses": [{"state": state}] if state else []})

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        pass  # quiet; the harness asserts on behaviour, not logs


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=4398)
    args = ap.parse_args()
    if MODE == "down":
        # Bind nothing: the manager's connect fails, which is what "GitHub is
        # unreachable" is supposed to mean.
        threading.Event().wait()
        return
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
