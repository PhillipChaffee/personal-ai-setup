#!/usr/bin/env bash
# check-docs.sh — README.md carries GENERATED regions; this is the gate that
# says so and proves it.
#
# Two regions today, both rendered by scripts/verify/docs_lint.py: the repo map
# (whose counts come from the filesystem on every render) and the add-on menu
# (whose rows come from config/units/*.yaml). A generated block with no checker
# rots FASTER than a hand-written one, because it reads as authoritative — the
# README said "11 skills" against 12 directories in config/skills/ and "the six
# automations" against 7 files in recipes/, and neither number had anywhere to
# be checked. So the renderer and the gate are the same program, and this runs
# it in the mode that changes nothing.
#
# WHY A THIN WRAPPER. Same seam as check-goose-template.sh and check-units.sh:
# the work is a YAML parse, a tree render and a byte comparison, which is
# Python's job; the verdict counting and the exit-code convention are lib.sh's.
# It also puts docs_lint.py under ruff and mypy --strict, which a heredoc
# forecloses.
#
# UNCLAIMABLE, and for a stated reason. units_lint.py's UNCLAIMABLE map holds
# this file: no unit can legitimately claim it, because a unit claiming it would
# be asserting that the docs gate proves something about that unit, when what it
# does is check the README's account of the whole repo — including that unit.
# `pai verify` lists it, with the other three unclaimable gates, under "claimed
# by no unit". docs-lint.yml runs it, and `pai docs` is the same thing by hand.
set -euo pipefail

# shellcheck source=scripts/verify/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Resolved from BASH_SOURCE, never `git rev-parse --show-toplevel`: the negative
# harness runs a COPY of the tree out of a temp directory, and a git-derived root
# would walk back up to the real checkout and validate that instead — leaving
# every probe inert while still going green. Same rule check-units.sh applies.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: check-docs.sh [--check | --write] [--help]

  --check   (default) every generated region in the docs must equal what
            docs_lint.py renders for it, byte for byte, and every structural
            assertion in that file's docstring must hold. This is what CI runs.
  --write   re-render every region in place, then check. Run this after adding
            a unit manifest, a skill, a connector, or anything else the map
            counts — and commit the result. Mutually exclusive with --check.

Needs python3 with PyYAML (falls back to `uv run --with pyyaml`). Speaks to no
network and needs no credentials. Exit: 0 ok, 1 findings, 2 usage/precondition.
EOF
}

# A LOOP AND A SHIFT, exactly as check-units.sh does it, and here it is not
# stylistic. This was `case "${1:-}"` with no loop: every argument after the
# first was silently discarded, so `check-docs.sh --check --no-such-flag` exited
# 0 with the bogus flag gone -- and, in the direction that costs something,
# `check-docs.sh --write --check` performed the WRITE. This is the only gate in
# scripts/verify/ with a mode that edits tracked files; it is the last one that
# may drop a word of its own argv.
#
# AND MUTUALLY EXCLUSIVE, which check-units.sh does not need. Its two modes both
# only read, so last-wins is harmless there. Here "last wins" would make whether
# README.md gets rewritten depend on which order two flags were typed in, and
# docs_lint.py's own parser already refuses the pair
# (add_mutually_exclusive_group); the wrapper says the same thing rather than
# quietly picking one.
MODE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --check|--write)
      if [ -n "$MODE" ] && [ "$MODE" != "$1" ]; then
        die_usage "--check and --write are mutually exclusive (got $MODE then $1)"
      fi
      MODE="$1"
      ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift
done
[ -n "$MODE" ] || MODE="--check"

# ---- python runner ----------------------------------------------------------
# lib.sh's py_runner. The assignment is deliberate: `read -r -a PY <<<"$(...)"`
# swallows the die (verified under bash 3.2.57), which is what the version in
# cli.sh used to do.
PY_CMD="$(py_runner)"
read -r -a PY <<<"$PY_CMD"

# ---- run --------------------------------------------------------------------
OUT_FILE="$(mktemp)"
trap 'rm -f "$OUT_FILE"' EXIT

# `RC=0; ... || RC=$?`, never `if "${PY[@]}" ...; then`: a command inside an `if`
# runs with errexit disabled for its whole body, and this script's whole job is
# to notice a non-zero exit.
RC=0
"${PY[@]}" "$HERE/docs_lint.py" "$MODE" >"$OUT_FILE" 2>&1 || RC=$?

while IFS= read -r line; do
  case "$line" in
    "PASS  "*) pass "${line#PASS  }" ;;
    "FAIL  "*) fail "${line#FAIL  }" ;;
    "NOTE  "*) note "${line#NOTE  }" ;;
    *) echo "$line" ;;
  esac
done <"$OUT_FILE"

# A checker that DIED rather than reported is itself a failure — otherwise a
# traceback (an unreadable manifest, a vanished README) would exit non-zero with
# zero FAIL lines and `finish` would call it a pass. Same rule check-units.sh
# and check-goose-template.sh apply.
if [ "$RC" -ne 0 ] && [ "$FAIL_COUNT" -eq 0 ]; then
  fail "docs_lint.py $MODE exited $RC without reporting a verdict"
fi

summary_row "generated doc regions ($MODE): $PASS_COUNT ok, $FAIL_COUNT failed"
finish
