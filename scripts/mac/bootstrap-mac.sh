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
# that went stale.
#
# WHICH of the five run is chosen by --with/--without/--only, resolved ONCE in
# the prelude into $SELECTED; --dry-run prints that resolution and exits without
# touching anything. The unit table those flags are resolved against (UNIT_IDS,
# REQUIRES_*, OWNS_*) is checked against the manifests by units_lint.py's P8, so
# it is a copy of config/units/ that cannot silently diverge from it -- see the
# comment above the table for why it is a copy at all.
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

# The unit ids in this heredoc are KEBAB-CASE (base-goose), never the function
# name (unit_base_goose). units_lint.py's P3 counts a unit's call sites with a
# lexical `^unit_base_goose$` over the whole file, heredocs included, so a
# column-0 function name in here would read as a second call and fail the gate
# that checks the manifests against this script.
usage() {
  cat <<'EOF'
Usage: bootstrap-mac.sh [--with ID] [--without ID] [--only ID] [--dry-run] [--help]

Installs the Mac toolchain for the personal-ai setup and copies the repo's
config templates (no-clobber) into place. Run it from your clone of the repo;
re-running is safe. Follow-ups it will point you at: keychain-secrets.sh and
the scripts/verify/ checks. OpenCode's Zen credential is written for you
(scripts/mac/opencode-auth.sh) when $OPENCODE_ZEN_API_KEY is already set --
there is no /connect step any more.

With no flags it installs all five units, which is what it has always done.

  --with ID[,ID]     add ID (and whatever it requires) to the default set
  --without ID[,ID]  drop ID, and anything left needing it, from the set
  --only ID[,ID]     install exactly ID plus what ID requires, nothing else
  --dry-run          print the resolved plan and exit; touches nothing at all,
                     needs no Homebrew, and does not even ask what OS this is
  -h, --help         this text

The five units, in dependency order:

  base-toolchain   uv, node, jq, the Tailscale cask
  base-goose       the goose CLI + Desktop cask, the pin, ~/.config/goose
  opencode         the OpenCode CLI, ~/.config/opencode/opencode.json, and the
                   Zen credential in ~/.local/share/opencode/auth.json
  base-skills      the connect-service skill in ~/.agents/skills
  coding-pack      the eleven ported skills, the OpenCode agents, AGENTS.md

`--only coding-pack` therefore installs four units, because coding-pack needs
opencode, which needs base-goose, which needs base-toolchain. Excluding a unit
something else still needs is refused with exit 2 rather than half-installed.
EOF
}

# --with/--without/--only accumulate raw, comma-or-repeat separated ids here and
# are validated after the containment gate, next to the table they are checked
# against. `${2//,/ }` is a bash 3.2 pattern substitution -- macOS ships bash
# 3.2.57 and nothing newer is guaranteed, so no ${x^^}, no mapfile, no
# `declare -A` anywhere in this file.
DRY_RUN=0
WITH_IDS=""
WITHOUT_IDS=""
ONLY_IDS=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --with)
      [ "$#" -ge 2 ] || { echo "bootstrap-mac.sh: --with needs a unit id" >&2; usage >&2; exit 2; }
      WITH_IDS="$WITH_IDS ${2//,/ }"; shift 2 ;;
    --without)
      [ "$#" -ge 2 ] || { echo "bootstrap-mac.sh: --without needs a unit id" >&2; usage >&2; exit 2; }
      WITHOUT_IDS="$WITHOUT_IDS ${2//,/ }"; shift 2 ;;
    --only)
      [ "$#" -ge 2 ] || { echo "bootstrap-mac.sh: --only needs a unit id" >&2; usage >&2; exit 2; }
      ONLY_IDS="$ONLY_IDS ${2//,/ }"; shift 2 ;;
    *) echo "bootstrap-mac.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

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

