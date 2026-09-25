#!/usr/bin/env bash
# test-verify-checks.sh — the harness for the check-*.sh scripts themselves.
#
# WHY THIS FILE EXISTS. scripts/verify/ is where this repo keeps its assertions,
# and until now nothing asserted anything ABOUT them: bootstrap-mac.sh has
# test-base-install.sh, deploy-vps.sh has test-deploy-vps.sh, doctor.py has
# test-pai.sh, and the check-*.sh had a shellcheck pass. So check-mcp.sh could
# hold a smoke-test roster that no longer matched the extensions it claimed to
# cover, and nothing noticed.
#
# THE FIXTURES ARE GENERATED, NOT COMMITTED — same rule as test-pai.sh:7-13. A
# committed config.yaml would be asserting yesterday's template. Every fixture
# here is written at run time and every one is a SHAPE, not a copy: an enabled
# extension with no smoke test, a config with no connectors at all. Copying the
# repo's own artifacts would make these assertions true by
# whatever the repo happens to ship this month.
#
# Nothing here reaches the network, opens a socket, spawns goose, or writes
# outside $WORK. The `goose` these checks run is a stub that records its argv
# and exits 0. check-herdr.sh's herdr plane is likewise fixtures: a fake
# /data/herdr tree, a fake systemd dir, and no binary, service or network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pai-checks.XXXXXX")"
cleanup() { rm -rf "$WORK"; return 0; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

# shellcheck source=scripts/verify/lib.sh
. "$HERE/lib.sh"

usage() {
  cat <<'EOF'
Usage: test-verify-checks.sh [--help]

Drives scripts/verify/check-mcp.sh, check-security.sh, check-brain.sh and
check-herdr.sh against generated fixtures. Offline; no goose, no herdr
server, no network, no credentials.
Exit: 0 ok, 1 findings, 2 usage.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) die_usage "unknown argument: $1" ;;
esac

# A goose that answers every run identically and records what it was asked.
# It must NEVER echo anything the caller passed as a credential; it does not
# receive one, and the assertion below is that its argv holds no secret.
GOOSE_STUB="$WORK/goose"
cat > "$GOOSE_STUB" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/goose-argv.log"
echo "stub goose: nothing real happened"
exit 0
EOF
chmod +x "$GOOSE_STUB"

# write_config <path> <yaml...> — a live goose config.yaml fixture on stdin.
write_config() {
  mkdir -p "$(dirname "$1")"
  cat > "$1"
  return 0
}

run_check() { # run_check <script> [args...]  -> RC_OUT / RC_CODE
  local script="$1"
  shift
  RC_CODE=0
  RC_OUT="$("$script" "$@" 2>&1)" || RC_CODE=$?
  return 0
}

saw() { # saw <label> <needle>
  if printf '%s\n' "$RC_OUT" | grep -qF -- "$2"; then
    pass "$1"
  else
    fail "$1 — no line matched: $2"$'\n'"$RC_OUT"
  fi
  return 0
}

absent() { # absent <label> <needle>
  if printf '%s\n' "$RC_OUT" | grep -qF -- "$2"; then
    fail "$1 — should not appear: $2"$'\n'"$RC_OUT"
  else
    pass "$1"
  fi
  return 0
}

echo "== test-verify-checks: the check scripts, against generated fixtures =="

# ---- 1. check-mcp.sh derives its roster from the live config ----------------
echo
echo "-- check-mcp.sh --"

# An enabled extension that declares an MCP server and has NO smoke test here.
# This is the shape the three hardcoded services could never report: before,
# enabling `tavily` was smoke-tested by nothing and nothing said so.
#
# THE BUILTIN AND THE PLATFORM ENTRY CARRY A `cmd:` ON PURPOSE, and that is the
# only reason the type exclusion is tested at all. With the bare `type: builtin,
# enabled: true` shape this fixture used to have, the `if not (cmd or uri)`
# guard excluded `developer` on its own -- so deleting the builtin/platform
# exclusion outright left this file at 28 passed, 0 failed (verified). A
# hand-edited or half-migrated config really does carry both, which is exactly
# when the two predicates have to disagree and the type has to win.
write_config "$WORK/mcp-unknown.yaml" <<'EOF'
extensions:
  developer:
    name: developer
    type: builtin
    cmd: goose-mcp-developer
    enabled: true
  apps:
    name: apps
    type: platform
    cmd: goose-mcp-apps
    enabled: true
  tavily:
    name: tavily
    type: stdio
    cmd: uvx
    enabled: true
EOF
# No readable config anywhere. PAI_GOOSE_CONFIG naming a file that does not
# exist, rather than merely leaving it unset: unset would fall through to the
# real $HOME and to /data/goose/config/config.yaml, so on the brain -- the one
# host this matters on -- the assertion would silently be about a real config.
PAI_GOOSE_CONFIG="$WORK/no-such-config.yaml" GOOSE_BIN="$GOOSE_STUB" \
  run_check "$HERE/check-mcp.sh"
if [ "$RC_CODE" -eq 2 ]; then
  pass "check-mcp exits 2 (precondition) when no live config resolves"
else
  fail "check-mcp exited $RC_CODE with no config to read:"$'\n'"$RC_OUT"
fi

PAI_GOOSE_CONFIG="$WORK/mcp-unknown.yaml" GOOSE_BIN="$GOOSE_STUB" \
  run_check "$HERE/check-mcp.sh"
saw "an enabled MCP extension with no smoke test FAILs, naming itself" \
  "FAIL  tavily is enabled and declares an MCP server, but check-mcp.sh has no smoke test"
absent "a builtin carrying a cmd is still not held to the smoke-test rule" \
  "developer is enabled"
absent "...and neither is a platform extension carrying one" "apps is enabled"
if [ "$RC_CODE" -eq 1 ]; then
  pass "...and that is a finding, not a skip"
else
  fail "check-mcp exited $RC_CODE on the unknown-extension fixture:"$'\n'"$RC_OUT"
fi

# The same file with the extension DISABLED. Nothing about the machine changed
# except the flag, and the verdict must move — otherwise the rule is reading the
# file's existence rather than its content.
write_config "$WORK/mcp-off.yaml" <<'EOF'
extensions:
  developer:
    name: developer
    type: builtin
    enabled: true
  tavily:
    name: tavily
    type: stdio
    cmd: uvx
    enabled: false
EOF
PAI_GOOSE_CONFIG="$WORK/mcp-off.yaml" GOOSE_BIN="$GOOSE_STUB" \
  run_check "$HERE/check-mcp.sh"
absent "the same extension disabled is not a finding" "no smoke test"
saw "a connector this machine does not have is a SKIP, not a failure" \
  "SKIP  todoist — not enabled"
if [ "$RC_CODE" -eq 0 ]; then
  pass "...and a machine with no connectors passes check-mcp"
else
  fail "check-mcp exited $RC_CODE on a machine with no connectors:"$'\n'"$RC_OUT"
fi

# An enabled extension that declares NEITHER cmd NOR uri is a config entry, not
# a server. Scoping the rule this way is what keeps `developer` and `memory` --
# which ship enabled and can have no smoke prompt -- out of it without an
# exempt-list, i.e. without a hand-maintained roster inside the fix.
write_config "$WORK/mcp-noserver.yaml" <<'EOF'
extensions:
  notaserver:
    name: notaserver
    type: stdio
    enabled: true
EOF
PAI_GOOSE_CONFIG="$WORK/mcp-noserver.yaml" GOOSE_BIN="$GOOSE_STUB" \
  run_check "$HERE/check-mcp.sh"
absent "an enabled extension declaring no cmd/uri is not an MCP server" "notaserver"

# The enabled one WITH a smoke test actually runs it, through the seam.
write_config "$WORK/mcp-todoist.yaml" <<'EOF'
extensions:
  todoist:
    name: todoist
    type: stdio
    uri: https://ai.todoist.net/mcp
    enabled: true
EOF
: > "$WORK/goose-argv.log"
PAI_GOOSE_CONFIG="$WORK/mcp-todoist.yaml" GOOSE_BIN="$GOOSE_STUB" \
  run_check "$HERE/check-mcp.sh"
saw "an enabled extension with a known smoke test runs it" "PASS  Todoist (ai.todoist.net)"
if [ "$(grep -c . "$WORK/goose-argv.log")" = "1" ]; then
  pass "...and exactly one goose run happened"
else
  fail "goose ran $(grep -c . "$WORK/goose-argv.log") time(s):"$'\n'"$(cat "$WORK/goose-argv.log")"
fi

# ---- 2. check-security.sh --------------------------------------------------
echo
echo "-- check-security.sh --"

# The off-brain guard. brain.yaml's verify entry is `check-security.sh --local`
# and `pai verify` derives its roster on EVERY host, so this path runs on a Mac
# too -- where /data, ufw and the `agent` user do not exist and every verdict
# below would be about a machine the script is not looking at.
PAI_MODE=remote run_check "$HERE/check-security.sh" --local
if [ "$RC_CODE" -eq 2 ]; then
  pass "--local off the brain is exit 2 (precondition), not four false FAILs"
else
  fail "check-security --local off-brain exited $RC_CODE:"$'\n'"$RC_OUT"
fi
saw "...and it points at the mode that DOES work from here" "terraform output -raw server_public_ip"

# A live config with connectors: sections are named and counted separately.
write_config "$WORK/sec-home/.config/goose/config.yaml" <<'EOF'
extensions:
  apps:
    name: apps
    type: platform
    enabled: false
  todoist:
    name: todoist
    type: stdio
    uri: https://ai.todoist.net/mcp
    available_tools: [get-tasks, add-task]
    enabled: true
EOF
PAI_MODE=local PAI_HOME="$WORK/sec-home" HOME="$WORK/sec-home" \
  run_check "$HERE/check-security.sh" --local
saw "host posture is a named section" "host posture "
saw "connector policy is its own named section" "connector policy "
saw "...and platform posture is a third" "goose platform posture "
saw "a hardened connector passes the policy section" \
  "PASS  all 1 enabled MCP extension(s) carry a non-empty available_tools allowlist"
if printf '%s\n' "$RC_OUT" | grep -q "^  host posture  *[0-9]* passed, [1-9]"; then
  pass "...while host posture fails on its own, in its own row"
else
  fail "the section recap did not separate the two:"$'\n'"$RC_OUT"
fi

# THE ACCEPTANCE CRITERION: a machine with no connectors is not penalised for
# the connector rule. Before, a missing allowlist entry was an unconditional
# finding, so a brain that simply never enabled a connector was red.
#
# `developer` and `computercontroller` carry a `cmd:` for the same reason
# check-mcp's fixture does: check-security.sh's `declared` loop applies the same
# two predicates, and with no `cmd:` the `cmd or uri` guard alone kept this
# machine's connector list empty -- deleting the builtin/platform exclusion from
# BOTH files left this file at 28 passed, 0 failed (verified). With the cmd
# present, dropping that exclusion puts two entries in `declared`, each with no
# `available_tools`, and the SKIP below becomes two FAILs.
write_config "$WORK/sec-none/.config/goose/config.yaml" <<'EOF'
extensions:
  apps:
    name: apps
    type: platform
    enabled: false
  computercontroller:
    name: computercontroller
    type: platform
    cmd: goose-mcp-computercontroller
    enabled: true
  developer:
    name: developer
    type: builtin
    cmd: goose-mcp-developer
    enabled: true
EOF
PAI_MODE=local PAI_HOME="$WORK/sec-none" HOME="$WORK/sec-none" \
  run_check "$HERE/check-security.sh" --local
saw "no connectors: the policy section SKIPs instead of failing" \
  "SKIP  no enabled extension in"
# Not "no FAIL line": the enabled connector must not be MENTIONED. The section
# returns before the entry even exists as a subject, and under the rule this
# replaces its absence was an unconditional finding on exactly this fixture.
absent "...and does not name a connector at all" "todoist"
if printf '%s\n' "$RC_OUT" | grep -q "^  connector policy  *0 passed, 0 failed, 1 skipped"; then
  pass "...and the recap row says so"
else
  fail "connector policy was not a clean skip:"$'\n'"$RC_OUT"
fi

# An unreadable live config stays a FAIL. It is the one state where "no
# candidate readable" and "readable but wrong" must not collapse into a skip:
# goose would run on upstream defaults with the apps extension ON.
mkdir -p "$WORK/sec-bad/.config/goose"
printf 'extensions: [unclosed\n' > "$WORK/sec-bad/.config/goose/config.yaml"
PAI_MODE=local PAI_HOME="$WORK/sec-bad" HOME="$WORK/sec-bad" \
  run_check "$HERE/check-security.sh" --local
# The VERDICT PREFIX is part of the needle. Without it this matched the same
# sentence emitted as a SKIP, so demoting the verdict — the exact regression
# worth catching — left the assertion green.
saw "an unparseable live config is a FAIL, never a skip" \
  "FAIL  live goose config.yaml"
saw "...and says what the parser choked on" "is unreadable or not valid YAML"

# The port roster is closed over the code that binds the ports. It is a literal
# in check-security.sh and the only port the repo still BINDS is goose serve's
# SERVE_PORT in deploy-vps.sh — herdr binds no TCP at all (its whole API is a
# 0600 Unix socket, UN1), and the container plane that bound 4300/4310 is gone.
# The scan keeps 4300/4310 anyway: a legacy brain that still runs the old plane
# must stay red until the manual teardown lands, which is the expectation list's
# job even though nothing binds those ports any more.
PORTS_LINE="$(grep -n '^PORTS=' "$HERE/check-security.sh" | head -n1)"
MISSING_PORTS=""
# shellcheck disable=SC2046  # the substitution is the WORD LIST
for port in $(sed -n 's/^SERVE_PORT=\([0-9]*\).*/\1/p' "$REPO_ROOT/scripts/vps/deploy-vps.sh" | head -n1)
do
  [ -n "$port" ] || { MISSING_PORTS="$MISSING_PORTS <unreadable-source>"; continue; }
  case " $PORTS_LINE " in
    *" $port "*|*"\"$port "*|*" $port\""*) ;;
    *) MISSING_PORTS="$MISSING_PORTS $port" ;;
  esac
