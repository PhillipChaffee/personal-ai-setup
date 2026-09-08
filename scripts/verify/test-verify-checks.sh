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
# Nothing here reaches the network, opens a socket, spawns goose, or writes
# outside $WORK. The `goose` these checks run is a stub that records its argv
# and exits 0; the container engine and the gateway the §5 sandbox probes talk
# to are likewise stubs that own nothing.
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

# ---- 5. the code-agent sandbox probes (issue #17 B1/B5) --------------------
echo
echo "-- code-agent-probes.sh --"

# WHAT THIS SECTION PROVES, AND WHAT IT DOES NOT. Every probe in
# code-agent-probes.sh reaches PASS or FAIL from an observation, and the
# observation can only be made on a brain with a live container plane. So what
# is asserted here is that each probe FIRES: given a leaky shape it FAILs and
# names the vector, given a vacuous shape it FAILs rather than passing for
# free, and given the isolated shape it passes. THE FIXTURES ARE NOT A
# SANDBOX. Nothing below says anything whatever about whether podman isolates
# two chats — only `check-code-agents.sh --probe` on a real brain says that,
# and it says so about that brain on that day.
#
# The probes are sourced, and each is run in a COMMAND SUBSTITUTION so its own
# pass()/fail() land in a subshell's counters instead of this file's: a probe
# that correctly reports FAIL must not make this harness red.
# shellcheck source=scripts/verify/code-agent-probes.sh
. "$HERE/code-agent-probes.sh"

run_probe() { # run_probe <fn> [args...] -> RC_OUT
  RC_OUT="$("$@" 2>&1)" || true
  return 0
}

# --- 5a. the gateway half: what the RUNNING server says it resolved ---------
# The stub answers GET <anything>/<name> from $CA_FIXTURE_DIR/<name>, so a
# fixture is one JSON file and the probe's URL-building is still exercised.
CA_FIXTURE_DIR="$WORK/gw"
mkdir -p "$CA_FIXTURE_DIR"
cat > "$WORK/fake-curl" <<'EOF'
#!/usr/bin/env bash
# The URL is always the last argument (the probe appends it after the flags).
url=""
for arg in "$@"; do url="$arg"; done
name="${url##*/}"
[ -f "$CA_FIXTURE_DIR/$name" ] || exit 7
cat "$CA_FIXTURE_DIR/$name"
EOF
chmod +x "$WORK/fake-curl"
export CA_FIXTURE_DIR
CA_CURL="$WORK/fake-curl"; CA_AUTH=""; CA_BASE="https://fixture.invalid:4300"

# The shape a correctly-configured chat server answers with.
printf '%s\n' '{"model":"opencode/deepseek-v4-flash","share":"disabled"}' \
  > "$CA_FIXTURE_DIR/config"
run_probe probe_share_disabled chat-a
saw "share=disabled on the running server is a PASS" \
  "PASS  /share refused: the running server resolved share=disabled"

# THE BROKEN INPUT: a container that ignored the template and came up on
# opencode's own default. This is the exact state the probe exists for — the
# repo's config/code-agents/opencode.json says "disabled" either way.
printf '%s\n' '{"model":"opencode/deepseek-v4-flash","share":"auto"}' \
  > "$CA_FIXTURE_DIR/config"
run_probe probe_share_disabled chat-a
saw "share=auto FAILs and names the value it found" \
  "FAIL  /share: the running server resolved share='auto', not 'disabled'"

# ...and the key missing outright, which is a different sentence on purpose:
# "absent" means the file was never loaded, not that it was loaded and lost.
printf '%s\n' '{"model":"opencode/deepseek-v4-flash"}' > "$CA_FIXTURE_DIR/config"
run_probe probe_share_disabled chat-a
saw "no share key at all FAILs as 'upstream default', not as a wrong value" \
  "FAIL  /share: the running server reports NO share setting (upstream default)"

# A server that is up but answering HTML/an error: the probe must not read a
# parse failure as a clean bill of health.
printf '%s\n' '<html>502</html>' > "$CA_FIXTURE_DIR/config"
run_probe probe_share_disabled chat-a
saw "a non-JSON answer FAILs instead of passing silently" \
  "FAIL  /share: the chat's server did not answer GET /config with JSON"

