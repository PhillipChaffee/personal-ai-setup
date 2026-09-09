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
# The per-chat container port band. The manager allocates chat ports from its
# index rather than from the OS, so two runs sharing a base both try to bind the
# same port for their first chat.
#
# EVERY PORT THIS HARNESS BINDS DERIVES FROM $PORT, so one override moves all of
# them and several worktrees can run this at once. That sentence used to be here
# and was FALSE: GH_PORT was a bare 4398 (see the fake-github block below), so a
# second run at a different PORT still collided on it -- and fake-github binds it
# twice, once at start-up and once for the mid-run restarts, so the symptom was
# three unrelated pull-request assertions failing plus a JSON traceback. Issue
# #118 is the general version of this; this is the one line of it that this file
# owns. The map, so a new fixture picks a free offset instead of guessing:
#     PORT-2  ntfy         PORT-1  fake-github   PORT     the manager
#     PORT+11 TLS          PORT+12..13 9e sweep  PORT+14  9f's own manager
#     PORT+15..17 9f chats PORT+18..19 waitfor   PORT+20  the chat band
BASE_CHAT_PORT="${BASE_CHAT_PORT:-$((PORT + 20))}"
PASS="test-secret-$$"
BASE="http://127.0.0.1:$PORT"
CURL="curl -sS --max-time 30 -u opencode:$PASS"

