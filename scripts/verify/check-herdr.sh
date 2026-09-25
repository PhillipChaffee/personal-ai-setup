#!/usr/bin/env bash
# check-herdr.sh — verification for the herdr plane: the service and its
# namespace contract, the six-key server config, the pick-aware environment
# set, the pinned binary and agent CLIs, the isolation boundary, and the disk
# gate. Run on the brain (over SSH) or from the Mac across the tailnet — it
# detects which side it's on. Concept: docs/coding-agents.md. Criteria: the
# revised herdr epic (#139 — the resolution comment on that ticket), against
# the Sep-12 base spec's U/T/TN ids.
set -euo pipefail

# shellcheck source=scripts/verify/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: check-herdr.sh [--local] [--help]

Checks the herdr coding-agent plane on the brain: herdr.service active and
namespace-hardened, the six-key config, the pinned binary and agent CLIs, the
pick-aware env set against the recorded agents.list, the isolation boundary
(what the herdr user can and cannot reach), the 0600 socket, the worktree
hygiene, and the 75%-of-volume disk gate.

  --local     force local mode (default: auto-detected via /data).

Remote mode needs BRAIN_HOST set to the brain's tailnet name, e.g.:
  BRAIN_HOST=<your-brain>.<your-tailnet>.ts.net ./scripts/verify/check-herdr.sh
and SSH access as agent@$BRAIN_HOST (keys only; see docs/security.md).
Exits non-zero if any automated check fails.
EOF
}

FORCE_LOCAL="no"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --local) FORCE_LOCAL="yes" ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift
done

# The same testing-only seam deploy-vps.sh carries; unset, they are the
# literals they replaced.
DATA_ROOT="${PAI_DATA_ROOT:-/data}"
SYSTEMD_DIR="${PAI_SYSTEMD_DIR:-/etc/systemd/system}"
HERDR="$DATA_ROOT/herdr"
HERDR_CONFIG="$HERDR/config"
REPO_DIR="${PAI_REPO_DIR:-/home/agent/personal-ai-setup}"
# The herdr home is 0750 herdr:herdr, so herdr-owned arms run as root (sudo) —
# the same reason check-code-agents.sh's herdr-side probes ran under sudo.
# Vendor-vs-Zen and the exact env-set rules below are the SAME RULES
# deploy-vps.sh implements; test-verify-checks.sh's drift-lock pins the
# catalog strings, so the two cannot quietly disagree.

