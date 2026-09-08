#!/usr/bin/env bash
# check-opencode.sh — the OpenCode unit's first verify script.
#
# Until #38 nothing under scripts/verify/ executed the opencode binary at all.
# The entire automated coverage of this unit was pin-models.sh reading two model
# ids out of config/opencode/opencode.json, plus doctor.py's PATH-cardinality
# probe — so a Mac where the credential had never been stored passed everything
# in this directory until a human typed `opencode`.
#
# NINE ROWS, and each one is a different way the install can be wrong:
#
#   C1  the config template landed and names both models
#   C2  auth.json exists
#   C3  auth.json is mode 600 exactly
#   C4  auth.json carries a usable api key      (a boolean; the key is not read
#                                                out of this script's mouth)
#   C5  the OpenCode agents landed
#   C6  `opencode run` actually completes
#   C7  the resolved binary is not the self-updating vendor build
#   C8  the resolved binary is the one brew declares
#   C9  exactly one `opencode` is on PATH
#
# C7 IS THE ONE THE TICKET IS ABOUT, AND IT TESTS IDENTITY, NOT CARDINALITY. The
# obvious rule — "FAIL when more than one opencode resolves" — is green on the
# machine that motivated the ticket, where `~/.opencode/bin/opencode` (a
# self-updating vendor build) is the ONLY resolution and brew's pinned 1.18.19
# is not on PATH at all. In a repo whose correctness story is pinning, "the
# binary that runs is the one nobody pinned" is the failure, and it is a
# property of WHICH path won, not of how many there were. C9 keeps the
# cardinality question as its own separate row, where it belongs.
#
# $OPENCODE_BREW_PREFIX IS A TEST SEAM AND ALSO A DENY-WALL ONE. Same
# convention as GOOSE_BIN. test-base-install.sh's deny wall lists `brew`, and
# `command -v brew` SUCCEEDS against the exit-127 shim it plants, so a bare
# `brew --prefix opencode` from here would append to $PAI_DENY_LOG and fail the
# harness's own "no call left the seam" invariant for a reason that has nothing
# to do with OpenCode. With the variable set, brew is never invoked; phase I
# sets it to a fixture prefix and then asserts its deny log is empty, so a
# regression here is loud rather than silent.
#
# `type -P`, NOT `which`. `which` is not in test-base-install.sh's REQUIRED_TOOLS
# and is therefore absent from the scrubbed PATH the harness builds; `type -P` is
# a bash builtin, so it works everywhere this script can run at all. The file
# mode is read with python3's oct(st_mode & 0o777) for the same reason: `stat` is
# not on that list either, and its flags differ between BSD and GNU.
#
# SECRETS. The key is compared and dropped: C4 exits on a boolean out of python3
# and this script never holds the value. Nothing here prints a file's contents.
set -euo pipefail

# shellcheck source=scripts/verify/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage: check-opencode.sh [--help]

Verifies the OpenCode unit on a Mac: the config template, the credential
scripts/mac/opencode-auth.sh writes, the ported agents, one real `opencode run`,
and which `opencode` the PATH actually resolves to.

Env seams (testing only). ADDING ONE MEANS ADDING IT TO
$HARNESS_UNSET_NAMES in scripts/verify/test-base-install.sh, or that harness
inherits the developer's value and runs a foreign binary against a $HOME that
holds a credential. I9 there fails if you forget.
  OPENCODE_BIN           the binary to run, instead of the PATH winner
  OPENCODE_BREW_PREFIX   the brew prefix to compare against, instead of asking
                         brew (which C8 otherwise shells out to)

Cost: one short completion. Exit: 0 ok, 1 findings, 2 OpenCode is not installed.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) die_usage "unknown argument: $1" ;;
esac

CONFIG_JSON="$HOME/.config/opencode/opencode.json"
AGENTS_DIR="$HOME/.config/opencode/agents"
AUTH_JSON="$HOME/.local/share/opencode/auth.json"
VENDOR_DIR="$HOME/.opencode"

# ---------------------------------------------------------------- resolution --
# The shape mirrors lib.sh's resolve_goose_bin, including the policy split: the
# PATH winner is recorded separately from the binary this script will run,
# because C7/C8 are questions ABOUT the PATH winner and an OPENCODE_BIN override
# must not be able to answer them.
PATH_WINNER="$(type -P opencode 2>/dev/null || true)"
ALL_ON_PATH="$(type -aP opencode 2>/dev/null || true)"
OPENCODE_BIN="${OPENCODE_BIN:-$PATH_WINNER}"

