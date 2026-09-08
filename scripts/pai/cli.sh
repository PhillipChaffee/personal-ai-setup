#!/usr/bin/env bash
# cli.sh — the `pai` dispatcher. READ-ONLY EXCEPT FOR ONE OPT-IN FLAG.
#
# doctor/status/list are doctor.py; verify is a runner over the existing
# scripts/verify/check-*.sh. The split is deliberate: verify is shell because
# the things it runs are shell, and a Python wrapper would only re-implement
# exit-code plumbing that lib.sh already has.
#
# EVERY COMMAND HERE WRITES NOTHING, with exactly one exception, added in #34:
# `pai doctor --fix`. It re-asserts, over goose's ACP config API, the keys the
# repo's own templates declare — the API rather than the file because goose
# serde-round-trips config.yaml, so a file-copying "fix" would be undone the
# next time goose starts. `pai doctor --dry-run` prints the same plan and
# writes nothing; that is the reading to reach for first.
#
# Flags are forwarded VERBATIM to doctor.py ("$@", not "$1") — it owns the
# option vocabulary, and an unknown flag must be its usage error rather than a
# word this dispatcher silently drops.
set -euo pipefail

# shellcheck source=scripts/verify/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../verify" && pwd)/lib.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage: pai <command> [options]

  doctor   what drifted between this machine and the repo's templates
  status   what is installed here
  list     what the repo ships
  verify   run the scripts/verify/check-*.sh suite, one table, one exit code

Every command writes nothing, except `doctor --fix`:

  doctor --dry-run             say exactly what --fix would do. writes nothing.
  doctor --fix                 re-assert the repo's own keys over goose's ACP
                               config API. THIS WRITES. Refuses to touch an
                               extension whose live config still holds inline
                               `envs` values, because any ACP write erases them.
  doctor --fix --migrate-envs  additionally promote those values into goose's
                               secret store. One way; the value is never printed.

Exit: 0 ok, 1 findings, 2 usage/precondition.

  PAI_HOME       inspect a different home (used by the tests); defaults to $HOME.
                 --fix REFUSES when it is not $HOME unless GOOSE_ACP_URL or
                 PAI_GOOSE_BIN also names which goose is meant.
  GOOSE_ACP_URL  a running `goose serve` to use; nothing is spawned. Required on
                 the brain, where goose-serve.service already owns the config.
  PAI_GOOSE_BIN  the goose binary --fix may spawn on loopback for the duration.
EOF
}

# PyYAML is not universally present, and this repo already solved that twice —
# check-connectors.sh:145-159 and check-security.sh. Same ladder, same message.
py_runner() {
  if ! command -v python3 >/dev/null 2>&1; then
    die 2 "python3 not found (needed to read the goose config)"
  fi
  if python3 -c 'import yaml' >/dev/null 2>&1; then
    printf '%s' "python3"
    return
  fi
  if command -v uv >/dev/null 2>&1; then
    printf '%s' "uv run --quiet --with pyyaml python"
    return
  fi
  die 2 "python3 cannot import yaml (PyYAML)." \
    "  Mac:   uv is installed by scripts/mac/bootstrap-mac.sh — re-run it," \
    "         or: python3 -m pip install --user pyyaml" \
    "  Brain: apt-get install -y python3-yaml"
}

cmd_verify() {
  # Host-aware roster: running check-brain.sh from a Mac only ever produces an
  # exit-2 about BRAIN_HOST, which is noise rather than a finding.
  local mode checks
  mode="$(pai_mode no)"
  if [ "$mode" = "local" ]; then
    checks="providers goose mcp connectors brain code-agents"
  else
    checks="providers goose mcp connectors"
  fi
  echo "== pai verify (host: $mode) =="
  echo
  for name in $checks; do
    local script="$REPO_ROOT/scripts/verify/check-$name.sh"
    [ -x "$script" ] || { skip "check-$name.sh is not present"; continue; }
    local rc=0
    "$script" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0) pass "check-$name" ;;
      # 2 is "unusable environment" by this repo's convention (missing keys, no
      # goose). Inside a sweep that is a SKIP; if the user named the check
      # explicitly it would be a failure, which is the rule
      # check-connectors.sh:1951 already applies one level down.
      2) skip "check-$name (exit 2 — precondition missing)" ;;
      *) fail "check-$name (exit $rc)" ;;
    esac
  done
  finish --skips
}

case "${1:-}" in
  -h|--help|"") usage; exit 0 ;;
  doctor|status|list)
    read -r -a PY <<<"$(py_runner)"
    exec "${PY[@]}" "$REPO_ROOT/scripts/pai/doctor.py" "$@"
    ;;
  verify) cmd_verify ;;
  *) die_usage "unknown command: $1" ;;
esac
