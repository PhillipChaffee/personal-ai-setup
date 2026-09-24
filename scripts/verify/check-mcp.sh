#!/usr/bin/env bash
# check-mcp.sh — Phase 2 verification: exercise the MCP extensions this machine
# ACTUALLY HAS ENABLED with one real goose run each. Run it on the Mac after
# enabling a connector (docs/connecting.md); it also works on the brain once
# the extension is enabled there.
#
# THE ROSTER IS THE LIVE CONFIG'S, not a list in this file. It used to be three
# hardcoded services, and the hardcoding pointed both ways: Gmail ran
# unconditionally, so a machine that never installed google-workspace was
# penalised for a connector it does not have; and an extension somebody enabled
# later — tavily, or the next one — was smoke-tested by nothing at all and
# nothing said so. Now: every enabled extension that declares an MCP server
# (`cmd` or `uri`) must have a smoke test here, and an enabled one that does not
# is a FAILURE naming it. Extensions with a smoke test that are NOT enabled skip.
#
# The rule is scoped to MCP-DECLARING extensions on purpose. goose's own
# builtins ship enabled (`developer`, `memory` and a dozen more) and no smoke
# prompt is possible for them — they are not servers. An exempt-list would have
# been a hand-maintained roster inside the fix whose whole point is deleting
# hand-maintained rosters; `cmd`/`uri` is a property of the thing itself.
#
# First-run consent may print an auth URL (Todoist) — that's expected; complete
# it and re-run.
set -euo pipefail

# shellcheck source=scripts/verify/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: check-mcp.sh [--help]

One smoke test per ENABLED MCP extension in the live goose config.yaml. The
two this script knows prompts for:
  todoist       — today's tasks (first-party remote MCP)
  playwright    — title of https://example.com

An enabled extension that declares an MCP server and has no smoke test here
FAILS, naming itself: nothing else in this repo would notice it. One that has a
smoke test but is not enabled SKIPs — a machine without that connector is not
penalised for it.

All runs are pinned to zen-openai/kimi-k2.6 (cheap, Tier-2-safe — connector
content must not go to free models; docs/privacy.md). Verify the printed
output looks like YOUR real tasks/pages — the script can only check that the
runs completed. Exits non-zero if a non-skipped check fails.

  PAI_GOOSE_CONFIG  read this config.yaml instead of resolving one (fixtures).
  PAI_HOME          resolve the config under a different home.
  GOOSE_BIN         the goose to run.
Exit: 0 ok, 1 findings, 2 usage/precondition.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) die_usage "unknown argument: $1" ;;
esac

# The config comes FIRST now: it is what says whether there is anything to run.
# lib.sh's resolver, so this and check-security.sh --local agree about which
# file goose reads — they used to disagree, and only check-security knew about
# /data/goose/config/config.yaml (GOOSE_PATH_ROOT's home on the brain).
CONFIG="$(live_goose_config)"
if [ -z "$CONFIG" ]; then
  die 2 "no readable goose config.yaml (${PAI_HOME:-$HOME}/.config/goose/, /data/goose/config/)" \
    "There is no extension roster to smoke-test. Mac: scripts/mac/bootstrap-mac.sh" \
    "installs the template; brain: scripts/vps/deploy-vps.sh does."
fi

# --required: every check here is a goose run, so there is nothing to report
# without it. (check-connectors.sh calls the same helper without --required.)
GOOSE_BIN="$(resolve_goose_bin --required)"

PY_CMD="$(py_runner)"
read -r -a PY <<<"$PY_CMD"

PROVIDER="zen-openai"
MODEL="kimi-k2.6"
OUT_FILE="$(mktemp)"
trap 'rm -f "$OUT_FILE"' EXIT

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
  # dies, so a zero exit alone is not success — a check that never reached the
  # tools must not PASS.
  if [ "$rc" -eq 0 ] && grep -qE 'Failed to start extension|^(Network error|Server error|Request failed)|Please resend your message to try again' "$OUT_FILE"; then
    fail "$name — the run completed but never reached the tools:"
    grep -oE 'Failed to start extension [^)]*\)|^(Network error|Server error|Request failed)[^\n]*' "$OUT_FILE" | head -n 3 | sed 's/^/      | /'
    tail -n 4 "$OUT_FILE" | sed 's/^/      | /'
    summary_row "FAIL  $name (tools/provider unreachable)"
  elif [ "$rc" -eq 0 ] && grep -qiE 'authentication is required|complete the (sign-in|authorization)' "$OUT_FILE"; then
    # The tool answered with an auth prompt, not data — and this one-shot run
    # has already exited, so consent clicked NOW lands on a dead callback
    # port. Approve the connector's consent, then re-run this script.
    fail "$name — AUTH PENDING: consent flow triggered but not completed."
    note "Do NOT just re-click the browser tab: approve the consent in a"
    note "fresh browser session, then re-run this script."
    summary_row "AUTH PENDING  $name"
  elif [ "$rc" -eq 0 ]; then
    pass "$name — output (verify it matches reality):"
    tail -n 8 "$OUT_FILE" | sed 's/^/      | /'
    summary_row "PASS  $name"
  else
    fail "$name (exit $rc). Last output lines:"
    tail -n 10 "$OUT_FILE" | sed 's/^/      | /'
    summary_row "FAIL  $name"
  fi
}