# pin_from SECTION KEY [SUBKEY] — the check's pin reader over $PINS. Strictly
# two nestings, like deploy-vps.sh's pin_value, but written independently: the
# two sides must AGREE, not share a parser — shared code would make the
# comparison a function agreeing with itself.
pin_from() {
  awk -v sec="$1" -v key="$2" -v sk="${3:-}" '
    {
      # The value test runs against the section state as of the PREVIOUS line:
      # the key line itself must not advance the pointer before it is matched.
      if (sk == "" && top == sec && mid == "" && $1 == key ":") {
        gsub(/"/, "", $2)
        print $2
        exit
      }
      if (sk != "" && top == sec && mid == key && $1 == sk ":") {
        gsub(/"/, "", $2)
        print $2
        exit
      }
      if ($1 ~ /^[A-Za-z][A-Za-z0-9_]*:$/) { split($0, t, ":"); top = t[1]; mid = "" }
      else if (top != "" && $1 ~ /^[A-Za-z][A-Za-z0-9_]*:$/ && /^  /) {
        split(substr($0, 3), t, ":")
        mid = t[1]
      }
    }
  ' "$PINS" 2>/dev/null
}

MODE="$(pai_mode "$FORCE_LOCAL")"

# ---- deselected, or not installed? ------------------------------------------
# exit 2 = SKIP for `pai verify` (cli.sh maps 2 to SKIP): a brain deployed
# without --with herdr must not carry a permanently-red check. Keyed on the
# deploy artifacts alone (unit file + herdr home), never on a binary probe.
if [ "$MODE" = "local" ] && [ ! -e "$SYSTEMD_DIR/herdr.service" ] && [ ! -d "$HERDR" ]; then
  die 2 "no herdr plane on this host — skipping." \
    "Neither $SYSTEMD_DIR/herdr.service nor $HERDR exists." \
    "That is the expected state for a brain deployed without '--with herdr'." \
    "It is ALSO what a failed herdr install looks like: if you did select the" \
    "unit, re-run 'deploy-vps.sh --only herdr' and read its output."
fi

echo "== check-herdr (mode: $MODE) =="
echo

# ---- live-arm availability ---------------------------------------------------
SYSTEMD_LIVE=no
HERDR_USER_LIVE=no
UNIT_LIVE=no
SYSTEMD_STATE="$(brain_exec sh -c 'systemctl is-system-running 2>/dev/null || true')"
[ -n "$SYSTEMD_STATE" ] && SYSTEMD_LIVE=yes
# The CI runner has REAL systemd (is-system-running answers), so reachability
# alone does not gate the service arms — the UNIT must also be known to this
# host's systemd, or `is-active` would report the plane as down for the simple
# reason that the fixture's unit file is not in the real /etc.
if [ "$SYSTEMD_LIVE" = "yes" ] && brain_exec systemctl cat herdr.service >/dev/null 2>&1; then
  UNIT_LIVE=yes
fi
if [ "$MODE" = "local" ]; then
  if sudo -u herdr true 2>/dev/null; then
    HERDR_USER_LIVE=yes
  fi
else
  # Remote mode IS the brain: the user and systemd are there by construction.
  HERDR_USER_LIVE=yes
fi
# ---- 1. the service ---------------------------------------------------------
if [ "$UNIT_LIVE" != "yes" ]; then
  skip "herdr.service active — systemd cannot see the unit on this host (a live arm; run on the brain)"
else
  SVC_STATE="$(brain_exec systemctl is-active herdr 2>&1 || true)"
  if [ "$SVC_STATE" = "active" ]; then
    pass "systemctl is-active herdr"
  else
    fail "herdr.service not active (got: ${SVC_STATE:-no answer})"
    note "After a reboot this is EXPECTED until luks-unlock.sh runs (docs/setup/50-vps-brain.md §10)."
    note "Logs: journalctl -u herdr -n 50"
  fi
fi

# ---- 2. the namespace contract ----------------------------------------------
# The unit file must be BYTE-IDENTICAL to the repo template: the hardening set
# (ProtectSystem/TemporaryFileSystem/BindPaths/ProtectHome/NoNewPrivileges/
# PrivateTmp + the HOME/XDG env block) is one contract, not a menu.
if [ "$MODE" = "local" ]; then
  if cmp -s "$REPO_DIR/scripts/vps/systemd/herdr.service" "$SYSTEMD_DIR/herdr.service" 2>/dev/null; then
    pass "herdr.service matches the repo template byte for byte"
  else
    fail "herdr.service differs from scripts/vps/systemd/herdr.service — the namespace contract may have drifted; re-run deploy-vps.sh --only herdr"
  fi
else
  note "unit-file comparison runs in local mode (the repo checkout is on the brain)"
fi
# The live properties, from systemd itself — the file can be right while the
# running unit predates it (systemd-analyze verify is CI's arm; this is the
# live half). show(1) prints one KEY=value line per -p.
if [ "$UNIT_LIVE" != "yes" ]; then
  skip "systemd namespace properties — systemd does not know the unit here (a live arm)"
else
  NS="$(brain_exec systemctl show herdr -p ProtectSystem -p ProtectHome -p NoNewPrivileges -p PrivateTmp 2>/dev/null || true)"
  if printf '%s\n' "$NS" | grep -qx "ProtectSystem=strict" && \
     printf '%s\n' "$NS" | grep -qx "ProtectHome=true" && \
     printf '%s\n' "$NS" | grep -qx "NoNewPrivileges=true" && \
     printf '%s\n' "$NS" | grep -qx "PrivateTmp=true"; then
    pass "systemd properties: ProtectSystem=strict, ProtectHome=true, NoNewPrivileges, PrivateTmp"
  else
    fail "systemd properties missing the hardening set (got: $(printf '%s' "$NS" | tr '\n' ' '))"
  fi
  # The see-only-its-own-dir pair. systemctl show reports TemporaryFileSystem
  # and BindPaths as the raw values the unit carries.
  NS2="$(brain_exec systemctl show herdr -p TemporaryFileSystem -p BindPaths -p ReadWritePaths -p Environment 2>/dev/null || true)"
  if printf '%s\n' "$NS2" | grep -q "^TemporaryFileSystem=/data:ro" && \
     printf '%s\n' "$NS2" | grep -q "^BindPaths=$HERDR\$"; then
    pass "namespace: /data is a read-only tmpfs with the herdr home bound back in"
  else
    fail "namespace: TemporaryFileSystem=/data:ro + BindPaths=$HERDR not in effect
       (got: $(printf '%s' "$NS2" | tr '\n' ' '))"
  fi
  if printf '%s\n' "$NS2" | grep -q "^Environment=HOME=$HERDR\$" && \
     printf '%s\n' "$NS2" | grep -q "^Environment=XDG_CONFIG_HOME=$HERDR_CONFIG\$"; then
    pass "environment: HOME and XDG_CONFIG_HOME point inside the herdr home"
  else
    fail "environment: the HOME/XDG_CONFIG_HOME contract with the SSH bridge is broken
       (the bridge resolves its socket from the login session's env; see herdr.service's header)"
  fi
fi

# ---- 3. the six-key config (T3) ---------------------------------------------
# The whole meaning of the brain's config is these exact lines: pane replay
# stays off even if herdr flips the default, resume stays on even if it flips
# the other way. Every key compared, table headers included (a key under the
# wrong table has a different meaning than its name suggests).
herdr_cfg="$HERDR_CONFIG/herdr/config.toml"
CFG_OK=1
for line in "onboarding = false" "[update]" "version_check = false" "manifest_check = false" \
            "[experimental]" "pane_history = false" "[session]" "resume_agents_on_restore = true" \
            "[worktrees]" 'directory = "'"$HERDR"'/worktrees"'; do
  if ! brain_exec grep -qxF -- "$line" "$herdr_cfg" 2>/dev/null; then
    CFG_OK=0
    fail "config.toml is missing or altered: '$line'"
  fi
done
if [ "$CFG_OK" = "1" ]; then
  pass "config.toml: all six keys explicit and correct ($herdr_cfg)"
fi

# ---- 4. the socket (0600, owned herdr) --------------------------------------
SOCKET="$HERDR_CONFIG/herdr/herdr.sock"
SOCKET_MODE="$(brain_exec stat -c %a "$SOCKET" 2>/dev/null || true)"
SOCKET_OWNER="$(brain_exec stat -c %U "$SOCKET" 2>/dev/null || true)"
if [ "$HERDR_USER_LIVE" != "yes" ]; then
  # Owner is unknowable without the user; the mode is still a fixture-able arm.
  if [ "$SOCKET_MODE" = "600" ]; then
    pass "API socket at $SOCKET is mode 0600 (owner not checkable on this host)"
  elif [ -z "$SOCKET_MODE" ]; then
    skip "socket mode 0600 (no socket found — service down? see check 1)"
  else
    fail "API socket at $SOCKET is mode ${SOCKET_MODE:-?} — want 0600"
  fi
elif [ "$SOCKET_MODE" = "600" ] && [ "$SOCKET_OWNER" = "herdr" ]; then
  pass "API socket at $SOCKET is mode 0600, owner herdr"
elif [ -z "$SOCKET_MODE" ]; then
  note "SKIP socket mode — $SOCKET does not exist (service down? see check 1)"
  skip "socket mode 0600 (no socket found)"
else
  fail "API socket at $SOCKET is mode ${SOCKET_MODE:-?} owner ${SOCKET_OWNER:-?} — want 0600 herdr
       (the SSH remote-attach bridge reaches the server ONLY through this socket,
       so its owner and mode are the whole access story)"
fi

# ---- 5. the pinned binary (T2/TN5) ------------------------------------------
herdr_bin="$HERDR/bin/herdr"
PINS="$REPO_DIR/config/pins.yaml"
PIN_HERDR="$(pin_from herdr version)"
if [ -z "$PIN_HERDR" ]; then
  skip "pinned version — config/pins.yaml not readable at $PINS"
elif [ "$HERDR_USER_LIVE" != "yes" ]; then
  skip "pinned version — the herdr user does not exist on this host (a live arm)"
else
  HERDR_VERSION="$(brain_exec sudo -u herdr env HOME="$HERDR" "$herdr_bin" --version 2>/dev/null | head -n1 || true)"
  if printf '%s' "$HERDR_VERSION" | grep -q "$PIN_HERDR"; then
    pass "herdr binary reports a version matching the pin ($PIN_HERDR)"
  else
    fail "herdr binary version ('${HERDR_VERSION:-none}') does not match the pinned '$PIN_HERDR' —
       re-run deploy-vps.sh --only herdr (the binary must never update itself: update.* are off, TN5)"
  fi
fi

# ---- 6. the pick-aware environment (T5, exact set) --------------------------
# agents.list is the record unit_herdr() wrote; the expected env set is the
# union of the picked agents' rows per the #138 matrix + the git PAT, with the
# vendor-first rule. This implements the SAME rules deploy-vps.sh does.
AGENTS_LIST="$HERDR_CONFIG/agents.list"
if ! brain_exec test -f "$AGENTS_LIST" 2>/dev/null; then
  fail "$AGENTS_LIST missing — the pick record every other arm here reads"
  AGENTS=""
else
  AGENTS="$(brain_exec grep -vE '^#|^[[:space:]]*$' "$AGENTS_LIST" 2>/dev/null || true)"
  pass "agents.list present ($(printf '%s' "$AGENTS" | grep -c . || true) agent(s): $(printf '%s' "$AGENTS" | tr '\n' ' '))"
fi

# The picked rows' sources, name-only: which keys in /data/secrets.env are
# non-empty decides vendor-vs-Zen exactly as the installer did. Values are
# never read here.
SECRETS_FILE="$DATA_ROOT/secrets.env"
present_names() {
  # present_names — the non-empty variable NAMES in /data/secrets.env.
  brain_exec sh -c "grep -oE '^[A-Z][A-Z0-9_]+=..*' '$SECRETS_FILE' 2>/dev/null | cut -d= -f1" 2>/dev/null || true
}
have() {
  printf '%s\n' "$SECRET_NAMES" | grep -qx "$1"
}
SECRET_NAMES="$(present_names)"

EXPECTED=""
for id in $AGENTS; do
  case "$id" in
    opencode|pi|grok-build)
      if have TOGETHER_API_KEY; then
        EXPECTED="$EXPECTED TOGETHER_API_KEY"
      else
        fail "agents.list picks '$id' but /data/secrets.env has no TOGETHER_API_KEY — the install requires it (the default biller); fill it in and re-run deploy-vps.sh --only herdr"
      fi ;;
    claude-code)
      if have ANTHROPIC_API_KEY; then
        EXPECTED="$EXPECTED ANTHROPIC_API_KEY"
      elif have OPENCODE_ZEN_API_KEY; then
        EXPECTED="$EXPECTED ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL"
      else
        fail "agents.list picks 'claude-code' but /data/secrets.env has neither ANTHROPIC_API_KEY (vendor) nor OPENCODE_ZEN_API_KEY (Zen) — fill one in and re-run deploy-vps.sh --only herdr"
      fi ;;
    codex)
      if have OPENAI_API_KEY; then
        EXPECTED="$EXPECTED OPENAI_API_KEY"
      elif have OPENCODE_ZEN_API_KEY; then
        EXPECTED="$EXPECTED OPENCODE_ZEN_API_KEY"
      else
        fail "agents.list picks 'codex' but /data/secrets.env has neither OPENAI_API_KEY (vendor) nor OPENCODE_ZEN_API_KEY (Zen) — fill one in and re-run deploy-vps.sh --only herdr"
      fi ;;
  esac