# ------------------------------------------------------------- The unit table --
# The five units, what each requires, and what each puts on the machine. This is
# a COPY of config/units/*.yaml and it is a copy ON PURPOSE.
#
# The selection has to be resolved BEFORE anything is installed, and a YAML read
# in the install path would be fail-CLOSED where the rest of this script is
# fail-tolerant. unit_base_goose()'s pins ladder is the evidence sitting in this
# same file: PyYAML is not guaranteed on a fresh Mac, and its fallback is `uv`
# -- which THIS SCRIPT installs, in the first unit. `--only coding-pack` could
# therefore need a parser that does not exist yet, and a PyYAML-less Mac would
# go from "installs everything" to "installs nothing" with no test able to see
# it: the harness dies without PyYAML long before it reaches that path.
#
# The copy is kept honest from the other side instead. units_lint.py's P8 fails
# when UNIT_IDS, any REQUIRES_*, or any OWNS_* stops matching config/units/, and
# it runs in scripts/verify/ where the manifests ARE the source of truth. That
# is also what makes the --dry-run plan below a claim about the catalog rather
# than a restatement of this script.
#
# DIRECTLY NAMED GLOBALS READ THROUGH A `case`, never `${!ref}` indirection:
# an indirectly-read global is SC2034 (unused) to ShellCheck 0.11.0, and a
# warning is a red gate here. (This paragraph deliberately does not start a line
# with the linter's own name -- that spelling parses as a directive.)
UNIT_IDS="base-toolchain base-goose opencode base-skills coding-pack"

# `requires`, restricted to the five units this script installs. base-goose and
# opencode also require base-secrets in the manifests; base-secrets has
# `installer: null` (the Keychain is a human's job), so it is elided rather than
# ordered, and P8(c) asserts exactly that elision instead of assuming it.
REQUIRES_BASE_TOOLCHAIN=""
REQUIRES_BASE_GOOSE="base-toolchain"
REQUIRES_OPENCODE="base-goose"
REQUIRES_BASE_SKILLS="base-goose"
REQUIRES_CODING_PACK="opencode"

# `owns`, at the manifests' granularity: brew: / cask: / home: prefixes over the
# manifest's brew_formula, brew_cask and home_path targets, in manifest order.
# The `~` is LITERAL -- these strings are printed and compared, never used as a
# path, so nothing here is ever tilde-expanded or globbed.
#
# ~/.local/share/opencode/auth.json IS LISTED even though opencode-auth.sh
# writes it only when $OPENCODE_ZEN_API_KEY is in the environment. `owns` is the
# unit's FOOTPRINT -- what this unit, and no other, is allowed to put on the
# machine -- and the manifest claims it for exactly that reason. A --dry-run
# plan that hid it because of a runtime condition would be a plan whose contents
# depended on the caller's shell, and P8(d)/P8(f) compare this list against the
# manifest, not against what a particular run happened to do.
OWNS_BASE_TOOLCHAIN="brew:uv brew:node brew:jq cask:tailscale"
OWNS_BASE_GOOSE="brew:block-goose-cli cask:block-goose
home:~/.config/goose/config.yaml home:~/.config/goose/custom_providers
home:~/.config/goose/.goosehints"
OWNS_OPENCODE="brew:anomalyco/tap/opencode home:~/.config/opencode/opencode.json
home:~/.local/share/opencode/auth.json"
OWNS_BASE_SKILLS="home:~/.agents/skills/connect-service"
OWNS_CODING_PACK="home:~/.agents/skills/ci-lint-test home:~/.agents/skills/clean-plan
home:~/.agents/skills/code-review home:~/.agents/skills/deep-research
home:~/.agents/skills/looping-code-review home:~/.agents/skills/looping-plan-review
home:~/.agents/skills/mr-review home:~/.agents/skills/plan-review
home:~/.agents/skills/pre-mr-checklist home:~/.agents/skills/refactor-planner
home:~/.agents/skills/ship home:~/.config/opencode/agents
home:~/.config/opencode/AGENTS.md"

requires_of() {
  # requires_of <id> -- the ids this unit needs, restricted to UNIT_IDS.
  case "$1" in
    base-toolchain) printf '%s' "$REQUIRES_BASE_TOOLCHAIN" ;;
    base-goose)     printf '%s' "$REQUIRES_BASE_GOOSE" ;;
    opencode)       printf '%s' "$REQUIRES_OPENCODE" ;;
    base-skills)    printf '%s' "$REQUIRES_BASE_SKILLS" ;;
    coding-pack)    printf '%s' "$REQUIRES_CODING_PACK" ;;
  esac
}

owns_of() {
  # owns_of <id> -- the brew:/cask:/home: items this unit puts on the machine.
  case "$1" in
    base-toolchain) printf '%s' "$OWNS_BASE_TOOLCHAIN" ;;
    base-goose)     printf '%s' "$OWNS_BASE_GOOSE" ;;
    opencode)       printf '%s' "$OWNS_OPENCODE" ;;
    base-skills)    printf '%s' "$OWNS_BASE_SKILLS" ;;
    coding-pack)    printf '%s' "$OWNS_CODING_PACK" ;;
  esac
}

in_set() {
  # in_set <id> <space-separated set> -- membership, with no subprocess.
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}

