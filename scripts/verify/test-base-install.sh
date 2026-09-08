#!/usr/bin/env bash
# test-base-install.sh — the whole Mac base install, end to end, with NO network,
# NO Homebrew, NO real goose and NO real key. bootstrap-mac.sh runs for real
# against the PAI_EXEC seam (scripts/verify/fake-exec.sh -> fake-brew.sh ->
# fake-goose.sh -> fake-provider.py), into a throwaway $HOME, and then the two
# checks the installer's last screen tells you to run are run against that
# install: check-providers.sh and check-goose.sh.
#
# Nine phases, and each exists because it asserts something no other one can:
#
#   A  fresh install      the 16-line brew golden, the config copy, the skills,
#                         the pins comparison, the deny-PATH invariant
#   B  immediate re-run   idempotence -- the claim at bootstrap-mac.sh:8-9 that
#                         nothing in this repo has ever tested -- and no-clobber
#   C  version mismatch   the pins WARNING arm, which is otherwise dead code
#   D  the real checks    check-providers.sh and check-goose.sh against the fake
#                         provider, asserted on the WIRE and not on the exit code
#   E  default endpoints  ZEN_BASE/TOGETHER_BASE unset still address the real
#                         hosts, proved with a recording curl shim and 0 packets
#   F  the flag surface   --with/--without/--only, and the ways they are refused
#   G  --without opencode the cascade, observed on disk and announced
#   H  --dry-run          the hand-typed plan goldens, and that nothing moved
#   I  the OpenCode unit  the credential unit_opencode() writes with no TUI
#                         (#38), and check-opencode.sh against fake-opencode.sh
#
# THE OPENCODE PHASE IS `I`, NOT `F`, AND THAT IS THE ONE THING #38 HAD TO GIVE
# UP IN THE REBASE. It was written as phase F against a tree where F was free;
# #37's flag surface landed first and took F, G and H, and `--only select`'s
# help text in this file names them. Two phases spelled F would print two
# different `FAIL  F5:` lines in the same run and share five shell variables
# (F4_RC, F5_RC, F5_HOME, F6_RC, F6_OUT) across a thousand lines, so the
# newcomer moved. Every row #38 shipped is here, in order, with an I: I0, I0b,
# I1..I12. install-test.yml's third negative test greps `^FAIL  I1:`.
#
# Every assertion carries its id from the spec (A1..A17, B1..B4, C1, D1..D6,
# E1..E2, F1..F6, G1..G6, H1..H4, I0..I12) so a failure names the thing the
# installer did not do, rather than the line that happened to notice. Ten ids
# are this file's own: E1b, because E1 as written cannot fail the way its
# negative control claims (see phase E); D-deny, which extends the deny-PATH
# invariant over the check-goose step; A9, the no-flag run's zero-skip guard;
# G6, which is the rebase's own row -- #38 added a second OpenCode-specific line
# to the epilogue #37 had just made selection-aware, and G6 is what keeps both
# of them inside the gate; I0b, which asserts check-opencode.sh's exit-2
# precondition arm; I9, which fails when a new env seam is not taken out of the
# environment here; I10/I11, the fixtures C7's and C8's symlink arms never had;
# and I12, which stops the installer's epilogue denying a manual step the
# manifest keeps; A14b0 and A17, which are #111's, and which assert the two
# preconditions A14b cannot assert for itself. A14
# is now A14a + A14b -- the seam's SHAPE and the installer's OUTPUT are two
# claims, and #37 makes only the first of them expressible as a diff of source.
#
# A DIFFERENTIAL THAT CAN SKIP IS A DIFFERENTIAL THAT CAN STOP ASSERTING (#111).
# A14b reads a pre-carve blob out of git history by pinned sha, and every way of
# losing that blob used to be one counted SKIP -- while the exit gate below reads
# $FAIL_COUNT only, so the run stayed green. A14b0 now splits those causes apart
# and only a genuinely shallow clone may skip; A17 asserts the `fetch-depth: 0`
# that keeps CI out of the shallow case; the skip allowlist at $SKIPPABLE makes
# "which assertions may skip" an enumerated decision; and refs/tags/mac-pre-carve
# keeps the pinned object reachable through a squash. See install-test.yml's last
# four negative tests, one per arm.
#
# THE BREW GOLDEN IS HAND-WRITTEN, and that is not a style choice. It is typed
# out below from the shapes bootstrap-mac.sh is supposed to emit, NEVER derived
# from $FORMULAE or from any other line of the code under test: an expectation
# computed from the thing it tests can never fail, and "the installed formula
# list is exactly this" is the acceptance criterion. There is deliberately no
# UPDATE_GOLDEN escape hatch. (test-pai.sh:7-11's "fixtures are generated, not
# committed" rule is about INPUTS -- do not assert against yesterday's rendered
# template. An expectation is the other thing.)
#
# The golden is ORDER SENSITIVE, so reordering the install loop fails it even
# when behaviour is unchanged. Update it, do not sort it: `brew pin` after
# `brew install` is the one ordering that matters, because real brew refuses to
# pin a formula it has not installed and the pin inside unit_base_goose() is a
# bare call under `set -e`.
#
# THE DENY-PATH IS THE INVARIANT. $WORK/deny goes first on PATH for both
# bootstrap phases and holds an exit-127 shim for every external binary this
# installer could reach for. If the log is non-empty, some call went around the
# seam. Nothing else can catch that: the four probe forms (`if brew list ...`,
# `if brew list --pinned | grep`, `pai_have brew`) swallow their own exit
# status, no regex over the source reaches them reliably, and a die-on-unhandled
# fake never sees the call because the call never arrives.
#
# PyYAML IS MANDATORY, asserted up front rather than tolerated. Without it
# unit_base_goose()'s pins ladder falls through to `uv run --with pyyaml
# python`, uv is denied here (it is a fake "install"), want_goose ends up empty,
# and the unit takes the "could not compare the goose version -- skipping the
# check" arm. Both pin arms (A4 and C1) then pass through a branch nobody
# tested, which is exactly the gap routing `goose --version` through the seam
# exists to close.
#
# SECRETS: nothing here handles a real one and nothing may ever print one. The
# real roster is UNSET before the fixtures are exported, so a developer's own
# key can neither decide the outcome nor reach check-providers.sh:81's mask();
# the fixture spellings are the ones already committed at
# test-code-agent-manager.sh:217/219. No assertion message below interpolates a
# captured value -- booleans, counts and status codes only
# (test-code-agent-manager.sh:523-525).
#
# Runs on a laptop, not only in CI: python3 (with PyYAML) + curl + the usual
# BSD/GNU userland, and the fakes do no real work, so the whole thing is
# seconds. `--only <leg>` runs one leg, which is what keeps the workflow's
# negative tests from re-running everything three times.
# shellcheck disable=SC2015
# ^ FILE-LEVEL and load bearing, same as test-code-agent-manager.sh:20-31: every
# assertion is the deliberate `[ cond ] && ok "..." || bad "..."` idiom. SC2015
# warns that `a && b || c` runs c when b fails; it cannot here, because ok()
# ends in `PASS_COUNT=$((PASS_COUNT + 1))`, an arithmetic ASSIGNMENT, which
# always exits 0. Do not "tidy" that to `((PASS_COUNT++))` -- that returns 1
# when the value was 0, so the first passing assertion would also report a
# failure, and this disable would hide it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage: test-base-install.sh [--only brew|goose|providers|routing|select|opencode]
                            [--help]

Runs bootstrap-mac.sh and the verify checks against the fakes in this
directory, in a throwaway $HOME, with no network and fixture keys.

  --only brew        phases A+B+C: the brew invocation goldens and the pins arms
  --only routing     phases A+B plus the structural gates: the deny-PATH
                     invariant and the PAI_EXEC containment/HOME interlock
  --only goose       phase A + check-goose.sh against fake-provider.py
  --only providers   phase A + check-providers.sh, and the phase E default-
                     endpoint proof
  --only select      phase A plus F+G+H: the flag surface (unknown ids,
                     contradictions, --only vs --with), --without opencode, and
                     --dry-run. `--only goose` also runs G, because G5 asserts
                     check-goose.sh against the opencode-less $HOME.
  --only opencode    phase A + phase I: the credential unit_opencode() writes
                     with no TUI, and check-opencode.sh against
                     fake-opencode.sh and phase I's own fake-provider.py
  (no flag)          all of it

Needs python3 with PyYAML (bootstrap compares config/pins.yaml with it) and
curl. Exits non-zero if any assertion fails.
EOF
}

ONLY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --only)
      [ "$#" -ge 2 ] || { echo "test-base-install.sh: --only needs a value" >&2; usage >&2; exit 2; }
      ONLY="$2"; shift 2 ;;
    *) echo "test-base-install.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$ONLY" in
  ""|brew|goose|providers|routing|select|opencode) ;;
  *) echo "test-base-install.sh: unknown --only leg: $ONLY" >&2; usage >&2; exit 2 ;;
esac

leg() {
  # leg <name> -- is this leg in scope for this run?
  [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]
}

PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0
ok()   { echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
bad()  { echo "FAIL  $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# THE SKIP ALLOWLIST (#111) — the exit gate at the bottom of this file is
# `[ "$FAIL_COUNT" -eq 0 ]`, and $SKIP_COUNT has never been part of it. That made
# every skip indistinguishable from a pass to CI, which is how A14b -- the whole
# safety argument for #105's carve -- could stop asserting anything the day its
# pinned blob went unreachable, with no check going red.
#
# THE FIX IS NOT "ANY SKIP FAILS". This repo has skips that are correct: the
# runtime checks in scripts/verify/check-*.sh describe a MACHINE, and
# check-security.sh:281 (no gitleaks), check-mcp.sh:287 (connector not enabled),
# check-opencode.sh:215 (coding-pack not installed) and check-connectors.sh:2129
# (no goose CLI) are all "this box does not have that", which is information, not
# a failure. A blanket rule would either delete those or -- far likelier -- get
# worked around by an author who stops calling skip() and prints a note instead,
# which is strictly worse than a counted skip.
#
# So the rule is per-ASSERTION and enumerated. This harness builds its own
# sandbox and its own fakes: there is no machine for it to be conditional about,
# and exactly one input it cannot fabricate -- git history. An id on this list
# has been argued for once, in writing, next to the arm that skips; an id that is
# not on it CANNOT skip, and calling skipped() for it is reported as a FAILURE
# rather than quietly counted. Adding an id here is a visible, reviewable act in
# the diff -- which is the property "make SKIP_COUNT fail the build" was reaching
# for, without the collateral damage.
#
#   A14b0  and ONLY on its genuinely-shallow-clone arm, which is self-repairing
#          (`git fetch --unshallow`) and which CI cannot hit because
#          install-test.yml sets `fetch-depth: 0` -- itself now asserted, by A17.
#          Every other way of losing the pre-carve blob is a bad(), not a skip.
SKIPPABLE="A14b0"
skipped() {
  # skipped <id> <message>
  case " $SKIPPABLE " in
    *" $1 "*) echo "SKIP  $1: $2"; SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
    *) bad "$1: $2 [and $1 IS NOT ON THIS HARNESS'S SKIP ALLOWLIST ('$SKIPPABLE'), so this skip is a failure: either fix the condition, or add the id above with the argument for why a skip there is honest]" ;;
  esac
}
# Indented evidence under a failure, the check-goose.sh:121 shape. Only ever fed
# a file this harness or a fake wrote -- never an environment value.
# `head` FIRST, and `|| true`: evidence is only ever called from a failure arm,
# so it is the last command of an if/&&-group, and under `set -euo pipefail` a
# missing file (or sed taking SIGPIPE from a head that stopped at 40) would end
# the whole run there -- turning one named failure into a truncated log with no
# summary and every later assertion unevaluated.
evidence() { { head -40 "$1" 2>/dev/null || true; } | sed 's/^/      | /'; }
die() { echo "test-base-install.sh: $*" >&2; exit 2; }

# ---- 1. preflight ------------------------------------------------------------
# Fail with a named list rather than mid-run: $WORK/pathmin below deliberately
# stops inheriting the caller's toolchain, so "works in CI, missing timeout
# locally" has to surface here, before a phase is half-done.

# Everything the installer, the fakes and the two checks shell out to under the
# scrubbed PATH. `bash` and `env` are on it because every script here starts
# `#!/usr/bin/env bash`, and env resolves bash through PATH.
#
# `cmp` is on the list for the installer's sake, not this harness's: the render
# reconciliation (#37) compares a rendered temp against the destination before
# it decides to rewrite it, and $WORK/pathmin is built from exactly this list.
# A `cmp` the installer can reach here but not in pathmin would exit 127 under
# `set -e` -- a failure with no relation to what the assertion is about.
REQUIRED_TOOLS="bash env python3 curl grep sed head tail tr cat cmp cp mv rm mkdir chmod basename dirname mktemp"
# timeout/gtimeout: check-goose.sh:74-80 falls back to running unbounded, so a
# Mac without coreutils is fine. git: only assertion A14b needs it.
OPTIONAL_TOOLS="timeout gtimeout git"

MISSING=""
for tool in $REQUIRED_TOOLS; do
  command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
done
[ -z "$MISSING" ] || die "missing required tool(s):$MISSING"

# The version bootstrap-mac.sh asserts against, read WITHOUT a YAML parser so
# this harness does not need one of its own (the installer's python3 does).
PINS_VERSION="$(grep -E '^  version:' "$REPO_ROOT/config/pins.yaml" | tr -d ' "' | cut -d: -f2)"
[ -n "$PINS_VERSION" ] || die "could not read goose.version out of config/pins.yaml"

# ---- 2. the sandbox ----------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pai-install-test.XXXXXX")"
PROVIDER_PID=""
cleanup() {
  [ -n "$PROVIDER_PID" ] && kill "$PROVIDER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

FAKE_HOME="$WORK/home"
STATE="$WORK/brew-state"     # PERSISTS across phases; that persistence IS phase B
PREFIX="$WORK/prefix"
RECORD="$WORK/provider.jsonl"
PORT="${PORT:-4396}"
PROVIDER_URL="http://127.0.0.1:$PORT"
mkdir -p "$FAKE_HOME" "$STATE" "$PREFIX" "$WORK/out"

# UNSET FIRST, EXPORT SECOND. test-code-agent-manager.sh:504-508: "leaving them
# inherited would let the developer's real environment decide the outcome."
# Concretely, an inherited GOOSE_BIN points check-goose.sh at a REAL goose,
# which reads the just-installed provider JSONs carrying the real
# https://opencode.ai / https://api.together.xyz base_urls -- and this
# "no network, no keys" harness makes authenticated-looking requests to two
# production endpoints with the developer's own key.
#
# THE SAME HAZARD, VERBATIM, FOR OPENCODE_BIN. #38 shipped it as a documented
# env seam (check-opencode.sh's "Env seams (testing only)" block) and did not
# add it here, so a developer with `export OPENCODE_BIN=/opt/homebrew/bin/opencode`
# in their shell had this harness run the REAL opencode three times against
# $HOME=$FAKE_HOME, whose auth.json holds the fixture key -- an
# authenticated-looking request to opencode.ai. OPENCODE_BREW_PREFIX,
# FAKE_OPENCODE_VERSION and FAKE_PROVIDER_URL are the same class of seam; phase
# I happens to set all three at every call site today, so they are defence in
# depth rather than a live hole, and I9 is what keeps the NEXT one from being.
#
# A LIST IN A VARIABLE, not a bare `unset` argv, because I9 asserts against it.
# A lint that re-parsed this source text for a name list would be one more thing
# to get wrong; reading the same string the `unset` consumes cannot drift.
HARNESS_UNSET_NAMES="GOOSE_BIN PAI_MODE BRAIN_HOST OPENCODE_ZEN_API_KEY
  TOGETHER_API_KEY GOOSE_SERVER__SECRET_KEY ZEN_BASE TOGETHER_BASE PAI_EXEC
  FAKE_PROVIDER_MODE FAKE_PROVIDER_ZEN_KEY FAKE_PROVIDER_TOGETHER_KEY
  OPENCODE_BIN OPENCODE_BREW_PREFIX FAKE_OPENCODE_VERSION FAKE_PROVIDER_URL"
# shellcheck disable=SC2086
# ^ DELIBERATE word splitting: the variable holds NAMES, one per word, and
# `unset "$HARNESS_UNSET_NAMES"` would try to unset one variable whose name is
# the whole sentence -- a silent no-op that reopens exactly the hole above.
unset $HARNESS_UNSET_NAMES 2>/dev/null || true

# The fixture keys, in the spelling already committed at
# test-code-agent-manager.sh:217/219 (low entropy, established gitleaks
# precedent). Both checks die 2 on an empty key -- there is no SKIP path, by
# design -- so the harness cannot reach a single assertion without them.
ZEN_FIXTURE_KEY="fake-zen-key"
TOGETHER_FIXTURE_KEY="fake-together-key"
export OPENCODE_ZEN_API_KEY="$ZEN_FIXTURE_KEY"
export TOGETHER_API_KEY="$TOGETHER_FIXTURE_KEY"

# $HOME for everything below. bootstrap writes here and check-goose.sh:47 reads
# here, in two different processes -- that the two agree is half of what a green
# check-goose actually proves.
export HOME="$FAKE_HOME"

# -- $WORK/pathmin: a scrubbed PATH, built by name, NOT by appending the
# caller's. A Mac that has really run bootstrap has a real goose and a real brew
# in $PATH, and inheriting them would make the deny-PATH assertions fail for a
# reason that has nothing to do with the installer.
mkdir -p "$WORK/pathmin"
for tool in $REQUIRED_TOOLS $OPTIONAL_TOOLS; do
  resolved="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$resolved" ] && ln -sf "$resolved" "$WORK/pathmin/$tool"
