#!/usr/bin/env bash
# check-connectors.sh — the connector manifest validator and smoke runner.
#
# Four jobs, in order:
#
#   1. ACP contract. Fetches crates/goose/acp-meta.json and acp-schema.json
#      from aaif-goose/goose AT THE PINNED VERSION TAG and asserts that every
#      ACP method this feature calls still exists, that `available_tools` is
#      still snake_case in the schema, and that clientId/clientSecretKey/scopes
#      are still absent (they are v1.47.0+ only). No network, no gh → SKIP.
#
#   2. Manifests. Every config/connectors/*.yaml against the contract in
#      config/connectors/README.md. The headline check is `available_tools`:
#      it is snake_case on the ACP wire, alone among its camelCase siblings,
#      goose sets no deny_unknown_fields, and an absent-or-empty allowlist
#      means ALL TOOLS ALLOWED. A camelCase `availableTools` is therefore
#      silently discarded and least privilege becomes a no-op. That failure is
#      invisible everywhere else in the stack; this script is where it dies.
#
#   3. --smoke <id>. Speaks MCP JSON-RPC straight to the manifest's server
#      (initialize, then tools/list) and asserts the exact tool set/count the
#      manifest claims. goose is not in the loop, so tools/list returns the
#      server's FULL surface — which is what turns the allowlist from a list
#      someone typed into observed fact, and what makes "how many tools would
#      go live if the allowlist were dropped" a real number.
#
#   4. --acp-roundtrip <id>. The second mandatory mitigation in
#      config/connectors/README.md, as a script rather than a habit: drives
#      config/extensions/add and then config/extensions/list against a RUNNING
#      goose serve and asserts the allowlist came back non-empty and set-equal
#      to what was sent. Job 2 can only prove the FILE says available_tools;
#      this is the only check in the repo that proves goose KEPT it — the exact
#      thing a camelCase spelling destroys silently in production.
#
# Never prints a secret: env var NAMES, HTTP status codes, tool names and
# counts only. Server stderr is redacted against the values of the declared
# envKeys before any of it is echoed.
set -euo pipefail

# shellcheck source=scripts/verify/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: check-connectors.sh [--smoke <id>] [--acp-roundtrip <id>] [--acp-url <url>]
                           [--goose-version <vX.Y.Z>] [--offline] [--help]

  --smoke <id>            After validating, run <id>'s smoke test: speak MCP to
                          the real server(s) over stdio or streamable HTTP and
                          assert the manifest's tool set/count. Needs the
                          connector's credentials in the environment; SKIPs
                          (never fails) when they are absent.
  --acp-roundtrip <id>    Drive config/extensions/add + config/extensions/list
                          against a running `goose serve` and assert the
                          allowlist survived the round trip non-empty and
                          set-equal. This is the fail-open check: everything
                          else can only read the manifest. Needs
                          GOOSE_SERVER__SECRET_KEY and a reachable server;
                          SKIPs when either is absent. Spawns no MCP server and
                          needs no connector credential — it only touches
                          goose's own config, and removes anything it added.
  --acp-url <url>         Where `goose serve` answers ACP. Default is
                          $GOOSE_ACP_URL, else https://127.0.0.1:3284/acp.
                          On the brain: https://<tailscale-ip>:3284/acp.
  --goose-version <tag>   Pin the ACP contract check to this tag. Default is
                          derived from infra/terraform/templates/cloud-init.yaml.tftpl
                          (GOOSE_VERSION=...), falling back to v1.46.0.
  --offline               Skip the two network checks outright.

