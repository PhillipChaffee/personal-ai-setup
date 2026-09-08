#!/usr/bin/env bash
# test-verify-checks.sh — the harness for the check-*.sh scripts themselves.
#
# WHY THIS FILE EXISTS. scripts/verify/ is where this repo keeps its assertions,
# and until now nothing asserted anything ABOUT them: bootstrap-mac.sh has
# test-base-install.sh, code-agent-manager.py has test-code-agent-manager.sh,
# doctor.py has test-pai.sh, and the nine check-*.sh had a shellcheck pass. So
# check-brain.sh could derive an EMPTY roster from register-schedules.sh and
# report "all 0 schedule(s)" as a PASS, and nothing noticed.
#
# THE FIXTURES ARE GENERATED, NOT COMMITTED — same rule as test-pai.sh:7-13. A
# committed config.yaml would be asserting yesterday's template. Every fixture
# here is written at run time and every one is a SHAPE, not a copy: an enabled
# extension with no smoke test, a config with no connectors at all, an indented
# ORDER=(. Copying the repo's own artifacts would make these assertions true by
# whatever the repo happens to ship this month.
#
# Nothing here reaches the network, spawns goose, or writes outside $WORK.
# The `goose` these checks run is a stub that records its argv and exits 0.
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

Drives scripts/verify/check-mcp.sh, check-security.sh and check-brain.sh
against generated fixtures. Offline; no goose, no network, no credentials.
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
  "SKIP  workspace-mcp — not enabled"
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
write_config "$WORK/mcp-ws.yaml" <<'EOF'
extensions:
  workspace-mcp:
    name: workspace-mcp
    type: stdio
    cmd: uvx
    enabled: true
EOF
: > "$WORK/goose-argv.log"
PAI_GOOSE_CONFIG="$WORK/mcp-ws.yaml" GOOSE_BIN="$GOOSE_STUB" USER_GOOGLE_EMAILS="a@b.test,c@d.test" \
  run_check "$HERE/check-mcp.sh"
saw "one smoke run per account in USER_GOOGLE_EMAILS" "PASS  Gmail (a@b.test)"
saw "...including the second account" "PASS  Gmail (c@d.test)"
if [ "$(grep -c . "$WORK/goose-argv.log")" = "2" ]; then
  pass "...and exactly two goose runs happened, not one"
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
  workspace-mcp:
    name: workspace-mcp
    type: stdio
    cmd: uvx
    args: [workspace-mcp, --permissions]
    available_tools: [search_gmail_messages]
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
# the connector rule. Before, `workspace-mcp` missing was an unconditional
# finding, so a brain that simply never installed google-workspace was red.
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
# Not "no FAIL line": workspace-mcp must not be MENTIONED. The section returns
# before the entry even exists as a subject, and under the rule this replaces
# its absence was an unconditional finding on exactly this fixture.
absent "...and does not mention workspace-mcp at all" "workspace-mcp"
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
# in check-security.sh and the defaults live in code-agent-manager.py; nothing
# joined them, and the two code-plane ports were missing from the probe entirely
# until somebody noticed by hand.
PORTS_LINE="$(grep -n '^PORTS=' "$HERE/check-security.sh" | head -n1)"
MISSING_PORTS=""
for port in \
  "$(sed -n 's/.*CODE_AGENT_PORT", "\([0-9]*\)".*/\1/p' "$REPO_ROOT/scripts/vps/code-agent-manager.py" | head -n1)" \
  "$(sed -n 's/.*CODE_AGENT_BASE_CHAT_PORT", "\([0-9]*\)".*/\1/p' "$REPO_ROOT/scripts/vps/code-agent-manager.py" | head -n1)" \
  "$(sed -n 's/^SERVE_PORT=\([0-9]*\).*/\1/p' "$REPO_ROOT/scripts/vps/deploy-vps.sh" | head -n1)"
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
  note "Sources: code-agent-manager.py's CODE_AGENT_PORT / CODE_AGENT_BASE_CHAT_PORT"
  note "defaults and deploy-vps.sh's SERVE_PORT."
fi

# ---- 3. check-brain.sh's derived schedule roster ---------------------------
echo
echo "-- check-brain.sh --"

# check-brain.sh reads register-schedules.sh from a path relative to its OWN
# location, so the fixture is a two-file copy of that layout: the check, lib.sh
# beside it, and a register-schedules.sh whose ORDER=( is malformed.
BR="$WORK/brainrepo"
mkdir -p "$BR/scripts/verify" "$BR/scripts/vps"
cp "$HERE/check-brain.sh" "$BR/scripts/verify/check-brain.sh"
cp "$HERE/lib.sh" "$BR/scripts/verify/lib.sh"
chmod +x "$BR/scripts/verify/check-brain.sh"

# Indented by one space. Under the column-0 anchor this produced an EMPTY roster
# and the loop then reported "all 0 schedule(s) this brain should have" as a
# PASS -- a derived check going green because its source stopped resolving.
#
# THE ASSERTION IS THE DERIVED IDS, NOT THE ABSENCE OF THAT OLD SENTENCE. The
# `absent "shows all 0 schedule(s)"` that stood here could not fail: the empty-
# ROSTER `die 2` added in the same commit makes that sentence unreachable
# whatever the anchor does, so restoring the column-0 anchor left this file at
# 28 passed, 0 failed -- verified by making that exact mutation. Naming both
# schedules is what separates "derived two" from "derived nothing": under the
# column-0 anchor this run is instead exit 2 about a roster it could not read.
printf 'declare -A PREREQ=(\n)\n ORDER=(morning-brief inbox-triage)\n' \
  > "$BR/scripts/vps/register-schedules.sh"
PAI_MODE=remote BRAIN_HOST=brain.invalid run_check "$BR/scripts/verify/check-brain.sh"
# The verdict prefix is part of the needle, for the reason the sec-bad fixture
# below records: without it the same sentence emitted as a SKIP would match.
saw "an indented ORDER=( is still derived, and every id it found is named" \
  "FAIL  goose schedule list is missing: morning-brief inbox-triage"
if [ "$RC_CODE" -eq 1 ]; then
  pass "...so the check reaches its own verdict instead of the roster refusal"
else
  fail "check-brain exited $RC_CODE on the indented-ORDER=( fixture:"$'\n'"$RC_OUT"
fi

# Removed outright: nothing to derive, so exit 2 rather than a green sweep.
printf 'declare -A PREREQ=(\n)\n' > "$BR/scripts/vps/register-schedules.sh"
PAI_MODE=remote BRAIN_HOST=brain.invalid run_check "$BR/scripts/verify/check-brain.sh"
if [ "$RC_CODE" -eq 2 ]; then
  pass "no ORDER=( at all is exit 2, naming what it could not read"
else
  fail "check-brain exited $RC_CODE with no roster to derive:"$'\n'"$RC_OUT"
fi
saw "...and says which file and which anchor" "ORDER=("

# ---- 4. nothing leaked into a log ------------------------------------------
# The stub goose records every argv it saw. No credential is ever passed to
# these checks, and none may appear in what they run: the standing rule that
# a credential reaches a process through the environment, never argv.
if [ -s "$WORK/goose-argv.log" ] && ! grep -qiE '(api[_-]?key|secret|password|token)[=: ]' "$WORK/goose-argv.log"; then
  pass "no credential-shaped word reached the goose argv these checks build"
else
  fail "the goose argv log is empty or holds a credential-shaped word"
fi

finish --skips