done
# python3 gets the REAL interpreter, not whatever shim answered `command -v`:
# a pyenv/asdf shim is a shell script that re-resolves itself through the
# caller's PATH, which is the one thing pathmin has taken away.
PY_REAL="$(python3 -c 'import sys; print(sys.executable)')"
ln -sf "$PY_REAL" "$WORK/pathmin/python3"

# PyYAML, asserted against the python3 the INSTALLER will run (the one in
# pathmin), not against the caller's. See the header: without it both pin arms
# go untested and the harness stays green.
PATH="$WORK/pathmin" "$WORK/pathmin/python3" -c 'import yaml' >/dev/null 2>&1 ||
  die "python3 has no yaml module — install pyyaml (pip install pyyaml==6.0.2). unit_base_goose()'s pins comparison needs it, and without it the pins comparison silently does not run."

# -- $WORK/deny: one exit-127 shim per binary the installer could reach for.
# "${0##*/}" rather than basename: a shim that shells out to record a call is a
# shim that can fail to record when the PATH it is testing is the problem.
mkdir -p "$WORK/deny" "$WORK/deny-net"
DENY_NAMES="brew security launchctl systemctl apt-get softwareupdate xcode-select sudo uname curl uv goose"
for name in $DENY_NAMES; do
  cat >"$WORK/deny/$name" <<'EOF'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "$PAI_DENY_LOG"
exit 127
EOF
  chmod 755 "$WORK/deny/$name"
  # deny-net is the same wall with curl knocked out of it, for the check-goose
  # step only: there, curl is fake-goose.sh standing in for the HTTP a real
  # goose would do itself, so denying it would be denying the thing under test.
  # Everything else -- brew, uname, sudo, a second goose -- stays denied.
  [ "$name" = "curl" ] || cp "$WORK/deny/$name" "$WORK/deny-net/$name"
done

BOOT_PATH="$WORK/deny:$WORK/pathmin"
GOOSE_PATH="$PREFIX/bin:$WORK/deny-net:$WORK/pathmin"

# THE WALL HAS TO BE ABLE TO FIRE. A5/B4 assert an EMPTY log, and an empty log
# is also what a wall of non-executable files, a mis-set PAI_DENY_LOG or a PATH
# that never took effect produces -- the assertion would then be unfailable,
# which is the failure mode this whole harness exists to prevent. So the wall is
# tested against a call that is definitely denied, before anything depends on it.
DENY_SELFTEST="$WORK/deny-selftest.log"
: >"$DENY_SELFTEST"
DENY_RC=0
PATH="$BOOT_PATH" PAI_DENY_LOG="$DENY_SELFTEST" uname -s >/dev/null 2>&1 || DENY_RC=$?
[ "$DENY_RC" -eq 127 ] && [ -s "$DENY_SELFTEST" ] &&
  ok "deny-wall self-test: a denied binary exits 127 and lands in the log" ||
  bad "deny-wall self-test: the wall did not fire (rc=$DENY_RC) — A5/B4 below cannot fail and prove nothing"

run_bootstrap() {
  # run_bootstrap <out-file> <brew-log> <goose-version> <deny-log>; echoes rc.
  # Prefix assignments only: the harness's own environment stays clean, so a
  # later phase cannot inherit a variable an earlier one set.
  local rc=0
  # Create the brew log EMPTY first, exactly as the caller does for the deny
  # log. A bootstrap that dies before its first brew call (an unrouted `uname`
  # denied at exit 127, say) otherwise leaves no file at all, and the very next
  # assertion -- `A_LINE2="$(sed -n 2p "$A_BREW")"` -- is a failing command
  # substitution in an assignment, which `set -e` turns into a hard abort. The
  # harness would then exit 1 having never evaluated A5, the deny-PATH
  # INVARIANT, which is the one assertion that names that exact failure. An
  # empty log weakens nothing: the golden diff fails on it, and so does A2.
  : >"$2"
  # `</dev/null` — stdin is CLOSED, deliberately, and it is an assertion in the
  # shape of a redirection. The installer is a non-interactive program; the
  # moment it grows a `read -r -p` (#37's prompted values) an inherited
  # terminal would make this harness hang waiting for a human in CI, and an
  # inherited pipe would feed it whatever the caller happened to be piping.
  # With /dev/null the read returns EOF immediately, which is the same answer a
  # cron/CI run gets on a real Mac -- so the path under test is the one that
  # actually ships.
  PATH="$BOOT_PATH" \
  PAI_EXEC="$REPO_ROOT/scripts/verify/fake-exec.sh" \
  PAI_FAKE_ROOT="$WORK" \
  PAI_DENY_LOG="$4" \
  FAKE_BREW_LOG="$2" \
  FAKE_BREW_STATE="$STATE" \
  FAKE_BREW_PREFIX="$PREFIX" \
  FAKE_GOOSE_VERSION="$3" \
    "$REPO_ROOT/scripts/mac/bootstrap-mac.sh" >"$1" 2>&1 </dev/null || rc=$?
  echo "$rc"
}

run_bootstrap_flags() {
  # run_bootstrap_flags <tag> <home> [args...]; echoes rc. Combined stdout+stderr
  # lands in $WORK/out/<tag>.log, the brew log in $WORK/brew-<tag>.log.
  #
  # A TAG-SCOPED BREW STATE, PREFIX AND $HOME, never the shared ones phases
  # A/B/C use. Those persist on purpose (that persistence IS phase B), and a
  # selective run sharing them would take the idempotent path and install
  # nothing -- so every golden below would be measuring phase A's leftovers
  # instead of this run's flags, and would pass whatever the flags did.
  #
  # `"$@"` and not `$ARGS`: a string of flags word-split by the shell is how a
  # test starts passing vacuously (`--only coding-pack` arriving as one argument
  # is an unknown-id exit 2 that looks exactly like the assertion succeeding).
  local tag home rc=0
  tag="$1"; home="$2"; shift 2
  mkdir -p "$home" "$WORK/state-$tag" "$WORK/prefix-$tag"
  : >"$WORK/brew-$tag.log"
  : >"$WORK/deny-$tag.log"
  HOME="$home" \
  PATH="$BOOT_PATH" \
  PAI_EXEC="$REPO_ROOT/scripts/verify/fake-exec.sh" \
  PAI_FAKE_ROOT="$WORK" \
  PAI_DENY_LOG="$WORK/deny-$tag.log" \
  FAKE_BREW_LOG="$WORK/brew-$tag.log" \
  FAKE_BREW_STATE="$WORK/state-$tag" \
  FAKE_BREW_PREFIX="$WORK/prefix-$tag" \
  FAKE_GOOSE_VERSION="$PINS_VERSION" \
    "$REPO_ROOT/scripts/mac/bootstrap-mac.sh" "$@" >"$WORK/out/$tag.log" 2>&1 </dev/null || rc=$?
  echo "$rc"
}

count_in() {
  # count_in <file> <extended-regex> -- grep -c exits 1 on zero matches, which
  # under set -e would abort the run at the one moment the count matters.
  grep -cE "$2" "$1" 2>/dev/null || true
}

# ---- 3. phase A — fresh install ---------------------------------------------
echo "== phase A: fresh install =="
A_OUT="$WORK/out/a.log"; A_BREW="$WORK/brew-a.log"; A_DENY="$WORK/deny-a.log"
: >"$A_DENY"
A_RC="$(run_bootstrap "$A_OUT" "$A_BREW" "$PINS_VERSION" "$A_DENY")"
[ "$A_RC" = "0" ] && ok "phase A: bootstrap-mac.sh exited 0 against the fakes" || {
  bad "phase A: bootstrap-mac.sh exited $A_RC"
  evidence "$A_OUT"
}

# A1 — THE GOLDEN. Hand-written, in order, 16 lines. See the header for why it
# is typed out and not computed. Five formulae (5 probes + 5 installs), two
# casks (2 + 2), one `list --pinned` and one `pin` = 16. Not 17.
#
# RE-TYPED for the carve, and the reorder is the point rather than an accident:
# the install is five unit functions now, called in dependency order, so brew
# sees each unit's packages together instead of seeing every formula, then every
# cask, then the pin. toolchain (uv node jq + the tailscale cask), then goose
# (formula, cask, pin), then opencode. Same 16 lines, same work, different
# grouping — typed out again from the shapes the units emit, never derived from
# $FORMULAE_*, which would compare the code to itself.
cat >"$WORK/golden-a.txt" <<'EOF'
brew list --formula --versions uv
brew install uv
brew list --formula --versions node
brew install node
brew list --formula --versions jq
brew install jq
brew list --cask --versions tailscale
brew install --cask tailscale
brew list --formula --versions block-goose-cli
brew install block-goose-cli
brew list --cask --versions block-goose
brew install --cask block-goose
brew list --pinned
brew pin block-goose-cli
brew list --formula --versions opencode
brew install anomalyco/tap/opencode
EOF
if diff -u "$WORK/golden-a.txt" "$A_BREW" >"$WORK/golden-a.diff" 2>&1; then
  ok "A1: brew-a.log is byte-identical to the 16-line hand-written golden"
else
  bad "A1: brew-a.log does not match the golden (left = expected, right = actual)"
  evidence "$WORK/golden-a.diff"
fi

# A2 — the ONE ordering that is a fact about brew rather than a fact about this
# script: real brew refuses to pin a formula it has not installed, and the pin
# is a bare `pai_exec` call under `set -e`, so the wrong order is a hard failure
# on a real Mac. Asserted as index(install) < index(pin), NOT as two hardcoded
# line numbers: the absolute positions are A1's job, and pinning them here too
# meant that any reorder of the whole list reported as an install/pin inversion.
# Located by content, so a rename of either package fails this loudly (empty
# index) rather than silently comparing two absent lines.
A_INSTALL_AT="$(grep -nxF 'brew install block-goose-cli' "$A_BREW" | head -1 | cut -d: -f1 || true)"
A_PIN_AT="$(grep -nxF 'brew pin block-goose-cli' "$A_BREW" | head -1 | cut -d: -f1 || true)"
[ -n "$A_INSTALL_AT" ] && [ -n "$A_PIN_AT" ] && [ "$A_INSTALL_AT" -lt "$A_PIN_AT" ] &&
  ok "A2: block-goose-cli is installed (line $A_INSTALL_AT) before it is pinned (line $A_PIN_AT)" ||
  bad "A2: install/pin ordering drifted (install at line '${A_INSTALL_AT:-absent}', pin at line '${A_PIN_AT:-absent}')"

# A3 — brew put a goose on the system. Without this, every later goose assertion
# is testing a shim the harness materialised for itself.
[ -x "$PREFIX/bin/goose" ] &&
  ok "A3: bin/goose exists and is executable under the fake brew prefix" ||
  bad "A3: no executable bin/goose under the fake brew prefix after brew install block-goose-cli"

# A4 — the pins comparison RAN and matched. The failure mode this catches is not
# a mismatch, it is the "could not compare ... skipping" arm being taken and
# nobody noticing that routing `goose --version` bought nothing.
grep -qF "==> goose $PINS_VERSION matches config/pins.yaml" "$A_OUT" &&
  ok "A4: the pins comparison ran and matched ($PINS_VERSION)" || {
  bad "A4: no '==> goose $PINS_VERSION matches config/pins.yaml' line — the comparison did not run"
  evidence "$A_OUT"
}

# A5 — THE INVARIANT.
[ -s "$A_DENY" ] && {
  bad "A5: an external binary was invoked outside the seam during phase A"
  evidence "$A_DENY"
} || ok "A5: the deny-PATH log is empty — every foreign call went through PAI_EXEC"

# A6 — the config copy landed, byte for byte, from the templates it claims.
COPY_BAD=0; COPY_N=0
check_copy() {
  COPY_N=$((COPY_N + 1))
  cmp -s "$1" "$2" || { COPY_BAD=$((COPY_BAD + 1)); echo "      | differs: $2"; }
}
check_copy "$REPO_ROOT/config/goose/config.yaml" "$HOME/.config/goose/config.yaml"
for provider_json in "$REPO_ROOT"/config/goose/custom_providers/*.json; do
  check_copy "$provider_json" "$HOME/.config/goose/custom_providers/$(basename "$provider_json")"
done
check_copy "$REPO_ROOT/config/goose/goosehints.example" "$HOME/.config/goose/.goosehints"
check_copy "$REPO_ROOT/config/opencode/opencode.json" "$HOME/.config/opencode/opencode.json"
check_copy "$REPO_ROOT/config/opencode/AGENTS.md" "$HOME/.config/opencode/AGENTS.md"
[ "$COPY_BAD" -eq 0 ] && [ "$COPY_N" -ge 8 ] &&
  ok "A6: all $COPY_N config templates installed byte-identical to the repo copies" ||
  bad "A6: $COPY_BAD of $COPY_N config templates missing or altered"

# A7 — the atomic skill install. A leftover .personal-ai-tmp.* is a partial
# directory that the no-clobber rule would then keep forever.
SKILL_BAD=0; SKILL_N=0
for skill_dir in "$REPO_ROOT"/config/skills/*/; do
  [ -d "$skill_dir" ] || continue
  SKILL_N=$((SKILL_N + 1))
  [ -d "$HOME/.agents/skills/$(basename "$skill_dir")" ] || SKILL_BAD=$((SKILL_BAD + 1))
done
TMP_LEFT=0
for leftover in "$HOME/.agents/skills"/.personal-ai-tmp.*; do
  [ -e "$leftover" ] && TMP_LEFT=$((TMP_LEFT + 1))
done
[ "$SKILL_BAD" -eq 0 ] && [ "$SKILL_N" -gt 0 ] && [ "$TMP_LEFT" -eq 0 ] &&
  ok "A7: all $SKILL_N skills installed, no .personal-ai-tmp.* left behind" ||
  bad "A7: $SKILL_BAD of $SKILL_N skills missing, $TMP_LEFT partial temp dir(s) left"

# A8 — names the shape. The golden would also have caught it; this says which.
[ -s "$STATE/unhandled.log" ] && {
  bad "A8: fake-brew was handed a shape it does not model"
  evidence "$STATE/unhandled.log"
} || ok "A8: fake-brew saw no unmodelled argv (unhandled.log absent or empty)"

