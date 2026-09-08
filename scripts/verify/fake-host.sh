#!/usr/bin/env bash
# fake-host.sh — the Ubuntu brain, faked, so scripts/vps/deploy-vps.sh can be
# EXECUTED. It is the deploy-side twin of fake-exec.sh/fake-brew.sh, and it is
# driven by scripts/verify/test-deploy-vps.sh.
#
# LINUX ONLY, and it dies 2 saying so rather than half-working. `ln -sfnT`
# (GNU -T), `stat -c %a` and register-schedules.sh's `declare -A` all rule out
# stock macOS, and a partial pass would be worse than no pass: the whole point
# of this fake is that `ln -sfn` without -T is a REAL failure mode of the
# script under test, so the assertion about it has to run against the real ln.
#
# ONE FILE, TWO ROLES:
#   fake-host.sh --materialise <dir> [name ...]   write one shim per name
#   fake-host.sh --deny-wall <dir> <name> ...     write exit-127 logging shims
#   fake-host.sh <name> <argv...>                 what the shims re-enter as
#
# Each shim is three lines and re-enters this file with its own basename
# prepended (`"${0##*/}"`, not `basename`: a shim that shells out to identify
# itself is a shim that fails to identify itself precisely when the PATH under
# test is the problem).
#
# MATCHED ON FULL ARGV, and anything unmodelled DIES (exit 97, logged). That is
# the difference between a gate and a rubber stamp -- fake-exec.sh:9-14's rule.
# A `podman) exit 0 ;;` arm would answer a future `podman run --privileged`
# with success and this harness would report a pass.
#
# THREE CLASSES OF SHIM, and the split is the design:
#
#   ANSWERING     sudo systemctl apt-get podman usermod loginctl tailscale
#                 curl mountpoint git goose sleep date
#                 They model a host. Nothing real happens.
#
#   PASSTHROUGH   ln mv cp rm rmdir install chmod mkdir
#                 Record the argv, then exec the REAL binary. This is what puts
#                 `ln -sfnT` in the log so the -T constraint is assertable,
#                 while leaving install_template's no-clobber, the .superseded
#                 rename and every symlink semantic REAL rather than modelled.
#                 A modelled `mv` could not tell you that `ln -sfnT` onto a
#                 surviving directory is an error, which is the entire content
#                 of that constraint.
#
#   NOT SHIMMED   seq head grep cmp ls stat id date basename readlink find sed
#                 cat wc tr sort env bash sh dirname mktemp diff comm
#                 Resolved from a minimal PATH the harness builds. A name that
#                 is neither shimmed nor in that PATH exits 127 mid-run, which
#                 is the point: an unmodelled dependency surfaces as a failure
#                 rather than as a silent pass.
#
# `sleep` IS SHIMMED AND RETURNS IMMEDIATELY. deploy-vps.sh's /status wait is
# 45 attempts of `sleep 2`; without this, the one assertion that proves the
# deploy blocks on /status costs 90 seconds of CI wall clock every run.
#
# WHAT A GREEN RUN PROVES: the exact sequence and argv of every privileged
# command; which files landed where, byte-identical, because install/cp are
# real; symlink and .superseded semantics; re-run behaviour; exit codes and
# which traps fired.
# WHAT IT CANNOT PROVE, and no amount of work here would: that podman, apt or
# systemd behave as modelled on a real Ubuntu; that `podman build` succeeds or
# that the image runs; that `systemctl enable --now` on a stale unit is a
# no-op (it can only assert that the reload was ISSUED); that rootless subuid
# ranges or `loginctl enable-linger` work; anything at all about a real remote
# host. See scripts/verify/test-deploy-vps.sh's header for the exact claim.
set -euo pipefail

FAKE_HOST_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

die() { echo "fake-host: $*" >&2; exit 97; }

