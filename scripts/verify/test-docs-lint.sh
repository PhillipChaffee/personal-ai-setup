#!/usr/bin/env bash
# test-docs-lint.sh — the negative harness for check-docs.sh / docs_lint.py.
#
# EVERY ASSERTION IN docs_lint.py IS FED A BROKEN INPUT HERE ONCE, and the probe
# greps the MESSAGE rather than the exit code. That distinction is the whole
# point: check-docs.sh exits non-zero for a missing PyYAML, for a stale region,
# for a dangling annotation and for a traceback, so an exit-code-only probe goes
# green with the assertion it claims to test DELETED. This repo has shipped a
# "byte for byte" check that passed on a CRLF file and a differential that
# sorted both sides; the counter at the bottom of this file exists because it
# has also shipped a harness that skipped its own probes and exited 0.
#
# HOW A PROBE WORKS. A pristine copy of the working tree is made once, and every
# probe starts from a fresh copy OF THAT COPY, mutates exactly one thing, and
# runs the checker out of the mutated tree. That works only because
# docs_lint.py's REPO_ROOT comes from __file__ and never from `git rev-parse`:
# a git-derived root would walk back up to the real checkout, validate that, and
# leave every probe below inert while still exiting 0.
#
# THE MUTATIONS ARE ASSERTED TOO. `subst` refuses unless the text it is replacing
# occurs exactly once, so a probe whose mutation stopped applying aborts the run
# instead of quietly testing nothing.
#
# WHAT IS HAND-TYPED, and why. The seven budget rows below were typed out by
# hand from README.md, not extracted from it: a golden derived from the thing
# under test compares that thing to itself and can never fail. Those rows are
# quoted verbatim by 8 `cost` entries across 7 unit manifests
# (units_lint.check_cost re-reads README.md and requires `line` and `amount` on
# the SAME line), so this is the assertion that the README rewrite did not
# silently break the manifest catalog.
#
#   scripts/verify/test-docs-lint.sh      # no arguments, no network, no goose
#
# Exit: 0 all probes green, 1 any probe red or the probe count wrong.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/docs-lint-test.XXXXXX")"

cleanup() {
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT
# 130 is the conventional "killed by SIGINT" status. Separate from the EXIT trap
# so Ctrl-C actually stops the run rather than resuming at the next probe.
trap 'cleanup; exit 130' INT TERM HUP

# shellcheck source=scripts/verify/lib.sh
. "$HERE/lib.sh"

# The count is asserted at the bottom. Raise it in the same commit that adds a
# probe; a probe that stops running takes this number with it.
EXPECTED_PROBES=21
PROBES=0
probe() {
  PROBES=$((PROBES + 1))
  return 0
}

PY_CMD="$(py_runner)"
read -r -a PY <<<"$PY_CMD"

PRISTINE="$WORK/pristine"
TREE="$WORK/tree"

# ---- the tree copy -----------------------------------------------------------
# cp -R over a name list, not `tar --exclude`: GNU tar and bsdtar disagree about
# whether an unanchored --exclude pattern matches a basename, and a copy that
# silently kept .git here would be a copy whose checker still found the real
# checkout. The dot-glob is guarded because `.[!.]*` stays literal when nothing
# matches.
mkdir -p "$PRISTINE"
for entry in "$REPO_ROOT"/* "$REPO_ROOT"/.[!.]*; do
  [ -e "$entry" ] || continue
  case "${entry##*/}" in
    .git|.claude|node_modules|.mypy_cache|.ruff_cache|htmlcov) continue ;;
  esac
  cp -R "$entry" "$PRISTINE/"
done
rm -rf "$PRISTINE/infra/terraform/.terraform"

fresh() {
  rm -rf "$TREE"
  cp -R "$PRISTINE" "$TREE"
  return 0
}

# ---- helpers -----------------------------------------------------------------

RC=0
OUT=""

# run_docs [args...] — run the checker out of the MUTATED tree.
run_docs() {
  RC=0
  OUT="$("$TREE/scripts/verify/check-docs.sh" "$@" 2>&1)" || RC=$?
  return 0
}

