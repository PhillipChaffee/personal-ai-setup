#!/usr/bin/env bash
# fake-goose.sh — the goose CLI stand-in. fake-brew.sh materialises a one-line
# /bin/sh shim at $FAKE_BREW_PREFIX/bin/goose that execs this file, so both
# callers reach it the way a real install would: bootstrap-mac.sh asks
# `goose --version` through fake-exec.sh, and check-goose.sh finds it via
# resolve_goose_bin walking PATH (the harness unsets GOOSE_BIN so that walk is
# forced to be the assertion rather than a shortcut).
#
# WHY THIS FILE EXISTS. check-goose.sh:124-129 scores a clean exit with no
# output as "PASS (odd output)" and lib.sh:87-89 counts that as green, so
# `#!/bin/sh` + `exit 0` would satisfy "check-goose passes" without ever opening
# a socket. This is the floor under that: every step below is an assertion the
# real installer had to have satisfied, and the run prints OK only after a
# provider answered 200 to a request built from the INSTALLED config.
#
# WRITTEN AGAINST THE CALLER, NOT AGAINST GOOSE. The argv matcher encodes what
# check-goose.sh:99-106 emits — the house standard (stub-engine.sh:6-7) — which
# means a change to goose's own CLI is invisible to this harness. What is tested
# here is the repo's scripts and config, not goose's acceptance of them.
#
# OUTPUT RULE, LOAD BEARING. check-goose.sh:112 greps the captured stdout+stderr
# case-insensitively and unanchored for
# `Network error:|Please resend your message|invalid api key|unauthorized|rate ?limit`,
# so one of those words in a happy-path message would turn a working run red.
# The happy path therefore prints exactly `OK` and nothing else, and no path
# ever prints a response body (`curl -o /dev/null`) — a relayed `x-ratelimit-*`
# header or a provider error string is not this file's to repeat.
#
# SECRETS. This is the only fake here that handles a live credential: it reads
# whichever of $OPENCODE_ZEN_API_KEY / $TOGETHER_API_KEY the provider JSON's
# api_key_env names, and hands it to curl as a header. Nothing records it —
# there is no log file, the key is never echoed and never interpolated into a
# message (errors carry a status code and a URL only), and the response body is
# discarded rather than reprinted the way check-providers.sh:74 would.
#
# zen-free.json is a fourth provider this repo ships; check-goose.sh:52 does not
# test it, so nothing here exercises it. Not an oversight.
set -euo pipefail

die() { echo "fake-goose: $*" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

# python3 + json, the way the rest of the verify scripts read structured files
# (stub-engine.sh:23): a missing key raises and the command substitution dies,
# where grep would hand back an empty string and let the assertion pass.
json_field() {
  # $1 = JSON file, $2 = top-level key
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"
}

json_has_model() {
  # $1 = JSON file, $2 = model name. Exit status only; prints nothing.
  python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if any(m.get("name") == sys.argv[2] for m in d["models"]) else 1)' "$1" "$2"
}

[ "$#" -gt 0 ] || die "no argv"

if [ "$1" = "--version" ]; then
  # A bare version and nothing else: bootstrap-mac.sh:118 pipes this through
  # `grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1`, and the pins comparison it
  # feeds is the one thing routing `goose --version` through the seam buys.
  [ "$#" -eq 1 ] || die "unhandled argv: $*"
  printf '%s\n' "${FAKE_GOOSE_VERSION:?fake-goose: FAKE_GOOSE_VERSION is required}"
  exit 0
fi

# The one run shape check-goose.sh:99-106 emits, matched by position and in
# order. A flag walk would be the permissive shape: it accepts a reordered,
# renamed or dropped flag, and a fake that accepts an argv it was not designed
# for has stopped testing anything.
[ "$#" -eq 9 ] &&
  [ "$1" = "run" ] && [ "$2" = "--no-session" ] && [ "$3" = "--quiet" ] &&
  [ "$4" = "-t" ] && [ "$6" = "--provider" ] && [ "$8" = "--model" ] ||
  die "unhandled argv: $*"
prompt="$5"
provider="$7"
model="$9"

# ---------------------------------------------------------------- the work --
# Eight steps, in this order because each narrows what a later failure can mean.

# 1. The provider JSON must be where check-goose.sh:47 looks, in THIS $HOME.
#    bootstrap-mac.sh:207-210 wrote it in a different process from a different
#    $REPO_ROOT; that the two steps agree on the path is half of what a green
#    check-goose actually proves, and nothing else in the repo asserts it.
provider_json="$HOME/.config/goose/custom_providers/$provider.json"
[ -f "$provider_json" ] || die "no provider JSON at $provider_json"

# 2. Everything the request is built from comes out of the INSTALLED file, not
#    out of this script. Hardcoding a URL here would test the fake, not the copy.
base_url="$(json_field "$provider_json" base_url)"
engine="$(json_field "$provider_json" engine)"
api_key_env="$(json_field "$provider_json" api_key_env)"