# THE PATH SPLIT, and it is not housekeeping. This script is reached THROUGH a
# shim directory that is first on the caller's PATH and contains shims named
# mkdir, mv, rm, cp, ln, chmod and install -- so a bare `mkdir` in here would
# re-enter this file, log a line the script under test never asked for, and (with
# the lying-mv sentinel armed) corrupt this fake's own state with the lie it is
# supposed to be telling the caller. So: fake-host.sh runs on a REAL system
# PATH, and hands the caller's PATH back only where a shim is what must be
# found -- `sudo`'s exec.
CALLER_PATH="$PATH"
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

# LINUX ONLY, and it is refused here as well as in test-deploy-vps.sh so that a
# hand-run `--materialise` on a Mac fails with the reason rather than producing
# shims that cannot work.
case "$(uname -s)" in
  Linux) ;;
  *) echo "fake-host.sh is Linux-only (needs GNU ln -T and stat -c). Run it in CI or a container." >&2; exit 2 ;;
esac

# ---------------------------------------------------------- materialise ----
if [ "${1:-}" = "--materialise" ] || [ "${1:-}" = "--deny-wall" ]; then
  MODE="$1"; shift
  [ "$#" -ge 1 ] || die "$MODE needs a directory"
  OUT="$1"; shift
  [ "$#" -ge 1 ] || die "$MODE needs at least one name"
  mkdir -p "$OUT"
  for name in "$@"; do
    if [ "$MODE" = "--deny-wall" ]; then
      # The wall. `${0##*/}` again, and $PAI_DENY_LOG required: a deny shim
      # that cannot record is an empty log, and an empty log is what every
      # "nothing was called" assertion checks for.
      cat >"$OUT/$name" <<'DENY'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "${PAI_DENY_LOG:?fake-host deny shim: PAI_DENY_LOG is required}"
exit 127
DENY
    else
      # shellcheck disable=SC2016
      # ^ `${0##*/}` and `"$@"` are for the SHIM to expand at ITS runtime, not
      # for this printf. That is the whole trick: one file, one behaviour per
      # basename.
      printf '#!/bin/sh\nexec "%s" "${0##*/}" "$@"\n' "$FAKE_HOST_SELF" >"$OUT/$name"
    fi
    chmod 755 "$OUT/$name"
  done
  exit 0
fi

# ------------------------------------------------------------- interlocks --
# Required, with no defaults: a fake that invents a path is a fake that can
# write somewhere real.
: "${PAI_FAKE_ROOT:?fake-host: PAI_FAKE_ROOT is required}"
: "${PAI_HOST_LOG:?fake-host: PAI_HOST_LOG is required}"
: "${PAI_HOST_STATE:?fake-host: PAI_HOST_STATE is required}"
: "${PAI_HOST_SHIMS:?fake-host: PAI_HOST_SHIMS is required}"