# subst <file> <old> <new> — exact replacement, and a HARD ERROR unless `old`
# occurs exactly once. A mutation that no longer applies must stop the run, not
# leave a probe testing an unmutated file.
subst() {
  "${PY[@]}" - "$1" "$2" "$3" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old, new = sys.argv[2], sys.argv[3]
found = text.count(old)
if found != 1:
    sys.exit(f"subst: {path}: expected 1 occurrence of {old!r}, found {found}")
path.write_text(text.replace(old, new), encoding="utf-8")
PY
  return 0
}

indent_out() {
  printf '%s\n' "$OUT" | sed 's/^/      /'
  return 0
}

# expect_fail <label> <needle> — the run must be non-zero AND say `needle`.
expect_fail() {
  probe
  if [ "$RC" -eq 0 ]; then
    fail "$1: check-docs.sh exited 0 — that assertion is INERT"
    indent_out
    return 0
  fi
  if printf '%s\n' "$OUT" | grep -qF -- "$2"; then
    pass "$1"
  else
    fail "$1: it failed, but never said \"$2\""
    indent_out
  fi
  return 0
}

# expect_line <label> <needle> — `needle` must appear, whatever the exit code.
# This is how the "the OTHER assertion stayed green" half of a probe is made.
expect_line() {
  probe
  if printf '%s\n' "$OUT" | grep -qF -- "$2"; then
    pass "$1"
  else
    fail "$1: the output never said \"$2\""
    indent_out
  fi
  return 0
}

expect_ok() {
  probe
  if [ "$RC" -eq 0 ]; then
    pass "$1"
  else
    fail "$1: exit $RC"
    indent_out
  fi
  return 0
}

expect_same() {
  probe
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1: '$2' is not '$3'"
  fi
  return 0
}

# ---- the hand-typed budget golden --------------------------------------------
# Typed from README.md by hand, on purpose. Eight `cost` entries across seven
# manifests quote these rows verbatim; units_lint.check_cost is what enforces
# that, and this is what notices if the rewrite moved a character.
budget_rows() {
  cat <<'EOF'
| Hetzner cpx21-class VPS + encrypted volume | ~€6–9/mo |
| OpenCode Zen inference (PAYG — **disable auto-reload, set a cap**) | ~$5–20/mo typical |
| Together AI inference (min $5 top-up; sensitive tier + default hub) | ~$5–10/mo |
| Tailscale (personal plan), ntfy failure-alert emails (free tier) | $0 |
| Code agents on the brain (containers) | no new account — bills to the Zen/Together lines above, plus disk |
| Pal Chat (backup phone client) | ~$7 one-time |
| **Total** | **~$15–35/mo** |
EOF
  return 0
}

BUDGET_MISS=""
# assert_budget <tree> — fills BUDGET_MISS with any row that is not present
# verbatim. A function rather than an `if grep`, so errexit stays live in here.
assert_budget() {
  local line
  BUDGET_MISS=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qxF -- "$line" "$1/README.md" || BUDGET_MISS="$BUDGET_MISS"$'\n'"      $line"
  done < <(budget_rows)
  return 0
}

echo "== test-docs-lint.sh: the negative harness for the generated doc regions =="
echo

# ---- the baseline ------------------------------------------------------------
# Everything below is a mutation of a tree that starts green. Without this, a
# probe could be reporting a pre-existing failure as its own success.
fresh
run_docs
expect_ok "an unmutated copy of the working tree passes check-docs.sh"

assert_budget "$TREE"
probe
if [ -z "$BUDGET_MISS" ]; then
  pass "all 7 hand-typed budget rows are in README.md verbatim (8 cost entries quote them)"
else
  fail "budget rows missing from README.md — units_lint.check_cost will be red:$BUDGET_MISS"
fi

# The acceptance criterion for the re-anchoring: no manifest may cite a line
# number in the ROOT README, because two generated regions now move those lines.
# `[^/]` keeps config/connectors/README.md:9-11 out of it — that is a different
# file and a different, still-valid citation.
CITATIONS="$(grep -rnE '(^|[^/])README\.md:[0-9]' "$TREE/config/units/" || true)"
probe
if [ -z "$CITATIONS" ]; then
  pass "no unit manifest cites a line number in the root README.md"
else
  fail "manifests still cite root-README line numbers:"$'\n'"$CITATIONS"
fi

