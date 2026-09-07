#!/usr/bin/env bash
# check-goose-template.sh — config/goose/config.yaml is a GENERATED artifact;
# this is the gate that says so and proves it.
#
# The sources are config/goose/config.base.yaml plus one file per extension in
# config/goose/extensions.d/. The generated file stays committed because five
# tracked scripts and ~15 doc references read that path — goose_template.py's
# docstring has the list. This checks that what is committed is exactly what
# the sources compose to, and five other things a per-file YAML linter cannot
# see (comment survival, per-file comment location, one-key-per-fragment,
# cross-file key collisions, allowlist-or-disabled).
#
# WHY A THIN WRAPPER. The work is a multiset comparison and a YAML parse, which
# is Python's job; the verdict counting and the exit-code convention are
# lib.sh's. So this file is the seam: it resolves a python that can import
# yaml (the same ladder cli.sh and check-connectors.sh use — PyYAML is not
# universally present) and turns the checker's PASS/FAIL lines into this
# repo's counters, so `check-goose-template.sh` totals like every other
# check-*.sh rather than inventing its own output shape.
set -euo pipefail

# shellcheck source=scripts/verify/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: check-goose-template.sh [--check | --write] [--help]

  --check   (default) config/goose/config.yaml must equal
            compose(config.base.yaml, extensions.d/*) byte for byte, and the
            five structural assertions must hold. This is what CI runs.
  --write   regenerate config/goose/config.yaml from the sources, then check.
            Run this after editing config.base.yaml or any fragment.

Needs python3 with PyYAML (falls back to `uv run --with pyyaml`). Speaks to
nothing and needs no credentials. Exit: 0 ok, 1 findings, 2 usage/precondition.
EOF
}

MODE="--check"
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  ""|--check) ;;
  --write) MODE="--write" ;;
  *) die_usage "unknown argument: $1" ;;
esac

# ---- python runner ----------------------------------------------------------
# Third copy of this ladder (check-connectors.sh, cli.sh), same message on
# purpose: a person who hits it in one script should recognise it in the next.
if command -v python3 >/dev/null 2>&1; then
  :
else
  die 2 "python3 not found (needed to parse YAML)"
fi
PY=(python3)
if python3 -c 'import yaml' >/dev/null 2>&1; then
  :
elif command -v uv >/dev/null 2>&1; then
  PY=(uv run --quiet --with pyyaml python)
else
  die 2 "python3 cannot import yaml (PyYAML)." \
    "  Mac:   uv is installed by scripts/mac/bootstrap-mac.sh — re-run it," \
    "         or: python3 -m pip install --user pyyaml" \
    "  Brain: apt-get install -y python3-yaml"
fi

# ---- run --------------------------------------------------------------------
OUT_FILE="$(mktemp)"
trap 'rm -f "$OUT_FILE"' EXIT

RC=0
"${PY[@]}" "$HERE/goose_template.py" "$MODE" >"$OUT_FILE" 2>&1 || RC=$?

while IFS= read -r line; do
  case "$line" in
    "PASS  "*) record_pass ;;
    "FAIL  "*) record_fail ;;
  esac
  echo "$line"
done <"$OUT_FILE"

# A checker that DIED rather than reported is itself a failure — otherwise a
# traceback (missing source file, unreadable fragment) would exit non-zero with
# zero FAIL lines and `finish` would call it a pass. Same rule
# check-connectors.sh's run_check applies to its own checkers.
if [ "$RC" -ne 0 ] && [ "$FAIL_COUNT" -eq 0 ]; then
  fail "goose_template.py $MODE exited $RC without reporting a verdict"
fi

summary_row "goose config template: $PASS_COUNT ok, $FAIL_COUNT failed"
finish
