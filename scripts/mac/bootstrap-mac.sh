#!/usr/bin/env bash
# bootstrap-mac.sh — one-shot Mac setup for the personal-ai stack.
#
# Installs (via Homebrew): goose CLI + Goose Desktop, OpenCode, uv, node, jq,
# Tailscale; pins the goose CLI formula; lays down the repo's config templates
# into ~/.config plus the ported skills (~/.agents/skills — read by both
# OpenCode and goose), OpenCode agents, and global AGENTS.md rules (never
# overwriting existing files). Idempotent — safe to re-run after a failed
# step. See docs/setup/20-mac-setup.md and docs/cursor-port.md.
#
# PAI_EXEC — TESTING/DEV ONLY, never set this on a real Mac. When set, it must
# name an executable under <this repo>/scripts/verify/ (enforced below, exit 2),
# and every external binary this script invokes goes to it instead: `pai_exec
# uname -s`, `pai_exec brew ...`, `pai_exec goose --version`, and `pai_have brew`
# for the presence probe (`have` is a seam VERB, not a binary name). Unset, both
# helpers are strict no-ops -- `${PAI_EXEC:+...}` expands to nothing, so the
# command runs verbatim with its own exit status, redirections and pipes. What
# does NOT go through the seam, on purpose: mkdir/cp/mv/rm (a fake $HOME
# substitutes for all of them, which keeps the no-clobber and atomic-skill
# logic REAL), and python3/uv (local compute over config/pins.yaml -- routing
# them would fake away the pin comparison). scripts/verify/fake-exec.sh is the
# only implementation; scripts/verify/test-base-install.sh drives it.
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

# Hoisted ABOVE the platform guard, because the guard now consults the seam and
# the containment check below needs REPO_ROOT. cd/dirname/pwd/BASH_SOURCE are
# pure and platform-independent, so moving them past a `uname` test changes
# nothing about what the script does.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# THE SEAM. See the PAI_EXEC paragraph in this file's header.
#
# `${PAI_EXEC:+"$PAI_EXEC"}` expands to NOTHING when unset -- not to an empty
# word -- so "$@" runs verbatim. `:+` is also one of the expansions `set -u`
# does not fault on, which is why no call site needs a guard. The body is a
# single command, so the function's exit status IS the call's, and redirections
# or pipes written on the call attach to it exactly as before.
pai_exec() { ${PAI_EXEC:+"$PAI_EXEC"} "$@"; }

# The presence half. `command -v` is a shell builtin consulting PATH, so it
# cannot be handed to an external dispatcher; `have` is a seam VERB that the
# dispatcher answers from a fixed allowlist.
pai_have() {
  if [ -n "${PAI_EXEC:-}" ]; then
    pai_exec have "$1"
  else
    command -v "$1" >/dev/null 2>&1
  fi
}