# ---- A1: the byte comparison, one region at a time ---------------------------
# The broken input is the exact regression this whole PR exists for: a skill
# directory appears and the README's count does not move.
fresh
mkdir -p "$TREE/config/skills/zz-probe"
printf '# probe skill\n' >"$TREE/config/skills/zz-probe/SKILL.md"
run_docs
expect_fail "A1: a new skill directory makes the repo map STALE" \
  "README.md region 'repo-map' is STALE"
# And the count really came from the filesystem rather than from a literal: the
# render says 13 where the committed file says 12.
expect_line "A1: the stale render counts the 13 skills that are on disk" \
  "13 skills, Claude-compatible"

# The other region, driven by the other source. A summary is data no glob can
# see, so this also proves the menu is rendered from the manifests.
fresh
subst "$TREE/config/units/base-goose.yaml" \
  "summary: Pinned goose CLI and Desktop cask, four custom providers, config template." \
  "summary: Something else entirely."
run_docs
expect_fail "A1: an edited manifest summary makes the add-on menu STALE" \
  "README.md region 'units-menu' is STALE"

# ---- A2: a dangling annotation, WITH A1 still green --------------------------
# This is the probe that justifies A2 existing at all. The annotations are static
# data, so deleting an annotated doc changes no count and no row: A1 passes,
# happily, about a map that points at a file that is gone. Both halves are
# asserted, because check-docs.sh exits 1 on any FAIL and an exit-code-only probe
# could not tell the two apart.
fresh
rm "$TREE/docs/providers.md"
run_docs
expect_fail "A2: a deleted annotated doc is caught" \
  "the repo map annotates 'docs/providers.md', which does not exist"
expect_line "A2: ...and A1 stayed GREEN through it, which is why A2 is not redundant" \
  "PASS  README.md region 'repo-map' is current"

# ---- A3: a directory nobody wrote down ---------------------------------------
# Neither A1 nor A2 can see this: both only know about paths already on the map.
fresh
mkdir -p "$TREE/config/prompts"
printf 'placeholder\n' >"$TREE/config/prompts/example.md"
run_docs
expect_fail "A3: a new config/ subdirectory that no map line covers is caught" \
  "config/prompts is not on the repo map"

# ---- A4: a hardcoded count ---------------------------------------------------
# The "11 skills" regression, re-created: replace the {n} placeholder with the
# number that happens to be right today. A1 alone would then compare a
# hand-typed number to itself forever.
fresh
subst "$TREE/scripts/verify/docs_lint.py" \
  '"{n} skills, Claude-compatible' \
  '"12 skills, Claude-compatible'
run_docs
expect_fail "A4: a note that hardcodes its count instead of deriving it is caught" \
  "the repo map's note for 'config/skills' hardcodes a count"

# ---- A5: a duplicated marker, and the --write refusal ------------------------
# The failure mode A5 exists for is not a confusing message, it is DATA LOSS:
# splicing between "the first begin" and "the end" deletes everything in between.
fresh
subst "$TREE/README.md" \
  "<!-- pai-docs:begin repo-map -->" \
  "<!-- pai-docs:begin repo-map -->
<!-- pai-docs:begin repo-map -->"
run_docs
expect_fail "A5: a duplicated begin marker is caught" \
  "has 2 '<!-- pai-docs:begin repo-map -->' markers"

BEFORE="$(cksum <"$TREE/README.md")"
run_docs --write
AFTER="$(cksum <"$TREE/README.md")"
expect_line "A5: --write says so rather than splicing" "nothing was written"
expect_same "A5: --write left README.md byte-identical instead of eating the region" \
  "$BEFORE" "$AFTER"

# ---- A6: a bare pipe in a rendered cell --------------------------------------
# units_lint caps a summary at 120 characters and says nothing about pipes.
fresh
subst "$TREE/config/units/base-goose.yaml" \
  "summary: Pinned goose CLI and Desktop cask, four custom providers, config template." \
  "summary: Pinned goose CLI | Desktop cask, four custom providers."
run_docs
expect_fail "A6: a pipe in a manifest summary would shift every column of its row" \
  "contains a bare '|'"

