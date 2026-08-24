#!/usr/bin/env bash
# check-security.sh — verifies the brain's security posture.
#
# Default mode (run from ANY machine, no nmap needed): probes the brain's
# PUBLIC IP over the open internet on ports 22, 80, 443, 3284 using bash's
# /dev/tcp. The pass condition is that NOTHING answers — the brain is
# tailnet-only by design (docs/security.md), so an open public port means the
# Hetzner firewall or ufw regressed.
#
# --local mode (run ON the brain): /data mount, every goose config/data/state
# path resolving onto the encrypted volume, secrets.env permissions, ufw
# default-deny, a gitleaks scan of the repo clone, and the LIVE config.yaml's
# extension hardening (apps off, workspace-mcp tool allowlist) — which the
# no-clobber config install cannot deliver to a brain that already has one.
set -euo pipefail

TIMEOUT_S=5
PORTS="22 80 443 3284"

usage() {
  cat <<'EOF'
Usage:
  check-security.sh <public-ip>     # external port probe (run from anywhere)
  check-security.sh --local         # host checks (run on the brain)
  check-security.sh --help

Pass the brain's public IP as the argument (or set the BRAIN_PUBLIC_IP env
var). It comes from terraform:
  ./scripts/verify/check-security.sh "$(cd infra/terraform && terraform output -raw server_public_ip)"
Use the PUBLIC IP — probing the tailnet address (100.x.y.z /
*.ts.net) tests nothing: the tailnet is SUPPOSED to reach the brain.
PASS = every port closed/filtered. Exits non-zero on any FAIL.
EOF
}

MODE="probe"
TARGET="${BRAIN_PUBLIC_IP:-}"
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --local)   MODE="local" ;;
  "")        ;;
  -*)        echo "check-security.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
  *)         TARGET="$1" ;;
esac

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL  $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ---------------------------------------------------------------- probe mode
if [ "$MODE" = "probe" ]; then
  if [ -z "$TARGET" ]; then
    echo "check-security.sh: no target. Pass the brain's PUBLIC IP:" >&2
    echo "  ./scripts/verify/check-security.sh \$(cd infra/terraform && terraform output -raw server_public_ip)" >&2
    usage >&2
    exit 2
  fi
  case "$TARGET" in
    *.ts.net|100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*)
      echo "check-security.sh: '$TARGET' looks like a TAILNET address." >&2
      echo "The probe must target the PUBLIC IP (terraform output -raw server_public_ip) —" >&2
      echo "the tailnet reaching the brain is expected and proves nothing." >&2
      exit 2
      ;;
  esac

  # /dev/tcp connect with a timeout: the connect runs in a background
  # subshell; if it is still trying after $TIMEOUT_S the packets are being
  # dropped (filtered — the expected result behind a default-deny firewall).
  # Returns 0 only if the TCP connect SUCCEEDED, i.e. the port is open.
  probe_port() {
    local ip="$1" port="$2" pid waited=0
    ( exec 3<>"/dev/tcp/$ip/$port" ) >/dev/null 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$waited" -ge "$TIMEOUT_S" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        return 1
      fi
      sleep 1
      waited=$((waited + 1))
    done
    if wait "$pid" 2>/dev/null; then return 0; else return 1; fi
  }

  echo "== check-security: external probe of $TARGET (ports: $PORTS, ${TIMEOUT_S}s each) =="
  echo "Expectation: ALL closed/filtered — the brain accepts nothing from the"
  echo "public internet, not even SSH (tailnet-only after bootstrap)."
  echo
  for port in $PORTS; do
    if probe_port "$TARGET" "$port"; then
      fail "port $port is OPEN on the public IP"
      case "$port" in
        22)   echo "      SSH must be tailnet-only after bootstrap (docs/security.md)." ;;
        3284) echo "      goose serve is exposed publicly — this is the worst case." ;;
      esac
      echo "      Fix: Hetzner Cloud Firewall (infra/terraform) + ufw on the host"
      echo "      must both default-deny inbound. Re-apply terraform, then re-probe."
    else
      pass "port $port closed/filtered"
    fi
  done

  echo
  if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "== summary: zero open public ports — as designed =="
  else
    echo "== summary: $FAIL_COUNT OPEN port(s). Treat as an incident: close them"
    echo "   before doing anything else (docs/security.md). =="
    exit 1
  fi
  exit 0
fi