set_minus() {
  # set_minus <id> <set> -- <set> with every occurrence of <id> removed.
  local out word
  out=""
  for word in $2; do
    [ "$word" != "$1" ] || continue
    out="$out $word"
  done
  printf '%s' "${out# }"
}

want() {
  # want <id> -- the gate every unit body opens with, as `want <id> || return 0`.
  # It ANNOUNCES the skip: a selective run has to say what it did not do, or the
  # next person debugging a missing skill has no thread to pull. On a no-flag run
  # everything is selected, so this never prints and stdout is what it was.
  case " $SELECTED " in *" $1 "*) return 0 ;; esac
  echo "==> skipping $1"
  return 1
}

# ------------------------------------------------------- Resolve the selection --
# Everything below is pure computation over the table: no seam call, no brew, no
# uname, no write. That is what lets --dry-run answer before the platform guard
# and before the Homebrew guard, and it is the single decision that keeps every
# mutating helper in this file free of a DRY_RUN branch. `brew`, `mkdir`, `cp`,
# `mv` and the `rm -rf` sweep are never reached under --dry-run because the
# script has already exited; there is no second seam to keep honest.
for want_id in $ONLY_IDS $WITH_IDS $WITHOUT_IDS; do
  in_set "$want_id" "$UNIT_IDS" || {
    echo "bootstrap-mac.sh: unknown unit id: $want_id" >&2
    echo "known units: $UNIT_IDS" >&2
    exit 2
  }
done

# Named and refused in the same command line is a contradiction, not a
# precedence puzzle. Refuse it rather than picking a winner.
for want_id in $ONLY_IDS $WITH_IDS; do
  if in_set "$want_id" "$WITHOUT_IDS"; then
    echo "bootstrap-mac.sh: $want_id is both requested and excluded — pick one" >&2
    exit 2
  fi
done

# REQUESTED is what a human named. It is what makes the cascade below safe: a
# unit asked for by name is never dropped quietly to satisfy an exclusion.
REQUESTED="$ONLY_IDS $WITH_IDS"
ONLY_COUNT=0
for want_id in $ONLY_IDS; do
  ONLY_COUNT=$((ONLY_COUNT + 1))
done

# --only replaces the default set; --with adds to it. That is the whole
# difference, and it is why `--only coding-pack` leaves base-skills out while
# `--with coding-pack` does not.
if [ "$ONLY_COUNT" -gt 0 ]; then
  SELECTED="$ONLY_IDS $WITH_IDS"
else
  SELECTED="$UNIT_IDS $WITH_IDS"
fi

# Transitive requires. The passes are BOUNDED by more than the table's depth:
# P8(b) asserts UNIT_IDS is a topological order of an acyclic manifest graph, so
# this reaches its fixed point in at most four passes -- and if a future edit
# ever introduces a cycle, a bounded loop degrades to a wrong answer that the
# closure check below refuses, rather than to a hang.
CLOSURE_PASS=0
while [ "$CLOSURE_PASS" -lt 8 ]; do
  CLOSURE_ADDED=0
  for want_id in $SELECTED; do
    for dep_id in $(requires_of "$want_id"); do
      if ! in_set "$dep_id" "$SELECTED"; then
        SELECTED="$SELECTED $dep_id"
        CLOSURE_ADDED=1
      fi
    done
  done
  if [ "$CLOSURE_ADDED" -eq 0 ]; then
    break
  fi
  CLOSURE_PASS=$((CLOSURE_PASS + 1))
done

# THE CASCADE. Dropping a unit drops whatever is left needing it -- but only if
# nobody named that dependent. `--without opencode` loses coding-pack and says
# so; `--only coding-pack --without opencode` names coding-pack, so it survives
# here and the closure check below refuses the whole command line instead.
DROPPED=""
CASCADE_PASS=0
while [ "$CASCADE_PASS" -lt 8 ]; do
  CASCADE_DROPPED=0
  for want_id in $WITHOUT_IDS; do
    SELECTED="$(set_minus "$want_id" "$SELECTED")"
  done
  for want_id in $SELECTED; do
    if in_set "$want_id" "$REQUESTED"; then
      continue
    fi
    for dep_id in $(requires_of "$want_id"); do
      if in_set "$dep_id" "$SELECTED"; then
        continue
      fi
      if in_set "$want_id" "$SELECTED"; then
        SELECTED="$(set_minus "$want_id" "$SELECTED")"
        DROPPED="$DROPPED $want_id"
        CASCADE_DROPPED=1
      fi
    done
  done
  if [ "$CASCADE_DROPPED" -eq 0 ]; then
    break
  fi
  CASCADE_PASS=$((CASCADE_PASS + 1))
