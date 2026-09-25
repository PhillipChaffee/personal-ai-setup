#!/usr/bin/env bash
# deploy-vps.sh — deploy (and later upgrade) the brain's stack. Run ON the
# VPS as user `agent`, after scripts/vps/luks-setup.sh has created /data and
# /data/secrets.env has been filled in (docs/setup/50-vps-brain.md §4-6).
#
# Idempotent — re-running is the upgrade path: it pulls the repo, refreshes
# configs (never clobbering local state), reinstalls units and restarts
# goose-serve.
#
# ONE ADD-ON IS A UNIT: unit_herdr, the installer named by
# config/units/herdr.yaml (`installer.function`), gated by --with/--without/
# --only plus the new --coding-agents flag and defined immediately above its
# one call site. The container plane that used to be this unit is GONE (the
# herdr pivot — docs/adr/0001); `herdr` replaces it, and it is OFF by default:
# a bare run installs brain core + goose-serve only, because hand runs never
# write credentials unasked (#138's "unpicked = nothing written"). The wizard
# passes `--with herdr --coding-agents <picked>` over SSH; a human opts in
# with the same flags.
#
# THE BRAIN CORE IS NOT A UNIT AND IS NOT SELECTABLE. The path-root migration,
# the goose config install, the systemd unit files, `goose-serve` and the
# /status gate are eight non-contiguous regions interleaved with the unit
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
# The herdr home IS the unit's world: config/, state/, repos/, worktrees/,
# bin/ all live under it, and the systemd sandbox makes the service see
# nothing else on /data (herdr.service's TemporaryFileSystem/BindPaths pair).
HERDR_ROOT="$DATA_ROOT/herdr"
HERDR_BIN="$HERDR_ROOT/bin/herdr"
HERDR_CONFIG_DIR="$HERDR_ROOT/config"
# Where the installer records the picked-agent list; check-herdr.sh derives
# the expected env set from it (the pick-aware exact-set check, T5).
HERDR_AGENTS_FILE="$HERDR_CONFIG_DIR/agents.list"
GOOSE_CONFIG_DIR="$HOME/.config/goose"
SERVE_PORT=3284
# The version pins, read out of the repo checkout: herdr + the coding-agent
# catalog. PAI_PINS_FILE is a testing-only seam like the roots above — unset,
# this is the repo file every real deploy reads.
PINS_FILE="${PAI_PINS_FILE:-$REPO_DIR/config/pins.yaml}"

# ------------------------------------------------------- the unit selection
# A space-delimited string, matched with `case " $SELECTED " in *" $id "*)`,
# and NOT a `declare -A`. This file is bash-3.2-clean and stays that way: an
# associative array, `mapfile` or `${x,,}` would work on the Ubuntu brain and
# break the moment anyone runs it under /bin/bash on a Mac, and nothing in CI
# here would catch it.
#
# THE ORDER IS THE CALL ORDER, and the --dry-run plan prints it in this order.
#
# UNLIKE bootstrap-mac.sh, THE DEFAULT SELECTION IS EMPTY. A bare
# `deploy-vps.sh` installs brain core + goose-serve and nothing else: herdr
# writes credentials and pane state, and a hand run that never asked for them
# must not provision them (the #138 rule the manifest's tier: default_on does
# NOT override — that tier is the wizard menu's default, not this script's).
UNIT_IDS="herdr"
SELECTED=""
# The coding-agent catalog: what --coding-agents may name. Gemini CLI was cut
# by the agent-picker decision (recorded refusal: Google-only auth, no Zen or
# Together billing, no herdr integration) and is refused here like any other
# unknown id. The ids are the same strings agents.list records and
# check-herdr.sh reads.
AGENT_CATALOG="opencode pi claude-code codex grok-build"
# Set by want(), cleared by completed(), read by on_unit_err(). Top-level
# globals on purpose — see the note above resume_goose_units about what `local`
# does to a variable an EXIT trap reads.
CURRENT_UNIT=""
DONE_UNITS=""
ERR_REPORTED=0

