#!/usr/bin/env bash
# check-mcp.sh — Phase 2 verification: exercise the admin MCP extensions
# (Google Workspace, Todoist, optionally Playwright) with one real goose run
# each. Run it on the Mac after docs/setup/30-google-oauth.md; it also works
# on the brain once tokens are transferred there.
#
# First-run OAuth dances may open a browser window (workspace-mcp) or print an
# auth URL (Todoist) — that's expected; complete them and re-run.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: check-mcp.sh [--help]

Runs three smoke tests through goose's configured extensions:
  1. Gmail    — subjects of the 3 most recent inbox emails (workspace-mcp).
     With USER_GOOGLE_EMAILS set (comma-separated multi-account roster,
     docs/setup/30-google-oauth.md §8) the check runs once PER account so
     every stored consent is exercised, not just the default account's.
  2. Todoist  — today's tasks (first-party remote MCP)
  3. Playwright — title of https://example.com (SKIPPED unless the playwright
     extension is enabled in ~/.config/goose/config.yaml)

All runs are pinned to zen-openai/kimi-k2.6 (cheap, Tier-2-safe — email
subjects must not go to free models; docs/privacy.md). Verify the printed
output looks like YOUR real inbox/tasks — the script can only check that the
runs completed. Exits non-zero if a non-skipped check fails.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "check-mcp.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

# A non-interactive SSH shell on the brain does not source the profile that
# puts ~/.local/bin on PATH, so fall back to the known install location the
# way register-schedules.sh does — otherwise this script is unusable over ssh.
GOOSE_BIN="${GOOSE_BIN:-}"
if [ -z "$GOOSE_BIN" ]; then
  if command -v goose >/dev/null 2>&1; then
    GOOSE_BIN="$(command -v goose)"
  elif [ -x "$HOME/.local/bin/goose" ]; then
    GOOSE_BIN="$HOME/.local/bin/goose"
  else
    echo "check-mcp.sh: goose CLI not found on PATH or at ~/.local/bin/goose" >&2
    echo "              (Mac: scripts/mac/bootstrap-mac.sh)" >&2
    exit 2
  fi
fi

CONFIG="$HOME/.config/goose/config.yaml"
PROVIDER="zen-openai"
MODEL="kimi-k2.6"
OUT_FILE="$(mktemp)"
trap 'rm -f "$OUT_FILE"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
SUMMARY=""

run_check() {
  # $1 = name, $2 = prompt
  name="$1"
  prompt="$2"
  echo
  echo "--> $name"
  rc=0
  env GOOSE_MODE=auto GOOSE_MAX_TURNS=15 GOOSE_DISABLE_SESSION_NAMING=true \
    "$GOOSE_BIN" run --no-session --quiet \
    -t "$prompt" \
    --provider "$PROVIDER" --model "$MODEL" \
    >"$OUT_FILE" 2>&1 || rc=$?
  # goose exits 0 even when an extension fails to start or every model call
  # dies (same behavior run-recipe.sh compensates for), so a zero exit alone is
  # not success — a per-account check that never reached Gmail must not PASS.
  if [ "$rc" -eq 0 ] && grep -qE 'Failed to start extension|^(Network error|Server error|Request failed)|Please resend your message to try again' "$OUT_FILE"; then
    echo "    FAIL — the run completed but never reached the tools:"
    grep -oE 'Failed to start extension [^)]*\)|^(Network error|Server error|Request failed)[^\n]*' "$OUT_FILE" | head -n 3 | sed 's/^/      | /'
    tail -n 4 "$OUT_FILE" | sed 's/^/      | /'
    FAIL_COUNT=$((FAIL_COUNT + 1))
    SUMMARY="$SUMMARY  FAIL  $name (tools/provider unreachable)"$'\n'
  elif [ "$rc" -eq 0 ] && grep -qiE 'authentication is required|complete the (sign-in|authorization)' "$OUT_FILE"; then
    # The tool answered with an auth prompt, not data — and this one-shot run
    # has already exited, taking the localhost OAuth callback listener with
    # it, so consent clicked NOW lands on a dead port. The consent must
    # complete while a session is alive; see docs/setup/30-google-oauth.md §6
    # for the retry-loop one-liner that holds the session open.
    echo "    AUTH PENDING — consent flow triggered but not completed."
    echo "    Do NOT just re-click the browser tab: run the §6 retry-loop"
    echo "    command from docs/setup/30-google-oauth.md, consent while it"
    echo "    runs, then re-run this script."
    FAIL_COUNT=$((FAIL_COUNT + 1))
    SUMMARY="$SUMMARY  AUTH PENDING  $name"$'\n'
  elif [ "$rc" -eq 0 ]; then
    echo "    PASS — output (verify it matches reality):"
    tail -n 8 "$OUT_FILE" | sed 's/^/      | /'
    PASS_COUNT=$((PASS_COUNT + 1))
    SUMMARY="$SUMMARY  PASS  $name"$'\n'
  else
    echo "    FAIL (exit $rc). Last output lines:"
    tail -n 10 "$OUT_FILE" | sed 's/^/      | /'
    FAIL_COUNT=$((FAIL_COUNT + 1))
    SUMMARY="$SUMMARY  FAIL  $name"$'\n'
  fi
}

echo "== check-mcp: extension smoke tests via $PROVIDER/$MODEL =="
echo "NOTE: first-run auth may open a browser (Google OAuth consent) or print"
echo "      an auth URL (Todoist). Complete it, then re-run this script."

