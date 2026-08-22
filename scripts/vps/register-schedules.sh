#!/usr/bin/env bash
# register-schedules.sh — idempotently register the automation roster with the
# brain's native goose scheduler (docs/automations.md). Run ON the brain as
# `agent`; deploy-vps.sh calls it on every deploy, and re-running it any time
# is safe: goose 1.x has no update/upsert subcommand (only add / list /
# remove / sessions / run-now / cron-help, verified against v1.46.0), so
# idempotency here = remove-then-add for any schedule-id that already exists.
# That also means edits to crons or recipe files propagate on re-run.
#
# vault-qa is deliberately NOT here — it is on-demand, never scheduled.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: register-schedules.sh

Registers the five scheduled recipes (6-field crons, seconds first, evaluated
in the brain's local timezone) with `goose schedule add`, then prints
`goose schedule list`. budget-checkin is registered but should stay paused
until a budgeting source is picked (see docs/automations.md).
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
esac

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Multi-account roster: pick up USER_GOOGLE_EMAILS from the brain's secrets
# when it isn't already in the environment (manual SSH runs). Harmless when
# the file is absent or the var unset — single-account behavior is unchanged.
if [[ -z "${USER_GOOGLE_EMAILS:-}" ]] && [[ -r /data/secrets.env ]]; then
  set -a
  # shellcheck disable=SC1091
  . /data/secrets.env
  set +a
fi

# The multi-account roster reaches scheduled runs as a stored recipe
# PARAMETER: `goose schedule add --params google_accounts=<roster>` persists
# it into schedule.json (verified against goose 1.46.0) and the scheduler
# applies it at fire time. Re-running this script updates stored params the
# same way it updates crons, and an empty roster simply omits --params so the
# recipe's own default ("") applies — single-account behavior, unchanged.

# The convention everywhere in this setup: the roster's FIRST entry is the
# primary account and must equal USER_GOOGLE_EMAIL. Warn on drift — recipes
# would deliver from one account while workspace-mcp defaults to another.
if [[ -n "${USER_GOOGLE_EMAILS:-}" && -n "${USER_GOOGLE_EMAIL:-}" \
      && "${USER_GOOGLE_EMAILS%%,*}" != "$USER_GOOGLE_EMAIL" ]]; then
  echo "WARNING: first USER_GOOGLE_EMAILS entry (${USER_GOOGLE_EMAILS%%,*}) does not" >&2
  echo "         match USER_GOOGLE_EMAIL ($USER_GOOGLE_EMAIL) — the roster's first" >&2
  echo "         entry must be the primary (docs/setup/30-google-oauth.md §8)." >&2
fi

# Headless box: no Secret Service keyring, and schedule subcommands need no
# secrets anyway.
export GOOSE_DISABLE_KEYRING=1

GOOSE_BIN="${GOOSE_BIN:-}"
if [[ -z "$GOOSE_BIN" ]]; then
  if command -v goose >/dev/null; then
    GOOSE_BIN="$(command -v goose)"
  elif [[ -x /home/agent/.local/bin/goose ]]; then
    GOOSE_BIN=/home/agent/.local/bin/goose
  else
    echo "ERROR: goose CLI not found (expected on PATH or at /home/agent/.local/bin/goose)." >&2
    exit 1
  fi
fi

# The roster — crons are canonical, mirrored by docs/automations.md and the
# fallback timers in scripts/vps/systemd/fallback/.
ORDER=(morning-brief inbox-triage weekly-review health-followups budget-checkin)
declare -A CRONS=(
  [morning-brief]="0 0 7 * * *"
  [inbox-triage]="0 0 9,13,17 * * MON-FRI"
  [weekly-review]="0 0 17 * * SUN"
  [health-followups]="0 30 18 * * SUN"
  [budget-checkin]="0 0 9 1 * *"
)

# Recipes whose inputs live in the private life vault (Phase 4). Registering
# them before that exists guarantees a scheduled failure every week — the run
# dies on the missing file and the watchdog fires an alert. Skip them, and
# unregister them if a previous deploy already added them, until their inputs
# are real. Set REGISTER_ALL=1 to register the roster regardless.
declare -A PREREQ=(
  [health-followups]="/data/life-vault/health/appointments.md"
  [budget-checkin]="/data/life-vault/finance/ledger.csv"
)

EXISTING="$("$GOOSE_BIN" schedule list 2>/dev/null || true)"

for id in "${ORDER[@]}"; do
  recipe="$REPO_DIR/recipes/$id.yaml"
  if [[ ! -f "$recipe" ]]; then
    echo "ERROR: recipe not found: $recipe" >&2
    exit 1
  fi
  prereq="${PREREQ[$id]:-}"
  if [[ -n "$prereq" && ! -e "$prereq" && -z "${REGISTER_ALL:-}" ]]; then
    if grep -q -- "$id" <<<"$EXISTING"; then
      echo "==> $id: prerequisite missing ($prereq) — unregistering"
      "$GOOSE_BIN" schedule remove --schedule-id "$id"
    else
      echo "==> $id: skipped — prerequisite missing ($prereq)"
    fi
    continue
  fi

  # Sweep recipes declare the google_accounts parameter; pass the roster as a
  # stored schedule parameter when one is configured.
  PARAMS=()
  if [[ -n "${USER_GOOGLE_EMAILS:-}" ]] && grep -q 'key: google_accounts' "$recipe"; then
    PARAMS=(--params "google_accounts=$USER_GOOGLE_EMAILS")
    echo "==> $id: registering with the multi-account roster as a stored parameter"
  fi
  if grep -q -- "$id" <<<"$EXISTING"; then
    echo "==> $id: already registered — removing and re-adding (no update subcommand)"
    "$GOOSE_BIN" schedule remove --schedule-id "$id"
  else
    echo "==> $id: registering"
  fi
  "$GOOSE_BIN" schedule add \
    --schedule-id "$id" \
    --cron "${CRONS[$id]}" \
    --recipe-source "$recipe" \
    ${PARAMS[@]+"${PARAMS[@]}"}
done

# budget-checkin ships paused until a budgeting source is picked. The 1.x CLI
# has no pause subcommand (pause/resume lives in the Desktop Scheduler UI),
# but probe for one so a future goose that grows it gets used automatically.
if "$GOOSE_BIN" schedule --help 2>&1 | grep -qw "pause"; then
  echo "==> budget-checkin: pausing via CLI"
  "$GOOSE_BIN" schedule pause --schedule-id budget-checkin
else
  cat <<'EOF'
NOTE: this goose CLI has no `schedule pause` — budget-checkin is registered
      but ACTIVE. Pause it now from the Desktop Scheduler UI (connected to
      the brain), or remove it until you have a budgeting source:
        goose schedule remove --schedule-id budget-checkin
      Its first fire would otherwise be the 1st of the month at 09:00.
      See docs/automations.md.
EOF
fi

echo
echo "==> Current schedule roster:"
"$GOOSE_BIN" schedule list