PASS_COUNT=0; FAIL_COUNT=0
ok()  { echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
bad() { echo "FAIL  $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
jget() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }
cstate() { STUB_ENGINE_STATE="$WORK/stub" "$HERE/stub-engine.sh" container inspect --format '{{.State.Status}}' "code-agent-$1" 2>/dev/null || echo absent; }
# What the ENGINE was actually handed for a chat's container, read back out of
# the stub's state dir. This is the harness's `podman inspect`: it reports what
# was baked in at create, which is the only thing a later `start` will reuse.
# The value is never derived here from the manager's own code -- the point is to
# see what crossed the process boundary.
cfield() { python3 -c '
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]])' \
  "$WORK/stub/code-agent-$1.json" "$2"; }

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
# A standalone mock-opencode-server used by section 4b. Declared here, with the
# others, because a fixture that outlives a failed run holds a port and turns
# the NEXT run's unrelated assertions red -- the confusion this file's PORT
# comment already warns about.
WF_PID=""
# Section 9f's second manager, which serves for real (unlike the other aux
# launches, which exit on their own) and so has to be reaped like this one.
ROT_PID=""
cleanup() {
  [ -n "$MANAGER_PID" ] && kill "$MANAGER_PID" 2>/dev/null || true
  [ -n "$GITHUB_PID" ] && kill "$GITHUB_PID" 2>/dev/null || true
  [ -n "$NTFY_PID" ] && kill "$NTFY_PID" 2>/dev/null || true
  [ -n "$WF_PID" ] && kill "$WF_PID" 2>/dev/null || true
  [ -n "$ROT_PID" ] && kill "$ROT_PID" 2>/dev/null || true
  # Both stub state dirs: 9f's containers are mock servers holding ports too,
  # and a run that failed before its assertions would otherwise leave them up.
  for pid in "$WORK"/stub/*.pid "$WORK"/rot-stub/*.pid; do
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
#
# DERIVED FROM $PORT, not a literal. It was `4398` and that was the one port in
# this file a single PORT override did not move, which quietly cost the
# concurrency the header claims. PORT-1 keeps the default byte-identical
# (4399-1 == 4398) so no existing invocation changes.
GH_PORT="${GH_PORT:-$((PORT - 1))}"
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
  # SAY WHAT IS PROVEN, NOT WHAT WOULD BE NICE. The oracle drives handle_any and
  # the route_* methods and asserts every dispatch site in their BYTECODE fired,
  # so a literal path, a prefix test or an inline send_json inside them is caught
  # (four fixtures feed each one in). Two escapes are known and NOT covered:
  # routing inside a do_<VERB> body (the five one-line bodies today just call
  # handle_any, and the oracle never sees a comparison made before that call),
  # and a non-route_* helper that handle_any delegates to. Both were reproduced
  # against the real manager and both swept clean. Neither is an idiom this file
  # uses, so the gate holds today -- but a green line that claimed the whole
  # dispatcher would be the exact overclaim this harness exists to prevent.
  ok "every VERB+route reachable through handle_any or a route_* method is named in the docstring AND in docs/code-agents.md"
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

# The module was imported with no environment, so PASSWORD is "". The probes
# below sign with a DERIVED per-chat credential, and deriving one from an empty
# key is refused (chat_server_secret) -- so without a key here these arms would
# raise before they ever reached the socket they exist to test.
mod.PASSWORD = "root-key-for-the-probe-fixture"  # noqa: S105

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

# Set these explicitly. This fixture does NOT run under `env -i`, so leaving
# them inherited would let the developer's real environment decide the outcome
# instead of the guard under test.
mod.GH_PAT = "pat-fixture"
mod.TOGETHER_KEY = "together-fixture"
# The gateway's root key. run_container derives from it and refuses an empty
# one, so this is a precondition of reaching the argv at all.
mod.PASSWORD = "gateway-root-key-fixture"  # noqa: S105

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
real_argv = argv_for(False)
assert any(a.startswith("GH_TOKEN=") for a in real_argv)

# The container's OWN credential, at the argv boundary (issue #115). Exactly one
# such flag, and its value is not the gateway's key -- which is precisely what
# `-e OPENCODE_SERVER_PASSWORD={PASSWORD}` used to emit. Values are compared,
# never printed.
baked = [a.split("=", 1)[1] for a in real_argv if a.startswith("OPENCODE_SERVER_PASSWORD=")]
assert len(baked) == 1, len(baked)
assert baked[0] != mod.PASSWORD, "the container was handed the gateway password"
assert len(baked[0]) == 64, len(baked[0])
# Two chats, two values -- at the argv boundary, where the id is the only input
# that differs.
mod.run_container(mod.Chat(id="otherchat", repo="testrepo", title="t", port=9002, branch="b"))
other = [a.split("=", 1)[1] for a in recorded[-1] if a.startswith("OPENCODE_SERVER_PASSWORD=")]
assert other and other[0] != baked[0], "two chats were handed the same credential"

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
  ok "run_container bakes a per-chat 64-hex secret, never the gateway password"
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
# The verdict is IN the message, though, and that is worth naming: a "refused"
# reported as "did not come up in 90s" sends the reader to boot times when the
# container is up and holding the wrong credential.
err = mod.ChatLaunchError(mod.WAIT_FOR_CHAT_SECONDS, "refused")
assert isinstance(err, RuntimeError)
assert str(err)
assert "refused" in str(err), str(err)
assert "down" in str(mod.ChatLaunchError(mod.WAIT_FOR_CHAT_SECONDS, "down"))
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

# ---- 0f. the repos.json writer, which no route calls yet -------------------
# add_repo() is the artefact that makes POST /api/repos (#98) safe to build,
# and it is fully testable without one -- so it is tested without one. Every
# assertion below was run against a named broken writer and watched to fail;
# the PR description lists which mutation produces which message.
#
# THE MUTATION HAS TO BE THE ADJACENT ONE, not the easy one. Seven of these
# assertions shipped in the first draft passing against the writer they were
# meant to refuse, and every miss had the same shape: the mutation they were
# tried against was one step further away than the one that mattered.
# "Write straight to the destination" is caught; "copy the temp over the
# destination instead of renaming it" was not, and it is the second that the
# tmp-and-rename idiom exists for. "Drop the fsyncs from inside the function"
# is caught; "flip fsync= at the call site" was not, and the call site is the
# line that decides. "No fsync" is caught; "fsync the file twice instead of
# the file and its directory" was not. Where an assertion below looks
# indirect -- an inode, a descriptor's st_mode, a lock that reports its own
# contention -- that is why.
#
# Two things it must not do, both invisible until something writes the file:
#
#   * READ THROUGH load_repos(). That helper answers {} for a file it cannot
#     parse, and its own comment explains why that is the SAFE direction --
#     for a READER, where an empty allowlist merely refuses new chats. A
#     writer that inherits it turns a hand-edit's trailing comma into a
#     one-entry file, and install_template (deploy-vps.sh) never clobbers
#     repos.json, so no deploy brings the rest back.
#   * ROUND-TRIP THROUGH RepoEntry. The dataclass has six fields; the file's
#     entries carry seven, and the extra one is `tier`, which docs/privacy.md
#     classifies every code chat by. The 21-line `_readme` that documents each
#     field is on neither.
#
# The third argument is the harness's OWN allowlist, read (never written) as a
# second fixture: three entries, every one carrying a tier.
cat >"$WORK/preflight-repos-writer.py" <<'PY'
import contextlib, importlib.util, io, json, os, shutil, stat, subprocess, sys, tempfile
import threading, time
from pathlib import Path

spec = importlib.util.spec_from_file_location("cam", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["cam"] = mod
spec.loader.exec_module(mod)


# --- the torn-write child, which is why this file re-invokes itself ----------
# A document that is half-written when the process dies. The parent SIGKILLs it
# at a point this child ANNOUNCES on stdout, so nothing here depends on winning
# a race. It runs under a plain interpreter and is then killed, so it
# contributes no coverage -- deliberately: the parent drives the same lines for
# real, and a SIGKILLed coverage process writes no data file anyway.
def torn_child(mode, dest):
    payload = {"repos": [{"name": f"r{i}", "url": "u", "tier": 1} for i in range(200)]}
    text = json.dumps(payload, indent=2)

    class HalfDump:
        """`json`, with a dump that writes half a document and then parks."""

        JSONDecodeError = json.JSONDecodeError

        @staticmethod
        def dump(obj, f, **kw):
            f.write(json.dumps(obj, **kw)[: len(text) // 2])
            f.flush()
            print("half", flush=True)
            time.sleep(3600)

    if mode == "atomic":
        mod.json = HalfDump
        mod.write_json_atomic(dest, payload, indent=2, ensure_ascii=False, fsync=True)
    else:
        # THE CONTROL: the same half-write, aimed straight at the destination.
        # This is the writer the tmp-and-rename exists to refuse, and the parent
        # asserts it really does tear -- an atomicity assertion whose control
        # cannot be made to fail is measuring nothing.
        with dest.open("w", encoding="utf-8") as f:
            f.write(text[: len(text) // 2])
            f.flush()
            print("half", flush=True)
            time.sleep(3600)


if len(sys.argv) > 2 and sys.argv[2] == "--torn":
    torn_child(sys.argv[3], Path(sys.argv[4]))
    sys.exit(0)

# The manager logs to stdout, and a successful add writes an audit line. This
# block's stdout is only read to decide pass/fail, so the log is captured
# rather than printed -- and then asserted on at the end rather than dropped.
_captured = io.StringIO()
sys.stdout = _captured

EXAMPLE = Path(sys.argv[2])
FIXTURE = Path(sys.argv[3])
tmp = Path(tempfile.mkdtemp())
mod.REPOS_PATH = tmp / "repos.json"

NEW = {"name": "added-repo", "url": "https://github.com/o/added.git", "tier": 2}
CLEAN_START = json.dumps({"_readme": ["clean"], "repos": []}, indent=2) + "\n"


def seed(src):
    """Put a copy of `src` at REPOS_PATH; return its bytes."""
    shutil.copyfile(src, mod.REPOS_PATH)
    return mod.REPOS_PATH.read_bytes()


def readme_block(text):
    """The `_readme` key and its whole value, verbatim, as it sits on disk."""
    start, end = text.index('"_readme"'), text.index('"repos"')
    assert start < end, "the fixture no longer has _readme before repos"
    return text[start:end]


def add_ok(body, why=""):
    """add_repo(body) succeeded AND left EXACTLY its own audit line.

    Every single-threaded success below goes through here, so the audit line
    is checked ON EACH INDIVIDUAL PATH rather than once in aggregate at the
    end. An aggregate count over a block that already contains a 24-thread
    concurrency check can only fail if that check failed first, which makes
    it unable to see a line dropped from any one path -- so it is not the
    assertion, this is.

    The audit line is the only record a trust-boundary mutation leaves in
    journald: `journalctl -u code-agent-manager | grep 'allowlist: added'` is
    the whole answer to "what was added to the allowlist, and when".
    """
    mark = len(_captured.getvalue())
    assert mod.add_repo(body) is None, (why, "a valid entry was refused", body)
    fresh = _captured.getvalue()[mark:].splitlines()
    lines = [ln for ln in fresh if "allowlist: added" in ln]
    assert len(lines) == 1 and lines[0].endswith(f"allowlist: added {body['name'].strip()}"), (
        why,
        f"a successful write left {lines} in the journal, not exactly one "
        f"'allowlist: added {body['name'].strip()}'",
    )


# ---- 1. a successful write preserves what nothing today preserves ----------
before_bytes = seed(EXAMPLE)
before = json.loads(before_bytes)
block = readme_block(before_bytes.decode())
assert len(block) > 800, f"the _readme block is only {len(block)} bytes; the assertion is weak"

add_ok(dict(NEW), "the shipped example")
after_bytes = mod.REPOS_PATH.read_bytes()
after = json.loads(after_bytes)

# BYTES, not values. A writer that serialises from load_repos()'s parsed state
# drops _readme entirely -- it is not a RepoEntry field and load_repos never
# looks at it -- and this is the assertion that sees that. It also pins the
# writer's serialisation to the shipped example's, which is the point: the file
# this produces is the file the owner hand-edits next.
assert block in after_bytes.decode(), (
    "the 21-line _readme that documents every field did not survive the write byte for byte"
)
assert after["_readme"] == before["_readme"]

# EVERY pre-existing entry, whole. `tier` is what proves it: RepoEntry has six
# fields and tier is not one of them, so any round trip through the dataclass
# silently strips the field docs/privacy.md classifies chats by.
assert after["repos"][: len(before["repos"])] == before["repos"], (
    f"a pre-existing entry was rewritten: {after['repos'][: len(before['repos'])]}"
)
assert all(e.get("tier") in (1, 2) for e in before["repos"]), before["repos"]
assert after["repos"][-1] == {
    "name": "added-repo",
    "url": "https://github.com/o/added.git",
    "tier": 2,
    "setup": "",
    "edit_only": False,
    "allow_push": False,
    "public_throwaway": False,
}, after["repos"][-1]
assert after_bytes.endswith(b"}\n") and not after_bytes.endswith(b"\n\n"), (
    "repos.json is a file a human opens in an editor: it ends with exactly one newline"
)

# KEY ORDER, which the assertion above cannot see: `==` on two dicts is
# order-insensitive, so it holds just as well for {setup, tier, url, name}.
# The claim is that the appended entry reads like the ones already in the file,
# and the file itself is where to take that from rather than a literal here.
EXAMPLE_KEYS = list(before["repos"][0])
assert EXAMPLE_KEYS == [
    "name",
    "url",
    "tier",
    "setup",
    "edit_only",
    "allow_push",
    "public_throwaway",
], f"repos.example.json's own entries changed shape: {EXAMPLE_KEYS}"
assert list(after["repos"][-1]) == EXAMPLE_KEYS, (
    "the appended entry's keys are in a different order from every entry "
    f"repos.example.json already has: {list(after['repos'][-1])} vs {EXAMPLE_KEYS}"
)

# AN UNKNOWN KEY IN THE REQUEST BODY DOES NOT LAND IN THE TRUST BOUNDARY.
# validated_repo_entry builds a NEW dict key by key rather than copying the
# caller's, and this is the assertion for that: a route (#98) hands this
# function a decoded request body, so anything it does not name is something a
# caller chose to put in the file every future reader of the allowlist parses.
# `tier` shows why it cannot be waved through as harmless -- a second `tier`
# spelling sitting next to the validated one is a classification nobody made.
mod.REPOS_PATH.write_text(CLEAN_START, encoding="utf-8")
add_ok(
    dict(
        NEW,
        name="unknown-keys",
        Tier=3,
        allow_push_=True,
        __proto__={"allow_push": True},
        note="ignore me",
    ),
    "a body with unknown keys",
)
smuggled = json.loads(mod.REPOS_PATH.read_text(encoding="utf-8"))["repos"][0]
assert list(smuggled) == EXAMPLE_KEYS, (
    "a key the caller invented was written into repos.json: the entry on disk "
    f"is {smuggled}"
)

# NON-ASCII SURVIVES AS THE BYTES THE OWNER TYPED. json.dump defaults to
# ensure_ascii=True, which rewrites the characters below as six-character
# escapes -- a diff nobody asked for in a file whose whole point is that a
# human edits it by hand.
accented = (
    json.dumps({"_readme": ["le dépôt — priorité"], "repos": []}, indent=2, ensure_ascii=False)
    + "\n"
)
mod.REPOS_PATH.write_text(accented, encoding="utf-8")
add_ok(dict(NEW), "a non-ASCII readme")
assert readme_block(accented) in mod.REPOS_PATH.read_text(encoding="utf-8"), (
    "a non-ASCII _readme was escaped on the way through the writer"
)

# THE SCOPE OF THE BYTE CLAIM, as an assertion rather than a hope. The writer
# re-serialises the whole parsed document at indent=2, which is precisely what
# repos.example.json already is -- that is WHY its _readme comes through
# untouched above, and the assertion above holds the writer to that shape. A
# file formatted some other way is REFORMATTED: what survives then is content,
# not bytes, and content is the guarantee to rely on. Both halves are checked
# here so neither can be read as more than it is.
squashed = '{"_readme":["one line"],"repos":[{"name":"keep","url":"u","tier":1}]}'
mod.REPOS_PATH.write_text(squashed, encoding="utf-8")
add_ok(dict(NEW), "a squashed document")
out = mod.REPOS_PATH.read_text(encoding="utf-8")
assert out != squashed and out.count("\n") > 5, "the writer's own formatting changed"
doc = json.loads(out)
assert doc["_readme"] == ["one line"], doc
assert doc["repos"][0] == {"name": "keep", "url": "u", "tier": 1}, doc

# THE FSYNC IS ISSUED -- and that is ALL this asserts. What fsync buys is
# durability across a host reset, and no fixture in this repo can produce one,
# so the claim is deliberately narrow: repos.json gets the flushes, index.json
# does not.
#
# THROUGH THE CALL SITES, not through write_json_atomic. Calling the function
# with a hardcoded fsync=True and checking it honours its own parameter is a
# test that supplies the answer it checks -- it passes with both `fsync=` at
# add_repo and `fsync=` at Index.save flipped, which are the two lines that
# actually decide anything. So this drives add_repo() and Index.save() and
# reads the answer off os.fstat of every descriptor either one flushes.
#
# WHAT was flushed, not how many times. A count of 2 cannot tell "the file and
# its directory" from "the file twice", and the directory fsync is the entire
# reason the extra syscall exists: rename is atomic for a concurrent READER
# without it, but the new directory entry is not DURABLE until the directory
# itself is flushed.
flushes = []
real_fsync = os.fsync
REPOS_TMP = mod.REPOS_PATH.with_name(mod.REPOS_PATH.name + ".tmp")


def record_fsync(fd):
    st = os.fstat(fd)
    flushes.append(
        {
            # A directory descriptor and a file descriptor are distinguishable
            # at the kernel, so this needs no cooperation from the code.
            "dir": stat.S_ISDIR(st.st_mode),
            "ino": st.st_ino,
            # ...and WHEN, relative to the publish: the temp file exists
            # before `tmp.replace(path)` and is gone after it. The directory
            # fsync must come after -- flushing the directory before the
            # rename that is meant to be made durable flushes the OLD entry.
            "pre_publish": REPOS_TMP.exists(),
        }
    )
    return real_fsync(fd)


mod.REPOS_PATH.write_text(CLEAN_START, encoding="utf-8")
os.fsync = record_fsync
try:
    add_ok({"name": "fsynced", "url": "u", "tier": 1}, "the repos.json call site")
finally:
    os.fsync = real_fsync
published = mod.REPOS_PATH.stat()
assert [f["dir"] for f in flushes] == [False, True], (
    "repos.json's call site must flush the FILE and then its DIRECTORY; the "
    f"descriptors it actually flushed were {flushes}"
)
assert flushes[0]["ino"] == published.st_ino, (
    "the file that was flushed is not the file that got published: flushed "
    f"inode {flushes[0]['ino']}, repos.json is {published.st_ino}"
)
assert flushes[1]["ino"] == mod.REPOS_PATH.parent.stat().st_ino, flushes
assert flushes[0]["pre_publish"] and not flushes[1]["pre_publish"], (
    "the directory fsync ran BEFORE the rename it exists to make durable, so "
    f"what reached the platter was the old directory entry: {flushes}"
)

# ...and index.json's call site, driven the same way, still pays for neither.
mod.INDEX_PATH = tmp / "index.json"
flushes.clear()
os.fsync = record_fsync
try:
    mod.Index(chats={"c": mod.Chat(id="c", repo="r", title="t", port=1, branch="b")}).save()
finally:
    os.fsync = real_fsync
assert flushes == [], (
    "index.json is rewritten on every proxied request; its call site paid for "
    f"a device flush it did not ask for: {flushes}"
)
# indent=1 is what Index.save already did, and the extraction was supposed to
# be a refactor here -- so the file it produces is byte-identical to the file
# it produced before.
assert (tmp / "index.json").read_text(encoding="utf-8") == (
    json.dumps(
        {"chats": {"c": mod.Chat(id="c", repo="r", title="t", port=1, branch="b").to_wire()}},
        indent=1,
    )
    + "\n"
), (tmp / "index.json").read_text(encoding="utf-8")

# ...and the OTHER half of that split, which is not cosmetic. A chat title
# comes from a request body, json.loads produces a lone surrogate from
# "\\ud800", and encoding one as UTF-8 raises. index.json is written with
# ensure_ascii=True, json.dump's own default and what Index.save already did,
# so the escape keeps it writable; repos.json is not, because escaping the em
# dashes in its _readme would rewrite lines nobody touched.
surrogate = json.loads('"\\ud800lone"')
assert len(surrogate) == 5 and surrogate[0] == "\ud800", repr(surrogate)
mod.Index(chats={"c": mod.Chat(id="c", repo="r", title=surrogate, port=1, branch="b")}).save()
assert mod.Index.load().chats["c"].title == surrogate, "the index no longer round-trips"

# The same preservation, against the harness's own three-entry allowlist -- the
# file the live manager is serving, which carries tier on every entry.
multi_before = json.loads(seed(FIXTURE))
assert len(multi_before["repos"]) >= 3, multi_before
add_ok(dict(NEW), "the harness's own allowlist")
multi_after = json.loads(mod.REPOS_PATH.read_text(encoding="utf-8"))
assert [e["tier"] for e in multi_after["repos"][:-1]] == [
    e["tier"] for e in multi_before["repos"]
], "a pre-existing tier was lost"
assert multi_after["repos"][:-1] == multi_before["repos"]
# ...and the allowlist the READER sees still has everything that was in it.
reread = mod.load_repos()
assert set(reread) == {e["name"] for e in multi_before["repos"]} | {"added-repo"}, sorted(reread)

# ---- 2. a corrupt file is refused, and left alone --------------------------
# The realistic corruption, named by load_repos' own comment: a hand-edit that
# left a trailing comma. load_repos() reads this as an EMPTY allowlist, which is
# the safe direction for a READER and catastrophic for a writer -- append one
# entry to {} and the trust boundary is a one-entry file that no deploy
# restores (install_template never clobbers repos.json).
CORRUPT = (
    '{\n  "_readme": ["hand-edited, and one comma too many"],\n'
    '  "repos": [\n    {"name": "keep-me", "url": "u", "tier": 1},\n  ]\n}\n'
)
mod.REPOS_PATH.write_text(CORRUPT, encoding="utf-8")
assert mod.load_repos() == {}, "the fixture is not actually corrupt"
err = mod.add_repo(dict(NEW))
# THE FILE FIRST, and the refusal second. A writer that read through
# load_repos() would leave a one-entry document here, and this is the assertion
# that has to be the one to say so.
now = mod.REPOS_PATH.read_text(encoding="utf-8")
assert now == CORRUPT, (
    "a corrupt repos.json was REWRITTEN; the allowlist it held is gone and no "
    f"deploy restores it. The file now reads: {now!r}"
)
assert isinstance(err, mod.ApiError) and err.status == 500, err
assert "NOT modified" in err.message, err.message

# ...and the same for a file that cannot be READ at all -- the other arm of
# load_repos' own except clause. A directory where the file should be raises
# IsADirectoryError, an OSError rather than a JSONDecodeError.
mod.REPOS_PATH.unlink()
mod.REPOS_PATH.mkdir()
err = mod.add_repo(dict(NEW))
assert isinstance(err, mod.ApiError) and err.status == 500, err
assert mod.REPOS_PATH.is_dir(), "the unreadable path was replaced"
mod.REPOS_PATH.rmdir()

# ...and a file that is not UTF-8 AT ALL, which is the third arm and the one
# that used to escape. repos.json is edited by hand, and an editor set to
# latin-1 needs one accented word in the _readme to produce this. The decode
# happens in read_text BEFORE json.loads is reached, so what comes out is
# UnicodeDecodeError -- a ValueError, and neither an OSError nor a
# JSONDecodeError. Caught as json.JSONDecodeError it went straight past both
# handlers and out of add_repo as an unhandled exception in a request thread;
# the refusal below is the whole contract of the function.
LATIN1 = '{\n  "_readme": ["le dépôt, hand-edited"],\n  "repos": [\n' \
         '    {"name": "keep-me", "url": "u", "tier": 1}\n  ]\n}\n'
mod.REPOS_PATH.write_bytes(LATIN1.encode("latin-1"))
before_latin1 = mod.REPOS_PATH.read_bytes()
err = mod.add_repo(dict(NEW))
assert mod.REPOS_PATH.read_bytes() == before_latin1, "the latin-1 file was rewritten"
assert isinstance(err, mod.ApiError) and err.status == 500, (
    f"a latin-1 repos.json did not come back as a refusal; add_repo returned {err!r}"
)
assert "NOT modified" in err.message and "UnicodeDecodeError" in err.message, err.message
# ...and the READER's own arm of it, which had the identical hole: every route
# that resolves a repo went down with it rather than degrading to the empty
# allowlist that arm exists to produce.
assert mod.load_repos() == {}, "load_repos did not degrade a latin-1 file to an empty allowlist"

# ...and the shapes that parse but are not an allowlist. Same class as the
# trailing comma: something is in there, and it is not ours to overwrite.
for junk in ('{"repos": "not a list"}', "[1, 2, 3]", '"a bare string"'):
    mod.REPOS_PATH.write_text(junk, encoding="utf-8")
    err = mod.add_repo(dict(NEW))
    assert isinstance(err, mod.ApiError) and err.status == 500, (junk, err)
    assert mod.REPOS_PATH.read_text(encoding="utf-8") == junk, junk

# ---- 3. the two consequential flags are not coerced -------------------------
# _bool is `bool(raw.get(key, False))`, so it reads "false" as True (a non-empty
# string), 1 as True, and "no" as True. allow_push grants a push with no
# permission ask and public_throwaway permits models that train on the data, so
# a value that is not a boolean has to be a refusal rather than a guess.
CLEAN = CLEAN_START
for key in ("allow_push", "public_throwaway", "edit_only"):
    for value in ("false", "no", 1, 0, None, [], "true"):
        mod.REPOS_PATH.write_text(CLEAN, encoding="utf-8")
        body = dict(NEW, **{key: value})
        assert mod._bool(body, key) is bool(value), "the _bool premise this rests on changed"
        err = mod.add_repo(body)
        assert mod.REPOS_PATH.read_text(encoding="utf-8") == CLEAN, (
            f"{key}={value!r} was COERCED and written to the allowlist: "
            f"{mod.REPOS_PATH.read_text(encoding='utf-8')!r}"
        )
        assert isinstance(err, mod.ApiError) and err.status == 400, (key, value, err)
        assert key in err.message, err.message
# ...and real booleans still work, both ways round.
mod.REPOS_PATH.unlink(missing_ok=True)
add_ok(dict(NEW, allow_push=True, edit_only=True), "real booleans")
entry = json.loads(mod.REPOS_PATH.read_text(encoding="utf-8"))["repos"][0]
assert entry["allow_push"] is True and entry["edit_only"] is True, entry
assert entry["public_throwaway"] is False, entry

# ---- 4. tier is required, and is 1 or 2 ------------------------------------
# `True == 1` and `1.0 == 1` in Python, so `value in (1, 2)` on its own reads
# {"tier": true} as Tier 1 -- an unclassified repo entering the boundary as the
# least restricted one.
for value in (3, 0, -1, "1", "one", 1.0, True, None, [1]):
    mod.REPOS_PATH.write_text(CLEAN, encoding="utf-8")
    body = dict(NEW)
    body["tier"] = value
    err = mod.add_repo(body)
    assert mod.REPOS_PATH.read_text(encoding="utf-8") == CLEAN, (
        f"tier={value!r} was accepted into the trust boundary: "
        f"{mod.REPOS_PATH.read_text(encoding='utf-8')!r}"
    )
    assert isinstance(err, mod.ApiError) and err.status == 400, (value, err)
    assert "tier" in err.message, err.message
mod.REPOS_PATH.write_text(CLEAN, encoding="utf-8")
absent = dict(NEW)
del absent["tier"]
err = mod.add_repo(absent)
assert mod.REPOS_PATH.read_text(encoding="utf-8") == CLEAN, (
    "an entry with NO tier was written; the manager made a classification that "
    "is the owner's to make"
)
assert isinstance(err, mod.ApiError) and err.status == 400 and "tier" in err.message, err
for value in (1, 2):
    mod.REPOS_PATH.unlink(missing_ok=True)
    body = dict(NEW)
    body["tier"] = value
    add_ok(body, f"tier={value}")
    assert json.loads(mod.REPOS_PATH.read_text(encoding="utf-8"))["repos"][0]["tier"] == value

# ---- 5. name and url are required; a duplicate name is refused -------------
mod.REPOS_PATH.unlink(missing_ok=True)
for body in (
    {"url": "u", "tier": 1},
    {"name": "", "url": "u", "tier": 1},
    {"name": "   ", "url": "u", "tier": 1},
    {"name": 7, "url": "u", "tier": 1},
    {"name": "n", "tier": 1},
    {"name": "n", "url": "", "tier": 1},
    {"name": "n", "url": 7, "tier": 1},
    {"name": "n", "url": "u", "tier": 1, "setup": 7},
):
    err = mod.add_repo(dict(body))
    assert isinstance(err, mod.ApiError) and err.status == 400, (body, err)
assert not mod.REPOS_PATH.exists(), "a refused entry created the file anyway"

# A MISSING file IS created -- there is no allowlist there to lose.
add_ok(dict(NEW), "a missing file")
doc = json.loads(mod.REPOS_PATH.read_text(encoding="utf-8"))
assert [e["name"] for e in doc["repos"]] == ["added-repo"], doc

# load_repos is LAST-WINS on duplicate names, so an appended twin silently takes
# over an existing entry's flags: allow_push true under a name whose owner set
# it false. Refusing is NEW behaviour, not enforcement of an existing rule.
err = mod.add_repo(dict(NEW, allow_push=True))
doc = json.loads(mod.REPOS_PATH.read_text(encoding="utf-8"))
assert len(doc["repos"]) == 1, f"a duplicate name was appended: {doc['repos']}"
assert mod.load_repos()["added-repo"].allow_push is False, (
    "the twin took the entry over: last-wins means the appended allow_push:true "
    "is now what every chat on this repo gets"
)
assert isinstance(err, mod.ApiError) and err.status == 409, err

# ...and the WHITESPACE TWIN, which is what makes the .strip() on `name`
# load-bearing rather than tidy. " added-repo " is a different string, so
# without the strip it sails past the duplicate scan above and is appended --
# and load_repos, being last-wins, then hands every chat on `added-repo` the
# twin's allow_push:true. The refusal is the assertion; the file is the proof.
err = mod.add_repo(dict(NEW, name=" added-repo ", allow_push=True))
doc = json.loads(mod.REPOS_PATH.read_text(encoding="utf-8"))
assert len(doc["repos"]) == 1, (
    f"a whitespace twin of an existing name was appended: {doc['repos']}"
)
assert mod.load_repos()["added-repo"].allow_push is False, (
    "the whitespace twin took the entry over: allow_push:true is now what "
    "every chat on this repo gets"
)
assert isinstance(err, mod.ApiError) and err.status == 409, err
# ...and the same strip on the way IN, so the name a future duplicate scan
# compares against is the trimmed one rather than whatever the caller sent.
mod.REPOS_PATH.write_text(CLEAN, encoding="utf-8")
add_ok({"name": "  spaced  ", "url": "  https://github.com/o/spaced.git\n", "tier": 1}, "strip")
stored = json.loads(mod.REPOS_PATH.read_text(encoding="utf-8"))["repos"][0]
assert stored["name"] == "spaced" and stored["url"] == "https://github.com/o/spaced.git", stored
assert "spaced" in mod.load_repos(), sorted(mod.load_repos())

# ---- 6. a document with a _readme and no repos key at all ------------------
# `.get("repos", [])` hands back a FRESH list for this one, so appending to that
# list writes a document with no allowlist in it.
mod.REPOS_PATH.write_text(json.dumps({"_readme": ["docs only"]}, indent=2), encoding="utf-8")
add_ok(dict(NEW), "no repos key at all")
doc = json.loads(mod.REPOS_PATH.read_text(encoding="utf-8"))
assert doc["_readme"] == ["docs only"], doc
assert [e["name"] for e in doc.get("repos", [])] == ["added-repo"], (
    f"the entry was appended to a list that is not in the document: {doc}"
)

# ---- 7. a write that fails is reported, not swallowed ----------------------
real_write = mod.write_json_atomic


def no_space(*_a, **_k):
    raise OSError(28, "No space left on device")


mod.write_json_atomic = no_space
audit = io.StringIO()
with contextlib.redirect_stdout(audit):
    err = mod.add_repo({"name": "nospace", "url": "u", "tier": 1})
mod.write_json_atomic = real_write
assert err is not None, (
    "a write that raised OSError was reported as success; the caller believes "
    "an entry is in the allowlist that is not"
)
assert isinstance(err, mod.ApiError) and err.status == 500, err
assert "nospace" not in mod.load_repos(), "a failed write reported an entry that is not there"
# The audit line is the only record a trust-boundary mutation leaves in
# journald. It must not claim a write that did not happen.
assert "allowlist: added" not in audit.getvalue(), audit.getvalue()

# ---- 8. the lock is real, and it is NOT _lock ------------------------------
# Two claims, and the second is the one that matters: `_lock` is non-reentrant
# and has wedged this process once, so a writer that took it would put a
# read-modify-write of repos.json in the same deadlock family as wake_chat's
# post-mortem.
mod.REPOS_PATH.write_text('{"repos": []}', encoding="utf-8")
inside, release = threading.Event(), threading.Event()


def parked(*_a, **_k):
    inside.set()
    release.wait(20)


class WatchedLock:
    """`_repos_lock`, with an Event set the instant a thread BLOCKS on it.

    This is what makes the mutual-exclusion assertion below deterministic
    rather than pass-biased. The obvious form -- start a second writer, then
    `assert not done.wait(1.0)` -- is satisfied by EVERY outcome in which the
    second thread has not finished in a second, including one where it was
    never scheduled at all: it cannot fail, so it cannot catch anything. What
    has to be observed is the second writer REACHING the lock and NOT getting
    through it, and a lock that reports its own contention says exactly that
    with no sleep and no timeout in the passing path.
    """

    def __init__(self):
        self._inner = threading.Lock()
        self.contended = threading.Event()

    def acquire(self, blocking=True, timeout=-1):
        if self._inner.acquire(blocking=False):
            return True
        # Held by someone else, so this call is about to block -- which is
        # the event, and it is recorded BEFORE the block rather than after.
        self.contended.set()
        return self._inner.acquire(blocking, timeout)

    def release(self):
        self._inner.release()

    def __enter__(self):
        self.acquire()
        return self

    def __exit__(self, *_exc):
        self.release()


real_repos_lock = mod._repos_lock
watched = WatchedLock()
mod._repos_lock = watched
mod.write_json_atomic = parked
first = threading.Thread(target=mod.add_repo, args=({"name": "a", "url": "u", "tier": 1},))
first.start()
try:
    assert inside.wait(10), "add_repo never reached the write"
    # It holds SOMETHING (the next assertion proves that) and it is not `_lock`,
    # so every route that needs `_lock` keeps working while a repos.json write
    # is in flight -- and neither lock can ever be waiting on the other.
    assert mod._lock.acquire(blocking=False), "add_repo is holding _lock, the wedge lock"
    mod._lock.release()
    done = threading.Event()
    second = threading.Thread(
        target=lambda: (mod.add_repo({"name": "b", "url": "u", "tier": 1}), done.set())
    )
    second.start()
    # BOTH halves, and neither is a timing guess. The first says the second
    # writer got as far as the module's own `_repos_lock` -- a writer that
    # takes no lock, or builds a fresh one per call, never contends and hangs
    # here. The second says that having reached it, it is still on the wrong
    # side: the holder is parked on `release`, so no scheduling outcome lets
    # the second thread be finished at this instant.
    assert watched.contended.wait(10), (
        "a second writer never blocked on _repos_lock while the first held it: "
        "it is not taking the module's lock at all"
    )
    assert not done.is_set(), "a second writer walked straight into the critical section"
    release.set()
    assert done.wait(10), "the second writer never finished"
    second.join(10)
finally:
    release.set()
    first.join(10)
mod.write_json_atomic = real_write
mod._repos_lock = real_repos_lock

# ...and the consequence, against the real writer AND the real lock: concurrent
# adds do not lose each other. Unlocked, two threads read the same N entries and
# the second write drops the first's.
mod.REPOS_PATH.write_text(json.dumps({"_readme": ["keep"], "repos": []}), encoding="utf-8")
concurrent_mark = len(_captured.getvalue())
threads = [
    threading.Thread(target=mod.add_repo, args=({"name": f"c{i}", "url": "u", "tier": 1},))
    for i in range(24)
]
for t in threads:
    t.start()
for t in threads:
    t.join(30)
doc = json.loads(mod.REPOS_PATH.read_text(encoding="utf-8"))
assert sorted(e["name"] for e in doc["repos"]) == sorted(f"c{i}" for i in range(24)), (
    f"{len(doc['repos'])} of 24 concurrent adds survived: "
    f"{sorted(e['name'] for e in doc['repos'])}"
)
assert doc["_readme"] == ["keep"]
# EXACTLY 24 audit lines, one per name -- not "more than ten". A threshold
# under a check that already guarantees 24 can only be reached once that check
# has failed, so it is unfalsifiable where it sits.
concurrent_audit = sorted(
    ln.split("allowlist: added ")[1]
    for ln in _captured.getvalue()[concurrent_mark:].splitlines()
    if "allowlist: added " in ln
)
assert concurrent_audit == sorted(f"c{i}" for i in range(24)), (
    f"24 concurrent adds left these audit lines: {concurrent_audit}"
)


# ---- 9. the destination never holds a partial document ---------------------
# TWO SEPARATE PROPERTIES, and the torn-write child below only covers the
# first. It is SIGKILLed while json.dump is still running inside the
# `with tmp.open(...)` block -- so what it shows is that the SERIALISATION
# goes to a temp file, and the publish is never reached. Replacing
# `tmp.replace(path)` with `shutil.copyfile(tmp, path); tmp.unlink()` leaves
# every one of its checks passing, which is the mutation the tmp-and-rename
# idiom exists to refuse.
#
# So the publish gets its own two assertions, before the child runs.

# (a) THE DIRECTORY ENTRY IS SWAPPED, the destination is not rewritten. This
# is the difference between rename and copy stated in the one place the kernel
# will answer honestly: rename gives the destination the temp file's inode,
# and any writer that opens the destination and writes into it -- copyfile,
# read-truncate-write, plain `open(path, "w")` -- leaves the inode alone.
mod.REPOS_PATH.write_text(CLEAN, encoding="utf-8")
before_ino = mod.REPOS_PATH.stat().st_ino
add_ok({"name": "published", "url": "u", "tier": 1}, "the publish")
assert mod.REPOS_PATH.stat().st_ino != before_ino, (
    "repos.json still has the inode it had before the write: the new document "
    "was written INTO the destination rather than published over it by rename, "
    "so every byte of it was visible to a concurrent reader as it landed"
)

# (b) ...and the consequence, measured on a reader that is actually looking.
# 30 writes of a ~350KB document with a reader hammering the path: with
# rename, a reader gets the whole old file or the whole new one and there is
# no third outcome, so the tolerance is ZERO. Under copyfile the same loop
# sees dozens of half-documents -- which is what `load_repos` would log as
# "repos.json is unreadable -- allowlist is empty" on a live brain.
crowd = {
    "_readme": ["x" * 400],
    "repos": [
        {"name": f"r{i}", "url": "u" * 60, "tier": 1, "setup": "",
         "edit_only": False, "allow_push": False, "public_throwaway": False}
        for i in range(1500)
    ],
}
mod.REPOS_PATH.write_text(json.dumps(crowd, indent=2) + "\n", encoding="utf-8")
assert mod.REPOS_PATH.stat().st_size > 300_000, mod.REPOS_PATH.stat().st_size
reader_stop, reader_read, reader_moved = threading.Event(), threading.Event(), threading.Event()
partial = []


def watch_repos():
    """Read the destination in a tight loop; record anything that is not whole."""
    first_size = None
    while not reader_stop.is_set():
        try:
            blob = mod.REPOS_PATH.read_bytes()
        except FileNotFoundError:
            partial.append("the destination did not exist")
            continue
        if first_size is None:
            first_size = len(blob)
            reader_read.set()
        elif len(blob) != first_size:
            reader_moved.set()
        try:
            doc = json.loads(blob)
        except ValueError as e:
            partial.append(f"{type(e).__name__}: {e}")
            continue
        if len(doc.get("repos", [])) < len(crowd["repos"]):
            partial.append(f"a document with only {len(doc.get('repos', []))} entries")


watcher = threading.Thread(target=watch_repos, daemon=True)
watcher.start()
assert reader_read.wait(30), "the reader thread never ran; it would prove nothing"
for i in range(30):
    add_ok({"name": f"w{i}", "url": "u", "tier": 1}, "under a concurrent reader")
# NOT PASS-BIASED: the file is now stable at a size it did not start at, so a
# reader that is still running observes the change. One that never sampled
# anything hangs here instead of quietly satisfying the zero-tears assertion.
assert reader_moved.wait(30), (
    "the reader never observed the file change at all, so its clean bill of "
    "health is about a file nobody was writing"
)
reader_stop.set()
watcher.join(30)
assert not partial, (
    f"a concurrent reader caught the writer mid-publish {len(partial)} times "
    f"across 30 writes; the first was {partial[0][:160]!r}. On the brain that "
    "is load_repos logging 'repos.json is unreadable -- allowlist is empty'"
)


# ...and the serialisation, killed mid-write at a point the child announces, so
# this is not a race either. The control is the same half-write aimed straight
# at the destination: it has to tear, or the atomic assertion above it is
# measuring nothing.
def killed_mid_write(mode, dest):
    child = subprocess.Popen(
        [sys.executable, sys.argv[0], sys.argv[1], "--torn", mode, str(dest)],
        stdout=subprocess.PIPE,
        text=True,
    )
    try:
        line = child.stdout.readline()
        assert line.strip() == "half", f"the {mode} child said {line!r}, not 'half'"
    finally:
        child.kill()
        child.wait(10)


ORIGINAL = json.dumps({"_readme": ["the whole allowlist"], "repos": []}, indent=2) + "\n"
dest = tmp / "torn.json"

dest.write_text(ORIGINAL, encoding="utf-8")
killed_mid_write("atomic", dest)
assert dest.read_text(encoding="utf-8") == ORIGINAL, "the destination was touched"
json.loads(dest.read_text(encoding="utf-8"))  # and it is still whole
# NOT VACUOUS: the write really was in flight and its bytes really were partial
# -- they were just not at the destination yet.
stray = dest.with_name(dest.name + ".tmp")
assert stray.is_file(), "no temp file at all: the child died before writing anything"
try:
    json.loads(stray.read_text(encoding="utf-8"))
except json.JSONDecodeError:
    pass
else:
    raise AssertionError("the temp file held a whole document; nothing was interrupted")
stray.unlink()

dest.write_text(ORIGINAL, encoding="utf-8")
killed_mid_write("naive", dest)
torn = dest.read_text(encoding="utf-8")
assert torn != ORIGINAL, "the control never reached the destination at all"
try:
    json.loads(torn)
except json.JSONDecodeError:
    pass
else:
    raise AssertionError("the non-atomic control produced a whole document; it proves nothing")

# ---- 10. the audit trail --------------------------------------------------
# The per-write assertion lives in add_ok(), which every single-threaded
# success above goes through, and the 24-thread block checks its own 24 lines
# by name. What is left for the end is the one thing neither can see: that a
# refusal never logs one. `len(added) > 10` used to sit here, and it could not
# fail -- the 24-thread check alone guarantees 24 lines, so the threshold was
# only reachable once that check had already gone red.
sys.stdout = sys.__stdout__
added = [ln for ln in _captured.getvalue().splitlines() if "allowlist: added " in ln]
names = {ln.split("allowlist: added ")[1] for ln in added}
# Every name that was REFUSED somewhere above, and so must appear in no line:
# the OSError write, the invalid bodies of section 5, and the whitespace twin
# (whose untrimmed spelling is also what a dropped .strip() would log).
for refused in ("nospace", "n", " added-repo "):
    assert refused not in names, (
        f"a refusal left an audit line claiming {refused!r} was added to the "
        f"allowlist: {sorted(names)}"
    )
# ...and every name that WAS written is in one, which is the same set the
# per-write add_ok() assertions built up one at a time.
assert {"added-repo", "spaced", "published", "fsynced", "unknown-keys"} <= names, sorted(names)
PY
if "${MANAGER_PY[@]}" "$WORK/preflight-repos-writer.py" \
  "$REPO_ROOT/scripts/vps/code-agent-manager.py" \
  "$REPO_ROOT/config/code-agents/repos.example.json" "$WORK/root/repos.json"
then
  ok "a write keeps repos.example.json's 21-line _readme byte for byte, and every pre-existing entry whole"
  ok "...including every tier, the field RepoEntry does not have — and the reader still sees the whole allowlist"
  ok "...and a non-ASCII readme is not escaped, and the file keeps exactly one trailing newline"
  ok "an unknown key in the request body is dropped, and the entry's key order is repos.example.json's"
  ok "add_repo's call site fsyncs the published file AND then its directory; Index.save's still flushes neither"
  ok "...and index.json keeps indent=1 and ensure_ascii, so a lone-surrogate chat title stays writable"
  ok "a corrupt, unreadable, latin-1 or wrong-shaped repos.json is refused and left byte-identical"
  ok "allow_push/public_throwaway/edit_only are refused unless they are booleans — _bool would read \"false\" as true"
  ok "tier is required and must be 1 or 2: 3, \"1\", 1.0, true and absent are all refused"
  ok "a duplicate name is refused (load_repos is last-wins), and so is its whitespace twin — and name/url are trimmed"
  ok "a write that fails is reported, not swallowed, and every success leaves exactly one audit line"
  ok "a second writer BLOCKS on the writer's own lock, never _lock, and 24 concurrent adds all survive"
  ok "the publish swaps the inode, and 30 writes under a hammering reader yield zero partial documents"
  ok "...and the serialisation is killed mid-write with the destination untouched, where the non-atomic control tears"
else
  bad "the repos.json writer (see the assertion above)"
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

# ---- 4b. per-chat container credentials (issue #115) ------------------------
# Two chats are up, which is the only moment in this file where a credential
# minted for one can be pointed at the other. Everything here is asserted over
# HTTP against the real servers, never in-process: the claim is about what a
# process holding chat A's environment can reach, and an in-process check of
# the derivation would be a check that the manager agrees with itself.
#
# The whole section is only meaningful because stub-engine.sh now records the
# `-e OPENCODE_SERVER_PASSWORD` it is handed and launches each mock from that
# recorded value. Before that it discarded `-e` and inherited the manager's own
# password, so every assertion below passed while covering nothing at all.
#
# Reaper-proofing, and it has to be tighter than the cap check's above. This
# section talks to the chats' ports DIRECTLY, so a chat the reaper took answers
# nothing at all -- which would read as "the credential was refused" when it is
# really "there was nobody there". A conditional wake is not enough: a chat that
# is running but was last touched 3.5s ago passes the condition and is gone a
# heartbeat later (IDLE_SECONDS=4, REAPER_INTERVAL=2). Observed exactly that.
# So: one proxy request per chat, which wakes it AND touches it, issued
# immediately before the direct-port calls with nothing slow in between.
wake_and_touch() {
  for _cred_id in "$CID" "$BID"; do
    # shellcheck disable=SC2086
    $CURL --max-time 120 -o /dev/null "$BASE/chat/$_cred_id/session" || true
  done
}
SEC_A="$(cfield "$CID" password)"; PORT_A="$(cfield "$CID" port)"
SEC_B="$(cfield "$BID" password)"; PORT_B="$(cfield "$BID" port)"

[ -n "$SEC_A" ] && [ "$SEC_A" != "$SEC_B" ] \
  && ok "two chats get two different container credentials" \
  || bad "container credentials are not per-chat (A=$SEC_A B=$SEC_B)"
[ "$SEC_A" != "$PASS" ] && [ "$SEC_B" != "$PASS" ] \
  && ok "no container is handed the gateway password" \
  || bad "a container holds the gateway password (#115)"
printf '%s' "$SEC_A" | grep -qE '^[0-9a-f]{64}$' \
  && printf '%s' "$SEC_B" | grep -qE '^[0-9a-f]{64}$' \
  && ok "each container credential is a 64-hex digest" \
  || bad "container credential is not 64 hex (A=$SEC_A B=$SEC_B)"

# The derivation itself, recomputed here rather than imported, so a change to
# the HMAC message is a deliberate edit in two places. The epoch is read out of
# the source for the same reason cred_epoch exists at all: bumping it must
# rotate the value, and a hardcoded 1 here would hide that.
#
# The ROOT KEY is a parameter and not $PASS, because section 9f needs this same
# derivation under a DIFFERENT key: that is precisely what a rotated
# OPENCODE_SERVER_PASSWORD is, and the containers it leaves behind are baked
# with the answer this function gives for the old one.
CRED_EPOCH="$(sed -n 's/^CRED_EPOCH = \([0-9][0-9]*\).*/\1/p' \
  "$REPO_ROOT/scripts/vps/code-agent-manager.py")"
derive() { # derive <root-key> <epoch> <chat-id>
  python3 -c '
import hashlib, hmac, sys
key, epoch, cid = sys.argv[1], sys.argv[2], sys.argv[3]
print(hmac.new(key.encode(), f"code-agent/{epoch}/{cid}".encode(), hashlib.sha256).hexdigest())
' "$1" "$2" "$3"; }
EXPECT_A="$(derive "$PASS" "$CRED_EPOCH" "$CID")"
[ -n "$CRED_EPOCH" ] && [ "$SEC_A" = "$EXPECT_A" ] \
  && ok "the container credential is HMAC(password, code-agent/<epoch>/<id>)" \
  || bad "credential is not the documented derivation (epoch='$CRED_EPOCH')"

# THE ASSERTION FOR #115, and it needs its control first: a credential that
# opens nothing at all would 401 everywhere and prove nothing. So chat A's
# secret must work at chat A's own port BEFORE the two refusals mean anything.
# All three calls back to back, right after the touch, for the reason above.
# `|| true`, not `|| echo 000`: -w already prints 000 on a failed transfer, and
# the extra echo made the two run together into an unreadable "000000".
code_at() { curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -u "opencode:$1" "$2" || true; }
wake_and_touch
CTL="$(code_at "$SEC_A" "http://127.0.0.1:$PORT_A/session")"
X_CHAT="$(code_at "$SEC_A" "http://127.0.0.1:$PORT_B/session")"
GW="$(code_at "$SEC_A" "$BASE/api/chats")"
GWOK="$(code_at "$PASS" "$BASE/api/chats")"
[ "$CTL" = "200" ] && ok "control: chat A's credential opens chat A's own server" \
  || { bad "control failed: chat A's credential got $CTL at its own port $PORT_A"
       echo "      (chat A is $(cstate "$CID"), chat B is $(cstate "$BID"))"; }
[ "$X_CHAT" = "401" ] && ok "chat A's credential is refused 401 at chat B's port" \
  || bad "cross-chat: chat A's credential got $X_CHAT at chat B's port $PORT_B"
[ "$GW" = "401" ] && ok "chat A's credential is refused 401 at the gateway (#115)" \
  || bad "#115: a container credential got $GW from the gateway"
# The gateway's own control, beside the refusal it is paired with: a gateway
# answering 401 to everything would satisfy the line above.
[ "$GWOK" = "200" ] && ok "control: the gateway password still opens the gateway" \
  || bad "control failed: the gateway password got $GWOK"

# No response body carries a secret. Substring of the RAW bytes, not a key
# lookup: a field that gets renamed, nested, or spliced in beside the chat (the
# way `stat`, `status` and `url` already are) would slip past a key check.
# $CHAT is the POST /api/chats body captured at create; $LIST is a fresh GET.
# shellcheck disable=SC2086
LIST="$($CURL "$BASE/api/chats")"
LEAK=""
for _s in "$SEC_A" "$SEC_B" "$PASS"; do
  case "$CHAT" in *"$_s"*) LEAK="$LEAK POST" ;; esac
  case "$LIST" in *"$_s"*) LEAK="$LEAK GET" ;; esac