usage() {
  cat <<'EOF'
Usage: deploy-vps.sh [--with ID] [--without ID] [--only ID] [--coding-agents LIST]
                     [--dry-run] [REPO_URL]

Deploys/upgrades the brain: repo clone or pull, migration of goose's
config/data/state onto the encrypted volume (GOOSE_PATH_ROOT=/data/goose),
goose config install, systemd units, goose-serve start. REPO_URL (or the
REPO_URL env var) is only needed for the
first-ever clone if the repo is not already at /home/agent/personal-ai-setup,
e.g.:

  deploy-vps.sh https://github.com/<your-github-username>/personal-ai-setup.git

Units (herdr is the only one, and it is OFF by default — a bare run installs
brain core + goose-serve only, because a hand run must never write
credentials it was never asked for):

  herdr              the coding-agent runtime: a dedicated herdr user, the
                     digest-pinned herdr binary, the server config, and the
                     coding agents named by --coding-agents. The wizard turns
                     this on; humans opt in with --with/--only.

  --with ID       select ID. Required to install herdr on a hand run:
                  `deploy-vps.sh --with herdr --coding-agents opencode,pi`.
                  `--with X --without X` warns and DESELECTS X — deselection
                  is the safe direction to lose an argument in.
  --without ID    deselect ID (no-op today: nothing is selected by default,
                  kept so the flag surface matches the Mac installer's).
  --only ID       select exactly ID (repeat, or comma-separate, for several).
                  Not combinable with --with/--without.
  --coding-agents LIST
                  the coding agents to install inside the herdr plane:
                  comma- or space-separated from: opencode pi claude-code
                  codex grok-build (repeatable). REQUIRES herdr selected via
                  --with/--only — error exit 2 otherwise. The flag BARE
                  (--coding-agents with no list) means server only: no agent
                  CLIs, no agent config, no credentials copied.
  --dry-run       print the plan and exit 0 without touching anything

THE BRAIN CORE IS NOT SELECTABLE. The path-root migration, the goose config
install, the systemd unit files, the goose-serve restart and the /status gate
run on every invocation, including `--only code-agents`. There is no flag that
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
CODING_AGENTS=""; CODING_AGENTS_GIVEN=0
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
    --coding-agents)
      # The flag BARE means server-only, so the next token counts as the list
      # only when it is not another flag.
      if [ "$#" -ge 2 ]; then
        case "$2" in
          --*) ;;
          *)
            # Commas as well as repetition, --only-style (see above); words
            # are validated and de-duplicated after the loop.
            CODING_AGENTS="$CODING_AGENTS $(echo "$2" | tr ',' ' ')"
            shift ;;
        esac
      fi
      CODING_AGENTS_GIVEN=1
      SELECTIVE=1
      shift ;;
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

# Every coding agent must be in the catalog, and named once. A doubled id in
# the list would double its install work on every run; an unknown id would
# otherwise silently skip that agent's credential and integration.
for id in $CODING_AGENTS; do
  case " $AGENT_CATALOG " in
    *" $id "*) ;;
    *) die_usage "unknown coding agent '$id'; known agents: $AGENT_CATALOG" ;;
  esac
done
CODING_AGENTS_DEDUP=""
for id in $CODING_AGENTS; do
  case " $CODING_AGENTS_DEDUP " in
    *" $id "*) ;;
    *) CODING_AGENTS_DEDUP="$CODING_AGENTS_DEDUP $id" ;;
  esac
done
CODING_AGENTS="${CODING_AGENTS_DEDUP# }"
unset CODING_AGENTS_DEDUP

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
    # Default selection is EMPTY (see the unit-selection note): only --with
    # turns a unit on, and --without only ever wins against the --with that
    # named the same id.
    case " $WITH_IDS " in
      *" $id "*) ;;
      *) continue ;;
    esac
    case " $WITHOUT_IDS " in
      *" $id "*)
        echo "WARNING: '$id' is named by both --with and --without; --without wins (use --only $id to select it alone)." >&2 ;;
      *) SELECTED="$SELECTED $id" ;;
    esac
  done
fi
# Trim the leading space so `--dry-run`'s plan and the error attribution read
# as a list rather than as a ragged one.
SELECTED="${SELECTED# }"

# Agents require herdr. The error must be a usage error (exit 2), because the
# wizard passes both flags together and a typo in either half should be a
# refused argv, not a half-plane. Checked AFTER the selection computation,
# which is what `--only herdr --coding-agents opencode` depends on.
if [ "$CODING_AGENTS_GIVEN" -eq 1 ]; then
  case " $SELECTED " in
    *" herdr "*) ;;
    *) die_usage "--coding-agents requires herdr selected: add --with herdr
        (or --only herdr), or drop --coding-agents" ;;
  esac
fi

if [ "$SELECTIVE" -eq 1 ]; then
  echo "==> units selected: ${SELECTED:-(none)}"
  [ "$CODING_AGENTS_GIVEN" -eq 0 ] || echo "==> coding agents: ${CODING_AGENTS:-(none — server only)}"
  echo "    note: the brain core (migration, goose config, goose-serve, /status)"
  echo "          is not selectable and always runs."
fi

