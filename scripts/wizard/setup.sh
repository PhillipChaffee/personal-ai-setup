#!/usr/bin/env bash
#
# The repo's front door: one wizard that sets up the whole personal-ai stack.
#
# Run it once from a clone of this repo, on the Mac. It asks six questions in a
# fixed order (the #137 flow, amended by #138 and #149) and then drives the two
# installers: scripts/mac/bootstrap-mac.sh locally, and scripts/vps/deploy-vps.sh
# over SSH on the brain. It stores what it captured in the local .env (this file
# is gitignored), writes exactly the keys it captured or generated into
# /data/secrets.env over SSH, and prints everything a human must do by hand.
#
# THE FLOW IS FIXED. #137 agreed the six questions and their order; #138 fixed
# the per-agent semantics (the matrix, the vendor-first biller question, the
# capture set); #149 landed the herdr plane this wizard drives:
#
#   1. Scope        fresh end-to-end, or configure the existing ai-brain.
#                   The one fork. Both answers run both installers; existing
#                   adds the one-time teardown checklist before the deploy.
#   2. Coding agents — one multi-pick screen. OpenCode + Pi first-class
#      (pre-checked), Claude Code / Codex / Grok Build in the catalog. Gemini
#      CLI was cut by #138 (Google-only auth, no herdr integration). Drives
#      the brain's `deploy-vps.sh --with herdr --coding-agents <picked>`.
#      A claude-code or codex pick asks its biller: vendor key first
#      (displayed default), Zen only by explicit choice. Nothing defaults
#      to Zen (#138); the default biller is Together AI.
#   3. Mac extras — connectors (a hand edit; nothing to install, nothing to
#      flag). The phone checklist died with the phone story (2026-09-22, #140).
#   4. Provisioning / teardown — fresh: the human-only gauntlet (Tailscale
#      account and toggles, terraform apply, luks-setup.sh, the /data/secrets.env
#      fill), each behind a confirm the wizard never performs; the wizard
#      scaffolds the secrets.env SKELETON over SSH (names only, no values) and
#      prints which rows remain hand-fill. Existing: the one-time teardown
#      checklist prints as hand steps and the deploy waits behind a confirm.
#   5. Capture — the flow's only ask_secrets: the keys the picks demand
#      (Together whenever >=1 agent; the Zen key only when a Zen-billed pick
#      chose Zen; the vendor key of a vendor-billed pick; the scoped GitHub
#      PAT whenever >=1 agent) and the GENERATED goose secret. Mac-scoped
#      values land in the macOS Keychain under the same service
#      keychain-secrets.sh uses, so its roster stays the single source.
#   6. Verify + finish — the verify commands print as steps, the hand-steps
#      list closes the run, and the guarantee is stated: nothing schedules
#      anything. No scheduler flag, no timers, no recipes — the stages write
#      only the local .env and drive the two installers, and this script
#      carries none of the strings a scheduler would need (asserted by
#      scripts/verify/test-verify-checks.sh).
#
# NEVER TOUCHED, ALWAYS HUMAN: the Hetzner token and the Tailscale auth key
# (terraform's interactive prompts), the Tailscale MagicDNS/HTTPS toggles, the
# LUKS passphrase, the /data/secrets.env hand rows, coding-agent pane logins,
# Goose Desktop connect and settings, and every row of /data/secrets.env this
# wizard did not capture. The wizard never prints a captured value.
#
# Pins: config/pins.yaml is read for the goose/herdr versions the checks
# compare against; the catalog ids and their pins live in the same file
# (coding_agents:) and are the same strings deploy-vps.sh validates.

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────
# Wizard library: delightful, consistent UX, identical across every wizard.
# ──────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
  # shellcheck disable=SC2034  # RED is template.sh's canonical palette; this
  # wizard's stages never colour an error, but the palette stays byte-identical.
  RED=$(tput setaf 1)
  BLUE=$(tput setaf 4); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
else
  BOLD=""; DIM=""; RESET=""; BLUE=""; GREEN=""; YELLOW=""; RED=""
fi

# Author sets this at the top of the stages section.
TOTAL_STAGES=0

_STAGE_INDEX=0
ENV_FILE="${ENV_FILE:-.env}"
WRITTEN_ENV=()    # KEYs written to ENV_FILE this run
WRITTEN_SECRET=() # secret names set this run
SKIPPED=()        # things we couldn't do (e.g. gh missing)

# _clear wipes the terminal so only the current step is on screen. No-op when
# output isn't a terminal, so piped logs stay readable.
_clear() {
  [[ -t 1 ]] || return 0
  if command -v tput >/dev/null 2>&1; then tput clear; else printf '\033[2J\033[3J\033[H'; fi
}

