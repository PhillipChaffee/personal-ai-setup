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

# Where rendered recipe copies live (docs/setup/30-google-oauth.md §8). The
# native scheduler runs recipes with their parameter DEFAULTS — it cannot
# pass values — so when USER_GOOGLE_EMAILS is set, each recipe that declares
# the google_accounts parameter is registered from a copy whose default IS
# the roster. The copies sit on /data (encrypted, untracked): the personal
# roster never lands in the repo. Re-running this script re-renders, so
# roster changes propagate the same way cron changes do.
RENDER_DIR=/data/rendered-recipes

# render_recipe <src> <dst>: bake the roster into the google_accounts
# parameter default (the first `default: ""` after `key: google_accounts`).
render_recipe() {
  awk -v roster="$USER_GOOGLE_EMAILS" '
    /key: google_accounts/ { in_param = 1 }
    in_param && /default: ""/ {
      sub(/default: ""/, "default: \"" roster "\"")
      in_param = 0
    }
    { print }
  ' "$1" >"$2"
}

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

EXISTING="$("$GOOSE_BIN" schedule list 2>/dev/null || true)"

for id in "${ORDER[@]}"; do
  recipe="$REPO_DIR/recipes/$id.yaml"
  if [[ ! -f "$recipe" ]]; then
    echo "ERROR: recipe not found: $recipe" >&2
    exit 1
  fi
  source_recipe="$recipe"
  if [[ -n "${USER_GOOGLE_EMAILS:-}" ]] && grep -q 'key: google_accounts' "$recipe"; then
    mkdir -p "$RENDER_DIR"
    rendered="$RENDER_DIR/$id.yaml"
    render_recipe "$recipe" "$rendered"
    source_recipe="$rendered"
    echo "==> $id: multi-account roster baked into rendered copy ($rendered)"
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
    --recipe-source "$source_recipe"
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
