#!/usr/bin/env bash
# check-code-agents.sh — verification for the code-agents plane: container
# engine + image, the session manager (TLS + auth), the repo allowlist, disk
# footprint, and (with --probe) a full create/isolate/spin-down/wake/delete
# lifecycle on a self-contained scratch chat. Run on the brain (over SSH) or
# from the Mac across the tailnet — it detects which side it's on.
# Concept + operations: docs/code-agents.md. Criteria: repo issue #17 (F2).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: check-code-agents.sh [--probe] [--insecure] [--local] [--help]

  --probe     run the deep lifecycle probe: creates a `_probe` chat (local
              scratch repo — no network, no credential), verifies container
              isolation and the minimized environment, exercises stop/wake,
              then deletes it with its volume. Local mode only.
  --insecure  pass -k to curl for gateway probes (before the LE cert exists).
  --local     force local mode (default: auto-detected via /data/code-agents).

Remote mode needs BRAIN_HOST set to the brain's tailnet name and
OPENCODE_SERVER_PASSWORD exported. Exits non-zero if any automated check fails.
EOF
}

PROBE="no"; INSECURE="no"; FORCE_LOCAL="no"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --probe)    PROBE="yes" ;;
    --insecure) INSECURE="yes" ;;
    --local)    FORCE_LOCAL="yes" ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "check-code-agents.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

PASS_COUNT=0; FAIL_COUNT=0
pass() { echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL  $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
note() { echo "      $1"; }

PORT=4300
MAX_DISK_GB="${CODE_AGENT_MAX_DISK_GB:-20}"

# ---- mode detection ---------------------------------------------------------
MODE="remote"
if [ "$FORCE_LOCAL" = "yes" ] || { [ -e /data/code-agents ] && command -v systemctl >/dev/null 2>&1; }; then
  MODE="local"
fi
if [ "$MODE" = "local" ]; then
  if [ -z "${OPENCODE_SERVER_PASSWORD:-}" ] && [ -r /data/secrets.env ]; then
    set -a
    # shellcheck disable=SC1091
    . /data/secrets.env
    set +a
  fi
  HOST="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  [ -n "$HOST" ] || HOST="127.0.0.1"
else
  BRAIN_HOST="${BRAIN_HOST:-<your-brain>.<your-tailnet>.ts.net}"
  case "$BRAIN_HOST" in
    *"<"*) echo "check-code-agents.sh: set BRAIN_HOST first (see --help)" >&2; exit 2 ;;
  esac
  HOST="$BRAIN_HOST"
  if [ "$PROBE" = "yes" ]; then
    echo "NOTE: --probe is local-only (it uses podman exec); skipping probe checks."
    PROBE="no"
  fi
fi

brain_exec() {
  if [ "$MODE" = "local" ]; then "$@"; else
    ssh -o BatchMode=yes -o ConnectTimeout=10 "agent@$BRAIN_HOST" "$@"
  fi
}

CURL="curl -sS --max-time 15"
[ "$INSECURE" = "yes" ] && CURL="$CURL -k"
BASE="https://$HOST:$PORT"
AUTH=""
if [ -n "${OPENCODE_SERVER_PASSWORD:-}" ]; then
  AUTH="-u opencode:$OPENCODE_SERVER_PASSWORD"
fi

echo "== check-code-agents (mode: $MODE) =="
echo

# ---- 1. engine + image ------------------------------------------------------
if brain_exec podman --version >/dev/null 2>&1; then
  pass "podman present"
else
  fail "podman not found — re-run deploy-vps.sh (it installs the engine)"
fi
if brain_exec podman image exists code-agent:local 2>/dev/null; then
  pass "code-agent:local image built"
else
  fail "code-agent:local image missing — deploy-vps.sh builds it from config/code-agents/Containerfile"
fi

# ---- 2. manager service -----------------------------------------------------
SVC_STATE="$(brain_exec systemctl is-active code-agent-manager 2>&1 || true)"
if [ "$SVC_STATE" = "active" ]; then
  pass "systemctl is-active code-agent-manager"
