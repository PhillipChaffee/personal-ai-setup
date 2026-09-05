#!/usr/bin/env bash
# stub-engine.sh — a podman stand-in for testing the code-agent manager with
# NO containers: each "container" is a mock-opencode-server.py process, and
# one-shot runs execute on the host with /chat rewritten to the volume dir.
# Used by scripts/verify/test-code-agent-manager.sh; never installed on the
# brain. It parses exactly the CLI shapes code-agent-manager.py emits, so a
# manager change that alters those shapes fails the harness loudly.
#
# State: $STUB_ENGINE_STATE/<name>.{json,pid} (default /tmp/stub-engine).
set -euo pipefail

STATE="${STUB_ENGINE_STATE:-/tmp/stub-engine}"
MOCK="${STUB_ENGINE_MOCK:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mock-opencode-server.py}"
mkdir -p "$STATE"

die() { echo "stub-engine: $*" >&2; exit 1; }

alive() { [ -f "$STATE/$1.pid" ] && kill -0 "$(cat "$STATE/$1.pid")" 2>/dev/null; }

launch() {
  # $1=name — reads port/dir from the state file.
  local name="$1" port dir
  port="$(python3 -c "import json;print(json.load(open('$STATE/$name.json'))['port'])")"
  dir="$(python3 -c "import json;print(json.load(open('$STATE/$name.json'))['dir'])")"
  OPENCODE_SERVER_PASSWORD="${OPENCODE_SERVER_PASSWORD:-mock}" \
    python3 "$MOCK" --port "$port" --dir "$dir" \
    >>"$STATE/$name.log" 2>&1 &
  echo $! > "$STATE/$name.pid"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  run)
    NAME=""; PORT=""; DIR=""; ONESHOT="no"; SCRIPT=""; DETACH="no"
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
        -e|--label|--memory|--cpus) i=$((i+1)) ;;
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
    printf '{"port": %s, "dir": "%s"}\n' "$PORT" "$DIR" > "$STATE/$NAME.json"
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
