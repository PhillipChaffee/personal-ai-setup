#!/usr/bin/env bash
# lib.sh — the shared spine of scripts/verify/check-*.sh. Sourced, never run.
#
# Before this file, pass()/fail() were copy-pasted into five scripts verbatim,
# two more counted inline with their own verdict spelling, brain-mode was
# decided by two sentinels that disagreed, GOOSE_BIN was resolved three ways
# with three different failure policies, and /data/secrets.env was sourced by
# three near-identical blocks gated on three different variables. Every new
# per-unit check would have copied whichever file its author opened first.
#
# TWO LAYERS, ON PURPOSE:
#
#   record_pass / record_fail / record_skip   count, print nothing
#   pass / fail / skip / note                 thin printers over them
#
# The split exists because check-mcp.sh's run_check() and check-goose.sh's
# provider loop decide their verdict in one place and print it in another —
# they need the counter without the printer. Without the split they would have
# had to keep private counters, which is exactly the duplication this file
# removes.
#
# NOT INCLUDED, deliberately:
#   * die() does not indent continuation lines. Callers pass their own literals
#     because their alignment differs (check-mcp.sh aligns to a 14-char prefix,
#     check-providers.sh is flush-left) and matching them here would buy a
#     parameter nobody wants to think about.
#   * No colour. Nothing in scripts/verify/ has ever used ANSI or tput, and a
#     verify script's output is read as often from a CI log as from a terminal.
#
# Callers source it as:
#     # shellcheck source=scripts/verify/lib.sh
#     . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
#
# It does NOT set -euo pipefail: every caller already does, and a sourced file
# that changes its caller's shell options is a trap.

[ -n "${PAI_VERIFY_LIB:-}" ] && return 0
PAI_VERIFY_LIB=1

# The prefix every error message in scripts/verify/ carries. $0 is the caller's
# path when this file is sourced, which is what we want.
PAI_PROG="$(basename "$0")"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
SUMMARY=""

# ---------------------------------------------------------------- counting --

record_pass() { PASS_COUNT=$((PASS_COUNT + 1)); }
record_fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); }
record_skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); }

# summary_row <text> — one line in the per-check recap printed under the footer.
summary_row() { SUMMARY="$SUMMARY  $1"$'\n'; }

# ---------------------------------------------------------------- printing --

pass() { echo "PASS  $1"; record_pass; }
fail() { echo "FAIL  $1"; record_fail; }
skip() { echo "SKIP  $1"; record_skip; }

# note — a continuation line under a verdict. Counts as nothing, by design:
# advisory text must never move a total.
note() { echo "      $1"; }

# ----------------------------------------------------------------- footers --

# summary_footer [--skips] — the standard tail. Pass --skips for scripts that
# can legitimately skip; omitting it keeps a zero-skip script's line short.
# shellcheck disable=SC2120  # --skips is optional; most callers pass nothing
summary_footer() {
  echo
  if [ "${1:-}" = "--skips" ]; then
    echo "== summary: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped =="
  else
    echo "== summary: $PASS_COUNT passed, $FAIL_COUNT failed =="
  fi
  [ -n "$SUMMARY" ] && printf '%s' "$SUMMARY"
  return 0
}

# finish [--skips] — footer, then the exit-1-on-any-failure guard that every
# check script ends with.
# shellcheck disable=SC2120  # --skips is optional; most callers pass nothing
finish() {
  summary_footer "$@"
  [ "$FAIL_COUNT" -eq 0 ] || exit 1
}

# ------------------------------------------------------------------ errors --

# die <exit-code> <line> [line...] — first line gets the script-name prefix,
# the rest go out verbatim. Everything to stderr.
die() {
  local code="$1"; shift
  echo "$PAI_PROG: $1" >&2; shift
  local line
  for line in "$@"; do echo "$line" >&2; done
  exit "$code"
}

# die_usage <line> [line...] — the argument-parsing error every script spells
# the same way: complain, print usage to stderr, exit 2. Extra lines land
# between the complaint and the usage text (check-security.sh's no-target
# refusal prints the terraform incantation there). Requires the caller to have
# defined usage() already, which all of them do immediately after their header.
die_usage() {
  echo "$PAI_PROG: $1" >&2; shift
  local line
  for line in "$@"; do echo "$line" >&2; done
  usage >&2
  exit 2
}

# -------------------------------------------------------------------- host --

