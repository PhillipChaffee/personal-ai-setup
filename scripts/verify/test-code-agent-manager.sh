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
for r in records:
    assert r["topic"] == agent_topic, f"wrong topic: {r['topic']!r}"
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
asks = [r for r in records if r["body"]["kind"] == "ask"]
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

echo
echo "== summary: $PASS_COUNT passed, $FAIL_COUNT failed =="
if [ "$FAIL_COUNT" -ne 0 ]; then
  echo "---- manager.log (tail) ----"; tail -30 "$WORK/manager.log"
  exit 1
fi
