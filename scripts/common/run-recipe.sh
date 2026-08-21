#!/usr/bin/env bash
# run-recipe.sh — headless runner + FAILURE WATCHDOG for goose recipe runs.
#
# Usage: run-recipe.sh <recipe-name>
#   <recipe-name> = a file in this repo's recipes/ dir, with or without .yaml
#   e.g.: run-recipe.sh morning-brief
#
# What it does:
#   1. runs the recipe headlessly (goose run --no-session, JSON output)
#   2. on nonzero exit, retries ONCE after a 60-second sleep (a blind retry:
#      a Together 429's x-ratelimit-reset header is not visible through
#      goose's exit status, so a fixed pause is the best available)
#   3. only after the retry also fails, sends a HIGH-PRIORITY failure alert
#      via notify.sh (recipe name only — never model output, which could
#      contain sensitive content)
#   4. on success, logs the run's final text to stdout — it does NOT deliver
#      it: every scheduled recipe emails its own result as an explicit final
#      self-addressed Gmail send (docs/automations.md)
#
# Used by the systemd fallback timers and for manual headless tests; those
# paths get this failure alert on top of the recipe's own delivery. The
# native-scheduler path never runs this script.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NOTIFY="$SCRIPT_DIR/notify.sh"
NAME="unknown"

usage() {
  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fail_notify() {
  # $1 = exit code, $2 = short reason (must not contain model output)
  "$NOTIFY" -t "Recipe failure" -p high \
    "Recipe '$NAME' failed: $2 (exit $1). Check the brain's logs." || true
}

on_err() {
  local rc=$?
  fail_notify "$rc" "wrapper aborted unexpectedly"
  exit "$rc"
}
trap on_err ERR

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 2
fi
case "$1" in
  -h|--help) usage; exit 0 ;;
esac

NAME="${1%.yaml}"
NAME="${NAME##*/}"
RECIPE="$REPO_ROOT/recipes/$NAME.yaml"

# systemd injects /data/secrets.env via EnvironmentFile; for manual runs from
# an SSH shell on the brain, load it here so notify/MCP secrets are present.
if [ -z "${NTFY_TOPIC:-}" ] && [ -r /data/secrets.env ]; then
  set -a
  # shellcheck disable=SC1091
  . /data/secrets.env
  set +a
fi

if [ ! -f "$RECIPE" ]; then
  echo "run-recipe.sh: recipe not found: $RECIPE" >&2
  fail_notify 2 "recipe file not found"
  exit 2
fi
if ! command -v goose >/dev/null 2>&1; then
  echo "run-recipe.sh: goose CLI not found on PATH" >&2
  fail_notify 127 "goose CLI not found"
  exit 127
fi

# Canonical headless environment. Deliberately NOT exporting GOOSE_PROVIDER /
# GOOSE_MODEL: env vars outrank config, and each recipe pins its own
# settings.goose_provider/goose_model.
export GOOSE_MODE=auto
export GOOSE_MAX_TURNS=50
export GOOSE_CONTEXT_STRATEGY=summarize
export GOOSE_DISABLE_SESSION_NAMING=true

OUT="$(mktemp "${TMPDIR:-/tmp}/run-recipe.$NAME.XXXXXX")"
trap 'rm -f "$OUT"' EXIT

run_goose() {
  goose run --recipe "$RECIPE" --no-session --quiet --output-format json \
    >"$OUT"
}

# goose exits 0 on provider failures (verified against v1.46.0: a dead
# endpoint produces VALID JSON with metadata.status "completed", the error
# text as the final assistant message, and total_tokens 0), so success needs
# more than a zero exit. Two signals:
#   - metadata.total_tokens == 0  → no model call ever succeeded (a real run
#     always bills tokens; content-independent)
#   - final assistant message is a goose error → the last turn died even if
#     earlier turns billed tokens (mid-run provider outage)
looks_failed() {
  if command -v jq >/dev/null 2>&1; then
    local tokens last
    tokens="$(jq -r '.metadata.total_tokens // 0' "$OUT" 2>/dev/null || echo 0)"
    case "$tokens" in
      ''|0|null) return 0 ;;
    esac
    last="$(jq -r '[ .messages[]? | select(.role == "assistant") ] | last
                   | .content[]? | select(.type == "text") | .text' \
            "$OUT" 2>/dev/null || true)"
    if printf '%s\n' "$last" \
        | grep -qE '^(Network error|Server error|Request failed)|Please resend your message to try again'; then
      return 0
    fi
    return 1
  else
    # No jq (shouldn't happen post-bootstrap): phrase check on the raw file.
    grep -qE 'Network error:|Please resend your message' "$OUT"
  fi
}

attempt() {
  local rc=0
  run_goose || rc=$?
  if [ "$rc" -eq 0 ] && looks_failed; then
    echo "run-recipe.sh: goose exited 0 but its output looks like a failed run" >&2
    rc=1
  fi
  return "$rc"
}

rc=0
attempt || rc=$?

if [ "$rc" -ne 0 ]; then
  # One blind retry after a fixed pause: transient failures (Together's
  # dynamic rate limits especially) often clear within a minute, and the
  # x-ratelimit-reset header is not visible through goose's exit status.
  echo "run-recipe.sh: '$NAME' failed (rc=$rc); retrying once in 60s" >&2
  sleep 60
  : >"$OUT"
  rc=0
  attempt || rc=$?
fi

if [ "$rc" -ne 0 ]; then
  fail_notify "$rc" "goose run exited non-zero (after one retry)"
  exit "$rc"
fi

# Extract the final text from goose's JSON. The exact schema varies across
# goose versions, so try the common shapes and fall back to the raw output
# rather than silently dropping a successful run's result.
RESULT=""
if command -v jq >/dev/null 2>&1; then
  RESULT="$(jq -r '
    def to_text:
      if type == "string" then .
      elif type == "array" then [ .[] | to_text ] | join("\n")
      elif type == "object" then
        ( .text? // .content? // .message? // .result? // empty ) | to_text
      else tostring
      end;
    ( .result? // .output? // .response? //
      ( .messages? | select(type == "array") | last ) //
      empty
    ) | to_text
  ' "$OUT" 2>/dev/null || true)"
else
  echo "run-recipe.sh: jq not found; using raw goose output" >&2
fi
if [ -z "${RESULT//[[:space:]]/}" ]; then
  RESULT="$(cat "$OUT")"
fi
if [ -z "${RESULT//[[:space:]]/}" ]; then
  fail_notify 1 "run succeeded but produced no output"
  exit 1
fi

# Trim leading/trailing whitespace (portable, bash 3.2-safe for the Mac).
TRIMMED="${RESULT#"${RESULT%%[![:space:]]*}"}"
TRIMMED="${TRIMMED%"${TRIMMED##*[![:space:]]}"}"

# No delivery here: the recipe already sent (or deliberately withheld) its
# own notification as its final step. Success output is simply logged to
# stdout — journald keeps it on timer runs. NO_ACTION_NEEDED is inbox-
# triage's documented "nothing worth an email" final text; it is logged like
# any other result.
printf '%s\n' "$TRIMMED"
exit 0