# 3. Byte for byte against the repo copy. bootstrap's copy_no_clobber keeps an
#    existing file forever, so a base_url mangled by a half-finished A/B swap
#    (the swap check-goose.sh:136-139 tells you to make) survives every re-run —
#    this is the assertion that notices.
repo_json="$REPO_ROOT/config/goose/custom_providers/$provider.json"
[ -f "$repo_json" ] || die "no repo provider JSON at $repo_json"
repo_base_url="$(json_field "$repo_json" base_url)"
[ "$base_url" = "$repo_base_url" ] ||
  die "installed base_url for $provider is '$base_url'; repo ships '$repo_base_url'"

# 4. The pair check-goose.sh:52 sends must be one the installed catalog offers.
#    pin-models.sh prunes these lists as Zen deprecates; a model that fell out
#    of the JSON must fail here, not as an opaque 404 from the provider.
json_has_model "$provider_json" "$model" || die "model '$model' is not in $provider_json"

# 5. Goose's engine rule, mirrored from check-goose.sh:55-57 (verified there
#    against v1.46.0): the openai engine appends /chat/completions only when the
#    base_url does not already end in it, while the anthropic engine ALWAYS
#    appends /v1/messages — which is why zen-anthropic.json ships a bare base.
case "$engine" in
  openai)
    case "$base_url" in
      */chat/completions) url="$base_url" ;;
      *) url="$base_url/chat/completions" ;;
    esac
    ;;
  anthropic) url="$base_url/v1/messages" ;;
  *) die "unhandled engine in $provider_json: $engine" ;;
esac

# 6. Rewrite the ORIGIN ONLY. The path computed in step 5 rides through
#    untouched, so what reaches fake-provider.py is the exact path the shipped
#    base_url plus the engine rule produced — the very question check-goose.sh
#    exists to settle. Rewriting the whole URL to a fixed endpoint would answer
#    that question by assumption. An origin with no entry in this map is a
#    request headed for a real provider, and dies here rather than leaving.
: "${FAKE_PROVIDER_URL:?fake-goose: FAKE_PROVIDER_URL is required}"
zen_origin="https://opencode.ai/zen"
together_origin="https://api.together.xyz"
case "$url" in
  "$zen_origin"/*) target="$FAKE_PROVIDER_URL/zen${url#"$zen_origin"}" ;;
  "$together_origin"/*) target="$FAKE_PROVIDER_URL/together${url#"$together_origin"}" ;;
  *) die "no origin rewrite for $url — refusing to contact a real provider" ;;
esac

# 7. The key the installed JSON names, in the header the engine implies. The
#    indirection is the assertion: a provider JSON pointing at a variable the
#    setup never sets fails here instead of at the provider.
#    The name is checked BEFORE the indirection, because bash evaluates an
#    array subscript inside ${!name}: an api_key_env of `x[$(...)]` in the
#    installed JSON runs that substitution instead of naming a variable, and
#    this is the one fake that holds a live credential. Step 3 pins only
#    base_url against the repo copy, so this field arrives unconstrained; a
#    value that is not a plain shell identifier is input this file was never
#    designed for and dies naming itself rather than being evaluated.
case "$api_key_env" in
  "" | [0-9]* | *[!A-Za-z0-9_]*) die "$provider has a non-identifier api_key_env: '$api_key_env'" ;;
esac
key="${!api_key_env:-}"
[ -n "$key" ] || die "$provider names \$$api_key_env, which is unset or empty"
case "$engine" in
  openai) auth=(-H "Authorization: Bearer $key") ;;
  # anthropic-version is not decoration: fake-provider.py 400s /v1/messages
  # without it, which is what makes "goose's anthropic engine sends it" an
  # observation rather than a claim inherited from the docs.
  anthropic) auth=(-H "x-api-key: $key" -H "anthropic-version: 2023-06-01") ;;
  # Unreachable — step 5 already rejected any other engine. Kept so a future
  # edit that splits these cases apart cannot leave "$auth" unset, which under
  # `set -u` would abort with bash's message instead of this file's.
  *) die "unhandled engine in $provider_json: $engine" ;;
esac

# 8. json.dumps builds the body so a quote or backslash in the prompt or the
#    model id cannot produce malformed JSON that fake-provider.py would 404 for
#    the wrong reason. -o /dev/null is the output rule made mechanical: the body
#    cannot be printed because it is never held.
payload="$(python3 -c 'import json,sys
print(json.dumps({"model": sys.argv[1], "max_tokens": 1,
                  "messages": [{"role": "user", "content": sys.argv[2]}]}))' "$model" "$prompt")"
status="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' \
  -X POST "${auth[@]}" -H "Content-Type: application/json" \
  -d "$payload" "$target")" || status="000"

# Status and URL only — no header, no body, no key. `OK` is the literal
# check-goose.sh:116 greps for, and it is the whole of the happy-path output.
[ "$status" = "200" ] || die "HTTP $status for $target"
printf 'OK\n'
