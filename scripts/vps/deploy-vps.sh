#!/usr/bin/env bash
# deploy-vps.sh — deploy (and later upgrade) the brain's stack. Run ON the
# VPS as user `agent`, after scripts/vps/luks-setup.sh has created /data and
# /data/secrets.env has been filled in (docs/setup/50-vps-brain.md §4-6).
#
# Idempotent — re-running is the upgrade path: it pulls the repo, refreshes
# configs (never clobbering local state), reinstalls units, restarts
# goose-serve, and re-registers the schedule roster.
#
# FOUR OF THE ADD-ONS ARE UNITS: unit_google_workspace, unit_telegram_gateway,
# unit_code_agents and unit_automations, each the installer named by a manifest
# in config/units/ (`installer.function`), each gated by --with/--without/--only
# and each defined immediately above its one call site. `--without code-agents`
# is the one that pays for itself: selected, it apt-installs podman and grants a
# subuid range ONCE (both are guarded), then enables linger and runs a
# multi-minute `podman build` on EVERY deploy — for a feature it may never use.
#
# THE BRAIN CORE IS NOT A UNIT AND IS NOT SELECTABLE. The path-root migration,
# the goose config install, the systemd unit files, `goose-serve` and the
# /status gate are eight non-contiguous regions interleaved with the four units
# above; wrapping them in one unit_brain() would either reorder the deploy or
# hand every future author a function that silently must not be skipped. Every
# selective run says so on stdout, and config/units/brain.yaml records it as a
# blocker rather than leaving it in nobody's head.
set -euo pipefail
# errtrace. REQUIRED, not tidiness: without it an ERR trap is NOT inherited by
# shell functions, and every unit body below is a function — so the attribution
# in on_unit_err() would never print for the only failures it exists to name.
set -E

# --------------------------------------------------------------- the seam --
# PAI_* — TESTING ONLY. Never set any of these on a real brain.
#
# This script's whole job is side effects on a host, and until this block
# existed nothing could execute a line of it: seven absolute roots were baked
# in as literals. They are now overridable, so scripts/verify/test-deploy-vps.sh
# can run the entire deploy inside a throwaway directory against
# scripts/verify/fake-host.sh. UNSET, every one of them expands to exactly the
# literal it replaced — a real deploy is unchanged.
#
# The gate below is the interlock, and it is three independent refusals
# (fake-exec.sh:28-34's rule, which test-base-install.sh A15/A16 already prove
# fires on the first routed call):
#   1. PAI_FAKE_ROOT set  -> every root must be lexically under it,
#   2. ...including $HOME, because the migration writes ~/.config/goose,
#      ~/.local/share/goose and ~/.local/state/goose whether or not any other
#      root moved, and
#   3. any PAI_* root set WITHOUT PAI_FAKE_ROOT is refused outright, so a stray
#      `export PAI_DATA_ROOT=/tmp/x` in a shell profile cannot half-contain a
#      real deploy.
PAI_FAKE_ROOT="${PAI_FAKE_ROOT:-}"
REPO_DIR="${PAI_REPO_DIR:-/home/agent/personal-ai-setup}"
DATA_ROOT="${PAI_DATA_ROOT:-/data}"
SYSTEMD_DIR="${PAI_SYSTEMD_DIR:-/etc/systemd/system}"
# Hoisted from its old home just above the `-x` probe further down. It is a
# plain assignment with no command substitution, so moving it above the
# preflight changes nothing about what runs — but the containment gate has to
# see it, and a root the gate cannot see is a root that is not contained.
GOOSE_BIN="${PAI_GOOSE_BIN:-/home/agent/.local/bin/goose}"
# /etc/subuid is READ, never written — but it decides whether `usermod
# --add-subuids` runs at all, so leaving it pointing at the real file would
# make the code-agents containment claim false on any Linux box that already
# happens to carry an `agent:` line.
SUBUID_FILE="${PAI_SUBUID_FILE:-/etc/subuid}"

SECRETS_FILE="$DATA_ROOT/secrets.env"
# GOOSE_PATH_ROOT: one absolute root holding goose's config/, data/ AND
# state/ (goose-serve.service sets the same value). LEGACY_DATA_DIR is where
# data/ alone used to live, before state/ — the llm_request logs — was found
# sitting on the unencrypted root disk.
GOOSE_ROOT="$DATA_ROOT/goose"
LEGACY_DATA_DIR="$DATA_ROOT/goose-data"
WMCP_ROOT="$DATA_ROOT/workspace-mcp"
CODE_AGENTS_ROOT="$DATA_ROOT/code-agents"
GOOSE_CONFIG_DIR="$HOME/.config/goose"
SERVE_PORT=3284

# ------------------------------------------------------- the unit selection
# A space-delimited string, matched with `case " $SELECTED " in *" $id "*)`,
# and NOT a `declare -A`. This file is bash-3.2-clean and stays that way: an
# associative array, `mapfile` or `${x,,}` would work on the Ubuntu brain and
# break the moment anyone runs it under /bin/bash on a Mac, and nothing in CI
# here would catch it.
#
# THE ORDER IS THE CALL ORDER, and the --dry-run plan prints it in this order.
UNIT_IDS="google-workspace telegram-gateway code-agents automations"
SELECTED="$UNIT_IDS"
# Set by want(), cleared by completed(), read by on_unit_err(). Top-level
# globals on purpose — see the note above resume_goose_units about what `local`
# does to a variable an EXIT trap reads.
CURRENT_UNIT=""
DONE_UNITS=""
ERR_REPORTED=0