# pai_mode [yes|no] — "local" when this is running ON the brain, else "remote".
# The argument is the caller's --local flag.
#
# THE SENTINEL MUST NOT NAME A SUBDIRECTORY. The two it replaces did, and they
# disagreed: check-brain.sh probed /data/goose (or /data/goose-data, the
# pre-GOOSE_PATH_ROOT layout), check-code-agents.sh probed /data/code-agents —
# so a brain running goose with code-agents not installed was "local" to one
# script and "remote" to the other, and tried to SSH to itself. Which
# subdirectory exists is a function of WHICH ADD-ONS are installed, which is
# precisely what a host test must not depend on.
#
# /data itself is the right sentinel: it is the LUKS mountpoint every brain-side
# unit lives under, it exists on a brain whose volume is still LOCKED (no
# subdirectory does), and that is exactly the case where check-brain.sh needs to
# reach its own "run luks-unlock.sh" hint instead of trying to ssh somewhere.
#
# PAI_MODE overrides both, for CI and fixtures — the same env-seam convention as
# GOOSE_BIN, MANAGER_PY and STUB_ENGINE_STATE.
pai_mode() {
  case "${PAI_MODE:-}" in
    local|remote) echo "$PAI_MODE"; return 0 ;;
  esac
  if [ "${1:-no}" = "yes" ]; then
    echo local
    return 0
  fi
  if [ -d /data ] && command -v systemctl >/dev/null 2>&1; then
    echo local
  else
    echo remote
  fi
}

# The placeholder BRAIN_HOST the docs tell you to replace.
PAI_BRAIN_HOST_PLACEHOLDER="<your-brain>.<your-tailnet>.ts.net"

# brain_host_is_placeholder — true when BRAIN_HOST is unset or still the
# angle-bracket template. Matches on "<" so a partial edit is caught too.
brain_host_is_placeholder() {
  case "${BRAIN_HOST:-$PAI_BRAIN_HOST_PLACEHOLDER}" in
    *"<"*) return 0 ;;
    *) return 1 ;;
  esac
}

# brain_exec <cmd...> — run a command on the brain, wherever this is executing.
# Requires MODE to be set by the caller (from pai_mode) and, when remote,
# BRAIN_HOST.
brain_exec() {
  if [ "${MODE:-remote}" = "local" ]; then
    "$@"
  else
    ssh -o BatchMode=yes -o ConnectTimeout=10 "agent@$BRAIN_HOST" "$@"
  fi
}

# ------------------------------------------------------------------- goose --

# resolve_goose_bin [--required] — echo the goose binary, or nothing.
#
# THE POLICY IS THE CALLER'S, not this function's. check-connectors.sh must keep
# going without goose (manifest validation is text work and has to run in CI on
# a machine that has never installed it); check-goose.sh and check-mcp.sh are
# meaningless without it and exit 2. Baking either policy in here would silently
# flip the other one — a check-goose.sh that "passes" on a machine with no goose
# is worse than no check at all.
#
# A non-interactive SSH shell on the brain does not source the profile that puts
# ~/.local/bin on PATH, hence the second arm.
resolve_goose_bin() {
  local bin="${GOOSE_BIN:-}"
  if [ -z "$bin" ]; then
    if command -v goose >/dev/null 2>&1; then
      bin="$(command -v goose)"
    elif [ -x "$HOME/.local/bin/goose" ]; then
      bin="$HOME/.local/bin/goose"
    fi
  fi
  if [ -z "$bin" ] && [ "${1:-}" = "--required" ]; then
    die 2 "goose CLI not found on PATH or at ~/.local/bin/goose" \
      "Mac:   scripts/mac/bootstrap-mac.sh installs it (brew install block-goose-cli)." \
      "Brain: cloud-init installs it for the agent user; see docs/setup/50-vps-brain.md."
  fi
  printf '%s' "$bin"
}

# ----------------------------------------------------------------- secrets --

# load_secrets <GATE_VAR> — source /data/secrets.env when GATE_VAR is empty and
# the file is readable. The gate means an already-exported value from the
# caller's shell always wins, and a Mac (no /data) is a silent no-op.
#
# Values land as exported globals: assignments inside a function are global
# unless declared local, and set -a exports them.
load_secrets() {
  local gate="$1"
  if [ -z "${!gate:-}" ] && [ -r /data/secrets.env ]; then
    set -a
    # shellcheck disable=SC1091  # runtime path on the brain; not in the repo
    . /data/secrets.env
    set +a
  fi
}