# banner "Title" shows the opening frame: what this wizard does.
banner() {
  _clear
  printf '\n%s%s  %s%s\n' "$BOLD" "$BLUE" "$1" "$RESET"
  printf '%s  %s stages%s\n\n' "$DIM" "$TOTAL_STAGES" "$RESET"
  printf '%s  You drive the browser; this wizard tells you exactly what to do and\n' "$DIM"
  printf '  captures the values you copy back. Stop any time with Ctrl-C and re-run\n'
  printf '  later, since it remembers values already saved.%s\n' "$RESET"
  pause "Ready to start?"
}

# stage "Name" clears the screen, then announces a stage and shows progress.
# Clearing keeps only the current step on screen.
stage() {
  _clear
  _STAGE_INDEX=$((_STAGE_INDEX + 1))
  printf '\n%s%s▸ Stage %s/%s · %s%s\n' \
    "$BOLD" "$BLUE" "$_STAGE_INDEX" "$TOTAL_STAGES" "$1" "$RESET"
}

# say "..." prints a plain instruction line.
say()  { printf '  %s\n' "$1"; }
# step "..." is a numbered-feeling action the human takes in the browser.
step() { printf '  %s•%s %s\n' "$BLUE" "$RESET" "$1"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$RESET"; }
warn() { printf '  %s⚠ %s%s\n' "$YELLOW" "$1" "$RESET"; }

# open_url URL opens it in the human's browser, cross-platform incl. WSL.
open_url() {
  local url="$1"
  printf '  %s↗ opening%s %s\n' "$GREEN" "$RESET" "$url"
  { if   command -v wslview     >/dev/null 2>&1; then wslview "$url"
    elif command -v explorer.exe >/dev/null 2>&1; then explorer.exe "$url"
    elif command -v xdg-open    >/dev/null 2>&1; then xdg-open "$url"
    elif command -v open        >/dev/null 2>&1; then open "$url"
    else warn "couldn't open a browser; visit it manually: $url"; fi
  } >/dev/null 2>&1 || warn "couldn't open a browser, so visit it manually: $url"
}

# pause "msg" waits for the human to confirm they've done the manual part.
pause() {
  printf '  %s%s%s ' "$DIM" "${1:-Press Enter to continue}" "$RESET"
  read -r _ || true
}

# confirm "question" is a y/N gate; returns success on yes.
confirm() {
  local reply=""
  printf '  %s? %s [y/N] ' "$YELLOW" "$1"
  read -r reply || true
  [[ "$reply" =~ ^[Yy] ]]
}

# _existing KEY: current value of KEY in ENV_FILE, if any.
_existing() {
  [[ -f "$ENV_FILE" ]] || return 1
  local line; line=$(grep -E "^${1}=" "$ENV_FILE" | tail -n1) || return 1
  printf '%s' "${line#*=}"
}

# ask KEY "Prompt" reads a value into $KEY. Offers the existing .env value as
# a default on re-runs (Enter keeps it). Visible input (non-secret).
ask() {
  local key="$1" prompt="$2" current input
  current=$(_existing "$key" || true)
  if [[ -n "$current" ]]; then
    printf '  %s%s%s %s[Enter keeps current]%s ' "$BOLD" "$prompt" "$RESET" "$DIM" "$RESET"
  else
    printf '  %s%s%s ' "$BOLD" "$prompt" "$RESET"
  fi
  read -r input || true
  [[ -z "$input" && -n "$current" ]] && input="$current"
  printf -v "$key" '%s' "$input"
}

# ask_secret KEY "Prompt" is like ask, but input is hidden.
ask_secret() {
  local key="$1" prompt="$2" current input
  current=$(_existing "$key" || true)
  if [[ -n "$current" ]]; then
    printf '  %s%s%s %s[Enter keeps current]%s ' "$BOLD" "$prompt" "$RESET" "$DIM" "$RESET"
  else
    printf '  %s%s%s ' "$BOLD" "$prompt" "$RESET"
  fi
  read -rs input || true
  printf '\n'
  [[ -z "$input" && -n "$current" ]] && input="$current"
  printf -v "$key" '%s' "$input"
}

# write_env KEY VALUE upserts KEY=VALUE into ENV_FILE (creates it; replaces
# any existing line). Idempotent.
write_env() {
  local key="$1" value="$2" tmp
  touch "$ENV_FILE"
  tmp=$(mktemp)
  grep -vE "^${key}=" "$ENV_FILE" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$ENV_FILE"
  WRITTEN_ENV+=("$key")
  printf '  %s✓ wrote%s %s → %s\n' "$GREEN" "$RESET" "$key" "$ENV_FILE"
}

# set_secret NAME VALUE sets a GitHub Actions repo secret via gh. Falls back
# to a warning (and records it) if gh is unavailable or unauthenticated.
set_secret() {
  local name="$1" value="$2"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if printf '%s' "$value" | gh secret set "$name" >/dev/null 2>&1; then
      WRITTEN_SECRET+=("$name")
      printf '  %s✓ set%s GitHub secret %s\n' "$GREEN" "$RESET" "$name"
      return
    fi
  fi
  SKIPPED+=("GitHub secret $name (set it manually: gh secret set $name)")
  warn "skipped GitHub secret $name: gh not ready; set it later"
}

# set_var NAME VALUE sets a GitHub Actions repo variable (non-secret).
set_var() {
  local name="$1" value="$2"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if gh variable set "$name" --body "$value" >/dev/null 2>&1; then
      printf '  %s✓ set%s GitHub variable %s\n' "$GREEN" "$RESET" "$1"
      return
    fi
  fi
  SKIPPED+=("GitHub variable $name")
  warn "skipped GitHub variable $name, gh not ready; set it later"
}

# finish clears, then shows a closing summary of everything configured.
finish() {
  _clear
  printf '\n%s%s  ✓ Setup complete%s\n' "$BOLD" "$GREEN" "$RESET"
  (( ${#WRITTEN_ENV[@]} ))    && note "wrote ${#WRITTEN_ENV[@]} value(s) to $ENV_FILE: ${WRITTEN_ENV[*]}"
  (( ${#WRITTEN_SECRET[@]} )) && note "set ${#WRITTEN_SECRET[@]} GitHub secret(s): ${WRITTEN_SECRET[*]}"
  if (( ${#SKIPPED[@]} )); then
    printf '\n'; warn "still to do by hand:"
    for s in "${SKIPPED[@]}"; do note "  - $s"; done
  fi
  printf '\n'
}

# ──────────────────────────────────────────────────────────────────────────
# STAGES: author this section. One stage() per step the human takes.
# ──────────────────────────────────────────────────────────────────────────

TOTAL_STAGES=8

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# The catalog is deploy-vps.sh's AGENT_CATALOG verbatim — the two lists must
# never disagree (the ids are what agents.list records and check-herdr.sh
# reads). First-class agents are pre-checked per #138.
AGENT_CATALOG="opencode pi claude-code codex grok-build"
FIRST_CLASS="opencode pi"

# The wizard's answers. AGENTS_PICK is a space-separated id list, matched with
# the installers' own `case " $set " in *" $id "*)` membership — bash-3.2-clean.
SCOPE=""
AGENTS_PICK=""
BILLER_CLAUDE="vendor"   # vendor | zen — vendor displayed first, nothing defaults to Zen
BILLER_CODEX="vendor"
CONNECTORS=0
BRAIN_SSH=""
REPO_URL=""

# Hand-steps finish prints; things this wizard points at, never performs.
# The secret vars are pre-declared because ask_secret assigns through
# `printf -v "$key"`, which shellcheck cannot see; declaring them here is the
# honest way to satisfy SC2154, and ask_secret overwrites each one when its
# stage runs.
HAND_STEPS=()
OPENCODE_ZEN_API_KEY=""
TOGETHER_API_KEY=""
ANTHROPIC_API_KEY=""
OPENAI_API_KEY=""
GITHUB_CODE_AGENT_PAT=""

add_hand_step() { HAND_STEPS+=("$1"); }

# in_catalog WORD — membership in AGENT_CATALOG, no subprocess.
in_catalog() {
  case " $AGENT_CATALOG " in *" $1 "*) return 0 ;; esac
  return 1
}

is_first_class() {
  case " $FIRST_CLASS " in *" $1 "*) return 0 ;; esac
  return 1
}

# ask_agents — the one multi-pick screen. Empty answer takes the first-class
# defaults; every token is validated and de-duplicated, re-asking on junk.
ask_agents() {
  local raw="" out="" word
  while :; do
    ask AGENTS_PICK "Agents to install (space-separated; Enter = OpenCode + Pi):"
    raw="${AGENTS_PICK//,/ }"
    out=""
    if [[ -z "${raw// /}" ]]; then
      out="$FIRST_CLASS"
    else
      for word in $raw; do
        if ! in_catalog "$word"; then
          warn "unknown agent '$word' — the catalog is: $AGENT_CATALOG"
          out=""
          break
        fi
        case " $out " in *" $word "*) ;; *) out="$out $word" ;; esac
      done
      [ -n "$out" ] || continue
    fi
    AGENTS_PICK="${out# }"
    break
  done
}

# keychain_put KEY VALUE — store under the same service keychain-secrets.sh
# reads back, so its roster and the ~/.zshrc block stay the single source. The
# value passes through argv (briefly visible in `ps`) — the trade
# keychain-secrets.sh already accepts on a single-user Mac; it never touches
# disk or shell history.
keychain_put() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  command -v security >/dev/null 2>&1 || { warn "no 'security' binary; store $1 in the Keychain by hand (keychain-secrets.sh)"; return 0; }
  security add-generic-password -U -s personal-ai -a "$1" -w "$2" || warn "Keychain write for $1 failed — store it via scripts/mac/keychain-secrets.sh"
  return 0
}

banner "personal-ai setup — the front door"

# ── Stage 1 · scope: the one fork ──────────────────────────────────────────
stage "Scope — where are we starting from?"
say "Two answers only. Both run both installers (the Mac bootstrap and the"
say "brain deploy); the fork decides what happens AROUND them."
while :; do
  ask SCOPE "Type fresh or existing:"
  case "$SCOPE" in
    fresh|existing) break ;;
    *) warn "answer is fresh or existing — nothing else" ;;
  esac
done
if [ "$SCOPE" = "fresh" ]; then
  say "Fresh end-to-end: new Mac + new brain. The provisioning gauntlet"
  say "(terraform, LUKS, the secrets.env fill) prints behind confirms —"
  say "the wizard points at each step and waits; it never performs one."
else
  say "Configure the existing ai-brain: both installers, the upgrade path,"
  say "and the one-time teardown checklist printed as hand steps before the"
  say "deploy waits behind your confirmation that you ran it."
fi
pause "Press Enter to continue"

# ── Stage 2 · coding agents ────────────────────────────────────────────────
stage "Coding agents — which live in herdr panes on the brain?"
say "OpenCode ★ and Pi ★ are first-class and pre-checked: herdr owns their"
say "lifecycle (official integrations). The catalog adds Claude Code, Codex"
say "and Grok Build (session-identity integration, credential at pick time)."
note "Gemini CLI is cut: Google-only auth, no Zen/Together billing, no herdr integration."
ask_agents
# Per-pick biller questions, vendor displayed FIRST (#138) — nothing defaults
# to Zen, and a Zen choice is explicit.
if printf '%s' " $AGENTS_PICK " | grep -q " claude-code "; then
  say "Claude Code's credential — vendor key first, Zen only by explicit choice:"
  ask BILLER_CLAUDE "Claude Code bills through [Enter = Anthropic vendor key; type zen for OpenCode Zen]:"
  case "$BILLER_CLAUDE" in
    zen|z|Z) BILLER_CLAUDE="zen" ;;
    *) BILLER_CLAUDE="vendor" ;;
  esac
fi
if printf '%s' " $AGENTS_PICK " | grep -q " codex "; then
  say "Codex's credential — same rule (its Zen wire is the #146-verified Responses shape):"
  ask BILLER_CODEX "Codex bills through [Enter = OpenAI vendor key; type zen for OpenCode Zen]:"
  case "$BILLER_CODEX" in
    zen|z|Z) BILLER_CODEX="zen" ;;
    *) BILLER_CODEX="vendor" ;;
  esac