# --------------------------------------------------- seam containment gate
# BEFORE the preflight, on purpose: the preflight already probes $DATA_ROOT and
# reads $SECRETS_FILE, so a gate placed after it would have let a half-set
# environment touch the real host before refusing.
if [[ -n "$PAI_FAKE_ROOT" ]]; then
  for pai_root in "$REPO_DIR" "$DATA_ROOT" "$SYSTEMD_DIR" "$GOOSE_BIN" "$SUBUID_FILE" "$PINS_FILE" "$HOME"; do
    case "$pai_root" in
      "$PAI_FAKE_ROOT"/*) ;;
      *) fail "PAI_FAKE_ROOT is set but '$pai_root' is not under it.
       Refusing to run: a half-contained test seam writes to the real host." ;;
    esac
  done
  unset pai_root
elif [[ -n "${PAI_REPO_DIR:-}${PAI_DATA_ROOT:-}${PAI_SYSTEMD_DIR:-}${PAI_GOOSE_BIN:-}${PAI_SUBUID_FILE:-}${PAI_PINS_FILE:-}" ]]; then
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
  if [ "$CODING_AGENTS_GIVEN" -eq 1 ]; then
    echo "    coding agents: ${CODING_AGENTS:-(none — server only)}"
  fi
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
for var in OPENCODE_ZEN_API_KEY TOGETHER_API_KEY GOOSE_SERVER__SECRET_KEY; do
  [[ -n "${!var:-}" ]] || MISSING+=("$var")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  fail "required variables empty in $SECRETS_FILE: ${MISSING[*]}
       Fill them in (see config/env/secrets.env.example for what each is)."
fi

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
#   data/    sessions.db (the whole chat history)
#   state/   logs/llm_request.*.jsonl — the raw request and response bodies
#            exchanged with inference providers
# GOOSE_PATH_ROOT=/data/goose relocates all three together (verified against
# goose 1.46.0) and is set in goose-serve.service. This block migrates an
# existing brain into that layout: it never deletes session history, and
# re-running it is a no-op.
#
# The symlinks matter as much as the env var. `goose` invoked from an SSH
# session — check-brain.sh, the herdr server's coding agents — does NOT
# inherit the systemd unit's environment, so without them the CLI
# and the service would read different config.yaml files. With them, both
# paths land in /data/goose either way.
echo "==> Migrating goose config/data/state onto the encrypted volume ($GOOSE_ROOT)"

# No goose process may be running while its directories move underneath it,
# and `Restart=always` means a crash-looping unit could start back up mid-move
# — so stop unconditionally whenever the unit exists, rather than testing
# is-active (which is false for a unit in `activating`). `systemctl cat` is the
# reliable "does this unit exist" test; stopping an already-stopped unit is a
# no-op.
#
# Hundreds of lines separate this stop from the restart at the end (config
# install, systemd units, podman build) and the script runs under `set -e`.
# Without a trap, a failure anywhere in between — an apt-get hiccup, a podman
# build error — would leave the brain OFFLINE with nothing but a stack of
# output to say so. The EXIT trap brings goose-serve back on ANY exit path; it
# is cleared just before the intentional restart at the end.
# TOP LEVEL, and it must stay there. This trap fires OUTSIDE every unit body,
# so a `local` inside one would leave the function reading an unbound variable
# under `set -u` — the trap would die after goose-serve had been started, on
# the one path where nobody is watching. Same rule as install_template and
# migrate_into_root.
resume_goose_units() {
  sudo systemctl start goose-serve.service >/dev/null 2>&1 || true
}

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

# ------------------------------------------------------- rules for unit bodies
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
#      WHOLE body with errexit disabled. units_lint.py:707 — the `called =
#      function_lines(...)` line in check_installer_status — counts `^unit_x$` and
#      would happily accept the `if` form. (Written as :659 first; #43 added 48
#      lines to check_uninstall above it. Nothing in CI resolves a citation from
#      one script to another — see the note on this in #43.)
#   3. `[ cond ] || continue` inside loops, never `[ cond ] && action` as a
#      loop's last statement — the loop inherits that status and the body then
#      returns false having done all of its work.
#   4. HELPERS AND THE TRAP'S GLOBALS STAY TOP LEVEL. install_template is
#      called from the goose-config block AND from unit_herdr; a helper
#      defined inside a unit is not defined until that unit has RUN, so a
#      selective install would die at `command not found`.

# ------------------------------------------------------------- systemd
echo "==> Installing systemd units (sudo)"
sudo install -m 644 "$REPO_DIR/scripts/vps/systemd/goose-serve.service" "$SYSTEMD_DIR/goose-serve.service"
sudo systemctl daemon-reload

# ------------------------------------------------------- herdr helpers
# ALL TOP LEVEL (rule 4 above): called from unit_herdr on a `--only herdr`
# run, which is exactly the run that defines nothing else first.

# pin_value SECTION KEY [SUBKEY] — read one pinned value out of $PINS_FILE.
# Understands exactly the two nestings pins.yaml uses (herdr.version;
# coding_agents.opencode.version) and no more: YAML parsing is Python's job
# and this file is bash-3.2-clean, so this is a strict shape match, not a
# parser. A pin that is absent FAILS rather than reading empty — an unpinned
# download is the drift pins.yaml exists to end.
pin_value() {
  local found
  found="$(awk -v sec="$1" -v key="$2" -v sk="${3:-}" '
    {
      # The shape: a section line ends in a bare colon; a subkey line is a
      # 2-space name ending in a bare colon; a VALUE line carries content
      # after its colon. The value test runs against the section state as of
      # the PREVIOUS line, so the wanted line does not advance the pointer
      # before it is matched — and only a line WITH a value can be one, so a
      # subkey boundary never reads as a value.
      if (sk == "" && top == sec && mid == "" && $0 ~ "^  " key ":[ \t]*[^ \t]") {
        line = $0
        sub(/^[ \t]*[A-Za-z][A-Za-z0-9_]*:[ \t]*/, "", line)
        gsub(/"/, "", line)
        print line
        found = 1
        exit
      }
      if (sk != "" && top == sec && mid == key && $0 ~ "^    " sk ":[ \t]*[^ \t]") {
        line = $0
        sub(/^[ \t]*[A-Za-z][A-Za-z0-9_]*:[ \t]*/, "", line)
        gsub(/"/, "", line)
        print line
        found = 1
        exit
      }
      if ($0 ~ /^[A-Za-z][A-Za-z0-9_]*:[ \t]*$/) { split($0, t, ":"); top = t[1]; mid = "" }
      else if (top != "" && $0 ~ /^  [A-Za-z][A-Za-z0-9_]*:[ \t]*$/) {
        split(substr($0, 3), t, ":")
        mid = t[1]
      }
    }
    END { exit found ? 0 : 1 }
  ' "$PINS_FILE")" || fail "pin_value: no pin '$1.$2${3+.$3}' in $PINS_FILE — this deploy installs nothing unpinned."
  printf '%s' "$found"
}