# A9 — THE DEFAULT IS STILL EVERYTHING. want() prints '==> skipping <id>' for
# every unit the flags left out, so a no-flag run printing even one of those
# lines means the selection surface changed what the plain install does. This
# assertion lives in phase A, unconditionally, because every leg runs phase A
# and the property it names ("no flags == the install this repo has always had")
# is the entire safety argument for the flag surface. A14b proves the same thing
# about the installed TREE; this is the cheap half that also runs on a shallow
# clone, where A14b degrades to a SKIP.
A9_SKIPS="$(count_in "$A_OUT" '^==> skipping ')"
[ "$A9_SKIPS" -eq 0 ] &&
  ok "A9: a no-flag run selected all five units (0 '==> skipping' lines)" || {
  bad "A9: a no-flag run skipped $A9_SKIPS unit(s) — the default selection is no longer everything"
  evidence "$A_OUT"
}

# ---- 4. phase B — the same install again ------------------------------------
if leg brew || leg routing; then
  echo
  echo "== phase B: immediate re-run, same state, same HOME =="
  # B3's sentinel goes in BEFORE the re-run and after A6 compared the file, so
  # this is a user's local edit in the only place bootstrap could destroy it.
  SENTINEL="# pai-install-test sentinel $$"
  # Guarded, and NOT with `mkdir -p`: if phase A never installed .goosehints
  # then B3 has nothing to test, and creating the file here would hand the
  # re-run a no-clobber target it must keep -- B3 would pass while proving
  # nothing. An unguarded `>>` into a missing directory is worse still: the
  # redirection fails and `set -e` kills the harness mid-phase, with no summary
  # and with B4 (the invariant) never evaluated.
  B3_READY=0
  if [ -f "$HOME/.config/goose/.goosehints" ]; then
    printf '%s\n' "$SENTINEL" >>"$HOME/.config/goose/.goosehints"
    B3_READY=1
  fi

  B_OUT="$WORK/out/b.log"; B_BREW="$WORK/brew-b.log"; B_DENY="$WORK/deny-b.log"
  : >"$B_DENY"
  B_RC="$(run_bootstrap "$B_OUT" "$B_BREW" "$PINS_VERSION" "$B_DENY")"
  [ "$B_RC" = "0" ] && ok "phase B: the re-run exited 0" || {
    bad "phase B: the re-run exited $B_RC"
    evidence "$B_OUT"
  }

  # B1 — eight probes, zero mutations. Also hand-written, and re-typed for the
  # carve in the same order as A1 (it is A1 with the mutations removed).
  cat >"$WORK/golden-b.txt" <<'EOF'
brew list --formula --versions uv
brew list --formula --versions node
brew list --formula --versions jq
brew list --cask --versions tailscale
brew list --formula --versions block-goose-cli
brew list --cask --versions block-goose
brew list --pinned
brew list --formula --versions opencode
EOF
  B_MUTATIONS="$(count_in "$B_BREW" ' (install|pin) ')"
  if diff -u "$WORK/golden-b.txt" "$B_BREW" >"$WORK/golden-b.diff" 2>&1 && [ "$B_MUTATIONS" -eq 0 ]; then
    ok "B1: the re-run is exactly the 8 probes, with 0 install/pin lines"
  else
    bad "B1: the installer is not idempotent ($B_MUTATIONS mutating line(s))"
    evidence "$WORK/golden-b.diff"
  fi

  # B2 — the probes' exit-status contract and `list --pinned`'s output FORMAT.
  # A `name 1.46.0` line would never match unit_base_goose()'s anchored
  # `grep -qx`, so the run would re-pin forever while B1 still passed.
  B_SKIPS="$(count_in "$B_OUT" 'already installed — skipping')"
  B_CASK_SKIPS="$(count_in "$B_OUT" '^==> cask .* already installed — skipping')"
  B_FORMULA_SKIPS=$((B_SKIPS - B_CASK_SKIPS))
  B_PINNED="$(count_in "$B_OUT" 'already pinned')"
  [ "$B_FORMULA_SKIPS" -eq 5 ] && [ "$B_CASK_SKIPS" -eq 2 ] && [ "$B_PINNED" -eq 1 ] &&
    ok "B2: 5 formula skips, 2 cask skips, 1 'already pinned'" ||
    bad "B2: skip lines drifted (formula=$B_FORMULA_SKIPS want 5, cask=$B_CASK_SKIPS want 2, pinned=$B_PINNED want 1)"

  # B3 — no-clobber. A user's edits must survive every re-run. A sentinel that
  # could not be planted (phase A installed no .goosehints) is a FAILURE, not a
  # pass: the file the no-clobber rule protects is not there to protect.
  [ "$B3_READY" -eq 1 ] && grep -qF "$SENTINEL" "$HOME/.config/goose/.goosehints" &&
    ok "B3: a local edit to ~/.config/goose/.goosehints survived the re-run" ||
    bad "B3: no-clobber unproven — ~/.config/goose/.goosehints was absent before the re-run (ready=$B3_READY) or the re-run clobbered it"

  # B4 — the invariant again, on the path where nothing is installed.
  [ -s "$B_DENY" ] && {
    bad "B4: an external binary was invoked outside the seam during phase B"
    evidence "$B_DENY"
  } || ok "B4: the deny-PATH log is still empty on the idempotent path"
fi

# ---- 5. phase C — the version the pins file does not name -------------------
if leg brew; then
  echo
  echo "== phase C: goose 9.9.9 against a pins file that says $PINS_VERSION =="
  C_OUT="$WORK/out/c.log"; C_DENY="$WORK/deny-c.log"
  : >"$C_DENY"
  C_RC="$(run_bootstrap "$C_OUT" "$WORK/brew-c.log" "9.9.9" "$C_DENY")"
  # C1 — the WARNING arm is otherwise dead code: nothing else in this repo has
  # ever reached the Mac/brain version-skew guard.
  grep -qF "WARNING: goose 9.9.9 is installed; config/pins.yaml says $PINS_VERSION" "$C_OUT" &&
    ok "C1: the pins WARNING arm fired for a mismatched goose version" || {
    bad "C1: no WARNING for goose 9.9.9 vs pins $PINS_VERSION (rc=$C_RC)"
    evidence "$C_OUT"
  }
fi

# ---- 6. phase F — the flag surface ------------------------------------------
# The refusals first, because a flag surface that installs the wrong thing on a
# bad command line is worse than one that installs nothing.
G_NOC_HOME=""
if leg select; then
  echo
  echo "== phase F: --with / --without / --only, and the ways they are refused =="

  # F1 — an unknown id must NAME the id. `sourdough` is not a substring of any
  # real unit id, so a grep for it cannot pass off a generic usage dump as the
  # specific complaint. Exit 2 alone would also be satisfied by the pre-existing
  # "unknown argument" arm, which is why the message is asserted too.
  F1_RC="$(run_bootstrap_flags f1 "$WORK/home-f1" --only sourdough)"
  [ "$F1_RC" = "2" ] && grep -qF "unknown unit id: sourdough" "$WORK/out/f1.log" &&
    ok "F1: an unknown unit id exits 2 and names the id" || {
    bad "F1: --only sourdough exited $F1_RC without naming the id"
    evidence "$WORK/out/f1.log"
  }

  # F2 — the same id requested and excluded in one command line. There is no
  # right precedence here, so the only honest answer is to refuse.
  F2_RC="$(run_bootstrap_flags f2 "$WORK/home-f2" --with opencode --without opencode)"
  [ "$F2_RC" = "2" ] && grep -qF "opencode is both requested and excluded" "$WORK/out/f2.log" &&
    ok "F2: --with X --without X exits 2 naming X" || {
    bad "F2: --with opencode --without opencode exited $F2_RC"
    evidence "$WORK/out/f2.log"
  }

  # F3 — DEPENDENCY ORDER SURVIVES AN EXCLUSION, and it survives LOUDLY. A unit
  # named on the command line is never dropped by --without's cascade, so this
  # command line resolves to "install coding-pack without OpenCode" — which is a
  # broken install that would otherwise exit 0 having written OpenCode agents
  # onto a machine with no OpenCode. Both ids must appear in the complaint: the
  # thing that cannot run, and the thing it needed.
  F3_RC="$(run_bootstrap_flags f3 "$WORK/home-f3" --only coding-pack --without opencode)"
  [ "$F3_RC" = "2" ] && grep -qF "coding-pack requires opencode" "$WORK/out/f3.log" &&
    [ ! -e "$WORK/home-f3/.agents" ] &&
    ok "F3: --only coding-pack --without opencode is refused (exit 2, names both, writes nothing)" || {
    bad "F3: a unit whose requirement was excluded was not refused (exit $F3_RC)"
    evidence "$WORK/out/f3.log"
  }

  # F4 — a flag that takes a value, given none. `--with` is the last argument,
  # so the arm that would read $2 under `set -u` is the arm being tested.
  F4_RC="$(run_bootstrap_flags f4 "$WORK/home-f4" --with)"
  # `--` before the pattern: it starts with two dashes, and grep would otherwise
  # read it as an option, print its own usage to stderr and exit 2. The `&&`
  # chain would then report the assertion as failed for a reason that has
  # nothing to do with the installer. (Measured: that is exactly how it failed.)
  [ "$F4_RC" = "2" ] && grep -qF -- "--with needs a unit id" "$WORK/out/f4.log" &&
    ok "F4: a value-taking flag with no value exits 2 rather than reading \$2 unset" || {
    bad "F4: --with with no value exited $F4_RC"
    evidence "$WORK/out/f4.log"
  }

  # F5/F6 — THE PAIR. --only X and --with X must not mean the same thing, and
  # the single observable that separates them is base-skills: it is in the
  # default set, it is NOT in coding-pack's requires closure, and it owns exactly
  # one file. So --only coding-pack must leave ~/.agents/skills/connect-service
  # absent and --with coding-pack must leave it present. An assertion that
  # passed for both would be testing neither.
  F5_RC="$(run_bootstrap_flags f5 "$WORK/home-f5" --only coding-pack)"
  F5_HOME="$WORK/home-f5"
  # THE BREW GOLDEN IS WHAT OBSERVES base-toolchain, and without it this
  # assertion did not cover the resolution its own failure message names. The
  # four filesystem probes below are all produced by base-goose, opencode and
  # coding-pack; base-toolchain installs no file into $HOME at all, so its
  # ONLY evidence is what it asked brew for. Measured, before this was added:
  # rewriting `requires_of`'s `base-goose)` arm to `printf '%s' ""` drops
  # base-toolchain out of this closure -- no uv, no node, no jq, no tailscale --
  # and F5 still passed, in a green 49/0 run.
  #
  # Hand-typed like A1 and G4, never derived from $FORMULAE_*. It is A1's list
  # exactly: base-skills is the one unit left out here and it asks brew for
  # nothing, so a four-unit closure and the five-unit default buy the same 16
  # lines. That coincidence is the reason the skip count below is asserted too.
  cat >"$WORK/golden-f5.txt" <<'EOF'
brew list --formula --versions uv
brew install uv
brew list --formula --versions node
brew install node
brew list --formula --versions jq
brew install jq
brew list --cask --versions tailscale
brew install --cask tailscale
brew list --formula --versions block-goose-cli
brew install block-goose-cli
brew list --cask --versions block-goose
brew install --cask block-goose
brew list --pinned
brew pin block-goose-cli
brew list --formula --versions opencode
brew install anomalyco/tap/opencode
EOF
  F5_SKIPS="$(count_in "$WORK/out/f5.log" '^==> skipping ')"
  F5_BREW_OK=0
  diff -u "$WORK/golden-f5.txt" "$WORK/brew-f5.log" >"$WORK/f5.diff" 2>&1 || F5_BREW_OK=1
  [ "$F5_RC" = "0" ] &&
    [ ! -e "$F5_HOME/.agents/skills/connect-service" ] &&
    [ -d "$F5_HOME/.agents/skills/ship" ] &&
    [ -f "$F5_HOME/.config/opencode/AGENTS.md" ] &&
    [ -f "$F5_HOME/.config/goose/config.yaml" ] &&
    [ "$F5_BREW_OK" -eq 0 ] &&
    [ "$F5_SKIPS" -eq 1 ] &&
    grep -qF "==> skipping base-skills" "$WORK/out/f5.log" &&
    ok "F5: --only coding-pack installs all four of its closure (16-line brew golden) and skips only base-skills" || {
    bad "F5: --only coding-pack did not resolve to exactly {base-toolchain, base-goose, opencode, coding-pack} (rc=$F5_RC, $F5_SKIPS skip line(s), brew golden rc=$F5_BREW_OK)"
    evidence "$WORK/f5.diff"
    evidence "$WORK/out/f5.log"
  }

  F6_RC="$(run_bootstrap_flags f6 "$WORK/home-f6" --with coding-pack)"
  F6_HOME="$WORK/home-f6"
  F6_SKIPS="$(count_in "$WORK/out/f6.log" '^==> skipping ')"
  [ "$F6_RC" = "0" ] &&
    [ -d "$F6_HOME/.agents/skills/connect-service" ] &&
    [ -d "$F6_HOME/.agents/skills/ship" ] &&
    [ "$F6_SKIPS" -eq 0 ] &&
    ok "F6: --with coding-pack ADDS to the default set — connect-service is installed, 0 skips" || {
    bad "F6: --with coding-pack did not keep the default set (rc=$F6_RC, $F6_SKIPS skip line(s))"
    evidence "$WORK/out/f6.log"
  }
fi

# ---- 7. phase G — --without opencode ----------------------------------------
# `leg goose` runs this too: G5 below asserts check-goose.sh against the $HOME
# this phase installs, and that assertion lives inside phase D's provider block.
if leg select || leg goose; then
  echo
  echo "== phase G: --without opencode =="
  G_FULL_HOME="$WORK/home-g-full"
  G_NOC_HOME="$WORK/home-g-noc"
  # A no-flag run into a FRESH home, as G3's reference. Not $FAKE_HOME: phase B
  # appends a sentinel to its .goosehints on purpose, so comparing against it
  # would fail for a reason that has nothing to do with --without.
  G_FULL_RC="$(run_bootstrap_flags g-full "$G_FULL_HOME")"
  G_NOC_RC="$(run_bootstrap_flags g-noc "$G_NOC_HOME" --without opencode)"

  [ "$G_FULL_RC" = "0" ] && [ "$G_NOC_RC" = "0" ] &&
    ok "phase G: both the reference run and --without opencode exited 0" || {
    bad "phase G: reference exited $G_FULL_RC, --without opencode exited $G_NOC_RC"
    evidence "$WORK/out/g-noc.log"
  }

  # G1 — AN ABSENCE, not an emptiness. ~/.config/opencode is created in exactly
  # one place (unit_opencode), and coding-pack creates only its agents/
  # subdirectory, so "opencode was not installed" is observable as the directory
  # not existing at all. An emptiness check would pass on a run that created the
  # directory and then failed to fill it.
  [ ! -e "$G_NOC_HOME/.config/opencode" ] &&
    ok "G1: ~/.config/opencode does not exist at all under --without opencode" ||
    bad "G1: ~/.config/opencode exists under --without opencode"

  # G2 — the cascade, observed on disk. coding-pack requires opencode, so
  # excluding opencode must also leave out its eleven skills; base-skills is
  # untouched, so exactly one entry is left. `find -mindepth 1 -maxdepth 1` and
  # not a `*` glob, so a leftover .personal-ai-tmp.* counts as the extra entry
  # it is instead of being invisible to pathname expansion.
  G2_LIST="$(find "$G_NOC_HOME/.agents/skills" -mindepth 1 -maxdepth 1 2>/dev/null |
    sed 's|.*/||' | sort | tr '\n' ' ' | sed 's/ *$//')"
  [ "$G2_LIST" = "connect-service" ] &&
    ok "G2: ~/.agents/skills holds exactly one entry, connect-service" ||
    bad "G2: ~/.agents/skills does not hold exactly connect-service"

  # G2b — the cascade, announced. A selective install that silently drops a unit
  # the user did not name is the failure mode this whole phase exists for.
  grep -qF "==> --without opencode also drops: coding-pack" "$WORK/out/g-noc.log" &&
    ok "G2b: the run announced that --without opencode also dropped coding-pack" || {
    bad "G2b: the cascade was not announced"
    evidence "$WORK/out/g-noc.log"
  }

  # G3 — everything base-goose owns is BYTE-IDENTICAL to the full install's. The
  # units are supposed to be independent; this is what makes that a measurement
  # rather than a layout claim. It also covers the four provider JSONs and the
  # .goosehints, which no other assertion in this phase looks at.
  if diff -r "$G_FULL_HOME/.config/goose" "$G_NOC_HOME/.config/goose" >"$WORK/g3.diff" 2>&1; then
    ok "G3: the ~/.config/goose subtree is byte-identical to the no-flag install's"
  else
    bad "G3: excluding opencode changed what base-goose installed"
    evidence "$WORK/g3.diff"
  fi

  # G4 — the brew golden for a three-unit install, hand-typed like A1 and B1 and
  # for the same reason: derived from FORMULAE_* it could not fail. It is A1
  # minus the two opencode lines, which is the whole claim.
  cat >"$WORK/golden-g.txt" <<'EOF'