Validates every config/connectors/*.yaml. Exits non-zero if anything FAILs.
SKIPs (no network, no credentials, no goose installed) never fail the run, and
NOTE lines are advisory — they are counted as nothing.

Every rule enforced here exists because getting it wrong has an observed
consequence; they are documented in config/connectors/README.md, starting with
the camelCase spelling that silently allows every tool.

Requires python3 with PyYAML (falls back to `uv run --with pyyaml`).
EOF
}

SMOKE_ID=""
ROUNDTRIP_ID=""
ACP_URL="${GOOSE_ACP_URL:-https://127.0.0.1:3284/acp}"
GOOSE_TAG_FLAG=""
OFFLINE="no"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)          usage; exit 0 ;;
    --offline)          OFFLINE="yes" ;;
    --smoke)            shift; [ $# -gt 0 ] || die 2 "--smoke needs an <id>"; SMOKE_ID="$1" ;;
    --smoke=*)          SMOKE_ID="${1#*=}" ;;
    --acp-roundtrip)    shift; [ $# -gt 0 ] || die 2 "--acp-roundtrip needs an <id>"; ROUNDTRIP_ID="$1" ;;
    --acp-roundtrip=*)  ROUNDTRIP_ID="${1#*=}" ;;
    --acp-url)          shift; [ $# -gt 0 ] || die 2 "--acp-url needs a URL"; ACP_URL="$1" ;;
    --acp-url=*)        ACP_URL="${1#*=}" ;;
    --goose-version)    shift; [ $# -gt 0 ] || die 2 "--goose-version needs a tag"; GOOSE_TAG_FLAG="$1" ;;
    --goose-version=*)  GOOSE_TAG_FLAG="${1#*=}" ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONNECTOR_DIR="$REPO_ROOT/config/connectors"
PRIVACY_DOC="$REPO_ROOT/docs/privacy.md"
CLOUD_INIT="$REPO_ROOT/infra/terraform/templates/cloud-init.yaml.tftpl"

# A non-interactive SSH shell on the brain does not source the profile that
# puts ~/.local/bin on PATH, so fall back to the known install location the way
# check-mcp.sh and register-schedules.sh do. Unlike those, a missing goose is
# NOT fatal here: manifest validation is text work and must run in CI on a
# machine that has never installed goose.
GOOSE_BIN="$(resolve_goose_bin)"

# ---- the pinned goose version ----------------------------------------------
# Single source of truth is the brain's installer line in cloud-init; the Mac
# pins the same release with `brew pin block-goose-cli`. Deriving it means a
# deliberate bump drags this check along instead of leaving a stale literal in
# a verification script.
GOOSE_TAG=""
TAG_SOURCE=""
if [ -n "$GOOSE_TAG_FLAG" ]; then
  GOOSE_TAG="$GOOSE_TAG_FLAG"
  TAG_SOURCE="--goose-version flag"
elif [ -r "$CLOUD_INIT" ]; then
  GOOSE_TAG="$(grep -oE 'GOOSE_VERSION=v[0-9]+\.[0-9]+\.[0-9]+' "$CLOUD_INIT" | head -n 1 | cut -d= -f2 || true)"
  [ -n "$GOOSE_TAG" ] && TAG_SOURCE="infra/terraform/templates/cloud-init.yaml.tftpl"
fi
if [ -z "$GOOSE_TAG" ]; then
  GOOSE_TAG="v1.46.0"
  TAG_SOURCE="built-in default (cloud-init not readable)"
fi
GOOSE_VER="${GOOSE_TAG#v}"

# ---- python runner ----------------------------------------------------------
# python3 is already a dependency of scripts/verify (test-code-agent-manager.sh,
# stub-engine.sh). PyYAML is not universally present, so fall back to uv, which
# both bootstrap-mac.sh and cloud-init install.
if ! command -v python3 >/dev/null 2>&1; then
  die 2 "python3 not found (needed to parse YAML/JSON)"
fi
PY=(python3)
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  if command -v uv >/dev/null 2>&1; then
    PY=(uv run --quiet --with pyyaml python)
  else
    die 2 "python3 cannot import yaml (PyYAML)." \
      "  Mac:   uv is installed by scripts/mac/bootstrap-mac.sh — re-run it," \
      "         or: python3 -m pip install --user pyyaml" \
      "  Brain: apt-get install -y python3-yaml"
  fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT_FILE="$WORK/out"
VALIDATOR="$WORK/validate.py"
ACP_CHECK="$WORK/acp_contract.py"
SMOKE_PY="$WORK/smoke.py"
ROUNDTRIP_PY="$WORK/roundtrip.py"
SCHEMA_KEYS="$WORK/schema-keys.json"

# run_check <summary-label> <command...> — runs a python checker that emits
# "PASS  ", "FAIL  ", "SKIP  ", "NOTE  " and "      | " lines, counts them here
# so the totals live in one place, and adds one verdict per label to the
# summary. A checker that dies (rather than reporting) is itself a FAIL.
run_check() {
  local label="$1"; shift
  local before before_pass before_skip rc line
  before="$FAIL_COUNT"
  before_pass="$PASS_COUNT"
  before_skip="$SKIP_COUNT"
  rc=0
  "$@" >"$OUT_FILE" 2>&1 || rc=$?
  while IFS= read -r line; do
    case "$line" in
      "PASS  "*) record_pass ;;
      "FAIL  "*) record_fail ;;
      "SKIP  "*) record_skip ;;
    esac
    printf '%s\n' "$line"
  done <"$OUT_FILE"
  if [ "$rc" -ne 0 ]; then
    echo "FAIL  $label: checker exited $rc (a bug in the checker, or a manifest that broke the parser)"
    record_fail
  fi
  if [ "$FAIL_COUNT" -gt "$before" ]; then
    summary_row "FAIL  $label ($((FAIL_COUNT - before)) problem(s))"
  elif [ "$PASS_COUNT" -eq "$before_pass" ] && [ "$SKIP_COUNT" -gt "$before_skip" ]; then
    # Nothing was actually proven — say so rather than reporting a green PASS.
    summary_row "SKIP  $label (nothing asserted)"
  else
    summary_row "PASS  $label"
  fi
}

# ---------------------------------------------------------------------------
# The checkers, written to $WORK so the quoting stays sane and so each one is a
# normal python program you can run by hand while debugging.
# ---------------------------------------------------------------------------

cat >"$ACP_CHECK" <<'PYEOF'
"""Assert goose's published ACP contract at the pinned tag.

acp-meta.json is the only machine-readable list of ACP methods goose ships;
acp-schema.json is the JSON Schema for the payloads. Both are read at the TAG,
never at main, because the `_goose/unstable/` prefix means what it says:
`config/extensions/toggle` became `set-enabled` between v1.37 and v1.38, and an
entire `_goose/config/*` family was deleted.
"""
import json
import sys

meta_path, schema_path, keys_out, tag = sys.argv[1:5]

# The eleven methods this feature calls. All verified present at v1.46.0.
METHODS = [
    "_goose/unstable/extensions/available",
    "_goose/unstable/config/extensions/list",
    "_goose/unstable/config/extensions/add",
    "_goose/unstable/config/extensions/remove",
    "_goose/unstable/config/extensions/set-enabled",
    "_goose/unstable/session/extensions/add",
    "_goose/unstable/session/extensions/remove",
    "_goose/unstable/session/extensions/list",
    "_goose/unstable/config/upsert",
    "_goose/unstable/config/read",
    "_goose/unstable/config/remove",
]


def ok(msg):
    print("PASS  acp@%s: %s" % (tag, msg))


def bad(msg, *cont):
    print("FAIL  acp@%s: %s" % (tag, msg))
    for line in cont:
        print("      | %s" % line)


# ---- 1. the method names ----------------------------------------------------
try:
    meta = json.load(open(meta_path))
    names = {m["method"] for m in meta.get("methods", []) if isinstance(m, dict)}
except Exception as exc:                                    # noqa: BLE001
    bad("acp-meta.json did not parse: %s" % type(exc).__name__)
    names = set()

if names:
    missing = [m for m in METHODS if m not in names]
    if missing:
        bad(
            "%d of %d required ACP methods are GONE at this tag" % (len(missing), len(METHODS)),
            *(missing + [
                "The connect workflow's adapter is keyed to the pinned version and there",
                "is no capability negotiation for these — a client must know from the pin.",
                "Re-verify docs/connecting.md before moving it.",
            ])
        )
    else:
        ok("all %d ACP methods this feature calls are present (of %d published)" % (len(METHODS), len(names)))

# ---- 2. the schema fields that fail open ------------------------------------
try:
    schema = json.load(open(schema_path))
    defs = schema.get("$defs") or schema.get("definitions") or {}
except Exception as exc:                                    # noqa: BLE001
    bad("acp-schema.json did not parse: %s" % type(exc).__name__)
    defs = {}

mcp = {}
for branch in defs.get("GooseExtension", {}).get("oneOf", []):
    props = branch.get("properties", {})
    if props.get("type", {}).get("const") == "mcp":
        mcp = props
        break

if not mcp:
    if defs:
        bad("GooseExtension has no `mcp` variant at this tag — the manifest shape is obsolete")
else:
    if "available_tools" in mcp and "availableTools" not in mcp:
        ok("available_tools is still snake_case (and availableTools is still not a field)")
    elif "availableTools" in mcp:
        bad(
            "upstream renamed the allowlist to availableTools",
            "Every shipped manifest now sends a field goose ignores, which means EVERY",
            "TOOL IS ALLOWED on every connector. Fix the manifests and this script in",
            "the same commit as the version bump.",
        )
    else:
        bad("GooseExtension.mcp has no tool allowlist field at all — re-read the schema before bumping the pin")

    if "envKeys" in mcp:
        ok("envKeys is still camelCase")
    else:
        bad("GooseExtension.mcp lost `envKeys` — per-connector secrets no longer work as documented")

    oauth = [k for k in ("clientId", "clientSecretKey", "scopes") if k in mcp]
    if oauth:
        bad(
            "OAuth fields now exist on the mcp variant: %s" % ", ".join(sorted(oauth)),
            "Those are v1.47.0+. Manifests are validated as if they cannot exist, so if",
            "the pin has moved, docs/connecting.md's OAuth section needs re-verifying —",
            "and OAuth still cannot be completed from a phone.",
        )
    else:
        ok("clientId/clientSecretKey/scopes absent, as expected at a 1.46.x pin")

http = defs.get("McpServerHttp", {}).get("properties", {})
if http:
    if "url" in http and "uri" not in http:
        ok("remote transport still spells it `url` on the wire (config.yaml says `uri`)")
    else:
        bad("McpServerHttp field names changed — recheck the two-layer table in config/connectors/README.md")

# Export the schema's own property names so manifest validation can reject
# unknown keys client-side. goose will not: there is no deny_unknown_fields.
keys = {
    "mcp": sorted(mcp.keys()),
    "stdio": sorted(defs.get("McpServerStdio", {}).get("properties", {}).keys()),
    "http": sorted(http.keys()),
}
if keys["mcp"] and keys["stdio"]:
    json.dump(keys, open(keys_out, "w"))
PYEOF

cat >"$VALIDATOR" <<'PYEOF'
"""Validate one connector manifest against config/connectors/README.md.

Emits PASS/FAIL lines (counted by the shell), NOTE lines (advisory, uncounted),
and "      | " continuations. Never prints the value of a field whose name
matches a declared secret.
"""
import datetime
import json
import os
import re
import sys

import yaml

MANIFEST, REPO_ROOT, PINNED_VER, KEYFILE, PRIVACY_DOC = sys.argv[1:6]
NAME = os.path.basename(MANIFEST)
STEM = NAME[:-5] if NAME.endswith(".yaml") else NAME

ARCHETYPES = {
    "first_party_remote_mcp",
    "self_hosted_mcp_stdio",
    "standard_protocol_bridge",
    "local_cli_wrapper",
    "browser_automation",
    "periodic_export",
}
FIRST_RUN_AUTH = {"none", "phone_secret", "brain_browser", "laptop_oob"}
PHONE_COMPLETABLE = {"yes", "no", "partial"}
VETTING_BARS = ["maintenance", "self_hosted_auth", "relocatable_state", "restrictable_tools", "privacy_row"]
TOP_LEVEL = {
    "id", "display_name", "summary", "manifest_version", "verified_on", "goose_version_verified",
    "archetype", "capabilities", "first_run_auth", "phone_completable", "auth_notes",
    "privacy", "vetting", "secrets", "acp_extension", "smoke_test", "runbook", "blockers", "notes",
}
SMOKE_KEYS = {
    "kind", "command", "expect_tools_exactly", "expect_tools_set", "expect_tools_absent",
    "expect_roundtrip", "notes",
}
# Fallback key lists, read off crates/goose/acp-schema.json at v1.46.0. Used
# only when the live schema could not be fetched; the live schema always wins.
FALLBACK_KEYS = {
    "mcp": ["available_tools", "bundled", "description", "envKeys", "server", "socket", "timeout", "type"],
    "stdio": ["_meta", "args", "command", "env", "name"],
    "http": ["_meta", "headers", "name", "type", "url"],
}
# Well-known credential prefixes. A deliberately short heuristic: a hit means a
# real token got pasted into a file that lives in a public repo.
TOKEN_PREFIXES = ("sk-", "ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-", "AKIA", "AIza", "-----BEGIN")


def ok(msg):
    print("PASS  %s: %s" % (STEM, msg))


def bad(msg, *cont):
    print("FAIL  %s: %s" % (STEM, msg))
    for line in cont:
        print("      | %s" % line)


def note(msg):
    print("NOTE  %s: %s" % (STEM, msg))


def walk(node, path=""):
    """Yield (dotted path, scalar) for every leaf."""
    if isinstance(node, dict):
        for k, v in node.items():
            for item in walk(v, "%s.%s" % (path, k) if path else str(k)):
                yield item
    elif isinstance(node, list):
        for i, v in enumerate(node):
            for item in walk(v, "%s[%d]" % (path, i)):
                yield item
    else:
        yield path, node


def walk_keys(node, path=""):
    """Yield (key, dotted path) for every mapping key. Comment-immune, unlike a
    text grep — a manifest that *documents* the camelCase trap in a comment is
    doing the right thing and must not be failed for it."""
    if isinstance(node, dict):
        for k, v in node.items():
            p = "%s.%s" % (path, k) if path else str(k)
            yield str(k), p
            for item in walk_keys(v, p):
                yield item
    elif isinstance(node, list):
        for i, v in enumerate(node):
            for item in walk_keys(v, "%s[%d]" % (path, i)):
                yield item


try:
    doc = yaml.safe_load(open(MANIFEST, encoding="utf-8").read())
except yaml.YAMLError as exc:
    bad("does not parse as YAML: %s" % str(exc).splitlines()[0])
    sys.exit(0)

if not isinstance(doc, dict):
    bad("top level is %s, not a mapping" % type(doc).__name__)
    sys.exit(0)

all_keys = list(walk_keys(doc))

# ---- 0. THE HEADLINE: the spelling that fails open -------------------------
camel = [p for k, p in all_keys if k == "availableTools"]
if camel:
    bad(
        "spells the allowlist `availableTools` at %s" % ", ".join(camel),
        "goose's #[serde(rename_all = \"snake_case\")] renames VARIANTS, not fields:",
        "`available_tools` is snake_case on the ACP wire while envKeys/clientId are",
        "camelCase, and there is no deny_unknown_fields. camelCase is SILENTLY",
        "DROPPED, available_tools then defaults to an empty allowlist, and an empty",
        "allowlist means EVERY TOOL IS ALLOWED. A read-only Gmail connector written",
        "this way ships with send_gmail_message live. Rename it to available_tools.",
    )

for wrong, right, why in (
    ("env_keys", "envKeys", "that is the config.yaml spelling"),
    ("uri", "url", "that is the config.yaml spelling"),
):
    hits = [p for k, p in all_keys if k == wrong]
    if hits:
        bad(
            "uses `%s` at %s — %s; a manifest describes the ACP WIRE shape (`%s`), goose translates"
            % (wrong, ", ".join(hits), why, right)
        )

for path, value in walk(doc):
    if path.endswith(".type") and value == "streamable_http":
        bad("`%s: streamable_http` is the config.yaml spelling; the ACP wire says `http`" % path)

for forbidden in ("clientId", "clientSecretKey", "scopes"):
    hits = [p for k, p in all_keys if k == forbidden]
    if hits:
        bad(
            "declares `%s` at %s" % (forbidden, ", ".join(hits)),
            "The OAuth fields on the mcp variant are v1.47.0+ and do not exist at the",
            "pinned %s, so goose drops them silently. And OAuth cannot be completed" % PINNED_VER,
            "from a phone at all (docs/connecting.md): the callback is loopback-bound on",
            "the brain and the authorization URL appears in no ACP message. Use a bearer",
            "token or app password — first_run_auth: phone_secret.",
        )

unknown_top = sorted({k for k, p in all_keys if p == k and k not in TOP_LEVEL})
if unknown_top:
    note("top-level key(s) not in the README schema: %s" % ", ".join(unknown_top))

# ---- 1. identity ------------------------------------------------------------
problems = []
mid = doc.get("id")
if not isinstance(mid, str) or not mid:
    problems.append("id is missing")
else:
    if mid != STEM:
        problems.append("id %r does not match the filename stem %r" % (mid, STEM))
    if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", mid):
        problems.append("id %r is not kebab-case" % mid)
for field in ("display_name", "summary"):
    if not str(doc.get(field, "") or "").strip():
        problems.append("%s is missing or empty" % field)
if doc.get("manifest_version") != 1:
    problems.append("manifest_version is %r, expected 1" % doc.get("manifest_version"))

verified_on = doc.get("verified_on")
if isinstance(verified_on, datetime.datetime):
    verified_on = verified_on.date()
if isinstance(verified_on, datetime.date):
    if verified_on > datetime.date.today():
        problems.append("verified_on %s is in the future" % verified_on)
elif isinstance(verified_on, str):
    try:
        datetime.date.fromisoformat(verified_on)
    except ValueError:
        problems.append("verified_on %r is not an ISO date" % verified_on)
else:
    problems.append("verified_on is missing")

gvv = str(doc.get("goose_version_verified") or "").lstrip("v")
if not gvv:
    problems.append("goose_version_verified is missing")
elif gvv != PINNED_VER:
    problems.append(
        "goose_version_verified %s != the pinned %s — the wire shapes in this manifest "
        "were verified against a goose nobody runs" % (gvv, PINNED_VER)
    )

if problems:
    bad("identity block", *problems)
else:
    ok("identity: id/display_name/summary/manifest_version/verified_on/goose_version_verified")

# ---- 2. archetype & capabilities -------------------------------------------
problems = []
arche = doc.get("archetype")
if arche not in ARCHETYPES:
    problems.append("archetype %r is not one of: %s" % (arche, ", ".join(sorted(ARCHETYPES))))
caps = doc.get("capabilities")
if not isinstance(caps, list) or not caps or not all(isinstance(c, str) and c for c in caps):
    problems.append("capabilities must be a non-empty list of strings")
    caps = []
if problems:
    bad("archetype/capabilities", *problems)
else:
    ok("archetype %s, capabilities %s" % (arche, ", ".join(caps)))

# ---- 3. can it be finished from a phone? -----------------------------------
problems = []
fra = doc.get("first_run_auth")
pc = doc.get("phone_completable")
# YAML 1.1 (which PyYAML implements) resolves bare yes/no/on/off to booleans and
# bare null/~/Null to None, so `phone_completable: no` is the boolean False to
# every reader, not the enum value "no". This is the same shape of trap as
# availableTools — the file looks right, the parsed value is something else —
# so it is a FAIL, not a note: one reader special-cases the boolean back into a
# string (this validator used to), the next one compares it to "no", gets False,
# and silently treats a laptop-only connector as phone-completable.
for field, raw in (("first_run_auth", fra), ("phone_completable", pc)):
    if isinstance(raw, bool):
        problems.append(
            "%s is the bare word %s, which YAML 1.1 resolves to the boolean %s, not the "
            "string %r. Quote it: %s: \"%s\""
            % (field, "yes" if raw else "no", raw, "yes" if raw else "no",
               field, "yes" if raw else "no")
        )
    elif raw is None and field in doc:
        problems.append(
            "%s is present but resolves to null (bare null/~/Null/empty in YAML 1.1). "
            "Quote the value you meant." % field
        )
if isinstance(pc, bool):
    pc = "yes" if pc else "no"
if fra not in FIRST_RUN_AUTH:
    problems.append("first_run_auth %r is not one of: %s" % (fra, ", ".join(sorted(FIRST_RUN_AUTH))))
if pc not in PHONE_COMPLETABLE:
    problems.append("phone_completable %r is not one of: yes, no, partial" % (pc,))
if fra in ("brain_browser", "laptop_oob") and pc == "yes":
    problems.append(
        "first_run_auth: %s but phone_completable: yes — the consent listener binds "
        "127.0.0.1 ON THE BRAIN and the auth URL never leaves it, so this claim strands "
        "the user 40 minutes into a connect it cannot finish" % fra
    )
if fra not in (None, "none") and not str(doc.get("auth_notes", "") or "").strip():
    problems.append("auth_notes is empty — say where the credential comes from and who can produce it")
if problems:
    bad("first_run_auth/phone_completable", *problems)
else:
    ok("first_run_auth: %s, phone_completable: %s" % (fra, pc))

# ---- 4. privacy: an actual grep, not a self-certification ------------------
# What counts as "a row" is one exact marker, `<!-- connector: <id> -->`, in the
# connector data-source table of docs/privacy.md. It is deliberately not a
# search for the display name: "Google Workspace" appears in that document for a
# dozen unrelated reasons, so a name grep would pass on prose that classifies
# nothing, and would fail the moment a row is retitled. The marker also settles
# which table is meant — the provider policy table is about INFERENCE ROUTES
# (where data goes), a different axis from DATA SOURCES (what a connector can
# pull in), and a connector adding no new provider owes no provider-table row.
privacy = doc.get("privacy")
if not isinstance(privacy, dict):
    bad("privacy block is missing")
else:
    tier = privacy.get("tier")
    row_claimed = privacy.get("row_added")
    problems = []
    if tier not in (1, 2, 3):
        problems.append("privacy.tier %r is not 1, 2 or 3" % (tier,))
    if not str(privacy.get("notes", "") or "").strip():
        problems.append(
            "privacy.notes is empty — classify by the most sensitive content this "
            "connector can surface, not by its label"
        )
    if not isinstance(row_claimed, bool):
        problems.append("privacy.row_added must be true or false")

    marker = "<!-- connector: %s -->" % (mid if isinstance(mid, str) and mid else STEM)
    marker_re = re.compile(
        r"<!--\s*connector:\s*%s\s*-->" % re.escape(mid if isinstance(mid, str) and mid else STEM)
    )

    row_found = False
    if os.path.exists(PRIVACY_DOC):
        row_found = bool(marker_re.search(open(PRIVACY_DOC, encoding="utf-8").read()))
    else:
        problems.append("%s not found — cannot verify the privacy row" % PRIVACY_DOC)

    missing_row = (
        "docs/privacy.md has no row anchored `%s`. The row goes in the connector "
        "data-source table (\"Connector data sources\"), which is a different axis from "
        "the provider policy table above it: that one records where data GOES, this one "
        "records what a connector can pull IN. Add the marker in the same edit as the row "
        "— the grep is for the marker, not the display name." % marker
    )
    # A missing row is a hard failure at EVERY tier. docs/privacy.md states the rule
    # without qualification — "every connector needs a row here before its first call" —
    # and a gate that only bites at tier 3 would make that sentence false. An honest
    # `row_added: false` does not soften it: it records that the connector is not usable
    # yet, which is exactly what a FAIL means.
    if not row_found:
        problems.append(missing_row)
    if tier == 3 and not row_found:
        problems.append(
            "privacy.tier: 3 compounds that: Tier 3 routing is a property of the SESSION, "
            "not a filter applied afterwards — raw request and response bodies hit "
            "<state>/logs/llm_request.*.jsonl before any post-hoc classification could "
            "help. Add the row first, then connect."
        )
    if row_claimed is True and not row_found:
        problems.append(
            "privacy.row_added: true asserts a row that is not there — the manifest's own "
            "claim is false"
        )

    if problems:
        bad("privacy gate", *problems)
    else:
        ok("privacy tier %s, docs/privacy.md row present (%s)" % (tier, marker))
    if row_claimed is False and row_found:
        note("privacy.row_added is false but the row exists (%s) — flip it to true" % marker)

# ---- 5. the vetting bar -----------------------------------------------------
vetting = doc.get("vetting")
if not isinstance(vetting, dict):
    bad("vetting block is missing (docs/providers.md's bar, as data)")
else:
    problems = []
    for bar in VETTING_BARS:
        entry = vetting.get(bar)
        if not isinstance(entry, dict):
            problems.append("vetting.%s is missing" % bar)
            continue
        if not str(entry.get("verdict", "") or "").strip():
            problems.append("vetting.%s.verdict is empty" % bar)
        if not str(entry.get("evidence", "") or "").strip():
            problems.append("vetting.%s has no evidence — a verdict with no evidence is a guess" % bar)
    if problems:
        bad("vetting bar", *problems)
    else:
        ok("vetting: all %d bars carry a verdict and evidence" % len(VETTING_BARS))
        not_pass = [b for b in VETTING_BARS if str(vetting[b].get("verdict")).lower() != "pass"]
        if not_pass:
            note("vetting verdicts that are not `pass`: %s — the bar is not self-certifying, a human signs these off" % ", ".join(not_pass))

# ---- 6. secrets, by name only ----------------------------------------------
secrets = doc.get("secrets") or []
secret_keys = []
if not isinstance(secrets, list):
    bad("secrets must be a list (use [] for a connector that needs no credential)")
    secrets = []
else:
    problems = []
    for i, entry in enumerate(secrets):
        if not isinstance(entry, dict):
            problems.append("secrets[%d] is not a mapping" % i)
            continue
        key = entry.get("key")
        if not isinstance(key, str) or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key or ""):
            problems.append("secrets[%d].key %r is not an UPPER_SNAKE env var name" % (i, key))
        else:
            secret_keys.append(key)
        if not str(entry.get("prompt", "") or "").strip():
            problems.append("secrets[%d] (%s) has no prompt — the phone UI has nothing to ask" % (i, key))
        if not isinstance(entry.get("secret"), bool):
            problems.append("secrets[%d] (%s) needs secret: true|false" % (i, key))
        if "value" in entry:
            problems.append("secrets[%d] (%s) carries a `value` — manifests name credentials, never hold them" % (i, key))
    if problems:
        bad("secrets block", *problems)
    elif secret_keys:
        ok("secrets declared by name only: %s" % ", ".join(secret_keys))
    else:
        ok("no credentials required")

# ---- 7. acp_extension (one, or a list of them) ------------------------------
try:
    live = bool(KEYFILE) and os.path.exists(KEYFILE)
    keys_map = json.load(open(KEYFILE)) if live else FALLBACK_KEYS
    keys_src = "live schema" if live else "built-in v1.46.0 key list"
except Exception:                                           # noqa: BLE001
    keys_map, keys_src = FALLBACK_KEYS, "built-in v1.46.0 key list"

ext_raw = doc.get("acp_extension")
if isinstance(ext_raw, dict):
    exts = [ext_raw]
elif isinstance(ext_raw, list) and ext_raw and all(isinstance(e, dict) for e in ext_raw):
    # A connector may need more than one extension (mail + calendar are two
    # different servers behind one credential story). Each is validated whole.
    exts = ext_raw
else:
    exts = []
    bad("acp_extension is missing or malformed — there is no payload to send to config/extensions/add")

all_env_keys = []
all_stdio_env_keys = []
all_subst_refs = set()
all_allowed = []

for idx, ext in enumerate(exts):
    tag = "acp_extension" if len(exts) == 1 else "acp_extension[%d]" % idx
    server = ext.get("server")
    srv_type = server.get("type") if isinstance(server, dict) else None
    label = "%s (%s)" % (tag, server.get("name") if isinstance(server, dict) else "unnamed")

    problems = []
    if ext.get("type") != "mcp":
        problems.append("type is %r; connectors are always `mcp`" % ext.get("type"))
    timeout = ext.get("timeout")
    if isinstance(timeout, bool) or not isinstance(timeout, int) or timeout <= 0:
        problems.append("timeout must be a positive integer (seconds)")
    if not str(ext.get("description", "") or "").strip():
        problems.append("description is empty — it is what the agent reads to decide whether to reach for this")
    unknown = [k for k in ext if k not in keys_map["mcp"]]
    if unknown:
        problems.append(
            "unknown key(s) %s — goose sets no deny_unknown_fields, so it would accept "
            "and discard them (%s)" % (", ".join(sorted(unknown)), keys_src)
        )

    if not isinstance(server, dict):
        problems.append("server is missing")
    elif srv_type == "sse":
        problems.append(
            "server.type: sse — goose's ACP layer rejects it outright (\"SSE is "
            "unsupported, migrate to streamable_http\") and a live initialize at 1.46.0 "
            "reports mcpCapabilities.sse: false. Use http."
        )
    elif srv_type not in ("stdio", "http"):
        problems.append("server.type %r is not stdio or http" % (srv_type,))
    else:
        allowed_keys = set(keys_map["stdio" if srv_type == "stdio" else "http"]) | {"type"}
        unknown_srv = [k for k in server if k not in allowed_keys]
        if not str(server.get("name", "") or "").strip():
            problems.append("server.name is missing")
        if srv_type == "stdio":
            if not str(server.get("command", "") or "").strip():
                problems.append("server.command is missing")
            args = server.get("args")
            if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
                problems.append("server.args must be a list of strings (use [] for none)")
            if "env" not in server:
                problems.append("server.env is required by the ACP schema for stdio — write env: []")
            elif server.get("env"):
                problems.append(
                    "server.env is non-empty. Inline env values cross the ACP frame in "
                    "PLAINTEXT and goose promotes them into secret storage. Keep env: [] "
                    "and declare envKeys instead."
                )
        else:
            if "env" in server:
                problems.append(
                    "server.env on an http server: `env` is a stdio-only field, so goose "
                    "drops it. If a credential is needed, it belongs in a header."
                )
                if "env" in unknown_srv:
                    unknown_srv.remove("env")
            if not str(server.get("url", "") or "").strip():
                problems.append("server.url is missing (the ACP wire field for a remote server)")
            headers = server.get("headers")
            if "headers" not in server:
                problems.append("server.headers is required by the ACP schema for http — write headers: []")
            elif isinstance(headers, dict):
                problems.append(
                    "server.headers is a mapping. The ACP schema wants a LIST of "
                    "{name, value} (HttpHeader), and unlike the allowlist this one does "
                    "not fail silently — the payload is rejected. Rewrite as: "
                    "headers: [{name: Authorization, value: \"Bearer ${VAR}\"}]"
                )
            elif not isinstance(headers, list) or not all(
                isinstance(h, dict) and "name" in h and "value" in h for h in headers
            ):
                problems.append("server.headers must be a list of {name, value}")
        if unknown_srv:
            problems.append("unknown server key(s): %s (%s)" % (", ".join(sorted(unknown_srv)), keys_src))

    if problems:
        bad("%s shape" % label, *problems)
    else:
        ok("%s: type mcp over %s, no unknown keys (%s)" % (label, srv_type, keys_src))

    # ---- 8. the allowlist itself, per extension -----------------------------
    tools = ext.get("available_tools")
    if tools is None:
        bad(
            "%s has no available_tools" % label,
            "Absent becomes None becomes vec![], and an empty allowlist means EVERY TOOL",
            "IS ALLOWED. Enumerate the tools this connector may call — the exact names,",
            "observed with --smoke, never typed from memory.",
        )
    elif not isinstance(tools, list) or not tools:
        bad(
            "%s has an empty available_tools" % label,
            "An empty allowlist means EVERY TOOL IS ALLOWED, which is the opposite of",
            "what an empty list looks like it means.",
        )
    elif not all(isinstance(t, str) and t.strip() for t in tools):
        bad("%s: available_tools contains a non-string or empty entry" % label)
    elif len(set(tools)) != len(tools):
        bad("%s: available_tools has duplicate entries: %s"
            % (label, ", ".join(sorted({t for t in tools if tools.count(t) > 1}))))
    else:
        all_allowed += tools
        ok("%s: available_tools present, non-empty, snake_case — %d tool(s) allowed" % (label, len(tools)))

    # ---- 9. credential wiring, per extension --------------------------------
    env_keys = ext.get("envKeys") or []
    if not isinstance(env_keys, list) or not all(isinstance(k, str) for k in env_keys):
        bad("%s: envKeys must be a list of env var NAMES" % label)
        env_keys = []
    all_env_keys += env_keys
    if srv_type == "stdio":
        all_stdio_env_keys += env_keys

    refs = set()
    if isinstance(server, dict):
        for field in ("url", "socket"):
            refs |= set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", str(server.get(field, "") or "")))
        headers = server.get("headers")
        if isinstance(headers, list):
            for h in headers:
                if isinstance(h, dict):
                    refs |= set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", str(h.get("value", "") or "")))
        elif isinstance(headers, dict):
            for v in headers.values():
                refs |= set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", str(v or "")))
    all_subst_refs |= refs

    problems = []
    undeclared = sorted(r for r in refs if r not in secret_keys and r not in env_keys)
    if undeclared:
        problems.append(
            "${%s} referenced but never declared in secrets or envKeys. Unlike a missing "
            "stdio env key (a hard extension-startup failure), a missing ${VAR} in a "
            "header is left LITERAL — the connector starts and fails open to a 401."
            % "}, ${".join(undeclared)
        )
    if srv_type == "stdio" and isinstance(server, dict):
        literal = [p for p, v in walk(server) if isinstance(v, str) and re.search(r"\$\{[A-Za-z_]", v)]
        if literal:
            problems.append(
                "${VAR} used at %s. Substitution applies ONLY to a remote server's "
                "url/headers/socket, never to stdio args or env — it is passed through "
                "literally." % ", ".join(literal)
            )
    if problems:
        bad("%s credential wiring" % label, *problems)

uncovered = [k for k in secret_keys if k not in all_env_keys and k not in all_subst_refs]
if exts:
    # A secret no extension consumes is usually a wiring bug, but not always:
    # an out-of-band credential (a vendor bridge's own password, typed into that
    # bridge's UI) legitimately reaches no MCP server. The distinction the
    # manifest has to make is explaining itself — in a blocker, a note, or the
    # prompt — so an unexplained orphan still fails.
    prose = " ".join(
        str(v) for p, v in walk(doc)
        if isinstance(v, str) and (p.startswith(("blockers", "notes", "auth_notes")) or p.endswith(".prompt"))
    )
    unexplained = [k for k in uncovered if k not in prose]
    explained = [k for k in uncovered if k in prose]
    if unexplained:
        bad(
            "declared secret(s) reach no extension: %s" % ", ".join(unexplained),
            "They appear in no envKeys list and in no ${...} reference, so the servers",
            "start without them. For stdio that is a hard extension-startup failure; note",
            "also that a secret whose stored value is not a JSON string (a numeric app",
            "password, say) is skipped with \"Secret value is not a string\" and the server",
            "comes up WITHOUT its credential. If one is deliberately out-of-band, say so",
            "in blockers or notes and this check will accept it.",
        )
    if explained:
        note("secret(s) consumed by no extension but explained in the manifest: %s" % ", ".join(explained))
    if not unexplained:
        ok("credential wiring: %d envKey(s), %d ${...} reference(s), every declared secret covered"
           % (len(all_env_keys), len(all_subst_refs)))
    if all_stdio_env_keys:
        note("stdio env keys are the server's own names (%s) — the <PROVIDER>_* convention "
             "cannot be honoured here, so a second account of the same provider collides "
             "on one key"
             % ", ".join(sorted(set(all_stdio_env_keys))))

# ---- 10. no secret VALUES anywhere -----------------------------------------
# Structural, not textual: prose that *discusses* a key ("setting only
# MCP_EMAIL_SERVER_IMAP_VERIFY_SSL=false is not enough") is documentation, not a
# leak, and a grep cannot tell the difference. What counts is a mapping key
# named after a declared secret that carries a value, an EnvVariable pair, or an
# argv entry of the form KEY=value.
leaks = []
for path, value in walk(doc):
    leaf = path.rsplit(".", 1)[-1].split("[")[0]
    if leaf in secret_keys and str(value or "").strip():
        leaks.append("%s carries a value" % path)
    if isinstance(value, str):
        for key in secret_keys:
            if re.match(r"^%s=\S" % re.escape(key), value.strip()):
                leaks.append("%s is a %s=<value> assignment" % (path, key))
        if value.startswith(TOKEN_PREFIXES):
            leaks.append("%s looks like a live credential (known token prefix)" % path)
for ext in exts:
    server = ext.get("server") or {}
    for i, pair in enumerate(server.get("env") or []):
        if isinstance(pair, dict) and str(pair.get("value", "") or "").strip():
            leaks.append("server.env[%d] (%s) carries an inline value" % (i, pair.get("name")))
if leaks:
    bad(
        "a credential VALUE appears in the manifest",
        *(leaks + [
            "This file lives in a public repo. Rotate the credential, then store it with",
            "config/upsert (is_secret) so it lands in <config_dir>/secrets.yaml at 0600 on",
            "the encrypted volume — and reference it by NAME here. Never read it back:",
            "config/read returns the first min(len/2, 8) characters in clear.",
        ])
    )
else:
    ok("no credential values in the file (declared key names and known token prefixes both clean)")

# ---- 11. smoke_test & runbook ----------------------------------------------
smoke = doc.get("smoke_test")
if not isinstance(smoke, dict):
    bad("smoke_test is missing — an unproven allowlist is a list someone typed")
else:
    problems = []
    kind = smoke.get("kind")
    if kind not in ("tools_list", "goose_run"):
        problems.append("smoke_test.kind %r is not tools_list or goose_run" % (kind,))
    if not str(smoke.get("command", "") or "").strip():
        problems.append("smoke_test.command is missing")

    expect_n = smoke.get("expect_tools_exactly")
    expect_set = smoke.get("expect_tools_set")
    expect_absent = smoke.get("expect_tools_absent") or []
    if kind == "tools_list":
        has_n = isinstance(expect_n, int) and not isinstance(expect_n, bool) and expect_n > 0
        has_set = isinstance(expect_set, list) and expect_set and all(isinstance(t, str) for t in expect_set)
        if not has_n and not has_set:
            problems.append(
                "needs expect_tools_exactly (a positive count) and/or expect_tools_set (the "
                "exact names) — that assertion is what proves the allowlist bit"
            )
        if has_n and has_set and len(set(expect_set)) != expect_n:
            problems.append(
                "expect_tools_exactly (%d) != len(expect_tools_set) (%d)" % (expect_n, len(set(expect_set)))
            )
        if has_set and all_allowed and set(expect_set) != set(all_allowed):
            problems.append(
                "expect_tools_set does not match the union of available_tools; extra: %s; missing: %s"
                % (", ".join(sorted(set(expect_set) - set(all_allowed))) or "none",
                   ", ".join(sorted(set(all_allowed) - set(expect_set))) or "none")
            )
        if has_n and not has_set and all_allowed and expect_n != len(set(all_allowed)):
            note(
                "expect_tools_exactly is %d but the allowlist holds %d tool(s). --smoke "
                "compares against the allowlist (what the agent may call); the server's "
                "own total is reported separately." % (expect_n, len(set(all_allowed)))
            )
    if not isinstance(expect_absent, list) or not all(isinstance(t, str) for t in expect_absent):
        problems.append("expect_tools_absent must be a list of tool names")
    else:
        wrongly_present = [t for t in expect_absent if t in all_allowed]
        if wrongly_present:
            problems.append(
                "expect_tools_absent lists %s, but available_tools grants them"
                % ", ".join(wrongly_present)
            )
    unknown_smoke = sorted(set(smoke) - SMOKE_KEYS)
    if unknown_smoke:
        problems.append(
            "unknown smoke_test key(s): %s (known: %s). An assertion key nothing reads is "
            "the same trap as availableTools one level up: `expect_tools` instead of "
            "expect_tools_set, or `token_preflight`, sits in the file looking like a check "
            "and asserts NOTHING, forever. Fix the spelling, or move the prose into "
            "smoke_test.notes." % (", ".join(unknown_smoke), ", ".join(sorted(SMOKE_KEYS)))
        )
    if smoke.get("expect_roundtrip"):
        note("expect_roundtrip is asserted by --acp-roundtrip %s (config/extensions/add "
             "then config/extensions/list against a running goose serve) and by the connect "
             "workflow; --smoke never touches goose" % (mid or STEM))

    if problems:
        bad("smoke_test", *problems)
    else:
        ok("smoke_test: kind %s%s" % (kind, ", expects %s tool(s)" % expect_n if expect_n else ""))
    cmd = str(smoke.get("command", "") or "")
    if mid and "--smoke" in cmd and mid not in cmd:
        note("smoke_test.command does not mention this manifest's id")

runbook = doc.get("runbook")
if runbook:
    if os.path.exists(os.path.join(REPO_ROOT, str(runbook))):
        ok("runbook %s exists" % runbook)
    else:
        bad("runbook %s does not exist in the repo" % runbook)

blockers = doc.get("blockers")
if blockers:
    if isinstance(blockers, list):
        note("%d recorded blocker(s) — a connector that records its blockers is honest, not finished" % len(blockers))
    else:
        bad("blockers must be a list")
PYEOF

cat >"$SMOKE_PY" <<'PYEOF'
"""Smoke-test one connector: talk MCP to its real server(s) and count tools.

goose is NOT in the loop, so tools/list returns the server's FULL surface. That
is the point. It proves every name in available_tools actually exists — a typo
allowlists nothing, matches nothing, and is invisible everywhere else — and it
puts a number on what would go live if the allowlist were ever dropped.

Prints status codes, tool names and counts. Server stderr is redacted against
the values of the declared envKeys before any of it is echoed.
"""
import json
import os
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time

import yaml

MANIFEST = sys.argv[1]
DEADLINE_S = float(sys.argv[2]) if len(sys.argv) > 2 else 120.0
PROTOCOL_VERSION = "2025-06-18"

doc = yaml.safe_load(open(MANIFEST, encoding="utf-8"))
STEM = str(doc.get("id") or os.path.basename(MANIFEST))
ext_raw = doc.get("acp_extension") or {}
EXTS = ext_raw if isinstance(ext_raw, list) else [ext_raw]
SMOKE = doc.get("smoke_test") or {}
REDACT = []
INIT_PARAMS = {
    "protocolVersion": PROTOCOL_VERSION,
    "capabilities": {},
    "clientInfo": {"name": "check-connectors.sh", "version": "1"},
}


def remember(value):
    """Track a credential value so it can be scrubbed from server output. Short
    values are skipped on purpose: redacting a 4-character string would mangle
    this script's own prose without protecting anything worth protecting."""
    if value and len(value) >= 8:
        REDACT.append(value)


def redact(text):
    out = str(text)
    for value in REDACT:
        out = out.replace(value, "<redacted>")
    return out


def ok(msg):
    print("PASS  smoke %s: %s" % (STEM, redact(msg)))


def bad(msg, *cont):
    print("FAIL  smoke %s: %s" % (STEM, redact(msg)))
    for line in cont:
        print("      | %s" % redact(line))


def skipped(msg, *cont):
    print("SKIP  smoke %s: %s" % (STEM, redact(msg)))
    for line in cont:
        print("      | %s" % redact(line))


def info(line):
    print("      | %s" % redact(line))


def rpc_frame(mid, method, params=None):
    frame = {"jsonrpc": "2.0", "method": method}
    if mid is not None:
        frame["id"] = mid
    frame["params"] = params if params is not None else {}
    return json.dumps(frame) + "\n"


def env_names(ext):
    """Every env var this extension needs: declared envKeys plus anything a
    ${VAR} in the remote url/headers would substitute."""
    server = ext.get("server") or {}
    names = set(ext.get("envKeys") or [])
    texts = [str(server.get("url") or ""), str(server.get("socket") or "")]
    headers = server.get("headers")
    if isinstance(headers, list):
        texts += [str(h.get("value", "")) for h in headers if isinstance(h, dict)]
    elif isinstance(headers, dict):
        texts += [str(v) for v in headers.values()]
    for text in texts:
        names |= set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", text))
    return sorted(names)


def read_message(q, want_id, deadline):
    """Pull line-delimited JSON-RPC until the response with want_id arrives."""
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("timed out waiting for a response to request id %s" % want_id)
        try:
            line = q.get(timeout=remaining)
        except queue.Empty:
            raise TimeoutError("timed out waiting for a response to request id %s" % want_id)
        if line is None:
            raise EOFError("server closed stdout before answering id %s" % want_id)
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue                       # servers that print banners to stdout
        if isinstance(msg, dict) and msg.get("id") == want_id:
            return msg


def list_tools_stdio(ext, label):
    """-> (tool names, negotiated protocol) or None on skip/failure."""
    server = ext["server"]
    needed = env_names(ext)
    missing = [k for k in needed if not os.environ.get(k)]
    if missing:
        skipped(
            "%s — credential(s) not in this shell: %s" % (label, ", ".join(missing)),
            "Names only; never paste the values here. Mac: scripts/mac/keychain-secrets.sh",
            "then a NEW terminal. Brain: set -a; . /data/secrets.env; set +a",
        )
        return None
    for k in needed:
        remember(os.environ.get(k, ""))

    cmd = [str(server.get("command"))] + [str(a) for a in (server.get("args") or [])]
    err_file = tempfile.TemporaryFile()
    try:
        # goose does no env_clear anywhere: every stdio MCP child inherits goose
        # serve's full environment. Passing os.environ through reproduces that.
        proc = subprocess.Popen(
            cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err_file,
            text=True, bufsize=1, env=dict(os.environ),
        )
    except OSError as exc:
        bad(
            "%s — cannot launch %s: %s" % (label, cmd[0], type(exc).__name__),
            "stdio connectors need their launcher on PATH (uvx from uv, npx from node).",
        )
        err_file.close()
        return None

    q = queue.Queue()

    def pump():
        try:
            for line in proc.stdout:
                q.put(line)
        finally:
            q.put(None)

    threading.Thread(target=pump, daemon=True).start()
    deadline = time.monotonic() + DEADLINE_S
    try:
        proc.stdin.write(rpc_frame(1, "initialize", INIT_PARAMS))
        proc.stdin.flush()
        init = read_message(q, 1, deadline)
        if "error" in init:
            bad("%s — initialize returned JSON-RPC error code %s" % (label, init["error"].get("code")))
            return None
        result = init.get("result") or {}
        negotiated = result.get("protocolVersion", "?")
        srv_info = result.get("serverInfo") or {}
        if srv_info:
            info("%s — serverInfo: %s %s" % (label, srv_info.get("name", "?"), srv_info.get("version", "?")))

        proc.stdin.write(rpc_frame(None, "notifications/initialized"))
        proc.stdin.flush()

        names, cursor, rid = [], None, 2
        while True:
            proc.stdin.write(rpc_frame(rid, "tools/list", {"cursor": cursor} if cursor else {}))
            proc.stdin.flush()
            resp = read_message(q, rid, deadline)
            if "error" in resp:
                bad("%s — tools/list returned JSON-RPC error code %s" % (label, resp["error"].get("code")))
                return None
            page = resp.get("result") or {}
            names += [t.get("name") for t in page.get("tools", []) if isinstance(t, dict)]
            cursor = page.get("nextCursor")
            rid += 1
            if not cursor:
                break
        return names, negotiated
    except (TimeoutError, EOFError, BrokenPipeError, OSError) as exc:
        err_file.seek(0)
        tail = err_file.read().decode("utf-8", "replace").splitlines()[-5:]
        bad(
            "%s — MCP handshake failed: %s" % (label, exc),
            *(["server stderr (redacted):"] + tail if tail else ["the server produced no stderr"])
        )
        return None
    finally:
        try:
            proc.stdin.close()
        except Exception:                                   # noqa: BLE001
            pass
        try:
            proc.terminate()
            proc.wait(timeout=10)
        except Exception:                                   # noqa: BLE001
            proc.kill()
        err_file.close()


def list_tools_http(ext, label):
    import urllib.error
    import urllib.request

    server = ext["server"]
    needed = env_names(ext)
    missing = [k for k in needed if not os.environ.get(k)]
    if missing:
        skipped(
            "%s — credential(s) not in this shell: %s" % (label, ", ".join(missing)),
            "Names only. goose leaves a missing ${VAR} in a header LITERAL and fails open",
            "to a 401, so guessing here would prove the wrong thing.",
        )
        return None
    for k in needed:
        remember(os.environ.get(k, ""))

    def sub(text):
        return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}",
                      lambda m: os.environ.get(m.group(1), m.group(0)), str(text))

    url = sub(server.get("url") or "")
    hdrs = {}
    headers = server.get("headers")
    if isinstance(headers, list):
        for h in headers:
            if isinstance(h, dict):
                hdrs[sub(h.get("name", ""))] = sub(h.get("value", ""))
    elif isinstance(headers, dict):
        # Not the ACP shape (the validator fails it), but smoke-testable anyway.
        for k, v in headers.items():
            hdrs[sub(k)] = sub(v)
    hdrs.setdefault("Content-Type", "application/json")
    hdrs.setdefault("Accept", "application/json, text/event-stream")

    def post(body, extra=None):
        merged = dict(hdrs)
        merged.update(extra or {})
        req = urllib.request.Request(url, data=body.encode(), headers=merged, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=DEADLINE_S) as resp:
                return resp.status, resp.read().decode("utf-8", "replace"), dict(resp.headers)
        except urllib.error.HTTPError as exc:
            return exc.code, "", dict(exc.headers or {})
        except Exception as exc:                            # noqa: BLE001
            return 0, type(exc).__name__, {}

    def payload(text):
        """Streamable HTTP answers with a JSON body or an SSE stream, and the SSE
        form may lead with `event:` before `data:`. Take whichever arrived."""
        text = (text or "").strip()
        if not text:
            return {}
        if text.startswith("{"):
            try:
                return json.loads(text)
            except ValueError:
                pass
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("data:"):
                try:
                    return json.loads(line[5:].strip())
                except ValueError:
                    continue
        return {}

    status, text, resp_headers = post(rpc_frame(1, "initialize", INIT_PARAMS))
    if status != 200:
        bad(
            "%s — initialize -> HTTP %s" % (label, status),
            "401/403 means the token is wrong or a ${VAR} never substituted; 0 means the",
            "request never completed (DNS, TLS, or no egress).",
        )
        return None
    init = payload(text)
    if "error" in init:
        bad("%s — initialize -> HTTP 200 but JSON-RPC error code %s" % (label, init["error"].get("code")))
        return None
    session = resp_headers.get("mcp-session-id") or resp_headers.get("Mcp-Session-Id")
    sess_hdr = {"Mcp-Session-Id": session} if session else {}
    negotiated = (init.get("result") or {}).get("protocolVersion", "?")

    post(rpc_frame(None, "notifications/initialized"), sess_hdr)

    names, cursor, rid = [], None, 2
    while True:
        status, text, _ = post(rpc_frame(rid, "tools/list", {"cursor": cursor} if cursor else {}), sess_hdr)
        if status != 200:
            bad("%s — tools/list -> HTTP %s" % (label, status))
            return None
        page = payload(text).get("result") or {}
        names += [t.get("name") for t in page.get("tools", []) if isinstance(t, dict)]
        cursor = page.get("nextCursor")
        rid += 1
        if not cursor:
            break
    return names, negotiated


# ---- run every extension ----------------------------------------------------
if SMOKE.get("kind") == "goose_run":
    skipped(
        "smoke_test.kind: goose_run",
        "This script will not exec a command string out of a manifest. Run the",
        "manifest's own smoke_test.command, or scripts/verify/check-mcp.sh, which",
        "drives goose end to end.",
    )
    sys.exit(0)

effective = []          # allowlisted tools the servers actually publish
complete = bool(EXTS)   # every extension answered, so the aggregate means something

for idx, ext in enumerate(EXTS):
    server = ext.get("server") or {}
    label = str(server.get("name") or "extension[%d]" % idx)
    allowlist = list(ext.get("available_tools") or [])
    srv_type = server.get("type")

    if srv_type == "stdio":
        outcome = list_tools_stdio(ext, label)
    elif srv_type == "http":
        outcome = list_tools_http(ext, label)
    else:
        skipped("%s — server.type %r cannot be smoke-tested over MCP" % (label, srv_type))
        outcome = None

    if outcome is None:
        complete = False
        continue

    names, negotiated = outcome
    names = sorted(set(n for n in names if n))
    ok("%s — initialize OK (protocol %s), tools/list returned %d tool(s)" % (label, negotiated, len(names)))

    present = [t for t in allowlist if t in names]
    missing = [t for t in allowlist if t not in names]
    effective += present
    if missing:
        bad(
            "%s — %d allowlisted tool(s) do not exist on the server: %s"
            % (label, len(missing), ", ".join(missing)),
            "goose happily allows a name that matches nothing, so a typo here reads as a",
            "working allowlist forever while quietly granting less (or, if it were the",
            "only entry, nothing at all).",
            "server publishes: %s" % ", ".join(names),
        )
    else:
        ok("%s — every allowlisted tool exists on the server (%d of %d published)"
           % (label, len(allowlist), len(names)))

    outside = [t for t in names if t not in allowlist]
    info("%s — blast radius: %d of %d published tool(s) sit OUTSIDE the allowlist; that is"
         % (label, len(outside), len(names)))
    info("%s   exactly what goes live the day available_tools is spelled camelCase." % (" " * len(label)))
    for t in (doc.get("smoke_test") or {}).get("expect_tools_absent") or []:
        if t in names and t not in allowlist:
            info("%s — withheld as intended: %s exists on the server, allowlist excludes it" % (label, t))
        elif t not in names:
            info("%s — expect_tools_absent lists %s, which this server does not publish at all" % (label, t))

# ---- the manifest's own assertion ------------------------------------------
expect_n = SMOKE.get("expect_tools_exactly")
expect_set = SMOKE.get("expect_tools_set")
effective = sorted(set(effective))

if not complete:
    skipped("aggregate assertion skipped — not every extension reported its tools")
else:
    if isinstance(expect_set, list) and expect_set:
        if sorted(set(expect_set)) == effective:
            ok("the agent can call exactly the %d tool(s) in expect_tools_set" % len(effective))
        else:
            bad(
                "effective tool set != smoke_test.expect_tools_set",
                "expected but not reachable: %s"
                % (", ".join(sorted(set(expect_set) - set(effective))) or "none"),
                "reachable but unexpected: %s"
                % (", ".join(sorted(set(effective) - set(expect_set))) or "none"),
            )
    if isinstance(expect_n, int) and not isinstance(expect_n, bool):
        if len(effective) == expect_n:
            ok("effective tool count is %d, exactly what the manifest claims" % expect_n)
        else:
            bad(
                "effective tool count is %d, manifest expects %d" % (len(effective), expect_n),
                "reachable: %s" % (", ".join(effective) or "none"),
                "This counts allowlisted tools the server actually publishes — the number",
                "of tools the agent can call. Each server's own total is reported above.",
            )
PYEOF

cat >"$ROUNDTRIP_PY" <<'PYEOF'
"""Prove goose KEPT the allowlist: config/extensions/add, then extensions/list.

This is the second of the two mandatory mitigations in
config/connectors/README.md, and the only one that can catch the failure in
production. Manifest validation proves the FILE says `available_tools`; nothing
about a file proves goose stored it. A camelCase spelling — or any future
rename, or a payload goose accepts and discards, since there is no
deny_unknown_fields — leaves an extension configured with an EMPTY allowlist,
and an empty allowlist means every tool is allowed. The only way to see that is
to read it back from the agent that persisted it.

What it does, per extension in the manifest:

  * if the extension is already configured, assert the LIVE entry's allowlist
    (nothing is added, nothing is overwritten — the live config is the thing
    that matters anyway);
  * otherwise add it with `enabled: false`, list, assert, and remove it again.

`enabled: false` matters: this mode must never start an MCP server. It touches
goose's own config only, needs none of the connector's credentials, and leaves
the config exactly as it found it.

Transport: POST /acp for requests; goose assigns a connection id in the
`acp-connection-id` response header on `initialize` and every later request
carries it back as `Acp-Connection-Id`. Replies to those later calls may arrive
on the separate `GET /acp` SSE channel rather than in the POST body, so both are
read.

Never prints a secret. GOOSE_SERVER__SECRET_KEY is sent as a header and never
echoed; manifests carry credential NAMES only and this mode neither reads nor
writes any credential.
"""
import json
import os
import queue
import re
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request

import yaml

MANIFEST, URL = sys.argv[1:3]
DEADLINE_S = float(sys.argv[3]) if len(sys.argv) > 3 else 30.0
SECRET = os.environ.get("GOOSE_SERVER__SECRET_KEY", "")
PROTOCOL_VERSION = 1

doc = yaml.safe_load(open(MANIFEST, encoding="utf-8"))
STEM = str(doc.get("id") or os.path.basename(MANIFEST))
ext_raw = doc.get("acp_extension") or {}
EXTS = [e for e in (ext_raw if isinstance(ext_raw, list) else [ext_raw]) if isinstance(e, dict)]


def ok(msg):
    print("PASS  roundtrip %s: %s" % (STEM, msg))


def bad(msg, *cont):
    print("FAIL  roundtrip %s: %s" % (STEM, msg))
    for line in cont:
        print("      | %s" % line)


def skipped(msg, *cont):
    print("SKIP  roundtrip %s: %s" % (STEM, msg))
    for line in cont:
        print("      | %s" % line)


def note(msg):
    print("NOTE  roundtrip %s: %s" % (STEM, msg))


def info(line):
    print("      | %s" % line)


VERIFIED_CTX = ssl.create_default_context()
UNVERIFIED_CTX = ssl._create_unverified_context()      # noqa: S323
STATE = {"ctx": VERIFIED_CTX, "downgraded": False, "conn": ""}


def headers(extra=None):
    h = {"Content-Type": "application/json"}
    if SECRET:
        h["X-Secret-Key"] = SECRET
    if STATE["conn"]:
        h["Acp-Connection-Id"] = STATE["conn"]
    h.update(extra or {})
    return h


def open_url(req):
    """urlopen, downgrading TLS verification once. goose serve's certificate is
    self-signed by design — real clients pin its fingerprint instead — so a
    verified handshake fails on a correctly configured brain. The downgrade is
    announced, and this probe is loopback/tailnet only."""
    try:
        return urllib.request.urlopen(req, timeout=DEADLINE_S, context=STATE["ctx"])
    except urllib.error.URLError as exc:
        if isinstance(getattr(exc, "reason", None), ssl.SSLError) and STATE["ctx"] is VERIFIED_CTX:
            STATE["ctx"] = UNVERIFIED_CTX
            STATE["downgraded"] = True
            return urllib.request.urlopen(req, timeout=DEADLINE_S, context=UNVERIFIED_CTX)
        raise


def rpc(rid, method, params=None):
    frame = {"jsonrpc": "2.0", "method": method, "params": params or {}}
    if rid is not None:
        frame["id"] = rid
    return json.dumps(frame).encode()


def post(rid, method, params=None, extra=None):
    """-> (status, parsed body or None, response headers). Raises on transport."""
    req = urllib.request.Request(URL, data=rpc(rid, method, params),
                                 headers=headers(extra), method="POST")
    try:
        with open_url(req) as resp:
            return resp.status, parse_body(resp.read().decode("utf-8", "replace")), dict(resp.headers)
    except urllib.error.HTTPError as exc:
        return exc.code, None, dict(exc.headers or {})


def parse_body(text):
    text = (text or "").strip()
    if not text:
        return None
    if text.startswith("{"):
        try:
            return json.loads(text)
        except ValueError:
            return None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("data:"):
            try:
                return json.loads(line[5:].strip())
            except ValueError:
                continue
    return None


REPLIES = queue.Queue()


def sse_pump():
    req = urllib.request.Request(
        URL, headers=headers({"Accept": "text/event-stream"}), method="GET")
    try:
        with open_url(req) as resp:
            for raw in resp:
                line = raw.decode("utf-8", "replace").strip()
                if line.startswith("data:"):
                    msg = parse_body(line)
                    if isinstance(msg, dict):
                        REPLIES.put(msg)
    except Exception:                                       # noqa: BLE001
        pass
    finally:
        REPLIES.put(None)


RID = [1]


def call(method, params=None):
    """One JSON-RPC request. -> (result, error_text). Exactly one is None."""
    RID[0] += 1
    rid = RID[0]
    try:
        status, body, _ = post(rid, method, params)
    except Exception as exc:                                # noqa: BLE001
        return None, "transport error: %s" % type(exc).__name__
    if status not in (200, 202):
        return None, "HTTP %s" % status
    if isinstance(body, dict) and body.get("id") == rid:
        msg = body
    else:
        msg = None
        deadline = time.monotonic() + DEADLINE_S
        while msg is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None, "timed out waiting for the reply to %s" % method
            try:
                candidate = REPLIES.get(timeout=remaining)
            except queue.Empty:
                return None, "timed out waiting for the reply to %s" % method
            if candidate is None:
                return None, "the SSE reply channel closed before %s answered" % method
            if candidate.get("id") == rid:
                msg = candidate
    if "error" in msg:
        err = msg["error"] or {}
        return None, "JSON-RPC error %s: %s" % (err.get("code"), err.get("message"))
    return msg.get("result") or {}, None


def norm(value):
    return re.sub(r"[^a-z0-9]", "", str(value or "").lower())


def allowlist_of(extension):
    """The stored allowlist, and how it was spelled. goose writes
    `available_tools` at 1.46.0; anything else coming back is itself the story."""
    if not isinstance(extension, dict):
        return None, None
    for spelling in ("available_tools", "availableTools"):
        if spelling in extension:
            return extension.get(spelling), spelling
    return None, None


def find_entry(entries, want_name):
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        ext = entry.get("extension") or {}
        server = ext.get("server") or {}
        candidates = [server.get("name"), entry.get("configKey"), ext.get("name")]
        if any(norm(c) == norm(want_name) for c in candidates if c):
            return entry
    return None


def list_extensions():
    result, err = call("_goose/unstable/config/extensions/list")
    if err:
        return None, err
    entries = result.get("extensions")
    if not isinstance(entries, list):
        return None, "config/extensions/list returned no `extensions` array"
    for warning in result.get("warnings") or []:
        note("goose reports a config warning: %s" % warning)
    return entries, None


# ---- preflight --------------------------------------------------------------
if not EXTS:
    skipped("the manifest has no acp_extension to send")
    sys.exit(0)
if not SECRET:
    skipped(
        "GOOSE_SERVER__SECRET_KEY is not in this shell — nothing to authenticate with",
        "Name only, never the value. Mac: scripts/mac/keychain-secrets.sh, then a NEW",
        "terminal. Brain: set -a; . /data/secrets.env; set +a",
        "(`goose serve --dangerously-unauthenticated` also works, and is why this is a",
        "SKIP rather than a FAIL.)",
    )
    sys.exit(0)

try:
    status, body, resp_headers = post(1, "initialize", {
        "protocolVersion": PROTOCOL_VERSION,
        "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}},
    })
except Exception as exc:                                    # noqa: BLE001
    skipped(
        "no goose serve answering at %s (%s)" % (URL, type(exc).__name__),
        "Start one, or point --acp-url at the brain: https://<tailscale-ip>:3284/acp.",
        "This mode asserts nothing when there is no agent to assert against.",
    )
    sys.exit(0)

if status in (401, 403):
    skipped("goose serve answered HTTP %s at %s — the secret key is wrong for this server" % (status, URL))
    sys.exit(0)
if status not in (200, 202) or not isinstance(body, dict) or "error" in (body or {}):
    skipped("initialize -> HTTP %s at %s, no usable ACP session" % (status, URL))
    sys.exit(0)

STATE["conn"] = resp_headers.get("acp-connection-id") or resp_headers.get("Acp-Connection-Id") or ""
if STATE["downgraded"]:
    note("TLS verification was skipped for this probe: goose serve's certificate is "
         "self-signed by design and real clients pin its fingerprint instead")
if STATE["conn"]:
    threading.Thread(target=sse_pump, daemon=True).start()
    ok("initialize OK at %s (connection established, ACP protocol %s)"
       % (URL, (body.get("result") or {}).get("protocolVersion", "?")))
else:
    note("no acp-connection-id header on initialize — replies are being read from the "
         "POST bodies only; if calls below time out, that header is the reason")

baseline, err = list_extensions()
if baseline is None:
    bad("config/extensions/list failed before anything was changed: %s" % err,
        "Nothing was added, so nothing needs cleaning up.")
    sys.exit(0)

# ---- the round trip ---------------------------------------------------------
added = []
failures = 0
try:
    for idx, ext in enumerate(EXTS):
        server = ext.get("server") or {}
        name = str(server.get("name") or "extension[%d]" % idx)
        sent = ext.get("available_tools")
        if not isinstance(sent, list) or not sent:
            bad("%s: the manifest itself has no non-empty available_tools — fix that first" % name)
            failures += 1
            continue

        existing = find_entry(baseline, name)
        if existing is not None:
            stored, spelling = allowlist_of(existing.get("extension") or {})
            source = "already configured on this goose (not re-added, so nothing was clobbered)"
        else:
            _, err = call("_goose/unstable/config/extensions/add",
                          {"extension": ext, "enabled": False})
            if err:
                bad("%s: config/extensions/add failed: %s" % (name, err),
                    "A rejected payload is the loud failure mode. The silent one — a key",
                    "goose accepts and discards — is what the read-back below exists for.")
                failures += 1
                continue
            added.append(name)
            entries, err = list_extensions()
            if entries is None:
                bad("%s: config/extensions/list failed right after add: %s" % (name, err))
                failures += 1
                continue
            entry = find_entry(entries, name)
            if entry is None:
                bad("%s: added, but config/extensions/list does not carry it back" % name,
                    "goose accepted the payload and persisted something this script cannot",
                    "find by server name or configKey. Read config.yaml before trusting it.")
                failures += 1
                continue
            stored, spelling = allowlist_of(entry.get("extension") or {})
            source = "sent with config/extensions/add, read back with config/extensions/list"

        if stored is None:
            bad(
                "%s: the stored extension has NO allowlist field at all (%s)" % (name, source),
                "This is the failure the whole feature exists to prevent: available_tools",
                "absent becomes vec![], and an empty allowlist means EVERY TOOL IS ALLOWED.",
                "Check the spelling in the manifest (snake_case `available_tools`), and",
                "whether the running goose is the pinned version.",
            )
            failures += 1
            continue
        if spelling != "available_tools":
            note("%s: goose returned the allowlist as `%s` — the pin may have moved; "
                 "re-verify config/connectors/README.md before trusting anything here"
                 % (name, spelling))
        if not isinstance(stored, list) or not stored:
            bad(
                "%s: the stored allowlist is EMPTY (%s)" % (name, source),
                "Empty means every tool is allowed — the opposite of what it looks like.",
                "Disable or remove this extension before using it: goose is configured to",
                "let the agent call the server's entire surface.",
            )
            failures += 1
            continue
        if set(stored) != set(sent):
            bad(
                "%s: the stored allowlist is not what the manifest sent (%s)" % (name, source),
                "sent but not stored: %s" % (", ".join(sorted(set(sent) - set(stored))) or "none"),
                "stored but not sent: %s" % (", ".join(sorted(set(stored) - set(sent))) or "none"),
                "Either goose dropped part of the payload, or the live config was narrowed",
                "(or widened) by hand and the manifest is now fiction. Reconcile before use.",
            )
            failures += 1
            continue
        ok("%s: allowlist survived the round trip — %d tool(s), set-equal to the manifest (%s)"
           % (name, len(stored), source))
finally:
    for name in added:
        entries, _ = list_extensions()
        entry = find_entry(entries or [], name)
        key = (entry or {}).get("configKey")
        if not key:
            note("could not find a configKey to remove the extension this check added (%s) "
                 "— remove it by hand from goose's config.yaml" % name)
            continue
        _, err = call("_goose/unstable/config/extensions/remove", {"configKey": key})
        if err:
            note("cleanup: config/extensions/remove(%s) failed: %s — remove it by hand" % (key, err))
        else:
            info("cleanup: removed the extension this check added (%s)" % key)

if failures == 0:
    ok("config/extensions/add + config/extensions/list agree for all %d extension(s) — "
       "the mitigation config/connectors/README.md calls mandatory is enforced here, "
       "not just described" % len(EXTS))
PYEOF

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
echo "== check-connectors: manifests in config/connectors/ =="
echo "pinned goose: $GOOSE_TAG  (source: $TAG_SOURCE)"
echo

# ---- 0. the goose actually installed here -----------------------------------
if [ -n "$GOOSE_BIN" ]; then
  LOCAL_VER="$("$GOOSE_BIN" --version 2>/dev/null | tr -d '[:space:]' || true)"
  if [ -z "$LOCAL_VER" ]; then
    skip "local goose at $GOOSE_BIN did not report a version"
  elif [ "$LOCAL_VER" = "$GOOSE_VER" ]; then
    pass "local goose is $LOCAL_VER, matching the pin"
  else
    fail "local goose is $LOCAL_VER but the pin is $GOOSE_VER"
    echo "      Every wire shape in these manifests was verified against the pinned"
    echo "      release, and the ACP method names have already broken twice in released"
    echo "      history. Mac: brew pin block-goose-cli (scripts/mac/bootstrap-mac.sh)."
    echo "      Brain: GOOSE_VERSION in infra/terraform/templates/cloud-init.yaml.tftpl."
  fi
else
  skip "goose CLI not installed here — manifest validation does not need it"
fi

# ---- 1. the ACP contract at the pinned tag ----------------------------------
echo
echo "--> ACP contract @ $GOOSE_TAG (aaif-goose/goose)"
META_JSON="$WORK/acp-meta.json"
SCHEMA_JSON="$WORK/acp-schema.json"

fetch_at_tag() {
  # $1 = path inside the goose repo, $2 = destination
  if command -v curl >/dev/null 2>&1 &&
     curl -fsSL --max-time 30 \
       "https://raw.githubusercontent.com/aaif-goose/goose/$GOOSE_TAG/$1" -o "$2" 2>/dev/null &&
     [ -s "$2" ]; then
    return 0
  fi
  if command -v gh >/dev/null 2>&1 &&
     gh api "repos/aaif-goose/goose/contents/$1?ref=$GOOSE_TAG" \
       -H "Accept: application/vnd.github.raw" >"$2" 2>/dev/null &&
     [ -s "$2" ]; then
    return 0
  fi
  return 1
}

if [ "$OFFLINE" = "yes" ]; then
  skip "ACP contract check (--offline)"
elif ! fetch_at_tag "crates/goose/acp-meta.json" "$META_JSON" ||
     ! fetch_at_tag "crates/goose/acp-schema.json" "$SCHEMA_JSON"; then
  skip "could not fetch acp-meta.json / acp-schema.json at $GOOSE_TAG (no network, no gh, or the tag does not exist)"
  echo "      Manifest key validation falls back to the v1.46.0 key list baked into"
  echo "      this script. Re-run with network before trusting a version bump."
else
  run_check "ACP contract @ $GOOSE_TAG" \
    "${PY[@]}" "$ACP_CHECK" "$META_JSON" "$SCHEMA_JSON" "$SCHEMA_KEYS" "$GOOSE_TAG"
fi

# ---- 2. every manifest -------------------------------------------------------
echo
echo "--> manifests"
if [ ! -d "$CONNECTOR_DIR" ]; then
  fail "$CONNECTOR_DIR does not exist"
else
  MANIFEST_COUNT=0
  for manifest in "$CONNECTOR_DIR"/*.yaml; do
    [ -e "$manifest" ] || continue
    MANIFEST_COUNT=$((MANIFEST_COUNT + 1))
    echo
    echo "  $(basename "$manifest")"
    run_check "$(basename "$manifest")" \
      "${PY[@]}" "$VALIDATOR" "$manifest" "$REPO_ROOT" "$GOOSE_VER" "$SCHEMA_KEYS" "$PRIVACY_DOC"
  done
  if [ "$MANIFEST_COUNT" -eq 0 ]; then
    skip "no manifests in config/connectors/ yet — the directory fills as services are connected"
    echo "      Run /connect-service (or recipes/connect-service.yaml); it writes one."
  fi
fi

# ---- 3. optional smoke test --------------------------------------------------
if [ -n "$SMOKE_ID" ]; then
  echo
  echo "--> smoke: $SMOKE_ID"
  SMOKE_FILE="$CONNECTOR_DIR/$SMOKE_ID.yaml"
  if [ ! -f "$SMOKE_FILE" ]; then
    fail "no manifest for id '$SMOKE_ID' at config/connectors/$SMOKE_ID.yaml"
    AVAILABLE="$(for f in "$CONNECTOR_DIR"/*.yaml; do [ -e "$f" ] || continue; b="${f##*/}"; printf '%s ' "${b%.yaml}"; done)"
    echo "      known ids: ${AVAILABLE:-(none)}"
  else
    echo "  Speaking MCP straight to the server — goose is not in the loop, so what comes"
    echo "  back is the server's FULL surface. The first run may download the server."
    SMOKE_PASS_BEFORE="$PASS_COUNT"
    run_check "smoke $SMOKE_ID" "${PY[@]}" "$SMOKE_PY" "$SMOKE_FILE" 120
    # A smoke that asserted NOTHING must not report success. The runner skips
    # gracefully when a credential is absent from the shell — right for a full
    # sweep, wrong here: `--smoke <id>` is an explicit request for this one
    # assertion, so "it never ran" and "it passed" have to differ in the exit
    # code or a CI job goes green having checked nothing.
    if [ "$PASS_COUNT" -eq "$SMOKE_PASS_BEFORE" ]; then
      fail "smoke $SMOKE_ID asserted nothing — it was requested explicitly, so a skip is a failure"
      echo "      Usually a credential missing from this shell (the SKIP lines above name it)."
      echo "      tools/list needs no REAL credential; a placeholder is enough to launch the"
      echo "      server, e.g.  USER_GOOGLE_EMAIL=smoke@example.com $0 --smoke $SMOKE_ID"
    fi
  fi