# ---------------------------------------------------------------- local mode
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "== check-security --local: host checks on the brain =="
echo "(the external port probe must run from a DIFFERENT machine:"
echo " ./scripts/verify/check-security.sh <public-ip>)"
echo

# 1. /data is a real mountpoint (the LUKS volume, not a stray directory on
#    the unencrypted root disk).
if command -v mountpoint >/dev/null 2>&1 && mountpoint -q /data; then
  pass "/data is a mountpoint (LUKS volume mounted)"
else
  fail "/data is NOT a mountpoint — the LUKS volume is not mounted"
  echo "      After a reboot: sudo scripts/vps/luks-unlock.sh. Never write to a"
  echo "      bare /data directory — that would put secrets on the unencrypted disk."
fi

# 2. No goose directory escapes the encrypted volume.
#    goose keeps config/, data/ AND state/ in three different places, and only
#    data/ was ever relocated. state/ holds logs/llm_request.*.jsonl — the raw
#    request and response bodies sent to inference providers — and config/
#    holds secrets.yaml. GOOSE_PATH_ROOT=/data/goose (goose-serve.service)
#    plus the three symlinks deploy-vps.sh creates are what keep all of it on
#    /data; this asserts the result rather than the mechanism, so a hand-edited
#    unit or a dir goose recreated after an upgrade still gets caught.
#    Resolve agent's home from passwd, not $HOME, so `sudo check-security.sh
#    --local` inspects the brain's dirs rather than root's. (`|| true`: under
#    set -e + pipefail a missing agent user would otherwise kill the script.)
AGENT_HOME="$(getent passwd agent 2>/dev/null | cut -d: -f6 || true)"
[ -n "$AGENT_HOME" ] || AGENT_HOME="$HOME"
ESCAPED=""
CHECKED=0
for p in "$AGENT_HOME/.config/goose" "$AGENT_HOME/.local/share/goose" "$AGENT_HOME/.local/state/goose"; do
  # -L as well as -e: with /data unmounted the symlinks dangle, and -e alone
  # would skip them — reporting "nothing to check" for a brain that is in fact
  # configured correctly (or misconfigured and pointing off-volume).
  [ -e "$p" ] || [ -L "$p" ] || continue
  CHECKED=$((CHECKED + 1))
  # -m, not -f: canonicalize without requiring the target to exist, so an
  # unmounted /data still reports where the link POINTS instead of erroring
  # out with half a path.
  RESOLVED="$(readlink -m "$p" 2>/dev/null)" || RESOLVED="$p"
  [ -n "$RESOLVED" ] || RESOLVED="$p"
  case "$RESOLVED" in
    /data|/data/*) ;;
    *) ESCAPED="$ESCAPED
      $p -> $RESOLVED" ;;
  esac
done
if [ -n "$ESCAPED" ]; then
  fail "goose state on the UNencrypted root disk:$ESCAPED"
  echo "      Chat history, secrets.yaml or raw provider request/response bodies"
  echo "      are outside /data. Fix: scripts/vps/deploy-vps.sh migrates them and"
  echo "      goose-serve.service sets GOOSE_PATH_ROOT=/data/goose (docs/privacy.md)."
elif [ "$CHECKED" -eq 0 ]; then
  echo "SKIP  no goose config/data/state dirs under $AGENT_HOME (not a brain, or goose never ran)"
else
  pass "goose config/data/state ($CHECKED of 3 present) resolve under /data"
fi

# 3. secrets.env exists with mode 600.
if [ -f /data/secrets.env ]; then
  PERMS="$(stat -c '%a' /data/secrets.env 2>/dev/null || echo '?')"
  if [ "$PERMS" = "600" ]; then
    pass "/data/secrets.env permissions are 600"
  else
    fail "/data/secrets.env permissions are $PERMS (want 600)"
    echo "      Fix: chmod 600 /data/secrets.env"
  fi
else
  fail "/data/secrets.env is missing"
  echo "      Create it from config/env/secrets.env.example (docs/setup/50-vps-brain.md)."
fi

# 4. ufw active with default-deny incoming.
if command -v ufw >/dev/null 2>&1; then
  UFW_OUT="$(sudo -n ufw status verbose 2>/dev/null || ufw status verbose 2>/dev/null || true)"
  if [ -z "$UFW_OUT" ]; then
    fail "could not read ufw status (needs sudo — run: sudo ufw status verbose)"
  elif printf '%s' "$UFW_OUT" | grep -q "Status: active" && \
       printf '%s' "$UFW_OUT" | grep -qi "deny (incoming)"; then
    pass "ufw active with default deny incoming"
  else
    fail "ufw is not in the expected state (active + default deny incoming)"
    printf '%s\n' "$UFW_OUT" | head -n 6 | sed 's/^/      | /'
  fi
else
  fail "ufw is not installed — cloud-init should have set it up (infra/terraform)"
fi

# 5. gitleaks over the repo clone (defense in depth for the public repo).
if command -v gitleaks >/dev/null 2>&1; then
  if gitleaks detect --source "$REPO_ROOT" --redact --no-banner >/dev/null 2>&1; then
    pass "gitleaks detect: no secrets in $REPO_ROOT"
  else
    fail "gitleaks found potential secrets in $REPO_ROOT"
    echo "      Inspect: gitleaks detect --source $REPO_ROOT --redact --verbose"
    echo "      Then follow docs/public-repo.md before any push."
  fi
else
  echo "SKIP  gitleaks not installed (install: https://github.com/gitleaks/gitleaks)"
fi

# 6. The LIVE config.yaml carries the extension hardening.
#    deploy-vps.sh installs config templates NO-CLOBBER — it has to, since
#    goose rewrites config.yaml at runtime — so hardening that lands in
#    config/goose/config.yaml after the first deploy reaches an ALREADY
#    DEPLOYED brain only if a human merges it. Nothing else notices when
#    nobody does, and the failure mode is silent and OPEN: an `available_tools`
#    allowlist that is absent, empty, or spelled camelCase (goose has no
#    deny_unknown_fields — the key is dropped without a warning) means EVERY
#    tool the MCP server exposes is callable. So assert the file goose
#    actually reads, never the repo template.
LIVE_CFG=""
for c in "$AGENT_HOME/.config/goose/config.yaml" /data/goose/config/config.yaml; do
  if [ -r "$c" ]; then LIVE_CFG="$c"; break; fi
done

# PyYAML: present on any brain (cloud-init itself depends on it); uv is the
# same fallback check-connectors.sh uses.
CFG_RUNNER=""
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  CFG_RUNNER="python3"
elif command -v uv >/dev/null 2>&1; then
  CFG_RUNNER="uv"
fi

if [ -z "$LIVE_CFG" ]; then
  fail "no live goose config.yaml ($AGENT_HOME/.config/goose/, /data/goose/config/)"
  echo "      goose would run on defaults: no tool allowlist, no pinned MCP version,"
  echo "      and the apps extension ON. Fix: scripts/vps/deploy-vps.sh installs it."
elif [ -z "$CFG_RUNNER" ]; then
  echo "SKIP  extension hardening in $LIVE_CFG unverified (no python3 with PyYAML, no uv)"
  echo "      Brain: sudo apt-get install -y python3-yaml, then re-run."
else
  CFG_CHECKER="$(mktemp)"
  cat >"$CFG_CHECKER" <<'PYEOF'
import sys

import yaml

path = sys.argv[1]
try:
    with open(path) as fh:
        cfg = yaml.safe_load(fh) or {}
except Exception as exc:  # unparseable/unreadable live config is a failure, not a skip
    # One line: the caller prints line 1 as the FAIL and indents the rest.
    print("live goose config.yaml (%s) is unreadable or not valid YAML: %s"
          % (path, " ".join(str(exc).split())))
    sys.exit(1)

if not isinstance(cfg, dict):
    print("live %s is valid YAML but not a config mapping (goose would ignore it)" % path)
    sys.exit(1)

exts = cfg.get("extensions")
if not isinstance(exts, dict):
    print("live %s has no `extensions:` map — no extension is configured, so none "
          "is constrained" % path)
    sys.exit(1)

problems = []

# The apps platform extension: ENABLED BY DEFAULT upstream at 1.46.0, so an
# absent entry is an enabled one — `enabled: false` must be written out. App-
# initiated tool calls skip the permission manager entirely.
apps = exts.get("apps")
if not isinstance(apps, dict) or apps.get("enabled") is not False:
    problems.append(
        "`apps` platform extension is not explicitly disabled (absent == ENABLED "
        "upstream) — app-initiated tool calls bypass the permission manager"
    )

ws = exts.get("workspace-mcp")
tool_count = 0
disabled = False
if ws is None:
    problems.append(
        "no `workspace-mcp` entry — this brain predates the hardened template "
        "(config.yaml is installed no-clobber, so it was never updated)"
    )
elif not isinstance(ws, dict):
    problems.append("`workspace-mcp` entry is not a mapping")
elif ws.get("enabled") is False:
    disabled = True
else:
    tools = ws.get("available_tools")
    args = [str(a) for a in (ws.get("args") or [])]
    if "availableTools" in ws:
        problems.append(
            "`workspace-mcp` carries the camelCase `availableTools` — goose "
            "discards it SILENTLY, and no allowlist means every tool is allowed"
        )
    if not isinstance(tools, list) or not tools:
        problems.append(
            "`workspace-mcp` has no non-empty snake_case `available_tools` — "
            "every tool the server registers is callable (fails OPEN)"
        )
    else:
        tool_count = len(tools)
    if "--permissions" not in args:
        problems.append(
            "`workspace-mcp` args carry no `--permissions` flag — OAuth consent "
            "then asks for every scope its services can use"
        )
    if "--tools" in args:
        problems.append(
            "`workspace-mcp` args carry `--tools` (selects whole SERVICES; "
            "mutually exclusive with --permissions upstream)"
        )

# Every OTHER enabled MCP extension needs an allowlist too. workspace-mcp gets
# the detailed treatment above because the repo ships it wired in, but the
# fail-open is a property of the mechanism, not of that one server: `playwright`
# and `tavily` ship disabled precisely so that nobody has to think about it, and
# the moment someone flips one to `enabled: true` without an allowlist it is a
# blank cheque. Assert it generally so a future extension cannot reintroduce the
# hole. Builtin/platform extensions are goose's own and are out of scope.
for name, ext in sorted(exts.items()):
    if name == "workspace-mcp" or not isinstance(ext, dict):
        continue
    if ext.get("type") in ("builtin", "platform"):
        continue
    if ext.get("enabled") is not True:
        continue
    if "availableTools" in ext:
        problems.append(
            "`%s` is enabled and carries the camelCase `availableTools` — goose "
            "discards it SILENTLY, so every tool is allowed" % name
        )
    tools = ext.get("available_tools")
    if not isinstance(tools, list) or not tools:
        problems.append(
            "`%s` is enabled with no non-empty snake_case `available_tools` — "
            "every tool that server registers is callable (fails OPEN). Derive the "
            "list from a real tools/list: scripts/verify/check-connectors.sh --smoke"
            % name
        )

if problems:
    print("live %s: %d hardening problem(s)" % (path, len(problems)))
    for p in problems:
        print("      - %s" % p)
    print("      These are template changes that never reached this brain — deploy")
    print("      installs config.yaml no-clobber. Merge by hand, then restart goose:")
    print("        diff %s <repo>/config/goose/config.yaml" % path)
    print("        sudo systemctl restart goose-serve.service")
    sys.exit(1)

if disabled:
    print("live %s: apps off; workspace-mcp present but disabled (allowlist not exercised)" % path)
    sys.exit(3)
print(
    "live config.yaml hardened (apps off; workspace-mcp --permissions + "
    "%d-tool available_tools allowlist)" % tool_count
)
PYEOF
  CFG_RC=0
  if [ "$CFG_RUNNER" = "python3" ]; then
    CFG_OUT="$(python3 "$CFG_CHECKER" "$LIVE_CFG" 2>&1)" || CFG_RC=$?
  else
    CFG_OUT="$(uv run --quiet --with pyyaml python "$CFG_CHECKER" "$LIVE_CFG" 2>&1)" || CFG_RC=$?
  fi
  rm -f "$CFG_CHECKER"
  CFG_MSG="$(printf '%s\n' "$CFG_OUT" | head -n 1)"
  CFG_REST="$(printf '%s\n' "$CFG_OUT" | tail -n +2)"
  if [ "$CFG_RC" -eq 0 ]; then
    pass "$CFG_MSG"
  elif [ "$CFG_RC" -eq 3 ]; then
    echo "SKIP  $CFG_MSG"
  else
    fail "$CFG_MSG"
  fi
  if [ -n "$CFG_REST" ]; then
    printf '%s\n' "$CFG_REST"
  fi
fi

echo
echo "== summary: $PASS_COUNT passed, $FAIL_COUNT failed =="
[ "$FAIL_COUNT" -eq 0 ] || exit 1