done
if [ -n "$AGENTS" ] && have GITHUB_CODE_AGENT_PAT; then
  EXPECTED="$EXPECTED GITHUB_CODE_AGENT_PAT"
fi
ACTUAL="$(brain_exec sh -c "grep -oE '^[A-Z][A-Z0-9_]+=' '$HERDR/secrets.env' 2>/dev/null | cut -d= -f1" 2>/dev/null || true)"
# shellcheck disable=SC2086  # both sets are newline-joined word lists on purpose
EXTRA="$(printf '%s\n' $ACTUAL | sort | uniq | comm -13 <(printf '%s\n' $EXPECTED | sort | uniq) - | tr '\n' ' ')"
# shellcheck disable=SC2086
MISSING="$(printf '%s\n' $EXPECTED | sort | uniq | comm -23 - <(printf '%s\n' $ACTUAL | sort | uniq) | tr '\n' ' ')"
if [ -z "$ACTUAL" ] && [ -z "$(printf '%s' "$EXPECTED")" ]; then
  pass "herdr env is empty (server only) — matches agents.list"
elif [ -n "${EXTRA# }${MISSING# }" ]; then
  fail "herdr env set does not match agents.list-derived expectation${EXTRA:+
       extra:  $EXTRA}${MISSING:+
       missing: $MISSING}
       Re-run deploy-vps.sh --only herdr; never hand-edit the env file."