fi
note "Picked: $AGENTS_PICK"
for a in $AGENTS_PICK; do
  if is_first_class "$a"; then
    note "  $a — herdr owns its lifecycle (official integration, config dir pre-created)"
  else
    note "  $a — session-identity integration; login and model pick are pane hand-steps"
  fi
done
if printf '%s' " $AGENTS_PICK " | grep -q " grok-build "; then
  note "  Grok Build rides Together's model catalog (Kimi, GLM, DeepSeek, …) by default;"
  note "  Grok's own models need an XAI_API_KEY (new account, paid-only) — documented"
  note "  opt-in, never wired by the wizard."
fi
if [ -z "$AGENTS_PICK" ]; then
  note "  (none picked — herdr still installs, server-only: no CLIs, no credentials copied)"
fi
pause "Press Enter to continue"

# ── Stage 3 · Mac extras ───────────────────────────────────────────────────
stage "Mac extras"
say "The Mac base is not a question: toolchain, goose CLI + Desktop, and the"
say "coding pack (eleven ported skills, read by goose) install as the thin"
say "client. No coding agent installs on the Mac — they live in herdr panes."
if confirm "Print the connectors adoption path as a hand-step? (adoption stays the documented hand edit — a fragment flip, a config re-render, a credential in goose's own store)"; then
  CONNECTORS=1