usage() {
  cat <<'EOF'
Usage: deploy-vps.sh [--with ID] [--without ID] [--only ID] [--dry-run] [REPO_URL]

Deploys/upgrades the brain: repo clone or pull, migration of goose's
config/data/state onto the encrypted volume (GOOSE_PATH_ROOT=/data/goose),
goose config install, systemd units, goose-serve start, schedule
registration. REPO_URL (or the REPO_URL env var) is only needed for the
first-ever clone if the repo is not already at /home/agent/personal-ai-setup,
e.g.:

  deploy-vps.sh https://github.com/<your-github-username>/personal-ai-setup.git

Selectable units (all of them are on by default):

  google-workspace   ~/.google_workspace_mcp -> /data/workspace-mcp
  telegram-gateway   goose-telegram-gateway.service, enabled when the token is set
  code-agents        rootless podman, the code-agent:local image, /data/code-agents
                     and code-agent-manager.service. This is the expensive one:
                     a first-deploy apt install, then an image build per deploy.
  automations        register-schedules.sh — the goose scheduler roster

  --with ID       select ID. A NO-OP today, because every unit is already on by
                  default; it exists so the flag surface matches the Mac
                  installer's. `--with X --without X` warns and DESELECTS X —
                  deselection is the safe direction to lose an argument in.
  --without ID    deselect ID
  --only ID       select exactly ID (repeat, or comma-separate, for several).
                  Not combinable with --with/--without.
  --dry-run       print the plan and exit 0 without touching anything

THE BRAIN CORE IS NOT SELECTABLE. The path-root migration, the goose config
install, the systemd unit files, the goose-serve restart and the /status gate
run on every invocation, including `--only automations`. There is no flag that
skips them and there should not be: everything else depends on them.

Prerequisites: /data mounted (luks-setup.sh / luks-unlock.sh) and
/data/secrets.env filled in (chmod 600).
EOF
}

fail() { echo "ERROR: $*" >&2; exit 1; }
# Usage errors exit 2, the convention every other entry point here follows
# (bootstrap-mac.sh, check-units.sh, cli.sh's `2 == precondition/usage`).
die_usage() { echo "deploy-vps.sh: $*" >&2; usage >&2; exit 2; }

# ------------------------------------------------------------- arguments --
WITH_IDS=""; WITHOUT_IDS=""; ONLY_IDS=""; ONLY_GIVEN=0; DRY_RUN=0; SELECTIVE=0
REPO_URL_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --with|--without|--only)
      [ "$#" -ge 2 ] || die_usage "$1 needs a unit id"
      # Commas are accepted as well as repetition, because `--only a,b` is what
      # everyone types first and a silent "unknown unit 'a,b'" is a worse
      # answer than either.
      case "$1" in
        --with)    WITH_IDS="$WITH_IDS $(echo "$2" | tr ',' ' ')" ;;
        --without) WITHOUT_IDS="$WITHOUT_IDS $(echo "$2" | tr ',' ' ')" ;;
        --only)    ONLY_IDS="$ONLY_IDS $(echo "$2" | tr ',' ' ')"; ONLY_GIVEN=1 ;;
      esac
      SELECTIVE=1
      shift 2 ;;
    --*) die_usage "unknown argument: $1" ;;
    *)
      [ -z "$REPO_URL_ARG" ] || die_usage "more than one REPO_URL given"
      REPO_URL_ARG="$1"; shift ;;
  esac
done
REPO_URL="${REPO_URL_ARG:-${REPO_URL:-}}"

# Every named id must be a known one. A typo like `--without code-agent` that
# silently installed podman anyway is the whole reason this is exit 2 and not a
# warning.
for id in $WITH_IDS $WITHOUT_IDS $ONLY_IDS; do
  case " $UNIT_IDS " in
    *" $id "*) ;;
    *) die_usage "unknown unit '$id'; known units: $UNIT_IDS" ;;
  esac
done

if [ "$ONLY_GIVEN" -eq 1 ]; then
  [ -z "$WITH_IDS$WITHOUT_IDS" ] || die_usage "--only cannot be combined with --with/--without"
  SELECTED=""
  for id in $UNIT_IDS; do
    case " $ONLY_IDS " in
      *" $id "*) SELECTED="$SELECTED $id" ;;
    esac
  done
else
  SELECTED=""
  for id in $UNIT_IDS; do
    # `|| continue`, never `[ cond ] && action` as a loop's last statement: the
    # for-loop inherits the status of its final command, and a false `&&` list
    # on the last iteration makes the whole loop — and under `set -e` the whole
    # script — fail after having done all of its work.
    case " $WITHOUT_IDS " in
      *" $id "*)
        case " $WITH_IDS " in
          *" $id "*) echo "WARNING: '$id' is named by both --with and --without; --without wins (use --only $id to select it alone)." >&2 ;;
        esac
        continue ;;
    esac
    SELECTED="$SELECTED $id"
  done
fi
# Trim the leading space so `--dry-run`'s plan and the error attribution read
# as a list rather than as a ragged one.
SELECTED="${SELECTED# }"

if [ "$SELECTIVE" -eq 1 ]; then
  echo "==> units selected: ${SELECTED:-(none)}"
  echo "    note: the brain core (migration, goose config, goose-serve, /status)"
  echo "          is not selectable and always runs."
fi

