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
# THE INSTALL IS FIVE UNITS: unit_base_toolchain, unit_base_goose, unit_opencode,
# unit_base_skills, unit_coding_pack, called in that (dependency) order at the
# bottom of this file. Each one is the installer named by a manifest in
# config/units/ -- config/units/base-goose.yaml's `installer.function`, for
# instance, is checked against this file by scripts/verify/check-units.sh, so a
# renamed function or an uncalled one is a failing gate rather than a comment
# that went stale. They all run today; choosing between them is the next change.
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

# ---------------------------------------------------------- Shared helpers --
# These four are TOP LEVEL and they stay top level. The install below IS a set
# of per-unit functions now (unit_base_toolchain, unit_base_goose, ...), and a
# helper defined inside one of those is not defined until that one has RUN --
# bash only globalises a nested definition after the outer function returns. A
# selective install that skips the defining unit would then die at
# `command not found` under `set -e`, on a machine nobody can debug from here.
# copy_no_clobber is the concrete case: it used to be defined in the middle of
# the config-templates step and is called from three of the five units.
#
# Each brew helper takes ONE argument: a space-separated package list, split
# inside the function on purpose. `brew_formula "$FORMULAE_BASE_TOOLCHAIN"`
# keeps the unquoted expansion (and the SC2086 argument about it) in one place
# instead of at every call site.

brew_formula() {
  # $1 = space-separated formula names; tap-qualified names are allowed.
  local formula short
  for formula in $1; do
    short="${formula##*/}"   # tap-qualified names: check by short name
    if pai_exec brew list --formula --versions "$short" >/dev/null 2>&1; then
      echo "==> $short already installed — skipping"
    else
      echo "==> brew install $formula"
      pai_exec brew install "$formula"
    fi
  done
}

brew_cask() {
  # $1 = space-separated cask names.
  local cask
  for cask in $1; do
    if pai_exec brew list --cask --versions "$cask" >/dev/null 2>&1; then
      echo "==> cask $cask already installed — skipping"
    else
      echo "==> brew install --cask $cask"
      pai_exec brew install --cask "$cask"
    fi
  done
}

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

install_skill() {
  # $1 = a skill source directory under config/skills/. Copies it into
  # ~/.agents/skills atomically (temp dir + mv), no-clobber: an interrupted
  # `cp -R` must not leave a partial skill dir that no-clobber then keeps
  # forever. The caller creates ~/.agents/skills and sweeps stale temps.
  local skill_name tmp_dir
  skill_name="$(basename "$1")"
  if [ -e "$HOME/.agents/skills/$skill_name" ]; then
    echo "    kept existing ~/.agents/skills/$skill_name"
  else
    tmp_dir="$HOME/.agents/skills/.personal-ai-tmp.$skill_name"
    cp -R "$1" "$tmp_dir"
    mv "$tmp_dir" "$HOME/.agents/skills/$skill_name"
    echo "    installed ~/.agents/skills/$skill_name"
  fi
}

# ------------------------------------------------- Per-unit package lists ---
# One list per unit, and they are GLOBALS rather than `local`s inside the unit
# functions below for two concrete reasons: install-test.yml's negative test
# mutates `^FORMULAE_BASE_TOOLCHAIN=` to prove the brew golden can fail, and the
# `--dry-run` planner (#37's flag surface) has to read them BEFORE any unit body
# runs. A list that moved inside a function would still be sed-able and the
# negative test would report the golden as inert when the only inert thing is
# the sed.
#
# THE EMISSION ORDER IS NOW THE UNIT ORDER, not this declaration order: each
# list is consumed by exactly one unit_*() below, and the units run in
# dependency order. That reordering is what the 16-line golden in
# test-base-install.sh was re-typed for.
FORMULAE_BASE_TOOLCHAIN="uv node jq"
FORMULAE_BASE_GOOSE="block-goose-cli"
# anomalyco/tap/opencode: OpenCode's official Homebrew tap (https://opencode.ai/docs)
FORMULAE_OPENCODE="anomalyco/tap/opencode"

# The eleven Cursor-ported skills, ENUMERATED and never "everything in
# config/skills/ except connect-service". The complement would install a future
# skill silently, would make `--without opencode` quietly install it anyway, and
# would make coding-pack.yaml's `owns` list decorative instead of authoritative.
# This list is the manifest's list: config/units/coding-pack.yaml `owns` the
# same eleven names as repo_file entries, and units_lint's totality check
# (#37's flag surface) is what will fail a twelfth that neither unit claims.
SKILLS_CODING_PACK="ci-lint-test clean-plan code-review deep-research
looping-code-review looping-plan-review mr-review plan-review
pre-mr-checklist refactor-planner ship"

