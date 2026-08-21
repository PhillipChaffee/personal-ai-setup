#!/usr/bin/env bash
# sync-models.sh — refresh the Goose custom-provider model lists from the
# LIVE Zen and Together catalogs, so the pickers offer (almost) everything
# each provider serves instead of a hand-curated subset.
#
# Usage:
#   sync-models.sh            # dry run: fetch catalogs, show the diffs
#   sync-models.sh --write    # rewrite config/goose/custom_providers/*.json
#
# Requires: jq, curl, and whichever keys you want synced
# (OPENCODE_ZEN_API_KEY and/or TOGETHER_API_KEY — a missing key just skips
# that provider). After --write, re-copy the files into
# ~/.config/goose/custom_providers/ (bootstrap-mac.sh copies no-clobber, so
# merge by hand or copy the changed files yourself) and restart goose; on
# the brain: systemctl restart goose-serve.
#
# How models are bucketed (Zen serves each family in its native wire format,
# and goose custom providers only speak chat-completions and messages):
#   zen-anthropic  claude-*, qwen3.5+          (Anthropic /messages)
#   zen-free       $0/$0 or *-free/big-pickle  (TRAIN ON YOUR DATA — the
#                                              provider name keeps that
#                                              boundary visible in the picker)
#   excluded       gpt-*, grok*, gemini*, muse* (Responses/Google wire
#                                              formats goose cannot speak)
#   zen-openai     everything else             (OpenAI /chat/completions)
# Explicit format metadata in the catalog, when present, wins over these
# name-based rules. Together keeps only type=="chat" models.
#
# Env overrides (mainly for tests): PROVIDERS_DIR, ZEN_MODELS_URL,
# TOGETHER_MODELS_URL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIR="${PROVIDERS_DIR:-$REPO_ROOT/config/goose/custom_providers}"
ZEN_URL="${ZEN_MODELS_URL:-https://opencode.ai/zen/v1/models}"
TOGETHER_URL="${TOGETHER_MODELS_URL:-https://api.together.xyz/v1/models}"
DEFAULT_CTX=131072

WRITE=0
case "${1:-}" in
  --write) WRITE=1 ;;
  -h|--help) sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  '') ;;
  *) echo "sync-models.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
esac

for tool in jq curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "sync-models.sh: $tool is required" >&2; exit 1; }
done
[ -d "$DIR" ] || { echo "sync-models.sh: provider dir not found: $DIR" >&2; exit 1; }

CHANGED=0