# install_template_as SRC DST OWNER MODE — install_template for paths owned by
# the herdr user, which the invoking user cannot write directly. Same
# no-clobber contract: a file that already exists and differs is a NOTE, never
# an overwrite, because the agents keep runtime state in these directories.
install_template_as() {
  local src="$1" dst="$2" own="${3%:*}" grp="${3#*:}" mode="$4"
  if sudo test -e "$dst"; then
    if ! sudo cmp -s "$src" "$dst"; then
      echo "    NOTE: $dst differs from repo template — not overwriting (agents keep runtime state in it)."
      echo "          Review and merge by hand:  sudo diff '$dst' '$src'"
    fi
  else
    sudo install -o "$own" -g "$grp" -m "$mode" "$src" "$dst"
    echo "    installed $dst"
  fi
}

# HERDR_ENV_STAGE / HERDR_ENV_NAMES — the pick-aware credential copy (spec §2,
# T5). The staged file becomes /data/herdr/secrets.env (0600, owner herdr) and
# the NAME list is what check-herdr.sh derives from agents.list: the two sides
# must implement the SAME rules, word for word.
HERDR_ENV_STAGE=""
HERDR_ENV_NAMES=""

require_secret() {
  # require_secret NAME WHY — fail the deploy with a remedy instead of
  # provisioning a half-credentialed plane.
  local name="$1" why="$2"
  [ -n "${!name:-}" ] || fail "$name is empty in $SECRETS_FILE — $why.
       Fill it in (docs/setup/10-accounts.md), then re-run deploy-vps.sh --only herdr."
}

herdr_env_add() {
  # herdr_env_add NAME VALUE — one row, once. Names are tracked for the
  # summary; values are copied from /data/secrets.env (already sourced), which
  # is the roster the wizard fills over SSH (#138).
  local name="$1" value="$2"
  case " $HERDR_ENV_NAMES " in
    *" $name "*) return 0 ;;
  esac
  HERDR_ENV_NAMES="$HERDR_ENV_NAMES $name"
  printf '%s=%s\n' "$name" "$value" >>"$HERDR_ENV_STAGE"
}

# One installer function per catalog id, and AGENT_CATALOG in the selection
# block must name exactly these (a drift-lock, asserted by test-deploy-vps.sh).
# Each installer is idempotent at the pinned version and does the FULL
# #138-matrix row: pinned CLI, pre-created config dir, herdr integration where
# one exists, credential plumbing file where the agent needs one. Unpicked
# agents run none of this: unpicked = nothing written.
install_agent_opencode() {
  local pin asset digest dl extract
  pin="$(pin_value coding_agents opencode version)"
  asset="$(pin_value coding_agents opencode asset)"
  digest="$(pin_value coding_agents opencode sha256)"
  # /data/herdr is 0750 herdr — every probe inside it runs as herdr.
  if sudo test -x "$HERDR_ROOT/bin/opencode" && \
     sudo -u herdr "$HERDR_ROOT/bin/opencode" --version 2>/dev/null | grep -q "$pin"; then
    echo "    opencode $pin already installed"
  else
    echo "    installing opencode $pin (release asset, sha256-checked)"
    dl="$(mktemp)"
    extract="$(mktemp -d)"
    curl -fsSL -o "$dl" "https://github.com/anomalyco/opencode/releases/download/v${pin}/${asset}"
    # Unguarded on purpose — see the herdr install's digest note above.
    printf '%s  %s\n' "$digest" "$dl" | sha256sum -c -
    tar -xzf "$dl" -C "$extract"
    sudo install -o herdr -g herdr -m 755 "$extract/opencode" "$HERDR_ROOT/bin/opencode"
    rm -rf "$extract"
    rm -f "$dl"
  fi
  # The config dir must pre-exist BEFORE `herdr integration install opencode`
  # writes its hook (the #133 delta: integration config dirs are pre-created).
  sudo install -d -o herdr -g herdr -m 750 "$HERDR_CONFIG_DIR/opencode"
  # Credential: TOGETHER_API_KEY rides the environment — OpenCode's models.dev
  # catalog marks the togetherai provider with exactly that env name, so the
  # provider activates with no auth.json plumbing.
  herdr_integration opencode
}

install_agent_pi() {
  local pin package
  pin="$(pin_value coding_agents pi version)"
  package="$(pin_value coding_agents pi package)"
  if sudo test -x "$HERDR_ROOT/.local/bin/pi" && \
     sudo -u herdr "$HERDR_ROOT/.local/bin/pi" --version 2>/dev/null | grep -q "$pin"; then
    echo "    pi $pin already installed"
  else
    echo "    installing pi $pin (npm, pinned)"
    sudo -u herdr env HOME="$HERDR_ROOT" \
      npm install -g --ignore-scripts --prefix "$HERDR_ROOT/.local" "${package}@${pin}"
  fi
  sudo install -d -o herdr -g herdr -m 750 "$HERDR_ROOT/.pi/agent"
  herdr_integration pi
}