done
# The matcher's own control: $CID really is in both bodies, so an empty body or
# a broken `case` cannot report "no secrets found".
CTL_HIT="no"
case "$CHAT" in *"$CID"*) case "$LIST" in *"$CID"*) CTL_HIT="yes" ;; esac ;; esac
[ "$CTL_HIT" = "yes" ] && ok "control: the substring test can find a chat id in both bodies" \
  || bad "the leak matcher is inert -- \$CID is not in the bodies it searches"
[ -z "$LEAK" ] && ok "no secret appears in the POST or GET /api/chats body" \
  || bad "a secret appears in the response body of:$LEAK"

# cred_epoch survives the save/load round-trip. Asserted through the API, which
# is Index.load() off disk, so a from_wire that forgot the field reports 0 here
# and the manager would recreate every container on every wake forever.
EPOCH_SEEN="$($CURL "$BASE/api/chats" | CID="$CID" python3 -c '
import json, os, sys
row = next(c for c in json.load(sys.stdin)["chats"] if c["id"] == os.environ["CID"])
print(row.get("cred_epoch", "MISSING"))')"
[ "$EPOCH_SEEN" = "$CRED_EPOCH" ] \
  && ok "cred_epoch survives a save/load round-trip (reads $EPOCH_SEEN)" \
  || bad "cred_epoch round-trip: index reports '$EPOCH_SEEN', source says '$CRED_EPOCH'"