fi
pause "Press Enter to continue"

# ── Stage 4 · provisioning / teardown confirm ───────────────────────────────
stage "Provisioning and teardown — the human-only gauntlet"
say "Values the wizard never touches, on any path:"
note "  • the Hetzner token and the Tailscale auth key — typed at terraform's"
note "    interactive prompts, stored nowhere"
note "  • the Tailscale admin toggles (MagicDNS + HTTPS Certificates) — two"
note "    switches in the web console"
note "  • the LUKS passphrase — typed during luks-setup.sh, asked again after"
note "    every reboot (crypttab is noauto on purpose)"
note "  • the coding-agent pane logins (subscription OAuth) — typed inside panes"
note "  • Goose Desktop connect + settings"
note "  • every /data/secrets.env row this wizard did not capture"
while :; do
  ask BRAIN_SSH "Brain SSH target (user@host — e.g. agent@your-brain.your-tailnet.ts.net):"
  case "$BRAIN_SSH" in *" "*) warn "no spaces in an ssh target" ;; "") warn "needed to drive the deploy over SSH" ;; *) break ;; esac
done
if [ "$SCOPE" = "fresh" ]; then
  while :; do
    ask REPO_URL "Repo clone URL for the brain's first-ever clone [Enter = upstream PhillipChaffee/personal-ai-setup]:"
    [ -n "$REPO_URL" ] || REPO_URL="https://github.com/PhillipChaffee/personal-ai-setup.git"
    case "$REPO_URL" in
      *"<"*|*" "*|*"~"*) warn "that URL is a placeholder — pass your real clone URL" ;;
      *) break ;;
    esac
  done
  say ""
  say "The gauntlet, in order — each behind a confirm; the wizard performs none of it:"
  pause "1/4 — Tailscale: account ready, Mac signed in, MagicDNS + HTTPS Certificates ON?"
  confirm "2/4 — terraform apply has run from infra/terraform (you typed the tagged auth key at the prompt)?" || {
    warn "The gauntlet runs before any deploy. Do the steps, then re-run this wizard."
    exit 1
  }
  confirm "3/4 — LUKS: luks-setup.sh --device <path> has run and /data is mounted (passphrase typed twice, FORMAT typed)?" || {
    warn "Run luks-setup.sh first (docs/setup/50-vps-brain.md §3), then re-run this wizard."
    exit 1
  }
  if confirm "4/4 — secrets.env: scaffold /data/secrets.env from the repo's example over SSH now? (names only — no value is sent)"; then
    say "scaffolding /data/secrets.env from config/env/secrets.env.example (names only)…"
    if ssh "$BRAIN_SSH" 'umask 077; if [ -f /data/secrets.env ]; then echo "kept existing /data/secrets.env"; else cat > /data/secrets.env && chmod 600 /data/secrets.env && echo "created /data/secrets.env (0600)"; fi' \
      < "$REPO_ROOT/config/env/secrets.env.example"; then
      say "The wizard writes ONLY the rows it captures (stage 5) — fill every other"
      say "row by hand now: OPENCODE_ZEN_API_KEY and TOGETHER_API_KEY when the wizard"
      say "is not capturing them, TAVILY_API_KEY only if you adopt tavily. Roster and"
      say "docs: docs/setup/50-vps-brain.md §4."
    else
      warn "scaffold failed — is the brain up, /data unlocked, and the SSH key authorized?"
      confirm "Continue anyway (you will fill /data/secrets.env entirely by hand)?" || {
        warn "Fix the SSH path or the LUKS mount (docs/setup/50-vps-brain.md §3-4),"
        warn "then re-run this wizard."
        exit 1
      }
    fi
  else
    warn "Skipping the scaffold: /data/secrets.env must exist before the deploy —"
    warn "create it by hand per docs/setup/50-vps-brain.md §4."
  fi