# --------------------------------------------------- seam containment gate
# BEFORE the preflight, on purpose: the preflight already probes $DATA_ROOT and
# reads $SECRETS_FILE, so a gate placed after it would have let a half-set
# environment touch the real host before refusing.
if [[ -n "$PAI_FAKE_ROOT" ]]; then
  for pai_root in "$REPO_DIR" "$DATA_ROOT" "$SYSTEMD_DIR" "$GOOSE_BIN" "$SUBUID_FILE" "$HOME"; do
    case "$pai_root" in
      "$PAI_FAKE_ROOT"/*) ;;
      *) fail "PAI_FAKE_ROOT is set but '$pai_root' is not under it.
       Refusing to run: a half-contained test seam writes to the real host." ;;
    esac
  done
  unset pai_root
elif [[ -n "${PAI_REPO_DIR:-}${PAI_DATA_ROOT:-}${PAI_SYSTEMD_DIR:-}${PAI_GOOSE_BIN:-}${PAI_SUBUID_FILE:-}" ]]; then
  fail "a PAI_* root is set without PAI_FAKE_ROOT.
       These variables exist only for scripts/verify/test-deploy-vps.sh, and
       they are refused unless the whole tree is contained under one root."
fi

# ------------------------------------------------------- the unit gate ----
# want <id> — the FIRST executable line of every unit body, as `want <id> ||
# return 0`. It also records which unit is running, for on_unit_err().
want() {
  case " $SELECTED " in
    *" $1 "*) CURRENT_UNIT="$1"; return 0 ;;
  esac
  echo "==> skipping $1 (deselected)"
  return 1
}

# completed <id> — the line AFTER every call site. It runs only if the unit
# returned 0, because errexit aborts otherwise, which is exactly what makes
# $DONE_UNITS mean "completed" rather than "attempted". Ends in an assignment
# (always exit 0), never in a `[ ... ]` test.
completed() {
  case " $SELECTED " in
    *" $1 "*) DONE_UNITS="$DONE_UNITS $1" ;;
  esac
  CURRENT_UNIT=""
}

# on_unit_err — attribution, and the honest answer to "one clear failure per
# unit rather than one exit code for six features".
#
# It does NOT continue past a failed unit, and that is deliberate. Continuing
# needs `unit_x || rc=$?` at the call site, which (a) is the errexit-disabling
# shape the rules above forbid, (b) breaks units_lint.py's P3 call count, and
# (c) is unsafe here in a way it is not on the Mac: the brain core is a
# prerequisite for everything after it, so "carry on" would mean carrying on
# with a stopped goose-serve and a half-migrated /data/goose.
#
# The summary has to live INSIDE this trap. errexit aborts at the failing call
# site, so nothing printed after it ever runs, and `trap - EXIT` further down
# means the EXIT trap is gone for the tail of the script.
on_unit_err() {
  local rc=$?
  # Bash fires ERR once for the failing command and again for each enclosing
  # function that inherits its status, so without this the message prints twice
  # and the second copy names the same unit.
  [ "$ERR_REPORTED" -eq 0 ] || return 0
  ERR_REPORTED=1
  [ -n "$CURRENT_UNIT" ] || return 0
  local pending="" id
  for id in $UNIT_IDS; do
    case " $SELECTED " in
      *" $id "*) ;;
      *) continue ;;
    esac
    case " $DONE_UNITS $CURRENT_UNIT " in
      *" $id "*) continue ;;
    esac
    pending="$pending $id"
  done
  echo "ERROR: unit '$CURRENT_UNIT' failed (exit $rc)." >&2
  echo "       completed:${DONE_UNITS:- (none)}" >&2
  echo "       not reached:${pending:- (none)}" >&2
  echo "       Re-run just that unit with: deploy-vps.sh --only $CURRENT_UNIT" >&2
  return 0
}
trap on_unit_err ERR

# --------------------------------------------------------------- dry run --
# ABOVE the preflight and above every mutation, not "the gate returns 1".
# The brain core is ungateable, so a dry-run that only silenced the four unit
# bodies would still stop both goose units, migrate three directories, install
# seven unit files and restart goose-serve — writing most of a deploy while
# printing the word "dry". bootstrap-mac.sh:392-424 exits above its platform
# guard at :426 for the same reason.
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "==> deploy-vps.sh --dry-run: nothing below this line ran, and nothing was written."
  echo "    always runs: brain core (path-root migration, goose config, systemd unit"
  echo "                 files, goose-serve restart, /status gate)"
  for id in $UNIT_IDS; do
    case " $SELECTED " in
      *" $id "*) echo "    run:  $id" ;;
      *)         echo "    skip: $id" ;;
    esac
  done
  exit 0
fi

# ---------------------------------------------------------------- preflight
[[ $(id -u) -ne 0 ]] || fail "run as the 'agent' user, not root (the script sudos only where needed)."
[[ "$(id -un)" == "agent" ]] || echo "WARNING: expected to run as 'agent', running as '$(id -un)'." >&2

if ! mountpoint -q "$DATA_ROOT"; then
  fail "$DATA_ROOT is not mounted. First boot: run 'sudo $REPO_DIR/scripts/vps/luks-setup.sh --device <path>'.
       After a reboot: run 'sudo $REPO_DIR/scripts/vps/luks-unlock.sh'."
fi

if [[ ! -f "$SECRETS_FILE" ]]; then
  fail "$SECRETS_FILE does not exist. Create it on the encrypted volume:
         cp $REPO_DIR/config/env/secrets.env.example $SECRETS_FILE
         chmod 600 $SECRETS_FILE
       then fill in every value (docs/setup/50-vps-brain.md §4)."
fi

PERMS="$(stat -c %a "$SECRETS_FILE")"
if [[ "$PERMS" != "600" ]]; then
  echo "==> Fixing $SECRETS_FILE permissions ($PERMS -> 600)"
  chmod 600 "$SECRETS_FILE"
fi

# Load the secrets for validation and for the /status probe below. Values are
# never echoed.
set -a
# shellcheck disable=SC1090
source "$SECRETS_FILE"
set +a

MISSING=()
for var in OPENCODE_ZEN_API_KEY TOGETHER_API_KEY GOOSE_SERVER__SECRET_KEY NTFY_TOPIC; do
  [[ -n "${!var:-}" ]] || MISSING+=("$var")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  fail "required variables empty in $SECRETS_FILE: ${MISSING[*]}
       Fill them in (see config/env/secrets.env.example for what each is)."
fi
for var in GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET; do
  [[ -n "${!var:-}" ]] || echo "WARNING: $var is empty — the Gmail/Calendar extension and the admin recipes will fail until it is set (docs/setup/30-google-oauth.md)." >&2
done

[[ -x "$GOOSE_BIN" ]] || command -v goose >/dev/null || \
  fail "goose CLI not found at $GOOSE_BIN — cloud-init should have installed it (infra/terraform/templates/cloud-init.yaml.tftpl). Reinstall with the pinned installer from that file."
command -v tailscale >/dev/null || fail "tailscale CLI not found — cloud-init should have installed and joined the tailnet."

# ---------------------------------------------------------- repo clone/pull
if [[ -d "$REPO_DIR/.git" ]]; then
  echo "==> Updating repo at $REPO_DIR"
  git -C "$REPO_DIR" pull --ff-only
else
  if [[ -z "$REPO_URL" || "$REPO_URL" == *"<"* ]]; then
    fail "repo not found at $REPO_DIR and no REPO_URL given.
         Pass your fork's clone URL:
           deploy-vps.sh https://github.com/<your-github-username>/personal-ai-setup.git"
  fi
  echo "==> Cloning $REPO_URL to $REPO_DIR"
  git clone "$REPO_URL" "$REPO_DIR"
fi

# ------------------------------------------- goose path root (encrypted)
# goose keeps THREE directories, and until this block existed only one of
# them was on the LUKS volume:
#   config/  config.yaml, .goosehints, memory/, secrets.yaml (0600)
#   data/    sessions.db (the whole chat history), schedule.json
#   state/   logs/llm_request.*.jsonl — the raw request and response bodies
#            exchanged with inference providers
# GOOSE_PATH_ROOT=/data/goose relocates all three together (verified against
# goose 1.46.0) and is set in goose-serve.service. This block migrates an
# existing brain into that layout: it never deletes session history, and
# re-running it is a no-op.
#
# The symlinks matter as much as the env var. `goose` invoked from an SSH
# session — check-brain.sh, `goose schedule run-now`, register-schedules.sh —
# does NOT inherit the systemd unit's environment, so without them the CLI
# and the service would read different config.yaml files and different
# schedule.json files. With them, both paths land in /data/goose either way.
echo "==> Migrating goose config/data/state onto the encrypted volume ($GOOSE_ROOT)"

# No goose process may be running while its directories move underneath it,
# and `Restart=always` means a crash-looping unit could start back up mid-move
# — so stop unconditionally whenever the unit exists, rather than testing
# is-active (which is false for a unit in `activating`). `systemctl cat` is the
# reliable "does this unit exist" test; stopping an already-stopped unit is a
# no-op.
#
# BOTH long-running goose units are stopped, not just the server: the telegram
# gateway is a full goose process with the same GOOSE_PATH_ROOT, so leaving it
# up would have it writing sessions and llm_request logs into directories that
# are being moved out from under it.
#
# Hundreds of lines separate this stop from the restart at the end (config
# install, systemd units, podman build, schedule registration) and the script
# runs under `set -e`. Without a trap, a failure anywhere in between — an
# apt-get hiccup, a podman build error — would leave the brain OFFLINE with
# nothing but a stack of output to say so. The EXIT trap brings back whatever
# was running on ANY exit path; it is cleared just before the intentional
# restart at the end.
# TOP LEVEL, and it must stay there. This trap fires OUTSIDE every unit body,
# so a `local GATEWAY_WAS_ENABLED` inside one would leave the test below
# reading an unbound variable under `set -u` — the trap would die after
# goose-serve had been started and before the gateway was, on the one path
# where nobody is watching. Same rule as install_template and migrate_into_root.
GATEWAY_WAS_ENABLED=0
resume_goose_units() {
  sudo systemctl start goose-serve.service >/dev/null 2>&1 || true
  if [[ "$GATEWAY_WAS_ENABLED" -eq 1 ]]; then
    sudo systemctl start goose-telegram-gateway.service >/dev/null 2>&1 || true
  fi
}

if systemctl cat goose-telegram-gateway.service >/dev/null 2>&1; then
  # is-ENABLED, not is-active: an enabled unit that is crash-looping is still
  # one we are obliged to put back. A unit that was never enabled (no
  # TELEGRAM_BOT_TOKEN) must NOT be started by the trap — it would just fail.
  if systemctl is-enabled --quiet goose-telegram-gateway.service 2>/dev/null; then
    GATEWAY_WAS_ENABLED=1
    echo "    stopping goose-telegram-gateway for the migration (restarted at the end of this run)"
  fi
  sudo systemctl stop goose-telegram-gateway.service
fi
if systemctl cat goose-serve.service >/dev/null 2>&1; then
  echo "    stopping goose-serve for the migration (restarted at the end of this run)"
  sudo systemctl stop goose-serve.service
fi
trap resume_goose_units EXIT

STAMP="$(date +%Y%m%d%H%M%S)"
mkdir -p "$GOOSE_ROOT"
chmod 700 "$GOOSE_ROOT"

# --- data/: /data/goose-data is already on the encrypted volume; move it in.
if [[ -d "$LEGACY_DATA_DIR" && ! -L "$LEGACY_DATA_DIR" ]]; then
  if [[ -d "$GOOSE_ROOT/data" && -n "$(ls -A "$GOOSE_ROOT/data" 2>/dev/null)" ]]; then
    # Both hold content — refuse to guess which sessions.db is canonical.
    echo "    NOTE: $GOOSE_ROOT/data already has content; keeping it and moving"
    echo "          $LEGACY_DATA_DIR aside to $LEGACY_DATA_DIR.superseded.$STAMP"
    echo "          (still on /data, so still encrypted — compare sessions.db, then delete)"
    mv "$LEGACY_DATA_DIR" "$LEGACY_DATA_DIR.superseded.$STAMP"
  else
    rmdir "$GOOSE_ROOT/data" 2>/dev/null || true
    mv "$LEGACY_DATA_DIR" "$GOOSE_ROOT/data"
    echo "    moved $LEGACY_DATA_DIR -> $GOOSE_ROOT/data (sessions.db intact, same volume)"
  fi
fi
# Keep the old path working as a symlink: docs, check-brain.sh's local-mode
# detection and any muscle memory still name /data/goose-data.
# -T everywhere in this script: without it, `ln -sfn LINK DIR` where DIR is a
# real directory does not replace the directory — it silently creates
# DIR/<basename> INSIDE it, leaving the original data in place and the caller
# believing the move happened. With -T that case is an error instead.
if [[ ! -e "$LEGACY_DATA_DIR" ]]; then
  ln -sfnT "$GOOSE_ROOT/data" "$LEGACY_DATA_DIR"
fi

# --- config/ and state/: these are on the UNencrypted root disk today.
# Cross-device mv copies then unlinks, which is what gets them off it.
migrate_into_root() {
  local src="$1" dst="$2" what="$3"
  if [[ -L "$src" ]]; then
    # Already a symlink (e.g. ~/.local/share/goose -> /data/goose-data from an
    # earlier deploy): nothing to move. Drop it and let the tail of this
    # function re-create it pointing straight at the canonical path, so we
    # don't leave a two-hop chain through the legacy name.
    if [[ "$(readlink -f "$src")" != "$(readlink -f "$dst" 2>/dev/null || echo "$dst")" ]]; then
      echo "    repointing $src (was $(readlink "$src") — check it holds nothing you need)"
    fi
    rm "$src"
  elif [[ -d "$src" ]]; then
    if [[ -d "$dst" && -n "$(ls -A "$dst" 2>/dev/null)" ]]; then
      echo "    NOTE: $dst already has content — copying only what is missing from $src,"
      echo "          then moving the root-disk copy to $dst.superseded.$STAMP"
      cp -an "$src/." "$dst/" 2>/dev/null || true
      mv "$src" "$dst.superseded.$STAMP"
    else
      rmdir "$dst" 2>/dev/null || true
      mv "$src" "$dst"
      echo "    moved $what off the root disk: $src -> $dst"
    fi
  fi
  mkdir -p "$dst"
  # -T (see above): if $src somehow survived as a real directory — a failed
  # mv, a dir goose recreated mid-run — this must be a hard error. Without -T
  # the link would be created at $src/$(basename $dst) and the root-disk copy
  # would live on, unencrypted, while every check reported success.
  ln -sfnT "$dst" "$src" || fail "$src is still a real directory — refusing to hide it under a symlink.
       Its contents did not move to $dst. Inspect it, move it aside by hand
       (mv '$src' '$src.manual') and re-run this script."
}

mkdir -p "$HOME/.config" "$HOME/.local/share" "$HOME/.local/state"
migrate_into_root "$GOOSE_CONFIG_DIR"          "$GOOSE_ROOT/config" "goose config (config.yaml, .goosehints, memory/, secrets.yaml)"
migrate_into_root "$HOME/.local/state/goose"   "$GOOSE_ROOT/state"  "goose state (llm_request logs: raw provider request/response bodies)"
migrate_into_root "$HOME/.local/share/goose"   "$GOOSE_ROOT/data"   "goose data (sessions.db)"

chmod 700 "$GOOSE_ROOT" "$GOOSE_ROOT/config" "$GOOSE_ROOT/data" "$GOOSE_ROOT/state"
# Every goose CLI call this script makes must use the same root as the
# service, or schedules registered below would land in the wrong schedule.json.
export GOOSE_PATH_ROOT="$GOOSE_ROOT"
echo "    ~/.config/goose, ~/.local/share/goose, ~/.local/state/goose -> $GOOSE_ROOT/{config,data,state} (0700)"
echo "    NOTE: a cross-device move unlinks the root-disk copy but does not wipe"
echo "          the freed blocks. Anything logged before this migration may still"
echo "          be recoverable from the unencrypted disk until it is overwritten."

# --------------------------------------------------------- goose config
# ~/.config/goose is a symlink to /data/goose/config (the block above) — never
# into the repo: goose writes runtime state (rewritten config.yaml, permission
# files, memory/, secrets.yaml) into it, and a symlinked repo dir would end up
# with untracked state and dirty checkouts. Instead we copy the templates once
# and never clobber — if the repo template later diverges from the live file,
# we say so and leave the merge to you.
echo "==> Installing goose config templates into $GOOSE_CONFIG_DIR (-> $GOOSE_ROOT/config)"
mkdir -p "$GOOSE_CONFIG_DIR/custom_providers"

install_template() {
  local src="$1" dst="$2"
  if [[ ! -e "$dst" ]]; then
    cp "$src" "$dst"
    echo "    installed $dst"
  elif ! cmp -s "$src" "$dst"; then
    echo "    NOTE: $dst differs from repo template — not overwriting (goose keeps runtime state in it)."
    echo "          Review and merge by hand:  diff '$dst' '$src'"
  fi
}

install_template "$REPO_DIR/config/goose/config.yaml" "$GOOSE_CONFIG_DIR/config.yaml"
for f in "$REPO_DIR"/config/goose/custom_providers/*.json; do
  install_template "$f" "$GOOSE_CONFIG_DIR/custom_providers/$(basename "$f")"
done
if [[ ! -e "$GOOSE_CONFIG_DIR/.goosehints" ]]; then
  cp "$REPO_DIR/config/goose/goosehints.example" "$GOOSE_CONFIG_DIR/.goosehints"
  echo "    installed $GOOSE_CONFIG_DIR/.goosehints (edit it — it is yours now)"
elif ! cmp -s "$REPO_DIR/config/goose/goosehints.example" "$GOOSE_CONFIG_DIR/.goosehints"; then
  # Yours to edit, so never overwritten — but say so, or template additions
  # (e.g. the multi-account paragraph) silently never reach an existing brain.
  echo "    NOTE: $GOOSE_CONFIG_DIR/.goosehints differs from the repo template — not overwriting."
  echo "          Review new guidance and merge by hand:"
  echo "          diff '$GOOSE_CONFIG_DIR/.goosehints' '$REPO_DIR/config/goose/goosehints.example'"
fi

# --------------------------------------- encrypted workspace-mcp token dir
# FOUR RULES FOR EVERY UNIT BODY BELOW. Each is a measured failure mode of
# `set -euo pipefail`, not a style preference. They are bootstrap-mac.sh's
# rules, and they are written here rather than left to units_lint.py because
# P3 is purely LEXICAL and accepts three of the four violations.
#
#   1. EVERY BODY ENDS IN `return 0`. A function whose last executed command is
#      false returns false, and a bare call to it aborts the whole script. This
#      text sat mid-script with lines after it before the carve, so a false tail
#      was harmless; inside a function it is fatal.
#   2. EVERY CALL SITE IS A BARE COLUMN-0 LINE — never `if unit_x; then`, never
#      `unit_x || rc=$?`. A function called from an `if` condition runs its
#      WHOLE body with errexit disabled. units_lint.py:659 counts `^unit_x$`
#      and would happily accept the `if` form.
#   3. `[ cond ] || continue` inside loops, never `[ cond ] && action` as a
#      loop's last statement — the loop inherits that status and the body then
#      returns false having done all of its work.
#   4. HELPERS AND THE TRAP'S GLOBALS STAY TOP LEVEL. install_template is
#      called from the goose-config block AND from unit_code_agents; a helper
#      defined inside a unit is not defined until that unit has RUN, so a
#      selective install would die at `command not found`. GATEWAY_WAS_ENABLED
#      is the sharp one: make it `local` and the EXIT trap — which fires
#      OUTSIDE the function — hits an unbound variable under `set -u`, dying
#      silently after goose-serve is back but before the gateway is.
#
# workspace-mcp stores its Google OAuth tokens in ~/.google_workspace_mcp/
# (the upstream default as of 2026-08-20). Point that at the encrypted
# volume so the tokens live on /data, never the unencrypted root disk.
# Verify after the first auth: if token files appear elsewhere, adjust here.
unit_google_workspace() {
  want google-workspace || return 0
  # `local` here and not a global: nothing outside this body has ever read it,
  # and unlike GATEWAY_WAS_ENABLED no trap does either.
  local wmcp_link="$HOME/.google_workspace_mcp"
  echo "==> Linking ~/.google_workspace_mcp -> $WMCP_ROOT"
  if [[ -d "$wmcp_link" && ! -L "$wmcp_link" ]]; then
    echo "    migrating existing $wmcp_link onto the encrypted volume"
    mkdir -p "$WMCP_ROOT"
    cp -an "$wmcp_link/." "$WMCP_ROOT/"
    rm -rf "$wmcp_link"
  fi
  mkdir -p "$WMCP_ROOT"
  # -T: the block above removes a real directory here, so this should always be
  # a plain link creation — if it is not, fail loudly rather than nesting the
  # link inside a surviving token directory on the root disk.
  ln -sfnT "$WMCP_ROOT" "$wmcp_link" || fail "$wmcp_link is still a real directory — the OAuth tokens did not move to $WMCP_ROOT.
       Move it aside by hand and re-run."
  return 0
}

unit_google_workspace
completed google-workspace

# ------------------------------------------------------------- systemd
echo "==> Installing systemd units (sudo)"
sudo install -m 644 "$REPO_DIR/scripts/vps/systemd/goose-serve.service" "$SYSTEMD_DIR/goose-serve.service"
# The scheduler-fallback units are installed so the one-command flip in
# docs/automations.md works — but they are NEVER enabled here. Timers are
# renamed to goose-recipe@<id>.timer to match the template service instance.
sudo install -m 644 "$REPO_DIR/scripts/vps/systemd/fallback/goose-recipe@.service" "$SYSTEMD_DIR/goose-recipe@.service"
for t in morning-brief inbox-triage weekly-review health-followups; do
  sudo install -m 644 "$REPO_DIR/scripts/vps/systemd/fallback/$t.timer" "$SYSTEMD_DIR/goose-recipe@$t.timer"
done
sudo install -m 644 "$REPO_DIR/scripts/vps/systemd/tls-cert-renew.service" "$SYSTEMD_DIR/tls-cert-renew.service"
sudo install -m 644 "$REPO_DIR/scripts/vps/systemd/tls-cert-renew.timer" "$SYSTEMD_DIR/tls-cert-renew.timer"
# THE RELOAD MOVED DOWN TO HERE, and that is a bug fix, not tidying.
#
# It used to sit above the two tls-cert-renew installs, so the `enable --now`
# on the next line ran against whatever definition systemd had cached from the
# previous deploy — on a re-deploy that changed tls-cert-renew.service, the
# timer was armed with the OLD one. It survived because a second
# `daemon-reload` further down (inside the code-agents block) happened to
# re-read the file afterwards. That rescue is exactly what `--without
# code-agents` removes, and it was never there at all on the path where
# `apt-get`/`podman build` aborts the script under `set -e`.
#
# One reload, after every unconditional install above it, before every enable
# below it. Keep it here: scripts/verify/test-deploy-vps.sh V2b' asserts
# index(install tls-cert-renew.timer) < index(daemon-reload) < index(enable
# --now tls-cert-renew.timer) and fails if it moves back up.
sudo systemctl daemon-reload
sudo systemctl enable --now tls-cert-renew.timer >/dev/null

# ------------------------------------------------------- telegram gateway
# Rules 1-4 are above unit_google_workspace().
unit_telegram_gateway() {
  want telegram-gateway || return 0
  sudo install -m 644 "$REPO_DIR/scripts/vps/systemd/goose-telegram-gateway.service" "$SYSTEMD_DIR/goose-telegram-gateway.service"
  # The gateway's own reload, and the second half of the same bug. Before the
  # carve the only reload covering this install was the one inside the
  # code-agents block, so `enable --now` on the next line started the gateway
  # from a cached unit definition — i.e. potentially without GOOSE_PATH_ROOT,
  # the exact failure the restart at the end of this script exists to prevent.
  # It cannot be hoisted to the unconditional reload above: this install is
  # gated, so an unconditional reload would have to run before it.
  sudo systemctl daemon-reload
  if grep -q '^TELEGRAM_BOT_TOKEN=..*' "$SECRETS_FILE" 2>/dev/null; then
    sudo systemctl enable --now goose-telegram-gateway.service >/dev/null
    echo "    telegram gateway: enabled (token present)"
  else
    echo "    telegram gateway: installed but not enabled (no TELEGRAM_BOT_TOKEN in secrets.env; see docs/setup/40-phone-setup.md §1a)"
  fi
  return 0
}

unit_telegram_gateway
completed telegram-gateway

# ---------------------------------------------------------- code agents
# Per-chat OpenCode containers + session manager (docs/code-agents.md,
# docs/setup/70-code-agents.md). THIS is the unit --without exists for: an apt
# install and a subuid grant on the first deploy (both guarded), plus linger
# and a multi-minute `podman build` on every deploy, enabled or not. The
# conditional ENABLE on the two secrets stays exactly as it was — it answers a
# different question ("are the credentials there?") from the gate ("did you ask
# for this at all?").
unit_code_agents() {
  want code-agents || return 0
  echo "==> Code agents: container engine, image, manager"
  if ! command -v podman >/dev/null 2>&1; then
    echo "    installing podman (rootless) + uidmap + slirp4netns"
    sudo apt-get update -qq
    sudo apt-get install -y -qq podman uidmap slirp4netns >/dev/null
  fi
  # Rootless podman needs subordinate id ranges for agent, and the system unit
  # needs agent's user runtime dir (/run/user/1000) kept alive by linger.
  grep -q '^agent:' "$SUBUID_FILE" 2>/dev/null || \
    sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 agent
  sudo loginctl enable-linger agent >/dev/null 2>&1 || true
  echo "    building code-agent image (pulls the OpenCode base on first run)"
  podman build -q -t code-agent:local \
    -f "$REPO_DIR/config/code-agents/Containerfile" \
    "$REPO_DIR/config/code-agents" >/dev/null
  mkdir -p "$CODE_AGENTS_ROOT/chats"
  install_template "$REPO_DIR/config/code-agents/repos.example.json" "$CODE_AGENTS_ROOT/repos.json"
  sudo install -m 644 "$REPO_DIR/scripts/vps/systemd/code-agent-manager.service" "$SYSTEMD_DIR/code-agent-manager.service"
  sudo systemctl daemon-reload
  if grep -q '^OPENCODE_SERVER_PASSWORD=..*' "$SECRETS_FILE" 2>/dev/null && \
     grep -q '^GITHUB_CODE_AGENT_PAT=..*' "$SECRETS_FILE" 2>/dev/null; then
    sudo systemctl enable code-agent-manager.service >/dev/null
    # RESTART, not `enable --now`. `--now` means `start`, which is a NO-OP on a
    # unit that is already running — so every deploy after the first one shipped
    # a new code-agent-manager.py to disk and left the old process serving it,
    # while printing the success line below. goose-serve is restarted explicitly
    # at the end of this script for exactly this reason; this unit was the one
    # that was not.
    #
    # The failure was undetectable from outside: check-code-agents.sh probes
    # /api/health, /api/chats, stop, wake and delete, all of which the OLD
    # process answers identically. A route added in this deploy would 404, and a
    # 404 from a stale process looks exactly like a route that was never written.
    #
    # This SIGTERMs every chat container, because the unit's ExecStopPost stops
    # anything labelled code-agent=1 and that runs during the stop half of a
    # restart. Volumes, agent branches and transcripts survive; an in-flight turn
    # and OpenCode's in-memory permission asks do not. Deploy when nothing is
    # mid-turn.
    sudo systemctl restart code-agent-manager.service
    echo "    code agents: restarted (manager on the tailnet, port 4300)"
  else
    echo "    code agents: installed but not enabled (set OPENCODE_SERVER_PASSWORD"
    echo "    and GITHUB_CODE_AGENT_PAT in secrets.env; docs/setup/70-code-agents.md)"
  fi
  return 0
}

unit_code_agents
completed code-agents

sudo systemctl enable goose-serve.service >/dev/null

# ------------------------------------------------------------ schedules
# BEFORE the restart on purpose: goose serve's scheduler reads schedule.json
# once at startup and does not hot-reload it, so a schedule registered while
# serve is running stays dormant until the next restart (verified against
# goose 1.46.0). Registering first means the restart below picks everything up.
# That ordering is the reason this unit's call site is HERE and not at the
# bottom with the rest of the add-ons; test-deploy-vps.sh V2d asserts
# index(last `goose schedule add`) < index(restart goose-serve.service).
#
# NOTE the asymmetry, recorded in config/units/automations.yaml: the four
# goose-recipe@<id>.timer FALLBACK units are installed by the brain core above
# and are NOT removed by --without automations. They are the escape hatch for a
# broken deploy, so they must land before anything that can fail.
unit_automations() {
  want automations || return 0
  echo "==> Registering automation schedules"
  bash "$REPO_DIR/scripts/vps/register-schedules.sh"
  return 0
}

unit_automations
completed automations

echo "==> (Re)starting goose-serve"
# The intentional restart — drop the safety-net trap installed with the
# migration stop, so from here on a failure is reported rather than papered
# over by a background start.
trap - EXIT
sudo systemctl restart goose-serve.service
# The gateway was stopped for the migration and its unit file was reinstalled
# above (it now carries GOOSE_PATH_ROOT), so it must come back explicitly.
# `enable --now` above covers the token-in-secrets.env case only; this covers
# every enabled gateway — including one enabled by hand — and guarantees the
# reinstalled unit file is what is running.
if systemctl is-enabled --quiet goose-telegram-gateway.service 2>/dev/null; then
  echo "==> Restarting goose-telegram-gateway (picks up GOOSE_PATH_ROOT=$GOOSE_ROOT)"
  sudo systemctl restart goose-telegram-gateway.service
fi

# ------------------------------------------------------- wait for /status
TS_IP="$(tailscale ip -4 | head -n1)"
[[ -n "$TS_IP" ]] || fail "no Tailscale IPv4 — is tailscaled up? (tailscale status)"
STATUS_URL="https://$TS_IP:$SERVE_PORT/status"
echo "==> Waiting for goose serve at $STATUS_URL"
# -k: goose serve uses a self-signed cert; real clients pin its SHA-256
# fingerprint, but this is only a local liveness probe.
UP=0
for _ in $(seq 1 45); do
  # shellcheck disable=SC2154  # exported into the environment by
  # `set -a; source "$SECRETS_FILE"` in the preflight block above
  if curl -fsSk -m 5 -H "X-Secret-Key: $GOOSE_SERVER__SECRET_KEY" "$STATUS_URL" >/dev/null 2>&1; then
    UP=1
    break
  fi
  sleep 2
done
if [[ "$UP" -ne 1 ]]; then
  fail "goose serve did not answer on $STATUS_URL within 90s.
       Inspect:  sudo journalctl -u goose-serve -n 50 --no-pager"
fi
echo "    up."

# -------------------------------------------------------------- summary
# NO LINE IN THIS HEREDOC MAY BEGIN WITH `unit_`. units_lint.py's P3 counts
# call sites with a lexical `^unit_x$` over the whole file, heredocs and
# usage() included, so a summary line starting with a unit name would read as a
# second call site and fail the manifest check with a message about a function
# that is called twice.
cat <<EOF

============================================================
Brain deployed. goose serve is listening on $TS_IP:$SERVE_PORT (tailnet-only,
TLS, shared-secret auth) with the scheduler enabled.

goose state: GOOSE_PATH_ROOT=$GOOSE_ROOT — config, data AND state on the LUKS
volume, including logs/llm_request.*.jsonl (raw provider request/response
bodies) and secrets.yaml (per-connector credentials). docs/privacy.md.

config.yaml is installed NO-CLOBBER: on a brain that already has one, every
"differs from repo template" NOTE above is hardening that has NOT reached this
machine. Two entries are security-relevant, and both fail quietly:

  apps           goose 1.46.0 ships this platform extension ENABLED by default,
                 and tool calls an app initiates are dispatched without passing
                 through the permission manager — an imported app is an
                 unreviewed route to every other extension's tools. The
                 template sets \`enabled: false\`. Confirm with:
                   goose configure   # Toggle Extensions -> apps must be unchecked

  workspace-mcp  the template pins workspace-mcp@1.25.0, narrows OAuth scopes
                 with --permissions, and carries a snake_case \`available_tools\`
                 allowlist. An ABSENT or EMPTY allowlist means every tool the
                 server exposes is callable — it fails OPEN — and the camelCase
                 spelling is discarded by goose without a word. Merge the entry
                 by hand:
                   diff $GOOSE_CONFIG_DIR/config.yaml $REPO_DIR/config/goose/config.yaml

check-security.sh --local asserts the live file for both, so it is the thing to
re-run after any hand-merge.

Verify next (docs/setup/50-vps-brain.md §6-10):
  1. TLS fingerprint for client pinning:
       sudo journalctl -u goose-serve -n 50 --no-pager | grep -iE 'listen|fingerprint'
  2. Full brain check:
       $REPO_DIR/scripts/verify/check-brain.sh
  3. Connect Goose Desktop to https://<your-brain>.<your-tailnet>.ts.net:$SERVE_PORT
     with GOOSE_SERVER__SECRET_KEY and the pinned fingerprint, then pair the
     phone (docs/setup/40-phone-setup.md).
  4. Fire a test run:  goose schedule run-now --schedule-id morning-brief
  5. From the Mac (in your repo checkout, where the terraform state lives),
     confirm zero public exposure:
       ./scripts/verify/check-security.sh "\$(cd infra/terraform && terraform output -raw server_public_ip)"
     And here on the brain (asserts no goose path escapes /data):
       $REPO_DIR/scripts/verify/check-security.sh --local
  6. Code agents (if enabled — docs/setup/70-code-agents.md):
       $REPO_DIR/scripts/verify/check-code-agents.sh --probe

Upgrades later: git pull happens automatically — just re-run this script.
============================================================
EOF