# ---- A7: an incomplete link --------------------------------------------------
# `runbook: ""` is a state a human can type. A truth test would render it as a
# bare id and lose it; `is not None` renders `[id]()`, which A7 refuses.
fresh
subst "$TREE/config/units/base-goose.yaml" \
  "runbook: docs/setup/20-mac-setup.md" \
  'runbook: ""'
run_docs
expect_fail "A7: an empty runbook string renders an empty link target, and is caught" \
  "renders an incomplete link"

# The other side of A7: a genuinely absent runbook must render as a PLAIN id,
# with no brackets at all. Read straight off --print, because check-docs.sh only
# reports verdicts and this is a claim about the rendered text.
fresh
subst "$TREE/config/units/brain.yaml" \
  "runbook: docs/setup/50-vps-brain.md" \
  "runbook: null"
MENU="$("${PY[@]}" "$TREE/scripts/verify/docs_lint.py" --print units-menu)"
probe
if printf '%s\n' "$MENU" | grep -q '^| brain |'; then
  pass "A7: a null runbook renders a plain id, never an empty link"
else
  fail "A7: brain's row is not a plain id:"$'\n'"$(printf '%s\n' "$MENU" | grep -F '| brain')"
fi

# ---- A8: the externally registered permalinks --------------------------------
# SAY WHAT THIS IS: a string comparison. docs/index.md is the Pages landing page
# and docs/app-privacy-policy.md's URL sits on a Google OAuth consent screen, and
# nothing in CI can fetch either — lychee runs --offline. What is provable is
# that the two strings did not change and that no third page minted one.
fresh
subst "$TREE/docs/index.md" "permalink: /" "permalink: /home/"
run_docs
expect_fail "A8: editing an externally registered permalink is caught" \
  "docs/index.md must declare exactly one 'permalink: /'"

fresh
subst "$TREE/docs/roadmap.md" "# Roadmap" $'---\npermalink: /roadmap/\n---\n\n# Roadmap'
run_docs
expect_fail "A8: a NEW published URL nobody registered is caught too" \
  "which is a published URL nobody registered"

# ---- the wrapper's died-without-a-verdict rule -------------------------------
# A traceback exits non-zero with zero FAIL lines, and `finish` would call that a
# pass. check-units.sh and check-goose-template.sh carry the same rule; this is
# the probe that shows check-docs.sh actually has it.
fresh
printf 'id: brain\ncost: [\n' >"$TREE/config/units/brain.yaml"
run_docs
expect_fail "the wrapper turns a traceback into a FAIL rather than a silent pass" \
  "without reporting a verdict"

# ---- --write actually repairs ------------------------------------------------
# A --write that did nothing would leave every probe above passing.
fresh
mkdir -p "$TREE/config/skills/zz-probe"
printf '# probe skill\n' >"$TREE/config/skills/zz-probe/SKILL.md"
run_docs --write
expect_ok "--write re-renders the stale region and the re-check that follows passes"

# ---- the hand-typed golden can itself fail -----------------------------------
# Otherwise the budget assertion at the top is decoration.
fresh
# shellcheck disable=SC2016  # `$15` and `$99` are dollars in a budget table,
# not shell expansions; single quotes are what keeps them literal.
subst "$TREE/README.md" \
  '| **Total** | **~$15–35/mo** |' \
  '| **Total** | **~$99/mo** |'
assert_budget "$TREE"
probe
if [ -n "$BUDGET_MISS" ]; then
  pass "the hand-typed budget golden goes red when a budget row is edited"
else
  fail "the budget golden accepted an edited Total row — it is INERT"
fi

# ---- the probe count ---------------------------------------------------------
# THE GUARD AGAINST THIS FILE'S OWN FAILURE MODE. A harness that skips its own
# probes and exits 0 has shipped from this repo before. Every probe increments
# the counter; a `fresh` that silently produced an empty tree, an early `return`,
# or a deleted block shows up here as a number rather than as a green run.
echo
if [ "$PROBES" -eq "$EXPECTED_PROBES" ]; then
  pass "all $EXPECTED_PROBES probes ran"
else
  fail "$PROBES probes ran, expected $EXPECTED_PROBES — probes were skipped or added"
fi

summary_row "docs regions: $PROBES probes, $PASS_COUNT ok, $FAIL_COUNT failed"
finish
