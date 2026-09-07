#!/usr/bin/env bash
# fake-exec.sh — the PAI_EXEC dispatcher: the single substitutable binary that
# stands in for everything bootstrap-mac.sh invokes outside this repo.
#
# NEVER POINT THIS AT A REAL MACHINE. It answers `uname -s` with `Darwin`
# regardless of the machine it is running on, which is the entire reason
# bootstrap-mac.sh refuses a PAI_EXEC that does not live under this directory.
#
# It matches on FULL ARGV, not on the binary name, and that is the difference
# between a gate and a rubber stamp. stub-engine.sh gets its strictness from
# matching further (`unknown container subcommand`), not from a catch-all: a
# `uname) echo Darwin ;;` arm would answer a future `uname -m` with `Darwin` and
# pass. Anything unrecognised dies loudly, so a change to what the installer
# invokes fails here instead of being silently absorbed.
#
# Records nothing. fake-brew.sh owns the invocation log; presence probes are
# deliberately not recorded, which is what keeps that log's golden exact.
set -euo pipefail

die() { echo "fake-exec: $*" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Required, with no defaults: a fake that invents a path is a fake that can
# write somewhere real.
: "${PAI_FAKE_ROOT:?fake-exec: PAI_FAKE_ROOT is required}"

# THE HOME INTERLOCK, checked before the dispatch so it fires on the FIRST
# routed call -- `uname -s`, which happens 38 lines before the first mutation.
# Even a correctly-contained PAI_EXEC cannot touch a real home directory.
case "$HOME" in
  "$PAI_FAKE_ROOT"/*) ;;
  *) die "HOME ($HOME) is not under PAI_FAKE_ROOT ($PAI_FAKE_ROOT)" ;;
esac

[ "$#" -gt 0 ] || die "no command given"

case "$1" in
  uname)
    # Exact shape only. `uname -s` is the platform guard; any other flag is a
    # call this fake has never seen and must not guess at.
    [ "$#" -eq 2 ] && [ "$2" = "-s" ] || die "unhandled uname flags: $*"
    echo Darwin
    ;;
  have)
    # A seam VERB, not a binary: `command -v` is a shell builtin and cannot be
    # handed to an external dispatcher. Answered from a fixed allowlist.
    [ "$#" -eq 2 ] || die "unhandled presence probe: $*"
    [ "$2" = "brew" ] || die "unhandled presence probe: $*"
    ;;
  brew)
    shift
    exec "$HERE/fake-brew.sh" "$@"
    ;;
  goose)
    # Routed through the shim fake-brew materialised, ON PURPOSE: it makes
    # "brew installed goose before bootstrap asked its version" a real ordering
    # assertion rather than an assumption.
    [ "$#" -eq 2 ] && [ "$2" = "--version" ] || die "unhandled goose argv: $*"
    exec "${FAKE_BREW_PREFIX:?fake-exec: FAKE_BREW_PREFIX is required}/bin/goose" --version
    ;;
  *)
    die "unhandled command: $*"
    ;;
esac