install_agent_claude_code() {
  local pin installer
  pin="$(pin_value coding_agents claude_code version)"
  if sudo test -x "$HERDR_ROOT/.local/bin/claude" && \
     sudo -u herdr "$HERDR_ROOT/.local/bin/claude" --version 2>/dev/null | grep -q "$pin"; then
    echo "    claude-code $pin already installed"
  else
    echo "    installing claude-code $pin (documented installer; it verifies sha256 itself)"
    installer="$(mktemp)"
    curl -fsSL -o "$installer" "https://claude.ai/install.sh"
    sudo -u herdr env HOME="$HERDR_ROOT" bash "$installer" "$pin"
    rm -f "$installer"
  fi
  sudo install -d -o herdr -g herdr -m 750 "$HERDR_ROOT/.claude"
  # A native install self-updates in the background past any pin unless told
  # not to (docs: DISABLE_AUTOUPDATER). Seeded no-clobber, like every agent
  # config: the user may have grown it.
  claude_settings="$(mktemp)"
  printf '{\n  "env": { "DISABLE_AUTOUPDATER": "1" }\n}\n' >"$claude_settings"
  install_template_as "$claude_settings" "$HERDR_ROOT/.claude/settings.json" herdr:herdr 644
  rm -f "$claude_settings"
}

install_agent_codex() {
  local pin package
  pin="$(pin_value coding_agents codex version)"
  package="$(pin_value coding_agents codex package)"
  if sudo test -x "$HERDR_ROOT/.local/bin/codex" && \
     sudo -u herdr "$HERDR_ROOT/.local/bin/codex" --version 2>/dev/null | grep -q "$pin"; then
    echo "    codex $pin already installed"
  else
    echo "    installing codex $pin (npm, pinned)"
    sudo -u herdr env HOME="$HERDR_ROOT" \
      npm install -g --ignore-scripts --prefix "$HERDR_ROOT/.local" "${package}@${pin}"
  fi
  sudo install -d -o herdr -g herdr -m 750 "$HERDR_ROOT/.codex"
  # Credential plumbing: a custom model provider whose env_key names the row
  # the credential copy wrote. Zen's provider is the #146-verified shape
  # (Responses wire); the vendor row is the documented custom-provider shape.
  codex_cfg="$(mktemp)"
  if [ "${CODEX_ZEN:-0}" = "1" ]; then
    cat >"$codex_cfg" <<'EOF'
# Written by deploy-vps.sh (unit_herdr): codex bills through OpenCode Zen's
# Responses wire — the shape the #146 smoke test verified end to end.
model_provider = "zen"

[model_providers.zen]
name = "OpenCode Zen"
base_url = "https://opencode.ai/zen/v1"
env_key = "OPENCODE_ZEN_API_KEY"
wire_api = "responses"
EOF
  else
    cat >"$codex_cfg" <<'EOF'
# Written by deploy-vps.sh (unit_herdr): codex bills through its vendor key.
model_provider = "openai-api"

[model_providers.openai-api]
name = "OpenAI"
base_url = "https://api.openai.com/v1"
env_key = "OPENAI_API_KEY"
wire_api = "responses"
EOF
  fi
  install_template_as "$codex_cfg" "$HERDR_ROOT/.codex/config.toml" herdr:herdr 644
  rm -f "$codex_cfg"
}

install_agent_grok_build() {
  local pin installer
  pin="$(pin_value coding_agents grok_build version)"
  if sudo test -x "$HERDR_ROOT/.grok/bin/grok" && \
     sudo -u herdr "$HERDR_ROOT/.grok/bin/grok" --version 2>/dev/null | grep -q "$pin"; then
    echo "    grok-build $pin already installed"
  else
    echo "    installing grok-build $pin (official installer)"
    echo "    NOTE: upstream publishes no checksum for this installer — the"
    echo "          download is TLS-only. Recorded as a blocker in herdr.yaml."
    installer="$(mktemp)"
    curl -fsSL -o "$installer" "https://x.ai/cli/install.sh"
    sudo -u herdr env HOME="$HERDR_ROOT" bash "$installer" "$pin"
    rm -f "$installer"
  fi
  sudo install -d -o herdr -g herdr -m 750 "$HERDR_ROOT/.grok"
  # BYOK plumbing: the credential is the env var named by env_key — never a
  # literal in a file. Grok models themselves need XAI_API_KEY (paid-only, a
  # new account); that is a documented opt-in the installer never wires.
  grok_cfg="$(mktemp)"
  cat >"$grok_cfg" <<'EOF'
# Written by deploy-vps.sh (unit_herdr): Grok Build rides Together AI by
# default (the #138 matrix). Pick models interactively in the pane.
[model.together]
base_url = "https://api.together.xyz/v1"
name = "Together AI (BYOK)"
env_key = "TOGETHER_API_KEY"
api_backend = "chat_completions"
EOF
  install_template_as "$grok_cfg" "$HERDR_ROOT/.grok/config.toml" herdr:herdr 644
  rm -f "$grok_cfg"
}