# Normalize any of the catalog shapes we might get (top-level array, .data,
# .models) into a flat array of {id, ctx, fmt, free} objects.
normalize() {
  jq --argjson dctx "$DEFAULT_CTX" '
    ( if type == "array" then . else (.data // .models // []) end )
    | [ .[]
        | { id:  (.id // .name),
            ctx: ((.context_length // .context_limit // .limit.context // $dctx) | tonumber? // $dctx),
            fmt: ((.format // .api // .endpoint // "") | ascii_downcase),
            free: ((((.cost.input // .pricing.input // .pricing.prompt // 1)) | tonumber? // 1) == 0) }
        | select(.id != null and .id != "") ]'
}

# Turn a normalized bucket into goose's models[] shape.
to_models() {
  jq '[ .[] | { name: .id, context_limit: .ctx } ] | sort_by(.name)'
}

# update_file <file> <models-json>: show the diff; with --write, back up and
# apply. Refuses to write an empty list — an API-shape surprise must never
# nuke a working provider file.
update_file() {
  local file="$1" models="$2" path new count
  path="$DIR/$file"
  [ -f "$path" ] || { echo "  SKIP $file (not present in $DIR)"; return 0; }
  count="$(jq 'length' <<<"$models")"
  if [ "$count" -eq 0 ]; then
    echo "  SKIP $file — catalog produced 0 models for this bucket; keeping the current list" >&2
    return 0
  fi
  new="$(jq --argjson models "$models" '.models = $models' "$path")"
  if [ "$new" = "$(cat "$path")" ]; then
    echo "  OK   $file unchanged ($count models)"
    return 0
  fi
  CHANGED=1
  echo "  DIFF $file -> $count models:"
  diff -u "$path" <(printf '%s\n' "$new") | sed 's/^/    /' || true
  if [ "$WRITE" -eq 1 ]; then
    cp "$path" "$path.bak"
    printf '%s\n' "$new" > "$path"
    echo "  WROTE $file (backup: $file.bak)"
  fi
}

# ---------------------------------------------------------------- Together
if [ -n "${TOGETHER_API_KEY:-}" ]; then
  echo "== Together catalog ($TOGETHER_URL)"
  raw="$(curl -fsS --max-time 30 -H "Authorization: Bearer $TOGETHER_API_KEY" "$TOGETHER_URL")"
  norm="$(normalize <<<"$raw")"
  # Keep chat models only: Together's catalog also lists embedding/image/
  # audio/rerank models, which goose cannot chat with. Together publishes
  # the kind under .type (absent type = assume chat).
  typed="$(jq '( if type == "array" then . else (.data // .models // []) end )
               | [ .[] | select((.type // "chat") == "chat") | (.id // .name) ]' <<<"$raw")"
  chat="$(jq --argjson keep "$typed" '[ .[] | select(.id as $i | $keep | index($i)) ]' <<<"$norm")"
  update_file together.json "$(to_models <<<"$chat")"
else
  echo "== Together: TOGETHER_API_KEY not set — skipping"
fi

# --------------------------------------------------------------------- Zen
if [ -n "${OPENCODE_ZEN_API_KEY:-}" ]; then
  echo "== Zen catalog ($ZEN_URL)"
  raw="$(curl -fsS --max-time 30 -H "Authorization: Bearer $OPENCODE_ZEN_API_KEY" "$ZEN_URL")"
  norm="$(normalize <<<"$raw")"

  free="$(jq '[ .[] | select(.free or (.id | test("(^|-)free$|-free-|^big-pickle$"))) ]' <<<"$norm")"
  rest="$(jq --argjson free "$free" '[ .[] | select(.id as $i | ($free | map(.id) | index($i)) | not) ]' <<<"$norm")"

  msgs="$(jq '[ .[] | select(
      (.fmt | test("anthropic|messages")) or
      (.fmt == "" and (.id | test("^claude-|^qwen3\\.[5-9]"))) ) ]' <<<"$rest")"
  excluded="$(jq '[ .[] | select(
      (.fmt | test("responses|google|gemini")) or
      (.fmt == "" and (.id | test("^gpt-|^grok|^gemini|^muse"))) ) ]' <<<"$rest")"
  chat="$(jq --argjson m "$msgs" --argjson x "$excluded" \
      '[ .[] | select(.id as $i | (($m + $x) | map(.id) | index($i)) | not) ]' <<<"$rest")"

  update_file zen-anthropic.json "$(to_models <<<"$msgs")"
  update_file zen-free.json      "$(to_models <<<"$free")"
  update_file zen-openai.json    "$(to_models <<<"$chat")"

  xcount="$(jq 'length' <<<"$excluded")"
  if [ "$xcount" -gt 0 ]; then
    echo "  NOTE: $xcount Zen models excluded (Responses/Google wire formats goose cannot speak):"
    jq -r '.[].id' <<<"$excluded" | sed 's/^/    - /'
  fi
else
  echo "== Zen: OPENCODE_ZEN_API_KEY not set — skipping"
fi

echo
if [ "$CHANGED" -eq 0 ]; then
  echo "sync-models: everything already up to date."
elif [ "$WRITE" -eq 1 ]; then
  echo "sync-models: files updated. Now re-copy the changed files into"
  # shellcheck disable=SC2088  # tilde is human-facing text here, not a path
  echo "~/.config/goose/custom_providers/ and restart goose"
  echo "(brain: systemctl restart goose-serve). Then update any model IDs"
  echo "pinned in recipes/ or docs/model-routing.md that the diff renamed."
else
  echo "sync-models: dry run — re-run with --write to apply the diffs above."
fi
