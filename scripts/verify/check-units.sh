#!/usr/bin/env bash
# check-units.sh — the unit-manifest gate. config/units/*.yaml claims what each
# installable piece of this setup ACTUALLY IS TODAY; this is what makes those
# claims falsifiable.
#
# Seven properties, all offline: schema and identity (an unknown top-level key
# is FATAL), the requires graph, the two-state installer assertion, footprint
# disjointness, verify/runbook resolution in both directions, store-conditioned
# secrets, and freshness. config/units/README.md is the contract; the reasons
# each rule exists are there and in units_lint.py's docstring.
#
# THE POINT IS THE ABSENCES. Eight of eighteen units have nothing that installs
# them and eleven have no verify script. The schema has a place to record every
# such gap, and this gate FAILS when one is unrecorded — `verify: []` without a
# `no-verify` blocker, `installer: null` without manual steps. A manifest that
# papers over a gap converts an unknown into a wrong known.
#
# WHY A THIN WRAPPER. Same seam as check-goose-template.sh: the work is a YAML
# parse, a topological sort and six cross-file joins, which is Python's job;
# the verdict counting and the exit-code convention are lib.sh's. It also puts
# units_lint.py under ruff and mypy --strict, which a heredoc forecloses.
#
# STILL NOT IN `pai verify`, and now for a stated reason rather than by
# accident. That roster is no longer a hardcoded string — cmd_verify derives it
# from the manifests' `verify:` — but this script is UNCLAIMABLE
# (units_lint.py's UNCLAIMABLE map): a unit claiming it would be asserting that
# the validator proves something about that unit, when what it does is validate
# every manifest including that one. `pai verify` lists it, with the other two
# unclaimable gates, under "claimed by no unit". data-lint.yml runs it.
set -euo pipefail

# shellcheck source=scripts/verify/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Resolved from BASH_SOURCE, never `git rev-parse --show-toplevel`: the
# negative tests in data-lint.yml run a COPY of the tree out of $RUNNER_TEMP,
# and a git-derived root would walk back up to the real checkout and validate
# that instead — leaving both negative tests inert while still going green.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: check-units.sh [--offline | --strict] [--help]

  --offline (default) The CI gate. Three checks that cannot pass until the
            whole catalog exists are NOTEs here: the verify reverse-closure,
            the secrets reverse-closure, and the 180-day staleness window.
  --strict  Promotes those three from NOTE to FAIL. This is the monthly
            scheduled run, where a red build is a work item rather than a
            blocked push. Every manifest carries the same verified_on, so a
            staleness FAIL in a required job would turn the whole catalog red
            on one calendar day for whoever happened to push next — which is
            the fastest way to get a gate deleted.

A future-dated verified_on FAILs in BOTH modes: there is no benign reason.

Needs python3 with PyYAML (falls back to `uv run --with pyyaml`). Speaks to no
network, needs no credentials, and needs no goose. It does run one local
program: P8(f) executes `bootstrap-mac.sh --dry-run` once per unit, which
writes nothing and needs neither Homebrew nor macOS.
Exit: 0 ok, 1 findings, 2 usage/precondition.
EOF
}

MODE="--offline"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --offline) MODE="--offline" ;;
    --strict)  MODE="--strict" ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift
done

# ---- python runner ----------------------------------------------------------
# lib.sh's, not a fourth copy. The comment this replaces explained that cli.sh's
# py_runner could not be reused because sourcing cli.sh runs a top-level `case`
# that exits — true, and the answer was to move the function to the file all
# four of these scripts already source rather than to copy it again.
PY_CMD="$(py_runner)"
read -r -a PY <<<"$PY_CMD"

# ---- run --------------------------------------------------------------------
OUT_FILE="$(mktemp)"
trap 'rm -f "$OUT_FILE"' EXIT

RC=0
"${PY[@]}" "$HERE/units_lint.py" "$MODE" >"$OUT_FILE" 2>&1 || RC=$?

while IFS= read -r line; do
  case "$line" in
    "PASS  "*) pass "${line#PASS  }" ;;
    "FAIL  "*) fail "${line#FAIL  }" ;;
    "NOTE  "*) note "${line#NOTE  }" ;;
    *) echo "$line" ;;
  esac
done <"$OUT_FILE"

# A checker that DIED rather than reported is itself a failure — otherwise a
# traceback (an unreadable manifest, a missing installer) would exit non-zero
# with zero FAIL lines and `finish` would call it a pass. Same rule
# check-goose-template.sh and check-connectors.sh's run_check apply.
if [ "$RC" -ne 0 ] && [ "$FAIL_COUNT" -eq 0 ]; then
  fail "units_lint.py $MODE exited $RC without reporting a verdict"
fi

summary_row "unit manifests ($MODE): $PASS_COUNT ok, $FAIL_COUNT failed"
finish
