#!/usr/bin/env bash
# deploy-vps.sh — deploy (and later upgrade) the brain's stack. Run ON the
# VPS as user `agent`, after scripts/vps/luks-setup.sh has created /data and
# /data/secrets.env has been filled in (docs/setup/50-vps-brain.md §4-6).
#
# Idempotent — re-running is the upgrade path: it pulls the repo, refreshes
# configs (never clobbering local state), reinstalls units, restarts
# goose-serve, and re-registers the schedule roster.
set -euo pipefail

REPO_DIR="/home/agent/personal-ai-setup"
SECRETS_FILE="/data/secrets.env"
# GOOSE_PATH_ROOT: one absolute root holding goose's config/, data/ AND
# state/ (goose-serve.service sets the same value). LEGACY_DATA_DIR is where
# data/ alone used to live, before state/ — the llm_request logs — was found
# sitting on the unencrypted root disk.
GOOSE_ROOT="/data/goose"
LEGACY_DATA_DIR="/data/goose-data"
GOOSE_CONFIG_DIR="$HOME/.config/goose"
SERVE_PORT=3284

usage() {
  cat <<'EOF'
Usage: deploy-vps.sh [REPO_URL]

Deploys/upgrades the brain: repo clone or pull, migration of goose's
config/data/state onto the encrypted volume (GOOSE_PATH_ROOT=/data/goose),
goose config install, systemd units, goose-serve start, schedule
registration. REPO_URL (or the REPO_URL env var) is only needed for the
first-ever clone if the repo is not already at /home/agent/personal-ai-setup,
e.g.:

  deploy-vps.sh https://github.com/<your-github-username>/personal-ai-setup.git

Prerequisites: /data mounted (luks-setup.sh / luks-unlock.sh) and
/data/secrets.env filled in (chmod 600).
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
REPO_URL="${1:-${REPO_URL:-}}"

fail() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
[[ $(id -u) -ne 0 ]] || fail "run as the 'agent' user, not root (the script sudos only where needed)."
[[ "$(id -un)" == "agent" ]] || echo "WARNING: expected to run as 'agent', running as '$(id -un)'." >&2

if ! mountpoint -q /data; then
  fail "/data is not mounted. First boot: run 'sudo $REPO_DIR/scripts/vps/luks-setup.sh --device <path>'.
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

GOOSE_BIN="/home/agent/.local/bin/goose"
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
# workspace-mcp stores its Google OAuth tokens in ~/.google_workspace_mcp/
# (the upstream default as of 2026-08-20). Point that at the encrypted
# volume so the tokens live on /data, never the unencrypted root disk.
# Verify after the first auth: if token files appear elsewhere, adjust here.
echo "==> Linking ~/.google_workspace_mcp -> /data/workspace-mcp"
WMCP_LINK="$HOME/.google_workspace_mcp"
if [[ -d "$WMCP_LINK" && ! -L "$WMCP_LINK" ]]; then
  echo "    migrating existing $WMCP_LINK onto the encrypted volume"
  mkdir -p /data/workspace-mcp
  cp -an "$WMCP_LINK/." /data/workspace-mcp/
  rm -rf "$WMCP_LINK"
fi
mkdir -p /data/workspace-mcp
# -T: the block above removes a real directory here, so this should always be
# a plain link creation — if it is not, fail loudly rather than nesting the
# link inside a surviving token directory on the root disk.
ln -sfnT /data/workspace-mcp "$WMCP_LINK" || fail "$WMCP_LINK is still a real directory — the OAuth tokens did not move to /data/workspace-mcp.
       Move it aside by hand and re-run."

# ------------------------------------------------------------- systemd
echo "==> Installing systemd units (sudo)"
sudo install -m 644 "$REPO_DIR/scripts/vps/systemd/goose-serve.service" /etc/systemd/system/goose-serve.service
# The scheduler-fallback units are installed so the one-command flip in
# docs/automations.md works — but they are NEVER enabled here. Timers are
# renamed to goose-recipe@<id>.timer to match the template service instance.
sudo install -m 644 "$REPO_DIR/scripts/vps/systemd/fallback/goose-recipe@.service" "/etc/systemd/system/goose-recipe@.service"
for t in morning-brief inbox-triage weekly-review health-followups; do
  sudo install -m 644 "$REPO_DIR/scripts/vps/systemd/fallback/$t.timer" "/etc/systemd/system/goose-recipe@$t.timer"
done
sudo systemctl daemon-reload
sudo install -m 644 "$REPO_DIR/scripts/vps/systemd/tls-cert-renew.service" /etc/systemd/system/tls-cert-renew.service
sudo install -m 644 "$REPO_DIR/scripts/vps/systemd/tls-cert-renew.timer" /etc/systemd/system/tls-cert-renew.timer
sudo systemctl enable --now tls-cert-renew.timer >/dev/null
sudo install -m 644 "$REPO_DIR/scripts/vps/systemd/goose-telegram-gateway.service" /etc/systemd/system/goose-telegram-gateway.service
if grep -q '^TELEGRAM_BOT_TOKEN=..*' /data/secrets.env 2>/dev/null; then
  sudo systemctl enable --now goose-telegram-gateway.service >/dev/null
  echo "    telegram gateway: enabled (token present)"
else
  echo "    telegram gateway: installed but not enabled (no TELEGRAM_BOT_TOKEN in secrets.env; see docs/setup/40-phone-setup.md §1a)"
fi
# ---------------------------------------------------------- code agents
# Per-chat OpenCode containers + session manager (docs/code-agents.md,
# docs/setup/70-code-agents.md). Everything is installed unconditionally;
# the manager is ENABLED only when both of its secrets are present in
# secrets.env — the same conditional-enable pattern as the telegram gateway.
echo "==> Code agents: container engine, image, manager"
if ! command -v podman >/dev/null 2>&1; then
  echo "    installing podman (rootless) + uidmap + slirp4netns"
  sudo apt-get update -qq
  sudo apt-get install -y -qq podman uidmap slirp4netns >/dev/null
fi
# Rootless podman needs subordinate id ranges for agent, and the system unit
# needs agent's user runtime dir (/run/user/1000) kept alive by linger.
grep -q '^agent:' /etc/subuid 2>/dev/null || \
  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 agent
sudo loginctl enable-linger agent >/dev/null 2>&1 || true
echo "    building code-agent image (pulls the OpenCode base on first run)"
podman build -q -t code-agent:local \
  -f "$REPO_DIR/config/code-agents/Containerfile" \
  "$REPO_DIR/config/code-agents" >/dev/null
mkdir -p /data/code-agents/chats
install_template "$REPO_DIR/config/code-agents/repos.example.json" /data/code-agents/repos.json
sudo install -m 644 "$REPO_DIR/scripts/vps/systemd/code-agent-manager.service" /etc/systemd/system/code-agent-manager.service
sudo systemctl daemon-reload
if grep -q '^OPENCODE_SERVER_PASSWORD=..*' /data/secrets.env 2>/dev/null && \
   grep -q '^GITHUB_CODE_AGENT_PAT=..*' /data/secrets.env 2>/dev/null; then
  sudo systemctl enable code-agent-manager.service >/dev/null
  # RESTART, not `enable --now`. `--now` means `start`, which is a NO-OP on a
  # unit that is already running — so every deploy after the first one shipped
  # a new code-agent-manager.py to disk and left the old process serving it,
  # while printing the success line below. goose-serve (:244) is restarted
  # explicitly for exactly this reason; this unit was the one that was not.
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

sudo systemctl enable goose-serve.service >/dev/null

# ------------------------------------------------------------ schedules
# BEFORE the restart on purpose: goose serve's scheduler reads schedule.json
# once at startup and does not hot-reload it, so a schedule registered while
# serve is running stays dormant until the next restart (verified against
# goose 1.46.0). Registering first means the restart below picks everything up.
echo "==> Registering automation schedules"
bash "$REPO_DIR/scripts/vps/register-schedules.sh"

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