# ---- the roster: what this machine has ENABLED ------------------------------
# PyYAML, not awk. The awk this replaces scanned for a 2-space `todoist:` key
# and the next `enabled: true` line inside its block — which reads the config as
# text laid out the way the repo's template happens to lay it out. goose
# serde-round-trips this file at runtime, and check-security.sh already parses
# the same file properly for the same reason.
ROSTER="$("${PY[@]}" - "$CONFIG" <<'PYEOF'
import sys

import yaml

with open(sys.argv[1]) as fh:
    cfg = yaml.safe_load(fh) or {}
exts = cfg.get("extensions") if isinstance(cfg, dict) else None
if not isinstance(exts, dict):
    # No extensions map at all. Not an error here: check-security.sh --local is
    # the check that has a verdict about an unconfigured live config, and two
    # scripts failing for one cause is one cause reported twice.
    sys.exit(0)
for name, ext in sorted(exts.items()):
    if not isinstance(ext, dict):
        continue
    # goose's own builtins are not servers; no smoke prompt is possible for
    # them, and `developer` and `memory` ship enabled in this repo's template.
    if ext.get("type") in ("builtin", "platform"):
        continue
    if ext.get("enabled") is not True:
        continue
    # An extension with neither is a config entry, not a server: nothing gets
    # spawned and nothing gets connected to, so there is no smoke to test.
    if not (ext.get("cmd") or ext.get("uri")):
        continue
    print(name)
PYEOF
)" || die 2 "could not read the extensions map from $CONFIG" \
  "It is unreadable or not valid YAML. check-security.sh --local has the" \
  "detailed verdict about a live config in that state."

# The smoke prompts. THIS IS A ROSTER TOO, and the difference that matters is
# that its gaps are now reported: an enabled MCP extension missing from here
# FAILs below, naming itself. Adding one is adding a case arm.
KNOWN="todoist playwright"

echo "== check-mcp: extension smoke tests via $PROVIDER/$MODEL =="
echo "   live config: $CONFIG"
echo "   enabled MCP extensions: ${ROSTER:-(none)}" | tr '\n' ' '
echo
echo "NOTE: first-run auth may print an auth URL (Todoist). Complete it,"
echo "      then re-run this script."

check_todoist() {
  local before="$FAIL_COUNT"
  run_check "Todoist (ai.todoist.net)" \
    "Using the Todoist tools, list my tasks due today, titles only, one per line. If there are none, output exactly: no tasks due today. Do not create or modify any task."
  if [ "$FAIL_COUNT" -gt "$before" ]; then
    note "Hints: the first connect triggers Todoist's OAuth — approve it"
    note "and re-run."
  fi
  return 0
}

check_playwright() {
  run_check "Playwright (browser)" \
    "Using the Playwright browser tools, open https://example.com and report the page title. Output only the title text."
  return 0
}

# ---- 1. every enabled MCP extension, in the config's own order --------------
for ext in $ROSTER; do
  case "$ext" in
    todoist)       check_todoist ;;
    playwright)    check_playwright ;;
    *)
      # THE COMPLETENESS RULE. Nothing else in this repo notices an extension
      # somebody enabled: check-security.sh --local asserts it has a tool
      # allowlist, and that is the whole of the coverage it gets. An enabled
      # server nobody ever proved can answer is a connector that fails
      # mid-task instead of here, under your eyes.
      echo
      echo "--> $ext"
      fail "$ext is enabled and declares an MCP server, but check-mcp.sh has no smoke test for it"
      note "Add one: a case arm in check-mcp.sh's roster loop and its name in"
      note "KNOWN. A read-only prompt that touches the server is enough — the"
      note "point is that something proves it can answer."
      summary_row "FAIL  $ext (enabled, no smoke test)"
      ;;
  esac
done

# ---- 2. the ones this script knows about that are NOT enabled ---------------
# A SKIP, not a failure. A machine that never installed a connector must not be
# penalised for the connector rule — that is the completeness rule's own
# acceptance criterion, and Gmail running unconditionally was the case that
# broke it.
for ext in $KNOWN; do
  case "
$ROSTER
" in
    *"
$ext
"*) continue ;;
  esac
  echo
  echo "--> $ext"
  skip "$ext — not enabled in $CONFIG, so this machine has no such connector"
  summary_row "SKIP  $ext (not enabled)"
done

finish --skips