# herdr_integration AGENT — run the official integration install as the herdr
# user, with the SAME environment the service carries. herdr resolves the
# agent's config dir from this env (XDG_CONFIG_HOME), so a different env here
# would write the hook where the pane's agent will not read it.
herdr_integration() {
  sudo -u herdr env HOME="$HERDR_ROOT" \
    XDG_CONFIG_HOME="$HERDR_CONFIG_DIR" XDG_STATE_HOME="$HERDR_ROOT/state" \
    "$HERDR_BIN" integration install "$1"
}

# ------------------------------------------------------------- herdr agents
# unit_herdr — the coding-agent runtime (config/units/herdr.yaml). OFF by
# default: only --with/--only select it, and --coding-agents (whose list is
# validated against AGENT_CATALOG at argv time) decides which agent CLIs are
# installed. The namespace contract lives in herdr.service; the disk layout
# and the credential rules are spec §2/§4/§5 of the revised epic (#139).
#
# TEARDOWN IS DELIBERATELY ABSENT: the deploy script gains no teardown logic
# and no automated deletion of any kind (spec §8). Legacy cleanup on an
# existing brain is the wizard's printed manual checklist; check-brain.sh's
# legacy arm is its completion signal.
unit_herdr() {
  want herdr || return 0
  echo "==> herdr: dedicated user, pinned binary, server config, coding agents"

  # ---- the dedicated user (T1) ----
  # A real login shell, not nologin: every remote-attach operation is an ssh
  # exec-channel request, and sshd runs those through the login shell —
  # nologin would break `herdr machine add` entirely. systemd needs no shell;
  # the SSH bridge does. (Verified against herdr 0.9.1 source, 2026-09-24.)
  if ! id -u herdr >/dev/null 2>&1; then
    sudo useradd --home-dir "$HERDR_ROOT" --no-create-home --shell /bin/bash herdr
  fi
  # install -d applies owner/mode to existing dirs too, so a drifted mode is
  # repaired on every deploy and nothing inside is ever touched.
  sudo install -d -o herdr -g herdr -m 750 "$HERDR_ROOT"
  sudo install -d -o herdr -g herdr -m 755 "$HERDR_ROOT/bin"
  sudo install -d -o herdr -g herdr -m 750 "$HERDR_ROOT/config" "$HERDR_ROOT/state" \
    "$HERDR_ROOT/repos" "$HERDR_ROOT/worktrees"

  # ---- the pinned binary (T2), digest-checked ----
  HERDR_PIN="$(pin_value herdr version)"
  if ! sudo test -x "$HERDR_BIN" || \
     ! sudo -u herdr env HOME="$HERDR_ROOT" "$HERDR_BIN" --version 2>/dev/null | grep -q "$HERDR_PIN"; then
    herdr_asset="$(pin_value herdr asset)"
    herdr_digest="$(pin_value herdr sha256)"
    echo "    installing herdr $HERDR_PIN ($herdr_asset, sha256-checked)"
    herdr_dl="$(mktemp)"
    curl -fsSL -o "$herdr_dl" "https://github.com/herdrdev/herdr/releases/download/v${HERDR_PIN}/${herdr_asset}"
    # UNGUARDED on purpose: under set -e a mismatch aborts the unit and the
    # ERR trap ATTRIBUTES it ("unit 'herdr' failed"), the same contract the
    # rest of this script honours. A `|| fail` guard would turn the same
    # failure into an exit 1 with no attribution — an exit is not a failing
    # command, and the ERR trap never fires for one.
    printf '%s  %s\n' "$herdr_digest" "$herdr_dl" | sha256sum -c -
    sudo install -o herdr -g herdr -m 755 "$herdr_dl" "$HERDR_BIN"
    rm -f "$herdr_dl"
    unset herdr_asset herdr_digest herdr_dl
  fi
  # The remote-attach bridge's discovery checks $HOME/.local/bin/herdr among
  # its fixed candidates; bind the pinned binary there too (a symlink: one
  # copy on disk, two discovery paths).
  sudo install -d -o herdr -g herdr -m 750 "$HERDR_ROOT/.local/bin"
  sudo ln -sfnT "$HERDR_BIN" "$HERDR_ROOT/.local/bin/herdr"

  # ---- the environment contract with the SSH bridge ----
  # The systemd unit sets HOME/XDG_*; the SSH exec-channel runs commands under
  # the login shell, which sources these files. If the two environments drift,
  # the bridge resolves a DIFFERENT socket than the server bound. Overwritten
  # on every deploy on purpose: this file is the unit's, not the user's.
  herdr_env_sh="$(mktemp)"
  {
    echo "# Managed by deploy-vps.sh (unit_herdr) — keep in sync with herdr.service."
    echo "# These are the values the service carries; the SSH remote-attach bridge"
    echo "# resolves its socket from the login session's env, so both must match."
    echo "export XDG_CONFIG_HOME=$HERDR_CONFIG_DIR"
    echo "export XDG_STATE_HOME=$HERDR_ROOT/state"
    echo "export PATH=\"$HERDR_ROOT/bin:$HERDR_ROOT/.local/bin:$HERDR_ROOT/.grok/bin:\$PATH\""
  } >"$herdr_env_sh"
  sudo install -o herdr -g herdr -m 644 "$herdr_env_sh" "$HERDR_ROOT/.bashrc"
  sudo install -o herdr -g herdr -m 644 "$herdr_env_sh" "$HERDR_ROOT/.profile"
  rm -f "$herdr_env_sh"
  unset herdr_env_sh

  # ---- server config: six keys explicit (T3) ----
  # herdr appends its own app dir to XDG_CONFIG_HOME, so the file the binary
  # reads is $HERDR_CONFIG_DIR/herdr/config.toml — and the socket lands beside
  # it at $HERDR_CONFIG_DIR/herdr/herdr.sock (0600, owned herdr). The unit's
  # Environment=XDG_CONFIG_HOME is what makes both paths hold by construction.
  sudo install -d -o herdr -g herdr -m 750 "$HERDR_CONFIG_DIR/herdr"
  install_template_as "$REPO_DIR/config/herdr/config.toml" \
    "$HERDR_CONFIG_DIR/herdr/config.toml" herdr:herdr 644

  # ---- the picked-agent record (T5, pick-aware) ----
  # Written ALWAYS when herdr runs, even with zero agents: check-herdr.sh
  # derives the expected env set from it, and an absent record would make the
  # exact-set check assert nothing.
  herdr_agents_record="$(mktemp)"
  {
    echo "# The coding agents this herdr plane was set up with, one id per line."
    echo "# Written by deploy-vps.sh (unit_herdr); check-herdr.sh reads it."
    for id in $CODING_AGENTS; do
      echo "$id"
    done
  } >"$herdr_agents_record"
  sudo install -o herdr -g herdr -m 644 "$herdr_agents_record" "$HERDR_AGENTS_FILE"
  rm -f "$herdr_agents_record"
  unset herdr_agents_record

  # ---- the pick-aware credential copy (T5) ----
  # /data/secrets.env is already sourced (preflight). The union is per the
  # #138 matrix + GITHUB_CODE_AGENT_PAT; vendor keys beat the Zen key when
  # both are present (the wizard displays the vendor first — the same rule
  # check-herdr.sh implements). The goose secret NEVER enters this file.
  CODEX_ZEN=0
  HERDR_ENV_STAGE="$(mktemp)"
  HERDR_ENV_NAMES=""
  {
    echo "# /data/herdr/secrets.env — written by deploy-vps.sh (unit_herdr)."
    echo "# The herdr-scoped copy: exactly the picked agents' rows plus the"
    echo "# git PAT, per the #138 matrix. Never the goose serve secret."
    echo "# check-herdr.sh asserts this exact set against agents.list."
  } >"$HERDR_ENV_STAGE"
  for id in $CODING_AGENTS; do
    case "$id" in
      opencode|pi|grok-build)
        require_secret TOGETHER_API_KEY "the '$id' pick bills through Together AI (the default biller)"
        # shellcheck disable=SC2154  # assigned by the sourced /data/secrets.env
        herdr_env_add TOGETHER_API_KEY "$TOGETHER_API_KEY" ;;
      claude-code)
        # Vendor first (the wizard displays the vendor default, #138); when
        # only the Zen key is present, Claude Code is plumbed to Zen's
        # Anthropic wire with the captured key under the name it reads.
        if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
          herdr_env_add ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY"
        elif [ -n "${OPENCODE_ZEN_API_KEY:-}" ]; then
          herdr_env_add ANTHROPIC_AUTH_TOKEN "$OPENCODE_ZEN_API_KEY"
          herdr_env_add ANTHROPIC_BASE_URL "https://opencode.ai/zen"
        else
          fail "the claude-code pick needs ANTHROPIC_API_KEY (vendor) or OPENCODE_ZEN_API_KEY (Zen) in $SECRETS_FILE.
       The wizard captures one at pick time; fill it in and re-run deploy-vps.sh --only herdr."
        fi ;;
      codex)
        if [ -n "${OPENAI_API_KEY:-}" ]; then
          herdr_env_add OPENAI_API_KEY "$OPENAI_API_KEY"
        elif [ -n "${OPENCODE_ZEN_API_KEY:-}" ]; then
          herdr_env_add OPENCODE_ZEN_API_KEY "$OPENCODE_ZEN_API_KEY"
          CODEX_ZEN=1
        else
          fail "the codex pick needs OPENAI_API_KEY (vendor) or OPENCODE_ZEN_API_KEY (Zen) in $SECRETS_FILE.
       The wizard captures one at pick time; fill it in and re-run deploy-vps.sh --only herdr."
        fi ;;
    esac
  done
  if [ -n "$CODING_AGENTS" ]; then
    # The PAT scope IS the allowlist (TN7): no repos.json comes back. Agents
    # clone in panes with this credential, so every picked list needs it.
    require_secret GITHUB_CODE_AGENT_PAT "agents clone and push in panes with the scoped GitHub PAT"
    # shellcheck disable=SC2154  # assigned by the sourced /data/secrets.env
    herdr_env_add GITHUB_CODE_AGENT_PAT "$GITHUB_CODE_AGENT_PAT"
  fi
  sudo install -o herdr -g herdr -m 600 "$HERDR_ENV_STAGE" "$HERDR_ROOT/secrets.env"
  rm -f "$HERDR_ENV_STAGE"
  unset HERDR_ENV_STAGE
  if [ -n "$HERDR_ENV_NAMES" ]; then
    echo "    herdr env rows:${HERDR_ENV_NAMES}"
  else
    echo "    herdr env: no credential rows (server only)"
  fi

  # ---- the picked agents (T6) ----
  # Config dirs pre-created by the installers, BEFORE herdr integration install
  # runs (the #133 delta: the integration step needs its config dir to exist).
  for id in $CODING_AGENTS; do
    case "$id" in
      opencode)    install_agent_opencode ;;
      pi)          install_agent_pi ;;
      claude-code) install_agent_claude_code ;;
      codex)       install_agent_codex ;;
      grok-build)  install_agent_grok_build ;;
    esac
  done

  # ---- the service ----
  sudo install -m 644 "$REPO_DIR/scripts/vps/systemd/herdr.service" "$SYSTEMD_DIR/herdr.service"
  sudo systemctl daemon-reload
  sudo systemctl enable herdr.service >/dev/null
  # RESTART, not `enable --now`: --now is a no-op on an already-running unit,
  # which is how a previous deploy once shipped new code to disk while the old
  # process kept serving it. A restart stops the panes: herdr restores layout
  # and resumes agent sessions on restart, but a mid-turn pane does not come
  # back mid-turn — deploy when nothing is mid-turn (the old plane's rule,
  # carried over).
  echo "    restarting herdr.service (pane processes die — herdr restores layout and resumes sessions on restart)"
  sudo systemctl restart herdr.service
  echo "    herdr: restarted (Unix socket only, mode 0600 — no TCP listener)"
  unset CODEX_ZEN HERDR_PIN herdr_asset herdr_digest
  return 0
}