# CONTAINMENT, and it is a gate rather than a banner. Routing `uname` through
# the seam means a program outside this script now answers "what OS is this",
# so three independent things must go wrong before a real machine is at risk:
# PAI_EXEC must be set at all, it must point INSIDE this repo's scripts/verify/,
# and fake-exec.sh itself refuses every call unless $HOME is under
# $PAI_FAKE_ROOT. The `-x` test matters for a reason that is not obvious: an
# unexecutable PAI_EXEC yields an empty command substitution inside the `if`
# below -- which does not trip `set -e` -- so "" != "Darwin" and a Mac user is
# told the script is macOS-only. That is the seam failing in a way
# indistinguishable from running on Linux.
if [ -n "${PAI_EXEC:-}" ]; then
  case "$PAI_EXEC" in
    "$REPO_ROOT"/scripts/verify/*) ;;
    *) echo "bootstrap-mac.sh: PAI_EXEC must be a file under $REPO_ROOT/scripts/verify/" >&2
       exit 2 ;;
  esac
  [ -x "$PAI_EXEC" ] || {
    echo "bootstrap-mac.sh: PAI_EXEC is set but not executable: $PAI_EXEC" >&2
    exit 2
  }
fi

if [ "$(pai_exec uname -s)" != "Darwin" ]; then
  echo "bootstrap-mac.sh: this script is macOS-only (Mac surface setup)." >&2
  echo "The VPS brain is provisioned by infra/terraform + scripts/vps/ instead," >&2
  echo "and it runs Linux — goose itself is not the Mac-only part." >&2
  echo "" >&2
  echo "What is Mac-only, and what a Linux laptop would need instead, is listed" >&2
  echo "per component in docs/setup/00-overview.md under 'Supported platforms'." >&2
  exit 1
fi

echo "==> personal-ai Mac bootstrap (repo: $REPO_ROOT)"

# ---------------------------------------------------------------- Homebrew --
if ! pai_have brew; then
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
  if pai_exec brew list --formula --versions "$short" >/dev/null 2>&1; then
    echo "==> $short already installed — skipping"
  else
    echo "==> brew install $formula"
    pai_exec brew install "$formula"
  fi
done

# ----------------------------------------------------------------- Casks ----
for cask in block-goose tailscale; do
  if pai_exec brew list --cask --versions "$cask" >/dev/null 2>&1; then
    echo "==> cask $cask already installed — skipping"
  else
    echo "==> brew install --cask $cask"
    pai_exec brew install --cask "$cask"
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
if pai_exec brew list --pinned 2>/dev/null | grep -qx "block-goose-cli"; then
  echo "==> block-goose-cli already pinned"
else
  echo "==> brew pin block-goose-cli (goose 2.0 churn — upgrades are opt-in)"
  pai_exec brew pin block-goose-cli
fi
echo "NOTE: casks can't be pinned; open Goose Desktop's settings and turn OFF"
echo "      automatic updates so Desktop stays on the same major as the CLI."

# The pin above freezes whatever brew INSTALLED; it does not choose a version.
# config/pins.yaml does, and the brain's cloud-init installs exactly it. Brew
# cannot install an arbitrary prior release without a versioned formula, so this
# side ASSERTS rather than installs — one source of truth, and only the side
# that can honour it exactly is asked to. See config/pins.yaml for the argument.
PIN_FILE="$REPO_ROOT/config/pins.yaml"
if [ -r "$PIN_FILE" ]; then
  # The repo's usual ladder: python3 with PyYAML, else uv (installed above).
  if python3 -c 'import yaml' >/dev/null 2>&1; then
    read -r -a PIN_PY <<<"python3"
  else
    read -r -a PIN_PY <<<"uv run --quiet --with pyyaml python"
  fi
  WANT_GOOSE="$("${PIN_PY[@]}" -c \
    'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["goose"]["version"])' \
    "$PIN_FILE" 2>/dev/null || true)"
  # `goose --version` prints a bare version on 1.x; take the first version-shaped
  # token so a future format change degrades to "cannot tell" rather than a
  # spurious mismatch.
  HAVE_GOOSE="$(pai_exec goose --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  if [ -z "$WANT_GOOSE" ] || [ -z "$HAVE_GOOSE" ]; then
    echo "NOTE: could not compare the goose version against config/pins.yaml"
    echo "      (want='${WANT_GOOSE:-?}' have='${HAVE_GOOSE:-?}') — skipping the check."
  elif [ "$WANT_GOOSE" = "$HAVE_GOOSE" ]; then
    echo "==> goose $HAVE_GOOSE matches config/pins.yaml"
  else
    echo "WARNING: goose $HAVE_GOOSE is installed; config/pins.yaml says $WANT_GOOSE."
    echo "         The brain installs exactly $WANT_GOOSE, so the two surfaces differ."
    echo "         Fix: brew unpin block-goose-cli && brew upgrade block-goose-cli"
    echo "         && brew pin block-goose-cli — or bump config/pins.yaml if $HAVE_GOOSE"
    echo "         is what you actually want, and re-provision the brain to match."
  fi
fi

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