else
  cat <<'EOF'
  The one-time teardown, before the deploy (the deploy never deletes anything;
  check-brain.sh's legacy arm is this checklist's completion signal):

    goose schedules and recipes
    [ ] goose schedule remove <id> for every id still registered (ids live in git history)
    [ ] sudo systemctl disable --now 'goose-recipe@*.timer' 2>/dev/null
    [ ] sudo systemctl disable --now goose-recipe@.service 2>/dev/null
    [ ] sudo rm -f /etc/systemd/system/goose-recipe@.service /etc/systemd/system/goose-recipe@*.timer
    [ ] sudo rm -f /data/goose/data/schedule.json
    legacy services and listeners
    [ ] sudo systemctl disable --now code-agent-manager.service tls-cert-renew.service tls-cert-renew.timer goose-telegram-gateway.service 2>/dev/null
    [ ] sudo rm -f /etc/systemd/system/code-agent-manager.service \
          /etc/systemd/system/tls-cert-renew.service /etc/systemd/system/tls-cert-renew.timer \
          /etc/systemd/system/goose-telegram-gateway.service
    [ ] nothing listens on :4300 any more (the old container plane's port)
    dead secret rows in /data/secrets.env — delete these rows, keep the live ones
    [ ] USER_GOOGLE_EMAILS, USER_GOOGLE_EMAIL, GOOGLE_OAUTH_*, TELEGRAM_BOT_TOKEN,
        NTFY_TOPIC, NTFY_EMAIL, NTFY_AGENT_TOPIC, and the vault deploy key
    vault (the live /data/life-vault stays untouched — records, not code)
    [ ] GitHub: delete the vault deploy key by hand
    Mac
    [ ] rm -rf ~/.agents/skills/connect-service  (no-clobber-installed; no uninstall path)
EOF
  confirm "I ran the teardown checklist on the brain" || {
    warn "Run the teardown first (docs/setup/50-vps-brain.md §5), then re-run this"
    warn "wizard; the deploy does not, and must not, delete anything."
    exit 1
  }
fi
pause "Press Enter to continue"

# ── Stage 5 · capture ───────────────────────────────────────────────────────
stage "Capture — the flow's only secrets"
say "Everything under 'never touched' is typed by a human, forever. The wizard"
say "asks for exactly the keys the picks demand, generates the goose secret,"
say "and writes EXACTLY this set — nothing else — into /data/secrets.env over"
say "SSH in the deploy stage. Mac-scoped values also land in the Keychain."

if [ "$BILLER_CLAUDE" = "zen" ] || [ "$BILLER_CODEX" = "zen" ]; then
  say "OpenCode Zen key — a Zen-billed pick chose Zen (#138: explicit choice):"
  open_url "https://opencode.ai/docs/zen"
  step "Zen console → copy the API key (docs/setup/10-accounts.md §1)."
  ask_secret OPENCODE_ZEN_API_KEY "Paste the OpenCode Zen API key:"
  write_env OPENCODE_ZEN_API_KEY "$OPENCODE_ZEN_API_KEY"
  keychain_put OPENCODE_ZEN_API_KEY "$OPENCODE_ZEN_API_KEY"
fi
if [ -n "$AGENTS_PICK" ]; then
  say "Together AI key — the default biller, asked whenever >=1 agent is picked:"
  open_url "https://api.together.ai"
  step "Together AI console → copy the API key (docs/setup/10-accounts.md §2)."
  ask_secret TOGETHER_API_KEY "Paste the Together AI API key:"
  write_env TOGETHER_API_KEY "$TOGETHER_API_KEY"
  keychain_put TOGETHER_API_KEY "$TOGETHER_API_KEY"
  if [ "$BILLER_CLAUDE" = "vendor" ]; then
    say "Claude Code's vendor credential (the pick chose the displayed default):"
    open_url "https://console.anthropic.com/settings/keys"
    step "Anthropic console → copy the API key (docs/setup/10-accounts.md §4)."
    ask_secret ANTHROPIC_API_KEY "Paste the Anthropic API key:"
    write_env ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY"
  fi
  if [ "$BILLER_CODEX" = "vendor" ]; then
    say "Codex's vendor credential:"
    open_url "https://platform.openai.com/api-keys"
    step "OpenAI platform → copy the API key (docs/setup/10-accounts.md §4)."
    ask_secret OPENAI_API_KEY "Paste the OpenAI API key:"
    write_env OPENAI_API_KEY "$OPENAI_API_KEY"
  fi
  say "Fine-grained GitHub PAT — the scope IS the allowlist (no repos.json exists):"
  open_url "https://github.com/settings/personal-access-tokens/new"
  step "GitHub → Settings → Developer settings → Fine-grained tokens: scope it to"
  step "ONLY the repos the agents should reach, permissions Contents + Pull"
  step "requests (read/write). Copy the token (docs/setup/70-coding-agents.md §2)."
  ask_secret GITHUB_CODE_AGENT_PAT "Paste the fine-grained GitHub PAT:"
  write_env GITHUB_CODE_AGENT_PAT "$GITHUB_CODE_AGENT_PAT"
fi
if [ -n "$AGENTS_PICK" ] && [ "$BILLER_CODEX" = "zen" ]; then
  warn "Codex on Zen bills PAID ids only — Zen's free tier is OpenCode-client-gated"
  warn "upstream (403 FreeTierError from Codex). Pick a paid model in the pane:"
  note "  cheapest live gpt-6-luna, or the codex family gpt-5.3-codex / gpt-5.3-codex-spark."
fi
say "The goose serve secret — GENERATED here, never asked:"
GOOSE_SERVER__SECRET_KEY="$(openssl rand -hex 32)"
write_env GOOSE_SERVER__SECRET_KEY "$GOOSE_SERVER__SECRET_KEY"
keychain_put GOOSE_SERVER__SECRET_KEY "$GOOSE_SERVER__SECRET_KEY"
note "  ✓ minted once; the brain and the Mac Keychain carry the SAME value, so the"
note "    old human-copy step is dissolved and Desktop pairs with the brain."
pause "Press Enter to continue"

# ── Stage 6 · Mac installer ─────────────────────────────────────────────────
stage "Mac installer — bootstrap-mac.sh"
say "Three units, in dependency order: base-toolchain (uv, node, jq, the"
say "Tailscale cask), base-goose (goose CLI + Desktop, the pin, ~/.config/goose),"
say "coding-pack (the eleven ported skills — the OpenCode agents and AGENTS.md"
say "stay in the repo as paste-in material). No-clobber; re-running is safe."
bash "$REPO_ROOT/scripts/mac/bootstrap-mac.sh"
stage "Mac secrets — keychain-secrets.sh"
say "Hidden prompts for every Keychain row the wizard did not already store"
say "(the Zen and Together keys when they were not captured), then it"
say "regenerates the ~/.zshrc export block. Press Enter at a prompt to skip."
bash "$REPO_ROOT/scripts/mac/keychain-secrets.sh"

# ── Stage 7 · brain deploy over SSH ─────────────────────────────────────────
stage "Brain deploy — driven over SSH"
say "The wizard writes EXACTLY the keys it captured or generated into"
say "/data/secrets.env over SSH (values ride stdin, never argv), then runs"
say "the deploy. /data/secrets.env must already exist (stage 4)."
UPSERT_BLOCK="$(printf 'GOOSE_SERVER__SECRET_KEY\t%s\n' "$GOOSE_SERVER__SECRET_KEY")"
if [ -n "${OPENCODE_ZEN_API_KEY:-}" ] && { [ "$BILLER_CLAUDE" = "zen" ] || [ "$BILLER_CODEX" = "zen" ]; }; then
  UPSERT_BLOCK="$UPSERT_BLOCK$(printf 'OPENCODE_ZEN_API_KEY\t%s\n' "$OPENCODE_ZEN_API_KEY")"
fi
# Empty captures never ride up: an empty overwrite would wipe a hand-filled
# row, and the deploy's require_secret then fails loudly on the missing row —
# the honest failure, not a silent wipe.
if [ -n "$AGENTS_PICK" ]; then
  if [ -n "$TOGETHER_API_KEY" ]; then
    UPSERT_BLOCK="$UPSERT_BLOCK$(printf 'TOGETHER_API_KEY\t%s\n' "$TOGETHER_API_KEY")"
  fi
  if [ "$BILLER_CLAUDE" = "vendor" ] && [ -n "$ANTHROPIC_API_KEY" ]; then
    UPSERT_BLOCK="$UPSERT_BLOCK$(printf 'ANTHROPIC_API_KEY\t%s\n' "$ANTHROPIC_API_KEY")"
  fi
  if [ "$BILLER_CODEX" = "vendor" ] && [ -n "$OPENAI_API_KEY" ]; then
    UPSERT_BLOCK="$UPSERT_BLOCK$(printf 'OPENAI_API_KEY\t%s\n' "$OPENAI_API_KEY")"
  fi
  if [ -n "$GITHUB_CODE_AGENT_PAT" ]; then
    UPSERT_BLOCK="$UPSERT_BLOCK$(printf 'GITHUB_CODE_AGENT_PAT\t%s\n' "$GITHUB_CODE_AGENT_PAT")"
  fi
fi
if [ "$SCOPE" = "fresh" ]; then
  say "The brain will get exactly these rows: GOOSE_SERVER__SECRET_KEY${OPENCODE_ZEN_API_KEY:+, OPENCODE_ZEN_API_KEY}${AGENTS_PICK:+, TOGETHER_API_KEY${ANTHROPIC_API_KEY:+, ANTHROPIC_API_KEY}${OPENAI_API_KEY:+, OPENAI_API_KEY}, GITHUB_CODE_AGENT_PAT}."
  say "Every other row stays yours — fill the hand rows over SSH if you have"
  say "keys the wizard did not capture."
fi
say "Upserting the captured rows into /data/secrets.env…"
# SC2087 is the point, not a slip: the delimiter is deliberately UNQUOTED so
# $UPSERT_BLOCK expands on THIS side and the values ride the ssh stdin stream —
# they are never in an argv, where ps on either host would show them.
# shellcheck disable=SC2087
ssh "$BRAIN_SSH" 'bash -s' <<REMOTE
set -eu
f=/data/secrets.env
if [ ! -f "\$f" ]; then
  echo "ERROR: \$f does not exist — run the provisioning gauntlet first (docs/setup/50-vps-brain.md §4)" >&2
  exit 1
fi
chmod 600 "\$f"
tmp="\$f.wizard.\$\$"
trap 'rm -f "\$tmp"' EXIT
wrote=""
while IFS="$(printf '\t')" read -r key value <&3; do
  [ -n "\$key" ] || continue
  case "\$key" in
    GOOSE_SERVER__SECRET_KEY|OPENCODE_ZEN_API_KEY|TOGETHER_API_KEY|ANTHROPIC_API_KEY|OPENAI_API_KEY|GITHUB_CODE_AGENT_PAT) ;;
    *) echo "ERROR: refusing to write unexpected row '\$key'" >&2; exit 2 ;;
  esac
  grep -vE "^\${key}=" "\$f" > "\$tmp" || true
  printf '%s=%s\n' "\$key" "\$value" >> "\$tmp"
  chmod 600 "\$tmp"
  mv -f "\$tmp" "\$f"
  wrote="\$wrote \$key"