brew list --formula --versions uv
brew install uv
brew list --formula --versions node
brew install node
brew list --formula --versions jq
brew install jq
brew list --cask --versions tailscale
brew install --cask tailscale
brew list --formula --versions block-goose-cli
brew install block-goose-cli
brew list --cask --versions block-goose
brew install --cask block-goose
brew list --pinned
brew pin block-goose-cli
EOF
  if diff -u "$WORK/golden-g.txt" "$WORK/brew-g-noc.log" >"$WORK/golden-g.diff" 2>&1; then
    ok "G4: --without opencode emits exactly the 14-line golden, with no opencode line"
  else
    bad "G4: the --without opencode brew log is not the 14-line golden"
    evidence "$WORK/golden-g.diff"
  fi

  # G6 — THE EPILOGUE IS SELECTION-AWARE, BOTH OF ITS OPENCODE LINES. #37 split
  # the next-steps screen into heredocs so the /connect step could be omitted;
  # #38 replaced that step with the credential paragraph and added a third
  # verify line, `check-opencode.sh`. Both are OpenCode-specific, so both are
  # inside `if in_set opencode "$SELECTED"` now, and this is the row that says
  # so. It is asserted as a PAIR and against the reference run: "the noc log
  # does not mention opencode-auth.sh" passes just as well on a truncated log,
  # or on a run that printed no epilogue at all, which is why the same two
  # strings must be PRESENT in $G_FULL_HOME's transcript.
  G6_NOC=0
  G6_FULL=0
  grep -qF "opencode-auth.sh" "$WORK/out/g-noc.log" ||
    grep -qF "check-opencode.sh" "$WORK/out/g-noc.log" || G6_NOC=1
  grep -qF "opencode-auth.sh" "$WORK/out/g-full.log" &&
    grep -qF "check-opencode.sh" "$WORK/out/g-full.log" && G6_FULL=1
  [ "$G6_NOC" -eq 1 ] && [ "$G6_FULL" -eq 1 ] &&
    ok "G6: the next-steps screen offers opencode-auth.sh and check-opencode.sh only when opencode was installed" || {
    bad "G6: the epilogue is not selection-aware (noc clean=$G6_NOC, reference mentions both=$G6_FULL)"
    evidence "$WORK/out/g-noc.log"
  }
fi

# ---- 8. phase H — --dry-run -------------------------------------------------
if leg select; then
  echo
  echo "== phase H: --dry-run touches nothing =="
  H_HOME="$WORK/home-dry"
  H_RC="$(run_bootstrap_flags h "$H_HOME" --dry-run)"

  # H1 — THE WHOLE DEFAULT DRY RUN, hand-typed. Thirty-three lines: the plan
  # header, the five units in dependency order, the `would install` banner, and
  # all 26 items the five units own. Typed out of config/units/*.yaml's `owns`
  # blocks in manifest order, NEVER pasted from a run of the script — the same
  # rule as A1 and G4, for the same reason (an expectation derived from the code
  # under test compares the code to itself and can never fail).
  #
  # It grew a line with #38: ~/.local/share/opencode/auth.json, opencode.yaml's
  # fifth `owns` entry, between opencode.json and connect-service. RE-TYPED out
  # of the manifest by hand, in the manifest's order, exactly as the rule above
  # requires — the temptation on a rebase is to paste the new run's output and
  # call the golden updated, which converts this assertion into a tautology.
  #
  # It is the whole file and not `head -N`. This assertion USED to clip to six
  # lines, which meant the banner and every owns line were compared to nothing:
  # `owns_of`'s `opencode)` arm could be rewritten to print `$OWNS_BASE_SKILLS`
  # -- dropping the opencode formula and printing connect-service twice -- with
  # the whole harness green. Measured, before this was widened: 49 passed.
  #
  # This is also the ONLY assertion anywhere that sees opencode's and
  # coding-pack's owns lines. H4 pins a whole log too, but for
  # `--dry-run --without opencode`, whose plan excludes both by construction.
  #
  # Kebab-cased and indented, both deliberately: a column-0 unit_*() name
  # printed here would be counted as a call site by units_lint.py's P3. And
  # there is no `==> personal-ai Mac bootstrap` banner above the plan --
  # --dry-run answers before the platform guard, so nothing precedes it.
  cat >"$WORK/golden-h.txt" <<'EOF'
==> plan (5 units, in dependency order):
  base-toolchain
  base-goose
  opencode
  base-skills
  coding-pack
==> would install:
  brew formula  uv
  brew formula  node
  brew formula  jq
  brew cask     tailscale
  brew formula  block-goose-cli
  brew cask     block-goose
  file          ~/.config/goose/config.yaml
  file          ~/.config/goose/custom_providers
  file          ~/.config/goose/.goosehints
  brew formula  anomalyco/tap/opencode
  file          ~/.config/opencode/opencode.json
  file          ~/.local/share/opencode/auth.json
  file          ~/.agents/skills/connect-service
  file          ~/.agents/skills/ci-lint-test
  file          ~/.agents/skills/clean-plan
  file          ~/.agents/skills/code-review
  file          ~/.agents/skills/deep-research
  file          ~/.agents/skills/looping-code-review
  file          ~/.agents/skills/looping-plan-review
  file          ~/.agents/skills/mr-review
  file          ~/.agents/skills/plan-review
  file          ~/.agents/skills/pre-mr-checklist
  file          ~/.agents/skills/refactor-planner
  file          ~/.agents/skills/ship
  file          ~/.config/opencode/agents
  file          ~/.config/opencode/AGENTS.md
EOF
  if [ "$H_RC" = "0" ] && diff -u "$WORK/golden-h.txt" "$WORK/out/h.log" >"$WORK/h1.diff" 2>&1; then
    ok "H1: --dry-run prints exactly the 33-line five-unit plan and its 26 owned items"
  else
    bad "H1: the default --dry-run output is not the 33-line golden (rc=$H_RC)"
    evidence "$WORK/h1.diff"
  fi

  # H2 — A FRESH $HOME IS STILL EMPTY. mkdir/cp/mv do not go through the seam
  # (bootstrap-mac.sh:26-28 — a fake $HOME substitutes for all of them), so this
  # count is the only thing that can catch a mutating helper that grew a
  # DRY_RUN branch it does not honour.
  H2_FILES="$(find "$H_HOME" -mindepth 1 | wc -l | tr -d ' ')"
  [ "$H2_FILES" -eq 0 ] &&
    ok "H2: --dry-run into a fresh \$HOME left it completely empty" ||
    bad "H2: --dry-run wrote $H2_FILES entries into a fresh \$HOME"

  # H2b — AND AN EXISTING $HOME IS BYTE-IDENTICAL AFTERWARDS. H2 alone is
  # satisfiable by a --dry-run that only ever writes into paths that already
  # exist: every copy_no_clobber destination in this installer is under
  # ~/.config, which on a fresh home is absent and on a real Mac is not. So the
  # populated case is the one that matters, and it is asserted as `diff -r`
  # against a snapshot taken immediately before the run rather than as "no
  # error". The snapshot is a copy of phase A's install: 61 files, every
  # template, every skill, every agent.
  H_POP="$WORK/home-dry-pop"
  H_REF="$WORK/home-dry-ref"
  rm -rf "$H_POP" "$H_REF"
  cp -R "$FAKE_HOME" "$H_POP"
  cp -R "$FAKE_HOME" "$H_REF"
  H2B_BEFORE="$(find "$H_REF" -type f | wc -l | tr -d ' ')"
  H2B_RC="$(run_bootstrap_flags h-pop "$H_POP" --dry-run)"
  if [ "$H2B_RC" = "0" ] && [ "$H2B_BEFORE" -ge 61 ] &&
     diff -r "$H_REF" "$H_POP" >"$WORK/h2b.diff" 2>&1; then
    ok "H2b: --dry-run over a populated \$HOME ($H2B_BEFORE files) left every byte where it was"
  else
    bad "H2b: --dry-run modified a populated \$HOME (rc=$H2B_RC, files=$H2B_BEFORE want >=61)"
    evidence "$WORK/h2b.diff"
  fi

  # H3 — NO TOOLCHAIN CALL, AND NO `uname`. The plan is pure computation over
  # the unit table, so --dry-run answers before the platform guard and before
  # the Homebrew guard: an empty deny log proves nothing on the wall was
  # reached, and an empty brew log proves the seam itself was never used.
  # Together they are what makes `bootstrap-mac.sh --dry-run` honest on a Mac
  # with no Homebrew, and on a Linux box.
  #
  # NOT "no external call at all", which is what this used to claim and which is
  # false: `dirname` at bootstrap-mac.sh:107 forks before the dry-run exit, and
  # neither log can see it. What these two logs cover is the operative claim --
  # nothing from $DENY_NAMES (brew, uname, uv, goose, sudo, curl, ...) and
  # nothing through the seam. `dirname` is a pure string function of
  # $BASH_SOURCE that every POSIX userland has; that it is a fork rather than a
  # builtin is not a dependency on the machine's state.
  H3_DENY="$(count_in "$WORK/deny-h.log" '.')"
  H3_BREW="$(count_in "$WORK/brew-h.log" '.')"
  [ "$H3_DENY" -eq 0 ] && [ "$H3_BREW" -eq 0 ] &&
    ok "H3: --dry-run reached for no toolchain binary and never asked what OS this is (deny log and brew log both empty)" || {
    bad "H3: --dry-run reached outside itself ($H3_DENY denied call(s), $H3_BREW brew call(s))"
    evidence "$WORK/deny-h.log"
  }

  # H4 — the whole output for a cascading exclusion, hand-typed. Sixteen lines
  # that pin, in one artifact: the cascade announcement, the three-unit plan, its
  # order, and — by their absence — that not one opencode or coding-pack path is
  # offered. A "no opencode line" grep would pass on an empty file.
  H4_RC="$(run_bootstrap_flags h-noc "$WORK/home-dry-noc" --dry-run --without opencode)"
  cat >"$WORK/golden-h4.txt" <<'EOF'
==> --without opencode also drops: coding-pack
==> plan (3 units, in dependency order):
  base-toolchain
  base-goose
  base-skills
==> would install:
  brew formula  uv
  brew formula  node
  brew formula  jq
  brew cask     tailscale
  brew formula  block-goose-cli
  brew cask     block-goose
  file          ~/.config/goose/config.yaml
  file          ~/.config/goose/custom_providers
  file          ~/.config/goose/.goosehints
  file          ~/.agents/skills/connect-service
EOF
  if [ "$H4_RC" = "0" ] &&
     diff -u "$WORK/golden-h4.txt" "$WORK/out/h-noc.log" >"$WORK/h4.diff" 2>&1; then
    ok "H4: --dry-run --without opencode prints exactly the 16-line three-unit plan"
  else
    bad "H4: the cascading dry-run plan is not the 16-line golden (rc=$H4_RC)"
    evidence "$WORK/h4.diff"
  fi
fi

# ---- 9. phase D — the checks the installer tells you to run -----------------
if leg goose || leg providers; then
  echo
  echo "== phase D: check-providers.sh and check-goose.sh against fake-provider.py =="
  : >"$RECORD"
  "$HERE/fake-provider.py" --port "$PORT" --out "$RECORD" >"$WORK/out/provider.log" 2>&1 &
  PROVIDER_PID=$!

  # Readiness by polling a REAL route with the key we expect: there is no
  # /__ready, on purpose, so this poll also proves the auth wiring is live
  # before a check runs. The poll rows land in the record like any other, which
  # is why every assertion below counts rows ADDED since a mark.
  READY=0
  for _ in $(seq 1 100); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $ZEN_FIXTURE_KEY" \
      "$PROVIDER_URL/zen/v1/models" 2>/dev/null || echo 000)"
    [ "$code" = "200" ] && { READY=1; break; }
    sleep 0.1
  done
  [ "$READY" -eq 1 ] || {
    evidence "$WORK/out/provider.log"
    die "fake-provider.py never answered 200 on $PROVIDER_URL/zen/v1/models (port $PORT busy?)"
  }

  row_count() { grep -c . "$RECORD" 2>/dev/null || true; }
  rows_since() {
    # One canonical line per recorded request. `model` is null for a catalog
    # GET; print it as `-` so the expectation stays greppable by eye.
    "$WORK/pathmin/python3" -c '
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
for r in rows[int(sys.argv[2]):]:
    print(r["mount"], r["method"], r["path"], r["auth_scheme"],
          str(r["key_matched"]).lower(), r["model"] or "-", r["status"])
' "$RECORD" "$1"
  }

  if leg providers; then
    MARK="$(row_count)"
    P_OUT="$WORK/out/providers.log"; P_RC=0
    PATH="$WORK/pathmin" \
    ZEN_BASE="$PROVIDER_URL/zen/v1" \
    TOGETHER_BASE="$PROVIDER_URL/together/v1" \
      "$HERE/check-providers.sh" >"$P_OUT" 2>&1 || P_RC=$?

    # D1 — AC1, half of it.
    [ "$P_RC" -eq 0 ] && grep -qF "== summary: 5 passed, 0 failed ==" "$P_OUT" &&
      ok "D1: check-providers.sh exited 0 with '5 passed, 0 failed'" || {
      bad "D1: check-providers.sh exited $P_RC without a clean summary"
      evidence "$P_OUT"
    }

    # D2 — the documented uncertainty, settled. A blind-200 shim prints this
    # same line, which is exactly why D3 exists next to it.
    grep -qF "RESULT: Zen /messages accepts -> Authorization: Bearer AND x-api-key" "$P_OUT" &&
      ok "D2: /messages was reached under BOTH auth schemes" ||
      bad "D2: the Bearer-AND-x-api-key RESULT line is missing"

    # D3 — the wire itself. The exit code and the summary are both satisfiable
    # without a single correct request; these six rows are not.
    cat >"$WORK/expect-d3.txt" <<'EOF'