if [ -z "$OPENCODE_BIN" ]; then
  # Exit 2, not 1: "OpenCode is not installed" is a precondition, and
  # scripts/pai/cli.sh reads 2 as a skip rather than as a finding. A FAIL here
  # would make every machine that deliberately does not install this add-on red.
  die 2 "opencode CLI not found on PATH" \
    "Mac: scripts/mac/bootstrap-mac.sh installs it (brew install anomalyco/tap/opencode)." \
    "See config/units/opencode.yaml and docs/setup/20-mac-setup.md#3-opencode-zen."
fi

echo "== check-opencode: the OpenCode unit, end to end =="
echo
echo "--> opencode: $OPENCODE_BIN"

# ------------------------------------------------------------------ helpers --

file_mode() {
  # Prints the octal permission bits, or nothing. Always exits 0, so a caller's
  # `X="$(file_mode ...)"` cannot abort the script under `set -e` — a missing
  # file is C2's finding, not this helper's.
  python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' \
    "$1" 2>/dev/null || true
}

real_path() {
  # Symlinks resolved, and this is not a nicety: on a correct Mac `type -P`
  # answers /opt/homebrew/bin/opencode (brew's bin symlink) while
  # `brew --prefix opencode` answers /opt/homebrew/opt/opencode, so a STRING
  # comparison in C8 reports a shadowed install on the machine that has none.
  # Measured on the owner's Mac: both resolve to
  # /opt/homebrew/Cellar/opencode/<version>/bin/opencode. The rows still PRINT
  # the paths as given — the user has to recognise them.
  [ -n "$1" ] || return 0
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null || true
}

version_of() {
  # Prints the first version-shaped token a binary reports, or `?`. Never fails.
  local out=""
  if [ -x "$1" ]; then
    out="$({ "$1" --version 2>/dev/null || true; } | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  fi
  printf '%s' "${out:-?}"
}

run_bounded() {
  # check-goose.sh:74-80's ladder, verbatim: GNU timeout on Linux, gtimeout on a
  # Mac with coreutils, unbounded otherwise.
  if command -v timeout >/dev/null 2>&1; then
    timeout 180 "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 180 "$@"
  else
    "$@"
  fi
}

# ------------------------------------------------------------ C1: the config --
if [ ! -f "$CONFIG_JSON" ]; then
  fail "C1: no OpenCode config at $CONFIG_JSON"
  note "Install it: scripts/mac/bootstrap-mac.sh (unit_opencode), or copy"
  note "config/opencode/opencode.json there yourself."
elif python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
sys.exit(0 if isinstance(doc.get("model"), str) and isinstance(doc.get("small_model"), str) else 1)
' "$CONFIG_JSON" >/dev/null 2>&1; then
  pass "C1: $CONFIG_JSON parses and pins both model and small_model"
else
  fail "C1: $CONFIG_JSON does not parse, or does not name both model and small_model"
  note "config/opencode/opencode.json:3-4 is what pins them; the /models step in"
  note "the runbook is only for an OpenCode that has remembered another choice."
fi

# ------------------------------------------------------- C2/C3/C4: the key --
# THREE ROWS FOR ONE FILE, on purpose. "auth.json is fine" collapses three
# different repairs — run opencode-auth.sh, chmod it, re-run it with a key in
# the environment — into one verdict that names none of them.
if [ ! -f "$AUTH_JSON" ]; then
  fail "C2: no credential at $AUTH_JSON"
  note "Write it: scripts/mac/opencode-auth.sh (needs \$OPENCODE_ZEN_API_KEY)."
  note "The /connect TUI step is gone; the bootstrap does this now."
  skip "C3: auth.json mode — nothing to read"
  skip "C4: auth.json contents — nothing to read"
