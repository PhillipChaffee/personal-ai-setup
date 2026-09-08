#!/usr/bin/env bash
# test-code-agent-manager.sh — end-to-end integration test of the code-agent
# plane with NO containers and NO VPS: the manager runs for real, chats are
# mock-opencode-server.py processes behind stub-engine.sh, and the repo being
# "cloned" is a local scratch git repo. Exercises the full lifecycle:
#
#   auth · allowlist + zen-free guards · create (clone/branch/setup/config/
#   auth seed) · base branches (list, cut-from, refusals) · max-active refusal ·
#   proxying incl. SSE · the blocking permission flow · busy-guarded idle
#   spin-down · wake-on-request with state intact · stop/wake/delete-purge ·
#   the agent notifications, against a recording fake ntfy (fake-ntfy.py):
#   each edge fires once, later passes do not re-fire, an abort is silent, and
#   the payload is asserted content-free against the bytes that left the box
#
# Runs anywhere with python3 + git + curl. Exits non-zero on any failure.
#
# --serve: instead of running assertions, stand the stack up (manager + stub
# engine + fixtures) and stay in the foreground, printing the connection env
# — for driving other clients at it (e.g. goose-phone-app's
# `cargo run -p opencode-client --example smoke`). Ctrl-C tears it down.
# shellcheck disable=SC2015
# ^ FILE-LEVEL, and load bearing. Every assertion below is the deliberate
# `[ cond ] && ok "..." || bad "..."` idiom, which SC2015 warns about because
# `a && b || c` runs c when b fails. It cannot here: ok() ends in
# `PASS_COUNT=$((PASS_COUNT + 1))`, an arithmetic ASSIGNMENT, which exits 0
# unconditionally.
#
# DO NOT "tidy" that to `((PASS_COUNT++))`. It returns 1 when the value was 0
# (verified: `n=0; ((n++))` -> exit 1, `n=0; n=$((n+1))` -> exit 0), so the
# first passing assertion of every run would ALSO report a failure -- and this
# disable would suppress the warning that would have caught it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/code-agent-test.XXXXXX")"
# Overridable so an assertion run can happen while a `--serve` stack is still
# up on the defaults — otherwise the second one dies on "address already in
# use" and reports it as four failed assertions.
PORT="${PORT:-4399}"
# The assertions want a reaper that fires while the test is still watching.
# `--serve` does not: a 4-second idle timeout means a client being driven by
# hand re-wakes the container between every tap. Override for that case.
IDLE_SECONDS="${IDLE_SECONDS:-4}"
# The per-chat container port band, derived from PORT so a single override moves
# everything. This is what lets several worktrees run this harness at once: the
# manager allocates chat ports from its index rather than from the OS, so two
# runs sharing a base both try to bind the same port for their first chat.
BASE_CHAT_PORT="${BASE_CHAT_PORT:-$((PORT + 20))}"
PASS="test-secret-$$"
BASE="http://127.0.0.1:$PORT"
CURL="curl -sS --max-time 30 -u opencode:$PASS"

