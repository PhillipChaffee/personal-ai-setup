#!/usr/bin/env bash
# keychain-secrets.sh — put the setup's secrets in the macOS Keychain and wire
# your shell to export them from there. Nothing is ever written to disk in
# plaintext, and values are never echoed.
#
# Storage: security add-generic-password -s personal-ai -a <VARNAME>
# Readback: security find-generic-password -w -s personal-ai -a <VARNAME>
#
# THE ROSTER IS NOT IN THIS FILE. It comes from `pai secrets --host mac`, which
# projects it out of config/units/*.yaml -- one row per key, carrying that
# manifest's own `prompt`. Before #39 it was a nine-name string here plus a
# `case` of hints whose default arm was `echo ""`, so TELEGRAM_BOT_TOKEN and
# NTFY_EMAIL prompted with an empty parenthetical, on every run, for features
# the reader had not been told about yet. A base install now asks for
# TOGETHER_API_KEY and OPENCODE_ZEN_API_KEY and stops; `--units <id>` adds one
# add-on's names when you install that add-on.
#
# TWO ROSTERS, ON PURPOSE:
#   the SELECTION (--units, or the base + default_on default) is what is
#     prompted for;
#   the WHOLE CATALOG (--all) is what the ~/.zshrc block exports.
# An export of a key that is not in the Keychain yields an empty string by
# design, so the block is harmless where it is unused -- and building it from
# the selection instead would silently delete the exports of an add-on that was
# set up on an earlier run.
#
# THE ~/.zshrc BLOCK IS REGENERATED, NOT REFUSED. That file belongs to you, so
# there are exactly three states and no fourth: no markers (append), one
# well-formed marked region (replace between them), anything else (refuse, exit
# 2, name the malformation, touch nothing). Everything outside the markers is
# copied through unchanged and the file's mode is preserved.
set -euo pipefail

SERVICE="personal-ai"
ZSHRC="$HOME/.zshrc"
MARKER_BEGIN="# >>> personal-ai keychain exports (keychain-secrets.sh) >>>"
MARKER_END="# <<< personal-ai keychain exports <<<"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# The literal typed at a hidden prompt to mint a value instead of pasting one.
# Only offered for keys whose manifest row carries a `generate` command --
# NTFY_TOPIC and NTFY_AGENT_TOPIC today, both minted on the Mac in Phase 1
# (docs/setup/10-accounts.md §6). Keys that are generated on the BRAIN and
# transcribed here (GOOSE_SERVER__SECRET_KEY) must never offer it: a fresh value
# on this side unpairs the client from the server.
GENERATE_WORD="generate"

UNITS=""
REWRITE_ONLY=0

