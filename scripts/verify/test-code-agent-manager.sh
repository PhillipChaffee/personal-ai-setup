#!/usr/bin/env bash
# test-code-agent-manager.sh — end-to-end integration test of the code-agent
# plane with NO containers and NO VPS: the manager runs for real, chats are
# mock-opencode-server.py processes behind stub-engine.sh, and the repo being
# "cloned" is a local scratch git repo. Exercises the full lifecycle:
#
#   auth · allowlist + zen-free guards · create (clone/branch/setup/config/
#   auth seed) · max-active refusal · proxying incl. SSE · the blocking
#   permission flow · busy-guarded idle spin-down · wake-on-request with
#   state intact · stop/wake/delete-purge
#
# Runs anywhere with python3 + git + curl. Exits non-zero on any failure.
#
# --serve: instead of running assertions, stand the stack up (manager + stub
# engine + fixtures) and stay in the foreground, printing the connection env
# — for driving other clients at it (e.g. goose-phone-app's
# `cargo run -p opencode-client --example smoke`). Ctrl-C tears it down.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/code-agent-test.XXXXXX")"
PORT=4399
# The assertions want a reaper that fires while the test is still watching.
# `--serve` does not: a 4-second idle timeout means a client being driven by
# hand re-wakes the container between every tap. Override for that case.
IDLE_SECONDS="${IDLE_SECONDS:-4}"
PASS="test-secret-$$"
BASE="http://127.0.0.1:$PORT"
CURL="curl -sS --max-time 30 -u opencode:$PASS"

PASS_COUNT=0; FAIL_COUNT=0
ok()  { echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
bad() { echo "FAIL  $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
jget() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }
cstate() { STUB_ENGINE_STATE="$WORK/stub" "$HERE/stub-engine.sh" container inspect --format '{{.State.Status}}' "code-agent-$1" 2>/dev/null || echo absent; }

MANAGER_PID=""
GITHUB_PID=""
cleanup() {
  [ -n "$MANAGER_PID" ] && kill "$MANAGER_PID" 2>/dev/null || true
  [ -n "$GITHUB_PID" ] && kill "$GITHUB_PID" 2>/dev/null || true
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

cat > "$WORK/root/repos.json" <<EOF
{"repos": [
  {"name": "testrepo", "url": "file://$WORK/seed", "tier": 1,
   "setup": "touch /chat/workspace/setup-ran.marker",
   "edit_only": false, "allow_push": false, "public_throwaway": false},
  {"name": "throwaway", "url": "file://$WORK/seed", "tier": 1,
   "setup": "", "edit_only": true, "allow_push": true, "public_throwaway": true}
]}
EOF

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
GH_PORT=4398
FAKE_GITHUB_BRANCH="agent/testrepo-fixture" \
  python3 "$HERE/fake-github.py" --port "$GH_PORT" &
GITHUB_PID=$!
for _ in $(seq 1 20); do
  curl -sS -o /dev/null "http://127.0.0.1:$GH_PORT/repos/testowner/testrepo/pulls" && break
  sleep 0.3
done

env -i PATH="$PATH" HOME="$HOME" \
  CODE_AGENT_BIND=127.0.0.1 \
  CODE_AGENT_PORT=$PORT \
  CODE_AGENT_ROOT="$WORK/root" \
  CODE_AGENT_ENGINE="$HERE/stub-engine.sh" \
  CODE_AGENT_IMAGE=mock \
  CODE_AGENT_IDLE_SECONDS="$IDLE_SECONDS" \
  CODE_AGENT_REAPER_INTERVAL=2 \
  CODE_AGENT_MAX_ACTIVE=2 \
  CODE_AGENT_TLS_CERT="$WORK/no-cert" \
  CODE_AGENT_TLS_KEY="$WORK/no-key" \
  STUB_ENGINE_STATE="$WORK/stub" \
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
# shellcheck disable=SC2086
CODE="$($CURL -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d '{"repo":"testrepo","task":"third"}' "$BASE/api/chats")"
[ "$CODE" = "409" ] && ok "max-active refusal (409) at the cap" || bad "cap: got $CODE"
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
sleep 1

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
sleep 1
grep -q "permission.updated" "$WORK/sse.log" \
  && ok "SSE events arrive live while the turn is still blocked" \
  || bad "SSE buffered — events not delivered until close (proxy must use read1)"

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
assert set(got) == {12, 11, 10, 9, 8}, f"wrong set: {sorted(got)}"
assert got[12]["mergeable"] is True, "mergeable lost — the detail call is missing"
assert got[12]["checks"] == "passing", got[12]["checks"]
assert got[11]["checks"] == "failing", got[11]["checks"]
assert got[10]["mergeable"] is None, "null mergeable was coerced"
assert got[10]["checks"] == "pending", got[10]["checks"]
assert got[9]["draft"] is True
assert got[8]["state"] == "merged", got[8]["state"]
' && ok "pulls listed for this branch only, with mergeable and checks" \
  || bad "pulls payload wrong: $PULLS"

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
  FAKE_GITHUB_BRANCH="agent/testrepo-fixture" FAKE_GITHUB_MODE="$1" \
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
# shellcheck disable=SC2086
$CURL -X DELETE "$BASE/api/chats/$CID?purge=1" >/dev/null
[ ! -d "$WORK/root/chats/$CID" ] && ok "final delete purges" || bad "final purge failed"

echo
echo "== summary: $PASS_COUNT passed, $FAIL_COUNT failed =="
if [ "$FAIL_COUNT" -ne 0 ]; then
  echo "---- manager.log (tail) ----"; tail -30 "$WORK/manager.log"
  exit 1
fi