done
if [ -z "$MISSING_PORTS" ]; then
  pass "every port this repo binds is in check-security.sh's PORTS probe"
else
  fail "PORTS is missing:$MISSING_PORTS"
  note "$PORTS_LINE"
  note "Source: deploy-vps.sh's SERVE_PORT (herdr binds no TCP — UN1)."
fi

# ---- 3b. herdr.service binds no TCP (the static half of UN1) -----------------
if [ -s "$REPO_ROOT/scripts/vps/systemd/herdr.service" ] && \
   ! grep -qE 'ListenStream|--port|0\.0\.0\.0|--host' "$REPO_ROOT/scripts/vps/systemd/herdr.service"; then
  pass "herdr.service names no TCP listener — the whole API is the 0600 socket (UN1, static half)"
else
  fail "herdr.service missing or carries a TCP-listening shape — UN1's static arm is dead"
fi

# ---- 3. nothing leaked into a log ------------------------------------------
# The stub goose records every argv it saw. No credential is ever passed to
# these checks, and none may appear in what they run: the standing rule that
# a credential reaches a process through the environment, never argv.
if [ -s "$WORK/goose-argv.log" ] && ! grep -qiE '(api[_-]?key|secret|password|token)[=: ]' "$WORK/goose-argv.log"; then
  pass "no credential-shaped word reached the goose argv these checks build"
