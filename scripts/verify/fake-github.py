#!/usr/bin/env python3
"""fake-github — the slice of GitHub's REST API the session manager calls.

The manager's GitHub integration had no test, because testing it meant either
talking to real GitHub with a real token or not testing it at all. Pointing
`GITHUB_API_BASE` at this instead exercises the real request building and the
real error mapping against answers we control:

    GITHUB_API_BASE=http://127.0.0.1:4398 python3 scripts/vps/code-agent-manager.py

Implements, for owner/repo `testowner/testrepo`:
    GET /repos/:owner/:repo/pulls?head=&state=      list (no `mergeable` and
                                                    no size counts, exactly
                                                    like the real one)
    GET /repos/:owner/:repo/pulls/:n                detail (with `mergeable`,
                                                    commits, additions,
                                                    deletions, changed_files)
    PUT /repos/:owner/:repo/pulls/:n/merge          merge
    GET /repos/:owner/:repo/commits/:sha/check-runs
    GET /repos/:owner/:repo/commits/:sha/status
    GET /repos/:owner/:repo                         default_branch, and
                                                    nothing else a client reads
    GET /repos/:owner/:repo/branches?per_page=&page=  the base-branch picker's
                                                    list, really paginated
    GET /repos/:owner/:repo/branches/:name          "does this ref exist"
    GET /repos/:owner/:repo/compare/:base...:head   the per-tree change stat.
                                                    Keyed on the HEAD ref: the
                                                    fixture branch is `ahead`
                                                    with three files, the
                                                    default branch is
                                                    `identical` with none, and
                                                    anything else 404s — which
                                                    is the "never pushed" arm
                                                    every other chat gets free.
                                                    `total_commits` is 99 while
                                                    `ahead_by` is 3 ON PURPOSE:
                                                    a manager that reports the
                                                    wrong one is caught.
    GET /__calls                                    how many requests this fake
                                                    has served. Answered BEFORE
                                                    any failure mode, so it
                                                    stays readable under
                                                    `denied`/`serverfail`; it
                                                    backs "a cached route costs
                                                    the same calls whether it is
                                                    read 10 times or 30".
                                                    Unreadable under `down`,
                                                    which binds no socket.

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

Every fixture also carries the four size counts, distinct per pull so a
client that crosses two of them cannot pass. #12's `deletions` is 0 ON
PURPOSE: a real zero has to survive the trip intact, which is the other half
of "a pull with no detail sends no counts at all".

Set FAKE_GITHUB_MODE to make it misbehave on purpose:
    down      every call fails at the socket    -> manager should say 502
    denied    every call answers 403            -> "PAT may have expired"
    noscope   check endpoints alone answer 403  -> checks degrade to "unknown"
    nodetail  GET /pulls/:n alone answers 500   -> the list survives on the
                                                   list entries, and every
                                                   detail-only field is
                                                   ABSENT, never zero
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
    nocompare the compare alone answers 404       -> the tree loses its `stat`
                                                   and keeps its pull requests

FAKE_GITHUB_INVISIBLE_REPOS is a SEAM, not a mode: a comma-separated list of
`owner/repo` slugs this PAT cannot see. Every route under `/repos/:owner/:repo`
answers 404 carrying GitHub's own body, `{"message": "Not Found"}`, while every
other slug — `testowner/testrepo` included — is served normally in the SAME run.
Three properties are load bearing and none of them are cosmetic:

    404, NOT 403.   Real GitHub will not confirm to an unscoped token that a
                    private repo exists, so it answers 404. And gh() maps
                    401/403 onto "the PAT may have expired" — the wrong
                    sentence for "your token cannot see that repo", which a
                    route built against a 403 fixture would then ship. The
                    `nodefault` mode above IS the 403 shape and is deliberately
                    not this one.
    PER REPO.       `denied` above is a whole-request 403: arming it to refuse
                    one repo takes the branch sweep and every other
                    GitHub-touching route down with it, so it can never show
                    one route refusing while the rest of the stack runs.
    ABSENT, not unverifiable. A 404 is an ANSWER. A caller shaped like the
                    manager's validate_base has to read it as "no such base"
                    (a 400 the picker can print) and a 5xx as "could not
                    check" (a 502) — two different claims that must not
                    collapse into one.

Applied AFTER the whole-request modes and after GET /__calls, so a counter read
stays readable while it is armed.
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
from urllib.parse import ParseResult, parse_qs, urlparse

Wire = dict[str, Any]

BRANCH = os.environ.get("FAKE_GITHUB_BRANCH", "agent/testrepo-fixture")
DEFAULT_BRANCH = os.environ.get("FAKE_GITHUB_DEFAULT_BRANCH", "main")
BRANCHES_FILE = os.environ.get("FAKE_GITHUB_BRANCHES_FILE", "")
MODE = os.environ.get("FAKE_GITHUB_MODE", "")

STATE_LOCK = threading.Lock()
# Every request this fake has seen, readable at GET /__calls. It exists so a
# test can assert a manager-side CACHE is a cache: N reads of a cached route
# must cost the same GitHub calls as M reads, for any N and M.
CALLS = 0


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
        # Detail-form only, like `mergeable` — route_list strips all five.
        # Derived from the number so no two fixtures share a value and no two
        # fields within one fixture do either.
        "commits": over.get("commits", number % 4 + 1),
        "additions": over.get("additions", number * 7),
        "deletions": over.get("deletions", number * 3),
        "changed_files": over.get("changed_files", number % 5 + 2),
    }


# GitHub's list form carries none of these; only the per-pull detail does. A
# manager that skips the detail call must therefore be able to tell.
DETAIL_ONLY = ("mergeable", "commits", "additions", "deletions", "changed_files")

PULLS: dict[int, Wire] = {
    12: _pull(12, "Tighten the README quickstart", deletions=0),
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


def _invisible_repos() -> frozenset[str]:
    """Read the env seam's `owner/repo` slugs — the ones this PAT cannot see.

    Read the same way BRANCHES_FILE is: once, at import, so the fixture a run
    is serving cannot change under an assertion halfway through it.
    """
    raw = os.environ.get("FAKE_GITHUB_INVISIBLE_REPOS", "")
    return frozenset(slug.strip() for slug in raw.split(",") if slug.strip())


INVISIBLE_REPOS: frozenset[str] = _invisible_repos()


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
    # `(.+)$`, NOT segment-anchored, matching BRANCH_ONE's precedent above and
    # mandatory here: every branch this system makes is `agent/<chat id>` and a
    # base can be `release/2.x`. A `[^/]+` route would 404 every fixture, the
    # manager would read that as the legitimate "never pushed" arm, and the
    # whole stat matrix would go green having tested nothing.
    COMPARE = re.compile(r"^/repos/([^/]+)/([^/]+)/compare/(.+)$")
    # EVERY route under a repo, not only the two-segment one. A validator
    # refused on `GET /repos/:o/:r` must be refused on the branch check it
    # would have made next, or the fixture is not the refusal GitHub gives and
    # the caller under test never reaches its own second call.
    REPO_SCOPED = re.compile(r"^/repos/([^/]+)/([^/]+)(?:/.*)?$")

    def send(self, code: int, obj: object) -> None:
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:
        if self.counter_route():
            return
        self.route()

    def do_PUT(self) -> None:
        self.count_request()
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

    def invisible_repo(self, path: str) -> bool:
        """404 a repo FAKE_GITHUB_INVISIBLE_REPOS names; True when it answered.

        Keyed on the owner/repo the path carries, which is why it can be true
        of one repo and false of the next in the same run — unlike
        whole_request_mode() above, which cares only about the mode. This is
        the only arm in the file that reads the two captures the routes have
        always thrown away.
        """
        m = self.REPO_SCOPED.match(path)
        if m is None or f"{m.group(1)}/{m.group(2)}" not in INVISIBLE_REPOS:
            return False
        # GitHub's own body, not a bare 404: a caller's error mapping has to be
        # tested against the shape it will really meet, and an empty body would
        # let one that reads `message` pass for the wrong reason.
        self.send(404, {"message": "Not Found"})
        return True

    def count_request(self) -> int:
        """Count one request and return the running total."""
        with STATE_LOCK:
            global CALLS  # noqa: PLW0603 -- a counter is exactly what this is
            CALLS += 1
            return CALLS

    def counter_route(self) -> bool:
        """Count this request; answer GET /__calls. True when it answered.

        Called from do_GET BEFORE route(), so it lands ahead of
        whole_request_mode(): under `denied`/`serverfail`/`notjson` that helper
        answers everything, and a counter read would come back as a 403 body --
        the assertion built on it would then be measuring the failure mode
        rather than the call count. (Unreadable under `down`, which binds no
        socket at all.)
        """
        seen = self.count_request()
        if urlparse(self.path).path == "/__calls":
            self.send(200, {"calls": seen})
            return True
        return False

    def route(self) -> None:
        """Pull-scoped routes; repo-scoped ones are delegated.

        Split in two along that seam rather than grown into one chain, because
        a single dispatcher for all nine routes trips ruff's complexity limit —
        and the limit is right that a ten-branch chain is where a route gets
        added in the wrong place.
        """
        if self.whole_request_mode():
            return
        parsed = urlparse(self.path)
        path = parsed.path
        # Ahead of every repo route and behind counter_route(), so an invisible
        # repo cannot be reached by any verb and GET /__calls still answers.
        if self.invisible_repo(path):
            return
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
        elif not self.route_repo_scoped(path, parsed):
            self.send(404, {"message": "Not Found"})

    def route_repo_scoped(self, path: str, parsed: ParseResult) -> bool:
        """Branches, compare and the repo itself. True when it answered."""
        if self.BRANCH_LIST.match(path):
            self.route_branch_list(parse_qs(parsed.query))
        elif m := self.BRANCH_ONE.match(path):
            self.route_branch_one(m.group(3))
        elif m := self.COMPARE.match(path):
            self.route_compare(m.group(3))
        elif self.REPO_ONE.match(path):
            self.route_repo()
        else:
            return False
        return True

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
            # The real list endpoint does NOT carry `mergeable` or the size
            # counts. A manager that skips the per-PR detail call gets nulls
            # and no numbers, and no Merge button ever appears — which is the
            # whole point of testing here.
            rows.append({k: v for k, v in pull.items() if k not in DETAIL_ONLY})
        self.send(200, rows)

    def route_one(self, number: int) -> None:
        if MODE == "detailbad":
            # GitHub answering a LIST where the manager expects an object.
            self.send(200, [{"number": number}])
            return
        if MODE == "nodetail":
            # Only this endpoint fails, so the list route still answers and
            # the manager's per-pull fallback is the thing under test.
            self.send(500, {"message": "Server Error"})
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

    def route_compare(self, refs: str) -> None:
        """`base...head` — the change stat the manager caches per tree.

        Keyed on the HEAD ref only. Split on the LAST `...` because a ref may
        legitimately contain dots (`release/2.x`).

        Deliberately no truncated-diff fixture: 300 files is covered in-process,
        and a mode only one assertion reaches is a mode that rots.
        """
        if MODE == "nocompare":
            # Compare alone fails, so the pull list still answers. This is what
            # proves a lost stat does not cost the row its pull requests.
            self.send(404, {"message": "Not Found"})
            return
        head = refs.rsplit("...", 1)[-1]
        if head == BRANCH:
            # Distinct per file, so a client that sums them wrong cannot pass.
            self.send(200, {
                "status": "ahead",
                "ahead_by": 3,
                "behind_by": 0,
                # Deliberately DIFFERENT from ahead_by: the manager must report
                # ahead_by as `commits`, and an equal value would not prove it.
                "total_commits": 99,
                "files": [
                    {"filename": "a.py", "additions": 40, "deletions": 5},
                    {"filename": "b.py", "additions": 2, "deletions": 11},
                    {"filename": "c.md", "additions": 7, "deletions": 0},
                ],
            })
            return
        if head == DEFAULT_BRANCH:
            # The honest-zeros arm: a real measurement, not an absence.
            self.send(200, {
                "status": "identical",
                "ahead_by": 0, "behind_by": 0, "total_commits": 0, "files": [],
            })
            return
        # Every other chat's branch was never pushed, which is the dominant
        # steady state and must read as "no answer" rather than as zeros.
        self.send(404, {"message": "Not Found"})

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