# ------------------------------------------------------------- The units ----
# Below this line the install is five functions, one per config/units/*.yaml
# manifest that names this script. They run unconditionally today: the
# selection flags (--with/--without/--only/--dry-run) are the next change, and
# splitting "what the pieces are" from "which pieces you get" keeps the carve
# provable by test-base-install.sh's A14b -- the pre-carve installer and this
# one write the same $HOME.
#
# FOUR RULES FOR THESE BODIES. Every one of them is a measured failure mode of
# `set -euo pipefail`, not a style preference:
#
#   1. EVERY BODY ENDS IN `return 0`. A function whose last executed command is
#      false returns false, and a bare call to it aborts the whole script.
#      Before the carve this same text sat mid-script with lines after it, so a
#      false tail was harmless; inside a function it is fatal, and it fails as
#      "the bootstrap stopped" rather than as "this unit is wrong".
#   2. EVERY CALL SITE IS A BARE COLUMN-0 LINE -- never `if unit_x; then`,
#      never `unit_x || die`. A function called from an `if` condition runs its
#      WHOLE body with errexit disabled, so a failing `brew install` in the
#      middle of a unit would stop aborting and the bootstrap would exit 0
#      having installed half of it. units_lint.py's P3 accepts the `if` form,
#      which is exactly why the rule is written here instead of left to it.
#   3. NO `local X="$(cmd)"` (SC2155): `local` succeeds whatever the command
#      substitution did, so the failure is swallowed. Declare, then assign.
#   4. THE SKILLS FILTER IS `|| continue`, never `[ ... ] && install_skill ...`
#      -- that is rule 1 again. `ship` sorts last, so on the final iteration the
#      `&&` list is false, the `for` inherits that status, and the unit returns
#      false after having done all of its work.

unit_base_toolchain() {
  brew_formula "$FORMULAE_BASE_TOOLCHAIN"
  brew_cask "tailscale"

  echo "NOTE: Tailscale was installed as the standalone app. Launch it once and"
  echo "      sign in to your tailnet (docs/setup/10-accounts.md). If you already"
  echo "      use the App Store version, keep that one and 'brew uninstall --cask"
  echo "      tailscale' — the two variants conflict."
  return 0
}

unit_base_goose() {
  # pin_py is an array (`read -r -a`) because it is a COMMAND, not a string:
  # `uv run --quiet --with pyyaml python` is five words and "${pin_py[@]}"
  # keeps them five words without a re-split of the whole command line.
  local pin_file want_goose have_goose provider_json
  local -a pin_py

  brew_formula "$FORMULAE_BASE_GOOSE"
  brew_cask "block-goose"

  # ------------------------------------------------------------------- Pin --
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
  # cannot install an arbitrary prior release without a versioned formula, so
  # this side ASSERTS rather than installs — one source of truth, and only the
  # side that can honour it exactly is asked to. See config/pins.yaml.
  pin_file="$REPO_ROOT/config/pins.yaml"
  if [ -r "$pin_file" ]; then
    # The repo's usual ladder: python3 with PyYAML, else uv (installed above).
    if python3 -c 'import yaml' >/dev/null 2>&1; then
      read -r -a pin_py <<<"python3"
    else
      read -r -a pin_py <<<"uv run --quiet --with pyyaml python"
    fi
    want_goose="$("${pin_py[@]}" -c \
      'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["goose"]["version"])' \
      "$pin_file" 2>/dev/null || true)"
    # `goose --version` prints a bare version on 1.x; take the first
    # version-shaped token so a future format change degrades to "cannot tell"
    # rather than a spurious mismatch.
    have_goose="$(pai_exec goose --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    if [ -z "$want_goose" ] || [ -z "$have_goose" ]; then
      echo "NOTE: could not compare the goose version against config/pins.yaml"
      echo "      (want='${want_goose:-?}' have='${have_goose:-?}') — skipping the check."
    elif [ "$want_goose" = "$have_goose" ]; then
      echo "==> goose $have_goose matches config/pins.yaml"
    else
      echo "WARNING: goose $have_goose is installed; config/pins.yaml says $want_goose."
      echo "         The brain installs exactly $want_goose, so the two surfaces differ."
      echo "         Fix: brew unpin block-goose-cli && brew upgrade block-goose-cli"
      echo "         && brew pin block-goose-cli — or bump config/pins.yaml if $have_goose"
      echo "         is what you actually want, and re-provision the brain to match."
    fi
  fi

  # -------------------------------------------------- goose config templates --
  echo "==> Installing goose config templates (no-clobber)"
  mkdir -p "$HOME/.config/goose/custom_providers"

  copy_no_clobber "$REPO_ROOT/config/goose/config.yaml" "$HOME/.config/goose/config.yaml"
  for provider_json in "$REPO_ROOT"/config/goose/custom_providers/*.json; do
    copy_no_clobber "$provider_json" "$HOME/.config/goose/custom_providers/$(basename "$provider_json")"
  done
  copy_no_clobber "$REPO_ROOT/config/goose/goosehints.example" "$HOME/.config/goose/.goosehints"

  echo "    (edit ~/.config/goose/.goosehints — replace the <placeholders> with"
  echo "     your name, email, and timezone)"
  return 0
}

unit_opencode() {
  brew_formula "$FORMULAE_OPENCODE"

  # ~/.config/opencode is created HERE and nowhere else, which is what makes a
  # future `--without opencode` assertable as an ABSENCE rather than as an
  # empty directory. coding-pack creates its own agents/ subdirectory.
  echo "==> Installing the OpenCode config template (no-clobber)"
  mkdir -p "$HOME/.config/opencode"
  copy_no_clobber "$REPO_ROOT/config/opencode/opencode.json" "$HOME/.config/opencode/opencode.json"
  return 0
}

unit_base_skills() {
  # One skills target serves both tools: ~/.agents/skills/ is read by OpenCode
  # ("agent-compatible" global dir) AND by goose >= 1.16's built-in skills
  # support. This unit owns exactly one of the shipped skills, connect-service;
  # coding-pack owns the Cursor-ported rest and creates the same directory
  # itself, because neither unit requires the other.
  local skill_dir skill_name

  echo "==> Installing the connect-service skill (no-clobber)"
  mkdir -p "$HOME/.agents/skills"

  # Sweep first: a leftover temp from an interrupted run is a partial skill
  # dir, and install_skill's `mv` would otherwise inherit it. `|| true` and
  # idempotent, so both skill-installing units run it.
  rm -rf "$HOME/.agents/skills"/.personal-ai-tmp.* 2>/dev/null || true

  for skill_dir in "$REPO_ROOT"/config/skills/*/; do
    [ -d "$skill_dir" ] || continue
    skill_name="$(basename "$skill_dir")"
    # `|| continue`, NOT `&& install_skill`. See rule 4 above: `ship` sorts
    # last, so the `&&` form would leave this function returning false after a
    # completely successful install.
    [ "$skill_name" = connect-service ] || continue
    install_skill "$skill_dir"
  done
  return 0
}