else
  fail "the goose argv log is empty or holds a credential-shaped word"
fi

# ---- 4. check-herdr.sh — skip precondition + fixture-driven arms ------------
echo
echo "-- check-herdr.sh --"

# WHAT THIS SECTION PROVES, AND WHAT IT DOES NOT. check-herdr.sh's live arms —
# service state, systemd namespace properties, the 0600 socket, the isolation
# probes, the disk gate — mean something only on a real brain. What is asserted
# here is the split every other check's harness draws: the SKIP precondition
# fires, the arms FIRE on populated fixtures (the exact-set derivation, the
# goose-secret refusal, the clone-in-worktrees tell, the six-key config), and
# the installer and the check cannot drift apart on the catalog, the env rules
# or the pins. THE FIXTURES ARE NOT A SANDBOX: nothing below says anything
# about a real herdr server — only check-herdr.sh on the brain says that.

# 4a. the SKIP precondition (exit 2), on a host with no plane at all.
PAI_MODE=local \
PAI_DATA_ROOT="$WORK/none/data" \
PAI_SYSTEMD_DIR="$WORK/none/systemd" \
  run_check "$HERE/check-herdr.sh"
if [ "$RC_CODE" -eq 2 ]; then
  pass "check-herdr.sh exits 2 (SKIP) when the plane was never installed"