else
  pass "herdr env set matches agents.list-derived expectation ($(printf '%s' "$ACTUAL" | wc -w | tr -d ' ') rows)"
fi
# shellcheck disable=SC2086  # ACTUAL is a newline-joined word list on purpose
if printf '%s\n' $ACTUAL | grep -qx GOOSE_SERVER__SECRET_KEY; then
  fail "GOOSE_SERVER__SECRET_KEY is in the herdr env — the goose secret stays goose-scoped, never here"
fi
if [ "$HERDR_USER_LIVE" != "yes" ]; then
  skip "herdr env file mode/owner — the herdr user does not exist on this host (a live arm)"
elif [ "$MODE" = "local" ]; then
  SECRETS_MODE="$(stat -c %a "$HERDR/secrets.env" 2>/dev/null || true)"
  SECRETS_OWNER="$(stat -c %U "$HERDR/secrets.env" 2>/dev/null || true)"
  if [ "$SECRETS_MODE" = "600" ] && [ "$SECRETS_OWNER" = "herdr" ]; then
    pass "herdr env file is 0600, owner herdr"
  else
    fail "herdr env file is mode ${SECRETS_MODE:-?} owner ${SECRETS_OWNER:-?} — want 0600 herdr"
  fi
fi

# ---- 7. pinned agent CLIs (T6, live) ----------------------------------------
# One version arm per recorded agent. A picked agent whose CLI is missing or
# off-pin is a FAIL: the pin is the whole supply-chain story for the plane.
if [ "$HERDR_USER_LIVE" != "yes" ]; then
  skip "pinned agent CLIs — the herdr user does not exist on this host (a live arm)"