zen GET /zen/v1/models bearer true - 200
zen POST /zen/v1/chat/completions bearer true minimax-m2.7 200
zen POST /zen/v1/messages bearer true claude-haiku-4-5 200
zen POST /zen/v1/messages x-api-key true claude-haiku-4-5 200
together GET /together/v1/models bearer true - 200
together POST /together/v1/chat/completions bearer true openai/gpt-oss-120b 200
EOF
    rows_since "$MARK" >"$WORK/actual-d3.txt" || true
    if diff -u "$WORK/expect-d3.txt" "$WORK/actual-d3.txt" >"$WORK/d3.diff" 2>&1; then
      ok "D3: exactly the 6 expected requests reached the provider, in order, all key-matched"
    else
      bad "D3: the requests check-providers.sh made are not the ones its source implies"
      evidence "$WORK/d3.diff"
    fi
  fi

  if leg goose; then
    MARK="$(row_count)"
    G_OUT="$WORK/out/goose.log"; G_RC=0; G_DENY="$WORK/deny-d.log"
    : >"$G_DENY"
    PATH="$GOOSE_PATH" \
    PAI_DENY_LOG="$G_DENY" \
    FAKE_PROVIDER_URL="$PROVIDER_URL" \
    FAKE_GOOSE_VERSION="$PINS_VERSION" \
      "$HERE/check-goose.sh" >"$G_OUT" 2>&1 || G_RC=$?

    # D4 — AC1, the other half. check-goose.sh:124-129 scores a clean-exit,
    # silent run as "PASS (odd output)" and lib.sh:87-89 counts it green, so the
    # exit code alone certifies a `true` binary. The recap rows must be exactly
    # PASS, for all three providers.
    D4_ODD="$(count_in "$G_OUT" 'PASS \(odd output\)')"
    D4_ROWS=0
    grep -qE '^ +zen-openai +minimax-m2\.7 +PASS$' "$G_OUT" && D4_ROWS=$((D4_ROWS + 1))
    grep -qE '^ +zen-anthropic +claude-haiku-4-5 +PASS$' "$G_OUT" && D4_ROWS=$((D4_ROWS + 1))
    grep -qE '^ +together +openai/gpt-oss-120b +PASS$' "$G_OUT" && D4_ROWS=$((D4_ROWS + 1))
    [ "$G_RC" -eq 0 ] && [ "$D4_ROWS" -eq 3 ] && [ "$D4_ODD" -eq 0 ] &&
      ok "D4: check-goose.sh exited 0 with 3 recap rows of exactly PASS (0 'odd output')" || {
      bad "D4: check-goose exited $G_RC with $D4_ROWS/3 clean PASS rows and $D4_ODD 'odd output' row(s)"
      evidence "$G_OUT"
    }

    # D5 — goose actually reached a provider, over the URLs the INSTALLED
    # base_urls plus goose's engine rule produce. x-api-key on /messages is the
    # anthropic engine's convention, and it is what makes zen-anthropic's bare
    # base_url a tested claim rather than a documented one.
    cat >"$WORK/expect-d5.txt" <<'EOF'