# ---- 1. Gmail via workspace-mcp --------------------------------------------
# One smoke test per account in USER_GOOGLE_EMAILS (falls back to
# USER_GOOGLE_EMAIL, then to the extension's default account). Each account's
# check passes its address as the tools' user_google_email argument, so a
# missing consent for a secondary account fails ITS check, not the primary's.
# On the brain the roster lives in /data/secrets.env — load it like the other
# brain-side scripts (register-schedules.sh, check-brain.sh) so an SSH shell
# without the exports still sweeps every account.
if [ -z "${GOOGLE_OAUTH_CLIENT_ID:-}" ] && [ -r /data/secrets.env ]; then
  # Gate on the OAuth client id, not the roster: secrets.env is also the only
  # source of GOOGLE_OAUTH_CLIENT_ID/SECRET, which workspace-mcp needs to start
  # at all. Gating on the roster meant that exporting USER_GOOGLE_EMAILS by hand
  # skipped the file and left the extension unable to launch.
  set -a
  # shellcheck disable=SC1091
  . /data/secrets.env
  set +a
fi

GMAIL_CHECKS=0
ACCOUNTS="${USER_GOOGLE_EMAILS:-${USER_GOOGLE_EMAIL:-}}"
if [ -n "$ACCOUNTS" ]; then
  OLD_IFS="$IFS"
  IFS=','
  for account in $ACCOUNTS; do
    IFS="$OLD_IFS"
    account="$(printf '%s' "$account" | tr -d '[:space:]')"
    [ -n "$account" ] || { IFS=','; continue; }
    GMAIL_CHECKS=$((GMAIL_CHECKS + 1))
    run_check "Gmail ($account)" \
      "Using the Google Workspace tools, list the subject lines of the 3 most recent emails in the inbox of the Google account $account. Pass user_google_email=$account on every tool call. Output only the three subject lines, one per line. Do not modify, label, or send anything."
    IFS=','
  done
  IFS="$OLD_IFS"
fi
if [ "$GMAIL_CHECKS" -eq 0 ]; then
  # No (usable) roster — the pre-multi-account behavior: one check against
  # the extension's default account. A roster of only commas/whitespace
  # lands here too instead of silently skipping Gmail entirely.
  run_check "Gmail (workspace-mcp)" \
    "Using the Google Workspace tools, list the subject lines of the 3 most recent emails in my inbox. Output only the three subject lines, one per line. Do not modify, label, or send anything."
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "    Hints: is workspace-mcp enabled in $CONFIG? Are"
  echo "    GOOGLE_OAUTH_CLIENT_ID/GOOGLE_OAUTH_CLIENT_SECRET in the env"
  echo "    (Keychain export / secrets.env)? Was the OAuth consent completed"
  echo "    and the GCP app published 'In production'? (docs/setup/30-google-oauth.md"
  echo "    — a 'Testing' app expires refresh tokens every 7 days.)"
  echo "    A failure for one specific account usually means that account's"
  echo "    consent dance was never completed — docs/setup/30-google-oauth.md §8."
fi

# ---- 2. Todoist remote MCP (only if enabled) --------------------------------
TODOIST_ON="no"
if [ -f "$CONFIG" ] && awk '/^  todoist:/{f=1; next} f && /^  [A-Za-z_#]/{f=0} f && /enabled: true/{found=1} END{exit !found}' "$CONFIG"; then
  TODOIST_ON="yes"
fi

if [ "$TODOIST_ON" = "yes" ]; then
  GMAIL_FAILS=$FAIL_COUNT
  run_check "Todoist (ai.todoist.net)" \
    "Using the Todoist tools, list my tasks due today, titles only, one per line. If there are none, output exactly: no tasks due today. Do not create or modify any task."

  if [ "$FAIL_COUNT" -gt "$GMAIL_FAILS" ]; then
    echo "    Hints: the first connect triggers Todoist's OAuth — approve it"
    echo "    and re-run."
  fi
else
  echo "SKIP  Todoist — extension disabled in $CONFIG (no todo app adopted yet)"
fi

# ---- 3. Playwright (only if enabled) ----------------------------------------
PLAYWRIGHT_ON="no"
if [ -f "$CONFIG" ]; then
  # Reads the "playwright:" block of the extensions map (2-space key; block
  # ends at the next 2-space key or 2-space comment) and looks for its
  # enabled: true.
  if awk '/^  playwright:/{f=1; next} f && /^  [A-Za-z_#]/{f=0} f && /enabled: true/{found=1} END{exit !found}' "$CONFIG"; then
    PLAYWRIGHT_ON="yes"
  fi
fi

if [ "$PLAYWRIGHT_ON" = "yes" ]; then
  run_check "Playwright (browser)" \
    "Using the Playwright browser tools, open https://example.com and report the page title. Output only the title text."
else
  echo
  echo "--> Playwright (browser)"
  echo "    SKIP — playwright extension is disabled in $CONFIG (the shipped"
  echo "    default). Enable it there (enabled: true) if a workflow needs the"
  echo "    browser; the first run downloads browser binaries."
  SKIP_COUNT=$((SKIP_COUNT + 1))
  SUMMARY="$SUMMARY  SKIP  Playwright (disabled in config)"$'\n'
fi

echo
echo "== summary: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped =="
printf '%s' "$SUMMARY"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
