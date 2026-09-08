#!/usr/bin/env bash
# fake-brew.sh — the Homebrew stand-in behind the PAI_EXEC seam. fake-exec.sh
# strips the tool name and execs this file, so what arrives on argv here is
# exactly what bootstrap-mac.sh asked brew to do, verbatim.
#
# It models exactly the six shapes bootstrap-mac.sh emits and dies on anything
# else, because a fake that accepts an argv it was not designed for is a rubber
# stamp: it absorbs a drifted call silently and then certifies an installer that
# no longer does what the test claims it does.
#
# Two jobs beyond answering. It keeps a private installed-set, so a second
# bootstrap over the same state is genuinely idempotent rather than idempotent
# by assumption — the claim at bootstrap-mac.sh:8-9 that nothing in this repo
# has ever tested. And it appends one line per invocation to an ordered log the
# harness diffs against a HAND-WRITTEN golden; that diff, not this file's `die`
# calls, is what actually catches a reordered or added brew call.
#
# SECRETS: recording "$*" verbatim is safe HERE ONLY because no brew argument is
# ever a credential. Do not carry the pattern into a sibling fake that can see
# `-w`, `--password` or `Authorization` — keychain-secrets.sh:142 puts a live key
# on `security`'s argv, and a fake standing in for that must redact before it
# records (log the flag, the service and a length; never the value).
#
# Required env, no defaults — a fake that invents a path is a fake that can
# write somewhere real:
#   FAKE_BREW_LOG     the invocation log. The harness gives each phase a FRESH
#                     path, so run 1 can never bleed into run 2's assertion.
#   FAKE_BREW_STATE   the installed-set directory. PERSISTS across phases; that
#                     persistence is the entire phase B experiment.
#   FAKE_BREW_PREFIX  where bin/goose is materialised (see below).
# FAKE_BREW_STATE in particular must never fall back to a fixed /tmp path the
# way STUB_ENGINE_STATE does. That directory holds only .json/.pid/.log; this
# one's sibling FAKE_BREW_PREFIX/bin holds EXECUTABLES THAT GO ON PATH, so a
# fixed, world-writable location is a hijack surface on a shared CI runner and a
# stale-shim trap on a Mac.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOG="${FAKE_BREW_LOG:?fake-brew: FAKE_BREW_LOG is required}"
STATE="${FAKE_BREW_STATE:?fake-brew: FAKE_BREW_STATE is required}"
PREFIX="${FAKE_BREW_PREFIX:?fake-brew: FAKE_BREW_PREFIX is required}"

# Created up front so `list --pinned` on a virgin state prints nothing instead
# of failing, and so the record below can never be the thing that dies.
mkdir -p "$(dirname "$LOG")" "$STATE/formula" "$STATE/cask" "$STATE/pinned"

# THE RECORD, first thing and before any validation of the argv. A shape that
# has DRIFTED still lands in the log, so the ordered golden diff fails on it
# even though the dispatch below would also have killed the run — and it fails
# naming the line that changed rather than the line that stopped.
printf 'brew %s\n' "$*" >>"$LOG"

die() { echo "fake-brew: $*" >&2; exit 1; }

unhandled() {
  # unhandled.log is a better error message, NOT the alarm. Because recording
  # happens above, the golden diff has already failed by the time anyone reads
  # this file; what it adds is the offending shape in one place, next to the
  # state that shape was aimed at.
  printf 'brew %s\n' "$*" >>"$STATE/unhandled.log"
  die "unhandled brew argv: $*"
}

# THE MATERIALISATION ALLOWLIST IS EXACTLY THIS ONE BINARY, AND IT MUST NEVER
# GROW TO INCLUDE uname, sw_vers, security OR sudo. The platform escape belongs
# to the seam, where bootstrap-mac.sh's containment gate and fake-exec.sh's HOME
# interlock can both see it — not to a PATH shim that every later step in the
# harness silently inherits. Die-on-argv shims for jq/node/uv/opencode would buy
# nothing either (bootstrap-mac.sh invokes none of them, and they would shadow
# the runner's real tools for steps that hard-require jq, e.g. check-coverage.sh
# and pin-models.sh); the markers under state/formula/ already prove the loop
# ran. goose is the exception because bootstrap-mac.sh really does execute it,
# and routing that execution through a file THIS script wrote is what makes
# "brew installed goose before bootstrap asked its version" an ordering
# assertion instead of an assumption.
materialise_goose() {
  # umask in a subshell so the tight mode applies to the shim and its directory
  # without leaking onto the state markers written by the caller.
  (
    umask 077
    mkdir -p "$PREFIX/bin"
    cat >"$PREFIX/bin/goose" <<EOF
#!/bin/sh
exec "$HERE/fake-goose.sh" "\$@"
EOF
    chmod 700 "$PREFIX/bin/goose"
  )
}