else
  pass "C2: $AUTH_JSON exists"

  AUTH_MODE="$(file_mode "$AUTH_JSON")"
  if [ "$AUTH_MODE" = "600" ]; then
    pass "C3: auth.json is mode 600"
  else
    fail "C3: auth.json is mode ${AUTH_MODE:-unreadable}, want 600"
    note "Repair: chmod 600 $AUTH_JSON"
    note "opencode-auth.sh creates it O_EXCL at 0600, so a wider mode means"
    note "something else wrote or relaxed it."
  fi

  # A BOOLEAN, and the value never leaves python3. `>/dev/null 2>&1` because
  # even a traceback out of this program would quote the document it choked on.
  if python3 -c '
import json, sys
entry = json.load(open(sys.argv[1])).get("opencode")
ok = isinstance(entry, dict) and entry.get("type") == "api" \
    and isinstance(entry.get("key"), str) and bool(entry["key"])
sys.exit(0 if ok else 1)
' "$AUTH_JSON" >/dev/null 2>&1; then
    pass "C4: auth.json carries a non-empty opencode api key (value not read here)"
  else
    fail "C4: auth.json has no usable {\"opencode\": {\"type\": \"api\", \"key\": ...}} entry"
    note "Re-run scripts/mac/opencode-auth.sh with \$OPENCODE_ZEN_API_KEY set."
  fi
fi

# ------------------------------------------------------------ C5: the agents --
# These files are coding-pack's footprint, not this unit's, and they are checked
# here because this is the only script in the repo that looks inside
# ~/.config/opencode at all. SKIP rather than FAIL when the directory is absent:
# a Mac that installed opencode without coding-pack is a supported shape.
if [ ! -d "$AGENTS_DIR" ]; then
  skip "C5: $AGENTS_DIR is absent (coding-pack not installed)"
