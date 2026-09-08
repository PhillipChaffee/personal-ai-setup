#!/usr/bin/env bash
# test-base-install.sh — the whole Mac base install, end to end, with NO network,
# NO Homebrew, NO real goose and NO real key. bootstrap-mac.sh runs for real
# against the PAI_EXEC seam (scripts/verify/fake-exec.sh -> fake-brew.sh ->
# fake-goose.sh -> fake-provider.py), into a throwaway $HOME, and then the two
# checks the installer's last screen tells you to run are run against that
# install: check-providers.sh and check-goose.sh.
#
# Five phases, and each exists because it asserts something no other one can:
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
#
# Every assertion carries its id from the spec (A1..A16, B1..B4, C1, D1..D6,
# E1..E2) so a failure names the thing the installer did not do, rather than the
# line that happened to notice. Two ids are this file's own: E1b, because E1 as
# written cannot fail the way its negative control claims (see phase E), and
# D-deny, which extends the deny-PATH invariant over the check-goose step. A14
# is now A14a + A14b -- the seam's SHAPE and the installer's OUTPUT are two
# claims, and #37 makes only the first of them expressible as a diff of source.
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
Usage: test-base-install.sh [--only brew|goose|providers|routing|select] [--help]

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
  ""|brew|goose|providers|routing|select) ;;
  *) echo "test-base-install.sh: unknown --only leg: $ONLY" >&2; usage >&2; exit 2 ;;
esac

leg() {
  # leg <name> -- is this leg in scope for this run?
  [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]
}

PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0
ok()   { echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
bad()  { echo "FAIL  $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skipped() { echo "SKIP  $1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }
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
unset GOOSE_BIN PAI_MODE BRAIN_HOST OPENCODE_ZEN_API_KEY TOGETHER_API_KEY \
  GOOSE_SERVER__SECRET_KEY ZEN_BASE TOGETHER_BASE PAI_EXEC FAKE_PROVIDER_MODE \
  FAKE_PROVIDER_ZEN_KEY FAKE_PROVIDER_TOGETHER_KEY 2>/dev/null || true

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
  [ "$F5_RC" = "0" ] &&
    [ ! -e "$F5_HOME/.agents/skills/connect-service" ] &&
    [ -d "$F5_HOME/.agents/skills/ship" ] &&
    [ -f "$F5_HOME/.config/opencode/AGENTS.md" ] &&
    [ -f "$F5_HOME/.config/goose/config.yaml" ] &&
    grep -qF "==> skipping base-skills" "$WORK/out/f5.log" &&
    ok "F5: --only coding-pack installs its requires closure and NOT base-skills" || {
    bad "F5: --only coding-pack did not resolve to exactly {base-toolchain, base-goose, opencode, coding-pack} (rc=$F5_RC)"
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
fi

# ---- 8. phase H — --dry-run -------------------------------------------------
if leg select; then
  echo
  echo "== phase H: --dry-run touches nothing =="
  H_HOME="$WORK/home-dry"
  H_RC="$(run_bootstrap_flags h "$H_HOME" --dry-run)"

  # H1 — the plan, hand-typed. Six lines, in dependency order, kebab-cased and
  # indented (a column-0 unit_*() name printed here would be counted as a call
  # site by units_lint.py's P3). The banner is NOT among them: --dry-run answers
  # before the platform guard, so there is nothing before the plan.
  cat >"$WORK/golden-h.txt" <<'EOF'
==> plan (5 units, in dependency order):
  base-toolchain
  base-goose
  opencode
  base-skills
  coding-pack
EOF
  head -6 "$WORK/out/h.log" >"$WORK/actual-h.txt" 2>/dev/null || true
  if [ "$H_RC" = "0" ] && diff -u "$WORK/golden-h.txt" "$WORK/actual-h.txt" >"$WORK/h1.diff" 2>&1; then
    ok "H1: --dry-run prints the five units in dependency order and exits 0"
  else
    bad "H1: the --dry-run plan is not the five units in dependency order (rc=$H_RC)"
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

  # H3 — ZERO EXTERNAL CALLS, including `uname`. The plan is pure computation
  # over the unit table, so --dry-run answers before the platform guard and
  # before the Homebrew guard: an empty deny log proves nothing left the seam,
  # and an empty brew log proves the seam itself was never used. Together they
  # are what makes `bootstrap-mac.sh --dry-run` honest on a Mac with no brew.
  H3_DENY="$(count_in "$WORK/deny-h.log" '.')"
  H3_BREW="$(count_in "$WORK/brew-h.log" '.')"
  [ "$H3_DENY" -eq 0 ] && [ "$H3_BREW" -eq 0 ] &&
    ok "H3: --dry-run made no external call at all (deny log and brew log both empty)" || {
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
  PRE_CARVE_SHA="5f016b3736d7ec017d30e4d98e61197958f3dae9"

  A14B_HAVE_GIT=0
  if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 &&
     git -C "$REPO_ROOT" cat-file -e "$PRE_CARVE_SHA:scripts/mac/bootstrap-mac.sh" 2>/dev/null; then
    A14B_HAVE_GIT=1
  fi

  if [ "$A14B_HAVE_GIT" -ne 1 ]; then
    # Loud SKIP, never a silent pass: install-test.yml's `fetch-depth: 0` is
    # what makes this reachable in CI, and a differential that degrades to green
    # when history is absent proves nothing at the moment it matters most.
    skipped "A14b: pre-carve blob ${PRE_CARVE_SHA:0:9} is not in this clone (shallow? needs fetch-depth: 0)"
  else
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

    run_bootstrap_at() {
      # run_bootstrap_at <script> <home> <pai-exec> <tag>; echoes rc.
      # Same seam wiring as run_bootstrap, but with the script, the $HOME and
      # the brew state all parameterised, because the whole point is two runs
      # that share NOTHING except the repo's config/ and the fakes. A shared
      # FAKE_BREW_STATE would make the second run take the idempotent path and
      # install nothing, and the diff would then compare a full tree against
      # itself-from-the-first-run.
      local rc=0
      mkdir -p "$2" "$WORK/state-$4" "$WORK/prefix-$4"
      : >"$WORK/brew-$4.log"
      HOME="$2" \
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

    A14B_PRE_RC="$(run_bootstrap_at "$SHADOW/scripts/mac/bootstrap-mac.sh" \
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
fi

# ---- 12. summary --------------------------------------------------------------
echo
if [ "$SKIP_COUNT" -eq 0 ]; then
  echo "== summary: $PASS_COUNT passed, $FAIL_COUNT failed =="
else
  echo "== summary: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped =="
fi
[ "$FAIL_COUNT" -eq 0 ] || exit 1