PASS_COUNT=0; FAIL_COUNT=0
ok()  { echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
bad() { echo "FAIL  $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
jget() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }
cstate() { STUB_ENGINE_STATE="$WORK/stub" "$HERE/stub-engine.sh" container inspect --format '{{.State.Status}}' "code-agent-$1" 2>/dev/null || echo absent; }

# Poll until the github sweep has published a pass that STARTED after now, using
# /api/health's github_at as the predicate.
#
# TWO advances, not one: a pass already in flight when the world changed was
# reading the OLD world, so waiting for a single advance can return a snapshot
# taken before the fixture under test existed.
#
# A fixed sleep is forbidden here. At INTERVAL=2 a sweep can legitimately land
# mid-restart or on a half-written index, and sleep-and-hope makes every
# downstream assertion silently vacuous -- which is the flake class this file
# already documents. So this FAILS loudly on timeout rather than falling through.
wait_sweeps() { # wait_sweeps <advances>
  local want="${1:-2}" seen=0 last cur i
  # shellcheck disable=SC2086
  last="$($CURL "$BASE/api/health" 2>/dev/null | jget "d.get('github_at', 0)" 2>/dev/null || echo 0)"
  for i in $(seq 1 120); do
    sleep 0.25
    # shellcheck disable=SC2086
    cur="$($CURL "$BASE/api/health" 2>/dev/null | jget "d.get('github_at', 0)" 2>/dev/null || echo 0)"
    if [ "$cur" != "$last" ]; then
      seen=$((seen + 1)); last="$cur"
      [ "$seen" -ge "$want" ] && return 0
    fi
  done
  bad "the github sweep did not advance $want time(s) in 30s (github_at stuck at $last)"
  return 1
}

MANAGER_PID=""
GITHUB_PID=""
NTFY_PID=""
cleanup() {
  [ -n "$MANAGER_PID" ] && kill "$MANAGER_PID" 2>/dev/null || true
  [ -n "$GITHUB_PID" ] && kill "$GITHUB_PID" 2>/dev/null || true
  [ -n "$NTFY_PID" ] && kill "$NTFY_PID" 2>/dev/null || true
  for pid in "$WORK"/stub/*.pid; do
    [ -f "$pid" ] && kill "$(cat "$pid")" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---- fixtures ---------------------------------------------------------------
mkdir -p "$WORK/root" "$WORK/stub" "$WORK/seed"
git -C "$WORK/seed" init -q -b main
echo "# seed" > "$WORK/seed/README.md"
git -C "$WORK/seed" -c user.email=t@t -c user.name=t add README.md
git -C "$WORK/seed" -c user.email=t@t -c user.name=t commit -qm init

# A second branch with a file of its OWN on it: "was this cut from the base?"
# is then answerable by looking for that file, not by trusting a branch name.
git -C "$WORK/seed" checkout -q -b release/2.x
echo "shipped" > "$WORK/seed/RELEASE.md"
git -C "$WORK/seed" -c user.email=t@t -c user.name=t add RELEASE.md
git -C "$WORK/seed" -c user.email=t@t -c user.name=t commit -qm "release line"
git -C "$WORK/seed" checkout -q main
# 119 branches, because GitHub caps per_page at 100: a manager that does not
# paginate loses everything after claude/spike-114 and nobody notices.
MAIN_SHA="$(git -C "$WORK/seed" rev-parse main)"
{
  for i in $(seq 0 114); do printf 'create refs/heads/claude/spike-%03d %s\n' "$i" "$MAIN_SHA"; done
  printf 'create refs/heads/agent/testrepo-fixture %s\n' "$MAIN_SHA"
  printf 'create refs/heads/zzz-last-branch %s\n' "$MAIN_SHA"
} | git -C "$WORK/seed" update-ref --stdin
# Reverse-sorted on purpose — the manager is supposed to sort, and a fixture
# that arrives sorted cannot prove it does.
git -C "$WORK/seed" for-each-ref --format='%(refname:short)' refs/heads \
  | sort -r > "$WORK/branches.txt"
EXPECTED="$(wc -l < "$WORK/branches.txt" | tr -d ' ')"

cat > "$WORK/root/repos.json" <<EOF
{"repos": [
  {"name": "testrepo", "url": "file://$WORK/seed", "tier": 1,
   "setup": "touch /chat/workspace/setup-ran.marker",
   "edit_only": false, "allow_push": false, "public_throwaway": false},
  {"name": "throwaway", "url": "file://$WORK/seed", "tier": 1,
   "setup": "", "edit_only": true, "allow_push": true, "public_throwaway": true}
  ,
  {"name": "ghrepo", "url": "https://github.com/testowner/testrepo.git", "tier": 1,
   "setup": "", "edit_only": true, "allow_push": false, "public_throwaway": false}
]}
EOF
# ghrepo is never cloned, only listed: it is the one entry with a real GitHub
# URL, so it is the one that can prove the slug comes off the allowlist's URL
# rather than off the name the caller sent.

# ---- start the manager ------------------------------------------------------
# MANAGER_PY replaces the interpreter the manager runs under. It exists so CI
# can measure coverage of a component that is only ever exercised as a live
# server: MANAGER_PY="coverage run --parallel-mode --data-file=$PWD/.coverage".
# The env is wiped (env -i) to prove the manager needs nothing but what the
# unit gives it, so the data file must be named on the command line rather
# than inherited through COVERAGE_FILE.
read -r -a MANAGER_PY <<<"${MANAGER_PY:-python3}"

# A fake GitHub, so the manager's pull-request routes exercise real request
# building and real error mapping instead of going untested.
GH_PORT="${GH_PORT:-4398}"
FAKE_GITHUB_BRANCH="agent/testrepo-fixture" \
  FAKE_GITHUB_BRANCHES_FILE="$WORK/branches.txt" \
  python3 "$HERE/fake-github.py" --port "$GH_PORT" &
GITHUB_PID=$!
for _ in $(seq 1 20); do
  curl -sS -o /dev/null "http://127.0.0.1:$GH_PORT/repos/testowner/testrepo/pulls" && break
  sleep 0.3
done

# A recording ntfy, so the agent-notification channel can be asserted on the
# exact bytes that left the manager rather than on the manager's intentions.
# Two topics on purpose: the failure channel (NTFY_TOPIC, notify.sh) and the
# agent channel (NTFY_AGENT_TOPIC) must be separately burnable, so the tests
# below check the notifications landed on the second and never the first.
NTFY_PORT="${NTFY_PORT:-$((PORT - 2))}"
NTFY_LOG="$WORK/ntfy.jsonl"
FAILURE_TOPIC="failure-topic-$$"
AGENT_TOPIC="agent-topic-$$"
python3 "$HERE/fake-ntfy.py" --port "$NTFY_PORT" --out "$NTFY_LOG" &
NTFY_PID=$!
for _ in $(seq 1 20); do
  curl -sS -o /dev/null "http://127.0.0.1:$NTFY_PORT/ready" && break
  sleep 0.3
done
# Every notification recorded so far, filtered to one kind.
ntfy_count() { python3 -c '
import json, sys
kind = sys.argv[1]
n = 0
for line in open(sys.argv[2], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    body = json.loads(line)["body"]
    if isinstance(body, dict) and body.get("kind") == kind:
        n += 1
print(n)
' "$1" "$NTFY_LOG"; }

env -i PATH="$PATH" HOME="$HOME" \
  NTFY_SERVER="http://127.0.0.1:$NTFY_PORT" \
  NTFY_TOPIC="$FAILURE_TOPIC" \
  NTFY_AGENT_TOPIC="$AGENT_TOPIC" \
  CODE_AGENT_BIND=127.0.0.1 \
  CODE_AGENT_PORT="$PORT" \
  CODE_AGENT_BASE_CHAT_PORT="$BASE_CHAT_PORT" \
  CODE_AGENT_ROOT="$WORK/root" \
  CODE_AGENT_ENGINE="$HERE/stub-engine.sh" \
  CODE_AGENT_IMAGE=mock \
  CODE_AGENT_IDLE_SECONDS="$IDLE_SECONDS" \
  CODE_AGENT_REAPER_INTERVAL=2 \
  CODE_AGENT_GITHUB_INTERVAL=2 \
  CODE_AGENT_MAX_ACTIVE=2 \
  CODE_AGENT_TLS_CERT="$WORK/no-cert" \
  CODE_AGENT_TLS_KEY="$WORK/no-key" \
  STUB_ENGINE_STATE="$WORK/stub" \
  STUB_ENGINE_FAIL_ONESHOT="$WORK/fail-oneshot" \
  STUB_ENGINE_MOCK="$HERE/mock-opencode-server.py" \
  OPENCODE_SERVER_PASSWORD="$PASS" \
  GITHUB_CODE_AGENT_PAT="fake-pat-for-tests" \
  GITHUB_API_BASE="http://127.0.0.1:$GH_PORT" \
  OPENCODE_ZEN_API_KEY="fake-zen-key" \
  "${MANAGER_PY[@]}" "$REPO_ROOT/scripts/vps/code-agent-manager.py" \
  > "$WORK/manager.log" 2>&1 &
MANAGER_PID=$!

for _ in $(seq 1 30); do
  # shellcheck disable=SC2086
  $CURL -o /dev/null "$BASE/api/health" 2>/dev/null && break
  sleep 0.5
done

if [ "${1:-}" = "--serve" ]; then
  echo "code-agent test stack is up. Drive a client at it with:"
  echo "  export CODE_BASE_URL=$BASE"
  echo "  export CODE_PASSWORD=$PASS"
  echo "Ctrl-C to tear down. Manager log: $WORK/manager.log"
  # For non-interactive callers: the env in a sourceable file.
  echo "export CODE_BASE_URL=$BASE" > "${SERVE_ENV_FILE:-$WORK/serve.env}"
  echo "export CODE_PASSWORD=$PASS" >> "${SERVE_ENV_FILE:-$WORK/serve.env}"
  wait "$MANAGER_PID"
  exit 0
fi

echo "== test-code-agent-manager (work dir: $WORK) =="

# ---- 0. the reaper's clock and the notifier's net (unit, no stack) -----------
#
# Everything else in this file is end-to-end, and neither of these two can be
# reached that way: one is a race whose window is the duration of a socket walk,
# the other only shows up on a daemon thread's stderr. Both shipped, both were
# found by an adversarial pass reading the diff, and both are cheap to pin here.
#
#   * `sampled_at` must be stamped BEFORE the status walk, because it exists to
#     answer "how old are these readings". Stamped after, it dates them to the
#     END of a walk that is a subprocess plus a timeout=5 socket per chat, over
#     a running set that MAX_ACTIVE does not bound (admission_count exempts
#     blocked chats). Two wedged siblings put more than ARM_SETTLE_SECONDS
#     between the first chat's reading and the stamp — so a turn started after
#     that reading looks settled, buzzes "turn ended" seconds INTO the turn, and
#     pops its own arm so the real ending never buzzes.
#   * `_post_ntfy` runs on a daemon thread, where anything uncaught goes to
#     threading.excepthook and prints a traceback to journald. A malformed
#     NTFY_SERVER raises ValueError from `url.port` and a non-ASCII topic raises
#     UnicodeEncodeError from putrequest — neither an OSError nor an
#     HTTPException, and the second one's message quotes a character of the
#     topic. The topic is a password. The net has to be wider than the log.
# Written to a file, not piped: `coverage run -` refuses stdin ("No file to
# run"), so a heredoc here would have to fall back to a bare python3 -- which
# is exactly what it used to do, and why the coverage of everything these
# checks exercise was silently thrown away. $WORK is outside scripts/, so
# preflight.py is itself unmeasured, which is correct: it is test code.
cat >"$WORK/preflight.py" <<'PY'
import contextlib, importlib.util, io, sys, time

spec = importlib.util.spec_from_file_location("cam", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["cam"] = mod
spec.loader.exec_module(mod)

# --- the stamp dates the readings, not the pass ---
CHATS = ["c1", "c2", "c3"]
idx = mod.Index(chats={
    c: mod.Chat(id=c, repo="r", title="t", port=1, branch="b", last_active=time.time())
    for c in CHATS
})
readings = {}


def slow_session_state(chat):
    time.sleep(0.3)          # stands in for the timeout=5 socket, serially
    readings[chat.id] = time.time()
    return "idle"


mod.Index.load = staticmethod(lambda: idx)
mod.container_state = lambda cid: "running"
mod.session_state = slow_session_state
mod.pending_permissions = lambda running=None: ([], [])
mod.spin_down_idle = lambda *a: None
mod.notify_new_asks = lambda *a: None
captured = {}
mod.notify_finished_turns = lambda index, status, running, at: captured.__setitem__("at", at)
mod.reaper_pass()

assert len(readings) == len(CHATS), f"session_state ran {len(readings)}x, expected {len(CHATS)}"
skew = captured["at"] - readings["c1"]
assert skew <= 0, (
    f"sampled_at is {skew:.2f}s AFTER the reading it claims to date; at "
    f"ARM_SETTLE_SECONDS={mod.ARM_SETTLE_SECONDS} a real walk buzzes mid-turn"
)

# The consequence, stated in the domain: a turn armed one second after its chat
# was read idle is not finished, and must keep its arm for a later pass.
mod._reaper_memory.prev_running = frozenset(CHATS)
fired = []
real_notify_agent = mod.notify_agent
mod.notify_agent = lambda kind, count, chats: fired.append((kind, count, chats))
sampled = time.time()
with mod._reaper_memory.armed_lock:
    mod._reaper_memory.armed["c1"] = sampled + 1.0
mod.notify_finished_turns(idx, dict.fromkeys(CHATS, "idle"), frozenset(CHATS), sampled)
assert not fired, f"buzzed for a turn that had not started: {fired}"
assert "c1" in mod._reaper_memory.armed, "the arm was eaten; the real ending can never buzz"

# --- the notifier's net is wider than the log ---
mod.notify_agent = real_notify_agent      # the stub above would swallow the whole path
TOPIC = "sekritTopicóValue"
mod.NTFY_AGENT_TOPIC = TOPIC
mod.NTFY_SERVER = "http://ntfy.example:not-a-port"   # url.port raises ValueError
out, err = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
    mod.notify_agent("turn", 1, ["c1"])
    for _ in range(50):
        time.sleep(0.05)
        if out.getvalue() or err.getvalue():
            break
    time.sleep(0.2)
o, e = out.getvalue(), err.getvalue()
assert "Traceback" not in e, f"an uncaught daemon-thread traceback reached stderr: {e[:200]}"
assert "agent notification lost" in o, f"the failure was not logged at all: {o!r}"
assert TOPIC not in o + e and "ó" not in o + e, "the topic leaked into the log"
PY
if "${MANAGER_PY[@]}" "$WORK/preflight.py" "$REPO_ROOT/scripts/vps/code-agent-manager.py"
then
  ok "the reaper stamps sampled_at before the walk, and withholds an unsettled turn"
  ok "a malformed ntfy target is logged by TYPE — no traceback, no topic"
else
  bad "reaper clock / notifier exception net (see the assertion above)"
fi

# ---- 0b. the shapes a hand-edited state file can take (unit, no stack) ------
# Index.load and load_repos are written to tolerate junk -- isinstance checks at
# every level -- and none of those arms had ever executed, because the only
# files they ever see are ones the manager itself wrote. Same for the config
# template guard and the handle-eviction bound: reachable in principle, never
# reached by an end-to-end run. All in-process, no wall clock.
cat >"$WORK/preflight-shapes.py" <<'PY'
import dis, importlib.util, inspect, json, re, sys, tempfile
from pathlib import Path
from urllib.parse import urlparse as REAL_URLPARSE

spec = importlib.util.spec_from_file_location("cam", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["cam"] = mod
spec.loader.exec_module(mod)

tmp = Path(tempfile.mkdtemp())

# --- Index.load: wrong shapes degrade, they do not raise ---
mod.INDEX_PATH = tmp / "index.json"
mod.INDEX_PATH.write_text(json.dumps({"chats": "not a dict"}))
assert mod.Index.load().chats == {}, "a non-dict chats map should read as empty"
# Only the non-dict ENTRY is reachable from a file. The companion
# `isinstance(cid, str)` guard cannot fail for anything json.load produces --
# JSON object keys are always strings, so an int key round-trips to "7" and is
# legitimately kept. That guard is defensive against a caller, not a file.
mod.INDEX_PATH.write_text(json.dumps({"chats": {"ok": {"id": "ok", "repo": "r", "title": "t",
                                                       "port": 1, "branch": "b"},
                                                "bad": "not a dict"}}))
loaded = mod.Index.load().chats
assert set(loaded) == {"ok"}, f"wrong-typed entries survived: {sorted(loaded)}"

# --- load_repos: missing, wrong container, wrong entries ---
mod.REPOS_PATH = tmp / "repos.json"
assert mod.load_repos() == {}, "a missing repos.json should be an empty allowlist"
mod.REPOS_PATH.write_text(json.dumps({"repos": "not a list"}))
assert mod.load_repos() == {}, "a non-list repos value should be an empty allowlist"
mod.REPOS_PATH.write_text(json.dumps({"repos": [
    "not a dict",
    {"no": "name"},
    {"name": 7},
    {"name": "good", "url": "https://github.com/o/n.git", "tier": 1, "setup": "",
     "edit_only": True, "allow_push": False, "public_throwaway": False},
]}))
repos = mod.load_repos()
assert set(repos) == {"good"}, f"malformed allowlist entries survived: {sorted(repos)}"

# --- the handle memory is bounded, oldest first ---
rm = mod.ReaperMemory()
first = rm.mint_handle(["c1"])
for i in range(mod.HANDLE_MEMORY + 5):
    rm.mint_handle([f"c{i}"])
assert len(rm.handles) <= mod.HANDLE_MEMORY, f"handle memory unbounded: {len(rm.handles)}"
assert first not in rm.handles, "the oldest handle was not the one evicted"

# --- the config template guard, and the model override ---
bad_tpl = tmp / "bad-template.json"
bad_tpl.write_text(json.dumps(["not", "an", "object"]))
mod.CONFIG_TEMPLATE = bad_tpl
try:
    mod.render_chat_config(tmp / "chatA", None, allow_push=False)
except mod.ConfigTemplateError:
    pass
else:
    raise AssertionError("a non-object config template was accepted")

good_tpl = tmp / "good-template.json"
good_tpl.write_text(json.dumps({"_readme": "strip me", "model": "opencode/default"}))
mod.CONFIG_TEMPLATE = good_tpl
chat_dir = tmp / "chatB"
mod.render_chat_config(chat_dir, "opencode/chosen-model", allow_push=True)
written = json.loads((chat_dir / "home" / ".config" / "opencode" / "opencode.json").read_text())
assert written["model"] == "opencode/chosen-model", written
assert "_readme" not in written, "the template readme leaked into a chat config"
assert written["permission"]["bash"]["git push*"] == "allow", written

# --- the container's standing instructions land beside the config (#17 C3) ---
# The repo's real AGENTS.md, byte for byte: the config template names it by its
# in-container path, so a chat whose copy is stale or absent is a chat that was
# never told the delivery convention.
rendered = chat_dir / "home" / ".config" / "opencode" / "AGENTS.md"
assert rendered.is_file(), "AGENTS.md was not rendered into the chat volume"
assert rendered.read_bytes() == mod.AGENTS_TEMPLATE.read_bytes(), "AGENTS.md was altered"
# A DRIFT-LOCK BETWEEN TWO STRINGS IN THIS REPO, and nothing more. It is NOT
# evidence about any pull request: the agent writes the body, so no assertion
# here can make one say anything. What it holds together is a pair that has to
# agree — the label AGENTS.md tells the agent to write, and AGENT_PR_MARKER,
# which pull_to_wire greps for when it reports `agent_authored`. Rename one
# without the other and every pull silently reads agent_authored: false, which
# looks exactly like a model that stopped following the convention. The
# OBSERVABLE for the convention itself is that field on /api/pulls; the three
# assertions below it are what test it.
assert mod.AGENT_PR_MARKER in rendered.read_text().lower(), \
    "the instructions no longer name the marker pull_to_wire looks for"

# A MISSING TEMPLATE MUST NOT FAIL A CREATE. Instructions are a convention;
# trading one for an outage would be the wrong direction.
mod.AGENTS_TEMPLATE = tmp / "no-such-AGENTS.md"
chat_dir_c = tmp / "chatC"
mod.render_chat_config(chat_dir_c, None, allow_push=False)
assert (chat_dir_c / "home" / ".config" / "opencode" / "opencode.json").is_file()
assert not (chat_dir_c / "home" / ".config" / "opencode" / "AGENTS.md").exists()

# --- agent_authored: the OBSERVABLE, not an enforcement (#17 C3) -------------
# Nothing can make the agent write the line. What must hold is that a body
# carrying it reads true, a body without it reads FALSE rather than absent
# (absent would render as "unknown" and hide the regression), and a pull GitHub
# sent no body for carries no claim at all.
marked = mod.pull_to_wire("o/n", {"number": 1, "body": "Agent-authored: opened by a code-agent chat."},
                          with_checks=False)
assert marked["agent_authored"] is True, marked
plain = mod.pull_to_wire("o/n", {"number": 2, "body": "Fixes the thing."}, with_checks=False)
assert plain["agent_authored"] is False, plain
none = mod.pull_to_wire("o/n", {"number": 3, "body": None}, with_checks=False)
assert "agent_authored" not in none, none

# --- every route+VERB the dispatcher serves is named in BOTH published lists -
# Issue #17 C1's "exposes exactly" list named five things; the dispatcher
# serves twelve API paths plus the proxy — thirteen (verb, path) rows — and the
# module docstring had drifted three routes behind. It is derived here so the
# NEXT route cannot, and derived at VERB granularity, which the first cut was
# not: it compared PATHS, so deleting only the `GET /api/chats` row left the
# path documented by `POST /api/chats` and reported a clean sweep, and a NEW
# verb on an existing path was invisible for the same reason. `blind` below
# holds exactly the rows that gate could not report, as an assertion.
#
# AND DERIVED FROM THE DISPATCHER RATHER THAN FROM THE TABLES, which the second
# cut was not: it drove every path `API_READS` and the `ROUTE_*` patterns name,
# so a route dispatched from a LITERAL path — the file's own idiom, `elif
# (path, verb) == ("/api/chats", "POST")` — was named by no table, never
# driven, and needed no documenting. served() now discovers the paths BY
# DRIVING (the oracle above the definition) and refuses to answer until every
# dispatch site in the dispatcher's bytecode has fired. `LiteralRoute`,
# `PrefixRoute`, `InlineAnswer` and `BlindOracle` below are the three escapes
# and the oracle's own control, fed in as fixtures.
#
# TWO LISTS, ONE GATE. The docstring is not the only place this surface is
# published: docs/code-agents.md carries the same thirteen rows in a table that
# reads as generated. A hand-maintained copy that looks derived is worse than
# one that looks hand-maintained, so both are checked against the dispatcher
# and against each other, in both directions — a row served and not listed is
# drift, and a row listed and not served is drift too.
DOCS_MD = Path(sys.argv[2]).read_text()

# THE VERBS ARE THE SERVER'S OWN, read off the do_* methods rather than typed
# out here: add `do_HEAD = handle_any` and this probe widens by itself. The
# floor assertion is against VACUITY — an empty verb set would make every
# "the list is complete" claim below true for free.
VERBS = sorted(n[3:] for n in dir(mod.Handler) if n.startswith("do_"))
assert {"GET", "POST", "DELETE"} <= set(VERBS), VERBS

# One table, read twice: what a published list calls the placeholder, and a
# value that really matches the group. The same pattern therefore yields both
# the row a list has to contain and a path the dispatcher can be DRIVEN with,
# and the `match` assertion in candidates() fails loudly the day a pattern
# change makes the sample stale rather than silently dropping the route.
GROUPS = (("([a-zA-Z0-9-]+)", "<id>", "probe-chat"),
          ("([0-9]+)", "<n>", "7"),
          ("([^/]+)", "<name>", "probe-repo"),
          ("(/.*|$)", "/<path>", "/session"))

def expand(pattern, column):
    text = pattern.lstrip("^").rstrip("$")
    for regex, shown, sample in GROUPS:
        text = text.replace(regex, shown if column == "shown" else sample)
    if "(wake|stop)" in text:
        return [text.replace("(wake|stop)", "wake"), text.replace("(wake|stop)", "stop")]
    return [text]

# THE PATH ORACLE — why the candidate paths cannot come from the tables.
# handle_any's own idiom for a route with neither a pattern nor a table entry is
#     elif (path, verb) == ("/api/chats", "POST")
# and a path named ONLY that way is in no table this file can read. The previous
# revision enumerated the tables, so a route added that way was served under
# every verb, named by no published list, and swept clean (LiteralRoute below is
# that mutation, fed in as a fixture).
#
# So the candidates are taken off the dispatcher's OWN COMPARISONS: the path it
# is driven with records every string it gets compared against, and each one is
# driven back through the dispatcher on the next lap. handle_any starts with
# `path = urlparse(self.path).path`, which is where the recording rides in;
# `str.__eq__` still decides the answer, so the dispatcher behaves identically.
LITERALS: set[str] = set()

class WatchedPath(str):
    """A path that remembers what it was compared to. Equality is str's, and
    `!=` is Python's own inversion of it, so both directions are watched."""
    def __eq__(self, other):
        if isinstance(other, str):
            LITERALS.add(str(other))
        return str.__eq__(self, other)
    __hash__ = str.__hash__  # so `path in self.API_READS` still hits

def watching_urlparse(raw):
    parsed = REAL_URLPARSE(raw)
    return parsed._replace(path=WatchedPath(parsed.path))

def candidates(cls):
    """[(published path, a path that matches it)] — every path to drive: the two
    tables, plus every literal the oracle has watched the dispatcher compare."""
    out = [(p, p) for p in cls.API_READS]
    for name in sorted(dir(cls)):
        if not name.startswith("ROUTE_"):
            continue
        pattern = getattr(cls, name).pattern
        for shown, real in zip(expand(pattern, "shown"), expand(pattern, "real")):
            assert re.compile(pattern).match(real), f"{name}: sample {real} no longer matches"
            out.append((shown, real))
    out += [(p, p) for p in LITERALS if p.startswith("/")]
    return sorted(set(out))

def dispatchers(cls):
    """The functions that make a routing decision: every handle_any in the MRO,
    plus every route_* handed the VERB — route_pull_requests is a dispatcher in
    its own right, which is why dispatched() leaves it real."""
    out = [k.__dict__["handle_any"] for k in cls.__mro__ if "handle_any" in k.__dict__]
    for name in sorted(dir(cls)):
        if name.startswith("route_") and \
                "verb" in inspect.signature(getattr(cls, name)).parameters:
            out.append(getattr(cls, name))
    return out

def is_dispatch_target(name):
    """The names a dispatcher hands a request off to. Exact, not prefixed, for
    the two singletons: a helper called `proxy_headers` is not a route, and a
    site nothing can drive would hold this gate red forever."""
    return name in ("proxy", "send_json") or name.startswith("route_")

def dispatch_sites(cls):
    """{(file, line): label} — every place a dispatcher's own BYTECODE hands the
    request off. Read off the compiled function rather than the source text: the
    bytecode is what runs, and a name that reaches it reaches it however it was
    written.

    `send_json` counts, because a dispatcher's other way of answering is to
    answer inline — `elif path.startswith("/x"): self.send_json(200, ...)` is a
    served route with no route method to name it, and the sweep has to reach
    that line too or it is not enumerating the dispatcher.

    The table dispatch (`getattr(self, self.API_READS[path])()`) names no target
    and so has no site here — that route's completeness comes from the table,
    which is enumerated directly."""
    out = {}
    for func in dispatchers(cls):
        for ins in dis.get_instructions(func):
            target = ins.argval
            if not isinstance(target, str) or not is_dispatch_target(target):
                continue
            line = ins.positions.lineno if ins.positions else ins.starts_line
            assert line, f"{func.__qualname__}: no line for {target}"
            out[(func.__code__.co_filename, line)] = \
                f"{target} at line {line} of {func.__qualname__}"
    return out

def dispatched(cls, verb, path, fired):
    """Drive the REAL dispatcher once; say whether it routed the request, and
    record WHERE it dispatched from into `fired`.

    Nothing here reads handle_any's SOURCE — that would be a second guess at
    the routing table, which is the thing being checked. The handler is the one
    the server uses, with its leaves replaced by recorders. A method that is
    handed the verb (route_pull_requests) is a dispatcher in its own right and
    is left REAL — it is WRAPPED rather than replaced, so the call site is
    recorded while the verb distinction this gate exists to see is preserved. A
    method that is never handed the verb cannot make a verb decision, so
    recording it is lossless.

    A dispatch target that is neither `proxy` nor `route_*` would run for real;
    the `routed or refused` assertion is what catches that, loudly and with the
    output in the message, rather than letting a new target answer silently.
    """
    handler = cls.__new__(cls)
    handler.path, handler.command = path, verb
    handler.authed = lambda: True
    seen = []

    def recorder(name, real):
        def call(*a, **k):
            frame = sys._getframe(1)  # the dispatcher that just called us
            fired.add((frame.f_code.co_filename, frame.f_lineno))
            if real is not None:
                return real(*a, **k)
            seen.append(("ROUTED", name))
            return None
        return call

    # send_json ANSWERS rather than routes, so it is wrapped rather than
    # replaced: the call site is recorded, the status still reaches `seen`, and
    # nothing here reads it as "this path is served".
    handler.send_json = recorder(
        "send_json", lambda status, body: seen.append((status, body)))
    for name in dir(cls):
        if name != "proxy" and not name.startswith("route_"):
            continue
        takes_verb = "verb" in inspect.signature(getattr(cls, name)).parameters
        setattr(handler, name,
                recorder(name, getattr(handler, name) if takes_verb else None))
    saved, mod.urlparse = mod.urlparse, watching_urlparse
    try:
        handler.handle_any()
    finally:
        mod.urlparse = saved
    routed = [s for s in seen if s[0] == "ROUTED"]
    refused = [s for s in seen
               if s[0] == 404 and str(s[1].get("error", "")).startswith("no route")]
    assert routed or refused, f"{verb} {path} neither routed nor refused: {seen}"
    return bool(routed)

def served(cls):
    """{(verb, published path)} the dispatcher routes.

    `*` when EVERY verb the server answers is routed, which is the wildcard the
    published lists already use for the proxy — the one route with no verb
    allowlist of its own.

    THE SWEEP PROVES ITS OWN COMPLETENESS BEFORE IT ANSWERS, because "the list
    is complete" is the claim every assertion downstream rests on and an
    enumeration cannot be trusted to notice what it never looked at:

      * THE ORACLE IS LIVE. Not one comparison recorded means a literal-path
        route would be invisible, and the sweep says so instead of answering.
      * EVERY DISPATCH SITE FIRED. The candidates are driven to a fixpoint (a
        literal discovered on one lap is driven on the next), and then every
        place the dispatcher's bytecode hands off to a route has to have been
        reached by one of those drives. A route the candidates never name is a
        site that never fired — PrefixRoute below is that shape.
    """
    rows, done, fired = set(), set(), set()
    LITERALS.clear()  # a control from a PREVIOUS sweep is not this sweep's control
    while True:
        todo = [c for c in candidates(cls) if c not in done]
        if not todo:
            break
        for shown, real in todo:
            done.add((shown, real))
            verbs = [v for v in VERBS if dispatched(cls, v, real, fired)]
            if len(verbs) == len(VERBS):
                rows.add(("*", shown))
            else:
                rows.update((v, shown) for v in verbs)
    assert LITERALS, ("the path oracle recorded no comparison at all: nothing "
                      "shows a literal-path route would be seen, so this sweep "
                      "cannot claim to have enumerated the dispatcher")
    sites = dispatch_sites(cls)
    missing = sorted(label for key, label in sites.items() if key not in fired)
    assert not missing, (f"the sweep never reached {missing} — the dispatcher "
                         "routes somewhere these candidate paths do not go, so "
                         "the surface below is not the surface")
    return rows

def doc_rows(text, table=False):
    """Every `VERB /path` row in a published list.

    `table=True` for markdown, where only a `|`-delimited cell counts: prose in
    docs/code-agents.md names `GET /api/chats/<id>/pulls` in a sentence, and
    letting a sentence stand in for a table row is how a table starts lying.
    """
    rows = set()
    for line in text.splitlines():
        if table:
            if not line.startswith("|"):
                continue
            line = line.split("|")[1]
        parts = line.replace("`", "").split()
        if len(parts) >= 2 and parts[0] in [*VERBS, "*"] and parts[1].startswith("/"):
            rows.add((parts[0], parts[1].split("[")[0]))  # DELETE /api/chats/<id>[?purge=1]
    return rows

def drop_row(text, verb, path, table=False):
    """Delete the ONE row for (verb, path) — not the rows sharing its path."""
    return "\n".join(l for l in text.splitlines()
                     if (verb, path) not in doc_rows(l, table))

rows = served(mod.Handler)
for name, listed in (("module docstring", doc_rows(mod.__doc__)),
                     ("docs/code-agents.md", doc_rows(DOCS_MD, table=True))):
    assert not sorted(rows - listed), f"served but not in the {name}: {sorted(rows - listed)}"
    assert not sorted(listed - rows), f"in the {name} but not served: {sorted(listed - rows)}"
# LAST, so the two assertions above get to name the drift first — this one only
# has a count to report. It is the floor against a served() that quietly
# stopped deriving anything, and the reason adding a route means editing a test.
assert len(rows) == 13, f"expected thirteen (verb, route) rows, derived {sorted(rows)}"

# THE GATE'S OWN FALSIFIABILITY, fed in once per row rather than once — for
# both lists, because a gate that covers one copy of a list and not the other
# is how the second copy rots. Every row is deleted on its own and has to come
# back named, prefix-shadowed or verb-shadowed.
for verb, path in sorted(rows):
    for name, text, table in (("module docstring", mod.__doc__, False),
                              ("docs/code-agents.md", DOCS_MD, True)):
        holed = drop_row(text, verb, path, table)
        assert holed != text, f"drop_row removed no {name} row for {verb} {path}"
        assert sorted(rows - doc_rows(holed, table)) == [(verb, path)], \
            f"{name}: holing {verb} {path} reported {sorted(rows - doc_rows(holed, table))}"

# THE ROWS THE PATH-ONLY GATE COULD NOT REPORT, as an assertion rather than a
# claim in a comment. `/api/chats` is served under two verbs, so deleting
# either row leaves the PATH documented by the other and the previous revision
# of this gate swept clean — the literal acceptance test it was asked to fail.
def path_only_undocumented(text, table=False):
    listed = {p for _, p in doc_rows(text, table)}
    return sorted({p for _, p in rows} - listed)

blind = sorted(r for r in rows if not path_only_undocumented(drop_row(mod.__doc__, *r)))
assert blind == [("GET", "/api/chats"), ("POST", "/api/chats")], blind

# ...and the other half of the same blindness: a verb the dispatcher GROWS on a
# path that is already documented. `PUT /api/chats` is served by this subclass
# and named by no list, which the path-only gate reported as a clean sweep
# because `POST /api/chats` keeps the path listed. served() is driven, not
# parsed, so it sees the new verb without being told the route exists.
class GrewAVerb(mod.Handler):
    def handle_any(self):
        if self.command == "PUT" and self.path == "/api/chats":
            self.route_list_chats()
            return
        mod.Handler.handle_any(self)

grew = sorted(served(GrewAVerb) - doc_rows(mod.__doc__))
assert grew == [("PUT", "/api/chats")], grew

# THE THIRD BLINDNESS, AND THE ONE THAT SHIPPED: a route dispatched from a
# LITERAL path. It is in no table — not `API_READS`, not a `ROUTE_*` pattern —
# so a gate that enumerated the tables never drove it, never saw it served, and
# reported a clean sweep with an undocumented route answering every verb. The
# path here is discovered the only way it can be: by watching the dispatcher
# compare against it. The fixture reaches the oracle exactly the way the real
# dispatcher does, through the module's urlparse, because that is where the
# recording is wired in.
class LiteralRoute(mod.Handler):
    def handle_any(self):
        if mod.urlparse(self.path).path == "/api/admin/secrets":
            self.route_repos()
            return
        mod.Handler.handle_any(self)

literal = sorted(served(LiteralRoute) - doc_rows(mod.__doc__))
assert literal == [("*", "/api/admin/secrets")], literal

# ...and the shape the ORACLE cannot see either, which is why the sweep also
# has to prove it reached every dispatch site: a prefix test compares no
# literal, so no candidate path ever names this route and nothing above would
# notice. The sweep refuses to answer instead of answering short.
class PrefixRoute(mod.Handler):
    def handle_any(self):
        if mod.urlparse(self.path).path.startswith("/api/internal/"):
            self.route_repos()
            return
        mod.Handler.handle_any(self)

try:
    served(PrefixRoute)
except AssertionError as e:
    assert "the sweep never reached" in str(e), e
    assert "route_repos" in str(e), e
else:
    raise AssertionError("a route no candidate path reaches was swept clean")

# ...and the same escape with no route method at all: the dispatcher answers
# the request itself. Nothing names a route, so only the line it answers ON can
# report it, which is why send_json is a dispatch site like any other.
class InlineAnswer(mod.Handler):
    def handle_any(self):
        if mod.urlparse(self.path).path.startswith("/api/internal/"):
            self.send_json(200, {"secrets": "here you go"})
            return
        mod.Handler.handle_any(self)

try:
    served(InlineAnswer)
except AssertionError as e:
    assert "the sweep never reached" in str(e), e
    assert "send_json" in str(e), e
else:
    raise AssertionError("a route the dispatcher answers inline was swept clean")

# ...and the ORACLE'S OWN CONTROL, which is the reason the two fixtures above
# fail the way they do rather than passing quietly. This dispatcher routes off
# `self.path` directly, so it never asks the module's urlparse and nothing can
# watch it. A sweep that records not one comparison has no evidence a
# literal-path route would be seen, and says so instead of answering.
class BlindOracle(mod.Handler):
    def handle_any(self):
        if self.path == "/api/admin/secrets":
            self.route_repos()
            return
        self.send_json(404, {"error": f"no route: {self.command} {self.path}"})

try:
    served(BlindOracle)
except AssertionError as e:
    assert "the path oracle recorded no comparison" in str(e), e
else:
    raise AssertionError("a sweep whose oracle never fired reported a surface anyway")

# THE TWO GUARDS INSIDE THE HELPERS, fired once each. Both exist so that a
# future edit degrades LOUDLY instead of shrinking the derived surface, and an
# assertion nobody has ever seen fail is an assertion nobody has seen.
class AnsweredSomethingElse(mod.Handler):
    """A dispatch target that is neither `proxy` nor `route_*` runs for real.
    dispatched() has to refuse to read that as "not served" — which is what it
    looks like, and which would drop the route out of the surface silently."""
    def handle_any(self):
        self.send_json(500, {"error": "boom"})

try:
    dispatched(AnsweredSomethingElse, "GET", "/api/health", set())
except AssertionError as e:
    assert "neither routed nor refused" in str(e), e
else:
    raise AssertionError("a handler that neither routed nor refused was read as a verdict")

class StaleSample(mod.Handler):
    """A route pattern GROUPS cannot instantiate. Without the match assertion
    the sample path simply never dispatches, and the route disappears from the
    derived surface — a gate that quietly loses routes as the code is edited."""
    ROUTE_STALE = re.compile(r"^/api/widgets/([0-9a-f]{8})$")

try:
    candidates(StaleSample)
except AssertionError as e:
    assert "no longer matches" in str(e), e
else:
    raise AssertionError("a route whose sample cannot match it was derived anyway")
PY
if "${MANAGER_PY[@]}" "$WORK/preflight-shapes.py" "$REPO_ROOT/scripts/vps/code-agent-manager.py" \
  "$REPO_ROOT/docs/code-agents.md"
then
  ok "a hand-mangled index.json or repos.json degrades instead of raising"
  ok "the notification handle memory is bounded and evicts oldest-first"
  ok "a non-object config template is refused; the model override and push grant apply"
  ok "the container's AGENTS.md is rendered into the chat volume, and a missing one is survivable"
  ok "agent_authored is true/false from the PR body, and absent when GitHub sent none"
  ok "every VERB+route the dispatcher serves is named in the docstring AND in docs/code-agents.md"
  ok "...and holing any ONE row of either list — path- or verb-shadowed — reports exactly it"
  ok "...and a verb the dispatcher GROWS on an already-listed path is reported too"
  ok "...and a route dispatched from a LITERAL path, which no table names, is reported too"
  ok "...and the sweep proves its own reach: every dispatch site fired, and the oracle did"
  ok "...and the derivation refuses to guess: an unroutable answer and a stale sample both raise"
else
  bag="state-shape / config-template / instructions / route-doc checks"
  bad "$bag (see the assertion above)"
fi

# ---- 0c. the probes, when the thing they probe is not there (unit) ----------
# pending_permissions, session_state and container_state all have arms for "the
# chat did not answer", and those arms were being covered BY ACCIDENT: a socket
# occasionally timed out under load, so the same commit measured 91.04% on one
# run and 91.84% on another, with exactly these eight lines flapping.
#
# Coverage that depends on a race is not coverage of the behaviour, and it puts
# noise under the fail_under floor. These reach the same arms deterministically
# and in-process, by pointing the probes at a port nothing is listening on --
# pending_permissions takes its running list as a parameter precisely so a
# caller can supply one.
cat >"$WORK/preflight-probes.py" <<'PY'
import importlib.util, socket, sys

spec = importlib.util.spec_from_file_location("cam", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["cam"] = mod
spec.loader.exec_module(mod)

# A port that is bound and immediately closed: connect() gets ECONNREFUSED
# right away rather than hanging, so this costs no wall clock.
s = socket.socket()
s.bind(("127.0.0.1", 0))
dead_port = s.getsockname()[1]
s.close()

dead = mod.Chat(id="dead-chat", repo="r", title="t", port=dead_port, branch="b")

# --- the permission sweep: a chat that will not answer is UNREACHABLE, and
# must not be silently dropped. "In neither list" is the one outcome the
# docstring forbids, because the app reads it as "nothing pending".
found, unreachable = mod.pending_permissions(running=[dead])
assert found == [], f"a dead chat produced asks: {found}"
assert unreachable == ["dead-chat"], f"a dead chat was not reported unreachable: {unreachable}"

# --- session_state: unknown, NOT idle. The reaper must not spin down a chat
# it merely failed to reach.
state = mod.session_state(dead)
assert state == "unknown", f"an unreachable chat reported {state!r}, not 'unknown'"

# --- container_state: absent when the engine says nothing exists.
assert mod.container_state("no-such-chat-at-all") == "absent"
PY
if "${MANAGER_PY[@]}" "$WORK/preflight-probes.py" "$REPO_ROOT/scripts/vps/code-agent-manager.py"
then
  ok "an unreachable chat is reported unreachable, never silently dropped"
  ok "an unreachable chat's session reads 'unknown', not 'idle'"
  ok "a container the engine does not know is 'absent'"
else
  bad "probe-failure arms (see the assertion above)"
fi

# ---- 0d. arms with no HTTP surface (in-process units) -----------------------
# Three clusters that the running manager cannot be driven into from outside:
# container argv (the process never starts under the stub engine's eye with a
# PAT set), GitHub responses of the wrong SHAPE (fake-github.py always answers
# well-formed), and a truncated index.json (every write here is atomic, so no
# torn read can ever be observed).
#
# $WORK is outside scripts/, so these fixtures are themselves unmeasured, which
# is correct — they are test code. They MUST run under $MANAGER_PY: a plain
# python3 asserts identically and contributes zero coverage.

cat >"$WORK/preflight-argv.py" <<'PY'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("cam", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["cam"] = mod
spec.loader.exec_module(mod)

# Set BOTH explicitly. This fixture does NOT run under `env -i`, so leaving
# them inherited would let the developer's real environment decide the outcome
# instead of the guard under test.
mod.GH_PAT = "pat-fixture"
mod.TOGETHER_KEY = "together-fixture"

recorded = []
mod.engine = lambda *a, **k: recorded.append(list(a))


def argv_for(probe):
    recorded.clear()
    mod.run_container(mod.Chat(
        id="argvprobe", repo="_probe" if probe else "testrepo",
        title="t", port=9001, branch="b", probe=probe))
    assert len(recorded) == 1, len(recorded)
    return recorded[0]


# NEVER interpolate the captured argv into an assertion message: on a machine
# with a real TOGETHER_API_KEY or GITHUB_CODE_AGENT_PAT exported, a failure
# would print a live secret into the harness log. Booleans and counts only.
probe_argv = argv_for(True)
assert any(a.startswith("TOGETHER_API_KEY=") for a in probe_argv)
assert not any(a.startswith("GH_TOKEN=") for a in probe_argv)

# The PAIRED call is what proves the GUARD decided, not the environment. With
# GH_PAT empty the "no GH_TOKEN" assertion above passes vacuously.
assert any(a.startswith("GH_TOKEN=") for a in argv_for(False))

# validate_base's two refusals that happen BEFORE anything is cloned.
err = mod.validate_base("_probe", mod.PROBE_REPO, "main")
assert err is not None and err.status == 400, err
assert "no branch to base on" in err.message, err.message

err = mod.validate_base("emptyurl", mod.RepoEntry(name="emptyurl", url=""), "main")
assert err is not None and err.status == 409, err
assert "no GitHub remote to read" in err.message, err.message

# list_branches when the pager EXHAUSTS instead of breaking early. The live
# fixture holds 119 branches, so page 2 is short and the break always fires.
pages = []


def fake_gh(method, path, body=None):
    page = int(path.rsplit("page=", 1)[1])
    pages.append(page)
    # Unique names per page: dict.fromkeys dedupes, so repeated names would
    # silently shrink the count and hide a short page.
    return [{"name": f"b{page}-{i}"} for i in range(mod.BRANCH_PAGE_SIZE)]


mod.gh = fake_gh
mod.default_branch = lambda slug: "main"
out = mod.list_branches("r", mod.RepoEntry(name="r", url="https://github.com/o/r"))
# Against the CONSTANTS, never the literals 5/100.
assert pages == list(range(1, mod.BRANCH_MAX_PAGES + 1)), pages
assert out["truncated"] is True, out["truncated"]
assert len(out["branches"]) == mod.BRANCH_MAX_PAGES * mod.BRANCH_PAGE_SIZE, len(out["branches"])
PY
if "${MANAGER_PY[@]}" "$WORK/preflight-argv.py" "$REPO_ROOT/scripts/vps/code-agent-manager.py"
then
  ok "a probe chat gets TOGETHER_API_KEY but never GH_TOKEN (paired against a real chat)"
  ok "validate_base refuses _probe and a remote-less repo before any clone"
  ok "list_branches reports truncated when the pager exhausts"
else
  bad "container argv / validate_base / branch pager (see the assertion above)"
fi

cat >"$WORK/preflight-gh.py" <<'PY'
import http.server, importlib.util, json, sys, threading

spec = importlib.util.spec_from_file_location("cam", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["cam"] = mod
spec.loader.exec_module(mod)


class Recorder(http.server.BaseHTTPRequestHandler):
    calls = []
    routes = []  # (needle, status, body-bytes) -- FIRST match wins

    def do_GET(self):
        Recorder.calls.append(self.headers.get("Authorization"))
        status, body = 200, b"null"
        for needle, st, bd in Recorder.routes:
            if needle in self.path:
                status, body = st, bd
                break
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Recorder)
threading.Thread(target=srv.serve_forever, daemon=True).start()
mod.GH_API = "http://127.0.0.1:%d" % srv.server_address[1]


def j(obj):
    return json.dumps(obj).encode()


# A. no PAT: the Authorization header must be absent entirely.
mod.GH_PAT = ""
Recorder.calls.clear(); Recorder.routes = []
mod.gh("GET", "/x")
assert len(Recorder.calls) == 1, len(Recorder.calls)
assert Recorder.calls[0] is None, "an Authorization header was sent without a PAT"

# B. a 4xx whose body is valid JSON but NOT an object. The recorder count is
#    mandatory, not decorative: this exact status+message pair is ALSO what a
#    dict-with-no-message produces, so without it the assertion cannot tell the
#    two arms apart.
Recorder.calls.clear(); Recorder.routes = [("/x", 422, j(["not", "an", "object"]))]
try:
    mod.gh("GET", "/x")
except mod.GitHubError as e:
    assert e.status == 422, e.status
    assert e.message == "GitHub answered 422", e.message
else:
    raise AssertionError("a 422 did not raise")
assert len(Recorder.calls) == 1, len(Recorder.calls)

# C. combined status of the wrong TYPE -- the check-runs verdict still stands.
Recorder.calls.clear()
Recorder.routes = [("/check-runs", 200, j({"check_runs": [{"conclusion": "success"}]})),
                   ("/status", 200, j([]))]
assert mod.summarise_checks("o/r", "sha1") == "passing"
assert len(Recorder.calls) == 2, len(Recorder.calls)

# D. a conclusion in none of the three sets. "unknown" is not reachable by any
#    other exit -- none/failing/pending/passing are all distinct returns.
Recorder.calls.clear()
Recorder.routes = [("/check-runs", 200, j({"check_runs": [{"conclusion": "weird-new-thing"}]})),
                   ("/status", 200, j({}))]
assert mod.summarise_checks("o/r", "sha1") == "unknown"
assert len(Recorder.calls) == 2, len(Recorder.calls)

# E. with_checks=False. The ZERO-REQUEST assertion is the only thing that
#    distinguishes this from with_checks=True; asserting checks=="unknown"
#    alone would pass either way.
Recorder.calls.clear()
wire = mod.pull_to_wire("o/r", {"number": 1, "head": {"sha": "abc"}}, with_checks=False)
assert wire["checks"] == "unknown", wire["checks"]
assert Recorder.calls == [], Recorder.calls
PY
if "${MANAGER_PY[@]}" "$WORK/preflight-gh.py" "$REPO_ROOT/scripts/vps/code-agent-manager.py"
then
  ok "gh() sends no Authorization header when there is no PAT"
  ok "a 4xx body that is not an object falls back to GitHub's status line"
  ok "summarise_checks survives a wrong-typed combined status, and an unknown conclusion"
  ok "pull_to_wire(with_checks=False) makes no GitHub call at all"
else
  bad "gh/summarise_checks/pull_to_wire shapes (see the assertion above)"
fi

cat >"$WORK/preflight-corrupt.py" <<'PY'
import importlib.util, sys, tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("cam", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["cam"] = mod
spec.loader.exec_module(mod)

# Index.save() writes to a temp file and replaces, so a TRUNCATED index.json is
# unobservable through the running manager -- every corrupt fixture elsewhere in
# this harness writes valid json of the wrong SHAPE, which takes a different arm.
tmp = Path(tempfile.mkdtemp())
mod.INDEX_PATH = tmp / "index.json"
mod.INDEX_PATH.write_text('{"chats": {')

logged = []
mod.log = lambda msg: logged.append(msg)

idx = mod.Index.load()
assert idx.chats == {}, idx.chats
assert any("index.json is unreadable" in m for m in logged), logged
assert any("JSONDecodeError" in m for m in logged), logged

# ChatLaunchError's only construction site sits behind a real 90s wait, so its
# message body is unreachable in an end-to-end run. Assert that it HAS one
# rather than re-deriving the f-string, which would only restate the class.
err = mod.ChatLaunchError(mod.WAIT_FOR_CHAT_SECONDS)
assert isinstance(err, RuntimeError)
assert str(err)
PY
if "${MANAGER_PY[@]}" "$WORK/preflight-corrupt.py" "$REPO_ROOT/scripts/vps/code-agent-manager.py"
then
  ok "a truncated index.json degrades to empty and says so, instead of killing every request"
else
  bad "corrupt-index / ChatLaunchError arms (see the assertion above)"
fi

# ---- 0e. the github sweep's dispositions and its error nets ------------------
# The sweep answers /api/pulls from a cache so the app's ten-second poll costs no
# GitHub calls. Its three dispositions are three different CLAIMS, and the live
# stack can only produce one of them: an id in `pulls` with rows. A chat whose
# repo left the allowlist, one GitHub refuses to answer for, and one that raises
# something gh() does not convert all need arranging, and the loop's never-die
# net needs a pass that raises. All in-process.
cat >"$WORK/preflight-github.py" <<'PY'
import contextlib, importlib.util, io, sys, time, types

spec = importlib.util.spec_from_file_location("cam", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["cam"] = mod
spec.loader.exec_module(mod)


# Kept before anything stubs it: the sections below replace mod.compare_stat to
# drive github_pass, and section 6 needs the REAL one back.
real_compare_stat = mod.compare_stat


def chat(cid):
    return mod.Chat(id=cid, repo="r", title="t", port=1, branch="b", last_active=time.time())


# 1. One pass over an index holding every disposition at once.
idx = mod.Index(chats={c: chat(c) for c in ("fine", "gone", "refused", "weird")})
mod.Index.load = classmethod(lambda cls: idx)


def fake_repo_slug(c):
    if c.id == "gone":
        # What slug_of really raises for a repo off the allowlist, and for the
        # _probe chat whose RepoEntry carries an empty url.
        raise mod.GitHubError(409, "repo 'r' is not in the allowlist any more")
    return "o/r"


def fake_chat_pulls(c):
    if c.id == "refused":
        raise mod.GitHubError(502, "GitHub is unreachable")
    if c.id == "weird":
        # gh() converts OSError and HTTPException; it does not convert this. A
        # non-ASCII branch in a hand-edited index.json raises exactly it out of
        # http.client's putrequest.
        raise UnicodeEncodeError("ascii", "brünch", 1, 2, "ordinal not in range")
    return [{"number": 7, "title": "t"}]


mod.repo_slug = fake_repo_slug
mod.chat_pulls = fake_chat_pulls
# A stat for EVERY chat that gets as far as being measured, including the one
# whose pull list then fails. That is what makes the atomicity assertion below
# real rather than incidental.
mod.compare_stat = lambda c, s, h: {"ahead": 1, "behind": 0, "commits": 1,
                                    "files": 1, "additions": 2, "deletions": 3,
                                    "truncated": False}

buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    mod.github_pass()
snap = mod._github_memory.snapshot

assert snap.as_of > 0, snap.as_of
assert list(snap.pulls) == ["fine"], list(snap.pulls)
assert snap.pulls["fine"] == [{"number": 7, "title": "t"}], snap.pulls["fine"]
# Settled vs retryable are different buckets. A probe chat parked in
# `unreachable` would spin on a screen forever.
assert snap.no_remote == frozenset({"gone"}), snap.no_remote
assert snap.unreachable == frozenset({"refused", "weird"}), snap.unreachable
# A chat with no answer is NAMED, never given an empty list: the app reads an
# empty list as "nothing is open", which a failure is not.
for cid in ("gone", "refused", "weird"):
    assert cid not in snap.pulls, cid
# ATOMICITY: "refused" was measured -- compare_stat returned for it -- but its
# pull list raised, so it publishes NOTHING. A half-row (a fresh stat beside a
# stale pull list, with the chat also named unreachable) is exactly the
# ambiguity `unreachable` exists to prevent.
assert list(snap.stats) == ["fine"], list(snap.stats)
# THE UNION INVARIANT: every chat in the index is in exactly one disposition.
assert set(snap.pulls) | snap.unreachable | snap.no_remote == set(idx.chats)
assert not (set(snap.pulls) & snap.unreachable)
assert not (snap.unreachable & snap.no_remote)
# One line per pass with a count, not one per chat.
out = buf.getvalue()
assert "github sweep: 3 chat(s) had no answer" in out, out

# 2. as_of is stamped BEFORE the walk, not after. Same shape as the reaper's
#    sampled_at fixture: a slow call whose own reading must be LATER than the
#    stamp. Measured after, as_of would date the readings to the wrong end of a
#    walk that can run for minutes at gh()'s timeout=20.
readings = []


def slow_pulls(c):
    time.sleep(0.05)
    readings.append(time.time())
    return []


mod.repo_slug = lambda c: "o/r"
mod.chat_pulls = slow_pulls
mod.github_pass()
assert readings, "the walk never ran"
assert mod._github_memory.snapshot.as_of <= readings[0], (
    mod._github_memory.snapshot.as_of, readings[0])

# 3. Eviction is structural: the next pass rebuilds from the index it loaded, so
#    a deleted chat is gone by omission. There is no eviction code to get wrong,
#    and this is the assertion that keeps it that way.
assert set(mod._github_memory.snapshot.pulls) == set(idx.chats)
smaller = mod.Index(chats={"fine": chat("fine")})
mod.Index.load = classmethod(lambda cls: smaller)
mod.github_pass()
snap2 = mod._github_memory.snapshot
assert set(snap2.pulls) == {"fine"}, set(snap2.pulls)
for gone in ("gone", "refused", "weird"):
    assert gone not in snap2.pulls
    assert gone not in snap2.unreachable
    assert gone not in snap2.no_remote

# 4. The publish is one whole object, so a reader can never see half a pass.
assert isinstance(snap2, mod.GitHubSnapshot)
wire = snap2.to_wire()
assert sorted(wire) == ["as_of", "no_remote", "unreachable"], sorted(wire)
assert wire["unreachable"] == [] and wire["no_remote"] == []

# 5. compare_to_stat: the parser, with no server at all.
#    `commits` must be ahead_by, NOT total_commits -- they agree below GitHub's
#    10,000-commit cap and only ahead_by stays exact above it, so a body where
#    the two DIFFER is the only way to assert this non-vacuously.
full = mod.compare_to_stat({
    "ahead_by": 3, "behind_by": 1, "total_commits": 99,
    "files": [{"additions": 40, "deletions": 5}, {"additions": 2, "deletions": 11}],
})
assert full == {"ahead": 3, "behind": 1, "commits": 3, "files": 2,
                "additions": 42, "deletions": 16, "truncated": False}, full

# `identical` is a real MEASUREMENT of zero, not an absence. It must return a
# dict; only a body we cannot read returns None.
same = mod.compare_to_stat({"status": "identical", "ahead_by": 0, "behind_by": 0, "files": []})
assert same is not None and same["files"] == 0 and same["additions"] == 0, same

# At the cap the counts become lower bounds, which is what `truncated` says.
# Asserting the exact sums is the point: a truncated block is an honest partial,
# never a guess and never a zero.
big = mod.compare_to_stat(
    {"ahead_by": 1, "behind_by": 0, "files": [{"additions": 1, "deletions": 2}] * mod.FILES_CAP})
assert big is not None and big["truncated"] is True, big
assert big["files"] == mod.FILES_CAP, big
assert big["additions"] == mod.FILES_CAP and big["deletions"] == 2 * mod.FILES_CAP, big

# Wrong-shaped bodies are None, never zeros. The 301 is real: GitHub answers a
# RENAMED repo with a JSON object, and read leniently it would arrive on a
# screen as "this branch changed nothing".
assert mod.compare_to_stat(["not", "a", "dict"]) is None
assert mod.compare_to_stat({"message": "Moved Permanently", "url": "x"}) is None
assert mod.compare_to_stat({"ahead_by": True, "behind_by": 0}) is None, "a bool passed as a count"
# A junk `files` entry is skipped and a junk count reads as 0, without raising.
mixed = mod.compare_to_stat(
    {"ahead_by": 0, "behind_by": 0, "files": ["nope", {"additions": "x", "deletions": 3}]})
assert mixed is not None and mixed["files"] == 1, mixed
assert mixed["additions"] == 0 and mixed["deletions"] == 3, mixed

# 6. compare_stat against a recorder, for the URL it builds and the refs it
#    refuses.
import http.server, threading  # noqa: E402


class Rec(http.server.BaseHTTPRequestHandler):
    paths = []
    answer = (200, b'{"ahead_by": 1, "behind_by": 0, "files": []}')
    repo_answer = (200, b'{"default_branch": "main"}')

    def do_GET(self):
        Rec.paths.append(self.path)
        status, body = Rec.repo_answer if "/compare/" not in self.path else Rec.answer
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Rec)
threading.Thread(target=srv.serve_forever, daemon=True).start()
mod.GH_API = "http://127.0.0.1:%d" % srv.server_address[1]
mod.GH_PAT = "pat-fixture"
# The real one back: section 1 replaced it to drive github_pass, and calling
# that stub here would assert against the fixture instead of the code.
mod.compare_stat = real_compare_stat


def tree(cid, branch="agent/x", base=""):
    return mod.Chat(id=cid, repo="r", title="t", port=1, branch=branch, base=base)


# The heads memo: two chats with no base on the SAME slug must resolve the
# default branch ONCE. Without it the stat costs two calls per chat, and eight
# chats on one repo ask the same question eight times -- this assertion is what
# keeps the documented cost model true.
Rec.paths.clear()
heads = {}
mod.compare_stat(tree("a"), "o/r", heads)
mod.compare_stat(tree("b"), "o/r", heads)
assert sum(1 for p in Rec.paths if "/compare/" not in p) == 1, Rec.paths

# An explicit base is percent-encoded with its slash intact, and per_page=1 is
# sent so GitHub does not ship a commits[] nobody reads.
Rec.paths.clear()
mod.compare_stat(tree("c", base="release/2.x"), "o/r", {})
assert Rec.paths == ["/repos/o/r/compare/release/2.x...agent/x?per_page=1"], Rec.paths

# INJECTION, both refs, PAIRED. `branch` is the one the existing code never
# validates -- Chat.from_wire takes whatever index.json holds, and this harness
# rewrites `branch` in it by hand. Zero requests is the assertion: a refusal
# that still sent the request would have refused too late.
for bad_chat in (tree("d", base="../../../user"), tree("e", branch="main\nX-Injected: 1")):
    Rec.paths.clear()
    try:
        mod.compare_stat(bad_chat, "o/r", {"o/r": "main"})
    except mod.GitHubError:
        pass
    else:
        raise AssertionError("an unusable ref reached the URL")
    assert Rec.paths == [], Rec.paths

# A base that could not be RESOLVED must raise, not 404. default_branch degrades
# to "" rather than raising, and an empty base would build `/compare/...agent/x`,
# draw the same 404, and be misreported as "never pushed".
Rec.paths.clear()
Rec.repo_answer = (403, b'{"message": "Resource not accessible"}')
try:
    mod.compare_stat(tree("f"), "o/r", {})
except mod.GitHubError:
    pass
else:
    raise AssertionError("an unresolvable base was not reported as a failure")
assert not [p for p in Rec.paths if "/compare/" in p], "it compared against an empty base"
Rec.repo_answer = (200, b'{"default_branch": "main"}')

# 404 is "never pushed" -- None, no raise. Any other error is a real failure.
Rec.answer = (404, b'{"message": "Not Found"}')
assert mod.compare_stat(tree("g"), "o/r", {"o/r": "main"}) is None
Rec.answer = (500, b'{"message": "boom"}')
try:
    mod.compare_stat(tree("h"), "o/r", {"o/r": "main"})
except mod.GitHubError:
    pass
else:
    raise AssertionError("a 500 was swallowed as 'never pushed'")
Rec.answer = (200, b'{"ahead_by": 1, "behind_by": 0, "files": []}')

# 7. A missing stat must not cost the row its pull requests: the two are
#    independent facts about one chat.
one = mod.Index(chats={"solo": chat("solo")})
mod.Index.load = classmethod(lambda cls: one)
mod.repo_slug = lambda c: "o/r"
mod.compare_stat = lambda c, s, h: None
mod.chat_pulls = lambda c: []
mod.github_pass()
snap3 = mod._github_memory.snapshot
assert "solo" not in snap3.stats, "a 404 compare produced a stat anyway"
assert snap3.pulls["solo"] == [], snap3.pulls
assert "solo" not in snap3.unreachable and "solo" not in snap3.no_remote

# 8. github_loop's net. reaper_loop's identical arm is uncovered today, so
#    without this one this would be too. `time` is replaced on the MODULE rather
#    than patching time.sleep globally, which would poison this process; and the
#    escape is KeyboardInterrupt, a BaseException, so the loop's own
#    `except Exception` cannot swallow the thing ending the test.
def boom_pass():
    raise RuntimeError("sweep exploded")


def stop_sleeping(_seconds):
    raise KeyboardInterrupt


mod.github_pass = boom_pass
mod.time = types.SimpleNamespace(time=time.time, sleep=stop_sleeping)
buf2 = io.StringIO()
try:
    with contextlib.redirect_stdout(buf2):
        mod.github_loop()
except KeyboardInterrupt:
    pass
else:
    raise AssertionError("github_loop returned instead of looping")
# It logged and kept going -- reaching sleep at all proves it did not die.
assert "github sweep failed: RuntimeError" in buf2.getvalue(), buf2.getvalue()
PY
if "${MANAGER_PY[@]}" "$WORK/preflight-github.py" "$REPO_ROOT/scripts/vps/code-agent-manager.py"
then
  ok "the sweep sorts every chat into exactly one of pulls/unreachable/no_remote"
  ok "a repo off the allowlist is 'no_remote' (settled), not 'unreachable' (retryable)"
  ok "the sweep stamps as_of before the walk, and evicts by rebuilding"
  ok "the sweep loop logs and survives a pass that raises, instead of dying"
else
  bad "github sweep dispositions / loop net (see the assertion above)"
fi

# ---- 1. auth ----------------------------------------------------------------
# shellcheck disable=SC2086
CODE="$($CURL -o /dev/null -w '%{http_code}' "$BASE/api/health" || echo 000)"
[ "$CODE" = "200" ] && ok "health authenticated (200)" || bad "health returned $CODE"
CODE="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "$BASE/api/health" || echo 000)"
[ "$CODE" = "401" ] && ok "unauthenticated refused (401)" || bad "unauth returned $CODE"

# ---- 2. allowlist + model guards --------------------------------------------
# shellcheck disable=SC2086
BODY="$($CURL -X POST -H 'Content-Type: application/json' \
  -d '{"repo":"not-listed","task":"x"}' "$BASE/api/chats")"
echo "$BODY" | grep -q "not in the allowlist" \
  && ok "unknown repo refused with a clear message" || bad "unknown repo: $BODY"
# shellcheck disable=SC2086
BODY="$($CURL -X POST -H 'Content-Type: application/json' \
  -d '{"repo":"testrepo","task":"x","model":"opencode/big-pickle"}' "$BASE/api/chats")"
echo "$BODY" | grep -q "zen-free" \
  && ok "zen-free model refused for a private repo" || bad "free-model guard: $BODY"

# ---- 3. create --------------------------------------------------------------
# shellcheck disable=SC2086
CHAT="$($CURL --max-time 120 -X POST -H 'Content-Type: application/json' \
  -d '{"repo":"testrepo","task":"tidy the README"}' "$BASE/api/chats")"
CID="$(echo "$CHAT" | jget "d.get('id','')")"
if [ -n "$CID" ]; then
  ok "chat created ($CID)"
  CD="$WORK/root/chats/$CID"
  git -C "$CD/workspace" rev-parse --abbrev-ref HEAD 2>/dev/null | grep -q "^agent/" \
    && ok "workspace cloned on an agent/ branch" || bad "branch: $(git -C "$CD/workspace" rev-parse --abbrev-ref HEAD 2>&1)"
  # RELEASE.md exists only on release/2.x, so its absence is what proves a
  # create with no base still behaves exactly as it always did.
  [ ! -f "$CD/workspace/RELEASE.md" ] \
    && ok "no base named: cloned from the repo's default HEAD" \
    || bad "a chat with no base was cut from release/2.x"
  [ "$(echo "$CHAT" | jget "d.get('base','MISSING')")" = "" ] \
    && ok "no base named: the chat records none" || bad "base leaked onto a default create"
  [ -f "$CD/workspace/setup-ran.marker" ] \
    && ok "repo setup command ran in the workspace" || bad "setup marker missing"
  grep -q '"opencode/deepseek-v4-flash"' "$CD/home/.config/opencode/opencode.json" 2>/dev/null \
    && ok "per-chat opencode config rendered (default model)" || bad "chat config missing/wrong"
  grep -q '"git push\*": "ask"' "$CD/home/.config/opencode/opencode.json" 2>/dev/null \
    && ok "push=ask policy in chat config" || bad "push policy missing"
  # stat's mode flag is not portable: -c %a is GNU, -f %A is BSD/macOS. This
  # asked only the GNU way, so on a Mac it returned nothing and the check has
  # been failing for a reason that had nothing to do with the file.
  perms() { stat -c %a "$1" 2>/dev/null || stat -f %A "$1" 2>/dev/null; }
  [ "$(perms "$CD/home/.local/share/opencode/auth.json")" = "600" ] \
    && ok "zen auth seeded (0600)" || bad "auth.json missing or wrong perms"
  git -C "$CD/workspace" config user.name | grep -q "code-agent" \
    && ok "distinct git identity configured" || bad "git identity not set"
else
  bad "chat create failed: $CHAT"
  echo "---- manager.log ----"; tail -20 "$WORK/manager.log"; exit 1
fi

# ---- 4. max-active cap (both chats running) ---------------------------------
# shellcheck disable=SC2086
B="$($CURL --max-time 120 -X POST -H 'Content-Type: application/json' \
  -d '{"repo":"throwaway","task":"scratch"}' "$BASE/api/chats")"
BID="$(echo "$B" | jget "d.get('id','')")"
[ -n "$BID" ] && ok "second chat created (throwaway repo)" || bad "second chat: $B"
grep -q '"git push\*": "allow"' "$WORK/root/chats/$BID/home/.config/opencode/opencode.json" 2>/dev/null \
  && ok "allow_push repo renders push=allow" || bad "allow_push override missing"
# The cap counts RUNNING chats, and this harness deliberately runs a fast
# reaper (IDLE_SECONDS=4, REAPER_INTERVAL=2) so section 6 can watch a spin-down
# happen. Those two facts race: on a loaded runner, more than 4s can pass
# between creating the first chat and getting here, the reaper spins it down,
# admission_count drops to 1, and the third create is admitted -- 201 instead
# of 409. Observed in CI, and it is exactly the kind of flake that makes a
# green build a coin toss.
#
# Wake anything the reaper took, so the refusal is tested against the state it
# is a claim about rather than against the clock. Waking is the honest fix
# here: raising IDLE_SECONDS would slow every run and weaken section 6.
for _cap_id in "$CID" "$BID"; do
  if [ "$(cstate "$_cap_id")" != "running" ]; then
    # shellcheck disable=SC2086
    $CURL --max-time 120 -X POST "$BASE/api/chats/$_cap_id/wake" >/dev/null
  fi
done
CAP_STATES="$(cstate "$CID")/$(cstate "$BID")"
# shellcheck disable=SC2086
CODE="$($CURL -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d '{"repo":"testrepo","task":"third"}' "$BASE/api/chats")"
[ "$CODE" = "409" ] && ok "max-active refusal (409) at the cap" \
  || bad "cap: got $CODE (both chats must be running for this to mean anything; states were $CAP_STATES)"
# shellcheck disable=SC2086
$CURL -X POST "$BASE/api/chats/$BID/stop" >/dev/null
[ "$(cstate "$BID")" = "exited" ] && ok "explicit stop" || bad "stop did not stop ($(cstate "$BID"))"
# shellcheck disable=SC2086
$CURL -X DELETE "$BASE/api/chats/$BID?purge=1" >/dev/null
[ ! -d "$WORK/root/chats/$BID" ] && ok "delete purges the volume" || bad "volume survived purge"

# ---- 5. proxy + session + SSE + blocking permission -------------------------
# shellcheck disable=SC2086
SESS="$($CURL -X POST "$BASE/chat/$CID/session?directory=/chat/workspace" \
  -H 'Content-Type: application/json' -d '{}')"
SID="$(echo "$SESS" | jget "d.get('id','')")"
[ -n "$SID" ] && ok "session created through the proxy" || bad "session create: $SESS"

# shellcheck disable=SC2086
$CURL -N --max-time 120 "$BASE/chat/$CID/event" > "$WORK/sse.log" 2>/dev/null &
SSE_PID=$!
# WAIT FOR THE SUBSCRIPTION, do not guess at it. The upstream emits
# server.connected the instant the stream attaches, so this is a real signal.
#
# This was `sleep 1`, and under load the prompt below raced ahead of the
# subscription: the client missed every event emitted before it attached --
# the deltas and the permission.updated -- while still catching session.idle
# afterwards. That is exactly the two-failure shape seen in CI ("SSE buffered"
# plus "no deltas in SSE", with session.idle passing in between), and it is a
# property of the test, not of the proxy it is meant to be testing.
SSE_UP="no"
for _ in $(seq 1 60); do
  grep -q 'server.connected' "$WORK/sse.log" 2>/dev/null && { SSE_UP="yes"; break; }
  sleep 0.25
done
[ "$SSE_UP" = "yes" ] && ok "SSE stream attached before the prompt was sent" \
  || bad "SSE stream never attached (no server.connected after 15s)"

# shellcheck disable=SC2086
CODE="$($CURL -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  -d '{"parts":[{"type":"text","text":"push the branch and open a pull request"}]}' \
  "$BASE/chat/$CID/session/$SID/prompt_async")"
[ "$CODE" = "204" ] && ok "prompt_async accepted (204)" || bad "prompt_async: $CODE"

PERM_ID=""
for _ in $(seq 1 20); do
  # shellcheck disable=SC2086
  PERM_ID="$($CURL "$BASE/chat/$CID/permission" | jget "d[0]['id'] if d else ''")"
  [ -n "$PERM_ID" ] && break
  sleep 0.5
done
[ -n "$PERM_ID" ] && ok "permission ask surfaced (git push)" || bad "no permission ask arrived"

# LIVE arrival: the turn is still blocked on the ask, so nothing has closed
# or flushed the upstream — the events so far (deltas, permission.updated)
# must already be in the client's stream. Catches proxy buffering.
#
# Polled rather than slept: a fixed wait either flakes or is slower than it
# needs to be, and this is usually satisfied in well under a second. The claim
# is unchanged because the ask stays parked -- nothing answers it until much
# later in this section -- and the assertion below proves that rather than
# assuming it.
SSE_LIVE="no"
for _ in $(seq 1 40); do
  grep -q "permission.updated" "$WORK/sse.log" && { SSE_LIVE="yes"; break; }
  sleep 0.25
done
[ "$SSE_LIVE" = "yes" ] \
  && ok "SSE events arrive live while the turn is still blocked" \
  || bad "SSE buffered — events not delivered until close (proxy must use read1)"
# The half that makes "while still blocked" a fact rather than an assumption.
# shellcheck disable=SC2086
STILL_PARKED="$($CURL "$BASE/chat/$CID/permission" | jget "d[0]['id'] if d else ''")"
[ "$STILL_PARKED" = "$PERM_ID" ] \
  && ok "the ask was still parked when the event arrived" \
  || bad "the turn unblocked before the liveness check (got '$STILL_PARKED')"

# THE aggregate assertion: while this chat is parked on an ask, /api/permissions
# must name it, tag it with its chat, and report the OTHER chat — which is
# stopped — in neither list, without going near it.
# shellcheck disable=SC2086
$CURL "$BASE/api/permissions" | CID="$CID" OTHER="$BID" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
mine = [p for p in d["permissions"] if p["chatId"] == os.environ["CID"]]
assert mine, f"the parked ask was not reported: {d}"
assert mine[0].get("id"), mine[0]
assert mine[0].get("title"), "the container object was not passed through verbatim"
other = os.environ.get("OTHER") or ""
if other:
    assert all(p["chatId"] != other for p in d["permissions"]), "a stopped chat reported an ask"
    assert other not in d["unreachable"], "a stopped chat was contacted"
' && ok "aggregate reports the parked ask and leaves stopped chats alone" \
  || bad "permission aggregate wrong"

# Busy guard: the idle timeout (4s) passes many times over while the turn is
# blocked on the ask — the reaper must NOT stop the container.
sleep 6
[ "$(cstate "$CID")" = "running" ] \
  && ok "busy chat survives the idle reaper (blocked on the ask)" \
  || bad "reaper stopped a busy chat"

# ---- 5ab. the phone gets buzzed about the ask, once ------------------------
# The ask has been parked for >6s, so the reaper has swept at least three times
# (CODE_AGENT_REAPER_INTERVAL=2). Exactly one notification must have gone out:
# the first pass announces it, and every pass after that must recognise the
# same ask id and stay quiet. Getting this wrong is not a cosmetic bug — it is
# a phone buzzing every sixty seconds until somebody answers.
[ "$(ntfy_count ask)" = "1" ] \
  && ok "a parked ask buzzes the phone exactly once, not once per reaper pass" \
  || bad "expected 1 ask notification, got $(ntfy_count ask)"

# And the payload. This is the assertion the whole channel rests on: the push
# leaves the tailnet and renders on a LOCKED screen, so it must carry a kind, an
# opaque handle and a count, and nothing else. Every field a designer reaches
# for first is contaminated — chatId embeds the repo name, title is the first 80
# characters of the raw prompt, and a bash ask's metadata is the shell command —
# so the test names those actual values and demands their absence.
python3 - "$NTFY_LOG" "$CID" "$AGENT_TOPIC" "$FAILURE_TOPIC" <<'EONTFY' \
  && ok "the notification payload is content-free (kind, handle, count)" \
  || bad "the notification carried content"
import json, sys
log, cid, agent_topic, failure_topic = sys.argv[1:5]
records = [json.loads(l) for l in open(log, encoding="utf-8") if l.strip()]
assert records, "nothing was sent to ntfy at all"
# Both channels are legitimate -- notify.sh posts operational failures to
# FAILURE_TOPIC -- so the allowlist is over both, and the content contract
# below is asserted over the AGENT channel, which is the one that renders on a
# locked screen. Asserting `topic == agent_topic` for every record (as this
# once did) breaks the moment any test exercises notify_failure.
for r in records:
    assert r["topic"] in (agent_topic, failure_topic), f"unknown topic: {r['topic']!r}"
agent_records = [r for r in records if r["topic"] == agent_topic]
assert agent_records, "nothing was sent to the agent channel"
for r in agent_records:
    assert r["topic"] != failure_topic, "the agent channel used the failure topic"
    assert "Email" not in r["headers"], "an Email header would burn the ~5/day cap"
    body = r["body"]
    assert isinstance(body, dict), f"body is not JSON: {body!r}"
    assert set(body) == {"kind", "handle", "count"}, f"extra fields on the wire: {sorted(body)}"
    assert body["kind"] in ("ask", "turn"), body["kind"]
    assert isinstance(body["count"], int) and body["count"] >= 1, body["count"]
    assert isinstance(body["handle"], str) and body["handle"], body["handle"]
    # The whole record, headers and all, against everything that must never
    # travel: this chat's id (which embeds "testrepo"), the repo names, the
    # task text that became the title, and the ask's own tool arguments.
    blob = json.dumps(r).lower()
    for secret in (cid.lower(), "testrepo", "throwaway", "ghrepo",
                   "tidy the readme", "push the branch", "git push",
                   "agent/", "release/2.x", "/chat/workspace"):
        assert secret not in blob, f"the payload leaked {secret!r}: {r}"
asks = [r for r in agent_records if r["body"]["kind"] == "ask"]
assert asks, "no ask notification"
assert asks[0]["headers"]["Priority"] == "high", asks[0]["headers"]
title = asks[0]["headers"]["Title"]
assert title == "A code agent is waiting on you", repr(title)
EONTFY

# ---- 5aa. a parked ask must not take the whole plane offline ----------------
# The other horn of the same fact. A blocked chat reports busy forever, so the
# reaper touches it on every pass and it can never go idle again — and if it
# still counted toward MAX_ACTIVE (2 here), two unanswered asks would mean no
# chat can be created and no chat can be woken, with the 409 telling you to
# "wait for idle spin-down" that provably will not come. CID is parked on an
# ask right now, so it must be exempt: BOTH creates below have to succeed, and
# the second is the one that used to be refused.
#
# The reaper has run at least three times during the sleep above, so
# _reaper_memory.blocked already names CID.
# shellcheck disable=SC2086
$CURL "$BASE/api/health" | python3 -c '
import json, sys
h = json.load(sys.stdin)
assert h["blocked"] >= 1, "a chat parked on an ask is not reported blocked: %r" % h
assert h["active"] >= h["blocked"], h
' && ok "health reports the blocked chat separately from active" || bad "health blocked field wrong"

# shellcheck disable=SC2086
CAP_A="$($CURL --max-time 120 -X POST -H 'Content-Type: application/json' \
  -d '{"repo":"throwaway","task":"first past the parked ask"}' "$BASE/api/chats")"
CAP_AID="$(echo "$CAP_A" | jget "d.get('id','')")"
# Immediately, before the 4s idle timeout can retire CAP_A and let this pass
# for the wrong reason.
# shellcheck disable=SC2086
CAP_B="$($CURL --max-time 120 -X POST -H 'Content-Type: application/json' \
  -d '{"repo":"throwaway","task":"second past the parked ask"}' "$BASE/api/chats")"
CAP_BID="$(echo "$CAP_B" | jget "d.get('id','')")"
[ -n "$CAP_AID" ] && [ -n "$CAP_BID" ] \
  && ok "a chat parked on an ask does not hold a MAX_ACTIVE slot" \
  || bad "the parked ask wedged the plane: A=$CAP_A B=$CAP_B"
for DEAD in "$CAP_AID" "$CAP_BID"; do
  # shellcheck disable=SC2086
  [ -n "$DEAD" ] && $CURL -X DELETE "$BASE/api/chats/$DEAD?purge=1" >/dev/null
done
# And the ask itself is untouched by any of that — the exemption must not have
# been bought by reaping the thing that is waiting on the reader.
[ "$(cstate "$CID")" = "running" ] \
  && ok "the parked ask survived the chats that overtook it" \
  || bad "the blocked chat was stopped to make room"

# shellcheck disable=SC2086
$CURL -X POST -H 'Content-Type: application/json' -d '{"response":"once"}' \
  "$BASE/chat/$CID/session/$SID/permissions/$PERM_ID" >/dev/null \
  && ok "permission answered (once)" || bad "permission reply failed"

IDLE_SEEN="no"
for _ in $(seq 1 20); do
  grep -q "session.idle" "$WORK/sse.log" && IDLE_SEEN="yes" && break
  sleep 0.5
done
[ "$IDLE_SEEN" = "yes" ] && ok "SSE streamed through the proxy to session.idle" \
  || bad "no session.idle on the SSE stream"
grep -q '"delta"' "$WORK/sse.log" \
  && ok "streamed deltas passed through the proxy" || bad "no deltas in SSE"
kill "$SSE_PID" 2>/dev/null || true

# ---- 5ac. the other edge: the turn that just ended --------------------------
# The chat was ARMED when the manager proxied the prompt above; the turn has now
# run to completion, so the next reaper sweep must fire "a turn ended" — once.
# Not a busy->idle edge: at a 60s cadence in production a turn that starts and
# finishes between two samples is never observed busy and would produce no edge
# at all, which is exactly the pocket case this feature exists for.
TURNS="0"
for _ in $(seq 1 30); do
  TURNS="$(ntfy_count turn)"
  [ "$TURNS" != "0" ] && break
  sleep 0.5
done
[ "$TURNS" = "1" ] && ok "the finished turn buzzes the phone" \
  || bad "expected 1 turn notification, got $TURNS"

# Three more reaper passes with nothing new happening. The chat is disarmed, so
# every one of them must stay silent — otherwise an idle chat buzzes forever.
sleep 6
[ "$(ntfy_count turn)" = "1" ] && [ "$(ntfy_count ask)" = "1" ] \
  && ok "later reaper passes do not re-fire either edge" \
  || bad "re-fired: turn=$(ntfy_count turn) ask=$(ntfy_count ask)"

# These may cross an idle spin-down (4s in test config) and wake the chat
# transparently — allow for the wake window.
# shellcheck disable=SC2086
$CURL --max-time 120 "$BASE/chat/$CID/session/$SID/message" | grep -q "pull/7" \
  && ok "PR flow completed (URL in transcript)" || bad "no PR URL in messages"
# The canned diff is multi-file on purpose, so assert on the shape a client
# has to cope with — a whole-file patch and a binary entry with no patch at
# all — rather than on one filename.
# The agent list is how a client discovers the modes a turn can run in. Only
# primary/all agents are selectable; a subagent must be present in the payload
# so a client that fails to filter it can be caught.
# shellcheck disable=SC2086
$CURL --max-time 120 "$BASE/chat/$CID/agent" | python3 -c '
import json, sys
agents = json.load(sys.stdin)
by_mode = {a["mode"] for a in agents}
assert {"primary", "subagent"} <= by_mode, f"need both primary and subagent, got {by_mode}"
assert any(not a["builtIn"] for a in agents), "no custom agent to test builtIn=false"
assert all("permission" in a for a in agents), "agent missing permission block"
' && ok "agent list proxied (primary + subagent)" || bad "agent list failed"

# The chat's own resolved config. The app asks for this because a chat created
# without an explicit model has none on its record and none on its session
# until a turn has been sent — this route is where the model it is ACTUALLY
# running comes from. The manager's /chat/<id>/... proxy is a catch-all, so
# this also proves passthrough for a sibling of /config/providers.
# shellcheck disable=SC2086
$CURL --max-time 120 "$BASE/chat/$CID/config" | python3 -c '
import json, sys
cfg = json.load(sys.stdin)
assert isinstance(cfg, dict), cfg
model = cfg.get("model")
assert isinstance(model, str) and model, "no model in the resolved config: " + repr(model)
assert "/" in model, "a model reference is provider/id: " + repr(model)
' && ok "the chat's resolved config proxies, naming the model it runs" \
  || bad "chat config route failed"

# shellcheck disable=SC2086
DIFF_JSON="$($CURL --max-time 120 "$BASE/chat/$CID/session/$SID/diff")"
echo "$DIFF_JSON" | python3 -c '
import json, sys
entries = json.load(sys.stdin)
assert len(entries) >= 4, f"expected a multi-file diff, got {len(entries)}"
assert any(len(e["patch"].splitlines()) > 1000 for e in entries), "no whole-file patch"
assert any(not e["patch"] for e in entries), "no binary entry"
assert {e["status"] for e in entries} >= {"added", "deleted", "modified"}, "missing a status"
' && ok "diff endpoint proxied (multi-file, whole-file patches)" || bad "diff failed"

# ---- 5aa. the permission aggregate ------------------------------------------
# The whole point of this route is that it reports asks WITHOUT waking
# anything. Asking each chat through the proxy would hold every container open
# and defeat the idle spin-down, so this asserts the aggregate sees the ask on
# the running chat and that a stopped chat is left alone.
# shellcheck disable=SC2086
$CURL "$BASE/api/permissions" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert isinstance(d.get("permissions"), list), d
assert isinstance(d.get("unreachable"), list), d
' && ok "permission aggregate answers in the contracted shape" || bad "aggregate shape wrong"

# ---- 5a. attachments --------------------------------------------------------
# A text attachment is not echoed back the way it was sent: OpenCode decodes
# it and persists two extra SYNTHETIC parts onto the user's own message. A
# client that renders every part shows two bubbles nobody typed, so the mock
# reproduces it and this asserts it is there to be defended against.
ATTACH_B64="$(printf '# notes\nsecond line' | base64 | tr -d '\n')"
# shellcheck disable=SC2086
$CURL --max-time 120 -X POST -H 'Content-Type: application/json' \
  -d "{\"parts\":[{\"type\":\"text\",\"text\":\"look at this\"},{\"type\":\"file\",\"mime\":\"text/plain\",\"filename\":\"notes.md\",\"url\":\"data:text/plain;base64,$ATTACH_B64\"}]}" \
  "$BASE/chat/$CID/session/$SID/prompt_async" > /dev/null
sleep 3
# shellcheck disable=SC2086
$CURL --max-time 120 "$BASE/chat/$CID/session/$SID/message" | python3 -c '
import json, sys
msgs = json.load(sys.stdin)
user = [m for m in msgs if m["info"]["role"] == "user"]
attached = [m for m in user if any(p.get("type") == "file" for p in m["parts"])]
assert attached, "the file part never came back on the user message"
parts = attached[-1]["parts"]
files = [p for p in parts if p.get("type") == "file"]
assert files[0]["filename"] == "notes.md", files[0]
assert files[0]["url"].startswith("data:text/plain;base64,"), files[0]["url"][:40]
synth = [p for p in parts if p.get("synthetic")]
assert len(synth) == 2, f"expected two synthetic parts, got {len(synth)}"
assert any("Read tool" in p.get("text", "") for p in synth), synth
assert any("second line" in p.get("text", "") for p in synth), "file body not inlined"
' && ok "a text attachment round-trips, with the synthetic expansion" \
  || bad "attachment round-trip failed"

# ---- 5ad. a turn you stopped yourself is not news ---------------------------
# On the wire an abort and a natural completion are byte-identical — the mock
# resolves the ask, discards the busy flag and publishes session.idle exactly
# the way a finished turn does. The only thing that can tell them apart is that
# the abort came through the manager's own proxy, so the manager disarms
# instead of firing. You were holding the phone; you do not need telling.
#
# The same block proves ask dedup is keyed on the ASK ID and not on the chat:
# this is a second push ask on a chat that has already had one announced, and
# it must buzz again.
ASKS_BEFORE="$(ntfy_count ask)"; TURNS_BEFORE="$(ntfy_count turn)"
# shellcheck disable=SC2086
$CURL --max-time 120 -X POST -H 'Content-Type: application/json' \
  -d '{"parts":[{"type":"text","text":"push it again"}]}' \
  "$BASE/chat/$CID/session/$SID/prompt_async" > /dev/null
SECOND_PERM=""
for _ in $(seq 1 20); do
  # shellcheck disable=SC2086
  SECOND_PERM="$($CURL "$BASE/chat/$CID/permission" | jget "d[0]['id'] if d else ''")"
  [ -n "$SECOND_PERM" ] && break
  sleep 0.5
done
# Give the reaper a sweep to notice the new ask before it is aborted away.
sleep 3
NEW_ASKS="$(ntfy_count ask)"
# shellcheck disable=SC2086
$CURL -X POST "$BASE/chat/$CID/session/$SID/abort" >/dev/null
sleep 6
[ "$NEW_ASKS" -gt "$ASKS_BEFORE" ] \
  && ok "a second ask on the same chat buzzes again (dedup is per ask id)" \
  || bad "the second ask was swallowed: $ASKS_BEFORE -> $NEW_ASKS"
[ "$(ntfy_count turn)" = "$TURNS_BEFORE" ] \
  && ok "an aborted turn does not buzz" \
  || bad "abort fired a turn notification: $TURNS_BEFORE -> $(ntfy_count turn)"

# ---- 5ae. the reaper's error nets and its row filters (in-process) ----------
# reaper_pass wraps three calls in `except Exception` precisely so a buzz can
# never cost a spin-down — this file has already shipped that failure once. The
# only way to prove those nets hold is to make the calls raise, which no live
# fixture can do. Same for the row filters: the running manager never produces a
# malformed ask row, and an ntfy server that answers 503 is not something
# fake-ntfy.py does.
cat >"$WORK/preflight-reaper.py" <<'PY'
import contextlib, http.server, importlib.util, io, sys, threading, time

spec = importlib.util.spec_from_file_location("cam", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["cam"] = mod
spec.loader.exec_module(mod)

real_post_ntfy = mod._post_ntfy

# Stub the notifier at the TOP. This fixture does NOT run under `env -i`, so a
# real NTFY_SERVER in the environment would otherwise send live traffic.
fired = []
mod.notify_agent = lambda kind, count, chats: fired.append((kind, count, sorted(chats)))
mod._post_ntfy = lambda *a, **k: None


def chat(cid, probe=False):
    return mod.Chat(id=cid, repo="r", title="t", port=1, branch="b", probe=probe,
                    last_active=time.time())


# 1. notify_new_asks drops malformed rows, probe chats and unknown chats.
idx = mod.Index(chats={"real": chat("real"), "probe1": chat("probe1", probe=True)})
mod._reaper_memory.seen_asks.clear()
fired.clear()
mod.notify_new_asks(
    idx,
    [
        {"chatId": 5, "id": "a"},           # chatId is not a str
        {"chatId": "real", "id": ""},       # empty ask id
        {"chatId": "real", "id": "a1"},     # the one real row
        {"chatId": "probe1", "id": "p1"},   # a probe chat: nobody's pocket
        {"chatId": "gone", "id": "g1"},     # not in the index at all
    ],
    [],
    frozenset({"real", "probe1"}),
)
assert fired == [("ask", 1, ["real"])], fired
# The skip happens BEFORE seen.setdefault, so a skipped chat must leave no
# memory behind. Asserting absence from seen_asks is a real consequence; merely
# asserting the buzz count would pass even if the rows had been remembered.
assert "probe1" not in mod._reaper_memory.seen_asks, dict(mod._reaper_memory.seen_asks)
assert "gone" not in mod._reaper_memory.seen_asks, dict(mod._reaper_memory.seen_asks)

# 2. notify_finished_turns forgets arms whose chat is deleted or not running.
now = time.time()
stale = now - (mod.ARM_SETTLE_SECONDS + 10)
mod._reaper_memory.armed.clear()
mod._reaper_memory.armed.update({"deleted": stale, "notrun": stale, "real": stale})
idx2 = mod.Index(chats={"real": chat("real"), "notrun": chat("notrun")})
mod._reaper_memory.prev_running = frozenset({"real"})
fired.clear()
mod.notify_finished_turns(idx2, {"real": "idle"}, frozenset({"real"}), now)
assert fired == [("turn", 1, ["real"])], fired
assert "deleted" not in mod._reaper_memory.armed, dict(mod._reaper_memory.armed)
assert "notrun" not in mod._reaper_memory.armed, dict(mod._reaper_memory.armed)

# 3. reaper_pass, PASS 1: the ask probe raises. The spin-down must still run and
#    notify_new_asks must be SKIPPED -- feeding it an empty map would revoke
#    every blocked chat's MAX_ACTIVE exemption on a fan-out hiccup.
idx3 = mod.Index(chats={"c1": chat("c1"), "c2": chat("c2")})
mod.Index.load = classmethod(lambda cls: idx3)
mod.container_state = lambda cid: "running"
mod.session_state = lambda c: "idle"


def boom(*a, **k):
    raise RuntimeError("probe exploded")


calls = []
mod.spin_down_idle = lambda *a: calls.append("spin")
mod.pending_permissions = boom
mod.notify_new_asks = lambda *a: calls.append("asks")
mod.notify_finished_turns = lambda *a: calls.append("turns")
mod._reaper_memory.prev_running = frozenset()
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    mod.reaper_pass()
out = buf.getvalue()
assert "reaper ask probe failed: RuntimeError" in out, out
assert calls == ["spin", "turns"], calls
assert mod._reaper_memory.prev_running == frozenset({"c1", "c2"})

# 4. PASS 2: both notifiers raise; the pass still finishes and still records
#    prev_running. The prev_running RESET below is mandatory -- PASS 1 already
#    left it at exactly this value, so without the reset the assertion is
#    vacuous rather than evidence that line 1492 was reached.
mod._reaper_memory.prev_running = frozenset()
calls2 = []
mod.spin_down_idle = lambda *a: calls2.append("spin")
mod.pending_permissions = lambda chats: ([], [])


def boom_asks(*a):
    raise RuntimeError("asks exploded")


def boom_turns(*a):
    raise RuntimeError("turns exploded")


mod.notify_new_asks = boom_asks
mod.notify_finished_turns = boom_turns
buf2 = io.StringIO()
with contextlib.redirect_stdout(buf2):
    mod.reaper_pass()
out2 = buf2.getvalue()
assert "reaper notify failed (asks): RuntimeError" in out2, out2
assert "reaper notify failed (turns): RuntimeError" in out2, out2
assert calls2 == ["spin"], calls2
assert mod._reaper_memory.prev_running == frozenset({"c1", "c2"})


# 5. an ntfy server that ANSWERS, with a 4xx/5xx. Distinct from "lost".
class Ntfy(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        # Drain the body FIRST. This is REQUIRED, not hygiene: answering and
        # closing with an unread body still in the receive queue emits RST,
        # http.client raises ConnectionResetError inside _post_ntfy's try, and
        # the "lost" arm runs instead of the "refused" one -- the test would go
        # red for entirely the wrong reason. fake-ntfy.py reads the body for
        # exactly this reason.
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        self.send_response(503)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *a):
        pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Ntfy)
threading.Thread(target=srv.serve_forever, daemon=True).start()
mod.NTFY_SERVER = "http://127.0.0.1:%d" % srv.server_address[1]
mod.NTFY_AGENT_TOPIC = "t-fixture"
mod._post_ntfy = real_post_ntfy
buf3 = io.StringIO()
with contextlib.redirect_stdout(buf3):
    # Called directly, on THIS thread: notify_agent posts on a daemon thread and
    # the assertion would race it.
    mod._post_ntfy("turn", "T", "default", '{"kind":"turn"}')
assert "agent notification refused (turn): HTTP 503" in buf3.getvalue(), buf3.getvalue()

# 6. arm_from_proxy refuses to arm a probe chat or a rejected prompt.
mod._reaper_memory.armed.clear()
mod.arm_from_proxy(chat("probechat", probe=True), "/session/s/prompt", 200)
mod.arm_from_proxy(chat("rejected"), "/session/s/prompt", 400)
mod.arm_from_proxy(chat("accepted"), "/session/s/prompt", 200)
assert list(mod._reaper_memory.armed) == ["accepted"], dict(mod._reaper_memory.armed)
PY
if "${MANAGER_PY[@]}" "$WORK/preflight-reaper.py" "$REPO_ROOT/scripts/vps/code-agent-manager.py"
then
  ok "notify_new_asks drops malformed rows, probe chats and deleted chats without remembering them"
  ok "notify_finished_turns forgets arms whose chat vanished or stopped"
  ok "a raising ask probe still spins down, and skips the ask buzz rather than emptying it"
  ok "both notifiers can raise and the pass still completes and records prev_running"
  ok "an ntfy server that answers 5xx is 'refused', not 'lost'"
  ok "arm_from_proxy arms neither a probe chat nor a rejected prompt"
else
  bad "reaper error nets / row filters (see the assertion above)"
fi

# ---- 5b. pull requests ------------------------------------------------------
# These are GitHub calls the MANAGER makes. They must never proxy into the
# container, so they must work against a chat whose branch is the fixture's
# and must not count as chat activity.
PR_CHAT="$(echo "$CHAT" | jget "d.get('id','')")"
python3 - "$WORK/root" "$PR_CHAT" <<'EOP'
import json, sys, pathlib
# Point the chat at the branch the fake GitHub has pull requests for.
index = pathlib.Path(sys.argv[1]) / "index.json"
data = json.loads(index.read_text())
data["chats"][sys.argv[2]]["branch"] = "agent/testrepo-fixture"
index.write_text(json.dumps(data))
EOP
# shellcheck disable=SC2086
PULLS="$($CURL "$BASE/api/chats/$PR_CHAT/pulls")"
echo "$PULLS" | python3 -c '
import json, sys
pulls = json.load(sys.stdin)["pulls"]
got = {p["number"]: p for p in pulls}
assert 7 not in got, "listed a pull request from another branch"
assert set(got) == {12, 11, 10, 9, 8, 6, 5}, f"wrong set: {sorted(got)}"
assert got[12]["mergeable"] is True, "mergeable lost — the detail call is missing"
assert got[12]["checks"] == "passing", got[12]["checks"]
assert got[11]["checks"] == "failing", got[11]["checks"]
assert got[10]["mergeable"] is None, "null mergeable was coerced"
assert got[10]["checks"] == "pending", got[10]["checks"]
assert got[9]["draft"] is True
assert got[8]["state"] == "merged", got[8]["state"]
' && ok "pulls listed for this branch only, with mergeable and checks" \
  || bad "pulls payload wrong: $PULLS"

# The four size counts ride the detail form the manager already fetches for
# `mergeable`. They are what the app draws a diffstat from, so a row that
# loses them renders a 300-line rewrite exactly like a typo fix.
echo "$PULLS" | python3 -c '
import json, sys
got = {p["number"]: p for p in json.load(sys.stdin)["pulls"]}
assert got[12]["commits"] == 1, got[12]
assert got[12]["additions"] == 84, got[12]
assert got[12]["changed_files"] == 4, got[12]
# An honest zero is a measurement, not a missing field: it has to arrive.
assert got[12]["deletions"] == 0, "a real zero was dropped as if absent"
assert got[11]["commits"] == 4, got[11]
assert got[11]["additions"] == 77, got[11]
assert got[11]["deletions"] == 33, got[11]
assert got[11]["changed_files"] == 3, got[11]
' && ok "pull size counts survive the detail call" || bad "pull counts wrong: $PULLS"

# ---- 5b2. the same pulls, served from the sweep's cache ----------------------
# BEFORE the merge tests on purpose: a merge mutates the fake's fixture state,
# and a byte-identity assertion taken after one would race the sweep.
if wait_sweeps 2; then
  # shellcheck disable=SC2086
  ALL_PULLS="$($CURL "$BASE/api/pulls")"
  printf '%s' "$ALL_PULLS" > "$WORK/all-pulls.json"
  printf '%s' "$PULLS" > "$WORK/one-pulls.json"
  # THE assertion for this feature. The sweep calls chat_pulls() unmodified, so
  # the cached rows must be identical to the interactive route's; anything else
  # means the cache is not serving what it claims to be serving.
  if python3 - "$WORK/all-pulls.json" "$WORK/one-pulls.json" "$PR_CHAT" <<'PY'
import json, sys
allp = json.load(open(sys.argv[1]))
onep = json.load(open(sys.argv[2]))
cached = allp["pulls"][sys.argv[3]]
live = onep["pulls"]
by_number = lambda rows: sorted(rows, key=lambda r: r["number"])
assert by_number(cached) == by_number(live), (len(cached), len(live))
assert allp["as_of"] > 0, "the cache served a cold snapshot"
PY
  then
    ok "/api/pulls serves rows identical to the per-chat route, from cache"
  else
    bad "the cached pulls differ from the interactive route's"
  fi

  # shellcheck disable=SC2086
  CHATS_NOW="$($CURL "$BASE/api/chats")"
  printf '%s' "$CHATS_NOW" > "$WORK/chats-now.json"
  if python3 - "$WORK/all-pulls.json" "$WORK/chats-now.json" <<'PY'
import json, sys
allp = json.load(open(sys.argv[1]))
ids = {c["id"] for c in json.load(open(sys.argv[2]))["chats"]}
buckets = set(allp["pulls"]) | set(allp["unreachable"]) | set(allp["no_remote"])
assert allp["unreachable"] == [], allp["unreachable"]
assert allp["no_remote"] == [], allp["no_remote"]
# Every chat is accounted for: named in a bucket, never silently dropped.
assert ids <= buckets, sorted(ids - buckets)
PY
  then
    ok "every chat is named in exactly one of pulls/unreachable/no_remote"
  else
    bad "the sweep left a chat in no disposition at all"
  fi

  # THE COST PROPERTY, measured independently of request count. An inline
  # implementation scales with requests; a cache does not. The two deltas must
  # be EQUAL, not zero -- at INTERVAL=2 under coverage, 40 requests will not
  # reliably fit inside one sweep tick, and asserting zero would be exactly the
  # timing flake this harness documents elsewhere.
  CALLS0="$(curl -sS "http://127.0.0.1:$GH_PORT/__calls" | jget "d['calls']")"
  # shellcheck disable=SC2086
  for _ in $(seq 1 10); do $CURL -o /dev/null "$BASE/api/pulls"; done
  CALLS1="$(curl -sS "http://127.0.0.1:$GH_PORT/__calls" | jget "d['calls']")"
  # shellcheck disable=SC2086
  for _ in $(seq 1 30); do $CURL -o /dev/null "$BASE/api/pulls"; done
  CALLS2="$(curl -sS "http://127.0.0.1:$GH_PORT/__calls" | jget "d['calls']")"
  # Subtract the two counter reads themselves from each window.
  D1=$(( CALLS1 - CALLS0 - 1 )); D2=$(( CALLS2 - CALLS1 - 1 ))
  if [ "$D1" -eq "$D2" ]; then
    ok "30 reads of /api/pulls cost the same GitHub calls as 10 — it is a cache"
  else
    bad "GitHub calls scaled with requests: 10 reads cost $D1, 30 cost $D2"
  fi

  # ---- the change stat, on the same cached snapshot -------------------------
  if python3 - "$WORK/chats-now.json" "$PR_CHAT" <<'PY'
import json, sys
chats = json.load(open(sys.argv[1]))
rows = {c["id"]: c for c in chats["chats"]}
stat = rows[sys.argv[2]].get("stat")
assert stat is not None, "the chat on the fixture branch has no stat"
# The fake answers ahead_by=3 with total_commits=99: `commits` must follow
# ahead_by, or a row contradicts its own ahead count.
assert stat["ahead"] == 3 and stat["commits"] == 3, stat
assert stat["behind"] == 0, stat
# Three files with distinct counts, so a client that sums them wrong fails.
assert stat["files"] == 3, stat
assert stat["additions"] == 49, stat
assert stat["deletions"] == 16, stat
assert stat["truncated"] is False, stat
assert chats["github"]["as_of"] > 0, chats["github"]
# The ABSENCE half -- an unpushed branch carrying no stat rather than zeros --
# is asserted in section 5d under `nocompare`, where it can be produced on
# demand. Only one chat exists at this point in the run, so there is no
# never-pushed sibling here to check it against.
PY
  then
    ok "a pushed branch carries an exact stat; an unpushed one carries none at all"
  else
    bad "the change stat is wrong or leaked zeros onto an unpushed branch"
  fi
fi

# shellcheck disable=SC2086
BODY="$($CURL -X POST -H 'Content-Type: application/json' -d '{}' \
  "$BASE/api/chats/$PR_CHAT/pulls/7/merge")"
echo "$BODY" | grep -q "not from this chat" \
  && ok "merging another branch's pull request is refused" || bad "cross-branch merge: $BODY"

# shellcheck disable=SC2086
BODY="$($CURL -X POST -H 'Content-Type: application/json' -d '{}' \
  "$BASE/api/chats/$PR_CHAT/pulls/9/merge")"
echo "$BODY" | grep -q "still a draft" \
  && ok "merging a draft is refused" || bad "draft merge: $BODY"

# shellcheck disable=SC2086
BODY="$($CURL -X POST -H 'Content-Type: application/json' -d '{}' \
  "$BASE/api/chats/$PR_CHAT/pulls/10/merge")"
echo "$BODY" | grep -q "not finished computing" \
  && ok "merging an uncomputed pull request is refused" || bad "null-mergeable merge: $BODY"

# shellcheck disable=SC2086
BODY="$($CURL -X POST -H 'Content-Type: application/json' -d '{}' \
  "$BASE/api/chats/$PR_CHAT/pulls/12/merge")"
echo "$BODY" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d.get("merged") is True, d
assert d.get("sha"), "no sha"
assert d.get("pull", {}).get("state") == "merged", d.get("pull")
' && ok "merge succeeds and returns the re-read pull" || bad "merge: $BODY"

# shellcheck disable=SC2086
BODY="$($CURL "$BASE/api/chats/does-not-exist/pulls")"
echo "$BODY" | grep -q "unknown chat" \
  && ok "pulls for an unknown chat is a clean 404" || bad "unknown chat: $BODY"

# The degradation paths, which are the ones that fail silently if they are
# wrong. Restart the fake GitHub misbehaving on purpose.
restart_github() {
  kill "$GITHUB_PID" 2>/dev/null || true
  sleep 0.4
  # The branches file has to be here too: miss it and every mode after this
  # point silently falls back to the fake's five-branch built-in list, which
  # fails the count assertions for a reason that is not the manager's.
  FAKE_GITHUB_BRANCH="agent/testrepo-fixture" FAKE_GITHUB_MODE="$1" \
    FAKE_GITHUB_BRANCHES_FILE="$WORK/branches.txt" \
    python3 "$HERE/fake-github.py" --port "$GH_PORT" &
  GITHUB_PID=$!
  for _ in $(seq 1 20); do
    curl -sS -o /dev/null "http://127.0.0.1:$GH_PORT/repos/testowner/testrepo/pulls" && break
    sleep 0.3
  done
}

# The documented PAT carries neither Checks:read nor Commit statuses:read, so
# a private repo answers 403 there. That must degrade one field, not the route.
restart_github noscope
# shellcheck disable=SC2086
PULLS="$($CURL "$BASE/api/chats/$PR_CHAT/pulls")"
echo "$PULLS" | python3 -c '
import json, sys
pulls = json.load(sys.stdin)["pulls"]
assert pulls, "the list itself failed when only the check scopes were missing"
assert all(p["checks"] == "unknown" for p in pulls), [p["checks"] for p in pulls]
assert any(p["mergeable"] is True for p in pulls), "mergeable lost with checks"
' && ok "missing check scopes degrade checks, not the list" || bad "noscope: $PULLS"

# The other degradation on the same route: the per-pull detail call fails and
# the list entry is all the manager has. Everything only the detail carries
# must then be ABSENT — sending `0` would tell the app the branch changed
# nothing, and the app has no way to disbelieve a number it was sent.
restart_github nodetail
# shellcheck disable=SC2086
PULLS="$($CURL "$BASE/api/chats/$PR_CHAT/pulls")"
echo "$PULLS" | python3 -c '
import json, sys
pulls = json.load(sys.stdin)["pulls"]
assert pulls, "the list itself failed when only the detail call did"
assert all(p["mergeable"] is None for p in pulls), [p["mergeable"] for p in pulls]
for p in pulls:
    for key in ("commits", "additions", "deletions", "changed_files"):
        assert key not in p, ("invented with no detail form", key, p)
assert all(p["title"] for p in pulls), "the row lost more than the detail fields"
' && ok "a failed detail call omits the counts rather than zeroing them" \
  || bad "nodetail: $PULLS"

# A lost compare must cost the tree its STAT and nothing else. This is the
# absence half of the stat contract, produced on demand: `allow_push` defaults
# to false, so "never pushed" is the dominant steady state for a real tree, and
# a row rendered as "0 files changed" rather than "unknown" would lie about most
# of them.
restart_github nocompare
if wait_sweeps 2; then
  # shellcheck disable=SC2086
  $CURL "$BASE/api/chats" > "$WORK/chats-nocompare.json"
  # shellcheck disable=SC2086
  $CURL "$BASE/api/pulls" > "$WORK/pulls-nocompare.json"
  if python3 - "$WORK/chats-nocompare.json" "$WORK/pulls-nocompare.json" "$PR_CHAT" <<'PY'
import json, sys
rows = {c["id"]: c for c in json.load(open(sys.argv[1]))["chats"]}
allp = json.load(open(sys.argv[2]))
cid = sys.argv[3]
assert "stat" not in rows[cid], rows[cid].get("stat")
# NOT a failure: a 404 compare is an answer, so the chat stays out of both
# failure buckets and keeps everything else it had.
assert cid not in allp["unreachable"], allp["unreachable"]
assert cid not in allp["no_remote"], allp["no_remote"]
assert len(allp["pulls"][cid]) == 7, len(allp["pulls"][cid])
PY
  then
    ok "a branch with no compare loses its stat and keeps its pull requests"
  else
    bad "nocompare: the lost stat took the row's pulls or its disposition with it"
  fi
fi
restart_github ""

# GitHub says 405 for branch protection; the app wants one "GitHub said no"
# case carrying GitHub's own sentence.
restart_github blocked
# shellcheck disable=SC2086
CODE="$($CURL -o /tmp/merge-blocked.$$ -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' -d '{}' \
  "$BASE/api/chats/$PR_CHAT/pulls/11/merge")"
BODY="$(cat /tmp/merge-blocked.$$; rm -f /tmp/merge-blocked.$$)"
[ "$CODE" = "422" ] && echo "$BODY" | grep -q "approving review" \
  && ok "a blocked merge is 422 carrying GitHub's sentence" \
  || bad "blocked merge: $CODE $BODY"

# Unreachable GitHub must be a clean 502, not a stack trace.
restart_github down
# shellcheck disable=SC2086
CODE="$($CURL -o /tmp/pulls-down.$$ -w '%{http_code}' "$BASE/api/chats/$PR_CHAT/pulls")"
BODY="$(cat /tmp/pulls-down.$$; rm -f /tmp/pulls-down.$$)"
[ "$CODE" = "502" ] && echo "$BODY" | grep -q "unreachable" \
  && ok "unreachable GitHub is a clean 502" || bad "github down: $CODE $BODY"
restart_github ""

# ---- 5c. base branches ------------------------------------------------------
# The app's new-session sheet offers a base branch, so the manager must be able
# to say what the branches ARE and to cut a chat from one. Both are
# manager-side GitHub calls: nothing here goes near a container.

# shellcheck disable=SC2086
chat_count() { $CURL "$BASE/api/chats" | jget "len(d['chats'])"; }
chat_dirs() { find "$WORK/root/chats" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '; }

# shellcheck disable=SC2086
BR="$($CURL "$BASE/api/repos/testrepo/branches")"
echo "$BR" | EXPECTED="$EXPECTED" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
names = [b["name"] for b in d["branches"]]
want = int(os.environ["EXPECTED"])
assert d["default"] == "main", "default branch not reported: " + repr(d.get("default"))
assert names[0] == "main", "the default is not first: " + repr(names[:3])
assert d["branches"][0]["default"] is True, d["branches"][0]
assert sum(1 for b in d["branches"] if b["default"]) == 1, "default marked more than once"
assert names[1:] == sorted(names[1:], key=str.lower), "not sorted: " + repr(names[1:5])
assert "release/2.x" in names, names[:8]
assert len(names) == want, "got %d branches, expected %d" % (len(names), want)
assert "zzz-last-branch" in names, "the tail past per_page=100 was dropped"
assert d["truncated"] is False, d["truncated"]
' && ok "branches listed, paginated, default first and marked" || bad "branches: $BR"

# shellcheck disable=SC2086
[ "$($CURL "$BASE/api/repos/ghrepo/branches" | jget "d['slug']")" = "testowner/testrepo" ] \
  && ok "the GitHub slug comes from the allowlist URL, not the repo's name" \
  || bad "slug derivation wrong"

# shellcheck disable=SC2086
CODE="$($CURL -o "$WORK/br-unlisted.json" -w '%{http_code}' "$BASE/api/repos/not-listed/branches")"
[ "$CODE" = "403" ] && grep -q "not in the allowlist" "$WORK/br-unlisted.json" \
  && ok "branches for an unlisted repo are refused (403)" || bad "unlisted: $CODE"

# --- creating on a base
# shellcheck disable=SC2086
BASED="$($CURL --max-time 120 -X POST -H 'Content-Type: application/json' \
  -d '{"repo":"testrepo","task":"work the release line","base":"release/2.x"}' \
  "$BASE/api/chats")"
BBID="$(echo "$BASED" | jget "d.get('id','')")"
if [ -n "$BBID" ]; then
  ok "chat created on a base branch ($BBID)"
  BWS="$WORK/root/chats/$BBID/workspace"
  # RELEASE.md exists only on release/2.x: this is the assertion that the base
  # reached the clone rather than merely being parsed.
  [ -f "$BWS/RELEASE.md" ] && ok "the branch was cut from the base, not the default HEAD" \
    || bad "RELEASE.md missing — the clone ignored base"
  git -C "$BWS" rev-parse --abbrev-ref HEAD | grep -q "^agent/" \
    && ok "still on its own agent/ branch after basing" \
    || bad "HEAD is $(git -C "$BWS" rev-parse --abbrev-ref HEAD 2>&1)"
  [ "$(echo "$BASED" | jget "d.get('base','')")" = "release/2.x" ] \
    && ok "the base is echoed on the created chat" || bad "base not echoed: $BASED"
  # shellcheck disable=SC2086
  $CURL "$BASE/api/chats" | BBID="$BBID" python3 -c '
import json, os, sys
row = {c["id"]: c for c in json.load(sys.stdin)["chats"]}[os.environ["BBID"]]
assert row["base"] == "release/2.x", row
' && ok "the base survives into the chat index" || bad "base missing from /api/chats"
  # shellcheck disable=SC2086
  $CURL -X DELETE "$BASE/api/chats/$BBID?purge=1" >/dev/null
else
  bad "create with a base failed: $BASED"
fi

# --- refusals build nothing
BEFORE="$(chat_count)"; BEFORE_DIRS="$(chat_dirs)"
# shellcheck disable=SC2086
CODE="$($CURL -o "$WORK/base-unknown.json" -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  -d '{"repo":"testrepo","task":"x","base":"no-such-branch"}' "$BASE/api/chats")"
[ "$CODE" = "400" ] && grep -q "does not exist" "$WORK/base-unknown.json" \
  && ok "an unknown base is a clean 400 with a readable message" \
  || bad "unknown base: $CODE $(cat "$WORK/base-unknown.json")"
[ "$(chat_count)" = "$BEFORE" ] && [ "$(chat_dirs)" = "$BEFORE_DIRS" ] \
  && ok "a refused base builds nothing (no index entry, no volume)" \
  || bad "the refusal left residue behind"

# A malformed base must be refused on SHAPE, before any GitHub call — the
# message differs from the existence refusal precisely so this can tell them
# apart. `../../etc` reaching the URL builder would come back as "does not
# exist" instead.
SHAPE_OK="yes"
for BADBASE in '../../etc' 'main..evil' '-b' 'main branch' 'main\nX-Injected: 1'; do
  # shellcheck disable=SC2086
  BODY="$($CURL -X POST -H 'Content-Type: application/json' \
    -d "{\"repo\":\"testrepo\",\"task\":\"x\",\"base\":\"$BADBASE\"}" "$BASE/api/chats")"
  echo "$BODY" | grep -q "not a valid branch name" || { SHAPE_OK="no"; echo "  ($BADBASE -> $BODY)"; }
done
[ "$SHAPE_OK" = "yes" ] && ok "a malformed base is refused on shape, before any GitHub call" \
  || bad "a malformed base reached the network"

# --- 403 degrades
restart_github denied
# shellcheck disable=SC2086
CODE="$($CURL -o "$WORK/br-denied.json" -w '%{http_code}' "$BASE/api/repos/testrepo/branches")"
[ "$CODE" = "502" ] && grep -q "PAT" "$WORK/br-denied.json" \
  && ok "a 403 from GitHub is a clean 502 body, not a crash" || bad "denied branches: $CODE"
# shellcheck disable=SC2086
CODE="$($CURL -o "$WORK/base-denied.json" -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  -d '{"repo":"testrepo","task":"x","base":"release/2.x"}' "$BASE/api/chats")"
[ "$CODE" = "502" ] && grep -q "could not check base branch" "$WORK/base-denied.json" \
  && ok "an unverifiable base refuses instead of half-building" || bad "denied base: $CODE"
# And the default create path must not have acquired a dependency on GitHub.
# shellcheck disable=SC2086
PLAIN="$($CURL --max-time 120 -X POST -H 'Content-Type: application/json' \
  -d '{"repo":"testrepo","task":"no base needed"}' "$BASE/api/chats")"
PCID="$(echo "$PLAIN" | jget "d.get('id','')")"
if [ -n "$PCID" ]; then
  ok "creating without a base still works while GitHub refuses everything"
  # shellcheck disable=SC2086
  $CURL -X DELETE "$BASE/api/chats/$PCID?purge=1" >/dev/null
else
  bad "GitHub refusing broke the default create path: $PLAIN"
fi

restart_github nodefault
# shellcheck disable=SC2086
$CURL "$BASE/api/repos/testrepo/branches" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["branches"], "the whole list was lost when only the default-branch call failed"
assert d["default"] == "", d["default"]
assert not any(b["default"] for b in d["branches"]), "a branch was marked default with none known"
' && ok "losing the default-branch call costs the label, not the list" || bad "nodefault degraded badly"

restart_github ""
# shellcheck disable=SC2086
[ "$($CURL "$BASE/api/repos/testrepo/branches" | jget "len(d['branches'])")" = "$EXPECTED" ] \
  && ok "the branch list recovers once GitHub answers again" || bad "no recovery after the outage"

# ---- 5d. what the manager says when GitHub misbehaves -----------------------
# gh() has a careful error vocabulary -- 5xx and unparseable bodies both become
# "GitHub is unreachable", a 4xx keeps GitHub's own sentence, and a 4xx with no
# sentence falls back to the status code -- and none of those arms had ever
# run, because the fake had only ever answered well-formed JSON.
#
# Same for the three merge refusals with no fixture. #8 is closed AND merged,
# and merge_chat_pull tests merged_at first, so #8 can only reach the "already
# merged" arm; "is closed" needs a pull closed WITHOUT being merged (#6), and
# the conflict arm needs mergeable:false (#5).

merge_body() { # merge_body <pull-number>
  # shellcheck disable=SC2086
  $CURL -X POST "$BASE/api/chats/$PR_CHAT/pulls/$1/merge"
}
merge_code() { # merge_code <pull-number>
  # shellcheck disable=SC2086
  $CURL -o /dev/null -w '%{http_code}' -X POST "$BASE/api/chats/$PR_CHAT/pulls/$1/merge"
}

case "$(merge_body 8)" in *"already merged"*) ok "merging an already-merged pull is refused" ;;
  *) bad "merge #8: $(merge_body 8)" ;; esac
case "$(merge_body 6)" in *"is closed"*) ok "merging a closed pull is refused" ;;
  *) bad "merge #6: $(merge_body 6)" ;; esac
case "$(merge_body 5)" in *"conflicts with main"*) ok "a conflicting pull is refused by name" ;;
  *) bad "merge #5: $(merge_body 5)" ;; esac

restart_github serverfail
CODE="$(merge_code 12)"
[ "$CODE" = "502" ] && ok "a 5xx from GitHub becomes 502, not a crash" \
  || bad "serverfail merge: HTTP $CODE"

restart_github notjson
# shellcheck disable=SC2086
CODE="$($CURL -o /dev/null -w '%{http_code}' "$BASE/api/chats/$PR_CHAT/pulls")"
[ "$CODE" = "502" ] && ok "a 200 with an unparseable body becomes 502" \
  || bad "notjson pulls: HTTP $CODE"

restart_github nomessage
BODY="$(merge_body 12)"
case "$BODY" in *"GitHub answered 422"*) ok "a 4xx with no message falls back to the status" ;;
  *) bad "nomessage merge: $BODY" ;; esac

restart_github detailbad
CODE="$(merge_code 12)"
[ "$CODE" = "502" ] && ok "a pull detail that is not an object is refused, not crashed" \
  || bad "detailbad merge: HTTP $CODE"

# summarise_checks: "none" and "pending" are distinct answers and neither had a
# fixture. "pending with nothing behind it" is GitHub saying nothing has
# reported, which must not read as "something is running".
checks_for_12() {
  # shellcheck disable=SC2086
  $CURL "$BASE/api/chats/$PR_CHAT/pulls" \
    | jget "next((p['checks'] for p in d['pulls'] if p['number'] == 12), 'missing')"
}
restart_github nochecks
[ "$(checks_for_12)" = "none" ] && ok "no runs and no statuses summarises as none" \
  || bad "nochecks: $(checks_for_12)"
restart_github pendingonly
# "none", NOT "pending", and that is the point: a combined state of pending
# with no statuses behind it is GitHub saying nothing has reported yet, which
# must not render as "something is running". The two modes agree on the answer
# and disagree on the route taken to it -- pendingonly is the arm where the
# state is non-empty and the `or combined.get("statuses")` short-circuit is
# what rejects it.
[ "$(checks_for_12)" = "none" ] && ok "a bare pending status is 'nothing reported', not 'running'" \
  || bad "pendingonly: $(checks_for_12)"
restart_github ""

# ---- 6. idle spin-down + wake with state intact -----------------------------
STOPPED="no"
for _ in $(seq 1 15); do
  if [ "$(cstate "$CID")" = "exited" ]; then STOPPED="yes"; break; fi
  sleep 1
done
[ "$STOPPED" = "yes" ] && ok "idle chat spun down automatically" || bad "no idle spin-down"

# Any request wakes it; sessions must have survived (state in the volume).
# shellcheck disable=SC2086
WOKE="$($CURL --max-time 120 "$BASE/chat/$CID/session")"
if echo "$WOKE" | grep -q "$SID"; then
  ok "wake-on-request with sessions intact"
else
  bad "wake/state: $(echo "$WOKE" | head -c 200)"
  echo "---- stub logs ----"; tail -5 "$WORK"/stub/*.log 2>/dev/null
fi

# ---- 7. explicit wake endpoint + delete -------------------------------------
# shellcheck disable=SC2086
$CURL -X POST "$BASE/api/chats/$CID/stop" >/dev/null
# shellcheck disable=SC2086
CODE="$($CURL --max-time 120 -o /dev/null -w '%{http_code}' -X POST "$BASE/api/chats/$CID/wake")"
[ "$CODE" = "200" ] && [ "$(cstate "$CID")" = "running" ] \
  && ok "explicit wake endpoint" || bad "wake endpoint: HTTP $CODE, state $(cstate "$CID")"

# Waking a chat that is ALREADY running — the one path the rest of this file
# never takes, because every other wake here is preceded by a stop, so only the
# stopped branch was ever exercised. That is why the self-deadlock in
# wake_chat's running branch survived: it held the non-reentrant `_lock` and
# called touch(), which re-acquires it, parking the request thread forever while
# it still owned the lock and wedging the proxy, every later wake, create,
# delete and the reaper for the life of the process.
#
# The second assertion is the one that matters. The first request can only fail
# by timing out, and a timeout is precisely what leaves `_lock` orphaned — so
# "is the gateway still serving afterwards" is the actual claim.
# shellcheck disable=SC2086
CODE="$($CURL --max-time 10 -o /dev/null -w '%{http_code}' -X POST "$BASE/api/chats/$CID/wake" || echo 000)"
[ "$CODE" = "200" ] \
  && ok "wake on an already-running chat returns" \
  || bad "redundant wake: HTTP $CODE (000 = timed out holding _lock)"
# shellcheck disable=SC2086
CODE="$($CURL --max-time 10 -o /dev/null -w '%{http_code}' "$BASE/chat/$CID/session" || echo 000)"
[ "$CODE" = "200" ] \
  && ok "gateway still serving after a redundant wake" \
  || bad "gateway wedged after redundant wake: HTTP $CODE"

# shellcheck disable=SC2086
$CURL -X DELETE "$BASE/api/chats/$CID?purge=1" >/dev/null
[ ! -d "$WORK/root/chats/$CID" ] && ok "final delete purges" || bad "final purge failed"

# ---- 7b. wake_chat's refusal arms (in-process) ------------------------------
# Reaching these over HTTP means arranging a full cap, a container that starts
# but never answers, and an engine that raises — the last two are not states the
# stub engine can be put into, and the "did not answer" arm costs a real
# WAIT_FOR_CHAT_SECONDS (90s, not env-tunable) end to end. In-process they cost
# nothing.
cat >"$WORK/preflight-wake.py" <<'PY'
import importlib.util, sys, tempfile, time
from pathlib import Path

spec = importlib.util.spec_from_file_location("cam", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["cam"] = mod
spec.loader.exec_module(mod)

tmp = Path(tempfile.mkdtemp())
mod.INDEX_PATH = tmp / "index.json"
mod._reaper_memory.blocked = frozenset()

started = []
mod.engine = lambda *a, **k: started.append(list(a))
mod.run_container = lambda c: started.append(["run", c.id])
mod.notify_failure = lambda m: None


def chat(cid):
    return mod.Chat(id=cid, repo="r", title="t", port=1, branch="b", last_active=time.time())


# 1. the cap is full. wait_for_chat MUST be stubbed even though this arm should
#    never reach it: if the 409 guard regressed, the fall-through would poll a
#    dead port for a real 90s and turn a clear failure into a hang.
mod.Index(chats={c: chat(c) for c in ("sleeper", "busy1", "busy2")}).save()
mod.container_state = lambda cid: "stopped" if cid == "sleeper" else "running"
mod.wait_for_chat = lambda port: True
code, msg = mod.wake_chat("sleeper")
assert code == 409, (code, msg)
assert "already active" in msg, msg
# The discriminator: the fall-through would have called engine("start").
assert started == [], started

# 2. the container starts but opencode never answers.
mod.Index(chats={"lonely": chat("lonely")}).save()
mod.container_state = lambda cid: "stopped"
mod.wait_for_chat = lambda port: False
started.clear()
code, msg = mod.wake_chat("lonely")
assert code == 502, (code, msg)
assert msg == "chat container started but opencode did not answer", msg
assert started == [["start", mod.container_name("lonely")]], started

# 3. the engine itself raises. RESET wait_for_chat first -- block 2 left it
#    returning False, and without the reset this takes block 2's arm instead and
#    silently stops testing the exception net.
mod.wait_for_chat = lambda port: True
told = []
mod.notify_failure = lambda m: told.append(m)


def engine_boom(*a, **k):
    raise OSError("engine is broken")


mod.engine = engine_boom
code, msg = mod.wake_chat("lonely")
# `told` is the discriminator, not the status: block 2 also returns 502.
assert told == ["chat wake failed (lonely)"], told
assert code == 502 and msg.startswith("wake failed:"), (code, msg)

# 4. touch() on a chat that is no longer in the index writes nothing at all.
mod.INDEX_PATH.unlink()
mod.touch("gone")
assert not mod.INDEX_PATH.exists(), "touch wrote an index for a chat that does not exist"

# ...and touch CAN write, so the assertion above is evidence rather than an
# artefact of a broken fixture.
mod.Index(chats={"present": chat("present")}).save()
before = mod.Index.load().chats["present"].last_active
time.sleep(0.01)
mod.touch("present")
assert mod.Index.load().chats["present"].last_active > before
PY
if "${MANAGER_PY[@]}" "$WORK/preflight-wake.py" "$REPO_ROOT/scripts/vps/code-agent-manager.py"
then
  ok "a full cap refuses the wake with 409 and starts nothing"
  ok "a container that starts but never answers is a 502, not a hang"
  ok "an engine that raises is a 502 and buzzes a failure"
  ok "touch() on a deleted chat writes nothing, and still writes for a live one"
else
  bad "wake_chat refusal arms (see the assertion above)"
fi

# ---- 8. the request surface nothing has ever sent -------------------------
# Everything above drives the happy path of a chat's life. This section is the
# rest of the HTTP surface: the routes, refusals and malformed inputs the
# gateway ships and no test has ever issued. Ordered so the destructive cases
# (rewriting repos.json and index.json) come last -- the manager rewrites
# index.json on its next save and would otherwise eat the harness's own state.
#
# JSON bodies go through --data-binary @file, never inline -d with escaped
# quotes: inline bodies word-split under the unquoted $CURL idiom and silently
# send garbage, which reads as a passing 400 for entirely the wrong reason.

# 8a. GET /api/repos -- the allowlist round-trip. RepoEntry.to_wire() and its
# only caller have never run.
# shellcheck disable=SC2086
REPOS_JSON="$($CURL "$BASE/api/repos")"
NAMES="$(printf '%s' "$REPOS_JSON" | jget 'sorted(r["name"] for r in d["repos"])' 2>/dev/null || echo err)"
[ "$NAMES" = "['ghrepo', 'testrepo', 'throwaway']" ] \
  && ok "GET /api/repos returns the allowlist" \
  || bad "GET /api/repos: $NAMES"

# 8b. the 404 fallthrough, once per verb, so do_PUT/do_PATCH are proved to
# reach dispatch rather than merely being defined. The body names the verb, so
# asserting on it is the difference between coverage and a real claim.
for verb in GET PUT PATCH; do
  # shellcheck disable=SC2086
  BODY="$($CURL -X "$verb" "$BASE/api/nope")"
  WANT="no route: $verb /api/nope"
  case "$BODY" in
    *"$WANT"*) ok "404 fallthrough names the verb ($verb)" ;;
    *) bad "404 fallthrough for $verb: $BODY" ;;
  esac
done
# A path that MATCHES a route regex but with a verb it does not serve.
# shellcheck disable=SC2086
CODE="$($CURL -o /dev/null -w '%{http_code}' -X DELETE "$BASE/api/chats/nosuch/pulls")"
[ "$CODE" = "404" ] || [ "$CODE" = "405" ] \
  && ok "DELETE on the pulls route is refused (HTTP $CODE)" \
  || bad "DELETE /api/chats/x/pulls: HTTP $CODE"

# 8c. an Authorization header that is not decodable base64. The auth path has
# only ever seen a correct header or none at all.
CODE="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
  -H 'Authorization: Basic !!!not-base64!!!' "$BASE/api/health")"
[ "$CODE" = "401" ] && ok "malformed Basic credentials are rejected" \
  || bad "malformed Basic auth: HTTP $CODE"

# 8d. create-body validation: both arms, distinguished by their messages.
printf 'not json at all' > "$WORK/bad-body.json"
# shellcheck disable=SC2086
BODY="$($CURL -X POST --data-binary @"$WORK/bad-body.json" "$BASE/api/chats")"
case "$BODY" in *"invalid JSON body"*) ok "create rejects invalid JSON" ;;
  *) bad "create with invalid JSON: $BODY" ;; esac
printf '[]' > "$WORK/list-body.json"
# shellcheck disable=SC2086
BODY="$($CURL -X POST --data-binary @"$WORK/list-body.json" "$BASE/api/chats")"
case "$BODY" in *"must be a JSON object"*) ok "create rejects a non-object body" ;;
  *) bad "create with a JSON list: $BODY" ;; esac

# 8e/8f. unknown chat ids, on the proxy and on the lifecycle route.
# shellcheck disable=SC2086
CODE="$($CURL -o /dev/null -w '%{http_code}' "$BASE/chat/nosuchchat/session")"
[ "$CODE" = "404" ] && ok "proxy to an unknown chat is 404" || bad "proxy unknown chat: HTTP $CODE"
# shellcheck disable=SC2086
CODE="$($CURL -o /dev/null -w '%{http_code}' -X POST "$BASE/api/chats/nosuchchat/wake")"
[ "$CODE" = "404" ] && ok "wake on an unknown chat is 404" || bad "wake unknown chat: HTTP $CODE"

# 8g. DELETE without ?purge=1 -- the default. Every delete in this file so far
# has purged, so the branch that KEEPS the volume has never run, and "your work
# survives a delete" is the more consequential half of that promise.
printf '{"repo":"throwaway","task":"kept-volume"}' > "$WORK/keep-body.json"
# shellcheck disable=SC2086
KEEP_ID="$($CURL -X POST --data-binary @"$WORK/keep-body.json" "$BASE/api/chats" | jget 'd["id"]')"
if [ -n "$KEEP_ID" ] && [ -d "$WORK/root/chats/$KEEP_ID" ]; then
  # shellcheck disable=SC2086
  VOL="$($CURL -X DELETE "$BASE/api/chats/$KEEP_ID" | jget 'd["volume"]')"
  [ "$VOL" = "kept" ] && [ -d "$WORK/root/chats/$KEEP_ID" ] \
    && ok "delete without purge keeps the volume on disk" \
    || bad "non-purge delete: volume=$VOL, dir present=$([ -d "$WORK/root/chats/$KEEP_ID" ] && echo yes || echo no)"
else
  bad "could not create a chat for the non-purge delete case"
fi

# 8h. slug_of's refusals. Every fixture so far is either file:// or a full
# https owner/name, so only the happy arm has run. repos.json is re-read on
# every request (load_repos has no cache), so swapping it is safe and
# reversible -- restore it before anything else runs.
cp "$WORK/root/repos.json" "$WORK/repos.json.bak"
cat > "$WORK/root/repos.json" <<'EOJSON'
{"repos": [
  {"name": "emptyurl", "url": "", "tier": 1, "setup": "",
   "edit_only": true, "allow_push": false, "public_throwaway": false},
  {"name": "scpstyle", "url": "git@github.com:testowner/testrepo.git", "tier": 1, "setup": "",
   "edit_only": true, "allow_push": false, "public_throwaway": false},
  {"name": "onepart", "url": "https://github.com/justowner", "tier": 1, "setup": "",
   "edit_only": true, "allow_push": false, "public_throwaway": false}
]}
EOJSON
for r in emptyurl onepart; do
  # shellcheck disable=SC2086
  CODE="$($CURL -o /dev/null -w '%{http_code}' "$BASE/api/repos/$r/branches")"
  [ "$CODE" = "409" ] && ok "unusable repo URL is refused ($r -> 409)" \
    || bad "branches for $r: HTTP $CODE (want 409)"
done
# scp-style IS parseable -- it must resolve, not refuse. The fake serves it.
# shellcheck disable=SC2086
CODE="$($CURL -o /dev/null -w '%{http_code}' "$BASE/api/repos/scpstyle/branches")"
[ "$CODE" = "200" ] && ok "scp-style git remote parses to owner/name" \
  || bad "scp-style remote: HTTP $CODE (want 200)"
cp "$WORK/repos.json.bak" "$WORK/root/repos.json"

# 8h2. The create rollback -- the largest single block of untested code in the
# manager, and the one that decides whether a failed create leaves a half-built
# chat behind. Nothing had ever failed a clone, because stub-engine always
# succeeds, so none of it had run: not the index removal, not the container
# force-remove, not the rmtree, not the failure notification.
touch "$WORK/fail-oneshot"
printf '{"repo":"testrepo","task":"this create will fail"}' > "$WORK/fail-body.json"
# shellcheck disable=SC2086
FAIL_CODE="$($CURL -o "$WORK/fail-resp.json" -w '%{http_code}' \
  -X POST --data-binary @"$WORK/fail-body.json" "$BASE/api/chats")"
rm -f "$WORK/fail-oneshot"
LEAKED="$(python3 - "$WORK/root" <<'EOP'
import json, pathlib, sys
idx = json.loads((pathlib.Path(sys.argv[1]) / "index.json").read_text())
print(sum(1 for c in idx.get("chats", {}).values() if c.get("title") == "this create will fail"))
EOP
)"
[ "$FAIL_CODE" = "502" ] && [ "$LEAKED" = "0" ] \
  && ok "a failed create rolls back: 502, and no index entry survives" \
  || bad "create rollback: HTTP $FAIL_CODE, leaked index entries $LEAKED"
# The rollback also has to TELL someone. This is why the ntfy assertion above
# allowlists both topics rather than demanding the agent channel.
if grep -q "chat create failed" "$NTFY_LOG" 2>/dev/null; then
  ok "a failed create raises an operational alert"
else
  bad "no failure notification for a failed create"
fi

# 8i. LAST, because they corrupt the manager's own state files. A gateway that
# 500s on a hand-edited index.json is a gateway you cannot recover by hand.
printf 'this is not json' > "$WORK/root/repos.json"
# shellcheck disable=SC2086
CODE="$($CURL -o /dev/null -w '%{http_code}' "$BASE/api/repos")"
[ "$CODE" = "200" ] && ok "a corrupt repos.json degrades to an empty allowlist" \
  || bad "corrupt repos.json: HTTP $CODE"
printf '{"chats": "not a dict"}' > "$WORK/root/index.json"
# shellcheck disable=SC2086
CODE="$($CURL -o /dev/null -w '%{http_code}' "$BASE/api/health")"
[ "$CODE" = "200" ] && ok "a malformed index.json degrades to no chats" \
  || bad "malformed index.json: HTTP $CODE"

# ---- 8j. routes addressed to a chat that does not exist ---------------------
# Every existing merge names $PR_CHAT and every existing DELETE names a live
# chat, so both "unknown chat" guards have never fired.
#
# BOTH conjuncts below are mandatory. A mistyped URL falls through to
# handle_any's "no route: ..." which is ALSO a 404 — so the status alone is
# exactly the vacuous assertion this repo has shipped twice. The body is what
# distinguishes "the guard fired" from "the router never matched".
# shellcheck disable=SC2086
CODE="$($CURL -o "$WORK/merge404.json" -w '%{http_code}' -X POST \
  "$BASE/api/chats/nosuchchat/pulls/1/merge" || echo 000)"
if [ "$CODE" = "404" ] && grep -q 'unknown chat' "$WORK/merge404.json"; then
  ok "merging on an unknown chat is 404 'unknown chat', not 'no route'"
else
  bad "merge on unknown chat: got $CODE $(cat "$WORK/merge404.json" 2>/dev/null)"
fi
# shellcheck disable=SC2086
CODE="$($CURL -o "$WORK/del404.json" -w '%{http_code}' -X DELETE \
  "$BASE/api/chats/nosuchchat" || echo 000)"
if [ "$CODE" = "404" ] && grep -q 'unknown chat' "$WORK/del404.json"; then
  ok "deleting an unknown chat is 404 'unknown chat', and pops nothing"
else
  bad "delete unknown chat: got $CODE $(cat "$WORK/del404.json" 2>/dev/null)"
fi

# ---- 8k. a declared body larger than the manager will hold -------------------
# A declared Content-Length is an instruction to allocate that much, so
# read_body refuses one over MAX_BODY_BYTES (32 MB) BEFORE reading a byte. Only
# reachable with a raw socket: curl would have to actually send 64 MB.
if python3 - "$PORT" "$PASS" <<'PY'
import base64, socket, sys

port, pw = int(sys.argv[1]), sys.argv[2]
auth = base64.b64encode(f"opencode:{pw}".encode()).decode()
s = socket.create_connection(("127.0.0.1", port), timeout=10)
# Declare 64 MB and send ZERO body bytes. Zero is deliberate: with an unsent
# body the server's receive queue is empty at close, so there is no RST to turn
# this into a connection error instead of the 413 under test.
s.sendall(
    b"POST /api/chats HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    + f"Authorization: Basic {auth}\r\n".encode()
    + b"Content-Length: 67108864\r\nConnection: close\r\n\r\n"
)
# Read to EOF. send_json writes headers and body as two separate socket writes,
# so a single recv() can return the status line without the phrase -- a
# coin-flip false failure that would look like a real one.
buf = b""
while True:
    chunk = s.recv(8192)
    if not chunk:
        break
    buf += chunk
s.close()
assert buf.startswith(b"HTTP/1.1 413"), buf[:120]
assert b"request body is larger than" in buf, buf[:400]
PY
then
  ok "a declared body over the cap is refused 413 before a byte is read"
else
  bad "oversized Content-Length was not refused with 413"
fi

# ---- 9. startup, which the long-lived instance cannot reach ----------------
# Everything above runs against ONE manager, started once with a good
# configuration. main()'s guards therefore never execute, and neither does the
# TLS branch -- the harness deliberately points CODE_AGENT_TLS_CERT at a path
# that does not exist, so the configuration PRODUCTION ACTUALLY RUNS has never
# once been started under test. These are sub-second launches, each with its
# own root and port, each reaped before the next.
#
# They go through "${MANAGER_PY[@]}" like the main instance, so their coverage
# counts; --parallel-mode unions the data files.

SHIMS="$WORK/shims"; mkdir -p "$SHIMS"
AUX_ROOT="$WORK/aux"

# launch_aux <name> <expect-exit> <env-assignments...> -- runs the manager to
# completion (these all exit on their own) and captures its log.
launch_aux() {
  local name="$1" want="$2"; shift 2
  local logf="$WORK/aux-$name.log" rc=0
  rm -rf "$AUX_ROOT"; mkdir -p "$AUX_ROOT"
  env -i PATH="$PATH" HOME="$HOME" CODE_AGENT_ROOT="$AUX_ROOT" "$@" \
    "${MANAGER_PY[@]}" "$REPO_ROOT/scripts/vps/code-agent-manager.py" \
    >"$logf" 2>&1 || rc=$?
  [ "$rc" = "$want" ] || echo "      (exit $rc, wanted $want; log: $logf)"
  [ "$rc" = "$want" ]
}

# 9a. No password. The one refusal that must never be soft: an unauthenticated
# code plane is remote code execution for anyone on the tailnet.
if launch_aux nopass 1 OPENCODE_SERVER_PASSWORD= CODE_AGENT_BIND=127.0.0.1 \
   && grep -q "FATAL: OPENCODE_SERVER_PASSWORD is empty" "$WORK/aux-nopass.log"; then
  ok "an empty password is fatal at startup, not a warning"
else
  bad "empty-password guard"
fi

# 9b. Password set, but no PAT, no repos.json and no tailnet: both warnings,
# then the deliberate nonzero exit that makes systemd's Restart=always the
# wait-for-the-tailnet loop. `tailscale` is shimmed to exit 1 -- the real one
# lives on PATH on this Mac, and finding it would give the manager an address
# and change the outcome.
printf '#!/bin/sh\nexit 1\n' > "$SHIMS/tailscale"; chmod +x "$SHIMS/tailscale"
if launch_aux notailnet 1 OPENCODE_SERVER_PASSWORD=x GITHUB_CODE_AGENT_PAT= \
     PATH="$SHIMS:$PATH" \
   && grep -q "WARNING: GITHUB_CODE_AGENT_PAT is empty" "$WORK/aux-notailnet.log" \
   && grep -q "missing — the allowlist is empty" "$WORK/aux-notailnet.log" \
   && grep -q "no Tailscale IPv4 yet — exiting for systemd to retry" "$WORK/aux-notailnet.log"; then
  ok "no PAT, no allowlist and no tailnet: two warnings, then exit for systemd"
else
  bad "startup warnings / tailnet retry exit"
fi

# 9c. tailnet_ip's success arm, and its empty-output arm. Without a shim the
# only way to reach either is to be on a tailnet.
printf '#!/bin/sh\necho 100.64.0.9\n' > "$SHIMS/tailscale"; chmod +x "$SHIMS/tailscale"
# It resolves an address, gets past the host guard, and then fails to BIND it
# (100.64.0.9 is not a local interface) -- which is itself the proof that the
# address came from the shim and was used.
launch_aux tsok 1 OPENCODE_SERVER_PASSWORD=x PATH="$SHIMS:$PATH" >/dev/null 2>&1 || true
if grep -qE "Cannot assign requested address|Traceback" "$WORK/aux-tsok.log" \
   && ! grep -q "no Tailscale IPv4 yet" "$WORK/aux-tsok.log"; then
  ok "tailnet_ip returns the address tailscale printed"
else
  bad "tailnet_ip success arm (log: $WORK/aux-tsok.log)"
fi
printf '#!/bin/sh\nexit 0\n' > "$SHIMS/tailscale"; chmod +x "$SHIMS/tailscale"
if launch_aux tsempty 1 OPENCODE_SERVER_PASSWORD=x PATH="$SHIMS:$PATH" \
   && grep -q "no Tailscale IPv4 yet" "$WORK/aux-tsempty.log"; then
  ok "tailscale answering with no address is treated as no tailnet"
else
  bad "tailnet_ip empty-output arm"
fi
rm -f "$SHIMS/tailscale"

# 9d. TLS. This is the configuration the brain actually runs and it has never
# been started under test: the main instance points TLS at nonexistent paths on
# purpose, so `have_tls` has only ever been False and the wrap_socket branch has
# never executed.
TLS_PORT=$((PORT + 11))
if openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
     -keyout "$WORK/tls-key.pem" -out "$WORK/tls-cert.pem" \
     -subj /CN=localhost >/dev/null 2>&1; then
  rm -rf "$AUX_ROOT"; mkdir -p "$AUX_ROOT"
  env -i PATH="$PATH" HOME="$HOME" CODE_AGENT_ROOT="$AUX_ROOT" \
    OPENCODE_SERVER_PASSWORD="$PASS" CODE_AGENT_BIND=127.0.0.1 \
    CODE_AGENT_PORT="$TLS_PORT" CODE_AGENT_ENGINE="$HERE/stub-engine.sh" \
    CODE_AGENT_TLS_CERT="$WORK/tls-cert.pem" CODE_AGENT_TLS_KEY="$WORK/tls-key.pem" \
    "${MANAGER_PY[@]}" "$REPO_ROOT/scripts/vps/code-agent-manager.py" \
    >"$WORK/aux-tls.log" 2>&1 &
  TLS_PID=$!
  for _ in $(seq 1 40); do
    curl -sk --max-time 2 -o /dev/null "https://127.0.0.1:$TLS_PORT/api/health" && break
    sleep 0.25
  done
  TLS_CODE="$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' \
    -u "opencode:$PASS" "https://127.0.0.1:$TLS_PORT/api/health" || echo 000)"
  PLAIN_WARN="no"
  grep -q "serving PLAIN HTTP" "$WORK/aux-tls.log" && PLAIN_WARN="yes"
  kill "$TLS_PID" 2>/dev/null || true; wait "$TLS_PID" 2>/dev/null || true
  [ "$TLS_CODE" = "200" ] && [ "$PLAIN_WARN" = "no" ] \
    && ok "serves HTTPS when a cert is present, with no plain-HTTP warning" \
    || bad "TLS launch: HTTP $TLS_CODE, plain-http-warning=$PLAIN_WARN"
else
  echo "SKIP  TLS launch — openssl unavailable"
fi

echo
echo "== summary: $PASS_COUNT passed, $FAIL_COUNT failed =="
if [ "$FAIL_COUNT" -ne 0 ]; then
  echo "---- manager.log (tail) ----"; tail -30 "$WORK/manager.log"
  exit 1
fi
