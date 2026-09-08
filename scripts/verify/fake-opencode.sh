#!/usr/bin/env bash
# fake-opencode.sh — the OpenCode CLI stand-in, for check-opencode.sh.
#
# WRITTEN AGAINST THE CALLER, NOT AGAINST OPENCODE. Same standing rule as
# fake-goose.sh:16-19: the argv matcher below encodes exactly the two shapes
# check-opencode.sh emits (`--version` and `run <prompt>`) and dies on anything
# else. A change to OpenCode's own CLI is invisible here on purpose — what this
# harness tests is this repo's scripts and config, not upstream's acceptance of
# them.
#
# WHY IT EXISTS. check-opencode.sh's headline row is "an `opencode run`
# succeeded". A `#!/bin/sh` + `echo OK` shim satisfies that while proving that
# the install has a credential, a config and a reachable provider — which is
# every single thing the check is for. This is the floor under it: the run below
# fails unless the INSTALLED ~/.config/opencode/opencode.json is readable and
# names the model the repo ships, the INSTALLED ~/.local/share/opencode/auth.json
# carries a usable key, and a provider answers 200 to a request built from both.
#
# WHY small_model AND NOT model. fake-provider.py's Zen catalog is three literal
# ids (:113) and `model` in the shipped opencode.json is `opencode/kimi-k2.6`,
# which is not one of them; `small_model` is `opencode/minimax-m2.7`, which is.
# Being honest about what that buys: this is NOT a claim that a real `opencode
# run` picks small_model for the main completion. It is the id that lets the
# request be built end to end from the installed config against the fake
# provider this repo already ships, and the assertion it carries is "the model
# id on the wire came out of the installed opencode.json" — break that file's
# wiring and the recorded row changes or the request 404s.
#
# SECRETS. This file reads a live credential out of auth.json and hands it to
# curl as a header. It is never echoed, never interpolated into an error message
# (errors carry a status code and a URL), never placed on any argv, and no
# response body is reprinted — only the single `content` field is, which is what
# a real `opencode run` puts on stdout and what check-opencode.sh greps.
set -euo pipefail

die() { echo "fake-opencode: $*" >&2; exit 1; }

[ "$#" -gt 0 ] || die "no argv"

if [ "$1" = "--version" ]; then
  # A bare version and nothing else: check-opencode.sh's shadowing rows pipe
  # this through `head -1` and print it next to a path.
  [ "$#" -eq 1 ] || die "unhandled argv: $*"
  printf '%s\n' "${FAKE_OPENCODE_VERSION:?fake-opencode: FAKE_OPENCODE_VERSION is required}"
  exit 0
fi

# The one run shape check-opencode.sh emits, matched by position and arity. A
# flag walk would accept a reordered or dropped operand, and a fake that accepts
# an argv it was not designed for has stopped testing anything.
[ "$#" -eq 2 ] && [ "$1" = "run" ] || die "unhandled argv: $*"
prompt="$2"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

# python3 + json, the way the rest of the verify fakes read structured files
# (stub-engine.sh:23, fake-goose.sh:48-51): a missing key raises and the command
# substitution dies, where grep would hand back an empty string and let the
# assertion pass.
json_field() {
  # $1 = JSON file, $2 = top-level key
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"
}

# 1. The config must be where bootstrap-mac.sh's unit_opencode() put it, in THIS
#    $HOME. Two different processes agreeing on that path is half of what a
#    green check-opencode actually proves.
config_json="$HOME/.config/opencode/opencode.json"
[ -f "$config_json" ] || die "no OpenCode config at $config_json"

# 2. Byte for byte against the repo copy, for the one field the request is built
#    from. copy_no_clobber keeps an existing file forever, so a small_model
#    mangled by a half-finished edit survives every re-run — this is the
#    assertion that notices.
repo_json="$REPO_ROOT/config/opencode/opencode.json"
[ -f "$repo_json" ] || die "no repo OpenCode config at $repo_json"
small_model="$(json_field "$config_json" small_model)"
repo_small_model="$(json_field "$repo_json" small_model)"
[ "$small_model" = "$repo_small_model" ] ||
  die "installed small_model is '$small_model'; repo ships '$repo_small_model'"

# 3. `provider/id` is OpenCode's model spelling; the wire wants the bare id.
#    Split rather than assumed, so a config that drops the provider prefix
#    (or invents a second slash) fails here rather than as an opaque 404.
case "$small_model" in
  */*/*) die "small_model '$small_model' has more than one provider prefix" ;;
  opencode/*) wire_model="${small_model#opencode/}" ;;
  *) die "small_model '$small_model' is not an opencode/* id — refusing to guess the provider" ;;
esac

# 4. The credential comes out of the file opencode-auth.sh wrote, and only out of
#    that file. No environment fallback: reading $OPENCODE_ZEN_API_KEY here would
#    make the run pass on a Mac where auth.json was never written, which is
#    exactly the state check-opencode.sh exists to catch.
auth_json="$HOME/.local/share/opencode/auth.json"
[ -f "$auth_json" ] || die "no credential at $auth_json (run scripts/mac/opencode-auth.sh)"
key="$(python3 -c '
import json, sys
entry = json.load(open(sys.argv[1])).get("opencode") or {}
key = entry.get("key")
if not isinstance(key, str) or not key:
    sys.exit("no usable opencode api key in the auth file")
print(key)
' "$auth_json")" || die "could not read the opencode credential out of $auth_json"

# 5. Never a real provider. Same rule as fake-goose.sh:129-142 — there is no
#    default, so a harness that forgot to set this dies here rather than sending
#    a fixture key to opencode.ai.
: "${FAKE_PROVIDER_URL:?fake-opencode: FAKE_PROVIDER_URL is required}"
target="$FAKE_PROVIDER_URL/zen/v1/chat/completions"

# 6. json.dumps builds the body so a quote or backslash in the prompt or the
#    model id cannot produce malformed JSON that the provider would 404 for the
#    wrong reason.
payload="$(python3 -c 'import json,sys
print(json.dumps({"model": sys.argv[1], "max_tokens": 16,
                  "messages": [{"role": "user", "content": sys.argv[2]}]}))' \
  "$wire_model" "$prompt")"

body="$(mktemp)"
trap 'rm -f "$body"' EXIT
status="$(curl -sS --max-time 30 -o "$body" -w '%{http_code}' \
  -X POST -H "Authorization: Bearer $key" -H "Content-Type: application/json" \
  -d "$payload" "$target")" || status="000"

# Status and URL only — no header, no body, no key.
[ "$status" = "200" ] || die "HTTP $status for $target"

# 7. ONE FIELD, not the body. A real `opencode run` prints the model's answer;
#    reprinting the whole response would put whatever a provider chose to echo
#    (see fake-provider.py's no-echo rule) onto a log this harness greps.
python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
print(doc["choices"][0]["message"]["content"])
' "$body"