else
  AGENTS_MISSING=0
  AGENTS_TOTAL=0
  for agent_md in "$REPO_ROOT"/config/opencode/agents/*.md; do
    [ -f "$agent_md" ] || continue
    AGENTS_TOTAL=$((AGENTS_TOTAL + 1))
    [ -f "$AGENTS_DIR/$(basename "$agent_md")" ] || AGENTS_MISSING=$((AGENTS_MISSING + 1))
  done
  if [ "$AGENTS_TOTAL" -gt 0 ] && [ "$AGENTS_MISSING" -eq 0 ]; then
    pass "C5: all $AGENTS_TOTAL OpenCode agents landed in $AGENTS_DIR"
  else
    fail "C5: $AGENTS_MISSING of $AGENTS_TOTAL OpenCode agents are missing from $AGENTS_DIR"
    note "Re-run scripts/mac/bootstrap-mac.sh (unit_coding_pack copies them, no-clobber)."
  fi
fi

# ---------------------------------------------------------------- C6: the run --
# THE HEADLINE ROW. Everything above is a file on disk; this is the only line
# that proves the pieces work together — a config, a credential and a provider,
# exercised by the binary the user will actually type.
RUN_OUT="$(mktemp)"
trap 'rm -f "$RUN_OUT"' EXIT
RUN_RC=0
# The prompt is on argv; the credential is NOT, and never is. #38 adopts that as
# a stated rule for this repo: argv shows up in `ps`, in a `set -x` transcript
# and in a crash dump, and a header or a file is free of all three.
run_bounded "$OPENCODE_BIN" run 'Reply with exactly OK' >"$RUN_OUT" 2>&1 || RUN_RC=$?

if [ "$RUN_RC" -eq 0 ] && grep -q "OK" "$RUN_OUT"; then
  pass "C6: \`opencode run\` completed and answered"
elif [ "$RUN_RC" -eq 0 ]; then
  # Ran clean but did not say OK. Counted as a PASS with the tail shown, the
  # same judgement check-goose.sh:126-129 makes: the wire evidently works and
  # the model's wording is not this repo's to police.
  pass "C6: \`opencode run\` ran clean, but the output lacked the literal 'OK' — inspect below"
  tail -n 5 "$RUN_OUT" | sed 's/^/      | /'
else
  fail "C6: \`opencode run\` exited $RUN_RC. Last output lines:"
  tail -n 8 "$RUN_OUT" | sed 's/^/      | /'
  note "Check C2-C4 first: no credential is the usual cause."
fi

# ----------------------------------------------- C7/C8/C9: which binary ran --
DECLARED=""
if [ -n "${OPENCODE_BREW_PREFIX:-}" ]; then
  DECLARED="$OPENCODE_BREW_PREFIX/bin/opencode"
elif command -v brew >/dev/null 2>&1; then
  BREW_PREFIX="$(brew --prefix opencode 2>/dev/null || true)"
  [ -z "$BREW_PREFIX" ] || DECLARED="$BREW_PREFIX/bin/opencode"
fi

WINNER_VERSION="$(version_of "$PATH_WINNER")"
DECLARED_VERSION="$(version_of "$DECLARED")"
WINNER_REAL="$(real_path "$PATH_WINNER")"
DECLARED_REAL="$(real_path "$DECLARED")"
# THE VENDOR ROOT HAS TO BE RESOLVED TOO, and it was not: the second arm below
# compares a RESOLVED winner against an UNRESOLVED $HOME/.opencode prefix, and
# on macOS $HOME under /var or /tmp resolves through /private, so the resolved
# path never has the unresolved prefix and the arm could not fire at all. Caught
# by I11 in test-base-install.sh, which is the first fixture that ever pointed a
# brew-shaped symlink into the vendor tree.
VENDOR_REAL="$(real_path "$VENDOR_DIR")"

# BOTH the path as PATH gave it and the path it resolves to. The lexical test
# is the one the ticket names; the resolved test also catches a brew-shaped
# symlink that points into the vendor tree, which the lexical test alone reads
# as clean.
is_vendor() {
  # is_vendor <path> <vendor-root>. BOTH must be non-empty: an empty root would
  # leave the glob as `/*`, which matches every absolute path on the machine and
  # would report every install as the vendor build.
  local path="${1:-}" root="${2:-}"
  [ -n "$path" ] || return 1
  [ -n "$root" ] || return 1
  case "$path" in "$root"/*) return 0 ;; esac
  return 1
}

if is_vendor "$PATH_WINNER" "$VENDOR_DIR" || is_vendor "$WINNER_REAL" "$VENDOR_REAL"; then
  fail "C7: the \`opencode\` on PATH is the self-updating vendor build"
  note "on PATH:  $PATH_WINNER ($WINNER_VERSION)"
  note "declared: ${DECLARED:-<brew could not say>} ($DECLARED_VERSION)"
  note "config/units/opencode.yaml owns the brew formula anomalyco/tap/opencode,"
  note "and that is the copy config/pins.yaml's story applies to. The vendor"
  note "install updates itself, so the version this repo verifies is not the"
  note "version you run. Nothing here removes it — put brew's bin ahead of"
  note "$VENDOR_DIR/bin on PATH, or delete the vendor install by hand."
else
  pass "C7: the \`opencode\` on PATH ($WINNER_VERSION) is not the vendor build under $VENDOR_DIR"
fi

# C8 COMPARES RESOLVED PATHS AND PRINTS UNRESOLVED ONES. Measured on the owner's
# Mac: `type -P` answers /opt/homebrew/bin/opencode and `brew --prefix opencode`
# answers /opt/homebrew/opt/opencode, and both resolve to the same file in the
# Cellar — a string comparison here reports a shadowed install on a machine that
# has none, which is a check that cries wolf until somebody deletes it.
if [ -z "$DECLARED" ]; then
  skip "C8: no declared install to compare against (set \$OPENCODE_BREW_PREFIX, or install brew)"
elif [ -n "$WINNER_REAL" ] && [ "$WINNER_REAL" = "$DECLARED_REAL" ]; then
  pass "C8: the PATH winner is the declared brew install ($DECLARED_VERSION)"
else
  fail "C8: the \`opencode\` on PATH is not the one the manifest declares"
  note "on PATH:  ${PATH_WINNER:-<none>} ($WINNER_VERSION)"
  note "declared: $DECLARED ($DECLARED_VERSION)"
fi

# C9 — cardinality, kept as its OWN row. It is a weaker question than C7 (see
# the header), and reporting the two together is how a machine with exactly one
# wrong binary reads as clean.
RESOLUTIONS="$(printf '%s\n' "$ALL_ON_PATH" | grep -c . || true)"
if [ "$RESOLUTIONS" -le 1 ]; then
  pass "C9: exactly one \`opencode\` resolves on PATH"
else
  fail "C9: $RESOLUTIONS \`opencode\` binaries resolve on PATH — the first one wins:"
  printf '%s\n' "$ALL_ON_PATH" | sed 's/^/      | /'
fi

finish --skips
