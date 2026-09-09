#!/usr/bin/env bash
# stub-engine.sh — a podman stand-in for testing the code-agent manager with
# NO containers: each "container" is a mock-opencode-server.py process, and
# one-shot runs execute on the host with /chat rewritten to the volume dir.
# Used by scripts/verify/test-code-agent-manager.sh; never installed on the
# brain. It parses exactly the CLI shapes code-agent-manager.py emits, so a
# manager change that alters those shapes fails the harness loudly.
#
# State: $STUB_ENGINE_STATE/<name>.{json,pid} (default /tmp/stub-engine).
#
# THE `-e` VALUES ARE RECORDED, NOT DISCARDED, and that is load bearing. Until
# issue #115 this arm was `-e|--label|--memory|--cpus) i=$((i+1)) ;;` — it threw
# the whole flag away — and launch() started the mock with
# `OPENCODE_SERVER_PASSWORD="${OPENCODE_SERVER_PASSWORD:-mock}"`, inherited from
# the MANAGER's environment. Every "container" therefore shared the gateway's
# own password no matter what the manager passed, so any assertion about a
# per-chat credential passed while covering nothing. Demonstrated: a run with
# `-e OPENCODE_SERVER_PASSWORD=PER-CHAT-DERIVED` under a manager holding
# GATEWAY-SECRET answered 401 to PER-CHAT-DERIVED and 200 to GATEWAY-SECRET.
#
# Recording it in the state file (rather than re-reading the environment at
# launch) is also the faithful model of `podman start`: a container's env is
# BAKED AT CREATE and reused on every later start, which is precisely why a
# container created under an old credential can never acquire a new one by
# being started, and why the manager has to recreate it instead.
set -euo pipefail

STATE="${STUB_ENGINE_STATE:-/tmp/stub-engine}"
MOCK="${STUB_ENGINE_MOCK:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mock-opencode-server.py}"
mkdir -p "$STATE"

die() { echo "stub-engine: $*" >&2; exit 1; }

alive() { [ -f "$STATE/$1.pid" ] && kill -0 "$(cat "$STATE/$1.pid")" 2>/dev/null; }

field() { # field <name> <key> — one string out of the state file, safely
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
    "$STATE/$1.json" "$2"
}

launch() {
  # $1=name — reads port/dir/password from the state file. NOTHING here reads
  # the ambient environment: see the header.
  local name="$1" port dir pw
  port="$(field "$name" port)"
  dir="$(field "$name" dir)"
  pw="$(field "$name" password)"
  OPENCODE_SERVER_PASSWORD="$pw" \
    python3 "$MOCK" --port "$port" --dir "$dir" \
    >>"$STATE/$name.log" 2>&1 &
  echo $! > "$STATE/$name.pid"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  run)
    NAME=""; PORT=""; DIR=""; ONESHOT="no"; SCRIPT=""; DETACH="no"; ENVPW=""
    ARGS=("$@")
    i=0
    while [ "$i" -lt "${#ARGS[@]}" ]; do
      a="${ARGS[$i]}"
      case "$a" in
        -d) DETACH="yes" ;;
        --rm) ONESHOT="yes" ;;
        --name) i=$((i+1)); NAME="${ARGS[$i]}" ;;
        --entrypoint) i=$((i+1)) ;;  # /bin/sh for one-shots
        -p) i=$((i+1)); PORT="$(echo "${ARGS[$i]}" | cut -d: -f2)" ;;
        -v) i=$((i+1)); DIR="$(echo "${ARGS[$i]}" | cut -d: -f1)" ;;
        -e) i=$((i+1))
            case "${ARGS[$i]}" in
              OPENCODE_SERVER_PASSWORD=*) ENVPW="${ARGS[$i]#OPENCODE_SERVER_PASSWORD=}" ;;
            esac ;;
        --label|--memory|--cpus) i=$((i+1)) ;;
        -c) i=$((i+1)); SCRIPT="${ARGS[$i]}" ;;
      esac
      i=$((i+1))
    done
    if [ "$ONESHOT" = "yes" ]; then
      [ -n "$DIR" ] || die "one-shot without a volume"
      [ -n "$SCRIPT" ] || die "one-shot without -c script"
      # STUB_ENGINE_FAIL_ONESHOT names a SENTINEL FILE, not a flag: the
      # engine inherits its environment from the manager, which was launched
      # once, so an env var could never be toggled mid-run. A file lets the
      # harness arm and disarm the clone/setup failure between requests.
      if [ -n "${STUB_ENGINE_FAIL_ONESHOT:-}" ] && [ -f "$STUB_ENGINE_FAIL_ONESHOT" ]; then
        echo "stub-engine: forced one-shot failure (sentinel present)" >&2
        exit 1
      fi
      # Emulate the bind mount textually: /chat -> the volume dir.
      exec sh -c "${SCRIPT//\/chat/$DIR}"
    fi
    [ "$DETACH" = "yes" ] || die "expected -d for a server run"
    [ -n "$NAME" ] && [ -n "$PORT" ] && [ -n "$DIR" ] || die "run missing name/port/volume"
    # LOUD, not defaulted. A server run with no password is a manager bug, and
    # silently falling back to "mock" (or to the ambient value) is exactly the
    # inertness this file's header describes.
    [ -n "$ENVPW" ] || die "server run without -e OPENCODE_SERVER_PASSWORD=..."
    # json.dump rather than printf: the password is an arbitrary string and a
    # hand-built JSON literal would corrupt the state file on the first quote.
    python3 -c 'import json,sys
json.dump({"port": int(sys.argv[1]), "dir": sys.argv[2], "password": sys.argv[3]},
          open(sys.argv[4], "w", encoding="utf-8"))' "$PORT" "$DIR" "$ENVPW" "$STATE/$NAME.json"
    launch "$NAME"
    ;;
  start)
    NAME="$1"
    [ -f "$STATE/$NAME.json" ] || die "no such container: $NAME"
    alive "$NAME" || launch "$NAME"
    ;;
  stop)
    # podman stop [--filter ...] [--time N] NAME...
    for a in "$@"; do
      case "$a" in
        --time|--filter) SKIP_NEXT=1 ;;
        *) if [ "${SKIP_NEXT:-0}" = 1 ]; then SKIP_NEXT=0; else
             [ -f "$STATE/$a.pid" ] && kill "$(cat "$STATE/$a.pid")" 2>/dev/null || true
             rm -f "$STATE/$a.pid"
           fi ;;
      esac
    done
    ;;
  rm)
    for a in "$@"; do
      [ "$a" = "-f" ] && continue
      [ -f "$STATE/$a.pid" ] && kill "$(cat "$STATE/$a.pid")" 2>/dev/null || true
      rm -f "$STATE/$a.pid" "$STATE/$a.json" "$STATE/$a.log"
    done
    ;;
  container)
    sub="$1"; shift
    case "$sub" in
      inspect)
        # container inspect --format {{.State.Status}} NAME
        NAME="${*: -1}"
        [ -f "$STATE/$NAME.json" ] || exit 1
        if alive "$NAME"; then echo "running"; else echo "exited"; fi
        ;;
      exists)
        NAME="$1"
        [ -f "$STATE/$1.json" ] || exit 1
        ;;
      *) die "unknown container subcommand: $sub" ;;
    esac
    ;;
  image)
    [ "$1" = "exists" ] && exit 0
    ;;
  logs)
    cat "$STATE/$1.log" 2>/dev/null || true
    ;;
  *)
    die "unhandled command: $cmd $*"
    ;;
esac