done 3<<'PAIRS'
$UPSERT_BLOCK
PAIRS
echo "    wrote:\$wrote"
REMOTE
unset UPSERT_BLOCK
warn "This deploy restarts herdr.service and goose-serve — pane processes die."
warn "herdr restores layout and resumes sessions, but a MID-TURN pane does not"
warn "come back mid-turn. Deploy when nothing is mid-turn."
agents_ids="${AGENTS_PICK// /,}"
agents_flag=""
if [ -n "$AGENTS_PICK" ]; then agents_flag=" --coding-agents '$agents_ids'"; fi
remote_cmd="if [ -d \"\$HOME/personal-ai-setup/.git\" ]; then echo '==> repo already at ~/personal-ai-setup'; else git clone '$REPO_URL' \"\$HOME/personal-ai-setup\"; fi && cd \"\$HOME/personal-ai-setup\" && scripts/vps/deploy-vps.sh --with herdr$agents_flag"
if confirm "Run the deploy over SSH now?"; then
  ssh -t "$BRAIN_SSH" "$remote_cmd"
else
  warn "Skipping the deploy — drive it by hand when ready:"
  note "    ssh -t $BRAIN_SSH \"$remote_cmd\""
fi

# ── Stage 8 · verify + finish ───────────────────────────────────────────────
stage "Verify + finish"
say "The wizard points; a human types. Run these (Mac first, then the brain):"
step "Mac, new terminal so the Keychain exports are live:"
note "    scripts/verify/check-providers.sh   # raw HTTPS per endpoint"
note "    scripts/verify/check-goose.sh       # goose through all providers"
step "Brain (over the tailnet):"
note "    ssh $BRAIN_SSH '~/personal-ai-setup/scripts/verify/check-brain.sh'"
note "    ssh $BRAIN_SSH '~/personal-ai-setup/scripts/verify/check-security.sh --local'"
if [ -n "$AGENTS_PICK" ]; then
  note "    ssh $BRAIN_SSH '~/personal-ai-setup/scripts/verify/check-herdr.sh'"
