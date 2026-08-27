#!/usr/bin/env bash
# keychain-secrets.sh — put the setup's secrets in the macOS Keychain and wire
# your shell to export them from there. Nothing is ever written to disk in
# plaintext, and values are never echoed.
#
# Storage: security add-generic-password -s personal-ai -a <VARNAME>
# Readback: security find-generic-password -w -s personal-ai -a <VARNAME>
# Roster: config/env/secrets.env.example (same variable names everywhere).
set -euo pipefail

SERVICE="personal-ai"
VARS="OPENCODE_ZEN_API_KEY TOGETHER_API_KEY GOOSE_SERVER__SECRET_KEY NTFY_TOPIC NTFY_AGENT_TOPIC NTFY_EMAIL TELEGRAM_BOT_TOKEN TAVILY_API_KEY GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET"
ZSHRC="$HOME/.zshrc"
MARKER_BEGIN="# >>> personal-ai keychain exports (keychain-secrets.sh) >>>"
MARKER_END="# <<< personal-ai keychain exports <<<"

usage() {
  cat <<EOF
Usage: keychain-secrets.sh [--help]

Prompts (silently) for each secret in the canonical roster and stores it in
the macOS Keychain under service "$SERVICE". Press Enter at any prompt to
skip it (an already-stored value is kept). Afterwards it offers to append an
export block to ~/.zshrc that reads the values back from the Keychain at
shell init.

Roster: $VARS
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "keychain-secrets.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

if [ "$(uname -s)" != "Darwin" ]; then
  echo "keychain-secrets.sh: macOS-only (uses the Keychain via 'security')." >&2
  echo "On the brain, secrets live in /data/secrets.env instead — see" >&2
  echo "config/env/secrets.env.example." >&2
  exit 1
fi

hint_for() {
  case "$1" in
    OPENCODE_ZEN_API_KEY)       echo "Zen console key — docs/setup/10-accounts.md §1" ;;
    TOGETHER_API_KEY)           echo "Together AI key — docs/setup/10-accounts.md §2" ;;
    GOOSE_SERVER__SECRET_KEY)   echo "goose serve shared secret; generate: openssl rand -hex 32" ;;
    NTFY_TOPIC)                 echo "ntfy topic name (IS a password); generate: openssl rand -hex 12" ;;
    NTFY_AGENT_TOPIC)           echo "SECOND ntfy topic, for code-agent buzzes — the one the phone subscribes to; generate: openssl rand -hex 12" ;;
    TAVILY_API_KEY)             echo "optional — only if the tavily extension is enabled" ;;
    GOOGLE_OAUTH_CLIENT_ID)     echo "GCP OAuth client — added in Phase 2 (docs/setup/30-google-oauth.md)" ;;
    GOOGLE_OAUTH_CLIENT_SECRET) echo "GCP OAuth client secret — Phase 2" ;;
    *)                          echo "" ;;
  esac
}

if [ ! -t 0 ]; then
  echo "keychain-secrets.sh: needs an interactive terminal (secrets are typed" >&2
  echo "at hidden prompts, never passed as arguments or piped)." >&2
  exit 2
fi

echo "==> Storing secrets in the macOS Keychain (service: $SERVICE)"
echo "    Input is hidden. Press Enter to skip a variable."
echo

STORED=0
for var in $VARS; do
  state="not stored yet"
  if security find-generic-password -s "$SERVICE" -a "$var" >/dev/null 2>&1; then
    state="already stored — Enter keeps it"
  fi
  echo "  $var  ($(hint_for "$var"))"
  # -s: silent read — the value never appears on screen or in history
  read -r -s -p "    value [$state]: " secret
  echo
  if [ -z "$secret" ]; then
    echo "    skipped"
    continue
  fi
  # -U updates in place if the item already exists. The value passes through
  # this process's argv (briefly visible in `ps`) — accepted on a single-user
  # Mac; it never touches disk or shell history.
  security add-generic-password -U -s "$SERVICE" -a "$var" -w "$secret"
  secret=""
  echo "    stored"
  STORED=$((STORED + 1))
done
echo
echo "==> Done: $STORED value(s) written."

# ------------------------------------------------------- shell export block --
# Build the block that reads each secret back from the Keychain at shell
# init. Missing/skipped items export as empty strings (stderr silenced) so a
# partial roster never breaks shell startup.
BLOCK="$MARKER_BEGIN"$'\n'
for var in $VARS; do
  BLOCK="$BLOCK$(printf 'export %s="$(security find-generic-password -w -s %s -a %s 2>/dev/null || true)"' "$var" "$SERVICE" "$var")"$'\n'
done
BLOCK="$BLOCK$MARKER_END"

if [ -f "$ZSHRC" ] && grep -qF "$MARKER_BEGIN" "$ZSHRC"; then
  echo "==> ~/.zshrc already has the export block — leaving it alone."
  echo "    (If the roster ever changes, delete the block between the"
  echo "    personal-ai markers and re-run this script.)"
else
  echo
  echo "==> This block makes every new shell export the secrets from the Keychain:"
  echo
  echo "$BLOCK"
  echo
  APPEND="n"
  if [ -t 0 ]; then
    read -r -p "Append it to $ZSHRC now? [y/N] " APPEND
  else
    echo "(no TTY — not appending automatically; add the block yourself)"
  fi
  case "$APPEND" in
    y|Y|yes|YES)
      { echo; echo "$BLOCK"; } >>"$ZSHRC"
      echo "==> Appended to $ZSHRC."
      ;;
    *)
      echo "==> Not appended. Paste the block into your shell init file manually."
      ;;
  esac
fi

cat <<'EOF'

Next:
  * Open a NEW terminal so the exports are live, then sanity-check:
        echo "${OPENCODE_ZEN_API_KEY:0:6}..."
  * GUI apps launched from Finder (Goose Desktop) do NOT read ~/.zshrc. If
    Desktop reports a missing API key while the CLI works, either launch it
    from a terminal once (open -a Goose) or load a key into the GUI session:
        launchctl setenv OPENCODE_ZEN_API_KEY \
          "$(security find-generic-password -w -s personal-ai -a OPENCODE_ZEN_API_KEY)"
    (repeat per variable; launchctl setenv does not survive a reboot).
  * Never set GOOSE_DISABLE_KEYRING on this Mac — it downgrades goose's own
    secret storage to a plaintext file (docs/security.md).
EOF