unit_herdr
completed herdr

sudo systemctl enable goose-serve.service >/dev/null

echo "==> (Re)starting goose-serve"
# The intentional restart — drop the safety-net trap installed with the
# migration stop, so from here on a failure is reported rather than papered
# over by a background start.
trap - EXIT
sudo systemctl restart goose-serve.service

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
TLS, shared-secret auth).

goose state: GOOSE_PATH_ROOT=$GOOSE_ROOT — config, data AND state on the LUKS
volume, including logs/llm_request.*.jsonl (raw provider request/response
bodies) and secrets.yaml (per-connector credentials). docs/privacy.md.

config.yaml is installed NO-CLOBBER: on a brain that already has one, every
"differs from repo template" NOTE above is hardening that has NOT reached this
machine. Two notes worth reading, and one of them fails quietly:

  apps           goose 1.46.0 ships this platform extension ENABLED by default,
                 and tool calls an app initiates are dispatched without passing
                 through the permission manager — an imported app is an
                 unreviewed route to every other extension's tools. The
                 template sets \`enabled: false\`. Confirm with:
                   goose configure   # Toggle Extensions -> apps must be unchecked

  workspace-mcp  REMOVED from this repo with the automations pivot (2026-09-23):
                 no fragment ships any more, so a brain that still has it
                 enabled shows a permanent "differs from repo template" NOTE.
                 Remove the extension by hand (\`goose configure\` -> Extensions)
                 — and note the repo never had a script to revoke the Google
                 OAuth grant or delete /data/workspace-mcp; both stay manual.

check-security.sh --local asserts the live file for both, so it is the thing to
re-run after any hand-merge.

Verify next (docs/setup/50-vps-brain.md §6-9):
  1. TLS fingerprint for client pinning:
       sudo journalctl -u goose-serve -n 50 --no-pager | grep -iE 'listen|fingerprint'
  2. Full brain check (including the legacy-plane arm):
       $REPO_DIR/scripts/verify/check-brain.sh
  3. Connect Goose Desktop to https://<your-brain>.<your-tailnet>.ts.net:$SERVE_PORT
     with GOOSE_SERVER__SECRET_KEY and the pinned fingerprint.
  4. From the Mac (in your repo checkout, where the terraform state lives),
     confirm zero public exposure:
       ./scripts/verify/check-security.sh "\$(cd infra/terraform && terraform output -raw server_public_ip)"
     And here on the brain (asserts no goose path escapes /data):
       $REPO_DIR/scripts/verify/check-security.sh --local
EOF

if [ -n "$SELECTED" ]; then
  cat <<EOF
  5. herdr (docs/setup/70-coding-agents.md):
       $REPO_DIR/scripts/verify/check-herdr.sh
     Attach from the Mac (clients attach as the herdr user — the server's own
     user owns the 0600 socket; a different SSH user cannot reach it):
       herdr machine add herdr@<your-brain>.<your-tailnet>.ts.net
     The SSH key must be authorized for herdr: add your Mac's public key to
     $HERDR_ROOT/.ssh/authorized_keys on the brain (runbook §4). Agents picked:
${CODING_AGENTS:+       $CODING_AGENTS}
     Restarting this unit kills pane processes (herdr restores layout and
     resumes sessions) — deploy when nothing is mid-turn.
EOF
else
  echo "    herdr is not installed this run: pass --with herdr (plus --coding-agents)"
  echo "    to set up the coding-agent runtime. docs/setup/70-coding-agents.md."
fi

cat <<EOF
Upgrades later: git pull happens automatically — just re-run this script.
============================================================
EOF