done

if [ -n "$DROPPED" ]; then
  echo "==> --without$WITHOUT_IDS also drops:$DROPPED"
fi

# THE CLOSURE CHECK, and it is reachable rather than defensive: it is where
# `--only coding-pack --without opencode` lands. A unit whose requirement the
# flags removed is refused with exit 2 naming both, because the alternative is
# unit_coding_pack() installing OpenCode agents onto a machine with no OpenCode
# -- a broken install that exits 0.
for want_id in $SELECTED; do
  for dep_id in $(requires_of "$want_id"); do
    if ! in_set "$dep_id" "$SELECTED"; then
      echo "bootstrap-mac.sh: $want_id requires $dep_id, and the flags excluded $dep_id." >&2
      echo "Either stop excluding $dep_id, or exclude $want_id as well." >&2
      exit 2
    fi
  done
done

# Order is the static UNIT_IDS order filtered, NEVER the order the flags arrived
# in: UNIT_IDS is a topological order of the manifest graph, so a unit can never
# run before something it requires. This also dedupes `--with base-goose` when
# base-goose was already in.
PLAN=""
for want_id in $UNIT_IDS; do
  if in_set "$want_id" "$SELECTED"; then
    PLAN="$PLAN $want_id"
  fi
done
SELECTED="${PLAN# }"

if [ "$DRY_RUN" -eq 1 ]; then
  PLAN_COUNT=0
  for want_id in $SELECTED; do
    PLAN_COUNT=$((PLAN_COUNT + 1))
  done
  echo "==> plan ($PLAN_COUNT units, in dependency order):"
  # INDENTED, and kebab-cased, both deliberately: units_lint.py's P3 counts call
  # sites with a lexical `^unit_base_goose$` over this whole file, heredocs and
  # format strings included, so a column-0 function name printed here would
  # register as a second call and fail the manifest gate.
  for want_id in $SELECTED; do
    printf '  %s\n' "$want_id"
  done
  echo "==> would install:"
  # At the manifests' granularity, which is why ~/.config/goose/custom_providers
  # and ~/.config/opencode/agents appear as directories rather than as the files
  # inside them: it makes the plan mechanically checkable against the catalog
  # instead of against this script's cp loops. P8(d) checks the OWNS_* strings;
  # P8(f) RUNS this loop -- `--dry-run --only <id>` for every id -- and compares
  # what it prints to config/units/. The second one is not redundant: owns_of()'s
  # `case` sits between the strings and this printf, and one word changed inside
  # it prints another unit's list with every OWNS_* still correct.
  for want_id in $SELECTED; do
    for own_item in $(owns_of "$want_id"); do
      case "$own_item" in
        brew:*) printf '  brew formula  %s\n' "${own_item#brew:}" ;;
        cask:*) printf '  brew cask     %s\n' "${own_item#cask:}" ;;
        home:*) printf '  file          %s\n' "${own_item#home:}" ;;
      esac
    done
  done
  exit 0
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
# functions below because install-test.yml's negative test mutates
# `^FORMULAE_BASE_TOOLCHAIN=` to prove the brew golden can fail. A list that
# moved inside a function would still be sed-able and the negative test would
# report the golden as inert when the only inert thing is the sed.
#
# The --dry-run planner does NOT read these: it prints OWNS_* from the unit
# table, which units_lint.py's P8(d) checks against the manifests. These lists
# are the argument vectors brew is actually handed, and the two agreeing is
# assertion A1's job, not a variable's.
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
# same eleven names as repo_file entries, and units_lint.py's P8(e) is the
# totality check that FAILS a twelfth directory neither unit claims -- the price
# of enumerating instead of globbing, paid where the manifests can see it.
SKILLS_CODING_PACK="ci-lint-test clean-plan code-review deep-research
looping-code-review looping-plan-review mr-review plan-review
pre-mr-checklist refactor-planner ship"