else
  fail "check-herdr.sh exited $RC_CODE, want 2 — 'pai verify' would FAIL for a unit nobody installed"
fi
saw "the SKIP names the deploy flag that selects the plane" \
  "without '--with herdr'"

# 4b. the catalog drift-lock: AGENT_CATALOG in deploy-vps.sh and the case arms
# in check-herdr.sh must name exactly the same ids — an id in one and not the
# other means an agent the installer records but no check verifies (or vice
# versa). deploy's ids use hyphens; the check's pin keys use underscores
# (YAML keys), so both sides are normalised to underscores before comparing.
DEPLOY_CATALOG="$(sed -n 's/^AGENT_CATALOG="\(.*\)"/\1/p' "$REPO_ROOT/scripts/vps/deploy-vps.sh" | head -n1)"
[ -n "$DEPLOY_CATALOG" ] || fail "AGENT_CATALOG not readable in deploy-vps.sh — the drift-lock is inert"
CHECK_IDS="$(sed -n 's/.*pin_key="\([a-z_]*\)".*/\1/p' "$HERE/check-herdr.sh" | grep -v '^$' | sort -u)"
# shellcheck disable=SC2086  # the catalog is a word list on purpose
DEPLOY_IDS="$(printf '%s\n' $DEPLOY_CATALOG | tr '-' '_' | sort -u)"
if [ -n "$(comm -3 <(printf '%s\n' "$DEPLOY_IDS") <(printf '%s\n' "$CHECK_IDS") | tr -d ' \n')" ]; then
  fail "AGENT_CATALOG and check-herdr.sh's case arms disagree:
       installer-only: $(comm -23 <(printf '%s\n' "$DEPLOY_IDS") <(printf '%s\n' "$CHECK_IDS") | tr '\n' ' ')
       check-only:     $(comm -13 <(printf '%s\n' "$DEPLOY_IDS") <(printf '%s\n' "$CHECK_IDS") | tr '\n' ' ')"