# external_directory: the per-agent resolution, which is the effective one.
cat > "$CA_FIXTURE_DIR/agent" <<'EOF'
[{"name":"build","mode":"primary","permission":{"edit":"allow","external_directory":"deny"}},
 {"name":"plan","mode":"primary","permission":{"external_directory":"deny"}},
 {"name":"general","mode":"subagent","permission":{"external_directory":"allow"}}]
EOF
run_probe probe_external_directory_denied chat-a
saw "deny on every selectable agent is a PASS, and counts them" \
  "PASS  external_directory=deny on all 2 selectable agent(s)"
absent "a subagent's permission is not counted (it cannot run a turn)" "general="

# THE BROKEN INPUT: one selectable agent overrides the config-level deny. This
# is precisely what a config-file assertion cannot see — the file still says
# deny, and the agent that will actually run the turn does not.
cat > "$CA_FIXTURE_DIR/agent" <<'EOF'
[{"name":"build","mode":"primary","permission":{"external_directory":"allow"}},
 {"name":"plan","mode":"primary","permission":{"external_directory":"deny"}}]
EOF
run_probe probe_external_directory_denied chat-a
saw "one agent overriding the deny FAILs and names the agent" \
  "FAIL  external_directory is not denied for: build=allow"

# The vacuous shape: no selectable agent at all. An empty subject makes every
# "all of them are denied" claim true, which is why it is a FAIL.
printf '%s\n' '[{"name":"general","mode":"subagent","permission":{}}]' \
  > "$CA_FIXTURE_DIR/agent"
run_probe probe_external_directory_denied chat-a
saw "an empty agent list FAILs rather than passing for free" \
  "FAIL  external_directory: the server listed NO selectable agent to check"

# THE PARTIALLY VACUOUS SHAPE, which is the same bug one entry at a time: an
# entry that is not an object was skipped WITHOUT being counted, so a list of
# two reported `deny:1` and passed while one listed agent was never examined.
# A count that reads as complete has to be complete.
printf '%s\n' '[{"name":"build","permission":{"external_directory":"deny"}}, "oops"]' \
  > "$CA_FIXTURE_DIR/agent"
run_probe probe_external_directory_denied chat-a
saw "an entry that is not an agent object FAILs and says which one" \
  "FAIL  external_directory is not denied for: entry 1=not-an-object"
absent "...and does not report a clean count over a list it only half read" \
  "PASS  external_directory=deny on all 1 selectable agent(s)"

# --- 5b. the cross-chat half: a container view that leaks, and one that does not
# The fake engine emulates `podman exec` the way stub-engine.sh emulates a
# one-shot: it rewrites the container's paths into a fixture tree and runs the
# script on the host. Three rewrites:
#   "/chat/           -> that container's volume, read from its own chatpath
#                        file (QUOTE-ANCHORED: a chat id may itself contain
#                        "chat", and a bare /chat rewrite turned
#                        .../chats/chat-b into nonsense)
#   <host chats dir>  -> the fixture's view of the host, or nothing
#   find /            -> find <that container's root>
cat > "$WORK/fake-engine" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
[ "${1:-}" = "exec" ] || { echo "fake-engine: unhandled: $*" >&2; exit 9; }
name="$2"; script="$5"
root="$CA_FAKE_ROOT/$name"
chat="$(cat "$root/chatpath")"
s="${script//\"\/chat\//\"@@CHAT@@/}"
s="${s//$CA_FAKE_HOST_FROM/$CA_FAKE_HOST_TO}"
s="${s//find \//find $root/fs }"
s="${s//@@CHAT@@/$chat}"
exec env PATH="$CA_FAKE_PATH" /bin/sh -c "$s"
EOF
chmod +x "$WORK/fake-engine"
CA_ENGINE="$WORK/fake-engine"

