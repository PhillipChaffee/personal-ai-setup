#!/usr/bin/env bash
# notify.sh — push a message to the phone via ntfy.
#
# Usage:
#   notify.sh [-t title] [-p priority] <message ...>
#   some-command | notify.sh [-t title] [-p priority]
#
# -t  notification title            (default: personal-ai)
# -p  ntfy priority                 (max|urgent|high|default|low|min; default: default)
#
# Requires NTFY_TOPIC in the environment (see config/env/secrets.env.example).
# The topic name is a secret: anyone who knows it can read and send on it.
# NTFY_SERVER overrides the ntfy server base URL (default https://ntfy.sh) —
# for a self-hosted ntfy, or a local mock in tests.
#
# ROLE: this is the FAILURE-ALERT channel (run-recipe.sh), not content
# delivery — recipes email their results directly via Gmail. When NTFY_EMAIL
# is set, ntfy.sh forwards each message to that address (free tier caps
# ~5 emails/day — fine for rare alerts, which is why digests don't go
# through here). Without NTFY_EMAIL it's a plain topic push for anyone
# who does run the ntfy app.
set -euo pipefail

TITLE="personal-ai"
PRIORITY="default"

usage() {
  sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while getopts ":t:p:h" opt; do
  case "$opt" in
    t) TITLE="$OPTARG" ;;
    p) PRIORITY="$OPTARG" ;;
    h) usage; exit 0 ;;
    :) echo "notify.sh: option -$OPTARG requires a value" >&2; usage >&2; exit 2 ;;
    *) echo "notify.sh: unknown option" >&2; usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

if [ "$#" -gt 0 ]; then
  MESSAGE="$*"
else
  MESSAGE="$(cat)"
fi

# HTTP headers cannot carry newlines.
TITLE="${TITLE//$'\n'/ }"

if [ -z "${MESSAGE//[[:space:]]/}" ]; then
  echo "notify.sh: empty message, nothing to send" >&2
  exit 0
fi

# Notification loss must never fail the job that produced the real work: by
# the time this script runs, the recipe/run already succeeded, and a non-zero
# exit here would make a healthy run look broken. So: complain loudly on
# stderr (journald keeps it), but always exit 0.
if [ -z "${NTFY_TOPIC:-}" ]; then
  echo "notify.sh: ERROR: NTFY_TOPIC is not set — notification NOT sent." >&2
  exit 0
fi

EMAIL_ARGS=()
if [ -n "${NTFY_EMAIL:-}" ]; then
  EMAIL_ARGS=(-H "Email: $NTFY_EMAIL")
fi

if ! curl -fsS --max-time 15 -o /dev/null \
    -H "Title: $TITLE" \
    -H "Priority: $PRIORITY" \
    ${EMAIL_ARGS[@]+"${EMAIL_ARGS[@]}"} \
    --data-binary "$MESSAGE" \
    "${NTFY_SERVER:-https://ntfy.sh}/${NTFY_TOPIC}"; then
  echo "notify.sh: ERROR: POST to ntfy failed — notification lost." >&2
fi

exit 0
