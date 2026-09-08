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

# A wget whose verdict is the fixture's, keyed on the URL: 127.0.0.1:4096 is
# chat A's own server (the network arm's positive control), anything else is
# the reach at chat B.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/wget" <<'EOF'
#!/usr/bin/env bash
url=""
for arg in "$@"; do url="$arg"; done
case "$url" in
  *127.0.0.1:4096*) exit "${CA_FAKE_CTL:-0}" ;;
  *) exit "${CA_FAKE_NET:-1}" ;;
esac
EOF
chmod +x "$WORK/bin/wget"
export CA_FAKE_ROOT="$WORK/view" CA_FAKE_PATH="$WORK/bin:$PATH"
export CA_FAKE_HOST_FROM="$WORK/chats" CA_FAKE_HOST_TO=""
export CA_FAKE_CTL=0 CA_FAKE_NET=1

# The host side: two chat volumes exactly where the manager puts them. Chat B's
# container writes into the real one, so "the host path" and "B's volume" are
# the same directory here as they are on a brain.
mkdir -p "$WORK/chats/chat-a/workspace" "$WORK/chats/chat-b/workspace"
mkdir -p "$WORK/view/code-agent-chat-a/fs/chat/workspace" "$WORK/view/code-agent-chat-b"
VIEW_A="$WORK/view/code-agent-chat-a/fs/chat"
echo "$VIEW_A" > "$WORK/view/code-agent-chat-a/chatpath"
echo "$WORK/chats/chat-b" > "$WORK/view/code-agent-chat-b/chatpath"

probe_pair() { # probe_pair <b_dir> — the two containers are always the same
  run_probe probe_cross_chat_reach code-agent-chat-a code-agent-chat-b \
    chat-b "$1" 4311
}

# ISOLATED: the host chats path resolves to nothing inside chat A, and chat B's
# port is unreachable.
CA_FAKE_HOST_TO="$WORK/view/code-agent-chat-a/fs/nohost"
probe_pair "$WORK/chats/chat-b"
saw "isolated view: the positive control fires" \
  "PASS  cross-chat control: chat A reads its OWN marker (the probe is live)"
saw "isolated view: no filesystem path reaches chat B" \
  "PASS  chat A cannot read chat B's volume"
saw "isolated view: chat B's port is unreachable, control confirmed" \
  "PASS  chat A cannot reach chat B's server on the host's published port"

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

# THE BROKEN INPUT (network): the filesystem is clean and chat A can still read
# chat B by talking to its server with the password every container holds.
CA_FAKE_NET=0
probe_pair "$WORK/chats/chat-b"
saw "a filesystem-clean chat that can reach B's PORT is still a FAIL" \
  "FAIL  chat A reached chat B's opencode server over the network:"
saw "...naming the host address it got through on" "via host.containers.internal"
CA_FAKE_NET=1

# THE VACUOUS SHAPE (network): wget cannot reach chat A's own server either, so
# "B was unreachable" measured nothing. Must be a SKIP, never a PASS.
CA_FAKE_CTL=1
probe_pair "$WORK/chats/chat-b"
saw "a dead network control is a SKIP, not a pass" \
  "SKIP  cross-chat network arm NOT exercised (control: unreachable)"
absent "...and the pass sentence is nowhere in that run" \
  "cannot reach chat B's server"
CA_FAKE_CTL=0

# An image with no wget at all reports the vector as untested by name. PATH is
# narrowed to symlinks for exactly the commands the probe script needs.
mkdir -p "$WORK/minbin"
for tool in cat find; do
  command -v "$tool" >/dev/null 2>&1 || continue
  ln -sf "$(command -v "$tool")" "$WORK/minbin/$tool"
done
CA_FAKE_PATH="$WORK/minbin"
probe_pair "$WORK/chats/chat-b"
saw "an image with no wget says the vector is untested" "control: nowget"
CA_FAKE_PATH="$WORK/bin:$PATH"

# THE VACUOUS SHAPE (staging): chat A's container has no workspace to write
# into, so the marker never lands. Nothing may be reported about isolation
# after that — four misses of a file that does not exist are four misses of
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