# Is this argument something brew would take as a formula/cask NAME? Part of the
# shape, not a nicety, because the arity tests below cannot tell a name from a
# flag and two shapes go wrong without it. `brew install --cask` — a future edit
# dropping the cask name — is $# == 2 and would install "a formula called
# --cask": marker written, exit 0, the drifted call rubber-stamped. And an empty
# or dotted name resolves the probe's test path to "$STATE/<kind>/" or
# "$STATE/<kind>/." — directories the fake itself creates, so both exist and
# `list --versions ""` answers INSTALLED for a formula that is not, which is the
# one wrong answer that makes bootstrap skip an install it needed. Both die as
# unhandled instead, naming the argv, which is the only honest thing a fake can
# say about a shape it does not model.
is_name() {
  case "$1" in -*) return 1 ;; esac        # option-shaped, e.g. a dropped operand
  case "${1##*/}" in ""|.|..|-*) return 1 ;; esac
  return 0
}

# The installed-set is keyed on the SHORT name ("${name##*/}") throughout, since
# bootstrap-mac.sh probes `opencode` (L121 strips the tap) but installs
# `anomalyco/tap/opencode`. Keyed on the literal argument, the probe would never
# find what the install wrote and every re-run would install again — phase B
# would go green while proving the opposite of idempotence.
probe() {
  # $1 = formula|cask, $2 = short name. Silent by contract: bootstrap-mac.sh
  # sends both streams to /dev/null and reads only the exit status.
  [ -e "$STATE/$1/$2" ] || exit 1
  exit 0
}

install_one() {
  # $1 = formula|cask, $2 = the name exactly as brew received it.
  local kind="$1" short
  short="${2##*/}"
  if [ -e "$STATE/$kind/$short" ]; then
    # Unreachable unless the probe lied: bootstrap-mac.sh only installs after
    # `list --versions` said no. Real brew merely warns here, so this is
    # deliberately stricter than brew — the drift it catches is a probe whose
    # exit-status contract changed, which is invisible from the log alone.
    die "$kind $short is already installed; the probe before it must have lied"
  fi
  : >"$STATE/$kind/$short"
  if [ "$kind" = "formula" ] && [ "$short" = "block-goose-cli" ]; then
    materialise_goose
  fi
}

case "${1:-}" in
  list)
    if [ "$#" -eq 2 ] && [ "$2" = "--pinned" ]; then
      # BARE names, one per line: bootstrap-mac.sh:149 pipes this into
      # `grep -qx`, anchored to the whole line, so brew's `name 1.46.0` form
      # would silently never match and the run would re-pin forever.
      for marker in "$STATE/pinned"/*; do
        # An empty directory leaves the glob unexpanded; skip the literal.
        [ -e "$marker" ] || continue
        printf '%s\n' "${marker##*/}"
      done
    elif [ "$#" -eq 4 ] && [ "$2" = "--formula" ] && [ "$3" = "--versions" ] && is_name "$4"; then
      probe formula "${4##*/}"
    elif [ "$#" -eq 4 ] && [ "$2" = "--cask" ] && [ "$3" = "--versions" ] && is_name "$4"; then
      probe cask "${4##*/}"
    else
      unhandled "$@"
    fi
    ;;
  install)
    if [ "$#" -eq 2 ] && is_name "$2"; then
      install_one formula "$2"
    elif [ "$#" -eq 3 ] && [ "$2" = "--cask" ] && is_name "$3"; then
      install_one cask "$3"
    else
      unhandled "$@"
    fi
    ;;
  pin)
    if [ "$#" -eq 2 ] && is_name "$2"; then
      # Failing on a not-installed formula is BELIEVED to match real brew — it
      # was not verified (running it would mutate a real Mac), and nothing in CI
      # can check it. It is here because it is the one thing that catches a
      # future reorder that pins before installing: under `set -e`, the bare
      # `pai_exec brew pin` at bootstrap-mac.sh:153 aborts the whole run.
      [ -e "$STATE/formula/${2##*/}" ] || die "cannot pin ${2##*/}: not installed"
      : >"$STATE/pinned/${2##*/}"
    else
      unhandled "$@"
    fi
    ;;
  *)
    unhandled "$@"
    ;;
esac