# A wget whose every answer is the fixture's, keyed on the URL. SIX separate
# dials, and that is the fix rather than a tidy-up: the version this replaces
# had two (`CA_FAKE_CTL` for chat A's own loopback, `CA_FAKE_NET` for
# everything else), so "the container->host route is dead" and "chat B's port
# is protected" were THE SAME FIXTURE VALUE. A probe cannot be shown to tell
# two states apart by a harness that cannot express them separately.
#
#   CA_FAKE_TOOL    A's own server at 127.0.0.1:4096, inside A's netns
#   CA_FAKE_TOOLNEG the SAME dial carrying a deliberately wrong token
#   CA_FAKE_ROUTE   A's OWN published port on the host — the route control
#   CA_FAKE_NET     chat B's published port on the host — the vector
#   CA_FAKE_GWCTL   the manager gateway's /api/health — the proxy control
#   CA_FAKE_GW      the gateway's /chat/<B>/session — the vector
#
# THE LAST TWO 4096 DIALS SHARE A URL, so this keys them on what actually
# differs — the credential — by decoding the Authorization header the probe
# built. A server that answers `ok` to both is a server enforcing nothing,
# which is the empty-OPENCODE_SERVER_PASSWORD shape.
#
# Each is `ok`, an HTTP status, or anything else for "could not connect".
# Statuses are printed in busybox wget's own wording, because that string is
# what ca_try() parses to tell a refusal from an unreachable host.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/wget" <<'EOF'
#!/usr/bin/env bash
url=""; cred=""
for arg in "$@"; do
  url="$arg"
  case "$arg" in --header=Authorization:*) cred="${arg#*Basic }" ;; esac