# wait_for_chat's three verdicts, over real sockets. Its own mock rather than a
# live chat's: the idle reaper would otherwise be free to spin the chat down
# mid-check, and "the container went away" would print as "the credential was
# refused" -- the exact confusion this tri-state exists to end.
#
# The fixture's password is the derivation for id `waitfor-fixture`, recomputed
# here, so the "ok" case is a genuine control: it hits the SAME port over the
# SAME code path as the "refused" case and differs only in the chat id the
# credential is derived from. Before #115 both returned True, and the docstring
# said "auth'd or 401" out loud.
WF_PORT=$((PORT + 18))
WF_PASS="$(derive "$PASS" "$CRED_EPOCH" "waitfor-fixture")"
mkdir -p "$WORK/waitfor/home"
python3 "$HERE/mock-opencode-server.py" --port "$WF_PORT" --dir "$WORK/waitfor" \
  --password "$WF_PASS" >"$WORK/waitfor.log" 2>&1 &
WF_PID=$!
for _ in $(seq 1 40); do
  curl -sS --max-time 2 -o /dev/null "http://127.0.0.1:$WF_PORT/session" && break
  sleep 0.25
done
cat >"$WORK/preflight-waitfor.py" <<'PY'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("cam", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["cam"] = mod
spec.loader.exec_module(mod)

port, pw, dead = int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
mod.PASSWORD = pw          # the module read an empty env; this is the root key


def chat(cid, port):
    return mod.Chat(id=cid, repo="r", title="t", port=port, branch="b")


verdict = mod.wait_for_chat(chat("waitfor-fixture", port), timeout_s=8)
assert verdict == "ok", f"control: the fixture answered {verdict!r}, not 'ok'"
verdict = mod.wait_for_chat(chat("some-other-chat", port), timeout_s=8)
assert verdict == "refused", f"a 401 read as {verdict!r}, not 'refused'"
verdict = mod.wait_for_chat(chat("waitfor-fixture", dead), timeout_s=1)
assert verdict == "down", f"a closed port read as {verdict!r}, not 'down'"
PY
if "${MANAGER_PY[@]}" "$WORK/preflight-waitfor.py" \
     "$REPO_ROOT/scripts/vps/code-agent-manager.py" "$WF_PORT" "$PASS" "$((PORT + 19))"
then
  ok "wait_for_chat: answering is ok, 401 is refused, a closed port is down"
else
  bad "wait_for_chat's verdicts (see the assertion above)"
fi
kill "$WF_PID" 2>/dev/null || true

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

# ---- the repo the PAT cannot see (NAMED, not numbered -- issue #119) --------
# The likeliest refusal any "validate this repo URL" route meets is "your token
# cannot see that repo", and the fake had no way to say it. Nothing above could
# stand in:
#
#   * `denied` is a WHOLE-REQUEST 403. Arming it to refuse one repo takes the
#     branch sweep and every other GitHub-touching route down with it, so it can
#     never show one repo refusing while the rest of the stack runs.
#   * `nodefault` 403s GET /repos/:o/:r alone -- architecturally the right
#     shape, the WRONG STATUS. Real GitHub answers 404 for a repo a fine-grained
#     PAT is not scoped to; confirming existence to a token that cannot see it is
#     exactly what it avoids.
#
# And the status is not cosmetic. gh() maps 401/403 onto "GitHub refused the
# credential - the PAT may have expired", which is the wrong sentence for "your
# token cannot see that repo" -- so a route built against a 403 fixture ships
# the wrong one. FAKE_GITHUB_INVISIBLE_REPOS names SLUGS, so one repo is dark
# while testowner/testrepo is served in the same run.

INVISIBLE_SLUG="secretowner/secretrepo"
SEAM_GH="http://127.0.0.1:$GH_PORT"

start_github_invisible() { # start_github_invisible <comma-separated slugs>
  kill "$GITHUB_PID" 2>/dev/null || true
  sleep 0.4
  # The branches file for the same reason restart_github carries it: without it
  # the fake falls back to its five-name built-in list and the branch-count
  # assertion below fails for a reason that is not the seam's.
  FAKE_GITHUB_BRANCH="agent/testrepo-fixture" \
    FAKE_GITHUB_INVISIBLE_REPOS="$1" \
    FAKE_GITHUB_BRANCHES_FILE="$WORK/branches.txt" \
    python3 "$HERE/fake-github.py" --port "$GH_PORT" &
  GITHUB_PID=$!
  for _ in $(seq 1 20); do
    curl -sS -o /dev/null "$SEAM_GH/repos/testowner/testrepo/pulls" && break
    sleep 0.3
  done
}

start_github_invisible "$INVISIBLE_SLUG"

# BOTH halves, in ONE run, in one assertion. A whole-request arm passes the
# first half and fails the second, and the first half alone would go green for
# a fake that had simply stopped serving.
INVIS_CODE="$(curl -sS -o "$WORK/invisible-repo.json" -w '%{http_code}' \
  "$SEAM_GH/repos/$INVISIBLE_SLUG")"
VIS_CODE="$(curl -sS -o "$WORK/visible-repo.json" -w '%{http_code}' \
  "$SEAM_GH/repos/testowner/testrepo")"
[ "$INVIS_CODE" = "404" ] && [ "$VIS_CODE" = "200" ] \
  && grep -q '"default_branch"' "$WORK/visible-repo.json" \
  && ok "an invisible repo 404s while testowner/testrepo is served in the same run" \
  || bad "invisible/visible: $INVIS_CODE / $VIS_CODE $(cat "$WORK/visible-repo.json")"

# The BODY, separately: a bare 404 with nothing in it would let a caller that
# reads `message` pass here for the wrong reason and then meet a real GitHub
# that does send one.
python3 -c '
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(d, dict), type(d).__name__
assert d.get("message") == "Not Found", d
' "$WORK/invisible-repo.json" \
  && ok "the invisible 404 carries GitHub own body shape, not an empty one" \
  || bad "invisible body: $(cat "$WORK/invisible-repo.json")"

# EVERYTHING under the repo, not just the two-segment route -- a validator that
# gets past GET /repos/:o/:r goes straight on to the branch check, and a
# two-segment-only arm would hand it a 200 there.
SEAM_SUB_OK="yes"
for SEAM_PATH in "" "/branches" "/branches/main" "/pulls" "/pulls/12" \
  "/commits/sha12/status" "/compare/main...agent/testrepo-fixture"; do
  SEAM_CODE="$(curl -sS -o /dev/null -w '%{http_code}' \
    "$SEAM_GH/repos/$INVISIBLE_SLUG$SEAM_PATH")"
  [ "$SEAM_CODE" = "404" ] \
    || { SEAM_SUB_OK="no"; echo "  (/repos/$INVISIBLE_SLUG$SEAM_PATH -> $SEAM_CODE)"; }
done
[ "$SEAM_SUB_OK" = "yes" ] \
  && ok "every route under an invisible repo 404s, not only /repos/:o/:r" \
  || bad "a route under the invisible repo still answered (see above)"

# The counter must stay readable and stay COUNTING while the seam is armed --
# it is answered ahead of every failure mode precisely so a call-count
# assertion is never measuring the failure mode instead.
CALLS_B="$(curl -sS "$SEAM_GH/__calls" | jget "d['calls']" 2>/dev/null || echo "-1")"
curl -sS -o /dev/null "$SEAM_GH/repos/$INVISIBLE_SLUG"
CALLS_A="$(curl -sS "$SEAM_GH/__calls" | jget "d['calls']" 2>/dev/null || echo "-1")"
[ "$CALLS_B" != "-1" ] && [ "$CALLS_A" -gt "$CALLS_B" ] \
  && ok "GET /__calls still answers, and still counts, while the seam is armed" \
  || bad "__calls under the seam: $CALLS_B -> $CALLS_A"

# Through the LIVE manager, on the slug that really is testowner/testrepo
# (ghrepo is the one allowlist entry with a real GitHub URL): another repo
# going dark must cost this one nothing.
# shellcheck disable=SC2086
[ "$($CURL "$BASE/api/repos/ghrepo/branches" | jget "len(d['branches'])")" = "$EXPECTED" ] \
  && ok "the manager still reads testowner/testrepo while another repo is dark" \
  || bad "ghrepo branches under the seam: $($CURL "$BASE/api/repos/ghrepo/branches")"

# The property #98's route will be built on, and validate_base's doctrine
# already states: unverifiable is not the same as absent, and both are the
# caller's to see. Run twice because the two answers come from two different
# server states, and asserting one of them proves nothing about the pair.
cat >"$WORK/preflight-invisible.py" <<'PY'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("cam", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["cam"] = mod
spec.loader.exec_module(mod)

# Set explicitly: this fixture does not run under `env -i`, so an inherited
# GITHUB_API_BASE would let the developer's environment pick the server.
mod.GH_API = sys.argv[2]
mod.GH_PAT = "pat-fixture"
want, slug = sys.argv[3], sys.argv[4]

entry = mod.RepoEntry(name="dark", url="https://github.com/" + slug + ".git")
err = mod.validate_base("dark", entry, "main")
assert err is not None, "validate_base accepted a base it could not read"

if want == "absent":
    # A 404 is an ANSWER: the picker gets a 400 it can print beside the field.
    assert err.status == 400, (err.status, err.message)
    assert err.message == "base branch 'main' does not exist in " + slug, err.message
    # And NOT the credential sentence, which is what gh()'s 401/403 arm would
    # have produced from a 403 fixture.
    assert "PAT" not in err.message, err.message
else:
    # Unverifiable: nothing may be built on it, and it must not read as absent.
    assert err.status == 502, (err.status, err.message)
    assert err.message.startswith("could not check base branch 'main'"), err.message
    assert "does not exist" not in err.message, err.message
PY
if "${MANAGER_PY[@]}" "$WORK/preflight-invisible.py" \
    "$REPO_ROOT/scripts/vps/code-agent-manager.py" "$SEAM_GH" absent "$INVISIBLE_SLUG"
then
  ok "a validate_base-shaped caller reads an invisible repo as an ABSENT base"
else
  bad "invisible base: the 404 did not read as absent (see the assertion above)"
fi

restart_github serverfail
if "${MANAGER_PY[@]}" "$WORK/preflight-invisible.py" \
    "$REPO_ROOT/scripts/vps/code-agent-manager.py" "$SEAM_GH" unverifiable "$INVISIBLE_SLUG"
then
  ok "and a 5xx on the same call is UNVERIFIABLE, which is a different answer"
else
  bad "serverfail base: the 5xx did not read as unverifiable (see above)"
fi

# The regression guard: with the seam UNSET the named slug is served exactly
# like any other, so nothing above this section can have changed meaning.
restart_github ""
SEAM_OFF_CODE="$(curl -sS -o "$WORK/invisible-off.json" -w '%{http_code}' \
  "$SEAM_GH/repos/$INVISIBLE_SLUG")"
[ "$SEAM_OFF_CODE" = "200" ] && grep -q '"default_branch"' "$WORK/invisible-off.json" \
  && ok "with the seam unset the same slug is served like any other repo" \
  || bad "seam unset: $SEAM_OFF_CODE $(cat "$WORK/invisible-off.json")"

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

# ---- 7a. migrating a container baked before #115 ---------------------------
# THE NAMED BROKEN INPUT, staged exactly: a container whose baked
# OPENCODE_SERVER_PASSWORD *is the gateway password*, which is what every chat
# on the brain holds today, plus the cred_epoch 0 that says so. `podman start`
# reuses baked env, so such a container can NEVER acquire the new credential by
# being started — recreating it from the volume is the only way back, and this
# is the assertion that the manager does it.
#
# shellcheck disable=SC2086
$CURL -X POST "$BASE/api/chats/$CID/stop" >/dev/null
python3 -c '
import json, sys
path, pw = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    state = json.load(f)
state["password"] = pw          # the pre-#115 world, verbatim
with open(path, "w", encoding="utf-8") as f:
    json.dump(state, f)
' "$WORK/stub/code-agent-$CID.json" "$PASS"
python3 -c '
import json, sys
path, cid = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    index = json.load(f)
index["chats"][cid]["cred_epoch"] = 0
with open(path, "w", encoding="utf-8") as f:
    json.dump(index, f)
' "$WORK/root/index.json" "$CID"
[ "$(cfield "$CID" password)" = "$PASS" ] \
  && ok "staged a legacy container holding the gateway password" \
  || bad "could not stage the legacy container (staging failed, so what follows is vacuous)"
# shellcheck disable=SC2086
CODE="$($CURL --max-time 120 -o /dev/null -w '%{http_code}' -X POST "$BASE/api/chats/$CID/wake")"
MIGRATED="$(cfield "$CID" password)"
[ "$CODE" = "200" ] && ok "a legacy chat still wakes" \
  || bad "legacy wake returned $CODE (a 502 here is the recreate not happening)"
[ "$MIGRATED" != "$PASS" ] \
  && ok "the recreated container no longer holds the gateway password" \
  || bad "the recreated container was handed the gateway password again"
[ "$MIGRATED" = "$EXPECT_A" ] \
  && ok "the recreated container holds this chat's derived secret" \
  || bad "recreated credential is '$MIGRATED', expected the derivation"
# shellcheck disable=SC2086
CODE="$($CURL --max-time 30 -o /dev/null -w '%{http_code}' "$BASE/chat/$CID/session" || echo 000)"
[ "$CODE" = "200" ] && ok "the migrated chat is reachable through the proxy" \
  || bad "proxy to the migrated chat: HTTP $CODE"
EPOCH_SEEN="$($CURL "$BASE/api/chats" | CID="$CID" python3 -c '
import json, os, sys
row = next(c for c in json.load(sys.stdin)["chats"] if c["id"] == os.environ["CID"])
print(row.get("cred_epoch", "MISSING"))')"
[ "$EPOCH_SEEN" = "$CRED_EPOCH" ] \
  && ok "the epoch is bumped only after the recreated container answered" \
  || bad "cred_epoch after migration is '$EPOCH_SEEN', wanted '$CRED_EPOCH'"

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
import hashlib, hmac, importlib.util, sys, tempfile, time
from pathlib import Path

spec = importlib.util.spec_from_file_location("cam", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["cam"] = mod
spec.loader.exec_module(mod)

tmp = Path(tempfile.mkdtemp())
mod.INDEX_PATH = tmp / "index.json"
mod._reaper_memory.blocked = frozenset()
REAL_RUN_CONTAINER = mod.run_container      # block 5 needs the real one

started = []
mod.engine = lambda *a, **k: started.append(list(a))
mod.run_container = lambda c: started.append(["run", c.id])
mod.notify_failure = lambda m: None


def chat(cid, epoch=None):
    # cred_epoch defaults to the CURRENT one: a chat left at 0 is "baked under
    # an older credential", which sends wake_chat down the recreate path and
    # would silently change what blocks 1-3 are testing.
    return mod.Chat(id=cid, repo="r", title="t", port=1, branch="b",
                    cred_epoch=mod.CRED_EPOCH if epoch is None else epoch,
                    last_active=time.time())


# 1. the cap is full. wait_for_chat MUST be stubbed even though this arm should
#    never reach it: if the 409 guard regressed, the fall-through would poll a
#    dead port for a real 90s and turn a clear failure into a hang.
mod.Index(chats={c: chat(c) for c in ("sleeper", "busy1", "busy2")}).save()
mod.container_state = lambda cid: "stopped" if cid == "sleeper" else "running"
mod.wait_for_chat = lambda chat: "ok"
code, msg = mod.wake_chat("sleeper")
assert code == 409, (code, msg)
assert "already active" in msg, msg
# The discriminator: the fall-through would have called engine("start").
assert started == [], started

# 2. the container starts but opencode never answers.
mod.Index(chats={"lonely": chat("lonely")}).save()
mod.container_state = lambda cid: "stopped"
mod.wait_for_chat = lambda chat: "down"
started.clear()
code, msg = mod.wake_chat("lonely")
assert code == 502, (code, msg)
assert msg == "chat container started but opencode did not answer", msg
assert started == [["start", mod.container_name("lonely")]], started

# 2b. the container is up and REFUSES the credential. Same 502 as block 2, so
#     the MESSAGE is the discriminator: before the tri-state, wait_for_chat
#     returned True on a 401 and this case reported "woken", then 401'd from the
#     proxy with nothing to go on. The fixture starts at epoch 0 so the second
#     half is a real claim -- a refused wake must not record the epoch, or the
#     next one would trust a container that has just refused this one.
mod.Index(chats={"refuser": chat("refuser", epoch=0)}).save()
mod.container_state = lambda cid: "stopped"
mod.wait_for_chat = lambda chat: "refused"
started.clear()
code, msg = mod.wake_chat("refuser")
assert code == 502, (code, msg)
assert "rejected the manager's credential" in msg, msg
assert "rm -f code-agent-refuser" in msg, msg          # the remedy, by name
assert msg != "chat container started but opencode did not answer", msg
assert mod.Index.load().chats["refuser"].cred_epoch == 0, mod.Index.load().chats

# 2c. a container baked under an older epoch is RECREATED, not started, and the
#     epoch is recorded only after it answers. `podman start` reuses baked env,
#     so `start` here would hand the chat back with a credential the manager
#     cannot use -- which is why the discriminator is the engine calls.
mod.Index(chats={"legacy": chat("legacy", epoch=0)}).save()
mod.container_state = lambda cid: "stopped"
mod.wait_for_chat = lambda chat: "ok"
started.clear()
code, msg = mod.wake_chat("legacy")
assert (code, msg) == (200, "woken"), (code, msg)
assert started == [["rm", "-f", mod.container_name("legacy")], ["run", "legacy"]], started
assert mod.Index.load().chats["legacy"].cred_epoch == mod.CRED_EPOCH, mod.Index.load().chats

# 2d. ...and a RUNNING container from an older epoch is recreated too. It would
#     otherwise take the "already running" fast path and keep serving 401s: the
#     credential is baked, so being up says nothing about being usable.
mod.Index(chats={"legacy": chat("legacy", epoch=0)}).save()
mod.container_state = lambda cid: "running"
started.clear()
code, msg = mod.wake_chat("legacy")
assert (code, msg) == (200, "woken"), (code, msg)
assert started == [["rm", "-f", mod.container_name("legacy")], ["run", "legacy"]], started

# 2e. the control for 2c/2d: a container AT the current epoch is started, never
#     recreated. Without this, "recreate everything always" would pass both.
mod.Index(chats={"current": chat("current")}).save()
mod.container_state = lambda cid: "stopped"
started.clear()
code, msg = mod.wake_chat("current")
assert (code, msg) == (200, "woken"), (code, msg)
assert started == [["start", mod.container_name("current")]], started

# 2f. the oldest arm, unchanged by any of this: a container that is simply GONE
#     (removed by an image upgrade, or by the startup sweep) is rebuilt from the
#     volume -- and NOT preceded by an rm, which would be an engine call about a
#     container that does not exist.
mod.Index(chats={"vanished": chat("vanished")}).save()
mod.container_state = lambda cid: "absent"
started.clear()
code, msg = mod.wake_chat("vanished")
assert (code, msg) == (200, "woken"), (code, msg)
assert started == [["run", "vanished"]], started

# 2g. THE ROTATION, which the epoch is blind to. A chat AT the current epoch
#     over a container baked from the OLD root key -- the state every chat on
#     the brain is in the moment OPENCODE_SERVER_PASSWORD is rotated, since
#     cred_epoch tracks a source constant that a rotation does not move. `start`
#     brings the container up, it refuses, and rebuilding it is the only route
#     back. The ENGINE CALLS are the discriminator: a 200 without the rm+run
#     would mean "woken" behind a credential the manager does not have.
mod.Index(chats={"rotated": chat("rotated")}).save()
mod.container_state = lambda cid: "stopped"
verdicts = ["refused", "ok"]
mod.wait_for_chat = lambda chat: verdicts.pop(0)
started.clear()
code, msg = mod.wake_chat("rotated")
assert (code, msg) == (200, "woken"), (code, msg)
assert started == [["start", mod.container_name("rotated")],
                   ["rm", "-f", mod.container_name("rotated")],
                   ["run", "rotated"]], started
assert verdicts == [], "the rebuilt container was never asked whether it answers"

# 2h. ...ONCE. A container that refuses even after being rebuilt is a different
#     fault (a name collision, an engine that reported success without
#     replacing it), and the 502 naming it is worth more than a loop that
#     rebuilds until the request times out. `started` is the discriminator:
#     exactly one rm+run, and the message is still the one with the remedy.
mod.Index(chats={"rotated": chat("rotated")}).save()
mod.wait_for_chat = lambda chat: "refused"
started.clear()
code, msg = mod.wake_chat("rotated")
assert code == 502, (code, msg)
assert "rejected the manager's credential" in msg, msg
assert started == [["start", mod.container_name("rotated")],
                   ["rm", "-f", mod.container_name("rotated")],
                   ["run", "rotated"]], started

# 3. the engine itself raises. RESET wait_for_chat first -- block 2 left it
#    returning "down", and without the reset this takes block 2's arm instead
#    and silently stops testing the exception net.
mod.Index(chats={"lonely": chat("lonely")}).save()
mod.container_state = lambda cid: "stopped"
mod.wait_for_chat = lambda chat: "ok"
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

# 5. an EMPTY OPENCODE_SERVER_PASSWORD. This is the case a length assertion
#    cannot catch, so establish that first: hmac with an empty key does not
#    raise, it returns a perfectly ordinary 64-hex digest -- computed under a
#    key everybody knows, which makes every chat's secret public. So the guard
#    has to refuse the KEY, and this block asserts on the refusal rather than
#    on the shape of what comes out.
public = hmac.new(b"", b"code-agent/1/anychat", hashlib.sha256).hexdigest()
assert len(public) == 64 and all(c in "0123456789abcdef" for c in public), public

saved_password = mod.PASSWORD
mod.PASSWORD = ""
try:
    mod.chat_server_secret("anychat")
except mod.MissingPasswordError:
    pass
else:
    raise AssertionError("chat_server_secret derived a secret from an empty key")

# ...and nothing gets created with it. `calls` is the discriminator: a guard
# placed after the argv was assembled, or after engine() ran, would still raise
# and still leave a container holding a computable credential.
calls = []
mod.engine = lambda *a, **k: calls.append(list(a))
mod.run_container = REAL_RUN_CONTAINER
try:
    mod.run_container(chat("nokey"))
except mod.MissingPasswordError:
    pass
else:
    raise AssertionError("run_container created a container with no password")
assert calls == [], calls
mod.PASSWORD = saved_password
PY
if "${MANAGER_PY[@]}" "$WORK/preflight-wake.py" "$REPO_ROOT/scripts/vps/code-agent-manager.py"
then
  ok "a full cap refuses the wake with 409 and starts nothing"
  ok "a container that starts but never answers is a 502, not a hang"
  ok "a container that refuses the credential is a 502 that names the remedy"
  ok "a refused wake does not record the credential epoch"
  ok "a container below the credential epoch is recreated, stopped or running"
  ok "a container at the current epoch is started, not recreated"
  ok "a container that is gone is rebuilt from the volume, with no pointless rm"
  ok "a container that refuses the rotated credential is rebuilt, then answers"
  ok "the rebuild is tried once, and a second refusal is the 502 with the remedy"
  ok "an engine that raises is a 502 and buzzes a failure"
  ok "touch() on a deleted chat writes nothing, and still writes for a live one"
  ok "an empty password refuses to derive a secret, and creates no container"
else
  bad "wake_chat refusal arms (see the assertion above)"
fi

# ---- 7c. what the proxy answers when the rebuild does NOT fix it -----------
# Section 9f proves the rebuild works. These are the two ways it can fail, and
# both are unreachable from outside: the stub engine bakes exactly what the
# manager hands it, so a container it rebuilds ALWAYS accepts the credential --
# there is no way to stage a rebuild that comes back still refusing.
#
# They matter because the whole point of the arm is that the app never sees a
# bare 401 again. If either of these fell through, the failure mode would be the
# one this PR exists to remove: an auth error at a client whose password is
# correct, naming nothing. So they are asserted against a fake connection.
cat >"$WORK/preflight-proxy.py" <<'PY'
import importlib.util, sys, tempfile, time
from pathlib import Path

spec = importlib.util.spec_from_file_location("cam", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["cam"] = mod
spec.loader.exec_module(mod)

tmp = Path(tempfile.mkdtemp())
mod.INDEX_PATH = tmp / "index.json"
mod.PASSWORD = "root-key"          # the module read an empty env


def chat(epoch):
    return mod.Chat(id="c1", repo="r", title="t", port=1, branch="b",
                    cred_epoch=epoch, last_active=time.time())


class FakeResp:
    def __init__(self, status):
        self.status, self.reads = status, 0

    def read(self):
        self.reads += 1
        return b""


class FakeConn:
    def __init__(self):
        self.closed = 0

    def close(self):
        self.closed += 1


sent, forwarded = [], []


class Fake(mod.Handler):
    # No BaseHTTPRequestHandler.__init__: that one runs an entire request cycle
    # against a socket. The two methods below are the whole surface
    # rebuild_and_replay touches.
    def __init__(self, resp):
        self.resp = resp

    def send_json(self, code, payload):
        sent.append((code, payload))

    def forward(self, chat, target, body, headers):
        forwarded.append(target)
        return FakeConn(), self.resp


# 1. the rebuilt container never answers at all. A 502 that says so -- and
#    NOTHING is forwarded, because replaying at a container that did not come
#    up would only spend the caller's timeout to learn the same thing.
mod.Index(chats={"c1": chat(mod.CRED_EPOCH)}).save()
mod.recreate_container = lambda c: "down"
assert Fake(FakeResp(200)).rebuild_and_replay(chat(mod.CRED_EPOCH), "/session", b"", {}) is None
assert sent[-1][0] == 502, sent
assert sent[-1][1]["error"] == "chat container started but opencode did not answer", sent
assert forwarded == [], forwarded

# 2. the rebuilt container answers and STILL refuses. Exactly one replay, then
#    the 502 naming the container and the remedy -- never the upstream 401.
sent.clear()
mod.recreate_container = lambda c: "ok"
assert Fake(FakeResp(401)).rebuild_and_replay(chat(mod.CRED_EPOCH), "/session", b"", {}) is None
assert forwarded == ["/session"], forwarded
assert sent[-1][0] == 502, sent
assert "rejected the manager's credential" in sent[-1][1]["error"], sent
assert "rm -f code-agent-c1" in sent[-1][1]["error"], sent

# 3. THE CONTROL for both: when the rebuilt container answers the replay, the
#    response is handed back for streaming, nothing is sent to the caller here,
#    and the epoch is recorded -- the container has just proved it holds the
#    current credential, which is the same rule wake_chat follows.
mod.Index(chats={"c1": chat(0)}).save()
sent.clear(), forwarded.clear()
out = Fake(FakeResp(200)).rebuild_and_replay(chat(0), "/session", b"", {})
assert out is not None and out[1].status == 200, out
assert forwarded == ["/session"], forwarded
assert sent == [], sent
assert mod.Index.load().chats["c1"].cred_epoch == mod.CRED_EPOCH, mod.Index.load().chats
PY
if "${MANAGER_PY[@]}" "$WORK/preflight-proxy.py" "$REPO_ROOT/scripts/vps/code-agent-manager.py"
then
  ok "a rebuilt container that never answers is a 502, and nothing is replayed"
  ok "a rebuilt container that still refuses is a 502 with the remedy, not a 401"
  ok "a rebuilt container that answers gets the replay, and the epoch recorded"
else
  bad "proxy rebuild-and-replay arms (see the assertion above)"
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

# 9e. the startup sweep. A deploy that rotates OPENCODE_SERVER_PASSWORD leaves
# every container holding a credential the new process cannot use, and the
# containers are still RUNNING, so nothing else in the manager would look at
# them until somebody made a request. This is the pass that happens first.
#
# Its own root and its own stub state dir, because it plants containers that
# must survive into the manager's startup -- launch_aux wipes its root, and the
# main instance's stub dir is still live.
#
# Three chats: one legacy WITH a container, one already current, and one legacy
# whose container is already gone -- a spun-down chat that was purged by an
# earlier sweep, which is the steady state after the first restart and must not
# make the pass say anything or do anything.
SWEEP_ROOT="$WORK/sweep"; SWEEP_STUB="$WORK/sweep-stub"
mkdir -p "$SWEEP_ROOT/chats/legacy" "$SWEEP_ROOT/chats/fresh" "$SWEEP_STUB"
_sweep_port=$((PORT + 12))
for _n in legacy fresh; do
  STUB_ENGINE_STATE="$SWEEP_STUB" STUB_ENGINE_MOCK="$HERE/mock-opencode-server.py" \
    "$HERE/stub-engine.sh" run -d --name "code-agent-$_n" \
    -p "127.0.0.1:$_sweep_port:4096" -v "$SWEEP_ROOT/chats/$_n:/chat" \
    -e "OPENCODE_SERVER_PASSWORD=baked-$_n" mock serve
  # Stopped, not running: the sweep's claim is about a container EXISTING at an
  # old epoch, and leaving two mock servers bound would fight the ports above.
  STUB_ENGINE_STATE="$SWEEP_STUB" "$HERE/stub-engine.sh" stop "code-agent-$_n"
  _sweep_port=$((_sweep_port + 1))
done
python3 -c '
import json, sys, time
path, epoch = sys.argv[1], int(sys.argv[2])
now = time.time()
def row(cid, e, port):
    return {"id": cid, "repo": "r", "title": cid, "port": port, "branch": "b",
            "base": "", "model": None, "probe": False, "cred_epoch": e,
            "created": now, "last_active": now}
with open(path, "w", encoding="utf-8") as f:
    json.dump({"chats": {"legacy": row("legacy", 0, 4001),
                         "fresh": row("fresh", epoch, 4002),
                         "containerless": row("containerless", 0, 4003)}}, f)
' "$SWEEP_ROOT/index.json" "$CRED_EPOCH"
printf '#!/bin/sh\nexit 1\n' > "$SHIMS/tailscale"; chmod +x "$SHIMS/tailscale"
# Exits 1 on "no tailnet", which happens AFTER the sweep -- so the sweep is
# what this run is for, and the exit is just how it ends.
env -i PATH="$SHIMS:$PATH" HOME="$HOME" CODE_AGENT_ROOT="$SWEEP_ROOT" \
  OPENCODE_SERVER_PASSWORD="$PASS" CODE_AGENT_ENGINE="$HERE/stub-engine.sh" \
  STUB_ENGINE_STATE="$SWEEP_STUB" STUB_ENGINE_MOCK="$HERE/mock-opencode-server.py" \
  "${MANAGER_PY[@]}" "$REPO_ROOT/scripts/vps/code-agent-manager.py" \
  >"$WORK/aux-sweep.log" 2>&1 || true
rm -f "$SHIMS/tailscale"
sweep_exists() { STUB_ENGINE_STATE="$SWEEP_STUB" "$HERE/stub-engine.sh" \
  container exists "code-agent-$1" 2>/dev/null && echo yes || echo no; }
[ "$(sweep_exists legacy)" = "no" ] \
  && ok "startup removes a container baked below the credential epoch" \
  || bad "the startup sweep left the legacy container in place"
# THE DISCRIMINATOR: a sweep with no epoch test would remove this one too, and
# every chat on the brain would be recreated on the next deploy.
[ "$(sweep_exists fresh)" = "yes" ] \
  && ok "startup leaves a container at the current epoch alone" \
  || bad "the startup sweep removed a container that was already current"
grep -q "legacy: container predates credential epoch" "$WORK/aux-sweep.log" \
  && ok "the startup sweep names the chat it recreated" \
  || bad "the sweep said nothing about legacy (log: $WORK/aux-sweep.log)"
# A legacy chat with NO container is already in the state the sweep is trying to
# reach, so it must be silent about it -- otherwise every restart after the
# first re-announces every chat the brain has ever had.
grep -q "containerless: container predates" "$WORK/aux-sweep.log" \
  && bad "the sweep announced a chat that had no container to remove" \
  || ok "a legacy chat with no container is passed over in silence"

# ---- 9f. surviving a rotated OPENCODE_SERVER_PASSWORD, with no hand `rm` ----
# docs/security.md's rotation row promises this: edit secrets.env, restart the
# unit, done. THE EPOCH CANNOT KEEP THAT PROMISE and 9e is not evidence that it
# can -- `cred_epoch` is compared against CRED_EPOCH, a source constant, so
# rotating the root key leaves every chat reading "current" over a container
# baked from the OLD key. 9e's sweep is silent about those, by construction.
# What the manager gets instead is a 401 from the chat's own server, and there
# are exactly two places it can arrive: on a wake (the container is started,
# then refuses) and on a proxied request (the container was already running, so
# nothing woke it). Before this section the first was a 502 telling the operator
# to `podman rm` by hand, and the second was a bare 401 with an empty body --
# the "mysterious 401 that names nothing" wait_for_chat's tri-state exists to
# end, one layer further out.
#
# ITS OWN MANAGER, its own root, its own stub state, and NO REAPER
# (IDLE_SECONDS=3600): every assertion here turns on the exact state a
# container is in, and the deliberately fast reaper the rest of this file needs
# would be free to stop one mid-assertion -- turning "the credential was
# refused" into "there was nobody there", which is the confusion this whole
# mechanism exists to remove.
ROT_ROOT="$WORK/rot"; ROT_STUB="$WORK/rot-stub"
ROT_PORT=$((PORT + 14)); ROT_BASE="http://127.0.0.1:$ROT_PORT"
# The key the containers below were baked under: the one being rotated AWAY
# from. The manager itself runs under $PASS, exactly as it would after the
# secrets.env edit and the restart.
OLD_PASS="rotated-away-$$"
mkdir -p "$ROT_STUB"
for _rot in rotated-up rotated-down stale-up; do
  mkdir -p "$ROT_ROOT/chats/$_rot/home"
done
python3 -c '
import json, sys, time
path, epoch, base = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
now = time.time()
def row(cid, e, port):
    return {"id": cid, "repo": "r", "title": cid, "port": port, "branch": "b",
            "base": "", "model": None, "probe": False, "cred_epoch": e,
            "created": now, "last_active": now}
with open(path, "w", encoding="utf-8") as f:
    # rotated-*: AT the current epoch, which is the whole point -- a rotation
    # does not move it. stale-up: at 0, the pre-#115 world 7a stages.
    json.dump({"chats": {"rotated-up": row("rotated-up", epoch, base),
                         "rotated-down": row("rotated-down", epoch, base + 1),
                         "stale-up": row("stale-up", 0, base + 2)}}, f)
' "$ROT_ROOT/index.json" "$CRED_EPOCH" "$((PORT + 15))"
env -i PATH="$PATH" HOME="$HOME" \
  CODE_AGENT_ROOT="$ROT_ROOT" \
  CODE_AGENT_BIND=127.0.0.1 \
  CODE_AGENT_PORT="$ROT_PORT" \
  CODE_AGENT_ENGINE="$HERE/stub-engine.sh" \
  CODE_AGENT_IMAGE=mock \
  CODE_AGENT_IDLE_SECONDS=3600 \
  CODE_AGENT_REAPER_INTERVAL=3600 \
  CODE_AGENT_GITHUB_INTERVAL=3600 \
  CODE_AGENT_MAX_ACTIVE=5 \
  CODE_AGENT_TLS_CERT="$WORK/no-cert" \
  CODE_AGENT_TLS_KEY="$WORK/no-key" \
  GITHUB_API_BASE="http://127.0.0.1:$GH_PORT" \
  STUB_ENGINE_STATE="$ROT_STUB" \
  STUB_ENGINE_MOCK="$HERE/mock-opencode-server.py" \
  OPENCODE_SERVER_PASSWORD="$PASS" \
  "${MANAGER_PY[@]}" "$REPO_ROOT/scripts/vps/code-agent-manager.py" \
  >"$WORK/aux-rot.log" 2>&1 &
ROT_PID=$!
for _ in $(seq 1 40); do
  curl -sS --max-time 2 -o /dev/null -u "opencode:$PASS" "$ROT_BASE/api/health" 2>/dev/null && break
  sleep 0.25
done
rot_engine() { STUB_ENGINE_STATE="$ROT_STUB" \
  STUB_ENGINE_MOCK="$HERE/mock-opencode-server.py" "$HERE/stub-engine.sh" "$@"; }
rot_cfield() { python3 -c '
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]])' \
  "$ROT_STUB/code-agent-$1.json" "$2"; }
rot_state() { rot_engine container inspect --format '{{.State.Status}}' \
  "code-agent-$1" 2>/dev/null || echo absent; }
# --max-time 120, where code_at allows 10: each of these requests deliberately
# triggers a container rebuild INSIDE the request (an engine run plus
# wait_for_chat's poll loop), which code_at's budget was never sized for -- and
# a timeout would print as 000 and read as a refusal.
rot_get() { curl -sS --max-time 120 -o /dev/null -w '%{http_code}' \
  -u "opencode:$PASS" "$ROT_BASE/chat/$1/session" || echo 000; }
plant() { # plant <chat-id> <port> <baked-password>
  rot_engine run -d --name "code-agent-$1" -p "127.0.0.1:$2:4096" \
    -v "$ROT_ROOT/chats/$1:/chat" -e "OPENCODE_SERVER_PASSWORD=$3" mock serve
}
# PLANTED AFTER THE MANAGER IS UP, and that is load bearing for stale-up: the
# startup sweep removes epoch-0 containers, so a container planted before the
# launch would simply be gone. Running AND below the epoch is the state a sweep
# whose `engine("rm", check=False)` silently failed leaves behind, and nothing
# else in this file produces it -- 7a stops the chat first, so its
# container_state is never "running" and the proxy's epoch test is never the
# clause that fires.
plant rotated-up   "$((PORT + 15))" "$(derive "$OLD_PASS" "$CRED_EPOCH" rotated-up)"
plant rotated-down "$((PORT + 16))" "$(derive "$OLD_PASS" "$CRED_EPOCH" rotated-down)"
rot_engine stop code-agent-rotated-down
# stale-up holds the GATEWAY password, which is what every container baked
# before #115 holds -- 7a stages the same thing. It is refused all the same:
# the manager signs with the derivation, never with PASSWORD.
plant stale-up     "$((PORT + 17))" "$PASS"
# Wait for the two that stay up to be LISTENING, not merely spawned. `podman
# ps` (and the stub's `alive`) says running the moment the process exists, and
# a request that lands in that gap comes back "chat unreachable" -- a 502 that
# would read as a rebuild failure. Unauthenticated on purpose: a 401 proves the
# socket is answering, which is all this loop is for.
for _rot_port in "$((PORT + 15))" "$((PORT + 17))"; do
  for _ in $(seq 1 40); do
    curl -sS --max-time 2 -o /dev/null "http://127.0.0.1:$_rot_port/session" 2>/dev/null && break
    sleep 0.25
  done
done
NEW_UP="$(derive "$PASS" "$CRED_EPOCH" rotated-up)"
NEW_DOWN="$(derive "$PASS" "$CRED_EPOCH" rotated-down)"
NEW_STALE="$(derive "$PASS" "$CRED_EPOCH" stale-up)"

# The staging's own controls. Every assertion below reads "the baked value was
# replaced", which is worth nothing unless the planted value was different to
# begin with and the containers really are in the states named.
ROT_STATES="$(rot_state rotated-up)/$(rot_state rotated-down)/$(rot_state stale-up)"
[ "$ROT_STATES" = "running/exited/running" ] \
  && ok "staged: two containers up and one stopped, ahead of a rotation" \
  || bad "rotation staging failed (states were $ROT_STATES, wanted running/exited/running)"
[ "$(rot_cfield rotated-up password)" != "$NEW_UP" ] \
  && [ "$(rot_cfield rotated-down password)" != "$NEW_DOWN" ] \
  && [ "$(rot_cfield stale-up password)" = "$PASS" ] \
  && ok "control: every staged container holds a pre-rotation secret" \
  || bad "staging is vacuous -- a container already holds the post-rotation secret"

# 1. THE PROXY. A running container, at the current epoch, holding a secret
#    derived from the old key: nothing in the manager's own state says anything
#    is wrong, so the 401 the container returns is the only evidence there is.
ROT_CODE="$(rot_get rotated-up)"
[ "$ROT_CODE" = "200" ] \
  && ok "a rotated password heals on the first proxied request" \
  || bad "proxy after a rotation: HTTP $ROT_CODE (401 = the bare 401 that names nothing)"
[ "$(rot_cfield rotated-up password)" = "$NEW_UP" ] \
  && ok "...by rebuilding the container on the NEW derived secret, with no hand rm" \
  || bad "the container still holds the pre-rotation secret after a proxied request"
grep -q "rotated-up: the chat's own server refused" "$WORK/aux-rot.log" \
  && ok "...and the manager says which container it rebuilt, and why" \
  || bad "nothing in the log names the refusal (log: $WORK/aux-rot.log)"

# 2. THE WAKE. Same rotation, but the container was stopped, so `podman start`
#    hands it back with the OLD env baked in -- which is exactly why starting it
#    can never be the fix, and why the 401 that follows has to be acted on.
ROT_CODE="$(curl -sS --max-time 120 -o /dev/null -w '%{http_code}' \
  -u "opencode:$PASS" -X POST "$ROT_BASE/api/chats/rotated-down/wake" || echo 000)"
[ "$ROT_CODE" = "200" ] \
  && ok "an explicit wake after a rotation returns 200, not 'rejected the credential'" \
  || bad "wake after a rotation: HTTP $ROT_CODE (502 = the runbook needs a hand rm)"
[ "$(rot_cfield rotated-down password)" = "$NEW_DOWN" ] \
  && ok "...having started it, seen the refusal, and rebuilt it once" \
  || bad "wake left the pre-rotation secret baked in"
grep -q "rotated-down: container refused the current credential" "$WORK/aux-rot.log" \
  && ok "...and names the rotation in the log rather than a boot timeout" \
  || bad "the wake said nothing about a refused credential"

# 3. THE PROXY'S EPOCH TEST, which is a DIFFERENT clause from 1: this container
#    is running too, but the manager can already see it is stale, so it must
#    rebuild BEFORE forwarding instead of discovering it with a refused request.
#    The status alone cannot show that -- arm 1 would heal this one as well --
#    so the discriminator is which of the two the manager logged.
ROT_CODE="$(rot_get stale-up)"
[ "$ROT_CODE" = "200" ] && [ "$(rot_cfield stale-up password)" = "$NEW_STALE" ] \
  && ok "a RUNNING container below the credential epoch is rebuilt by the proxy" \
  || bad "running+stale via the proxy: HTTP $ROT_CODE, baked $(rot_cfield stale-up password)"
grep -qE "stale-up: container predates credential epoch .*rebuilding" "$WORK/aux-rot.log" \
  && ok "...routed through wake_chat by the epoch test, before any forwarding" \
  || bad "the proxy did not take the epoch path for a running stale container"
grep -q "stale-up: the chat's own server refused" "$WORK/aux-rot.log" \
  && bad "the proxy forwarded to a container it already knew was stale" \
  || ok "...so no request was ever sent under a credential known to be refused"
kill "$ROT_PID" 2>/dev/null || true; ROT_PID=""

echo
echo "== summary: $PASS_COUNT passed, $FAIL_COUNT failed =="
if [ "$FAIL_COUNT" -ne 0 ]; then
  echo "---- manager.log (tail) ----"; tail -30 "$WORK/manager.log"
  exit 1
fi
