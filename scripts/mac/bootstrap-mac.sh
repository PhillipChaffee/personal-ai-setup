#!/usr/bin/env bash
# bootstrap-mac.sh — one-shot Mac setup for the personal-ai stack.
#
# Installs (via Homebrew): goose CLI + Goose Desktop, OpenCode, uv, node, jq,
# Tailscale; pins the goose CLI formula; lays down the repo's config templates
# into ~/.config plus the ported skills (~/.agents/skills — read by both
# OpenCode and goose), OpenCode agents, and global AGENTS.md rules (never
# overwriting existing files). Idempotent — safe to re-run after a failed
# step. See docs/setup/20-mac-setup.md and docs/cursor-port.md.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bootstrap-mac.sh [--help]

Installs the Mac toolchain for the personal-ai setup and copies the repo's
config templates (no-clobber) into place. Run it from your clone of the repo;
re-running is safe. Follow-ups it will point you at: keychain-secrets.sh,
OpenCode /connect, and the scripts/verify/ checks.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "bootstrap-mac.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

if [ "$(uname -s)" != "Darwin" ]; then
  echo "bootstrap-mac.sh: this script is macOS-only (Mac surface setup)." >&2
  echo "The VPS brain is provisioned by infra/terraform + scripts/vps/ instead." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "==> personal-ai Mac bootstrap (repo: $REPO_ROOT)"

# ---------------------------------------------------------------- Homebrew --
if ! command -v brew >/dev/null 2>&1; then
  cat >&2 <<'EOF'
Homebrew is not installed. Install it first (it will ask for your password):

    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

then open a new terminal (so `brew` is on PATH) and re-run this script.
Reference: https://brew.sh
EOF
  exit 1
fi

# --------------------------------------------------------------- Formulae ---
# anomalyco/tap/opencode: OpenCode's official Homebrew tap (https://opencode.ai/docs)
FORMULAE="block-goose-cli anomalyco/tap/opencode uv node jq"

for formula in $FORMULAE; do
  short="${formula##*/}"   # tap-qualified names: check by short name
  if brew list --formula --versions "$short" >/dev/null 2>&1; then
    echo "==> $short already installed — skipping"
  else
    echo "==> brew install $formula"
    brew install "$formula"
  fi
done

# ----------------------------------------------------------------- Casks ----
for cask in block-goose tailscale; do
  if brew list --cask --versions "$cask" >/dev/null 2>&1; then
    echo "==> cask $cask already installed — skipping"
  else
    echo "==> brew install --cask $cask"
    brew install --cask "$cask"
  fi
done

echo "NOTE: Tailscale was installed as the standalone app. Launch it once and"
echo "      sign in to your tailnet (docs/setup/10-accounts.md). If you already"
echo "      use the App Store version, keep that one and 'brew uninstall --cask"
echo "      tailscale' — the two variants conflict."

# ------------------------------------------------------------------- Pin ----
# goose releases roughly weekly and 2.0 is in RC churn; the whole setup is
# built against pinned 1.x. Unpin deliberately (brew unpin block-goose-cli)
# when you decide to upgrade, and upgrade the brain in the same sitting.
if brew list --pinned 2>/dev/null | grep -qx "block-goose-cli"; then
  echo "==> block-goose-cli already pinned"
else
  echo "==> brew pin block-goose-cli (goose 2.0 churn — upgrades are opt-in)"
  brew pin block-goose-cli
fi
echo "NOTE: casks can't be pinned; open Goose Desktop's settings and turn OFF"
echo "      automatic updates so Desktop stays on the same major as the CLI."

# ------------------------------------------------------- Config templates ---
# No-clobber on purpose: your local edits (e.g. a base_url variant fix from
# check-goose.sh) must survive re-runs.
copy_no_clobber() {
  # $1 = source file, $2 = destination file
  if [ -e "$2" ]; then
    echo "    kept existing $2"
  else
    cp "$1" "$2"
    echo "    installed $2"
  fi
}

echo "==> Installing config templates (no-clobber)"
mkdir -p "$HOME/.config/goose/custom_providers" "$HOME/.config/opencode"

copy_no_clobber "$REPO_ROOT/config/goose/config.yaml" "$HOME/.config/goose/config.yaml"
for provider_json in "$REPO_ROOT"/config/goose/custom_providers/*.json; do
  copy_no_clobber "$provider_json" "$HOME/.config/goose/custom_providers/$(basename "$provider_json")"
done
copy_no_clobber "$REPO_ROOT/config/goose/goosehints.example" "$HOME/.config/goose/.goosehints"
copy_no_clobber "$REPO_ROOT/config/opencode/opencode.json" "$HOME/.config/opencode/opencode.json"

echo "    (edit ~/.config/goose/.goosehints — replace the <placeholders> with"
echo "     your name, email, and timezone)"

# ------------------------------------------- Skills, agents, global rules ---
# Ported from PhillipChaffee/.cursor (docs/cursor-port.md). One skills target
# serves both tools: ~/.agents/skills/ is read by OpenCode ("agent-compatible"
# global dir) AND by goose >= 1.16's built-in skills support. OpenCode agents
# and the global AGENTS.md are OpenCode-only. Same no-clobber rule: a skill
# directory or agent file you've edited locally is never overwritten.
echo "==> Installing skills, OpenCode agents, and global rules (no-clobber)"
mkdir -p "$HOME/.agents/skills" "$HOME/.config/opencode/agents"

# Copy each skill atomically (temp dir + mv): an interrupted cp -R must not
# leave a partial skill dir that the no-clobber rule would then keep forever.
rm -rf "$HOME/.agents/skills"/.personal-ai-tmp.* 2>/dev/null || true
for skill_dir in "$REPO_ROOT"/config/skills/*/; do
  [ -d "$skill_dir" ] || continue
  skill_name="$(basename "$skill_dir")"
  if [ -e "$HOME/.agents/skills/$skill_name" ]; then
    echo "    kept existing ~/.agents/skills/$skill_name"
  else
    tmp_dir="$HOME/.agents/skills/.personal-ai-tmp.$skill_name"
    cp -R "$skill_dir" "$tmp_dir"
    mv "$tmp_dir" "$HOME/.agents/skills/$skill_name"
    echo "    installed ~/.agents/skills/$skill_name"
  fi
done

for agent_md in "$REPO_ROOT"/config/opencode/agents/*.md; do
  [ -f "$agent_md" ] || continue
  copy_no_clobber "$agent_md" "$HOME/.config/opencode/agents/$(basename "$agent_md")"
done

copy_no_clobber "$REPO_ROOT/config/opencode/AGENTS.md" "$HOME/.config/opencode/AGENTS.md"
echo "    (project-specific rule snippets stay in the repo:"
echo "     config/opencode/project-rules/ — see docs/cursor-port.md)"

# -------------------------------------------------------------- Next steps --
cat <<EOF

==> Bootstrap done. Next steps (docs/setup/20-mac-setup.md):

  1. Store your API keys in the macOS Keychain:
         $SCRIPT_DIR/keychain-secrets.sh
     then open a NEW terminal so the exported vars are live.

  2. Wire OpenCode to Zen: run 'opencode' in any project, type /connect,
     pick OpenCode Zen, paste your key. Set the daily model per
     docs/model-routing.md (kimi-k2.6).

  3. Verify before going further:
         $REPO_ROOT/scripts/verify/check-providers.sh   # raw HTTPS per endpoint
         $REPO_ROOT/scripts/verify/check-goose.sh       # goose through all 3 providers
EOF