else
  fail "code-agent-manager not active (got: ${SVC_STATE:-no answer})"
  note "Not enabled until OPENCODE_SERVER_PASSWORD and GITHUB_CODE_AGENT_PAT are in"
  note "secrets.env (deploy-vps.sh enables it then). After a reboot: luks-unlock.sh first."
  note "Logs: journalctl -u code-agent-manager -n 50"
fi

# ---- 3. gateway: TLS + auth enforced ----------------------------------------
if [ -n "$AUTH" ]; then
  # shellcheck disable=SC2086
  CODE="$($CURL $AUTH -o /dev/null -w '%{http_code}' "$BASE/api/health" 2>/dev/null || echo 000)"
  case "$CODE" in
    200) pass "gateway /api/health authenticated (200)" ;;
    000) fail "gateway unreachable at $BASE (TLS refused? try --insecure; cert: renew-tls-cert.sh)" ;;
    *)   fail "gateway /api/health returned HTTP $CODE" ;;
  esac
else
  fail "OPENCODE_SERVER_PASSWORD not set — cannot test the authenticated path"
fi
# shellcheck disable=SC2086
CODE="$($CURL -o /dev/null -w '%{http_code}' "$BASE/api/health" 2>/dev/null || echo 000)"
if [ "$CODE" = "401" ]; then
  pass "gateway refuses unauthenticated requests (401)"
elif [ "$CODE" = "000" ]; then
  note "SKIP unauth check — gateway unreachable (see check 3)"
else
  fail "gateway answered HTTP $CODE without credentials — expected 401"
fi

# ---- 4. allowlist -----------------------------------------------------------
if brain_exec test -f /data/code-agents/repos.json 2>/dev/null; then
  if brain_exec python3 -c 'import json,sys; d=json.load(open("/data/code-agents/repos.json")); sys.exit(0 if d.get("repos") else 3)' 2>/dev/null; then
    pass "repos.json is valid JSON with at least one repo"
  else
    fail "repos.json invalid or empty — copy config/code-agents/repos.example.json and edit"
  fi
  if brain_exec grep -qi 'life-vault' /data/code-agents/repos.json 2>/dev/null; then
    fail "repos.json mentions the life vault — Tier-3 repos are never allowlistable (docs/privacy.md)"
  else
    pass "no vault/Tier-3 repo in the allowlist"
  fi
else
  fail "/data/code-agents/repos.json missing (deploy copies the example; edit it)"
fi

# ---- 5. PAT + disk footprint ------------------------------------------------
if [ "$MODE" = "local" ]; then
  if [ -n "${GITHUB_CODE_AGENT_PAT:-}" ]; then
    pass "GITHUB_CODE_AGENT_PAT present in secrets.env"
    note "Scope check is manual: fine-grained, ONLY the allowlisted repos,"
    note "ONLY Contents + Pull requests read/write (github.com/settings/personal-access-tokens)"
  else
    fail "GITHUB_CODE_AGENT_PAT empty — clones of private repos and agent push/PR will fail"
  fi
  USED_KB="$(du -sk /data/code-agents 2>/dev/null | cut -f1 || echo 0)"
  USED_GB=$((USED_KB / 1024 / 1024))
  if [ "$USED_GB" -lt "$MAX_DISK_GB" ]; then
    pass "chat volumes footprint ${USED_GB}GB < ${MAX_DISK_GB}GB"
  else
    fail "chat volumes at ${USED_GB}GB (>= ${MAX_DISK_GB}GB) — delete old chats (the app, or DELETE /api/chats/<id>?purge=1)"
  fi
fi