# ------------------------------------------------------------- The units ----
# Below this line the install is five functions, one per config/units/*.yaml
# manifest that names this script. All five are still CALLED unconditionally;
# what changed with the flag surface is that each one opens with `want <id> ||
# return 0`, so the selection decides inside the body and never at the call
# site. With no flags every unit is selected, want() never prints, and the
# installed $HOME is byte-for-byte the pre-carve one -- which is not an argument
# here, it is test-base-install.sh's A14b.
#
# FIVE RULES FOR THESE BODIES. Every one of them is a measured failure mode of
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
#   3. THE GATE IS THE FIRST EXECUTABLE LINE OF THE BODY, spelled
#      `want <kebab-id> || return 0`. This is rule 2's other half: gating at the
#      call site is the ONE place a reviewer would naturally reach for `if`, and
#      that is precisely the shape that silently disables errexit. A unit skipped
#      this way returns 0, so the bare call after it is still safe.
#   4. NO `local X="$(cmd)"` (SC2155): `local` succeeds whatever the command
#      substitution did, so the failure is swallowed. Declare, then assign.
#   5. THE SKILLS FILTER IS `|| continue`, never `[ ... ] && install_skill ...`
#      -- that is rule 1 again. `ship` sorts last, so on the final iteration the
#      `&&` list is false, the `for` inherits that status, and the unit returns
#      false after having done all of its work.

unit_base_toolchain() {
  want base-toolchain || return 0
  brew_formula "$FORMULAE_BASE_TOOLCHAIN"
  brew_cask "tailscale"

  echo "NOTE: Tailscale was installed as the standalone app. Launch it once and"
  echo "      sign in to your tailnet (docs/setup/10-accounts.md). If you already"
  echo "      use the App Store version, keep that one and 'brew uninstall --cask"
  echo "      tailscale' — the two variants conflict."
  return 0
}

unit_base_goose() {
  want base-goose || return 0
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
  want opencode || return 0
  brew_formula "$FORMULAE_OPENCODE"

  # ~/.config/opencode is created HERE and nowhere else, which is what makes a
  # future `--without opencode` assertable as an ABSENCE rather than as an
  # empty directory. coding-pack creates its own agents/ subdirectory.
  echo "==> Installing the OpenCode config template (no-clobber)"
  mkdir -p "$HOME/.config/opencode"
  copy_no_clobber "$REPO_ROOT/config/opencode/opencode.json" "$HOME/.config/opencode/opencode.json"

  # THE CREDENTIAL, UNATTENDED (#38). This used to be a line in the epilogue
  # telling you to run `opencode`, type /connect and paste the key, while
  # scripts/vps/code-agent-manager.py's seed_auth() had been writing exactly
  # that file on the brain all along.
  #
  # A BARE CALL, deliberately: rule 2 above. It is safe as the second-to-last
  # command of this unit because opencode-auth.sh exits 0 when there is no key
  # in the environment -- a fresh Mac has not run keychain-secrets.sh yet, and
  # aborting the whole bootstrap there would be the worst possible time.
  #
  # NOT through pai_exec, and that is the same call this file already makes for
  # python3 and uv (see the PAI_EXEC paragraph in the header): this is a script
  # in THIS repo doing local compute over a file in $HOME, not an external
  # binary. Routing it would fake away the write that test-base-install.sh's
  # phase I then reads back out of the fake $HOME.
  "$SCRIPT_DIR/opencode-auth.sh"
  return 0
}

unit_base_skills() {
  want base-skills || return 0
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
  want coding-pack || return 0
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
# Split into three heredocs so the OpenCode step can be omitted when opencode
# was not installed -- telling someone how the credential for a CLI this very
# run deliberately did not install got written is how a selective install
# teaches people to distrust the output. The step NUMBER follows, which is why
# the tail is a separate heredoc rather than a conditional line inside one. With
# opencode selected (every no-flag run) the three concatenate to exactly the
# text a no-flag run has always printed.
cat <<EOF

==> Bootstrap done. Next steps (docs/setup/20-mac-setup.md):

  1. Store your API keys in the macOS Keychain:
         $SCRIPT_DIR/keychain-secrets.sh
     then open a NEW terminal so the exported vars are live.
EOF

NEXT_STEP=2
if in_set opencode "$SELECTED"; then
  cat <<EOF

  2. OpenCode's Zen credential is written by the bootstrap itself, from
     \$OPENCODE_ZEN_API_KEY. If step 1 was the first time you set that key,
     re-run this script (or just $SCRIPT_DIR/opencode-auth.sh) in the new
     terminal. There is no /connect step and no /models step: the models are
     pinned in config/opencode/opencode.json.
EOF
  NEXT_STEP=3
fi

cat <<EOF

  $NEXT_STEP. Verify before going further:
         $REPO_ROOT/scripts/verify/check-providers.sh   # raw HTTPS per endpoint
         $REPO_ROOT/scripts/verify/check-goose.sh       # goose through all 3 providers
         $REPO_ROOT/scripts/verify/check-opencode.sh    # opencode, credential and PATH
EOF
