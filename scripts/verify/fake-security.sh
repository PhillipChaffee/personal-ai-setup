#!/usr/bin/env bash
# fake-security.sh — the macOS `security` stand-in for test-pai.sh section 10.
# The harness puts a directory holding a `security` symlink to this file at the
# front of PATH, so what arrives on argv is exactly what keychain-secrets.sh
# asked the real tool to do.
#
# SECRETS. fake-brew.sh:18-22 already wrote the rule this file has to follow,
# and it named this file while doing it: "Do not carry the pattern into a
# sibling fake that can see `-w`, `--password` or `Authorization` —
# keychain-secrets.sh puts a live key on `security`'s argv, and a fake standing
# in for that must redact before it records (log the flag, the service and a
# length; never the value)." That is exactly what happens below: the log gets a
# verb, a service, an account and a CHARACTER COUNT. The value itself is never
# written anywhere -- not to the log, not to the keystore state, not to stderr.
# The state directory holds EMPTY marker files whose names are the accounts,
# which is all `find-generic-password` (without -w) has to answer.
#
# It models the two shapes keychain-secrets.sh emits and dies on anything else,
# for fake-brew's reason: a fake that accepts an argv it was not designed for
# absorbs a drifted call silently and then certifies a script that no longer
# does what the test claims.
#
# Required env, no defaults — a fake that invents a path is a fake that can
# write somewhere real:
#   FAKE_SECURITY_LOG     the invocation log, one line per call
#   FAKE_SECURITY_STATE   directory of account marker files (the "keychain")
set -euo pipefail

LOG="${FAKE_SECURITY_LOG:?fake-security: FAKE_SECURITY_LOG is required}"
STATE="${FAKE_SECURITY_STATE:?fake-security: FAKE_SECURITY_STATE is required}"
mkdir -p "$STATE"

die() { echo "fake-security: $1" >&2; exit 99; }

VERB="${1:-}"
shift || true

SERVICE=""
ACCOUNT=""
LENGTH=""
UPDATE=0
READBACK=0

while [ $# -gt 0 ]; do
  case "$1" in
    -s) shift; SERVICE="${1:-}" ;;
    -a) shift; ACCOUNT="${1:-}" ;;
    -U) UPDATE=1 ;;
    -w)
      # The one branch that ever sees a value. `add -w <value>` carries it;
      # `find -w` is the readback flag and carries nothing.
      if [ "$VERB" = "add-generic-password" ]; then
        shift
        LENGTH="${#1}"
      else
        READBACK=1
      fi
      ;;
    *) die "unexpected argument '$1' for $VERB" ;;
  esac
  shift
done

[ -n "$SERVICE" ] || die "$VERB with no -s <service>"
[ -n "$ACCOUNT" ] || die "$VERB with no -a <account>"

case "$VERB" in
  add-generic-password)
    [ "$UPDATE" -eq 1 ] || die "add-generic-password without -U would fail on an existing item"
    [ -n "$LENGTH" ] || die "add-generic-password with no -w <value>"
    echo "add s=$SERVICE a=$ACCOUNT len=$LENGTH" >>"$LOG"
    : >"$STATE/$ACCOUNT"
    ;;
  find-generic-password)
    echo "find s=$SERVICE a=$ACCOUNT readback=$READBACK" >>"$LOG"
    # Exit 44 is the real tool's "The specified item could not be found in the
    # keychain."; keychain-secrets.sh only reads the exit code.
    [ -f "$STATE/$ACCOUNT" ] || exit 44
    ;;
  *) die "unexpected verb '$VERB'" ;;
esac