# ---- 6. deep probe (--probe, local) -----------------------------------------
if [ "$PROBE" = "yes" ] && [ -n "$AUTH" ]; then
  echo
  echo "-- probe: full chat lifecycle on a scratch repo --"
  # shellcheck disable=SC2086
  CHAT_JSON="$($CURL $AUTH -X POST -H 'Content-Type: application/json' \
      -d '{"repo":"_probe","task":"verify probe"}' "$BASE/api/chats" || true)"
  CID="$(printf '%s' "$CHAT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
  if [ -n "$CID" ]; then
    pass "probe chat created ($CID)"
    CN="code-agent-$CID"

    # Minimized environment: none of the stack's other secrets may exist.
    LEAKED=""
    for var in GOOGLE_OAUTH_CLIENT_SECRET TELEGRAM_BOT_TOKEN NTFY_TOPIC GOOSE_SERVER__SECRET_KEY OPENCODE_ZEN_API_KEY; do
      if podman exec "$CN" sh -c "printenv $var" >/dev/null 2>&1; then LEAKED="$LEAKED $var"; fi
    done
    if [ -z "$LEAKED" ]; then
      pass "container env is minimized (no stack secrets leaked)"
    else
      fail "container env leaks:$LEAKED"
    fi

    # Isolation: host paths must not exist inside the container.
    ISOLATED="yes"
    for p in /data/secrets.env /data/life-vault /data/goose /data/goose-data; do
      if podman exec "$CN" sh -c "test -e $p" >/dev/null 2>&1; then ISOLATED="no"; note "reachable: $p"; fi
    done
    if [ "$ISOLATED" = "yes" ]; then
      pass "container cannot reach /data (secrets, vault, goose data)"
    else
      fail "container reaches host paths it must not"
    fi

    # Zen auth seeded + opencode answering with the chat's own state.
    if podman exec "$CN" sh -c 'test -s /chat/home/.local/share/opencode/auth.json' >/dev/null 2>&1; then
      pass "auth.json seeded in the chat volume"
    else
      note "auth.json absent (OPENCODE_ZEN_API_KEY unset?) — zen models won't resolve"
    fi

    # Spin-down / wake with state intact (issue #17 B2/B3).
    # shellcheck disable=SC2086
    $CURL $AUTH -X POST "$BASE/api/chats/$CID/stop" >/dev/null 2>&1 || true
    sleep 2
    if [ "$(podman inspect --format '{{.State.Status}}' "$CN" 2>/dev/null)" != "running" ]; then
      pass "stop: container down (volume kept)"
    else
      fail "stop did not stop the container"
    fi
    # shellcheck disable=SC2086
    WAKE_CODE="$($CURL $AUTH -o /dev/null -w '%{http_code}' -X POST "$BASE/api/chats/$CID/wake" || echo 000)"
    if [ "$WAKE_CODE" = "200" ] && podman exec "$CN" sh -c "git -C /chat/workspace rev-parse --abbrev-ref HEAD" 2>/dev/null | grep -q "^agent/"; then
      pass "wake: container back with workspace + agent/ branch intact"
    else
      fail "wake failed or workspace state lost (HTTP $WAKE_CODE)"
    fi

    # Cleanup (purges the scratch volume).
    # shellcheck disable=SC2086
    $CURL $AUTH -X DELETE "$BASE/api/chats/$CID?purge=1" >/dev/null 2>&1 || true
    if podman container exists "$CN" 2>/dev/null; then
      fail "probe chat container not removed"
    else
      pass "probe chat deleted (container + volume)"
    fi
  else
    fail "probe chat create failed"
    note "response: $(printf '%s' "$CHAT_JSON" | head -c 200)"
    note "journalctl -u code-agent-manager -n 30"
  fi
elif [ "$PROBE" = "yes" ]; then
  note "SKIP probe — OPENCODE_SERVER_PASSWORD not available"
else
  echo "SKIP  lifecycle probe (re-run with --probe for the deep checks)"
fi

# ---- 7. manual checklist ----------------------------------------------------
cat <<'EOF'

== manual checklist — the things only you can verify ==

  [ ] External port scan still clean after enabling code agents:
      ./scripts/verify/check-security.sh <server-public-ip>
  [ ] App pairing: goose-phone-app Code tab (or the OpenCode desktop app /
      a phone browser) pointed at https://<brain>.<tailnet>.ts.net:4300
      with the OPENCODE_SERVER_PASSWORD — chat list loads.
  [ ] Permission flow: in a real chat, ask the agent to `git push` — the
      ask pops on your device and push proceeds only on approval.
  [ ] PR flow: agent pushes its agent/ branch and opens the PR (gh);
      commits show the code-agent identity, never your name/email.
  [ ] Notification: the PR email arrives; a forced failure alerts via ntfy.

EOF

echo "== summary: $PASS_COUNT passed, $FAIL_COUNT failed =="
[ "$FAIL_COUNT" -eq 0 ] || exit 1