fi

# ---- 4. optional ACP round trip ---------------------------------------------
if [ -n "$ROUNDTRIP_ID" ]; then
  echo
  echo "--> acp round trip: $ROUNDTRIP_ID"
  RT_FILE="$CONNECTOR_DIR/$ROUNDTRIP_ID.yaml"
  if [ ! -f "$RT_FILE" ]; then
    fail "no manifest for id '$ROUNDTRIP_ID' at config/connectors/$ROUNDTRIP_ID.yaml"
    AVAILABLE="$(for f in "$CONNECTOR_DIR"/*.yaml; do [ -e "$f" ] || continue; b="${f##*/}"; printf '%s ' "${b%.yaml}"; done)"
    echo "      known ids: ${AVAILABLE:-(none)}"
  else
    echo "  Driving config/extensions/add then config/extensions/list against $ACP_URL."
    echo "  Nothing is enabled and no MCP server is started: this touches goose's own"
    echo "  config only, and removes whatever it added. It is the one check that can see"
    echo "  an allowlist goose silently dropped."
    RT_PASS_BEFORE="$PASS_COUNT"
    run_check "acp roundtrip $ROUNDTRIP_ID" "${PY[@]}" "$ROUNDTRIP_PY" "$RT_FILE" "$ACP_URL" 30
    # Same rule as --smoke: this was asked for explicitly, so "could not run" and
    # "passed" must not share an exit code. This is the ONLY check that observes
    # what goose actually stored, so a silent skip is the most expensive kind —
    # it is precisely the fail-open it exists to catch, reported as success.
    if [ "$PASS_COUNT" -eq "$RT_PASS_BEFORE" ]; then
      fail "acp roundtrip $ROUNDTRIP_ID asserted nothing — it was requested explicitly, so a skip is a failure"
      echo "      Common causes: no reachable \`goose serve\`, a missing GOOSE_SERVER__SECRET_KEY,"
      echo "      or an --acp-url without the /acp path (a bare host 404s on initialize)."
      echo "      Local check:  goose serve --host 127.0.0.1 --port 3288 --dangerously-unauthenticated"
      echo "                    $0 --acp-roundtrip $ROUNDTRIP_ID --acp-url http://127.0.0.1:3288/acp"
    fi
  fi
fi

finish --skips
