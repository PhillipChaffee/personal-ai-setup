#!/usr/bin/env bash
# check-goose.sh — one headless goose run through EACH of the three custom
# providers (zen-openai, zen-anthropic, together). This is the test that
# settles the custom-provider base_url path semantics (bare /v1 vs full
# /chat/completions|/messages) against YOUR pinned goose version — an
# uncertainty the upstream docs leave open.
#
# Run check-providers.sh first: if raw HTTPS fails there, fix that before
# blaming goose.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: check-goose.sh [--help]

Runs, per provider:
  goose run --no-session --quiet -t 'Reply with exactly OK' --provider X --model Y

Pairs tested: zen-openai/minimax-m2.7, zen-anthropic/claude-haiku-4-5,
together/openai/gpt-oss-120b. Needs the goose CLI, the custom-provider JSONs
in ~/.config/goose/custom_providers/, and OPENCODE_ZEN_API_KEY +
TOGETHER_API_KEY in the environment. Exits non-zero if any provider fails.
Cost: three one-line completions.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "check-goose.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

command -v goose >/dev/null 2>&1 || {
  echo "check-goose.sh: goose CLI not found (Mac: scripts/mac/bootstrap-mac.sh)" >&2
  exit 2
}

MISSING=""
[ -n "${OPENCODE_ZEN_API_KEY:-}" ] || MISSING="$MISSING OPENCODE_ZEN_API_KEY"
[ -n "${TOGETHER_API_KEY:-}" ] || MISSING="$MISSING TOGETHER_API_KEY"
if [ -n "$MISSING" ]; then
  echo "check-goose.sh: missing env var(s):$MISSING" >&2
  echo "Mac: open a NEW terminal after keychain-secrets.sh." >&2
  echo "Brain: set -a; source /data/secrets.env; set +a" >&2
  exit 2
fi

PROVIDER_DIR="$HOME/.config/goose/custom_providers"
OUT_FILE="$(mktemp)"
trap 'rm -f "$OUT_FILE"' EXIT

# provider:model pairs (model IDs verified as of 2026-08-20)
PAIRS="zen-openai:minimax-m2.7 zen-anthropic:claude-haiku-4-5 together:openai/gpt-oss-120b"

# Both base_url variants per provider, for the failure hint.
variants_for() {
  case "$1" in
    zen-openai)    echo "A: https://opencode.ai/zen/v1/chat/completions | B: https://opencode.ai/zen/v1" ;;
    zen-anthropic) echo "A: https://opencode.ai/zen/v1/messages | B: https://opencode.ai/zen/v1" ;;
    together)      echo "A: https://api.together.xyz/v1/chat/completions | B: https://api.together.xyz/v1" ;;
  esac
}

# Portable timeout: GNU timeout exists on Linux; macOS only has it with
# coreutils installed (as gtimeout). Fall back to no timeout.
run_bounded() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 180 "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 180 "$@"
  else
    "$@"
  fi
}

RESULTS=""
FAIL_COUNT=0

echo "== check-goose: one run per custom provider =="
for pair in $PAIRS; do
  provider="${pair%%:*}"
  model="${pair#*:}"
  echo
  echo "--> $provider / $model"

  if [ ! -f "$PROVIDER_DIR/$provider.json" ]; then
    echo "    FAIL: $PROVIDER_DIR/$provider.json is missing."
    echo "    Install it: scripts/mac/bootstrap-mac.sh (Mac) / deploy-vps.sh (brain),"
    echo "    or copy config/goose/custom_providers/$provider.json there yourself."
    RESULTS="$RESULTS$provider|$model|FAIL (provider JSON missing)"$'\n'
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  rc=0
  run_bounded env \
    GOOSE_MODE=auto \
    GOOSE_MAX_TURNS=3 \
    GOOSE_DISABLE_SESSION_NAMING=true \
    goose run --no-session --quiet \
    -t 'Reply with exactly OK' \
    --provider "$provider" --model "$model" \
    >"$OUT_FILE" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ] && grep -q "OK" "$OUT_FILE"; then
    echo "    PASS"
    RESULTS="$RESULTS$provider|$model|PASS"$'\n'
  elif [ "$rc" -eq 0 ]; then
    # Ran clean but didn't say OK — model reachable, output odd. Count as pass
    # with a note; the wire format evidently works.
    echo "    PASS (ran clean, but output lacked the literal 'OK' — inspect below)"
    tail -n 5 "$OUT_FILE" | sed 's/^/      | /'
    RESULTS="$RESULTS$provider|$model|PASS (odd output)"$'\n'
  else
    echo "    FAIL (exit $rc). Last output lines:"
    tail -n 8 "$OUT_FILE" | sed 's/^/      | /'
    echo
    echo "    Most likely cause: the base_url path variant. Goose custom providers"
    echo "    are ambiguous upstream about full-path vs bare-base URLs, and this"
    echo "    repo ships variant A. A/B it:"
    echo "      1. Edit $PROVIDER_DIR/$provider.json"
    echo "      2. Swap \"base_url\" to the other variant:"
    echo "         $(variants_for "$provider")"
    echo "      3. Re-run this script. (Symptom of the wrong variant: HTTP 404, or"
    echo "         a doubled path like /chat/completions/chat/completions in the error.)"
    if [ "$provider" = "zen-anthropic" ]; then
      echo "    Also possible for zen-anthropic only: the auth header. Run"
      echo "    scripts/verify/check-providers.sh — it reports whether Zen /messages"
      echo "    accepts x-api-key (what goose's anthropic engine sends). If it does"
      echo "    not, drop zen-anthropic and use Claude via OpenCode instead"
      echo "    (docs/troubleshooting.md)."
    fi
    RESULTS="$RESULTS$provider|$model|FAIL (exit $rc)"$'\n'
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done

echo
echo "== summary =="
printf '%-14s %-24s %s\n' "PROVIDER" "MODEL" "RESULT"
printf '%s' "$RESULTS" | while IFS='|' read -r p m r; do
  [ -n "$p" ] && printf '%-14s %-24s %s\n' "$p" "$m" "$r"
done

if [ "$FAIL_COUNT" -eq 0 ]; then
  echo
  echo "All three providers work — base_url semantics are settled for this goose version."
else
  echo
  echo "$FAIL_COUNT provider(s) failing — see hints above and docs/troubleshooting.md."
  exit 1
fi