else
  pass "AGENT_CATALOG and check-herdr.sh's case arms name the same agent ids"
fi

# 4c. the pins closure: every catalog id has a coding_agents pin row, and the
# herdr section pins a version — a pin the installer reads as absent fails the
# deploy, but a MISSING ROW for one agent would fail only that agent, mid-deploy.
PINS_MISSING=""
for id in $DEPLOY_IDS; do
  grep -q "^  $id:" "$REPO_ROOT/config/pins.yaml" || PINS_MISSING="$PINS_MISSING $id"
done
if [ -z "$PINS_MISSING" ] && grep -q '^herdr:' "$REPO_ROOT/config/pins.yaml"; then
  pass "config/pins.yaml has a coding_agents row for every catalog id and a herdr pin"
else
  fail "config/pins.yaml missing:${PINS_MISSING:- (herdr section)} — the #138 rule is one pin per installable CLI"
fi

# 4d. the fixture tree. Populated CORRECTLY first: service active, config with
# all six keys, agents.list with opencode, the env copy with exactly the rows
# the rules derive, socket 0600 herdr, worktrees holding only worktrees.
HF="$WORK/herdr-fixture"
mkdir -p "$HF/data/herdr/config/herdr" "$HF/data/herdr/state" "$HF/data/herdr/repos" \
         "$HF/data/herdr/worktrees" "$HF/data/secrets.env.d" "$HF/systemd"
