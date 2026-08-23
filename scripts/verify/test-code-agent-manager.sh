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
PASS="test-secret-$$"
BASE="http://127.0.0.1:$PORT"
CURL="curl -sS --max-time 30 -u opencode:$PASS"

PASS_COUNT=0; FAIL_COUNT=0
ok()  { echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
bad() { echo "FAIL  $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
jget() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }
cstate() { STUB_ENGINE_STATE="$WORK/stub" "$HERE/stub-engine.sh" container inspect --format '{{.State.Status}}' "code-agent-$1" 2>/dev/null || echo absent; }

MANAGER_PID=""
cleanup() {
  [ -n "$MANAGER_PID" ] && kill "$MANAGER_PID" 2>/dev/null || true
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
env -i PATH="$PATH" HOME="$HOME" \
  CODE_AGENT_BIND=127.0.0.1 \
  CODE_AGENT_PORT=$PORT \
  CODE_AGENT_ROOT="$WORK/root" \
  CODE_AGENT_ENGINE="$HERE/stub-engine.sh" \
  CODE_AGENT_IMAGE=mock \
  CODE_AGENT_IDLE_SECONDS=4 \
  CODE_AGENT_REAPER_INTERVAL=2 \
  CODE_AGENT_MAX_ACTIVE=2 \
  CODE_AGENT_TLS_CERT="$WORK/no-cert" \
  CODE_AGENT_TLS_KEY="$WORK/no-key" \
  STUB_ENGINE_STATE="$WORK/stub" \
  STUB_ENGINE_MOCK="$HERE/mock-opencode-server.py" \
  OPENCODE_SERVER_PASSWORD="$PASS" \
  GITHUB_CODE_AGENT_PAT="fake-pat-for-tests" \
  OPENCODE_ZEN_API_KEY="fake-zen-key" \
  python3 "$REPO_ROOT/scripts/vps/code-agent-manager.py" \
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
  [ "$(stat -c %a "$CD/home/.local/share/opencode/auth.json" 2>/dev/null)" = "600" ] \
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
# shellcheck disable=SC2086
$CURL --max-time 120 "$BASE/chat/$CID/session/$SID/diff" | grep -q '"README.md"' \
  && ok "diff endpoint proxied" || bad "diff failed"

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