done
sent="$(printf '%s' "$cred" | base64 -d 2>/dev/null || true)"
case "$url" in
  *127.0.0.1:4096*)
    case "$sent" in
      *not-the-password) verdict="${CA_FAKE_TOOLNEG:-401}" ;;
      *)                 verdict="${CA_FAKE_TOOL:-ok}" ;;
    esac
    ;;
  *:4310/session)    verdict="${CA_FAKE_ROUTE:-down}" ;;
  *:4311/session)    verdict="${CA_FAKE_NET:-down}" ;;
  *:4300/api/health) verdict="${CA_FAKE_GWCTL:-down}" ;;
  *:4300/chat/*)     verdict="${CA_FAKE_GW:-down}" ;;
  *)                 verdict=down ;;
esac
case "$verdict" in
  ok) exit 0 ;;
  [1-5][0-9][0-9])
    echo "wget: server returned error: HTTP/1.1 $verdict Refused" >&2
    exit 1
    ;;
  *)
    echo "wget: can't connect to remote host: Connection refused" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$WORK/bin/wget"
export CA_FAKE_ROOT="$WORK/view" CA_FAKE_PATH="$WORK/bin:$PATH"
export CA_FAKE_HOST_FROM="$WORK/chats" CA_FAKE_HOST_TO=""
# The dials at their ISOLATED values: wget works, the container->host route is
# live (A reaches its own published port), chat B's port is closed, the gateway
# is up and refuses B's session to A.
#
# THAT LAST ONE IS NOT WHAT THE BRAIN DOES TODAY. `proxy()` performs no
# per-chat authorization (issue #115), so a reachable gateway serves chat B to
# chat A. The fixture describes the shape the probe must call a PASS; the
# shapes the brain can actually produce (a 2xx, and an unreachable gateway) are
# fed in below and must NOT both look like this one.
export CA_FAKE_TOOL=ok CA_FAKE_TOOLNEG=401 CA_FAKE_ROUTE=ok CA_FAKE_NET=down
export CA_FAKE_GWCTL=ok CA_FAKE_GW=403

# The host side: two chat volumes exactly where the manager puts them. Chat B's
# container writes into the real one, so "the host path" and "B's volume" are
# the same directory here as they are on a brain.
mkdir -p "$WORK/chats/chat-a/workspace" "$WORK/chats/chat-b/workspace"
mkdir -p "$WORK/view/code-agent-chat-a/fs/chat/workspace" "$WORK/view/code-agent-chat-b"
VIEW_A="$WORK/view/code-agent-chat-a/fs/chat"
echo "$VIEW_A" > "$WORK/view/code-agent-chat-a/chatpath"
echo "$WORK/chats/chat-b" > "$WORK/view/code-agent-chat-b/chatpath"

probe_pair() { # probe_pair <b_dir> [gateway] — the containers never change.
  # 4310 is chat A's own published port, 4311 is chat B's. `${2-...}` and not
  # `${2:-...}` so a caller can pass an EMPTY gateway on purpose.
  run_probe probe_cross_chat_reach code-agent-chat-a 4310 code-agent-chat-b \
    chat-b "$1" 4311 "${2-https://fixture.invalid:4300}"
}

# ISOLATED: the host chats path resolves to nothing inside chat A, chat B's
# port is closed, and the gateway refuses B's session.
CA_FAKE_HOST_TO="$WORK/view/code-agent-chat-a/fs/nohost"
probe_pair "$WORK/chats/chat-b"
saw "isolated view: the positive control fires" \
  "PASS  cross-chat control: chat A reads its OWN marker (the probe is live)"
saw "isolated view: no filesystem path reaches chat B" \
  "PASS  chat A cannot read chat B's volume"
# The sentence CARRIES THE BOUND. It used to say "or any path under /" over a
# walk that stopped at depth 8, which is false on every run — and the arm has a
# control now, so the PASS also names the file the scan found.
saw "...and the sentence states the depth the scan actually walked to" \
  "or any path under / to depth 12)"
saw "...and names its own control: the scan found chat A's OWN marker" \
  "found its own control at"
# The PASS sentence NAMES the host address the route control got through on.
# It cannot be reached without a proven container->host round trip, which is
# the property the old arm was missing.
saw "isolated view: the route is proven live and B's port is still closed" \
  "PASS  chat A reaches the host (via host.containers.internal) but NOT chat B's published port"
saw "isolated view: the gateway refuses chat B's session to chat A" \
  "PASS  the gateway refused chat A's request for chat B's session (http:403)"

# THE BROKEN INPUT (host path): /data/code-agents/chats is visible inside chat
# A's container — the exact path issue #17 B1 names.
CA_FAKE_HOST_TO="$WORK/chats"
probe_pair "$WORK/chats/chat-b"
saw "a visible host chat root FAILs and prints the path it read" \
  "FAIL  chat A READ chat B's volume:"
saw "...naming the host-path vector B1 calls out" \
  "$WORK/chats/chat-b/workspace/.pai-probe-marker"

# THE BROKEN INPUT (traversal): the host root is invisible again, and chat B's
# volume sits one level up from chat A's mount — which is what `/chat/..`
# reaches when the mount is not a mount.
CA_FAKE_HOST_TO="$WORK/view/code-agent-chat-a/fs/nohost"
mkdir -p "$WORK/view/code-agent-chat-a/fs/chat-b/workspace"
echo "$WORK/view/code-agent-chat-a/fs/chat-b" > "$WORK/view/code-agent-chat-b/chatpath"
probe_pair "$WORK/view/code-agent-chat-a/fs/chat-b"
saw "...and the relative traversal out of the mount" \
  "/fs/chat/../chat-b/workspace/.pai-probe-marker"
rm -rf "$WORK/view/code-agent-chat-a/fs/chat-b"

# THE BROKEN INPUT (any path): chat B's volume is somewhere chat A cannot NAME
# — the host path is dead and the traversal misses — but it is still on chat
# A's filesystem. Only the bounded scan catches this one, which is why it is
# there: "cannot reach it by the two paths I thought of" is not isolation.
mkdir -p "$WORK/view/code-agent-chat-a/fs/var/lib/containers/other/workspace"
echo "$WORK/view/code-agent-chat-a/fs/var/lib/containers/other" \
  > "$WORK/view/code-agent-chat-b/chatpath"
probe_pair "$WORK/chats/chat-b"
saw "chat B's volume reachable under some OTHER path is still a FAIL" \
  "/fs/var/lib/containers/other/workspace/.pai-probe-marker"
rm -rf "$WORK/view/code-agent-chat-a/fs/var"
echo "$WORK/chats/chat-b" > "$WORK/view/code-agent-chat-b/chatpath"

# THE BROKEN INPUT THE OLD BOUND SWEPT CLEAN: the same leak, one directory
# deeper than the scan used to walk. Rootless podman keeps its containers'
# storage at /home/<user>/.local/share/containers/storage/overlay/<id>/diff/,
# so another chat's workspace marker inside chat A's view sits at depth 12 —
# and at -maxdepth 8 the probe printed "or any path under /" over a file chat A
# could cat. Nothing about this fixture is exotic: it is the layout a rootless
# brain already has.
DEEP="$WORK/view/code-agent-chat-a/fs/home/u/.local/share/containers/storage/overlay/abc123/diff/chat"
mkdir -p "$DEEP/workspace"
echo "$DEEP" > "$WORK/view/code-agent-chat-b/chatpath"
probe_pair "$WORK/chats/chat-b"
saw "a leak at podman's own storage depth (12) is a FAIL, not a clean sweep" \
  "/storage/overlay/abc123/diff/chat/workspace/.pai-probe-marker"
absent "...and the arm claims nothing about paths it did reach" \
  "PASS  chat A cannot read chat B's volume"
rm -rf "$WORK/view/code-agent-chat-a/fs/home"
echo "$WORK/chats/chat-b" > "$WORK/view/code-agent-chat-b/chatpath"

# THE VACUOUS SHAPE THIS ARM HAD NO CONTROL FOR: no find(1) in the image. The
# loop then emits nothing, which is indistinguishable from a walk that found
# nothing — and this arm used to render that as isolation while the two network
# arms, which HAVE controls, degraded to SKIP in the same run. So PATH here
# carries every tool the emitted script uses EXCEPT find — wget included, on
# purpose: the ONLY difference from the isolated run above is the instrument
# under test, and the contrast between the arms is the assertion.
mkdir -p "$WORK/nofindbin"
for tool in cat base64 tr sed head cut bash; do  # bash: the fake wget's shebang
  command -v "$tool" >/dev/null 2>&1 || continue
  ln -sf "$(command -v "$tool")" "$WORK/nofindbin/$tool"
done
CA_FAKE_PATH="$WORK/bin:$WORK/nofindbin"
probe_pair "$WORK/chats/chat-b"
saw "an image with no find(1) SKIPs the filesystem arm instead of passing it" \
  "SKIP  cross-chat filesystem arm NOT fully exercised (the / scan found nothing at all)"
absent "...and prints no isolation sentence about paths it never walked" \
  "PASS  chat A cannot read chat B's volume"
saw "...and says the two paths B1 names were still checked by cat" \
  "The two paths issue #17 B1 names WERE still"
saw "...while the arms whose instruments DO work still report" \
  "PASS  chat A reaches the host (via host.containers.internal) but NOT chat B's published port"
CA_FAKE_PATH="$WORK/bin:$PATH"

# THE BROKEN INPUT (published port): the filesystem is clean and chat A can
# still read chat B by talking to its server with the password every container
# holds.
CA_FAKE_NET=ok
probe_pair "$WORK/chats/chat-b"
saw "a filesystem-clean chat that can reach B's PORT is still a FAIL" \
  "FAIL  chat A reached chat B's opencode server over the network:"
saw "...naming the host address it got through on" "via host.containers.internal"
CA_FAKE_NET=down

# THE BROKEN SENTENCE (published port): chat B's port ANSWERS chat A and turns
# the credential away. Not producible on this brain — one password serves every
# container — but it is the normal answer the day issue #115 is fixed with
# per-chat tokens, and until now it left no tag at all, so the arm printed
# "chat A reaches the host but NOT chat B's published port" about a port that
# had just replied. That is the same collapse the proxy arm was fixed for,
# left in its sibling: "refused" is not "unreachable".
CA_FAKE_NET=401
probe_pair "$WORK/chats/chat-b"
saw "B refusing the credential is reported as REACHED, not as unreachable" \
  "PASS  chat A REACHED chat B's published port but B refused its credential"
absent "...and the old sentence claiming B's port was not reached is gone" \
  "but NOT chat B's published port"
saw "...and it says the network path is open and only the key is not" \
  "The network path to chat B is OPEN"
CA_FAKE_NET=down

# ...and an answer that is neither a read nor a refusal. Something is listening
# on chat B's published port and it is not answering as chat B, which is a
# broken subject rather than a result — the mirror of the proxy arm's 404.
CA_FAKE_NET=404
probe_pair "$WORK/chats/chat-b"
saw "a non-refusal HTTP answer from B's port is INCONCLUSIVE, not isolation" \
  "SKIP  cross-chat published-port arm INCONCLUSIVE"
absent "...and claims no isolation about a port that answered" \
  "but NOT chat B's published port"
CA_FAKE_NET=down

# THE VACUOUS SHAPE (credential, port arm): the container->host route is LIVE —
# chat A's own published port answers — and it turns chat A's own password
# away. A probe holding a key nothing accepts gets silence from chat B for a
# reason that has nothing to do with the sandbox, so the arm must not read that
# silence as isolation.
CA_FAKE_ROUTE=401
probe_pair "$WORK/chats/chat-b"
saw "a credential A's OWN port rejects is a SKIP, not isolation" \
  "SKIP  cross-chat published-port arm NOT exercised (A's own port refused A's credential)"
absent "...and no pass sentence about chat B's port survives it" \
  "but NOT chat B's published port"
CA_FAKE_ROUTE=ok

# ...and the SAME COLLAPSE one level up, which is the one this file is for: a
# 404 at chat A's own published port is NOT a rejected credential, it is some
# other process on A's port. Reporting it with the sentence above would be the
# probe inventing a reason, so it gets its own.
CA_FAKE_ROUTE=404
probe_pair "$WORK/chats/chat-b"
saw "a non-refusal answer at A's OWN port is its own SKIP, not a credential story" \
  "SKIP  cross-chat published-port arm NOT exercised (A's own port answered as something else)"
absent "...and does not blame the credential for it" \
  "refused A's credential"
absent "...and still claims no isolation" \
  "but NOT chat B's published port"
CA_FAKE_ROUTE=ok

# THE VACUOUS SHAPE THIS WHOLE ARM WAS REWRITTEN FOR, and the one the shipped
# probe reported as isolation. The container->host route is dead: chat A cannot
# reach its OWN published port on any of the three host addresses, so chat B's
# silence at the same three addresses measures nothing. This is the DEFAULT on
# rootless podman — allow_host_loopback=false, chat ports bound to 127.0.0.1.
#
# CA_FAKE_NET is `down` here and `down` in the isolated run above. The ONLY
# difference between a PASS and this SKIP is CA_FAKE_ROUTE, which is exactly
# the distinction the old single-dial fixture could not make and the old
# loopback control could not detect.
CA_FAKE_ROUTE=down
probe_pair "$WORK/chats/chat-b"
saw "a dead container->host route is a SKIP, not isolation" \
  "SKIP  cross-chat published-port arm NOT exercised (no container->host route)"
absent "...and no pass sentence about chat B's port survives it" \
  "but NOT chat B's published port"
absent "...nor the sentence the old probe printed on exactly this input" \
  "cannot reach chat B's server on the host's published port"
# The loopback control still answers `ok` here — it always did. Keeping it as
# the SKIP's sub-reason is what separates "no wget" from "no route".
saw "...and the note reports the loopback control that used to gate this arm" \
  "A's own server inside its netns answered: ok"
CA_FAKE_ROUTE=ok

# An image with no wget at all reports BOTH network vectors as untested by
# name. PATH is narrowed to symlinks for exactly the commands the probe needs.
mkdir -p "$WORK/minbin"
for tool in cat find; do
  command -v "$tool" >/dev/null 2>&1 || continue
  ln -sf "$(command -v "$tool")" "$WORK/minbin/$tool"
done
CA_FAKE_PATH="$WORK/minbin"
probe_pair "$WORK/chats/chat-b"
saw "an image with no wget says the published-port vector is untested" \
  "A's own server inside its netns answered: nowget"
saw "...and the proxy vector too, rather than sweeping it clean" \
  "SKIP  cross-chat proxy arm NOT exercised (gateway control: nowget)"
CA_FAKE_PATH="$WORK/bin:$PATH"

# --- 5c. the manager's own proxy: the shortest cross-chat path (issue #115) --
# /chat/<id>/<path> takes any chat id, does no per-chat authorization, is gated
# only by a global password every container is handed, and WAKES a stopped chat
# to serve it. No mount bug and no port guess is needed. The three outcomes
# below are the three the probe has to keep apart; collapsing "unreachable"
# into "protected" is the same false negative 5b just removed.

# THE BROKEN INPUT: the gateway serves chat B's session to chat A.
CA_FAKE_GW=ok
probe_pair "$WORK/chats/chat-b"
saw "the gateway serving B's session to A is a FAIL, loudly" \
  "FAIL  chat A DROVE chat B through the manager's proxy (/chat/<B-id>/session)"
saw "...and points at the issue that owns the credential model" "issue #115"
absent "...and claims no isolation anywhere in that run" \
  "PASS  the gateway refused"
CA_FAKE_GW=403

# THE VACUOUS SHAPE: the gateway is not reachable from inside the container's
# netns at all. UNPROVEN on a real brain either way — the chat ports are
# loopback-bound but the gateway binds the tailnet IP, which slirp4netns does
# forward. So this must SKIP and say what wget said, never pass.
CA_FAKE_GWCTL=down CA_FAKE_GW=down
probe_pair "$WORK/chats/chat-b"
saw "an unreachable gateway is a SKIP naming wget's own answer" \
  "SKIP  cross-chat proxy arm NOT exercised (gateway control: down:wget: can't connect"
absent "...and never renders as a refusal" "PASS  the gateway refused"
CA_FAKE_GWCTL=ok CA_FAKE_GW=403

# The gateway is reachable but will not take the credential the container
# holds. That IS isolation — a different sentence, because it is a different
# fact, and it is what fixing #115 by option 2 would look like from here.
# TOOL is `ok` throughout this file's isolated fixture, which is what makes the
# sentence true: some server DID take this token.
CA_FAKE_GWCTL=401 CA_FAKE_GW=401
probe_pair "$WORK/chats/chat-b"
saw "a gateway that rejects the container's credential is a PASS of its own" \
  "PASS  the gateway is reachable from chat A but refuses the credential it holds"
saw "...and the note reports BOTH halves of the credential control" \
  "answered ok to that password and http:401 to a"

# THE VACUOUS SHAPE THE CONTROL ITSELF HID, and the reason TOOLNEG exists. A
# container started with an EMPTY OPENCODE_SERVER_PASSWORD runs an opencode
# server that enforces nothing: it answers 2xx to any Authorization header, so
# `TOOL:ok` is true while chat A holds no key at all — and the gateway's 401 is
# then about the missing key, not about the plane refusing this chat. Only the
# NEGATIVE dial tells those apart, and only a fixture can produce the state:
# main() refuses to serve on an empty PASSWORD and run_container() hands that
# same value to every container.
CA_FAKE_TOOLNEG=ok
probe_pair "$WORK/chats/chat-b"
saw "a server that also takes a WRONG token proves nothing, and SKIPs" \
  "SKIP  cross-chat proxy arm NOT exercised (chat A's own server takes ANY credential)"
absent "...and no isolation is claimed off a credential nothing checked" \
  "PASS  the gateway is reachable from chat A"
CA_FAKE_TOOLNEG=401

# ...and the negative dial that settles nothing either: A's own server took the
# real token but never answered the wrong one, so whether it checks credentials
# at all is unknown. Unproven is a SKIP with its own sentence.
CA_FAKE_TOOLNEG=down
probe_pair "$WORK/chats/chat-b"
saw "a control whose own control did not answer is its own SKIP" \
  "SKIP  cross-chat proxy arm NOT exercised (the credential control is itself unproven)"
absent "...and still claims no isolation" \
  "PASS  the gateway is reachable from chat A"
CA_FAKE_TOOLNEG=401

# THE OTHER VACUOUS SHAPE: a container whose OPENCODE_SERVER_PASSWORD does not
# match the manager's 401s EVERYWHERE, including at its own opencode server.
# The identical gateway answer then means "this probe has no key", not "this
# plane refuses this chat", and printing an isolation PASS off it is a green
# verdict produced by the probe being broken.
CA_FAKE_TOOL=401
probe_pair "$WORK/chats/chat-b"
saw "401 from A's OWN server as well makes it a SKIP, not a refusal" \
  "SKIP  cross-chat proxy arm NOT exercised (the probe holds no working credential)"
absent "...and no isolation is claimed for a probe with no key" \
  "PASS  the gateway is reachable from chat A"

# ...and the case where the control cannot settle it either way: A's own server
# is not answering at all, so nothing shows the token is one the plane takes.
# Unproven is a SKIP with its own sentence, because "we could not tell" and "we
# tested and the key is dead" are different things to go and look at.
CA_FAKE_TOOL=down
probe_pair "$WORK/chats/chat-b"
saw "an unproven credential is its own SKIP, naming what the control answered" \
  "SKIP  cross-chat proxy arm NOT exercised (the probe's credential is unproven)"
absent "...and still claims no isolation" \
  "PASS  the gateway is reachable from chat A"
CA_FAKE_TOOL=ok
CA_FAKE_GWCTL=ok CA_FAKE_GW=403

# The gateway answered, but not about chat B: a 404 means the probe lost its
# subject between the create and the read. Neither a refusal nor a read.
CA_FAKE_GW=404
probe_pair "$WORK/chats/chat-b"
saw "a 404 from the proxy is INCONCLUSIVE, not a refusal" \
  "SKIP  cross-chat proxy arm INCONCLUSIVE — gateway up, /chat/<B>/session said http:404"
CA_FAKE_GW=403

# No gateway address to try at all — a caller that could not work out where the
# manager is listening. Named as such rather than silently omitted.
probe_pair "$WORK/chats/chat-b" ""
saw "no gateway address is a SKIP that says so" \
  "SKIP  cross-chat proxy arm NOT exercised (gateway control: nogateway)"

# THE VACUOUS SHAPE (staging): chat A's container has no workspace to write
# into, so the marker never lands. Nothing may be reported about isolation
# after that — a clean sweep for a file that does not exist is a sweep of
# nothing.
echo "$WORK/view/code-agent-chat-a/fs/no-such-volume" \
  > "$WORK/view/code-agent-chat-a/chatpath"
probe_pair "$WORK/chats/chat-b"
saw "a marker that never landed FAILs the whole probe" \
  "FAIL  cross-chat probe: chat A could not stage a marker in its own workspace"
absent "...and reports nothing about isolation" "chat A cannot read chat B's volume"

# ...and the same for chat B: with no marker in B there is nothing for A to
# fail to reach, which would otherwise be a clean sweep of an empty room.
echo "$VIEW_A" > "$WORK/view/code-agent-chat-a/chatpath"
echo "$WORK/view/code-agent-chat-b/no-such-volume" \
  > "$WORK/view/code-agent-chat-b/chatpath"
probe_pair "$WORK/chats/chat-b"
saw "no marker in chat B FAILs rather than sweeping an empty room" \
  "FAIL  cross-chat probe: chat B could not stage a marker in its own workspace"
echo "$WORK/chats/chat-b" > "$WORK/view/code-agent-chat-b/chatpath"

# THE WORST SHAPE: chat A is mounted on chat B's volume. A reads B's nonce as
# its own, and reporting a clean sweep there would be this probe's most
# dangerous failure.
echo "$WORK/chats/chat-b" > "$WORK/view/code-agent-chat-a/chatpath"
probe_pair "$WORK/chats/chat-b"
saw "a container mounted on the WRONG chat's volume FAILs as such" \
  "FAIL  cross-chat control: chat A's /chat holds another chat's marker"
absent "...and stops instead of reporting isolation it cannot claim" \
  "chat A cannot read chat B's volume"
echo "$VIEW_A" > "$WORK/view/code-agent-chat-a/chatpath"

# The one arm no fixture can reach end to end: the marker was staged and then
# vanished before the read. Fed to the verdict directly, because a probe whose
# own control silently disappeared must still refuse to report isolation.
run_probe ca_cross_chat_verdict "pai-own-fixture" ""
saw "an empty probe result FAILs on the control, not on the vectors" \
  "FAIL  cross-chat control: chat A cannot read its own workspace marker"
saw "...and says the isolation results are worthless" \
  "The isolation results below prove NOTHING"

finish --skips
