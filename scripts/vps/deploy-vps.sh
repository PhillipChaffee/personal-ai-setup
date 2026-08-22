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
GOOSE_DATA_DIR="/data/goose-data"
GOOSE_CONFIG_DIR="$HOME/.config/goose"
SERVE_PORT=3284

usage() {
  cat <<'EOF'
Usage: deploy-vps.sh [REPO_URL]

Deploys/upgrades the brain: repo clone or pull, goose config install,
encrypted data-dir symlink, systemd units, goose-serve start, schedule
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

# --------------------------------------------------------- goose config
# ~/.config/goose is NOT a symlink into the repo: goose writes runtime state
# (rewritten config.yaml, permission files, memory/) into it, and a symlinked
# repo dir would end up with untracked state and dirty checkouts. Instead we
# copy the templates once and never clobber — if the repo template later
# diverges from the live file, we say so and leave the merge to you.
echo "==> Installing goose config templates into $GOOSE_CONFIG_DIR"
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
fi

# ------------------------------------------- encrypted goose data dir
# ~/.local/share/goose -> /data/goose-data so sessions.db (the shared chat
# history) and schedule.json live on the LUKS volume.
echo "==> Linking ~/.local/share/goose -> $GOOSE_DATA_DIR"
GOOSE_DATA_LINK="$HOME/.local/share/goose"
mkdir -p "$HOME/.local/share"

if [[ -L "$GOOSE_DATA_LINK" ]]; then
  if [[ "$(readlink -f "$GOOSE_DATA_LINK")" != "$GOOSE_DATA_DIR" ]]; then
    echo "    replacing symlink (pointed at $(readlink "$GOOSE_DATA_LINK"))"
    rm "$GOOSE_DATA_LINK"
  fi
elif [[ -d "$GOOSE_DATA_LINK" ]]; then
  if [[ -d "$GOOSE_DATA_DIR" && -n "$(ls -A "$GOOSE_DATA_DIR" 2>/dev/null)" ]]; then
    BACKUP="$GOOSE_DATA_LINK.pre-deploy.$(date +%Y%m%d%H%M%S)"
    echo "    both $GOOSE_DATA_LINK and $GOOSE_DATA_DIR have content — keeping the"
    echo "    encrypted copy; moving the local dir aside to $BACKUP"
    echo "    (verify sessions look right, then delete the backup — it is on the UNencrypted root disk)"
    mv "$GOOSE_DATA_LINK" "$BACKUP"
  else
    echo "    migrating existing $GOOSE_DATA_LINK onto the encrypted volume"
    mv "$GOOSE_DATA_LINK" "$GOOSE_DATA_DIR"
  fi
fi
mkdir -p "$GOOSE_DATA_DIR"
[[ -L "$GOOSE_DATA_LINK" ]] || ln -s "$GOOSE_DATA_DIR" "$GOOSE_DATA_LINK"

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
ln -sfn /data/workspace-mcp "$WMCP_LINK"

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
  sudo systemctl enable --now code-agent-manager.service >/dev/null
  echo "    code agents: enabled (manager on the tailnet, port 4300)"
else
  echo "    code agents: installed but not enabled (set OPENCODE_SERVER_PASSWORD"
  echo "    and GITHUB_CODE_AGENT_PAT in secrets.env; docs/setup/70-code-agents.md)"
fi

sudo systemctl enable goose-serve.service >/dev/null
echo "==> (Re)starting goose-serve"
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

# ------------------------------------------------------------ schedules
echo "==> Registering automation schedules"
bash "$REPO_DIR/scripts/vps/register-schedules.sh"

# -------------------------------------------------------------- summary
cat <<EOF

============================================================
Brain deployed. goose serve is listening on $TS_IP:$SERVE_PORT (tailnet-only,
TLS, shared-secret auth) with the scheduler enabled.

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
  6. Code agents (if enabled — docs/setup/70-code-agents.md):
       $REPO_DIR/scripts/verify/check-code-agents.sh --probe

Upgrades later: git pull happens automatically — just re-run this script.
============================================================
EOF