else
  for id in $AGENTS; do
    case "$id" in
      opencode)    AGENT_BIN="$HERDR/bin/opencode";      pin_key="opencode" ;;
      pi)          AGENT_BIN="$HERDR/.local/bin/pi";     pin_key="pi" ;;
      claude-code) AGENT_BIN="$HERDR/.local/bin/claude"; pin_key="claude_code" ;;
      codex)       AGENT_BIN="$HERDR/.local/bin/codex";  pin_key="codex" ;;
      grok-build)  AGENT_BIN="$HERDR/.grok/bin/grok";    pin_key="grok_build" ;;
      *)           AGENT_BIN=""; pin_key="" ;;
    esac
    if [ -z "$AGENT_BIN" ]; then
      fail "agents.list names '$id', which this check does not know — deploy-vps.sh's AGENT_CATALOG and this case must agree"
      continue
    fi
    pin="$(pin_from coding_agents "$pin_key" version)"
    if [ -z "$pin" ]; then
      skip "$id version — no pin readable in config/pins.yaml"
    elif ! brain_exec sudo -u herdr test -x "$AGENT_BIN" 2>/dev/null; then
      fail "$id: pinned in agents.list but $AGENT_BIN is missing — re-run deploy-vps.sh --only herdr"
    else
      AGENT_VERSION="$(brain_exec sudo -u herdr env HOME="$HERDR" "$AGENT_BIN" --version 2>/dev/null | head -n1 || true)"
      if printf '%s' "$AGENT_VERSION" | grep -q "$pin"; then
        pass "$id at pinned version ($pin)"
      else
        fail "$id version ('$AGENT_VERSION') does not match the pinned '$pin' — re-run deploy-vps.sh --only herdr"
      fi
    fi
  done
fi

