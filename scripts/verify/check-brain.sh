#!/usr/bin/env bash
# check-brain.sh — Phase 3 verification of the VPS brain: goose-serve service,
# /status over TLS, the schedule roster, an optional live run-now, and the
# manual cross-device checklist. Run it on the brain itself (over SSH) or from
# the Mac across the tailnet — it detects which side it's on.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: check-brain.sh [--insecure] [--run-now] [--local] [--help]

  --insecure  pass -k to curl for the /status check. goose serve's TLS cert
              is self-signed (clients pin its fingerprint instead of using a
              CA), so plain curl may refuse it; -k only skips verification
              for THIS smoke test — never weaken the clients.
  --run-now   trigger `goose schedule run-now --schedule-id morning-brief`
              without prompting (costs one recipe run; sends a real email).
  --local     force local mode (default: auto-detected via /data/goose-data).

Remote mode needs BRAIN_HOST set to the brain's tailnet name, e.g.:
  BRAIN_HOST=<your-brain>.<your-tailnet>.ts.net ./scripts/verify/check-brain.sh
and SSH access as agent@$BRAIN_HOST (keys only; see docs/security.md).
Exits non-zero if any automated check fails.
EOF
}

INSECURE="no"
RUN_NOW="ask"
FORCE_LOCAL="no"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --insecure) INSECURE="yes" ;;
    --run-now)  RUN_NOW="yes" ;;
    --local)    FORCE_LOCAL="yes" ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "check-brain.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL  $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ---- mode detection ---------------------------------------------------------
MODE="remote"
if [ "$FORCE_LOCAL" = "yes" ] || { [ -e /data/goose-data ] && command -v systemctl >/dev/null 2>&1; }; then
  MODE="local"
fi

GOOSE_BIN="goose"
if [ "$MODE" = "local" ]; then
  command -v goose >/dev/null 2>&1 || GOOSE_BIN="/home/agent/.local/bin/goose"
  # Load GOOSE_SERVER__SECRET_KEY etc. for the checks below.
  if [ -z "${GOOSE_SERVER__SECRET_KEY:-}" ] && [ -r /data/secrets.env ]; then
    set -a
    # shellcheck disable=SC1091
    . /data/secrets.env
    set +a
  fi
  if command -v tailscale >/dev/null 2>&1; then
    STATUS_HOST="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  else
    STATUS_HOST=""
  fi
  if [ -z "$STATUS_HOST" ]; then
    STATUS_HOST="127.0.0.1"
    echo "NOTE: no Tailscale IPv4 found; probing /status on 127.0.0.1 (it will"
    echo "      fail — goose serve binds the tailnet address only, by design)."
  fi
else
  BRAIN_HOST="${BRAIN_HOST:-<your-brain>.<your-tailnet>.ts.net}"
  case "$BRAIN_HOST" in
    *"<"*)
      echo "check-brain.sh: set BRAIN_HOST to your brain's tailnet name first, e.g." >&2
      echo "  BRAIN_HOST=brain.example-tailnet.ts.net $0" >&2
      exit 2
      ;;
  esac
  STATUS_HOST="$BRAIN_HOST"
fi

# Run a command on the brain, wherever this script is executing.
brain_exec() {
  if [ "$MODE" = "local" ]; then
    "$@"
  else
    ssh -o BatchMode=yes -o ConnectTimeout=10 "agent@$BRAIN_HOST" "$@"
  fi
}

echo "== check-brain (mode: $MODE) =="
[ "$MODE" = "remote" ] && echo "brain: agent@$BRAIN_HOST"
echo

# ---- 1. systemd: goose-serve active ----------------------------------------
SVC_STATE="$(brain_exec systemctl is-active goose-serve 2>&1 || true)"
if [ "$SVC_STATE" = "active" ]; then
  pass "systemctl is-active goose-serve"
else
  fail "systemctl is-active goose-serve (got: ${SVC_STATE:-no answer})"
  if [ "$MODE" = "remote" ]; then
    echo "      If plain ssh failed, try Tailscale SSH: tailscale ssh agent@$BRAIN_HOST"
  fi
  echo "      After a reboot this is EXPECTED until luks-unlock.sh runs"
  echo "      (docs/setup/50-vps-brain.md §10). Otherwise: journalctl -u goose-serve"
fi

# ---- 2. goose serve /status over TLS ---------------------------------------
CURL_OPTS="-sS --max-time 10 -o /dev/null -w %{http_code}"
if [ "$INSECURE" = "yes" ]; then
  CURL_OPTS="$CURL_OPTS -k"
  echo "WARNING: --insecure skips TLS verification for this probe only. The"
  echo "         real clients (Desktop/iOS) must keep pinning the cert fingerprint."
fi
STATUS_URL="https://$STATUS_HOST:3284/status"
if [ -n "${GOOSE_SERVER__SECRET_KEY:-}" ]; then
  # shellcheck disable=SC2086
  HTTP_STATUS="$(curl $CURL_OPTS -H "X-Secret-Key: $GOOSE_SERVER__SECRET_KEY" "$STATUS_URL" 2>/dev/null)" || HTTP_STATUS="000"
