#!/usr/bin/env bash
# check-providers.sh — raw HTTPS smoke tests against every inference endpoint,
# with your real keys, no goose involved. Run this FIRST when anything is off:
# it separates "the provider/key is broken" from "goose is misconfigured".
#
# It also settles a documented uncertainty: the auth header for Zen's
# /messages (Anthropic-format) endpoint is not documented upstream, so the
# script tries Authorization: Bearer AND x-api-key and reports which worked.
#
# Endpoints (verified as of 2026-08-20, https://opencode.ai/docs/zen):
#   Zen      GET  https://opencode.ai/zen/v1/models
#   Zen      POST https://opencode.ai/zen/v1/chat/completions   (openai engine)
#   Zen      POST https://opencode.ai/zen/v1/messages           (anthropic engine)
#   Together GET  https://api.together.xyz/v1/models
#   Together POST https://api.together.xyz/v1/chat/completions
set -euo pipefail

# shellcheck source=scripts/verify/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: check-providers.sh [--help]

Requires OPENCODE_ZEN_API_KEY and TOGETHER_API_KEY in the environment
(Mac: open a new terminal after keychain-secrets.sh; brain: source
/data/secrets.env). Each test prints PASS/FAIL; exits non-zero if any fail.
Cost: a handful of 1-token completions — fractions of a cent.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) die_usage "unknown argument: $1" ;;
esac

ZEN_BASE="https://opencode.ai/zen/v1"
TOGETHER_BASE="https://api.together.xyz/v1"

mask() { printf '%s' "${1:0:4}...(masked)"; }

MISSING=""
[ -n "${OPENCODE_ZEN_API_KEY:-}" ] || MISSING="$MISSING OPENCODE_ZEN_API_KEY"
[ -n "${TOGETHER_API_KEY:-}" ] || MISSING="$MISSING TOGETHER_API_KEY"
if [ -n "$MISSING" ]; then
  die 2 "missing env var(s):$MISSING" \
    "Mac: run scripts/mac/keychain-secrets.sh, then open a NEW terminal." \
    "Brain: set -a; source /data/secrets.env; set +a"
fi

command -v curl >/dev/null 2>&1 || die 2 "curl not found"

BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

# request <curl args...> -> sets HTTP_STATUS, body in $BODY_FILE
request() {
  : >"$BODY_FILE"
  HTTP_STATUS="$(curl -sS --max-time 60 -o "$BODY_FILE" -w '%{http_code}' "$@" 2>>"$BODY_FILE")" || HTTP_STATUS="000"
  [ -n "$HTTP_STATUS" ] || HTTP_STATUS="000"
}

body_snippet() { head -c 300 "$BODY_FILE" | tr '\n' ' '; echo; }

echo "== check-providers =="
echo "Zen key:      $(mask "$OPENCODE_ZEN_API_KEY")"
echo "Together key: $(mask "$TOGETHER_API_KEY")"
echo

# ---- 1. Zen: GET /models ---------------------------------------------------
request -H "Authorization: Bearer $OPENCODE_ZEN_API_KEY" "$ZEN_BASE/models"
if [ "$HTTP_STATUS" = "200" ]; then
  pass "Zen GET /models (HTTP 200)"
else
  fail "Zen GET /models (HTTP $HTTP_STATUS)"
  echo "      body: $(body_snippet)"
fi

# ---- 2. Zen: POST /chat/completions (openai wire format) -------------------
request -H "Authorization: Bearer $OPENCODE_ZEN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"minimax-m2.7","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' \
  "$ZEN_BASE/chat/completions"
if [ "$HTTP_STATUS" = "200" ]; then
  pass "Zen POST /chat/completions with minimax-m2.7 (HTTP 200)"
else
  fail "Zen POST /chat/completions with minimax-m2.7 (HTTP $HTTP_STATUS)"
  echo "      body: $(body_snippet)"
  echo "      (404 on the model? run scripts/verify/pin-models.sh — Zen deprecates aggressively)"
fi

# ---- 3. Zen: POST /messages (anthropic wire format) — settle the header ----
# Both headers are tried regardless, so the report fully documents what Zen
# accepts today. Requests are 1 output token each.
MSG_PAYLOAD='{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}'
BEARER_STATUS=""
XAPI_STATUS=""

request -H "Authorization: Bearer $OPENCODE_ZEN_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  -d "$MSG_PAYLOAD" "$ZEN_BASE/messages"
BEARER_STATUS="$HTTP_STATUS"

request -H "x-api-key: $OPENCODE_ZEN_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  -d "$MSG_PAYLOAD" "$ZEN_BASE/messages"
XAPI_STATUS="$HTTP_STATUS"

if [ "$BEARER_STATUS" = "200" ] || [ "$XAPI_STATUS" = "200" ]; then
  pass "Zen POST /messages with claude-haiku-4-5 (Bearer: HTTP $BEARER_STATUS, x-api-key: HTTP $XAPI_STATUS)"
  WORKED=""
  [ "$BEARER_STATUS" = "200" ] && WORKED="Authorization: Bearer"
  if [ "$XAPI_STATUS" = "200" ]; then
    [ -n "$WORKED" ] && WORKED="$WORKED AND x-api-key" || WORKED="x-api-key"
  fi
  echo "      RESULT: Zen /messages accepts -> $WORKED"
  if [ "$XAPI_STATUS" != "200" ]; then
    echo "      NOTE: goose's anthropic engine sends x-api-key (the Anthropic"
    echo "      convention). If only Bearer works, the zen-anthropic provider"
    echo "      may still fail inside goose — see docs/troubleshooting.md for"
    echo "      the fallback (drop zen-anthropic; reach Claude via OpenCode)."
  fi
else
  fail "Zen POST /messages with claude-haiku-4-5 (Bearer: HTTP $BEARER_STATUS, x-api-key: HTTP $XAPI_STATUS)"
  echo "      body (last attempt): $(body_snippet)"
  echo "      Neither auth header worked. Fallback per docs/troubleshooting.md:"
  echo "      drop the zen-anthropic provider and use Claude via OpenCode only."
fi

# ---- 4. Together: GET /models ----------------------------------------------
request -H "Authorization: Bearer $TOGETHER_API_KEY" "$TOGETHER_BASE/models"
if [ "$HTTP_STATUS" = "200" ]; then
  pass "Together GET /models (HTTP 200)"
else
  fail "Together GET /models (HTTP $HTTP_STATUS)"
  echo "      body: $(body_snippet)"
fi

# ---- 5. Together: POST /chat/completions -----------------------------------
request -H "Authorization: Bearer $TOGETHER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"openai/gpt-oss-120b","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' \
  "$TOGETHER_BASE/chat/completions"
if [ "$HTTP_STATUS" = "200" ]; then
  pass "Together POST /chat/completions with openai/gpt-oss-120b (HTTP 200)"
else
  fail "Together POST /chat/completions with openai/gpt-oss-120b (HTTP $HTTP_STATUS)"
  echo "      body: $(body_snippet)"
  echo "      (429? Together rate limits are dynamic — wait per x-ratelimit-reset and retry)"
fi

finish