# THE HOME INTERLOCK, checked before the dispatch so it fires on the FIRST
# routed call rather than after the first mutation.
case "$HOME" in
  "$PAI_FAKE_ROOT"/*) ;;
  *) die "HOME ($HOME) is not under PAI_FAKE_ROOT ($PAI_FAKE_ROOT)" ;;
esac

[ "$#" -gt 0 ] || die "no command given"
NAME="$1"; shift

# --------------------------------------------------------------- helpers ---
# Every recorded path has $PAI_FAKE_ROOT collapsed to @ROOT@. That is what
# makes the pre-carve/post-carve differential possible at all: the two runs
# live in two different sandboxes, so an un-normalised log differs on every
# single line and `comm` reports the whole file as changed.
# REDACTION IS NOT OPTIONAL. deploy-vps.sh passes GOOSE_SERVER__SECRET_KEY to
# curl as `-H "X-Secret-Key: $GOOSE_SERVER__SECRET_KEY"`, so an un-redacted
# recorder writes a live shared secret into a log file that assertion failures
# then print. The 32+-hex arm is the belt to that braces: every fixture value
# test-deploy-vps.sh generates is `openssl rand -hex`, and nothing else this
# deploy passes on a command line is a long hex string.
redact() {
  local w="$1"
  case "$w" in
    "X-Secret-Key: "*) printf 'X-Secret-Key: @REDACTED@'; return 0 ;;
  esac
  case "$w" in
    *[!0-9a-fA-F]*|"") ;;
    *) if [ "${#w}" -ge 32 ]; then printf '@HEX@'; return 0; fi ;;
  esac
  printf '%s' "${w//"$PAI_FAKE_ROOT"/@ROOT@}"
}

record() {
  if [ -n "${PAI_HOST_QUIET:-}" ]; then
    return 0
  fi
  local line="" w
  for w in "$@"; do
    line="$line $(redact "$w")"
  done
  printf '%s\n' "${line# }" >>"$PAI_HOST_LOG"
}

# state_has <file> <line> / state_add / state_del — the tiny systemd model.
state_has() { [ -f "$PAI_HOST_STATE/$1" ] && grep -qxF "$2" "$PAI_HOST_STATE/$1"; }
state_add() {
  mkdir -p "$PAI_HOST_STATE"
  state_has "$1" "$2" || printf '%s\n' "$2" >>"$PAI_HOST_STATE/$1"
}
state_del() {
  [ -f "$PAI_HOST_STATE/$1" ] || return 0
  grep -vxF "$2" "$PAI_HOST_STATE/$1" >"$PAI_HOST_STATE/$1.tmp" || true
  cat "$PAI_HOST_STATE/$1.tmp" >"$PAI_HOST_STATE/$1"
}
armed() { [ -e "$PAI_HOST_STATE/$1" ]; }

# real_bin <name> — the passthrough half. Resolved from a fixed list of system
# directories rather than from PATH, because PATH is the shim directory.
real_bin() {
  local d
  for d in /usr/bin /bin /usr/sbin /sbin; do
    if [ -x "$d/$1" ]; then printf '%s' "$d/$1"; return 0; fi
  done
  die "no real '$1' under /usr/bin:/bin:/usr/sbin:/sbin"
}

passthrough() {
  local real
  record "$NAME" "$@"
  real="$(real_bin "$NAME")"
  exec "$real" "$@"
}

# ------------------------------------------------------------- dispatch ----
case "$NAME" in

  # ---- sudo: record the WHOLE line, then run the rest without a second
  # record. One log line per privileged call, so `index(...)` assertions read
  # the way the script reads.
  sudo)
    [ "$#" -gt 0 ] || die "sudo with no command"
    record sudo "$@"
    export PAI_HOST_QUIET=1
    PATH="$CALLER_PATH"
    exec "$@"
    ;;

  # ---- systemd. `cat` is the existence test deploy-vps.sh uses, so it is
  # answered from $PAI_SYSTEMD_DIR and not from a state file: a unit file the
  # deploy just installed must become visible to it.
  systemctl)
    record systemctl "$@"
    : "${PAI_SYSTEMD_DIR:?fake-host: PAI_SYSTEMD_DIR is required for systemctl}"
    [ "$#" -ge 1 ] || die "systemctl with no subcommand"
    sub="$1"; shift
    case "$sub" in
      daemon-reload)
        [ "$#" -eq 0 ] || die "unhandled systemctl daemon-reload argv: $*"
        ;;
      cat)
        [ "$#" -eq 1 ] || die "unhandled systemctl cat argv: $*"
        if [ -f "$PAI_SYSTEMD_DIR/$1" ]; then
          cat "$PAI_SYSTEMD_DIR/$1"
        else
          echo "No files found for $1." >&2
          exit 1
        fi
        ;;
      is-enabled|is-active)
        quiet=no
        if [ "${1:-}" = "--quiet" ]; then quiet=yes; shift; fi
        [ "$#" -eq 1 ] || die "unhandled systemctl $sub argv: $*"
        file=systemd-enabled; [ "$sub" = "is-enabled" ] || file=systemd-active
        if state_has "$file" "$1"; then
          [ "$quiet" = "yes" ] || echo "${sub#is-}"
        else
          [ "$quiet" = "yes" ] || echo "disabled"
          exit 1
        fi
        ;;
      enable|disable)
        now=no
        if [ "${1:-}" = "--now" ]; then now=yes; shift; fi
        [ "$#" -eq 1 ] || die "unhandled systemctl $sub argv: $*"
        # Real systemctl refuses to enable a unit whose file it cannot find.
        # Modelled, because "enable a unit that was never installed" is a
        # failure the carve could plausibly introduce.
        [ -f "$PAI_SYSTEMD_DIR/$1" ] || { echo "Failed to enable unit: Unit file $1 does not exist." >&2; exit 1; }
        if [ "$sub" = "enable" ]; then
          state_add systemd-enabled "$1"
          [ "$now" = "no" ] || state_add systemd-active "$1"
        else
          state_del systemd-enabled "$1"
          [ "$now" = "no" ] || state_del systemd-active "$1"
        fi
        ;;
      start|restart)
        [ "$#" -eq 1 ] || die "unhandled systemctl $sub argv: $*"
        [ -f "$PAI_SYSTEMD_DIR/$1" ] || { echo "Failed to $sub unit: Unit file $1 does not exist." >&2; exit 1; }
        state_add systemd-active "$1"
        ;;
      stop)
        [ "$#" -eq 1 ] || die "unhandled systemctl stop argv: $*"
        state_del systemd-active "$1"
        ;;
      *) die "unhandled systemctl subcommand: $sub $*" ;;
    esac
    ;;

  # ---- apt. The `install` arm MATERIALISES the podman shim, so `command -v
  # podman` is false on run 1 and true on run 2 -- which is what makes the
  # "a re-run does no apt-get install" assertion mean something.
  apt-get)
    record apt-get "$@"
    case "$*" in
      "update -qq") ;;
      "install -y -qq podman uidmap slirp4netns")
        "$FAKE_HOST_SELF" --materialise "$PAI_HOST_SHIMS" podman
        ;;
      *) die "unhandled apt-get argv: $*" ;;
    esac
    ;;

  podman)
    record podman "$@"
    case "${1:-}" in
      --version) echo "podman version 4.9.3" ;;
      build)
        # deploy-vps.sh:  podman build -q -t code-agent:local -f <file> <ctx>
        [ "$#" -eq 7 ] && [ "$2" = "-q" ] && [ "$3" = "-t" ] && [ "$5" = "-f" ] \
          || die "unhandled podman build argv: $*"
        if armed podman-build-fails; then
          echo "Error: building at STEP \"RUN\": exit status 1" >&2
          exit 1
        fi
        img="${4//:/_}"; img="${img//\//_}"
        mkdir -p "$PAI_HOST_STATE/images"
        : >"$PAI_HOST_STATE/images/$img"
        ;;
      image)
        [ "$#" -eq 3 ] && [ "$2" = "exists" ] || die "unhandled podman image argv: $*"
        img="${3//:/_}"; img="${img//\//_}"
        [ -e "$PAI_HOST_STATE/images/$img" ] || exit 1
        ;;
      *) die "unhandled podman argv: $*" ;;
    esac
    ;;

  usermod)
    record usermod "$@"
    case "$*" in
      "--add-subuids 100000-165535 --add-subgids 100000-165535 agent")
        printf 'agent:100000:65536\n' >>"${PAI_SUBUID_FILE:?fake-host: PAI_SUBUID_FILE is required for usermod}" ;;
      *) die "unhandled usermod argv: $*" ;;
    esac
    ;;

  loginctl)
    record loginctl "$@"
    case "$*" in
      "enable-linger agent") ;;
      *) die "unhandled loginctl argv: $*" ;;
    esac
    ;;

  tailscale)
    record tailscale "$@"
    case "$*" in
      "ip -4") echo "100.64.0.1" ;;
      *) die "unhandled tailscale argv: $*" ;;
    esac
    ;;

  # ---- curl. Fails by default. `/status answers` is an ARMED state, so the
  # "deploy blocks on /status" assertion runs against the real 45-attempt loop
  # rather than against a fake that always says yes.
  curl)
    record curl "$@"
    armed curl-ok || exit 7
    ;;

  mountpoint)
    record mountpoint "$@"
    [ "$#" -eq 2 ] && [ "$1" = "-q" ] || die "unhandled mountpoint argv: $*"
    [ -d "$2" ] || exit 1
    ;;

  git)
    record git "$@"
    # deploy-vps.sh only ever runs `git -C <dir> pull --ff-only` here: the
    # clone arm needs a REPO_URL, and the harness always seeds a .git directory
    # so the pull arm is the one that runs.
    [ "$#" -eq 4 ] && [ "$1" = "-C" ] && [ "$3" = "pull" ] && [ "$4" = "--ff-only" ] \
      || die "unhandled git argv: $*"
    ;;

  # ---- goose. Only the schedule surface register-schedules.sh uses.
  goose)
    record goose "$@"
    case "${1:-}" in
      --version) echo "goose 1.46.0" ;;
      schedule)
        shift
        case "${1:-}" in
          list)
            if [ -f "$PAI_HOST_STATE/schedules" ]; then cat "$PAI_HOST_STATE/schedules"; fi
            ;;
          --help) echo "Usage: goose schedule <add|list|remove|sessions|run-now|cron-help>" ;;
          add)
            # The V9 sentinel: one failing unit body, to prove the ERR trap
            # attributes it to `automations` rather than to line 780.
            if armed goose-add-fails; then
              echo "Error: failed to add schedule" >&2
              exit 1
            fi
            [ "${2:-}" = "--schedule-id" ] || die "unhandled goose schedule add argv: $*"
            state_add schedules "$3"
            ;;
          remove)
            [ "${2:-}" = "--schedule-id" ] || die "unhandled goose schedule remove argv: $*"
            state_del schedules "$3"
            ;;
          *) die "unhandled goose schedule argv: $*" ;;
        esac
        ;;
      *) die "unhandled goose argv: $*" ;;
    esac
    ;;

  sleep)
    record sleep "$@"
    ;;

  # ---- date. Only the one format deploy-vps.sh asks for is overridable, and
  # only when the harness has pinned it: $STAMP feeds the `.superseded.<stamp>`
  # names, and two runs that straddle a second boundary would differ there for
  # a reason that has nothing to do with the carve.
  date)
    record date "$@"
    if [ "$*" = "+%Y%m%d%H%M%S" ] && [ -f "$PAI_HOST_STATE/fixed-date" ]; then
      cat "$PAI_HOST_STATE/fixed-date"
    else
      exec "$(real_bin date)" "$@"
    fi
    ;;

  # ---- the passthroughs. Two of them can be told to LIE, which is the only
  # way to reach deploy-vps.sh's two `|| fail` arms: through the script's own
  # control flow they are unreachable, because a successful mv/rm always
  # removes the source. See test-deploy-vps.sh V3b.
  mv)
    if armed lie-mv; then
      record mv "$@"
      # "Copied but did not remove the source" -- a cross-device mv that
      # copied and then failed to unlink. deploy-vps.sh only ever mv's one
      # thing to one place, so two arguments is the whole model.
      [ "$#" -eq 2 ] || die "lying mv models two arguments only: $*"
      cp -a "$1" "$2"
      exit 0
    fi
    passthrough "$@"
    ;;
  rm)
    if armed lie-rm; then
      record rm "$@"
      exit 0
    fi
    passthrough "$@"
    ;;
  ln|cp|rmdir|install|chmod|mkdir)
    passthrough "$@"
    ;;

  *)
    die "unhandled command: $NAME $*"
    ;;
esac