else
  # shellcheck disable=SC2086
  HTTP_STATUS="$(curl $CURL_OPTS "$STATUS_URL" 2>/dev/null)" || HTTP_STATUS="000"
fi
case "$HTTP_STATUS" in
  200)
    pass "goose serve /status over TLS ($STATUS_URL)"
    ;;
  401|403)
    pass "goose serve /status reachable over TLS — auth enforced (HTTP $HTTP_STATUS)"
    [ -z "${GOOSE_SERVER__SECRET_KEY:-}" ] && \
      echo "      (export GOOSE_SERVER__SECRET_KEY to verify the authenticated path too)"
    ;;
  000)
    # Distinguish TLS refusal from no listener: retry once with -k.
    RETRY="$(curl -sS --max-time 10 -k -o /dev/null -w '%{http_code}' "$STATUS_URL" 2>/dev/null)" || RETRY="000"
    if [ "$RETRY" != "000" ]; then
      pass "goose serve /status reachable (TLS is self-signed — re-run with --insecure to silence curl; clients pin the fingerprint instead)"
    else
      fail "goose serve /status — no answer at $STATUS_URL"
      echo "      Checks: is this machine on the tailnet (tailscale status)? Is the"
      echo "      service up (check 1)? Does the port match (3284)?"
    fi
    ;;
  *)
    fail "goose serve /status (HTTP $HTTP_STATUS at $STATUS_URL)"
    ;;
esac

# ---- 3. schedule roster -----------------------------------------------------
if [ "$MODE" = "local" ]; then
  SCHEDULES="$("$GOOSE_BIN" schedule list 2>&1 || true)"
else
  SCHEDULES="$(brain_exec /home/agent/.local/bin/goose schedule list 2>&1 || true)"
fi
EXPECTED="morning-brief inbox-triage weekly-review health-followups budget-checkin"
MISSING=""
for id in $EXPECTED; do
  printf '%s' "$SCHEDULES" | grep -q "$id" || MISSING="$MISSING $id"
done
if [ -z "$MISSING" ]; then
  pass "goose schedule list shows all 5 schedules"
  echo "      (budget-checkin ships disabled/paused — that still counts; enable it"
  echo "       when finance/ledger.csv is real: docs/automations.md)"
else
  fail "goose schedule list is missing:$MISSING"
  echo "      Register them: scripts/vps/register-schedules.sh (idempotent). Raw list:"
  printf '%s\n' "$SCHEDULES" | sed 's/^/      | /'
fi

# ---- 4. live fire: run-now morning-brief (optional) -------------------------
if [ "$RUN_NOW" = "ask" ] && [ -t 0 ]; then
  read -r -p "Trigger 'goose schedule run-now --schedule-id morning-brief' now? (one real run + one real email) [y/N] " ANSWER
  case "$ANSWER" in y|Y|yes|YES) RUN_NOW="yes" ;; *) RUN_NOW="no" ;; esac
elif [ "$RUN_NOW" = "ask" ]; then
  RUN_NOW="no"
fi
if [ "$RUN_NOW" = "yes" ]; then
  if [ "$MODE" = "local" ]; then
    RC=0; "$GOOSE_BIN" schedule run-now --schedule-id morning-brief || RC=$?
  else
    RC=0; brain_exec /home/agent/.local/bin/goose schedule run-now --schedule-id morning-brief || RC=$?
  fi
  if [ "$RC" -eq 0 ]; then
    pass "run-now morning-brief triggered"
    echo "      NOW CONFIRM BY HAND: the digest email ('Morning brief — <date>',"
    echo "      self-addressed, sent by the recipe's own final Gmail step) arrives"
    echo "      in your inbox within ~1-3 minutes."
    echo "      No email => inspect the run's session (Desktop Scheduler UI, or"
    echo "      'goose schedule sessions --schedule-id morning-brief') — a run that"
    echo "      crashes before its delivery step sends nothing — and check that the"
    echo "      Gmail tool works from the brain (docs/setup/30-google-oauth.md)."
  else
    fail "run-now morning-brief (exit $RC)"
  fi
else
  echo "SKIP  run-now morning-brief (re-run with --run-now to fire it)"
fi

# ---- 5. manual cross-device checklist ---------------------------------------
cat <<'EOF'

== manual checklist — the v2 milestone (one history, every surface) ==
Nothing can verify this for you; do it once, now:

  [ ] Goose Desktop (connected to the brain) -> start a session, send one
      message.
  [ ] Phone surface (Goose iOS app, or the fallback per
      docs/setup/40-phone-setup.md) -> the SAME session is listed; open it,
      reply from the phone.
  [ ] Desktop -> the phone's reply appears in the same session.
  [ ] Desktop Scheduler UI -> the 5 schedules are visible; the run-now run
      from check 4 shows up in its per-schedule session history.

All boxes ticked = shared sessions.db confirmed across surfaces.
EOF

echo
echo "== summary: $PASS_COUNT passed, $FAIL_COUNT failed =="
[ "$FAIL_COUNT" -eq 0 ] || exit 1