zen POST /zen/v1/chat/completions bearer true minimax-m2.7 200
zen POST /zen/v1/messages x-api-key true claude-haiku-4-5 200
together POST /together/v1/chat/completions bearer true openai/gpt-oss-120b 200
EOF
    rows_since "$MARK" >"$WORK/actual-d5.txt" || true
    if diff -u "$WORK/expect-d5.txt" "$WORK/actual-d5.txt" >"$WORK/d5.diff" 2>&1; then
      ok "D5: goose made exactly the 3 expected provider requests"
    else
      bad "D5: goose did not reach the providers the installed config implies"
      evidence "$WORK/d5.diff"
    fi

    # D6 — resolve_goose_bin walked PATH into the sandbox. An ambient goose here
    # means the harness was testing the machine rather than the install.
    G_BIN="$(PATH="$GOOSE_PATH" bash -c '. "$1"; resolve_goose_bin --required' _ "$HERE/lib.sh" 2>/dev/null || true)"
    case "$G_BIN" in
      "$WORK"/*) ok "D6: resolve_goose_bin returned the sandbox goose, not an ambient one" ;;
      *) bad "D6: resolve_goose_bin returned a goose outside the sandbox" ;;
    esac

    [ -s "$G_DENY" ] && {
      bad "D-deny: check-goose reached a denied binary (curl excepted — it stands in for goose's own HTTP)"
      evidence "$G_DENY"
    } || ok "D-deny: check-goose invoked nothing from the deny wall"

    # G5 (AC2's second half) — check-goose.sh still passes against the $HOME
    # phase G installed WITHOUT OpenCode. It lives here rather than in phase G
    # because it needs the provider fake this block starts, and it runs after D5
    # because D5 diffs the rows recorded since its own mark — these requests are
    # additional ones and would fail that diff if they arrived first.
    #
    # It is not implied by G3. G3 says the goose subtree is byte-identical;
    # this says the goose those bytes configure actually reaches all three
    # providers on a machine where OpenCode was never installed.
    if [ -n "$G_NOC_HOME" ] && [ -d "$G_NOC_HOME/.config/goose" ]; then
      G5_OUT="$WORK/out/g5.log"; G5_RC=0
      HOME="$G_NOC_HOME" \
      PATH="$GOOSE_PATH" \
      PAI_DENY_LOG="$WORK/deny-g5.log" \
      FAKE_PROVIDER_URL="$PROVIDER_URL" \
      FAKE_GOOSE_VERSION="$PINS_VERSION" \
        "$HERE/check-goose.sh" >"$G5_OUT" 2>&1 || G5_RC=$?
      G5_ROWS=0
      grep -qE '^ +zen-openai +minimax-m2\.7 +PASS$' "$G5_OUT" && G5_ROWS=$((G5_ROWS + 1))
      grep -qE '^ +zen-anthropic +claude-haiku-4-5 +PASS$' "$G5_OUT" && G5_ROWS=$((G5_ROWS + 1))
      grep -qE '^ +together +openai/gpt-oss-120b +PASS$' "$G5_OUT" && G5_ROWS=$((G5_ROWS + 1))
      [ "$G5_RC" -eq 0 ] && [ "$G5_ROWS" -eq 3 ] &&
        ok "G5: check-goose.sh exits 0 with 3 clean PASS rows against the --without opencode \$HOME" || {
        bad "G5: check-goose exited $G5_RC with $G5_ROWS/3 PASS rows against the opencode-less \$HOME"
        evidence "$G5_OUT"
      }
    else
      bad "G5: phase G did not leave an opencode-less \$HOME to check (G_NOC_HOME='${G_NOC_HOME:-unset}')"
    fi
  fi

  kill "$PROVIDER_PID" 2>/dev/null || true
  wait "$PROVIDER_PID" 2>/dev/null || true
  PROVIDER_PID=""
fi

# ---- 10. phase E — the defaults, with zero packets ---------------------------
if leg providers; then
  echo
  echo "== phase E: ZEN_BASE/TOGETHER_BASE unset still address the real hosts =="
  mkdir -p "$WORK/curlshim"
  CURL_RECORD="$WORK/curl-urls.txt"
  : >"$CURL_RECORD"
  # RECORD ONLY URL-SHAPED ARGUMENTS. Measured with the naive record-all-argv
  # version: it wrote the key into the log four times, because check-providers
  # cannot run without keys and four of its argv elements are
  # `Authorization: Bearer <key>` / `x-api-key: <key>`.
  cat >"$WORK/curlshim/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in http*) printf '%s\n' "$a" >>"$CURL_RECORD" ;; esac
done
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && printf '{}' > "$a"
  prev="$a"
done
printf '200'
EOF
  chmod 755 "$WORK/curlshim/curl"

  # E1 — argv(unset) == argv(before), made mechanical. Grepping the source for
  # the ":-https://..." literal would be a tautology that cannot tell a honoured
  # default from one shadowed by an exported empty string.
  cat >"$WORK/expect-e1.txt" <<'EOF'
https://opencode.ai/zen/v1/models
https://opencode.ai/zen/v1/chat/completions
https://opencode.ai/zen/v1/messages
https://opencode.ai/zen/v1/messages
https://api.together.xyz/v1/models
https://api.together.xyz/v1/chat/completions
EOF

  # TWO probes, not one, and the second is the one with teeth. Unset, `${V-d}`
  # and `${V:-d}` are indistinguishable, so a probe with both names unset cannot
  # fail the way E1's negative control says it must. EXPORTED EMPTY is where the
  # two spellings part: `${ZEN_BASE-https://...}` keeps the empty string and
  # collapses "$ZEN_BASE/models" into the relative "/models" -- which the shim
  # does not even record, because it is not http-shaped. An empty ZEN_BASE in
  # the environment is also exactly what a developer who once exported it for a
  # CI-style run has, so this is a real state and not a contrived one.
  probe_defaults() {
    # probe_defaults <record-file> <out-file> <unset|empty>; echoes rc.
    local rc=0
    : >"$1"
    if [ "$3" = "empty" ]; then
      PATH="$WORK/curlshim:$WORK/pathmin" CURL_RECORD="$1" \
      ZEN_BASE="" TOGETHER_BASE="" \
        "$HERE/check-providers.sh" >"$2" 2>&1 || rc=$?
    else
      # env -u is belt and braces: neither name is exported anywhere in this
      # file (phase D sets them as prefix assignments), and this says so aloud.
      PATH="$WORK/curlshim:$WORK/pathmin" CURL_RECORD="$1" \
        env -u ZEN_BASE -u TOGETHER_BASE "$HERE/check-providers.sh" >"$2" 2>&1 || rc=$?
    fi
    echo "$rc"
  }

  E_RC="$(probe_defaults "$CURL_RECORD" "$WORK/out/e-unset.log" unset)"
  E_EMPTY_RECORD="$WORK/curl-urls-empty.txt"
  E_EMPTY_RC="$(probe_defaults "$E_EMPTY_RECORD" "$WORK/out/e-empty.log" empty)"

  if diff -u "$WORK/expect-e1.txt" "$CURL_RECORD" >"$WORK/e1.diff" 2>&1; then
    ok "E1: with both bases unset, curl was handed the 6 real HTTPS URLs, in order (rc=$E_RC)"
  else
    bad "E1: the default endpoints changed when ZEN_BASE/TOGETHER_BASE went overridable"
    evidence "$WORK/e1.diff"
  fi

  if diff -u "$WORK/expect-e1.txt" "$E_EMPTY_RECORD" >"$WORK/e1-empty.diff" 2>&1; then
    ok "E1b: an exported-EMPTY base still resolves to the real URLs (\`:-\`, not \`-\`) (rc=$E_EMPTY_RC)"
  else
    bad "E1b: an exported-empty base shadows the default — the override is spelled \`-\` where it must be \`:-\`"
    evidence "$WORK/e1-empty.diff"
  fi

  # E2 — the proof shim must not be the leak, in EITHER probe. This asserts on a
  # boolean; it never prints the offending line, because the offending line is
  # the key. (Measured failure mode: a record-every-argv shim writes the key
  # four times, one per key-bearing auth header.)
  E2_HITS="$(count_in "$CURL_RECORD" "$ZEN_FIXTURE_KEY|$TOGETHER_FIXTURE_KEY")"
  E2_HITS=$((E2_HITS + $(count_in "$E_EMPTY_RECORD" "$ZEN_FIXTURE_KEY|$TOGETHER_FIXTURE_KEY")))
  [ "$E2_HITS" -eq 0 ] &&
    ok "E2: neither curl record contains a credential-shaped line" ||
    bad "E2: the recording shim leaked a credential into its log ($E2_HITS line(s)) — not printed here"
fi

# ---- 11. structural — the seam itself ----------------------------------------
if leg routing; then
  echo
  echo "== structural: the seam, the pre-carve differential, the gate, the interlock =="

  # A14a (AC4) — THE SEAM IS EXACTLY THESE 17 LINES, and nothing outside them
  # reads $PAI_EXEC.
  #
  # This REPLACES the older A14, which sed-unwound the seam and diffed the whole
  # file against the pre-seam blob from git history. That assertion could only
  # hold while bootstrap-mac.sh's executable text stayed frozen at its pre-seam
  # shape, and #37 changes that text on purpose (the shared brew/skill helpers,
  # then the carve into unit functions). An unwind cannot reproduce text that no
  # longer exists. So the two things A14 was really proving are now asserted
  # separately, and each one more directly than the diff did:
  #
  #   A14a (here)   the seam is this block verbatim, and no second, undocumented
  #                 substitution point has appeared next to it
  #   A14b (below)  the pre-carve installer and this one write the SAME tree
  #                 into a fake $HOME -- the behaviour the whole-file diff was
  #                 only ever a proxy for, asserted on output instead of source
  #
  # Comments and blank lines go first: a comment cannot change what a Mac does,
  # and both #37 and the seam before it add paragraphs of them.
  strip_noise() { grep -vE '^[[:space:]]*(#|$)' "$1"; }

  # The seam, typed out from the spec rather than cut from the file it checks,
  # so a future edit to the helpers or to the containment gate has to be
  # re-justified HERE rather than absorbed silently.
  cat >"$WORK/seam-block.txt" <<'EOF'
pai_exec() { ${PAI_EXEC:+"$PAI_EXEC"} "$@"; }
pai_have() {
  if [ -n "${PAI_EXEC:-}" ]; then
    pai_exec have "$1"
  else
    command -v "$1" >/dev/null 2>&1
  fi
}
if [ -n "${PAI_EXEC:-}" ]; then
  case "$PAI_EXEC" in
    "$REPO_ROOT"/scripts/verify/*) ;;
    *) echo "bootstrap-mac.sh: PAI_EXEC must be a file under $REPO_ROOT/scripts/verify/" >&2
       exit 2 ;;
  esac
  [ -x "$PAI_EXEC" ] || {
    echo "bootstrap-mac.sh: PAI_EXEC is set but not executable: $PAI_EXEC" >&2
    exit 2
  }
fi
EOF
  strip_noise "$REPO_ROOT/scripts/mac/bootstrap-mac.sh" >"$WORK/patched-code.txt"

  # Cut the seam block out as a contiguous run (python3, because a line-wise
  # `grep -v` would also delete the `fi`, `}` and `exit 2` lines that belong to
  # the rest of the script).
  A14_CUT=0
  "$WORK/pathmin/python3" -c '
import sys
code = open(sys.argv[1]).read().splitlines()
seam = open(sys.argv[2]).read().splitlines()
try:
    i = code.index(seam[0])
except ValueError:
    sys.exit(1)
if code[i:i + len(seam)] != seam:
    sys.exit(1)
del code[i:i + len(seam)]
open(sys.argv[3], "w").write("\n".join(code) + "\n")
' "$WORK/patched-code.txt" "$WORK/seam-block.txt" "$WORK/unseamed.txt" || A14_CUT=1

  if [ "$A14_CUT" -ne 0 ]; then
    bad "A14a: the seam in bootstrap-mac.sh is not the block this harness was written against"
  else
    # `pai_exec`/`pai_have` CALLS are expected all through what is left -- that
    # is the seam being used. A bare $PAI_EXEC out there is a different thing:
    # a second dispatcher, or a guard that decides for itself what "under test"
    # means, either of which the containment gate above would never see.
    A14_RESIDUE="$(count_in "$WORK/unseamed.txt" 'PAI_EXEC')"
    { grep -nE 'PAI_EXEC' "$WORK/unseamed.txt" || true; } >"$WORK/a14a-residue.txt"
    [ "$A14_RESIDUE" -eq 0 ] &&
      ok "A14a: the seam is exactly the 17 lines this harness names, and PAI_EXEC is read nowhere else" || {
      bad "A14a: PAI_EXEC is read outside the seam block ($A14_RESIDUE line(s))"
      evidence "$WORK/a14a-residue.txt"
    }
  fi

  # A14b (AC1) — THE OUTPUT DIFFERENTIAL, and the reason #37 is allowed to touch
  # this installer at all.
  #
  # Run the PRE-CARVE bootstrap-mac.sh (a blob out of git, pinned by sha) and
  # the one in this working tree into two fake $HOMEs, and diff the trees. The
  # claim "the carve changes no behaviour" is then a measurement, not a review
  # opinion -- and it covers what nothing else here does: the 30 OpenCode agents
  # and the files INSIDE the 12 skill directories (A6 compares 8 named files,
  # A7 only checks that 12 directory names exist).
  #
  # THE NEW SIDE IS $REPO_ROOT, NEVER `git archive HEAD`. A differential between
  # two committed blobs is green on a laptop whose working tree is broken, and
  # this harness advertises laptop use in its header.
  #
  # PINNED, not located: the pre-carve revision is a fact about #37's history,
  # not something a rule over the file could still find once the carve has
  # landed (every later blob has unit functions in it). Bump it only when the
  # baseline it names is deliberately being moved forward.
  #
  # THE TAG refs/tags/mac-pre-carve IS LOAD-BEARING. DO NOT DELETE IT.
  #
  # 5f016b3 is an ancestor of main today, but only by ACCIDENT: it is `Merge pull
  # request #102`, a two-parent commit, and squashing later PRs therefore never
  # orphaned it. This repo's history is MIXED -- #101-#104 landed as merge
  # commits, #105/#107/#108/#106/#110 were SQUASHED -- and nothing enforces
  # either. The day the run of merge commits this pin sits inside is rewritten,
  # `cat-file -e` starts failing and the differential stops asserting. So the pin
  # is kept reachable by ARTIFACT rather than by a merge strategy nobody wrote
  # down:
  #   git push origin 5f016b3736d7ec017d30e4d98e61197958f3dae9:refs/tags/mac-pre-carve
  # A tag is a ref, so the object survives any squash, rebase or branch deletion,
  # and actions/checkout with `fetch-depth: 0` fetches tags
  # (getRefSpecForAllHistory includes `+refs/tags/*:refs/tags/*`), so CI sees it
  # too. This is the same artifact #110 pushed for the VPS differential, and
  # after #110 was squash-merged it is the only reason that one still works.
  #
  # AND THERE IS A SECOND ROUTE BACK, unlike the VPS pin. 5f016b3 is a MERGE
  # commit, and its second parent 1819bdf is refs/pull/102/head -- a ref GitHub
  # keeps forever -- which carries the IDENTICAL bootstrap-mac.sh (both resolve
  # to blob ae204b5, checked). So if the tag is ever lost as well, the baseline
  # can be re-pinned BACKWARDS onto 1819bdf without changing what A14b compares.
  # The failure text below says so. Backwards is always safe here; forwards is
  # the move A14b0's shape check exists to refuse.
  #
  # PINNED BY SHA RATHER THAN BY TAG NAME, deliberately, exactly as
  # test-deploy-vps.sh:363 is. A sha is content-addressed; `mac-pre-carve` could
  # be moved onto a post-carve revision by anyone with push access and the
  # differential would quietly become the tree against itself. The tag's job is
  # REACHABILITY; the sha's job is IDENTITY; A14b0 below checks the blob's SHAPE,
  # so re-pinning has two guards and not one.
  PRE_CARVE_SHA="5f016b3736d7ec017d30e4d98e61197958f3dae9"

  # A14b0 (#111) — THE BASELINE ITSELF, the preflight test-deploy-vps.sh:390
  # calls V0. Before this existed, all four of the ways below collapsed into one
  # counted SKIP and the harness still exited 0, so "the carve changed no
  # behaviour" could stop being asserted with nothing going red. They are
  # different facts and only ONE of them is recoverable by the person running the
  # harness, so only that one may skip:
  #
  #   reachable + pre-carve shape  -> A14b runs (the only arm that asserts)
  #   genuinely SHALLOW clone      -> SKIP, exit 0; `git fetch --unshallow` fixes
  #                                   it, and CI cannot get here (A17)
  #   unreachable in a FULL clone  -> FAIL: the tag is gone, or this branch was
  #                                   rebased and the sha was not re-pinned
  #   not a git work tree at all   -> FAIL: run from a clone, not a git-archive
  #   reachable but POST-carve     -> FAIL: someone "fixed" a dangling pin by
  #                                   re-pointing it at the branch head, and the
  #                                   differential would compare the tree with
  #                                   itself and could never fail again
  A14B_HAVE_GIT=0; A14B_SHALLOW=0; A14B_HAVE_BLOB=0
  if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    A14B_HAVE_GIT=1
    [ "$(git -C "$REPO_ROOT" rev-parse --is-shallow-repository 2>/dev/null)" != "true" ] || A14B_SHALLOW=1
    git -C "$REPO_ROOT" cat-file -e "$PRE_CARVE_SHA:scripts/mac/bootstrap-mac.sh" 2>/dev/null && A14B_HAVE_BLOB=1 || true
  fi

  # $A14B_BASELINE stays empty unless the pin is reachable AND pre-carve, and
  # A14b does not run without it. A14b0 is therefore a real gate and not a
  # diagnostic: there is no path on which A14b silently asserts nothing.
  A14B_BASELINE=""
  if [ "$A14B_HAVE_BLOB" -eq 1 ]; then
    # A SHADOW TREE, entirely inside $WORK: config/ and scripts/verify/ are
    # symlinked to the real ones (the fakes and the templates are inputs to both
    # sides and must be the same inputs), and only scripts/mac/bootstrap-mac.sh
    # is the archived blob. bootstrap-mac.sh derives REPO_ROOT from BASH_SOURCE
    # with a LOGICAL pwd, so it resolves to $WORK/pre-carve and its own
    # containment gate accepts $WORK/pre-carve/scripts/verify/fake-exec.sh.
    # Nothing is written into the checkout.
    SHADOW="$WORK/pre-carve"
    mkdir -p "$SHADOW/scripts/mac"
    # NORMALISED, and not for tidiness: macOS's $TMPDIR ends in a slash, so
    # $WORK carries a `//` that `cd`+`pwd` inside bootstrap-mac.sh collapses
    # when it derives REPO_ROOT. The containment gate then compares a collapsed
    # REPO_ROOT against an uncollapsed PAI_EXEC with a lexical `case`, refuses
    # it, and the whole differential exits 2 for a reason that has nothing to do
    # with the installer. (Measured: this is exactly how it failed first.)
    SHADOW="$(cd "$SHADOW" && pwd)"
    ln -sfn "$REPO_ROOT/config" "$SHADOW/config"
    ln -sfn "$REPO_ROOT/scripts/verify" "$SHADOW/scripts/verify"
    git -C "$REPO_ROOT" show "$PRE_CARVE_SHA:scripts/mac/bootstrap-mac.sh" \
      >"$SHADOW/scripts/mac/bootstrap-mac.sh"
    chmod 755 "$SHADOW/scripts/mac/bootstrap-mac.sh"

    # THE SHAPE CHECK, and it is the subtle arm. Reachability alone is not
    # enough: the obvious way to make a dangling pin go green is to re-point it
    # at the branch head, and a "differential" between HEAD and HEAD passes for
    # free and can never fail again. So the extracted blob is checked for what a
    # pre-carve revision must have and for what it must NOT: the PAI_EXEC seam
    # (#36, which is what makes the pre side runnable against fakes at all), and
    # zero `unit_*()` definitions -- main has five, and every revision after #105
    # has at least five. Measured at 5f016b3: seam=1, units=0.
    #
    # This is test-deploy-vps.sh:402-404's `PAI_FAKE_ROOT>=1, unit_*()==0` pair,
    # spelled for the installer instead of the deploy.
    A14B0_SEAM="$(count_in "$SHADOW/scripts/mac/bootstrap-mac.sh" '^pai_exec\(\) \{')"
    A14B0_UNITS="$(count_in "$SHADOW/scripts/mac/bootstrap-mac.sh" '^unit_[a-z_]+\(\) \{')"
    if [ "$A14B0_SEAM" -ge 1 ] && [ "$A14B0_UNITS" -eq 0 ]; then
      A14B_BASELINE="$SHADOW/scripts/mac/bootstrap-mac.sh"
      ok "A14b0: the pinned baseline ${PRE_CARVE_SHA:0:9} is reachable, carries the PAI_EXEC seam and defines no unit function"
    else
      bad "A14b0: ${PRE_CARVE_SHA:0:9} is reachable but is NOT a pre-carve revision of bootstrap-mac.sh (pai_exec()=$A14B0_SEAM want >=1, unit_*() definitions=$A14B0_UNITS want 0) — A14b did not run. Re-pinning the baseline forward onto a post-carve sha compares the working tree with itself, which passes for free and can never fail. If the pin is dangling, recover the OBJECT (see the UNREACHABLE arm below); do not move the pin."
    fi
  elif [ "$A14B_HAVE_GIT" -eq 1 ] && [ "$A14B_SHALLOW" -eq 1 ]; then
    # THE ONLY SKIP IN THIS HARNESS, and the only id on $SKIPPABLE. It is
    # distinguishable by construction (`--is-shallow-repository`), it is
    # self-repairing by one documented command, and CI cannot reach it because
    # install-test.yml sets `fetch-depth: 0` -- which A17 now asserts, so this
    # arm cannot become the silent normal case again.
    skipped "A14b0" "A14b did not run: this is a SHALLOW clone and the pre-carve blob ${PRE_CARVE_SHA:0:9} was never fetched — run 'git fetch --unshallow' (CI uses fetch-depth: 0)"
  elif [ "$A14B_HAVE_GIT" -eq 1 ]; then
    bad "A14b0: ${PRE_CARVE_SHA:0:9}:scripts/mac/bootstrap-mac.sh is UNREACHABLE in a FULL clone, so A14b asserted nothing. The tag refs/tags/mac-pre-carve exists to make this impossible, so it has most likely been DELETED (or this branch was rebased past the pin). Fix it, do not skip it: 'git fetch origin refs/tags/mac-pre-carve:refs/tags/mac-pre-carve' first, and re-push it with 'git push origin ${PRE_CARVE_SHA}:refs/tags/mac-pre-carve'. Failing that, ${PRE_CARVE_SHA:0:9} is a MERGE commit and its second parent is refs/pull/102/head, which GitHub keeps forever and which carries the identical blob ae204b5: 'git fetch origin refs/pull/102/head' and re-pin BACKWARDS to that commit. Failing THAT, retire A14b deliberately and say in this file what replaces it. Never re-pin FORWARDS onto a post-carve revision — A14b0 checks for that, and it compares the tree with itself."
  else
    bad "A14b0: $REPO_ROOT is not a git work tree, so the pre-carve baseline cannot be read and A14b asserted nothing. Run this harness from a clone, not from a 'git archive' export — install-test.yml's routing negative test uses 'cp -a' for exactly this reason."
  fi

  if [ -n "$A14B_BASELINE" ]; then
    run_bootstrap_at() {
      # run_bootstrap_at <script> <home> <pai-exec> <tag>; echoes rc.
      # Same seam wiring as run_bootstrap, but with the script, the $HOME and
      # the brew state all parameterised, because the whole point is two runs
      # that share NOTHING except the repo's config/ and the fakes. A shared
      # FAKE_BREW_STATE would make the second run take the idempotent path and
      # install nothing, and the diff would then compare a full tree against
      # itself-from-the-first-run.
      #
      # OPENCODE_ZEN_API_KEY IS WITHHELD FROM BOTH SIDES (#38). The differential
      # asks "does the carve change what gets installed", and the answer has to
      # be about the carve. unit_opencode() now calls opencode-auth.sh, which
      # writes ~/.local/share/opencode/auth.json that the pre-carve blob knows
      # nothing about -- a real, deliberate new behaviour that would read here
      # as a regression. Empty rather than excluded from the diff: with no key
      # the script takes its documented "print one line, write nothing" arm on
      # BOTH sides, so the trees stay comparable and nothing is hidden from the
      # comparison. Phase F is where the auth write is asserted, against phase
      # A's $HOME, which DOES have the fixture key.
      local rc=0
      mkdir -p "$2" "$WORK/state-$4" "$WORK/prefix-$4"
      : >"$WORK/brew-$4.log"
      HOME="$2" \
      OPENCODE_ZEN_API_KEY="" \
      PATH="$BOOT_PATH" \
      PAI_EXEC="$3" \
      PAI_FAKE_ROOT="$WORK" \
      PAI_DENY_LOG="$WORK/deny-$4.log" \
      FAKE_BREW_LOG="$WORK/brew-$4.log" \
      FAKE_BREW_STATE="$WORK/state-$4" \
      FAKE_BREW_PREFIX="$WORK/prefix-$4" \
      FAKE_GOOSE_VERSION="$PINS_VERSION" \
        "$1" >"$WORK/out/$4.log" 2>&1 </dev/null || rc=$?
      echo "$rc"
    }

    A14B_PRE_RC="$(run_bootstrap_at "$A14B_BASELINE" \
      "$WORK/home-pre" "$SHADOW/scripts/verify/fake-exec.sh" "pre")"
    A14B_POST_RC="$(run_bootstrap_at "$REPO_ROOT/scripts/mac/bootstrap-mac.sh" \
      "$WORK/home-post" "$REPO_ROOT/scripts/verify/fake-exec.sh" "post")"

    # THE SELF-TEST. `diff -r` over two empty directories is also empty, so a
    # pre-carve run that died at its first line would satisfy the diff while
    # proving nothing. 61 is what a no-flag run writes today (8 config
    # templates + 30 OpenCode agents + the files inside the 12 skills);
    # `-ge` rather than `-eq` so adding a skill is not a failure here -- A6/A7
    # and this diff's own right-hand side are what police the contents.
    A14B_FILES="$(find "$WORK/home-pre" -type f | wc -l | tr -d ' ')"

    if [ "$A14B_PRE_RC" = "0" ] && [ "$A14B_POST_RC" = "0" ] && [ "$A14B_FILES" -ge 61 ] &&
       diff -r "$WORK/home-pre" "$WORK/home-post" >"$WORK/a14b.diff" 2>&1; then
      ok "A14b: the working tree installs the same $A14B_FILES-file \$HOME as pre-carve ${PRE_CARVE_SHA:0:9}"
    else
      bad "A14b: the installed tree differs from pre-carve ${PRE_CARVE_SHA:0:9} (pre rc=$A14B_PRE_RC, post rc=$A14B_POST_RC, files=$A14B_FILES want >=61)"
      evidence "$WORK/a14b.diff"
    fi
  fi

  # A15 — the containment gate. A stray `export PAI_EXEC=/bin/true` in a .zshrc
  # must not become a way to skip the platform guard.
  A15_ERR="$WORK/out/a15.err"; A15_RC=0
  PATH="$BOOT_PATH" PAI_DENY_LOG="$WORK/deny-a15.log" PAI_EXEC="/bin/true" \
    "$REPO_ROOT/scripts/mac/bootstrap-mac.sh" >/dev/null 2>"$A15_ERR" </dev/null || A15_RC=$?
  [ "$A15_RC" -eq 2 ] && grep -qF "scripts/verify/" "$A15_ERR" &&
    ok "A15: PAI_EXEC=/bin/true is refused with exit 2, naming scripts/verify/" || {
    bad "A15: the containment gate did not refuse /bin/true (exit $A15_RC)"
    evidence "$A15_ERR"
  }

  # A16 — the HOME interlock, the second of the three independent things that
  # must go wrong. A correctly contained PAI_EXEC still cannot touch a home
  # outside the sandbox, and it fails on the FIRST routed call (`uname -s`),
  # 38 lines before the first mutation.
  A16_ERR="$WORK/out/a16.err"; A16_RC=0; A16_HOME="$WORK/outside-home"
  A16_BREW="$WORK/brew-a16.log"
  mkdir -p "$A16_HOME"
  HOME="$A16_HOME" \
  PATH="$BOOT_PATH" \
  PAI_DENY_LOG="$WORK/deny-a16.log" \
  PAI_EXEC="$REPO_ROOT/scripts/verify/fake-exec.sh" \
  PAI_FAKE_ROOT="$WORK/home" \
  FAKE_BREW_LOG="$A16_BREW" FAKE_BREW_STATE="$WORK/state-a16" \
  FAKE_BREW_PREFIX="$WORK/prefix-a16" FAKE_GOOSE_VERSION="$PINS_VERSION" \
    "$REPO_ROOT/scripts/mac/bootstrap-mac.sh" >/dev/null 2>"$A16_ERR" </dev/null || A16_RC=$?
  [ "$A16_RC" -ne 0 ] && grep -qF "is not under PAI_FAKE_ROOT" "$A16_ERR" &&
    [ ! -e "$A16_BREW" ] && [ ! -e "$A16_HOME/.config" ] &&
    ok "A16: a HOME outside PAI_FAKE_ROOT is refused before any brew call or any write" || {
    bad "A16: the HOME interlock did not stop the run (exit $A16_RC)"
    evidence "$A16_ERR"
  }

  # A17 (#111) — THE DIFFERENTIAL'S CI PRECONDITION, asserted instead of
  # commented. install-test.yml carries `fetch-depth: 0` twice, once per job,
  # each under a paragraph explaining that a shallow clone costs the job its
  # differential. Nothing checked it. actions/checkout DEFAULTS TO DEPTH 1, so
  # deleting one line was a silent, single-symptom degradation: A14b (or the
  # deploy job's V0/V1) would take its shallow arm forever, the badge would stay
  # green, and the file would still read as though history were being fetched.
  #
  # A HARNESS ASSERTING ON ITS OWN WORKFLOW is unusual here and deliberate: this
  # is the one precondition the harness cannot establish for itself and cannot
  # detect the loss of -- from inside a shallow checkout, "the blob is missing
  # because CI stopped fetching history" and "the blob is missing because I am on
  # a laptop with a shallow clone" are the same observation. So it is asserted
  # from the side that CAN tell them apart: the workflow text.
  #
  # BOTH JOBS, and an exact count. base-install's checkout feeds A14b; the
  # deploy-vps job's feeds test-deploy-vps.sh's V0/V1/V1b, which has the same
  # dependency for the same reason (#110). A third checkout appearing here is a
  # deliberate decision about history, so it fails until someone makes it.
  #
  # PARSED, not grepped. `grep -c 'fetch-depth: 0'` counts a line in a comment,
  # and both of these sit directly under a paragraph that spells the string out.
  # PyYAML is already mandatory above, and this is the same python3 the installer
  # itself runs.
  A17_WF="$REPO_ROOT/.github/workflows/install-test.yml"
  A17_OUT="$WORK/out/a17.txt"; A17_RC=0
  PATH="$WORK/pathmin" "$WORK/pathmin/python3" -c '
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
seen, bad = 0, []
for jid, job in sorted((doc.get("jobs") or {}).items()):
    for step in (job.get("steps") or []):
        if not str(step.get("uses", "")).startswith("actions/checkout@"):
            continue
        seen += 1
        depth = (step.get("with") or {}).get("fetch-depth")
        # Two near misses, both of which read as 0 and are not: the quoted
        # string "0", which actions/checkout treats as its own thing, and the
        # boolean false, which Python compares EQUAL to 0.
        if depth != 0 or isinstance(depth, bool):
            bad.append("%s: fetch-depth=%r" % (jid, depth))
print(seen)
print("; ".join(bad))
' "$A17_WF" >"$A17_OUT" 2>&1 || A17_RC=$?
  A17_SEEN="$(head -1 "$A17_OUT" 2>/dev/null || true)"
  A17_BAD="$(tail -n +2 "$A17_OUT" | tr -d '\n' || true)"
  if [ "$A17_RC" -eq 0 ] && [ "$A17_SEEN" = "2" ] && [ -z "$A17_BAD" ]; then
    ok "A17: both actions/checkout steps in install-test.yml set fetch-depth: 0, so A14b and V1 have the history they diff against"
  else
    bad "A17: install-test.yml no longer fetches full history for every checkout (rc=$A17_RC, checkout steps=${A17_SEEN:-none} want 2, offenders='$A17_BAD') — without it A14b degrades to a SKIP on every CI run and 'the carve changed no behaviour' is asserted on a laptop and nowhere else"
    evidence "$A17_OUT"
  fi
fi

# ==== 12. phase I — the OpenCode unit (#38) ===================================
# APPENDED AS ONE CONTIGUOUS BLOCK, and the delimiters earned their keep: #37's
# flag surface (phases F, G and H above) was being written against this same
# file at the same time, and it landed first. Everything this issue adds lives
# between these two banners and inside unit_opencode(), so the rebase was three
# conflicts and no interleaving. The one thing it cost is the phase LETTER --
# see the note at the top of this file for why F became I.
#
# What phase I is for: nothing under scripts/verify/ has ever executed the
# opencode binary, so whichever tier OpenCode lands in it shipped unverified.
# These nine rows are the first ones that run it.
#
# IT STARTS ITS OWN fake-provider.py, ON ITS OWN PORT, WITH ITS OWN RECORD.
# Phase D's provider is killed at the bottom of the `leg goose || leg providers`
# guard and `--only opencode` never enters that block, so there is nothing to
# reuse; a fresh record also means I3's expectation is a delta against a mark
# this phase takes itself, with no coupling to any earlier phase's row count.
if leg opencode; then
  echo
  echo "== phase I: the OpenCode credential, and check-opencode.sh =="

  # -- I9: THE SEAM LINT, and it exists because #38 got this wrong ------------
  # check-opencode.sh documented OPENCODE_BIN as an env seam and nothing added
  # it to $HARNESS_UNSET_NAMES, so the harness inherited it and ran a foreign
  # binary against the fake $HOME that carries the fixture key. Adding the four
  # names fixes today. This row is what makes the NEXT seam loud: it asserts
  # that every OPENCODE_*/FAKE_* name appearing anywhere in the three files
  # phase I drives is one this harness has taken out of the environment.
  #
  # LEXICAL AND OVER-BROAD ON PURPOSE, comments and note strings included. A
  # name that only ever appears in prose costs one word in the unset list; a
  # name that is a real seam and is missing costs a credential. The lookbehind
  # is the one narrowing: without it `PAI_OPENCODE_AUTH_FILE`
  # (opencode-auth.sh:99, a name that script exports for its own heredoc) is
  # reported as a missing seam, and a lint whose first output is a false
  # positive is a lint somebody deletes. It runs FIRST in the phase, before any
  # fixture is planted, because it is a property of the source and there is
  # nothing for it to wait for.
  I9_MISSING="$(PAI_I9_NAMES="$HARNESS_UNSET_NAMES" "$WORK/pathmin/python3" -c '
