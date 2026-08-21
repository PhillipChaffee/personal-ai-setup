#!/usr/bin/env bash
# pin-models.sh — model-drift detector. Every model ID pinned in this repo
# (config/goose/custom_providers/*.json, config/goose/config.yaml,
# config/opencode/opencode.json, recipes/*.yaml) is checked against the live
# catalogs:
#   Zen      GET https://opencode.ai/zen/v1/models
#   Together GET https://api.together.xyz/v1/models
#
# Zen deprecates models aggressively (18 in the 7 months before 2026-08-20)
# and Together renames with dated variants — run this MONTHLY and after any
# provider-side surprise. A pinned ID missing upstream = drift; the script
# reports it, suggests close matches, and exits non-zero.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: pin-models.sh [--help]

Requires OPENCODE_ZEN_API_KEY and TOGETHER_API_KEY in the environment, plus
curl and jq. Exit codes: 0 = all pinned IDs live; 1 = drift detected;
2 = could not fetch/parse a catalog (inconclusive — fix that first).
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "pin-models.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

for dep in curl jq; do
  command -v "$dep" >/dev/null 2>&1 || { echo "pin-models.sh: $dep not found" >&2; exit 2; }
done

MISSING_ENV=""
[ -n "${OPENCODE_ZEN_API_KEY:-}" ] || MISSING_ENV="$MISSING_ENV OPENCODE_ZEN_API_KEY"
[ -n "${TOGETHER_API_KEY:-}" ] || MISSING_ENV="$MISSING_ENV TOGETHER_API_KEY"
if [ -n "$MISSING_ENV" ]; then
  echo "pin-models.sh: missing env var(s):$MISSING_ENV" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
ZEN_IDS="$WORK_DIR/zen-ids"
TOGETHER_IDS="$WORK_DIR/together-ids"
PINNED="$WORK_DIR/pinned"

# Extract model IDs from whatever JSON shape a /models endpoint returns:
# {"data":[...]}, {"models":[...]}, a bare array of objects or strings, or an
# object keyed by model ID.
JQ_IDS='
  ( if type == "object" and has("data") then .data
    elif type == "object" and has("models") then .models
    else . end ) as $m
  | if ($m | type) == "array" then
      $m[] | if type == "string" then . else (.id // .name // empty) end
    elif ($m | type) == "object" then $m | keys[]
    else empty end'

fetch_catalog() {
  # $1 = label, $2 = url, $3 = api key, $4 = output file
  local body="$WORK_DIR/$1.json" status
  status="$(curl -sS --max-time 60 -o "$body" -w '%{http_code}' \
    -H "Authorization: Bearer $3" "$2" 2>/dev/null)" || status="000"
  if [ "$status" != "200" ]; then
    echo "pin-models.sh: $1 catalog fetch failed (HTTP $status at $2)" >&2
    return 1
  fi
  jq -r "$JQ_IDS" "$body" 2>/dev/null | grep -v '^$' | sort -u >"$4" || true
  if [ ! -s "$4" ]; then
    echo "pin-models.sh: $1 catalog parsed to zero IDs — response shape changed?" >&2
    echo "Inspect it yourself: curl -H 'Authorization: Bearer <key>' $2 | jq ." >&2
    return 1
  fi
}

echo "== pin-models: fetching live catalogs =="
fetch_catalog "zen" "https://opencode.ai/zen/v1/models" "$OPENCODE_ZEN_API_KEY" "$ZEN_IDS" || exit 2
fetch_catalog "together" "https://api.together.xyz/v1/models" "$TOGETHER_API_KEY" "$TOGETHER_IDS" || exit 2
echo "Zen: $(wc -l <"$ZEN_IDS" | tr -d ' ') models; Together: $(wc -l <"$TOGETHER_IDS" | tr -d ' ') models"
echo

# ---- collect every pinned ID in the repo ------------------------------------
{
  # goose custom providers: the models[] lists
  jq -r '.models[].name' "$REPO_ROOT"/config/goose/custom_providers/*.json 2>/dev/null

  # goose config.yaml: per-provider default models ("    model: X" lines)
  grep -hE '^[[:space:]]+model:' "$REPO_ROOT/config/goose/config.yaml" 2>/dev/null | awk '{print $2}'

  # recipes: per-recipe pinned models
  grep -hE '^[[:space:]]*goose_model:' "$REPO_ROOT"/recipes/*.yaml 2>/dev/null | awk '{print $2}'

  # opencode.json: default/small models (opencode/<id> = a Zen model) and any
  # models declared under custom providers
  jq -r '[.model, .small_model] | .[] | select(. != null)' \
    "$REPO_ROOT/config/opencode/opencode.json" 2>/dev/null | sed 's|^opencode/||'
  jq -r '(.provider // {}) | to_entries[] | (.value.models // {}) | keys[]' \
    "$REPO_ROOT/config/opencode/opencode.json" 2>/dev/null
} | grep -v '^$' | sort -u >"$PINNED"

if [ ! -s "$PINNED" ]; then
  echo "pin-models.sh: found no pinned model IDs in config/ or recipes/ — wrong checkout?" >&2
  exit 2
fi

echo "== checking $(wc -l <"$PINNED" | tr -d ' ') pinned IDs =="
DRIFT_COUNT=0
while IFS= read -r id; do
  # Which catalog should hold it? Together IDs are namespaced (org/model);
  # Zen IDs are bare. Every ID pinned in this repo follows that split.
  case "$id" in
    */*) catalog_file="$TOGETHER_IDS"; catalog_name="Together" ;;
    *)   catalog_file="$ZEN_IDS";      catalog_name="Zen" ;;
  esac
  if grep -Fxq "$id" "$catalog_file"; then
    echo "OK     $id  ($catalog_name)"
  else
    DRIFT_COUNT=$((DRIFT_COUNT + 1))
    echo "DRIFT  $id  — not in the live $catalog_name catalog"
    # Suggest near-matches: same leading letters, case-insensitive.
    stem="$(printf '%s' "${id##*/}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z].*$//')"
    if [ -n "$stem" ]; then
      MATCHES="$(grep -i -- "$stem" "$catalog_file" | head -n 5 || true)"
      if [ -n "$MATCHES" ]; then
        echo "       candidates upstream:"
        printf '%s\n' "$MATCHES" | sed 's/^/         /'
      fi
    fi
    if [ "$id" = "deepseek-ai/DeepSeek-V4-Flash" ]; then
      echo "       NOTE: this ID was flagged unconfirmed at pin time — Together"
      echo "       publishes dated variants (e.g. ...-0731). Pick the exact live ID"
      echo "       from the candidates above."
    fi
  fi
done <"$PINNED"

echo
if [ "$DRIFT_COUNT" -eq 0 ]; then
  echo "== summary: every pinned model ID is live upstream =="
else
  cat <<EOF
== summary: $DRIFT_COUNT pinned ID(s) drifted (deprecated/renamed upstream) ==
Update each occurrence in the SAME commit, then re-run until clean:
  - config/goose/custom_providers/*.json  (models[] lists)
  - config/goose/config.yaml              (per-provider default models)
  - config/opencode/opencode.json
  - recipes/*.yaml                        (goose_model pins)
  - docs/model-routing.md                 (the routing table)
Mind the routing rules when substituting: a sensitive-tier model must stay
ZDR/no-training (docs/privacy.md). Then propagate: re-copy on the Mac
(bootstrap-mac.sh); on the brain, deploy-vps.sh copies no-clobber, so merge
the changed files into ~/.config/goose by hand (it prints a diff hint).
EOF
  exit 1
fi
