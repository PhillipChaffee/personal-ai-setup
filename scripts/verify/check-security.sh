#!/usr/bin/env bash
# check-security.sh — verifies the brain's security posture.
#
# Default mode (run from ANY machine, no nmap needed): probes the brain's
# PUBLIC IP over the open internet on ports 22, 80, 443, 3284 using bash's
# /dev/tcp. The pass condition is that NOTHING answers — the brain is
# tailnet-only by design (docs/security.md), so an open public port means the
# Hetzner firewall or ufw regressed.
#
# --local mode (run ON the brain): /data mount, secrets.env permissions,
# ufw default-deny, and a gitleaks scan of the repo clone.
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

# 2. secrets.env exists with mode 600.
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

# 3. ufw active with default-deny incoming.
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

# 4. gitleaks over the repo clone (defense in depth for the public repo).
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

echo
echo "== summary: $PASS_COUNT passed, $FAIL_COUNT failed =="
[ "$FAIL_COUNT" -eq 0 ] || exit 1