import os, re, sys
unset = set(os.environ["PAI_I9_NAMES"].split())
seen = set()
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as fh:
        seen |= set(re.findall(r"(?<![A-Za-z0-9_])(?:OPENCODE|FAKE)_[A-Z0-9_]+", fh.read()))
print(" ".join(sorted(seen - unset)))
' "$HERE/check-opencode.sh" "$HERE/fake-opencode.sh" \
  "$REPO_ROOT/scripts/mac/opencode-auth.sh")"
  # The MESSAGE carries variable NAMES, never a value -- that is the whole point
  # of the row, and E2's rule still applies to it.
  [ -z "$I9_MISSING" ] &&
    ok "I9: every OPENCODE_*/FAKE_* seam the OpenCode scripts name is unset by this harness" || {
    bad "I9: an env seam the OpenCode scripts read is NOT in \$HARNESS_UNSET_NAMES: $I9_MISSING"
    echo "      | add it there, or this harness runs whatever the developer's shell chose"
    echo "      | against \$HOME=$FAKE_HOME, whose auth.json holds a credential"
  }

  OC_PORT="${OC_PORT:-4395}"
  OC_URL="http://127.0.0.1:$OC_PORT"
  OC_RECORD="$WORK/opencode-provider.jsonl"
  # ONE deny log for the whole phase, and I7 asserts it empty. Both walls feed
  # it: the auth probes run behind $WORK/deny (nothing external at all), and
  # check-opencode.sh runs behind $WORK/deny-net (curl allowed, because
  # fake-opencode.sh stands in for the HTTP the real binary does itself).
  OC_DENY="$WORK/deny-i.log"
  : >"$OC_DENY"
  : >"$OC_RECORD"
  "$HERE/fake-provider.py" --port "$OC_PORT" --out "$OC_RECORD" \
    >"$WORK/out/opencode-provider.log" 2>&1 &
  PROVIDER_PID=$!

  OC_READY=0
  for _ in $(seq 1 100); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $ZEN_FIXTURE_KEY" \
      "$OC_URL/zen/v1/models" 2>/dev/null || echo 000)"
    [ "$code" = "200" ] && { OC_READY=1; break; }
    sleep 0.1
  done
  [ "$OC_READY" -eq 1 ] || {
    evidence "$WORK/out/opencode-provider.log"
    die "fake-provider.py never answered 200 on $OC_URL/zen/v1/models (port $OC_PORT busy?)"
  }

  oc_row_count() { grep -c . "$OC_RECORD" 2>/dev/null || true; }
  oc_rows_since() {
    # The phase D shape, deliberately duplicated rather than hoisted: rows_since
    # is defined INSIDE the `leg goose || leg providers` guard, so hoisting it
    # would mean editing a region #37 is also in. Six lines is the cheaper of
    # the two costs and this comment is the record of that choice.
    "$WORK/pathmin/python3" -c '
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
for r in rows[int(sys.argv[2]):]:
    print(r["mount"], r["method"], r["path"], r["auth_scheme"],
          str(r["key_matched"]).lower(), r["model"] or "-", r["status"])
' "$OC_RECORD" "$1"
  }

  # -- I1/I2: the file PHASE A's bootstrap wrote, in phase A's $HOME ----------
  # Read back, never planted here. The acceptance criterion is "`pai install`
  # authenticates OpenCode with no TUI interaction", and a fixture this section
  # wrote itself would be the harness testing the harness.
  OC_AUTH="$FAKE_HOME/.local/share/opencode/auth.json"
  [ -f "$OC_AUTH" ] &&
    ok "I1: unit_opencode() wrote ~/.local/share/opencode/auth.json — no TUI, no /connect" ||
    bad "I1: no auth.json under the installed \$HOME — the bootstrap did not authenticate OpenCode"

  # oct(st_mode & 0o777) rather than `stat`: `stat` is not in REQUIRED_TOOLS
  # (so it is not in $WORK/pathmin either) and its flags differ BSD vs GNU.
  OC_MODE="$("$WORK/pathmin/python3" -c \
    'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' \
    "$OC_AUTH" 2>/dev/null || true)"
  [ "$OC_MODE" = "600" ] &&
    ok "I2: auth.json is mode 600" ||
    bad "I2: auth.json is mode ${OC_MODE:-absent}, want 600 — a live credential at a wider mode"

  # -- the stand-in binaries -------------------------------------------------
  plant_opencode() {
    # plant_opencode <bin-dir> <version> — a PATH shim that execs
    # fake-opencode.sh with a fixed version, the same shape fake-brew.sh's
    # materialise_goose() writes for goose. Planted by the HARNESS and not by
    # fake-brew: fake-brew.sh:65-76 states that its materialisation allowlist is
    # exactly one binary and must not grow, and every question phase I asks is
    # about check-opencode.sh's logic rather than about which formula brew ran.
    mkdir -p "$1"
    cat >"$1/opencode" <<EOF
#!/bin/sh
FAKE_OPENCODE_VERSION="$2"
export FAKE_OPENCODE_VERSION
exec "$HERE/fake-opencode.sh" "\$@"
EOF
    chmod 755 "$1/opencode"
  }

  # 1.18.19 / 1.18.26 are the two versions the ticket measured on the owner's
  # Mac: brew's pinned formula, and the self-updating vendor build that was
  # ahead of it on PATH.
  OC_BREW_PREFIX="$WORK/opencode-brew"
  plant_opencode "$OC_BREW_PREFIX/bin" "1.18.19"
  OC_PATH="$OC_BREW_PREFIX/bin:$WORK/deny-net:$WORK/pathmin"

  # -- I0/I3: the check itself -----------------------------------------------
  OC_MARK="$(oc_row_count)"
  OC_OUT="$WORK/out/opencode.log"; OC_RC=0
  # $OPENCODE_BREW_PREFIX is what keeps `brew --prefix opencode` from running:
  # brew is on DENY_NAMES and `command -v brew` SUCCEEDS against the exit-127
  # shim, so the bare call would land in $OC_DENY and I7 would catch it.
  PATH="$OC_PATH" \
  PAI_DENY_LOG="$OC_DENY" \
  OPENCODE_BREW_PREFIX="$OC_BREW_PREFIX" \
  FAKE_PROVIDER_URL="$OC_URL" \
    "$HERE/check-opencode.sh" >"$OC_OUT" 2>&1 || OC_RC=$?

  [ "$OC_RC" -eq 0 ] && grep -qF "== summary: 9 passed, 0 failed, 0 skipped ==" "$OC_OUT" &&
    ok "I0: check-opencode.sh exited 0 with '9 passed, 0 failed, 0 skipped'" || {
    bad "I0: check-opencode.sh exited $OC_RC without a clean nine-row summary"
    evidence "$OC_OUT"
  }

  # I3 — THE WIRE. I0's exit code is satisfiable by a check that inspects files
  # and never opens a socket; this row is not. One request, built end to end
  # from the INSTALLED opencode.json (the model id) and the INSTALLED auth.json
  # (the key), landing key-matched on the Zen mount.
  cat >"$WORK/expect-i3.txt" <<'EOF'
zen POST /zen/v1/chat/completions bearer true minimax-m2.7 200
EOF
  oc_rows_since "$OC_MARK" >"$WORK/actual-i3.txt" || true
  if diff -u "$WORK/expect-i3.txt" "$WORK/actual-i3.txt" >"$WORK/i3.diff" 2>&1; then
    ok "I3: \`opencode run\` made exactly one Zen request, with the model the installed config pins"
  else
    bad "I3: the request check-opencode.sh provoked is not the one the installed config implies"
    evidence "$WORK/i3.diff"
  fi

  # I0b — NOT INSTALLED IS A SKIP, NOT A FINDING. `opencode` is not in
  # DENY_NAMES, so taking the fixture prefix off PATH simply leaves nothing to
  # resolve — the state of a Mac that deliberately did not install this add-on.
  # scripts/pai/cli.sh reads exit 2 as a skip, so a FAIL here would turn every
  # such machine red.
  I0B_ERR="$WORK/out/i0b.err"; I0B_RC=0
  PATH="$WORK/deny-net:$WORK/pathmin" \
  PAI_DENY_LOG="$OC_DENY" \
  OPENCODE_BREW_PREFIX="$OC_BREW_PREFIX" \
    "$HERE/check-opencode.sh" >/dev/null 2>"$I0B_ERR" || I0B_RC=$?
  [ "$I0B_RC" -eq 2 ] && grep -qF "opencode CLI not found on PATH" "$I0B_ERR" &&
    ok "I0b: with no opencode on PATH, check-opencode.sh exits 2 and names the precondition" || {
    bad "I0b: check-opencode.sh exited $I0B_RC with no opencode installed (want 2)"
    evidence "$I0B_ERR"
  }

  # -- I4/I5: opencode-auth.sh's two arms, driven directly -------------------
  # DIRECTLY, not through bootstrap-mac.sh: both need a $HOME in a state the
  # installer cannot produce (a pre-existing second provider; no key at all),
  # and two more full bootstraps to reach a forty-line script would buy nothing.
  run_auth() {
    # run_auth <home> <out-file> <key|-> ; echoes rc. Behind the FULL deny wall:
    # opencode-auth.sh must reach no external binary at all, and I7 is what says
    # so. The key travels as an environment variable, never on argv.
    local rc=0
    mkdir -p "$1"
    if [ "$3" = "-" ]; then
      PATH="$WORK/deny:$WORK/pathmin" PAI_DENY_LOG="$OC_DENY" HOME="$1" \
        env -u OPENCODE_ZEN_API_KEY "$REPO_ROOT/scripts/mac/opencode-auth.sh" \
        >"$2" 2>&1 </dev/null || rc=$?
    else
      PATH="$WORK/deny:$WORK/pathmin" PAI_DENY_LOG="$OC_DENY" HOME="$1" \
      OPENCODE_ZEN_API_KEY="$3" \
        "$REPO_ROOT/scripts/mac/opencode-auth.sh" >"$2" 2>&1 </dev/null || rc=$?
    fi
    echo "$rc"
  }

  # I4 — MERGE, NOT OVERWRITE. seed_auth (code-agent-manager.py:1094) opens the
  # file "w" and dumps a single-key object; copying that here would silently
  # delete every other provider a Mac had connected. The sentinel is generated
  # at run time and never committed.
  I4_HOME="$WORK/home-merge"
  I4_SENTINEL="pai-install-test-other-$$"
  mkdir -p "$I4_HOME/.local/share/opencode"
  I4_AUTH="$I4_HOME/.local/share/opencode/auth.json"
  PAI_I4_PATH="$I4_AUTH" PAI_I4_SENTINEL="$I4_SENTINEL" "$WORK/pathmin/python3" -c '