usage() {
  cat <<EOF
Usage: keychain-secrets.sh [--units a,b,c] [--rewrite-only] [--help]

Prompts (silently) for each secret the selected units keep in the macOS
Keychain, under service "$SERVICE", then rewrites the export block in
~/.zshrc so every new shell reads them back from the Keychain.

  --units a,b,c   the unit ids to prompt for. Default: every base and
                  default_on unit, which is what a bootstrap install leaves
                  behind. Add an opt-in unit's id when you install it --
                  \`--units google-workspace\` asks for that unit's names only.
  --rewrite-only  skip every prompt and only regenerate the ~/.zshrc block.
                  This is the one mode that needs no terminal.

Press Enter at any prompt to skip it (an already-stored value is kept). At a
prompt whose key can be minted, type "$GENERATE_WORD" to have openssl mint one;
the value is stored and never printed.

Roster (names and prompts only, no values):
    pai secrets --host mac [--units a,b,c]
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --units)
      shift
      [ $# -gt 0 ] || { echo "keychain-secrets.sh: --units needs a list" >&2; exit 2; }
      UNITS="$1"
      ;;
    --rewrite-only) REWRITE_ONLY=1 ;;
    *) echo "keychain-secrets.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "keychain-secrets.sh: macOS-only (uses the Keychain via 'security')." >&2
  echo "On the brain, secrets live in /data/secrets.env instead — see" >&2
  echo "config/env/secrets.env.example, or run:" >&2
  echo "    pai secrets --host vps" >&2
  exit 1
fi

# ------------------------------------------------------------------ rosters --
# Both files hold NAMES AND PROMPTS ONLY -- there is no path in this script by
# which a value reaches a file. mktemp's 0600 is belt and braces.
SELECTED_ROSTER="$(mktemp "${TMPDIR:-/tmp}/pai-roster.XXXXXX")"
FULL_ROSTER="$(mktemp "${TMPDIR:-/tmp}/pai-roster.XXXXXX")"
BLOCK_FILE="$(mktemp "${TMPDIR:-/tmp}/pai-block.XXXXXX")"
# Beside ~/.zshrc rather than in $TMPDIR, so the `mv` below is a rename on one
# filesystem: an interrupted cross-device mv would leave the user's shell init
# half-written, and this script's whole promise is that it does not damage that
# file.
NEW_ZSHRC="$(mktemp "$HOME/.pai-zshrc.XXXXXX")"
trap 'rm -f "$SELECTED_ROSTER" "$FULL_ROSTER" "$BLOCK_FILE" "$NEW_ZSHRC"' EXIT

roster_or_die() { # roster_or_die <outfile> <pai-secrets-args...>
  local out="$1"; shift
  if ! "$REPO_ROOT/bin/pai" secrets --host mac "$@" >"$out"; then
    echo "keychain-secrets.sh: could not read the roster from 'pai secrets --host mac $*'" >&2
    exit 2
  fi
  return 0
}

if [ -n "$UNITS" ]; then
  roster_or_die "$SELECTED_ROSTER" --units "$UNITS"
else
  roster_or_die "$SELECTED_ROSTER"
fi
roster_or_die "$FULL_ROSTER" --all

# ------------------------------------------------------------------ prompts --
store_secret() { # store_secret <var> <value>
  # -U updates in place if the item already exists. The value passes through
  # this process's argv (briefly visible in `ps`) — accepted on a single-user
  # Mac; it never touches disk or shell history.
  security add-generic-password -U -s "$SERVICE" -a "$1" -w "$2"
  return 0
}

prompt_all() {
  local var need gen prompt state hint secret bytes stored=0
  echo "==> Storing secrets in the macOS Keychain (service: $SERVICE)"
  echo "    Input is hidden. Press Enter to skip a variable."
  echo
  # Read the roster on fd 3: fd 0 is where the human types, and a `read` loop
  # over stdin would eat the first answer as the second roster line.
  while IFS="$(printf '\t')" read -r var need gen prompt <&3; do
    [ -n "$var" ] || continue
    state="not stored yet — Enter skips"
    if security find-generic-password -s "$SERVICE" -a "$var" >/dev/null 2>&1; then
      state="already stored — Enter keeps it"
    fi
    hint=""
    if [ "$gen" != "-" ]; then
      hint="; \"$GENERATE_WORD\" mints one"
    fi
    if [ "$need" = "optional" ]; then
      echo "  $var  [optional]  ($prompt)"
    else
      echo "  $var  ($prompt)"
    fi
    # -s: silent read — the value never appears on screen or in history.
    # `|| true` is for Ctrl-D: EOF leaves `secret` empty, which reads as "skip",
    # and the remaining keys skip the same way. Without it, `set -e` would abort
    # the run mid-roster with a bare exit 1 and no explanation.
    read -r -s -p "    value [$state$hint]: " secret || true
    echo
    if [ -z "$secret" ]; then
      echo "    skipped"
      continue
    fi
    if [ "$secret" = "$GENERATE_WORD" ] && [ "$gen" = "-" ]; then
      # The word was typed at a key that is transcribed rather than minted --
      # GOOSE_SERVER__SECRET_KEY is the case that matters. Storing the literal
      # string "generate" as the shared secret would be a silent, very confusing
      # outage, so this refuses instead.
      secret=""
      echo "    refused: $var is transcribed, not minted here — nothing stored"
      continue
    fi
    if [ "$secret" = "$GENERATE_WORD" ]; then
      # The manifest's `generate` is NEVER evaluated as a command. check-units.sh
      # constrains it to `openssl rand -hex N`; this reads N back out and calls
      # openssl itself, so a manifest cannot become a shell.
      bytes="${gen##* }"
      case "$bytes" in
        ''|*[!0-9]*) echo "    refused: '$gen' is not an openssl byte count" >&2; continue ;;
      esac
      secret="$(openssl rand -hex "$bytes")"
      store_secret "$var" "$secret"
      secret=""
      # A LENGTH, never a prefix: the count is public (it is in the prompt) and
      # says the mint worked, which "stored" alone does not.
      echo "    minted and stored ($((bytes * 2)) hex chars)"
      stored=$((stored + 1))
      continue
    fi
    store_secret "$var" "$secret"
    secret=""
    echo "    stored"
    stored=$((stored + 1))
  done 3<"$SELECTED_ROSTER"
  echo
  echo "==> Done: $stored value(s) written."
  return 0
}

# ------------------------------------------------------- shell export block --
# Build the block that reads each secret back from the Keychain at shell init.
# Missing/skipped items export as empty strings (stderr silenced) so a partial
# roster never breaks shell startup.
build_block() {
  local var rest
  {
    printf '%s\n' "$MARKER_BEGIN"
    while IFS="$(printf '\t')" read -r var rest <&3; do
      [ -n "$var" ] || continue
      # shellcheck disable=SC2016  # the $( ) must land in ~/.zshrc literally, to
      # be evaluated at shell startup -- expanding it here would bake the SECRET
      # into the file, which is the whole thing this script exists to avoid.
      printf 'export %s="$(security find-generic-password -w -s %s -a %s 2>/dev/null || true)"\n' \
        "$var" "$SERVICE" "$var"
    done 3<"$FULL_ROSTER"
    printf '%s\n' "$MARKER_END"
  } >"$BLOCK_FILE"
  return 0
}

# file_mode <path> — the two-arm portable stat. GNU first, BSD second; nothing
# in this repo may assume either, because the same scripts run on a Mac and on
# ubuntu-latest.
file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %A "$1" 2>/dev/null || echo ""
  return 0
}

marker_count() { # marker_count <marker>
  grep -cF -- "$1" "$ZSHRC" 2>/dev/null || true
  return 0
}

marker_line() { # marker_line <marker>
  grep -nF -- "$1" "$ZSHRC" 2>/dev/null | head -1 | cut -d: -f1 || true
  return 0
}

refuse() { # refuse <what-is-wrong>
  echo "keychain-secrets.sh: $ZSHRC is not in a shape this script may rewrite:" >&2
  echo "    $1" >&2
  echo "  Nothing was written. Leave ONE '$MARKER_BEGIN'" >&2
  echo "  line above ONE '$MARKER_END' line, or delete both" >&2
  echo "  regions entirely, then re-run." >&2
  exit 2
}

# install_block — the whole file-writing surface of this script.
#
# Three states, checked in this order, and the third one writes nothing:
#   0 markers          append the block (after a blank line)
#   1 BEGIN + 1 END,   replace everything between them
#     BEGIN first
#   anything else      refuse
install_block() {
  local begins ends begin_at end_at mode
  if [ ! -f "$ZSHRC" ]; then
    cat "$BLOCK_FILE" >"$NEW_ZSHRC"
    # A file we create is ours to set the mode of, and 600 is the right one for
    # a file naming every credential this machine holds.
    chmod 600 "$NEW_ZSHRC"
    mv "$NEW_ZSHRC" "$ZSHRC"
    echo "==> Wrote $ZSHRC with the export block (mode 600)."
    return 0
  fi
  begins="$(marker_count "$MARKER_BEGIN")"
  ends="$(marker_count "$MARKER_END")"
  mode="$(file_mode "$ZSHRC")"
  if [ "$begins" = "0" ] && [ "$ends" = "0" ]; then
    cp "$ZSHRC" "$NEW_ZSHRC"
    # Only when one is missing: appending to a file that does not end in a
    # newline would otherwise splice the marker onto the user's last line.
    if [ -s "$NEW_ZSHRC" ] && [ "$(tail -c 1 "$NEW_ZSHRC" | wc -l | tr -d ' ')" = "0" ]; then
      printf '\n' >>"$NEW_ZSHRC"
    fi
    printf '\n' >>"$NEW_ZSHRC"
    cat "$BLOCK_FILE" >>"$NEW_ZSHRC"
    echo "==> Appended the export block to $ZSHRC."
  else
    [ "$begins" = "1" ] || refuse "$begins begin markers (want exactly 1)"
    [ "$ends" = "1" ] || refuse "$ends end markers (want exactly 1)"
    begin_at="$(marker_line "$MARKER_BEGIN")"
    end_at="$(marker_line "$MARKER_END")"
    [ "$begin_at" -lt "$end_at" ] || \
      refuse "the end marker (line $end_at) comes before the begin marker (line $begin_at)"
    # Everything outside the two marker lines is copied through byte for byte;
    # everything between them is replaced, whatever a hand-edit left there. The
    # one normalisation, stated because it is a real difference: awk is
    # line-oriented, so a file whose last line had no newline gets one.
    awk -v begin_at="$begin_at" -v end_at="$end_at" -v blk="$BLOCK_FILE" '
      NR == begin_at { while ((getline line < blk) > 0) print line; close(blk); next }
      NR > begin_at && NR <= end_at { next }
      { print }
    ' "$ZSHRC" >"$NEW_ZSHRC"
    echo "==> Rewrote the export block in $ZSHRC (lines $begin_at-$end_at)."
  fi
  [ -z "$mode" ] || chmod "$mode" "$NEW_ZSHRC"
  mv "$NEW_ZSHRC" "$ZSHRC"
  return 0
}

if [ "$REWRITE_ONLY" -eq 0 ]; then
  if [ ! -t 0 ]; then
    echo "keychain-secrets.sh: needs an interactive terminal (secrets are typed" >&2
    echo "at hidden prompts, never passed as arguments or piped). To regenerate" >&2
    echo "the ~/.zshrc block without prompting, use --rewrite-only." >&2
    exit 2
  fi
  prompt_all
fi

build_block
install_block

cat <<'EOF'

Next:
  * Open a NEW terminal so the exports are live, then sanity-check by LENGTH,
    never by printing a key:
        echo "${#OPENCODE_ZEN_API_KEY} chars"
  * GUI apps launched from Finder (Goose Desktop) do NOT read ~/.zshrc. If
    Desktop reports a missing API key while the CLI works, either launch it
    from a terminal once (open -a Goose) or load a key into the GUI session:
        launchctl setenv OPENCODE_ZEN_API_KEY \
          "$(security find-generic-password -w -s personal-ai -a OPENCODE_ZEN_API_KEY)"
    (repeat per variable; launchctl setenv does not survive a reboot).
  * Adding an add-on later? Re-run with --units <id> — it prompts for that
    unit's names only and rewrites the block in place.
  * Never set GOOSE_DISABLE_KEYRING on this Mac — it downgrades goose's own
    secret storage to a plaintext file (docs/security.md).
EOF
