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

# shellcheck source=scripts/verify/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TIMEOUT_S=5
# 4300 is the code-agent gateway and 4310 is the first per-chat opencode server
# (CODE_AGENT_PORT / CODE_AGENT_BASE_CHAT_PORT). Both were missing here, so the
# entire code plane — the half of this system that runs autonomous agents with a
# GitHub PAT — was never externally probed at all. 4310 is included as the
# representative of the whole 4310+ band: it binds 127.0.0.1 by design, so if it
# answers on the public IP the loopback binding has regressed.
PORTS="22 80 443 3284 4300 4310"

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
  -*)        die_usage "unknown option: $1" ;;
  *)         TARGET="$1" ;;
esac

# ---------------------------------------------------------------- probe mode
if [ "$MODE" = "probe" ]; then
  if [ -z "$TARGET" ]; then
    die_usage "no target. Pass the brain's PUBLIC IP:" \
      "  ./scripts/verify/check-security.sh \$(cd infra/terraform && terraform output -raw server_public_ip)"
  fi
  case "$TARGET" in
    *.ts.net|100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*)
      die 2 "'$TARGET' looks like a TAILNET address." \
        "The probe must target the PUBLIC IP (terraform output -raw server_public_ip) —" \
        "the tailnet reaching the brain is expected and proves nothing."
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
        4300) echo "      The code-agent gateway is public. It fronts containers holding a" \
                   "GitHub PAT that can open pull requests (docs/code-agents.md)." ;;
        4310) echo "      A per-chat opencode server is public. These bind 127.0.0.1 and are" \
                   "reachable only through the gateway — that binding has regressed." ;;
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
# --local IS A ROSTER ENTRY NOW. brain.yaml's `verify:` names it, and `pai
# verify` derives its roster from that field on every host — so this path runs
# on a Mac too. Every check below asks about /data, ufw and the `agent` user, so
# off the brain it would print four confident FAILs describing a machine it is
# not looking at. Exit 2 instead: this repo's word for "the precondition is
# missing", which cli.sh renders as a SKIP and `pai verify --require security`
# escalates back to a failure for someone who believes they ARE on the brain.
if [ "$(pai_mode no)" != "local" ]; then
  die 2 "--local runs ON the brain, and this is not one (no /data + systemctl)." \
    "From here, probe the brain from the outside instead — that is the mode" \
    "this script has for other machines, and it must run from one:" \
    "  ./scripts/verify/check-security.sh \"\$(cd infra/terraform && terraform output -raw server_public_ip)\"" \
    "PAI_MODE=local forces this path (fixtures, and the brain's own CI)."
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ---- named sections ---------------------------------------------------------
# THREE DIFFERENT SUBJECTS SHARED ONE EXIT CODE. This script asserts host
# hardening (the LUKS mount, ufw), where goose keeps its state, repo hygiene
# (gitleaks) and the live config's connector policy — and reported one number,
# so a red run said "something about the brain is wrong" and nothing more. A
# user with no connectors ran the connector rule and could not tell which unit
# had regressed.
#
# The verdicts are unchanged and the exit code is still one number, because a
# hardening failure is a hardening failure. What is new is that each section
# recaps its OWN counts under the footer, so the row that went red names the
# subject. Sections are delimited by calls, not by a table: a table of section
# names would be one more roster to keep in step with the code under it.
SECTION=""
SEC_PASS=0
SEC_FAIL=0
SEC_SKIP=0

end_section() {
  if [ -n "$SECTION" ]; then
    summary_row "$(printf '%-22s %d passed, %d failed, %d skipped' \
      "$SECTION" "$((PASS_COUNT - SEC_PASS))" "$((FAIL_COUNT - SEC_FAIL))" \
      "$((SKIP_COUNT - SEC_SKIP))")"
    SECTION=""
  fi
  return 0
}

begin_section() { # begin_section <name>
  end_section
  SECTION="$1"
  SEC_PASS="$PASS_COUNT"
  SEC_FAIL="$FAIL_COUNT"
  SEC_SKIP="$SKIP_COUNT"
  echo
  echo "-- $SECTION --"
  return 0
}