HF_DATA="$HF/data"; HF_HERDR="$HF_DATA/herdr"
cp "$REPO_ROOT/scripts/vps/systemd/herdr.service" "$HF/systemd/herdr.service"
# The template's worktrees root is the REAL brain path (/data/herdr); the
# fixture root is a temp dir, so the fixture config gets the path substituted
# — every other key stays template-exact.
sed 's|/data/herdr|'"$HF_HERDR"'|g' "$REPO_ROOT/config/herdr/config.toml" \
  >"$HF_HERDR/config/herdr/config.toml"
printf '# record\nopencode\n' >"$HF_HERDR/config/agents.list"
{
  echo "TOGETHER_API_KEY=$(openssl rand -hex 12)"
  echo "GITHUB_CODE_AGENT_PAT=$(openssl rand -hex 12)"
  echo "GOOSE_SERVER__SECRET_KEY=$(openssl rand -hex 12)"
} >"$HF_DATA/secrets.env"
HF_SECRETS="$HF_HERDR/secrets.env"
# The correct env for the opencode pick: TOGETHER + the PAT.
{
  echo "TOGETHER_API_KEY=$(openssl rand -hex 12)"
  echo "GITHUB_CODE_AGENT_PAT=$(openssl rand -hex 12)"
} >"$HF_SECRETS"
chmod 600 "$HF_SECRETS"
: >"$HF_HERDR/config/herdr/herdr.sock"; chmod 600 "$HF_HERDR/config/herdr/herdr.sock"

run_hf() { # run_hf <data-root> — check-herdr.sh against a fixture root
  PAI_MODE=local \
  PAI_DATA_ROOT="$1" \
  PAI_SYSTEMD_DIR="$HF/systemd" \
  PAI_REPO_DIR="$REPO_ROOT" \
  run_check "$HERE/check-herdr.sh"
}
# `sudo -u herdr` and systemd do not exist on this host; the live arms detect
# that and SKIP (they are live-check arms). The fixture arms below are the
# ones a fixture can genuinely drive: exact-set, socket, config keys,
# worktrees, unit-file equality.
run_hf "$HF_DATA"
if [ "$RC_CODE" -eq 0 ]; then
  pass "check-herdr.sh is GREEN on a correct fixture (every live arm skipped cleanly)"
else
  fail "check-herdr.sh exited $RC_CODE on a CORRECT fixture — a fixture arm fires on the shape it should pass:"$'\n'"$RC_OUT"
fi
# The exact-set arm must PASS on the correct env, and the pick's required key
# must be derivable.
saw "the exact-set arm passes on the correct opencode env" \
  "herdr env set matches agents.list-derived expectation"
saw "the agents.list arm names the picked agent" \
  "agents.list present (1 agent(s): opencode"
absent "the goose secret never belongs in the herdr env" \
  "GOOSE_SERVER__SECRET_KEY is in the herdr env"
# The config arm fires on the real template: every key found.
saw "the six-key config arm passes on the template fixture" \
  "config.toml: all six keys explicit and correct"
absent "...and nothing reports a wrong worktree root" \
  "worktrees root is not"
saw "the live arms SKIP on a fixture host instead of failing" \
  "SKIP  herdr.service active — systemd cannot see the unit on this host"

# THE BROKEN INPUT: a leaked goose secret in the herdr env. The exact-set arm
# alone would catch it only as a set difference — the dedicated arm names it.
{
  echo "TOGETHER_API_KEY=$(openssl rand -hex 12)"
  echo "GITHUB_CODE_AGENT_PAT=$(openssl rand -hex 12)"
  echo "GOOSE_SERVER__SECRET_KEY=$(openssl rand -hex 12)"
} >"$HF_SECRETS"
run_hf "$HF_DATA"
saw "a goose secret in the herdr env FAILs and names the row" \
  "GOOSE_SERVER__SECRET_KEY is in the herdr env"
{
  echo "TOGETHER_API_KEY=$(openssl rand -hex 12)"
  echo "GITHUB_CODE_AGENT_PAT=$(openssl rand -hex 12)"
} >"$HF_SECRETS"