# ---- 8. isolation: what the herdr user can and cannot reach (T8/TN2/TN3) ----
if [ "$HERDR_USER_LIVE" != "yes" ]; then
  skip "isolation arms — the herdr user does not exist on this host (live arms; run on the brain)"
elif [ "$MODE" = "local" ]; then
  # Positive controls FIRST: a probe that cannot succeed is a probe that
  # proves nothing. herdr CAN write its own home (else every agent is broken)
  # and CAN read the stack secrets file's PARENT list — the negative arms only
  # mean something when the positive one fires.
  if sudo -u herdr sh -c "test -w '$HERDR/worktrees'" 2>/dev/null; then
    pass "positive control: the herdr user can write its own worktrees"
  else
    fail "positive control failed: the herdr user cannot write $HERDR/worktrees — the isolation arms below are meaningless"
  fi
  if sudo -u herdr sh -c "test -r '$SECRETS_FILE'" 2>/dev/null; then
    fail "the herdr user can read $SECRETS_FILE (T8/TN3) — the stack secrets must be 0600 agent"
  else
    pass "the herdr user cannot read $SECRETS_FILE"
  fi
  if sudo -u herdr sh -c "test -w '$DATA_ROOT'" 2>/dev/null; then
    fail "the herdr user can write $DATA_ROOT (TN2) — the namespace or the permissions regressed"
  else
    pass "the herdr user cannot write $DATA_ROOT (TN2)"
  fi
  if [ -d "$DATA_ROOT/life-vault" ]; then
    if sudo -u herdr sh -c "test -r '$DATA_ROOT/life-vault'" 2>/dev/null; then
      fail "the herdr user can read $DATA_ROOT/life-vault — Tier-3 data is never in agent reach (docs/privacy.md)"
    else
      pass "the herdr user cannot read the life vault (dir present on this brain)"
    fi
  else
    note "no $DATA_ROOT/life-vault on this brain (repo-side vault code left with the automations removal)"
  fi
  if sudo -u herdr sh -c "test -w /home/agent" 2>/dev/null; then
    fail "the herdr user can write /home/agent (TN2) — home directories should be 0750"
  else
    pass "the herdr user cannot write /home/agent (TN2)"
  fi
  # TN1: not in the sudo group, and no sudoers drop-in names it.
  if brain_exec id -nG herdr 2>/dev/null | grep -qw sudo; then
    fail "the herdr user is in the sudo group (TN1)"
  else
    pass "the herdr user is not in the sudo group (TN1)"
  fi
  if brain_exec sh -c "grep -rl herdr /etc/sudoers.d/ 2>/dev/null | grep -q ." 2>/dev/null; then
    fail "a /etc/sudoers.d drop-in mentions herdr (TN1) — the installer must never grant it passwordless sudo"
  else
    pass "no sudoers drop-in grants herdr anything (TN1)"
  fi
  # The ptrace arm (Ubuntu 24.04): the kernel must block cross-user
  # environment reads, which is what keeps the herdr user out of agent's
  # process environments. Linux-only by construction (yama is a kernel
  # setting; a Mac reports nothing and skips rather than failing).
  if [ -r /proc/sys/kernel/yama/ptrace_scope ]; then
    PTRACE_SCOPE="$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo 0)"
    if [ "${PTRACE_SCOPE:-0}" -ge 1 ] 2>/dev/null; then
      pass "kernel ptrace_scope=$PTRACE_SCOPE — cross-user process environments are blocked"
    else
      fail "kernel ptrace_scope=${PTRACE_SCOPE:-unknown} — a herdr pane could read other users' process environments
       (Ubuntu 24.04 ships 1; investigate before running agents)"
    fi
  else
    skip "ptrace scope — /proc/sys/kernel/yama/ptrace_scope not readable (Linux-only live arm)"
  fi
fi

# ---- 9. no TCP listener (UN1) -----------------------------------------------
if ! brain_exec sh -c "command -v ss >/dev/null 2>&1" 2>/dev/null; then
  skip "TCP listener check — ss is not available on this host (UN1's live arm)"
elif brain_exec sh -c "ss -tlnp 2>/dev/null | grep -q herdr" 2>/dev/null; then
  fail "a herdr process is LISTENING on TCP — the whole API is a 0600 Unix socket (UN1)"