echo "== check-security --local: host checks on the brain =="
echo "(the external port probe must run from a DIFFERENT machine:"
echo " ./scripts/verify/check-security.sh <public-ip>)"

begin_section "host posture"

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
  skip "no goose config/data/state dirs under $AGENT_HOME (not a brain, or goose never ran)"
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

begin_section "repo hygiene"

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
  skip "gitleaks not installed (install: https://github.com/gitleaks/gitleaks)"
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
# lib.sh's resolver, with AGENT_HOME standing in for $HOME so `sudo
# check-security.sh --local` still inspects the brain's config rather than
# root's. THE CANDIDATE LIST IS SHARED WITH check-mcp.sh now: this script was
# the only one that knew about /data/goose/config/config.yaml, and unifying on
# check-mcp's single `$HOME/.config/goose/config.yaml` would have silently
# broken --local on the one host it is written for.
CFG_HOME="${PAI_HOME:-$AGENT_HOME}"
LIVE_CFG="$(PAI_HOME="$CFG_HOME" live_goose_config)"

# py_runner with a SKIP policy instead of its die: an unverifiable config is not
# the same finding as a bad one, and lib.sh's comment on resolve_goose_bin says
# in as many words that the policy belongs to the caller. PyYAML is present on
# any brain (cloud-init itself depends on it); uv is the same fallback.
CFG_RUNNER=""
if CFG_RUNNER="$(py_runner 2>/dev/null)"; then :; else CFG_RUNNER=""; fi

if [ -z "$LIVE_CFG" ]; then
  begin_section "live goose config"
  fail "no live goose config.yaml ($CFG_HOME/.config/goose/, /data/goose/config/)"
  echo "      goose would run on defaults: no tool allowlist, no pinned MCP version,"
  echo "      and the apps extension ON. Fix: scripts/vps/deploy-vps.sh installs it."
elif [ -z "$CFG_RUNNER" ]; then
  begin_section "live goose config"
  skip "extension hardening in $LIVE_CFG unverified (no python3 with PyYAML, no uv)"
  note "Brain: sudo apt-get install -y python3-yaml, then re-run."
else
  read -r -a CFG_PY <<<"$CFG_RUNNER"
  CFG_CHECKER="$(mktemp)"
  cat >"$CFG_CHECKER" <<'PYEOF'
# TWO SUBJECTS, TWO SECTIONS. `apps` is about goose's own permission manager and
# is true of any install; the allowlist rules are about the CONNECTORS this
# machine has. Merged, a user with no connectors ran the connector rule and a
# red run could not say which unit had regressed. Emitted as verdict lines the
# caller maps -- the same shape units_lint.py hands check-units.sh -- so the
# section split is one thing and the counting is still lib.sh's.
import sys

import yaml

path = sys.argv[1]


def emit(verdict, text):
    # TWO SPACES, always, whatever the verdict's length: the caller matches on
    # the literal prefix "SECTION  " / "FAIL  ", and `%-6s` silently produced
    # "SECTIONgoose platform posture", which fell through to the passthrough arm
    # and put every connector verdict in the previous section's tally.
    print("%s  %s" % (verdict, text))


try:
    with open(path) as fh:
        cfg = yaml.safe_load(fh) or {}
except Exception as exc:  # unparseable/unreadable live config is a failure, not a skip
    emit("SECTION", "live goose config")
    emit("FAIL", "live goose config.yaml (%s) is unreadable or not valid YAML: %s"
         % (path, " ".join(str(exc).split())))
    sys.exit(0)

emit("SECTION", "goose platform posture")
if not isinstance(cfg, dict):
    emit("FAIL", "live %s is valid YAML but not a config mapping (goose would "
                 "ignore it entirely)" % path)
    sys.exit(0)

exts = cfg.get("extensions")
if not isinstance(exts, dict):
    emit("FAIL", "live %s has no `extensions:` map — nothing is configured, so "
                 "nothing is constrained, and `apps` is on by default upstream" % path)
    exts = {}
