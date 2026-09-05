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
    GET /repos/:owner/:repo                         default_branch, and
                                                    nothing else a client reads
    GET /repos/:owner/:repo/branches?per_page=&page=  the base-branch picker's
                                                    list, really paginated
    GET /repos/:owner/:repo/branches/:name          "does this ref exist"

The branch fixture is 119 names ON PURPOSE: GitHub caps `per_page` at 100, so
a client that does not paginate silently loses the tail — `zzz-last-branch`
exists only on page 2 and is what catches that. FAKE_GITHUB_BRANCHES_FILE
replaces the built-in list with a newline-delimited file, which is how the
harness keeps this fixture and the repo it actually clones from disagreeing.

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
    down      every call fails at the socket    -> manager should say 502
    denied    every call answers 403            -> "PAT may have expired"
    noscope   check endpoints alone answer 403  -> checks degrade to "unknown"
    blocked   the merge answers 405             -> normalised to 422, message
                                                   carried through
    nodefault GET /repos/:o/:r alone answers 403 -> the branch list survives,
                                                   the default label does not
    serverfail every call answers 500            -> gh() maps 5xx to 502
    notjson   a 200 whose body is not JSON       -> gh() maps the parse error
                                                   to 502, not a crash
    nomessage the merge answers 422 with {}      -> gh() falls back to
                                                   "GitHub answered 422"
    nochecks  no check runs and no statuses      -> summarise_checks -> "none"
    pendingonly combined state pending, nothing  -> summarise_checks ->
              behind it                             "pending"
    detailbad GET /pulls/:n answers a LIST        -> merge refuses with 502
                                                   rather than crashing
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse

Wire = dict[str, Any]

BRANCH = os.environ.get("FAKE_GITHUB_BRANCH", "agent/testrepo-fixture")
DEFAULT_BRANCH = os.environ.get("FAKE_GITHUB_DEFAULT_BRANCH", "main")
BRANCHES_FILE = os.environ.get("FAKE_GITHUB_BRANCHES_FILE", "")
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
    # Closed WITHOUT being merged, and open-but-conflicting: the two merge
    # refusals with no fixture. #8 is closed AND merged, and merge_chat_pull
    # tests merged_at first, so #8 can only ever reach the "already merged"
    # arm -- the "is closed" arm needs a pull that was closed unmerged.
    6: _pull(6, "Abandoned approach", state="closed"),
    5: _pull(5, "Conflicts with main", mergeable=False),
}

# sha -> (check-run conclusions, combined status state)
CHECKS: dict[str, tuple[list[str], str]] = {
    "sha12": (["success", "skipped"], "success"),
    "sha11": (["success", "failure"], "failure"),
    "sha10": (["in_progress"], "pending"),
    "sha9": ([], "pending"),
    "sha8": (["success"], "success"),
    "sha7": (["success"], "success"),
    "sha6": (["success"], "success"),
    "sha5": (["success"], "success"),
}

# Branch fixtures. Stand-alone default: enough shapes to render (a default, a
# slashed-and-dotted release line, the branch the pull-request fixtures live
# on). The harness replaces these via FAKE_GITHUB_BRANCHES_FILE with the
# branches its seed repo really has, so "GitHub says yes" and "the clone works"
# cannot disagree. The order is NOT sorted, and the harness's file is
# reverse-sorted, on purpose: a fixture that arrives sorted cannot prove the
# manager sorts it.
DEFAULT_BRANCHES: list[str] = [
    "release/2.x",
    "claude/budget-note-fix",
    DEFAULT_BRANCH,
    BRANCH,
    "zzz-last-branch",
]


def _branches() -> list[str]:
    if not BRANCHES_FILE:
        return DEFAULT_BRANCHES
    raw = pathlib.Path(BRANCHES_FILE).read_text(encoding="utf-8")
    return [line.strip() for line in raw.splitlines() if line.strip()]


BRANCHES: list[str] = _branches()


def _int(raw: str, fallback: int) -> int:
    """Read a query parameter as an int, without a traceback for a bad one.

    A 500 out of here would be read as a manager bug by the harness, which is
    exactly the wrong place to look.
    """
    try:
        return int(raw)
    except ValueError:
        return fallback