unit_coding_pack() {
  # Ported from PhillipChaffee/.cursor (docs/cursor-port.md): eleven skills, the
  # OpenCode subagents, and the global AGENTS.md. The agents and AGENTS.md are
  # OpenCode-only. Same no-clobber rule throughout: a skill directory or agent
  # file you have edited locally is never overwritten.
  local skill_name agent_md

  echo "==> Installing skills, OpenCode agents, and global rules (no-clobber)"
  mkdir -p "$HOME/.agents/skills" "$HOME/.config/opencode/agents"
  rm -rf "$HOME/.agents/skills"/.personal-ai-tmp.* 2>/dev/null || true

  # By name, from SKILLS_CODING_PACK — deliberately NOT a glob, and deliberately
  # unguarded: a name in that list with no directory in the repo is a bug in the
  # list, and `cp -R` failing loudly under `set -e` is how it gets found.
  for skill_name in $SKILLS_CODING_PACK; do
    install_skill "$REPO_ROOT/config/skills/$skill_name"
  done

  for agent_md in "$REPO_ROOT"/config/opencode/agents/*.md; do
    [ -f "$agent_md" ] || continue
    copy_no_clobber "$agent_md" "$HOME/.config/opencode/agents/$(basename "$agent_md")"
  done

  copy_no_clobber "$REPO_ROOT/config/opencode/AGENTS.md" "$HOME/.config/opencode/AGENTS.md"
  echo "    (project-specific rule snippets stay in the repo:"
  echo "     config/opencode/project-rules/ — see docs/cursor-port.md)"
  return 0
}

# THE FIVE CALLS. Bare, column 0, contiguous, and with no comment, no `if` and
# no `||` on the call lines themselves — see rule 2 above, and note that
# units_lint.py's P3 counts these lexically (`^unit_x$`), so a trailing space or
# a wrapper changes what the manifests are checked against.
#
# The order is a topological order of the manifest graph restricted to these
# five: base-goose needs base-toolchain, opencode needs base-goose, base-skills
# needs base-goose, coding-pack needs opencode. (base-secrets is in base-goose's
# `requires` and has no installer at all, so it is elided rather than ordered.)
unit_base_toolchain
unit_base_goose
unit_opencode
unit_base_skills
unit_coding_pack

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