else:
    # The apps platform extension: ENABLED BY DEFAULT upstream at 1.46.0, so an
    # absent entry is an enabled one — `enabled: false` must be written out.
    # App-initiated tool calls skip the permission manager entirely.
    apps = exts.get("apps")
    if not isinstance(apps, dict) or apps.get("enabled") is not False:
        emit("FAIL", "`apps` platform extension is not explicitly disabled (absent "
                     "== ENABLED upstream) — app-initiated tool calls bypass the "
                     "permission manager")
    else:
        emit("PASS", "`apps` platform extension is explicitly disabled")

emit("SECTION", "connector policy")

# THE ROSTER IS THE LIVE CONFIG'S. Same predicate check-mcp.sh uses: an enabled
# extension that declares an MCP server (`cmd`/`uri`) and is not one of goose's
# own builtins. Everything below is scoped to it, so a machine that installed no
# connectors is not penalised for the connector rule -- which it was, because
# `workspace-mcp` missing was an unconditional finding.
declared = {}
for name, ext in sorted(exts.items()):
    if not isinstance(ext, dict):
        continue
    if ext.get("type") in ("builtin", "platform"):
        continue
    if ext.get("enabled") is not True:
        continue
    if not (ext.get("cmd") or ext.get("uri")):
        continue
    declared[name] = ext

problems = []
tool_count = 0

ws = declared.get("workspace-mcp")
if ws is not None:
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
# blank cheque.
for name, ext in sorted(declared.items()):
    if name == "workspace-mcp":
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

if not declared:
    emit("SKIP", "no enabled extension in %s declares an MCP server — this machine "
                 "has no connectors to police" % path)
    sys.exit(0)

for p in problems:
    emit("FAIL", p)
if problems:
    emit("NOTE", "These are template changes that never reached this brain — deploy")
    emit("NOTE", "installs config.yaml no-clobber. Merge by hand, then restart goose:")
    emit("NOTE", "  diff %s <repo>/config/goose/config.yaml" % path)
    emit("NOTE", "  sudo systemctl restart goose-serve.service")
else:
    emit("PASS", "all %d enabled MCP extension(s) carry a non-empty available_tools "
                 "allowlist: %s" % (len(declared), ", ".join(sorted(declared))))

# workspace-mcp's ABSENCE is a NOTE, not a failure, and that is a deliberate
# narrowing. It used to be an unconditional finding ("this brain predates the
# hardened template"), which penalised every machine that simply never installed
# google-workspace. Telling those two apart is exactly the "installed vs
# installed-and-broken" distinction that needs the unit registry (#40); until it
# exists there is no predicate, and a rule with no predicate is the one this
# issue is about.
if ws is None:
    emit("NOTE", "no enabled `workspace-mcp` entry. If google-workspace IS meant to "
                 "be installed here, this brain predates the hardened template "
                 "(config.yaml is installed no-clobber). Not a failure: nothing on "
                 "this machine records which units were selected (#40).")
PYEOF
  CFG_RC=0
  CFG_OUT="$("${CFG_PY[@]}" "$CFG_CHECKER" "$LIVE_CFG" 2>&1)" || CFG_RC=$?
  rm -f "$CFG_CHECKER"
  CFG_FAILS_BEFORE="$FAIL_COUNT"
  while IFS= read -r line; do
    case "$line" in
      "SECTION  "*) begin_section "${line#SECTION  }" ;;
      "PASS  "*)    pass "${line#PASS  }" ;;
      "FAIL  "*)    fail "${line#FAIL  }" ;;
      "SKIP  "*)    skip "${line#SKIP  }" ;;
      "NOTE  "*)    note "${line#NOTE  }" ;;
      *)            echo "$line" ;;
    esac
  done <<<"$CFG_OUT"
  # A checker that DIED rather than reported is itself a failure — the rule
  # check-units.sh and check-goose-template.sh already apply. Without it a
  # traceback would exit non-zero with zero FAIL lines and `finish` would call
  # the whole live-config arm a pass.
  if [ "$CFG_RC" -ne 0 ] && [ "$FAIL_COUNT" -eq "$CFG_FAILS_BEFORE" ]; then
    begin_section "live goose config"
    fail "the live-config checker exited $CFG_RC without reporting a verdict"
  fi
fi

end_section
finish --skips