class Handler(BaseHTTPRequestHandler):
    PULLS_LIST = re.compile(r"^/repos/([^/]+)/([^/]+)/pulls$")
    PULL_ONE = re.compile(r"^/repos/([^/]+)/([^/]+)/pulls/([0-9]+)$")
    PULL_MERGE = re.compile(r"^/repos/([^/]+)/([^/]+)/pulls/([0-9]+)/merge$")
    CHECK_RUNS = re.compile(r"^/repos/([^/]+)/([^/]+)/commits/([^/]+)/check-runs$")
    COMMIT_STATUS = re.compile(r"^/repos/([^/]+)/([^/]+)/commits/([^/]+)/status$")
    BRANCH_LIST = re.compile(r"^/repos/([^/]+)/([^/]+)/branches$")
    BRANCH_ONE = re.compile(r"^/repos/([^/]+)/([^/]+)/branches/(.+)$")
    # Two segments only, so it can never shadow any of the routes above.
    REPO_ONE = re.compile(r"^/repos/([^/]+)/([^/]+)$")

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

    def send_raw(self, code: int, raw: bytes) -> None:
        """Answer with a body that is NOT json — the one shape send() cannot make."""
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def whole_request_mode(self) -> bool:
        """Answer the modes that apply to EVERY route; True if answered.

        Split from route() to keep one dispatcher readable as a dispatcher:
        these arms care only about the mode, never about the path.
        """
        if MODE == "denied":
            self.send(403, {"message": "Resource not accessible by personal access token"})
        elif MODE == "serverfail":
            self.send(500, {"message": "Server Error"})
        elif MODE == "notjson":
            self.send_raw(200, b"<html>502 Bad Gateway</html>")
        else:
            return False
        return True

    def route(self) -> None:
        if self.whole_request_mode():
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
        elif self.BRANCH_LIST.match(path):
            self.route_branch_list(parse_qs(parsed.query))
        elif m := self.BRANCH_ONE.match(path):
            self.route_branch_one(m.group(3))
        elif self.REPO_ONE.match(path):
            self.route_repo()
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
        if MODE == "detailbad":
            # GitHub answering a LIST where the manager expects an object.
            self.send(200, [{"number": number}])
            return
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
        if MODE == "nomessage":
            # A 4xx with no "message" key. gh() has a fallback sentence for
            # exactly this and nothing has ever produced it.
            self.send(422, {})
            return
        if MODE == "blocked":
            self.send(405, {"message": "At least 1 approving review is required."})
            return
        with STATE_LOCK:
            pull["state"] = "closed"
            pull["merged_at"] = "2026-08-24T11:00:00Z"
        self.send(200, {"merged": True, "sha": f"merged{number}", "message": "Pull Request merged"})

    def route_check_runs(self, sha: str) -> None:
        if MODE in ("nochecks", "pendingonly"):
            self.send(200, {"check_runs": []})
            return
        if MODE == "noscope":
            self.send(403, {"message": "Resource not accessible by personal access token"})
            return
        runs, _ = CHECKS.get(sha, ([], ""))
        self.send(200, {"check_runs": [{"conclusion": c, "status": "completed"} for c in runs]})

    def route_status(self, sha: str) -> None:
        if MODE == "nochecks":
            # Nothing has reported at all: no runs, no statuses, no state.
            self.send(200, {"state": "", "statuses": []})
            return
        if MODE == "pendingonly":
            # GitHub's way of saying nothing has reported yet -- which the
            # manager must not confuse with "something is running".
            self.send(200, {"state": "pending", "statuses": []})
            return
        if MODE == "noscope":
            self.send(403, {"message": "Resource not accessible by personal access token"})
            return
        _, state = CHECKS.get(sha, ([], "pending"))
        self.send(200, {"state": state, "statuses": [{"state": state}] if state else []})

    def route_branch_list(self, query: dict[str, list[str]]) -> None:
        # Real per_page/page honouring, capped at 100 exactly as GitHub caps
        # it — that cap is the whole reason a client has to paginate.
        per_page = min(_int((query.get("per_page") or ["30"])[0], 30), 100)
        page = max(_int((query.get("page") or ["1"])[0], 1), 1)
        start = (page - 1) * per_page
        self.send(
            200,
            [
                {"name": n, "commit": {"sha": f"sha-{n}"}, "protected": n == DEFAULT_BRANCH}
                for n in BRANCHES[start : start + per_page]
            ],
        )

    def route_branch_one(self, name: str) -> None:
        if name not in BRANCHES:
            self.send(404, {"message": "Branch not found"})
            return
        self.send(200, {"name": name, "commit": {"sha": f"sha-{name}"}})

    def route_repo(self) -> None:
        if MODE == "nodefault":
            # The one call whose whole answer is a label. The list must
            # survive losing it.
            self.send(403, {"message": "Resource not accessible by personal access token"})
            return
        self.send(
            200,
            {
                "full_name": "testowner/testrepo",
                "default_branch": DEFAULT_BRANCH,
                "private": True,
            },
        )

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