# THE SECOND BROKEN INPUT: an env missing its picked row (someone hand-edited
# agents.list, or the key left secrets.env). The exact-set arm must say which.
{
  echo "GITHUB_CODE_AGENT_PAT=$(openssl rand -hex 12)"
} >"$HF_SECRETS"
run_hf "$HF_DATA"
saw "a missing TOGETHER row FAILs as a set mismatch" \
  "herdr env set does not match agents.list-derived expectation"
saw "...and names the missing row" "missing: TOGETHER_API_KEY"
{
  echo "TOGETHER_API_KEY=$(openssl rand -hex 12)"
  echo "GITHUB_CODE_AGENT_PAT=$(openssl rand -hex 12)"
} >"$HF_SECRETS"

# 4d. the clone-vs-worktree tell (T10): a .git DIRECTORY under worktrees is a
# clone and must fail, a .git FILE is a worktree and must not.
mkdir -p "$HF_HERDR/worktrees/task-1"
printf 'gitdir: /data/herdr/repos/x/.git/worktrees/task-1\n' >"$HF_HERDR/worktrees/task-1/.git"
run_hf "$HF_DATA"
saw "a worktree's .git FILE does not trip the clone arm (T10)" \
  "no clone landed in worktrees"
rm -f "$HF_HERDR/worktrees/task-1/.git"
mkdir -p "$HF_HERDR/worktrees/clone-1/.git"
run_hf "$HF_DATA"
saw "a .git DIRECTORY under worktrees FAILs as a clone (T10)" \
  "a .git DIRECTORY exists under"
saw "...and says where a clone belongs" "repos (reference-only)"
rm -rf "$HF_HERDR/worktrees/clone-1"

# 4e. the namespace contract is asserted BYTE-FOR-BYTE off the unit file (the
# systemctl arms are live): removing a single hardening line must FAIL the
# equality arm. sed -i is not portable (BSD needs a backup suffix), so the
# rewrite goes through a copy.
sed 's|^TemporaryFileSystem=/data:ro$|# removed for the harness|' \
  "$REPO_ROOT/scripts/vps/systemd/herdr.service" >"$HF/systemd/herdr.service"
run_hf "$HF_DATA"
if [ "$RC_CODE" -ne 0 ]; then
  pass "a unit file that lost one hardening line goes RED"
else
  fail "check-herdr.sh stayed green with a mutilated herdr.service"
fi
saw "...and the unit-file equality arm names the template" \
  "differs from scripts/vps/systemd/herdr.service"

# 4f. the unit-file equality arm on a cosmetic edit: ANY drift from the
# template is red — the hardening set is one contract, not a menu.
printf '# tampered\n' >>"$HF/systemd/herdr.service"
run_hf "$HF_DATA"
saw "a drifted unit file FAILs against the repo template" \
  "differs from scripts/vps/systemd/herdr.service"
cp "$REPO_ROOT/scripts/vps/systemd/herdr.service" "$HF/systemd/herdr.service"

# 5. THE FRONT DOOR SCHEDULES NOTHING. The #137 flow's guarantee: the wizard
# drives only the two installers and writes only the local .env — it carries
# none of the strings a SCHEDULER would need. The teardown checklist it prints
# for an existing brain legitimately names schedule-removal lines, so the list
# is the strings that CREATE or re-arm automation — the ones the automations
# pivot (#136/#143) deleted from the repo, plus the goose scheduler flag the
# pivot dropped — and none of those are removal-shaped.
WIZARD="$REPO_ROOT/scripts/wizard/setup.sh"
SCHED_HITS=""
for bad_string in "--enable-scheduler" "register-schedules" "run-recipe" \
                  "notify_failure" "crontab" "anacron" "brew services start"; do
  if grep -qF -- "$bad_string" "$WIZARD"; then
    SCHED_HITS="$SCHED_HITS $bad_string"
  fi
done
if [ -z "$SCHED_HITS" ]; then
  pass "the front-door wizard carries no scheduler-shaped string"
else
  fail "the front-door wizard mentions:$SCHED_HITS — nothing schedules anything"
fi

finish --skips