fi
if [ "$CONNECTORS" -eq 1 ]; then
  step "Connectors (opt-in, adoption stays a hand edit): flip enabled: true in the"
  note "    fragment, re-render config/goose/config.yaml (check-goose-template.sh"
  note "    --write), copy it to both hosts, and store the token in goose's own"
  note "    per-extension secret store. docs/connecting.md is the path."
fi
add_hand_step "Open a NEW terminal so the Keychain exports are live, then run the verify checks above"
add_hand_step "After any brain reboot: sudo scripts/vps/luks-unlock.sh — the passphrase is never stored"
add_hand_step "Goose Desktop: turn OFF auto-update; connect to https://<brain>.<tailnet>.ts.net:3284 with GOOSE_SERVER__SECRET_KEY and the pinned TLS fingerprint (sudo journalctl -u goose-serve | grep -iE 'listen|fingerprint')"
if printf '%s' " $AGENTS_PICK " | grep -qE " (claude-code|codex) "; then
  add_hand_step "Subscription logins (Claude / ChatGPT OAuth) happen inside their herdr panes, by hand"
fi
if [ -n "$AGENTS_PICK" ]; then
  add_hand_step "Authorize the Mac for herdr: add your Mac's public key to /data/herdr/.ssh/authorized_keys on the brain (docs/setup/70-coding-agents.md §4), then run: herdr machine add herdr@<your-brain>.<your-tailnet>.ts.net"
  if [ "$BILLER_CODEX" = "zen" ]; then
    add_hand_step "Codex on Zen bills PAID ids only (free ids are OpenCode-client-gated upstream) — pick a model in the pane"
  fi
  add_hand_step "Pick models inside each agent pane; opencode stats in a pane reports actual spend"
fi
printf '\n%s%sStill to do by hand:%s\n' "$BOLD" "$RED" "$RESET"
for h in "${HAND_STEPS[@]}"; do note "  - $h"; done
printf '\n'
note "Nothing schedules anything: no scheduler flag, no timers, no recipes. The"
note "stages wrote only the local .env and drove the two installers."
finish