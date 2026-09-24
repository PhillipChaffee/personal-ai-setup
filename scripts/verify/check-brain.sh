#!/usr/bin/env bash
# check-brain.sh — Phase 3 verification of the VPS brain: goose-serve service,
# /status over TLS, and the manual cross-device checklist. Run it on the brain
# itself (over SSH) or from the Mac across the tailnet — it detects which side
# it's on.
set -euo pipefail

# shellcheck source=scripts/verify/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: check-brain.sh [--insecure] [--local] [--help]

  --insecure  pass -k to curl for the /status check. goose serve's TLS cert
              is self-signed (clients pin its fingerprint instead of using a
              CA), so plain curl may refuse it; -k only skips verification
              for THIS smoke test — never weaken the clients.
  --local     force local mode (default: auto-detected via /data/goose).

Remote mode needs BRAIN_HOST set to the brain's tailnet name, e.g.:
  BRAIN_HOST=<your-brain>.<your-tailnet>.ts.net ./scripts/verify/check-brain.sh
and SSH access as agent@$BRAIN_HOST (keys only; see docs/security.md).
Exits non-zero if any automated check fails.
EOF
}

INSECURE="no"
FORCE_LOCAL="no"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --insecure) INSECURE="yes" ;;
    --local)    FORCE_LOCAL="yes" ;;
    -h|--help)  usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift
done

# ---- mode detection ---------------------------------------------------------
# One sentinel, in lib.sh. This used to probe /data/goose (or /data/goose-data,
# the pre-GOOSE_PATH_ROOT layout) — both of which are add-on artefacts, not
# host facts. See lib.sh's pai_mode for why /data itself is the right test.
MODE="$(pai_mode "$FORCE_LOCAL")"

GOOSE_BIN="goose"
if [ "$MODE" = "local" ]; then
  # The old fallback hardcoded /home/agent/.local/bin/goose with no -x test, so
  # a brain without goose got "command not found" from the substitution rather
  # than anything actionable. resolve_goose_bin tests before choosing; the
  # literal survives only as the path named in that failure.
  GOOSE_BIN="$(resolve_goose_bin)"
  [ -n "$GOOSE_BIN" ] || GOOSE_BIN="/home/agent/.local/bin/goose"
  # Load GOOSE_SERVER__SECRET_KEY etc. for the checks below.
  load_secrets GOOSE_SERVER__SECRET_KEY
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
  BRAIN_HOST="${BRAIN_HOST:-$PAI_BRAIN_HOST_PLACEHOLDER}"
  if brain_host_is_placeholder; then
    die 2 "set BRAIN_HOST to your brain's tailnet name first, e.g." \
      "  BRAIN_HOST=brain.example-tailnet.ts.net $0"
  fi
  STATUS_HOST="$BRAIN_HOST"
fi

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
  echo "         real clients (Goose Desktop) must keep pinning the cert fingerprint."
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

# ---- 3. manual checklist -----------------------------------------------------
cat <<'EOF'

== manual checklist — the milestone (one history, on the brain) ==
Nothing can verify this for you; do it once, now:

  [ ] Goose Desktop (connected to the brain) -> start a session, send one
      message, and see the reply land in the brain's history.

All boxes ticked = shared sessions.db confirmed on Desktop.
EOF

finish