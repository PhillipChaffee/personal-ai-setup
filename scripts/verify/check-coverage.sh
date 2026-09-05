#!/usr/bin/env bash
# check-coverage.sh — the half of the coverage gate `coverage report` cannot do.
#
# `coverage report --fail-under` enforces ONE number over the whole project, so
# a file at 40% hides behind a file at 99%, and a brand-new file contributes
# only its own weight to a total that barely moves. This adds:
#
#   1. a PER-FILE floor, so no single file can rot behind the average
#   2. an INVENTORY check, so a .py that the measurement never saw is a
#      failure rather than a silent absence
#
# (2) is the one that matters as scripts/pai/ lands. `source = scripts` only
# discovers a file in a directory without __init__.py when
# include_namespace_packages is on -- and if that ever regresses, the total
# goes UP (the uncovered file leaves the denominator) while coverage of the
# repo goes down. A gate that rewards deleting measurement is worse than none.
#
# Bash + jq deliberately: a new .py here would owe mypy --strict and
# ruff select=["ALL"], and a gate script is not worth opening that door for.
set -euo pipefail

# shellcheck source=scripts/verify/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: check-coverage.sh <coverage.json> [--per-file N]

Reads a `coverage json` report and enforces the two things the total floor
cannot: a per-file minimum, and that every tracked .py under the measured
scope actually appears in the report.

  --per-file N   per-file floor, percent (default: 85)

Exit: 0 all good; 1 a floor or inventory failure; 2 usage/precondition.
EOF
}

PER_FILE=85
REPORT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --per-file) shift; [ "$#" -gt 0 ] || die 2 "--per-file needs a number"; PER_FILE="$1" ;;
    -h|--help)  usage; exit 0 ;;
    -*)         die_usage "unknown option: $1" ;;
    *)          REPORT="$1" ;;
  esac
  shift
done

[ -n "$REPORT" ] || die_usage "no coverage.json given"
[ -r "$REPORT" ] || die 2 "cannot read $REPORT" \
  "Produce it with: coverage json --data-file=.coverage -o coverage.json --fail-under=0" \
  "(the --fail-under=0 matters: coverage json HONOURS fail_under and exits 2," \
  " which would kill the step before this gate ever runs.)"
command -v jq >/dev/null 2>&1 || die 2 "jq not found"

# THE OMIT LIST IS DUPLICATED ON PURPOSE. It also lives in .coveragerc, and the
# check below fails if the two disagree -- so adding a second exemption costs
# an edit in two files and shows up as such in a diff. Exemptions are how a
# coverage gate quietly stops meaning anything.
OMIT_GLOBS="scripts/verify/*"

echo "== check-coverage: per-file floor ${PER_FILE}% + inventory =="
echo

if ! grep -qF "$OMIT_GLOBS" .coveragerc; then
  fail "the omit list here ($OMIT_GLOBS) is not in .coveragerc"
  note "The two must agree, so a new exemption cannot be added in one place."
  finish
fi
pass "the omit list matches .coveragerc"

# ---- 1. per-file floor -------------------------------------------------------
# The float comparison happens in jq, which has floats -- bash does not, and
# shelling out to bc would add a dependency for one subtraction.
#
# CHECKED is not defensive padding. The first version of this loop read a key
# that does not exist (.totals instead of .summary), so jq emitted nothing, the
# loop body never ran, and the script reported "2 passed, 0 failed" -- a gate
# that checked no files and called itself green. A gate must fail when it
# cannot do its job, not when it happens to find nothing wrong.
CHECKED=0
while IFS=$'\t' read -r verdict file pct; do
  CHECKED=$((CHECKED + 1))
  if [ "$verdict" = "low" ]; then
    fail "$file at ${pct}% is below the ${PER_FILE}% per-file floor"
  else
    pass "$file at ${pct}%"
  fi
done < <(jq -r --argjson floor "$PER_FILE" '
  .files | to_entries[]
  | [(if .value.summary.percent_covered < $floor then "low" else "ok" end),
     .key,
     (.value.summary.percent_covered * 100 | round / 100 | tostring)]
  | @tsv' "$REPORT")

if [ "$CHECKED" -eq 0 ]; then
  fail "no files were checked -- the report has no per-file summaries"
  note "This means the gate is inert, not that coverage is fine."
fi

# ---- 2. inventory ------------------------------------------------------------
# Every tracked .py that is NOT omitted must appear in the report. A file the
# measurement never saw reads as "no problem here" and is exactly the failure
# mode include_namespace_packages exists to prevent.
MISSING=""
while IFS= read -r py; do
  case "$py" in
    scripts/verify/*) continue ;;
    scripts/*) ;;
    *) continue ;;
  esac
  jq -e --arg f "$py" '.files | has($f)' "$REPORT" >/dev/null 2>&1 || MISSING="$MISSING $py"
done < <(git ls-files '*.py')

if [ -n "$MISSING" ]; then
  fail "tracked .py files under the measured scope are absent from the report:$MISSING"
  note "Most likely cause: [report] include_namespace_packages is off, so"
  note "coverage refuses to descend into a directory with no __init__.py."
  note "Verify with: coverage report  (the file should appear at 0.00%)"
else
  pass "every tracked .py under scripts/ (excluding the harness) is measured"
fi

finish