import json, os
path = os.environ["PAI_I4_PATH"]
with open(path, "w", encoding="utf-8") as fh:
    json.dump({"anthropic": {"type": "api", "key": os.environ["PAI_I4_SENTINEL"]}}, fh)
os.chmod(path, 0o600)
'
  I4_RC="$(run_auth "$I4_HOME" "$WORK/out/i4.log" "$ZEN_FIXTURE_KEY")"
  I4_OK=0
  # A boolean out of python3, so neither the sentinel nor the key is compared in
  # a shell string this harness could later print.
  PAI_I4_PATH="$I4_AUTH" PAI_I4_SENTINEL="$I4_SENTINEL" PAI_I4_KEY="$ZEN_FIXTURE_KEY" \
    "$WORK/pathmin/python3" -c '
import json, os, sys
doc = json.load(open(os.environ["PAI_I4_PATH"]))
ok = (doc.get("anthropic", {}).get("key") == os.environ["PAI_I4_SENTINEL"]
      and doc.get("opencode") == {"type": "api", "key": os.environ["PAI_I4_KEY"]})
sys.exit(0 if ok else 1)
' >/dev/null 2>&1 && I4_OK=1
  [ "$I4_RC" = "0" ] && [ "$I4_OK" -eq 1 ] &&
    ok "I4: an unrelated provider's entry survived the write — auth.json is merged, not overwritten" ||
    bad "I4: opencode-auth.sh did not preserve the rest of auth.json (rc=$I4_RC, contents ok=$I4_OK)"

  # I5 — NO KEY IS NOT AN ERROR. A fresh Mac has not run keychain-secrets.sh
  # yet, and unit_opencode() calls this as a bare command under `set -e`.
  I5_HOME="$WORK/home-nokey"
  I5_RC="$(run_auth "$I5_HOME" "$WORK/out/i5.log" -)"
  I5_AUTH="$I5_HOME/.local/share/opencode/auth.json"
  I5_WROTE=no
  [ -e "$I5_AUTH" ] && I5_WROTE=yes
  [ "$I5_RC" = "0" ] && [ "$I5_WROTE" = "no" ] &&
    grep -qF "no Zen key in the environment" "$WORK/out/i5.log" &&
    ok "I5: with no key, opencode-auth.sh exits 0, says so, and writes no auth.json" || {
    bad "I5: the no-key path is wrong (rc=$I5_RC, wrote auth.json=$I5_WROTE)"
    evidence "$WORK/out/i5.log"
  }

  # -- I6: the shadowing check, which is what the ticket is actually about ----
  # The vendor build goes EARLIER on PATH than the brew fixture, which is the
  # state the ticket measured. Note what this does NOT do: it does not add a
  # second binary and check the count. C9 covers cardinality separately, and
  # C7 has to fire on a machine where the vendor build is the ONLY one.
  OC_VENDOR_BIN="$FAKE_HOME/.opencode/bin"
  plant_opencode "$OC_VENDOR_BIN" "1.18.26"
  I6_OUT="$WORK/out/i6.log"; I6_RC=0
  PATH="$OC_VENDOR_BIN:$OC_PATH" \
  PAI_DENY_LOG="$OC_DENY" \
  OPENCODE_BREW_PREFIX="$OC_BREW_PREFIX" \
  FAKE_PROVIDER_URL="$OC_URL" \
    "$HERE/check-opencode.sh" >"$I6_OUT" 2>&1 || I6_RC=$?
  I6_NAMED=0
  # Two -F patterns rather than the whole sentence: the verdict word and the
  # diagnosis, with the backticks around `opencode` left out so this stays a
  # plain fixed string in single quotes (SC2016 fires on a backtick inside them).
  grep -qF 'FAIL  C7:' "$I6_OUT" &&
    grep -qF 'is the self-updating vendor build' "$I6_OUT" &&
    grep -qF "$OC_VENDOR_BIN/opencode (1.18.26)" "$I6_OUT" &&
    grep -qF "$OC_BREW_PREFIX/bin/opencode (1.18.19)" "$I6_OUT" && I6_NAMED=1
  [ "$I6_RC" -ne 0 ] && [ "$I6_NAMED" -eq 1 ] &&
    ok "I6: a vendor build ahead of brew's FAILs C7, naming both paths and both versions" || {
    bad "I6: the shadowing check did not name the vendor install (rc=$I6_RC, named=$I6_NAMED)"
    evidence "$I6_OUT"
  }

  # -- I10/I11: the two rows that make C7's and C8's SYMLINK arms real ---------
  # Neither of these was constrained by a fixture before. plant_opencode writes
  # a regular file at exactly $OPENCODE_BREW_PREFIX/bin/opencode, so in I0 the
  # PATH winner and the declared path are byte-identical strings: reverting C8
  # to `[ "$PATH_WINNER" = "$DECLARED" ]` and deleting C7's `|| is_vendor
  # "$WINNER_REAL"` arm left this leg at 20 passed, 0 failed. The PR body spends
  # a section on the lexical-vs-resolved distinction; these two rows are what
  # holds it -- and I11 promptly found that C7's resolved arm compared against
  # an UNRESOLVED vendor root and so could not fire on this platform at all.
  #
  # I10 is the machine that is CORRECT and a lexical check would slander: the
  # measured /opt/homebrew/bin/opencode (a symlink) vs /opt/homebrew/opt/opencode
  # (brew's declared prefix), same file underneath. Only the link dir goes on
  # PATH -- putting both there would resolve `opencode` twice and redden C9 for
  # an unrelated reason, which is not what this row is asking.
  OC_LINK_DIR="$WORK/opencode-link/bin"
  mkdir -p "$OC_LINK_DIR"
  ln -sf "$OC_BREW_PREFIX/bin/opencode" "$OC_LINK_DIR/opencode"
  I10_OUT="$WORK/out/i10.log"; I10_RC=0
  PATH="$OC_LINK_DIR:$WORK/deny-net:$WORK/pathmin" \
  PAI_DENY_LOG="$OC_DENY" \
  OPENCODE_BREW_PREFIX="$OC_BREW_PREFIX" \
  FAKE_PROVIDER_URL="$OC_URL" \
    "$HERE/check-opencode.sh" >"$I10_OUT" 2>&1 || I10_RC=$?
  # C8's OWN row, not the summary: a summary assertion here reddens whenever any
  # of the other eight rows does (the CI negative that deletes the credential
  # makes C2 fail), and "C8 compared strings?" would then be a lie about a run
  # that never reached C8.
  #
  # I10_DISTINCT is the guard that keeps this row from going inert the way the
  # thing it replaces did: the fixture is only interesting while the two paths
  # DIFFER as strings, and an edit that pointed the link dir at the brew prefix
  # would leave a lexical C8 passing too.
  I10_DISTINCT=0
  if [ "$OC_LINK_DIR/opencode" != "$OC_BREW_PREFIX/bin/opencode" ]; then
    I10_DISTINCT=1
  fi
  I10_C8=0
  if grep -qF "PASS  C8: the PATH winner is the declared brew install" "$I10_OUT"; then
    I10_C8=1
  fi
  [ "$I10_DISTINCT" -eq 1 ] && [ "$I10_C8" -eq 1 ] &&
    ok "I10: a PATH winner that is a SYMLINK to the declared install passes C8 — no cry-wolf" || {
    bad "I10: check-opencode.sh called a correct machine shadowed (rc=$I10_RC, distinct=$I10_DISTINCT, C8 green=$I10_C8)"
    evidence "$I10_OUT"
  }

  # I11 is the mirror: a brew-SHAPED path (nothing under ~/.opencode about it)
  # that resolves into the vendor tree. The lexical arm alone reads this as
  # clean, which is the case C7's second arm exists for and the case no row
  # asked about. $OC_VENDOR_BIN itself stays off PATH so the finding cannot come
  # from cardinality.
  OC_TRAP_DIR="$WORK/opencode-trap/bin"
  mkdir -p "$OC_TRAP_DIR"
  ln -sf "$OC_VENDOR_BIN/opencode" "$OC_TRAP_DIR/opencode"
  I11_OUT="$WORK/out/i11.log"; I11_RC=0
  PATH="$OC_TRAP_DIR:$WORK/deny-net:$WORK/pathmin" \
  PAI_DENY_LOG="$OC_DENY" \
  OPENCODE_BREW_PREFIX="$OC_BREW_PREFIX" \
  FAKE_PROVIDER_URL="$OC_URL" \
    "$HERE/check-opencode.sh" >"$I11_OUT" 2>&1 || I11_RC=$?
  I11_NAMED=0
  grep -qF 'FAIL  C7:' "$I11_OUT" &&
    grep -qF 'is the self-updating vendor build' "$I11_OUT" &&
    grep -qF "$OC_TRAP_DIR/opencode (1.18.26)" "$I11_OUT" && I11_NAMED=1
  # I10_DISTINCT's counterpart, and the reason this row tests the RESOLVED arm
  # rather than the lexical one: the path PATH hands over must not itself be
  # under the vendor root, or C7's first arm answers and the second stays
  # unconstrained -- which is precisely the state this row was added to end.
  I11_LEXICAL_CLEAN=0
  case "$OC_TRAP_DIR/opencode" in
    "$FAKE_HOME/.opencode"/*) ;;
    *) I11_LEXICAL_CLEAN=1 ;;
  esac
  [ "$I11_RC" -ne 0 ] && [ "$I11_NAMED" -eq 1 ] && [ "$I11_LEXICAL_CLEAN" -eq 1 ] &&
    ok "I11: a brew-shaped symlink INTO the vendor tree still FAILs C7, naming the path PATH gave" || {
    bad "I11: the resolved-path arm of C7 did not fire (rc=$I11_RC, named=$I11_NAMED, lexically-clean fixture=$I11_LEXICAL_CLEAN)"
    evidence "$I11_OUT"
  }

  # -- I12: the epilogue may not deny a manual step the manifest still keeps ---
  # #38 shipped a next-steps screen reading "There is no /connect step and no
  # /models step" in the same commit that DELIBERATELY kept set-default-model in
  # config/units/opencode.yaml, under a comment explaining that /models is the
  # repair for a profile that is not fresh. A user whose OpenCode had remembered
  # another model was told by the installer that the step did not exist.
  #
  # The pairing is the assertion: prose in a `cat <<EOF` has no other reader, and
  # a manifest that declares a manual step is the one place this repo says a step
  # exists. Nested `if`s rather than the file's `&&` idiom because the inner grep
  # FAILING is the good case, and `grep ... && X=1` as the last command of a body
  # would take errexit down with it.
  #
  # BOTH HALVES, because "does not deny it" alone is satisfiable by silence. The
  # first cut of this row checked only $I12_DENIED, and deleting the entire
  # OpenCode paragraph out of the epilogue left it at `24 passed, 0 failed` --
  # the user is told nothing about /models, which is the same person, in the same
  # state, as the one #38's wording misinformed. $I12_TOLD is the anchor: while
  # the manifest declares the step, the screen has to mention it.
  I12_STEP=0
  I12_DENIED=0
  I12_TOLD=0
  if grep -qE '^  - id: set-default-model$' "$REPO_ROOT/config/units/opencode.yaml"; then
    I12_STEP=1
  fi
  if grep -qF "no /models step" "$A_OUT"; then
    I12_DENIED=1
  fi
  if grep -qF "/models" "$A_OUT"; then
    I12_TOLD=1
  fi
  if [ "$I12_STEP" -eq 0 ]; then
    ok "I12: opencode.yaml declares no set-default-model step, so the epilogue owes the user nothing"
  elif [ "$I12_DENIED" -eq 0 ] && [ "$I12_TOLD" -eq 1 ]; then
    ok "I12: the installer's next-steps screen names the manual step opencode.yaml keeps, and does not deny it"
  else
    bad "I12: opencode.yaml declares set-default-model, but the epilogue denies or omits /models (denied=$I12_DENIED, mentioned=$I12_TOLD)"
    echo "      | fix the PROSE or drop the manual step — one of the two is wrong"
  fi

  # -- I7: the invariant, over this phase --------------------------------------
  [ -s "$OC_DENY" ] && {
    bad "I7: something in phase I reached a denied binary — a bare \`brew\` in check-opencode.sh?"
    evidence "$OC_DENY"
  } || ok "I7: phase I's deny log is empty — \$OPENCODE_BREW_PREFIX kept brew out of it"

  # -- I8: no credential in anything this phase wrote --------------------------
  # A boolean and a count; the offending line is never printed, because the
  # offending line is the key (the E2 rule, applied to phase I's outputs). The
  # phase A transcript is on the list because that is where opencode-auth.sh's
  # own output lands on a real install.
  I8_HITS=0
  for oc_log in "$OC_RECORD" "$OC_DENY" "$OC_OUT" "$I6_OUT" "$I10_OUT" "$I11_OUT" \
                "$A_OUT" "$I0B_ERR" \
                "$WORK/out/i4.log" "$WORK/out/i5.log" "$WORK/out/opencode-provider.log"; do
    I8_HITS=$((I8_HITS + $(count_in "$oc_log" "$ZEN_FIXTURE_KEY|$I4_SENTINEL")))
  done
  [ "$I8_HITS" -eq 0 ] &&
    ok "I8: no credential-shaped line in the record, the deny log, or any phase I transcript" ||
    bad "I8: a credential reached a log this phase wrote ($I8_HITS line(s)) — not printed here"

  kill "$PROVIDER_PID" 2>/dev/null || true
  wait "$PROVIDER_PID" 2>/dev/null || true
  PROVIDER_PID=""
fi
# ======================= #38: OPENCODE, END ==================================

# ---- 13. summary -------------------------------------------------------------
echo
if [ "$SKIP_COUNT" -eq 0 ]; then
  echo "== summary: $PASS_COUNT passed, $FAIL_COUNT failed =="
else
  echo "== summary: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped =="
fi
# $SKIP_COUNT IS STILL NOT IN THE GATE, AND THAT IS THE ANSWER TO #111's FOURTH
# QUESTION, not an omission. Making a nonzero $SKIP_COUNT exit 1 would be the
# blanket rule; the allowlist at $SKIPPABLE is the same guarantee taken one
# assertion at a time, and it is strictly stronger here:
#
#   * It says WHICH skip is allowed, so the shallow-clone arm can keep exiting 0
#     for the developer it exists for, while the unreachable, non-git and
#     post-carve arms -- which used to share that skip -- are failures.
#   * It cannot be satisfied by deleting the skip. Under a blanket rule the
#     cheapest way to green is to stop calling skipped() and echo a line
#     instead, which loses the count AND the message; here an unlisted skip is
#     reported as a failure that names the id and the list, so the only way out
#     is to fix the condition or to argue for the id in the diff.
#   * It leaves the runtime checks alone. scripts/verify/check-*.sh skip because
#     a machine legitimately does not have gitleaks, or a connector, or a goose
#     CLI; those skips are the answer, not a degraded one, and a rule that made
#     them failures would be turned off within a week.
#
# So: skips are a per-assertion decision, taken once, in writing, next to the
# arm that takes them -- and every OTHER skip fails. The count above is left in
# the summary because a listed skip is still worth seeing.
[ "$FAIL_COUNT" -eq 0 ] || exit 1