else
  pass "no herdr process listens on TCP (UN1)"
fi

# ---- 10. directories + worktree root (T7) -----------------------------------
DIRS_OK=1
for d in config state repos worktrees; do
  if ! brain_exec test -d "$HERDR/$d" 2>/dev/null; then
    DIRS_OK=0
    fail "$HERDR/$d missing (T7) — re-run deploy-vps.sh --only herdr"
  fi
done
if [ "$DIRS_OK" = "1" ]; then
  pass "config/, state/, repos/, worktrees/ all present (T7)"
fi
if brain_exec grep -qF "directory = \"$HERDR/worktrees\"" "$herdr_cfg" 2>/dev/null; then
  pass "worktrees root is $HERDR/worktrees in the live config (T7)"
else
  fail "worktrees root is not $HERDR/worktrees in the live config (T7)"
fi

# ---- 11. disk gate (T9) ------------------------------------------------------
if [ "$MODE" = "local" ]; then
  USED_KB="$(du -sk "$HERDR" 2>/dev/null | cut -f1 || echo 0)"
  [ -n "$USED_KB" ] || USED_KB=0
  TOTAL_KB="$(df -Pk "$DATA_ROOT" 2>/dev/null | awk 'NR==2 {print $2}' || echo 0)"
  [ -n "$TOTAL_KB" ] || TOTAL_KB=0
  HERDR_MAX_DISK_PCT="${HERDR_MAX_DISK_PCT:-75}"
  if [ "$TOTAL_KB" -gt 0 ]; then
    CEILING_KB=$((TOTAL_KB * HERDR_MAX_DISK_PCT / 100))
    CEILING_DESC="${HERDR_MAX_DISK_PCT}% of the $((TOTAL_KB / 1024 / 1024))GB $DATA_ROOT volume"
    USED_DESC="$((USED_KB / 1024 / 1024)).$(( (USED_KB * 10 / 1024 / 1024) % 10 ))GB"
    if [ "$USED_KB" -lt "$CEILING_KB" ]; then
      pass "herdr footprint ${USED_DESC} < ${CEILING_DESC} (T9)"
    else
      fail "herdr footprint ${USED_DESC} (>= ${CEILING_DESC}) — grow data_volume_size or clean old worktrees (T9)"
    fi
  else
    skip "cannot size $DATA_ROOT (df returned nothing) — herdr at ${USED_KB}KB (T9)"
  fi
fi

# ---- 12. clone-vs-worktree (T10) --------------------------------------------
# repos/ is reference-only and worktrees hold checkouts; a real clone that
# landed in worktrees wastes the volume (a full object store per task). The
# tell is the .git entry: a worktree carries a .git FILE, a clone a .git DIR.
if brain_exec sh -c "find '$HERDR/worktrees' -type d -name .git 2>/dev/null | grep -q ." 2>/dev/null; then
  fail "a .git DIRECTORY exists under $HERDR/worktrees — that is a clone, not a worktree (T10)
       Clone into $HERDR/repos (reference-only) and create worktrees from it;
       'herdr worktree create' never lands a .git directory here."
else
  pass "no clone landed in worktrees (every .git entry is a worktree's file) (T10)"
fi

# ---- 13. manual checklist ----------------------------------------------------
cat <<'EOF'

== manual checklist — the things only you can verify ==

  [ ] Attach from the Mac: `herdr machine add herdr@<brain>` — the SSH target
      is the herdr USER (the server's own user owns the 0600 socket; sshing as
      agent cannot reach it). Your Mac's public key must be in
      /data/herdr/.ssh/authorized_keys first (docs/setup/70-coding-agents.md §4).
  [ ] OpenCode/Pi panes resume after a server restart (session ids restored) —
      a recorded observation, not an automated arm: a routine check must never
      restart the server.
  [ ] A clone pointed outside /data/herdr fails, and clones land under it —
      the intended boundary (epic §5).
  [ ] External port scan still clean: ./scripts/verify/check-security.sh <server-public-ip>
  [ ] The legacy container plane is fully torn down by hand if this brain ever
      ran it — check-brain.sh's legacy arm is the completion signal (spec §8).
EOF

finish --skips