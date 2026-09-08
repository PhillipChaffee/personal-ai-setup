#!/usr/bin/env bash
# code-agent-probes.sh — the sandbox probes issue #17 B1/B5 name and nothing
# in this repo asserted. Sourced, never run.
#
# WHY A SEPARATE FILE. Every function here is an OBSERVATION plus a VERDICT,
# and the observation can only happen on a brain with a live container plane.
# Split out and given two seams (CODE_AGENT_ENGINE for the in-container half,
# CA_CURL for the gateway half), the verdict half becomes drivable from
# scripts/verify/test-verify-checks.sh against fixtures — so the thing CI
# proves is that each probe FIRES on a broken input, which is the failure mode
# a probe living inline in check-code-agents.sh could never be tested for.
#
# WHAT CI CAN AND CANNOT PROVE, stated once so nothing downstream overclaims:
#   * CI proves the probe's plumbing — it builds the right observation, parses
#     the answer, and reaches PASS only on the isolated shape and FAIL on each
#     leaky one, INCLUDING the vacuous shape where the probe's own positive
#     control never fired.
#   * CI proves NOTHING about the sandbox. A fixture is not a container. The
#     only run that says anything about isolation is
#     `check-code-agents.sh --probe` on a brain with podman.
#
# Callers source it as:
#     # shellcheck source=scripts/verify/code-agent-probes.sh
#     . "<dir>/code-agent-probes.sh"
# after lib.sh (pass/fail/skip/note come from there).

[ -n "${PAI_CODE_AGENT_PROBES:-}" ] && return 0
PAI_CODE_AGENT_PROBES=1

# The container engine used for the in-container half. Named to match the
# manager's own CODE_AGENT_ENGINE so a brain that runs docker is probed with
# docker; the harness points it at a fixture that owns no containers at all.
CA_ENGINE="${CODE_AGENT_ENGINE:-podman}"

# The gateway half. check-code-agents.sh assigns its own $CURL/$AUTH/$BASE into
# these; the harness assigns a stub that answers from files.
CA_CURL="${CA_CURL:-curl -sS --max-time 15}"
CA_AUTH="${CA_AUTH:-}"
CA_BASE="${CA_BASE:-}"

# The file the cross-chat probe stages in a chat's workspace. Named with a dot
# so it never lands in a diff the agent is looking at, and identical in both
# chats so "A read the wrong one" is a content comparison rather than a guess.
CA_MARKER=".pai-probe-marker"

# ------------------------------------------------------------- observation --

# ca_exec <container> <sh-script> — run a script inside a chat's container.
# Never lets a non-zero exit reach the caller's errexit: every probe below
# decides on the OUTPUT, and "the command failed" is one of the shapes it has
# to be able to read rather than die on.
ca_exec() {
  "$CA_ENGINE" exec "$1" sh -c "$2" 2>/dev/null || true
}

# ca_get <path> — GET a gateway path, body on stdout, empty on any failure.
ca_get() {
  # shellcheck disable=SC2086  # $CA_CURL/$CA_AUTH are deliberately word-split
  $CA_CURL $CA_AUTH "$CA_BASE$1" 2>/dev/null || true
}

# ---------------------------------------------------------- B5: /share off --

# probe_share_disabled <chat_id>
#
# PROVES: the opencode server RUNNING in that chat's container resolved
# `"share": "disabled"`. `/share` publishes a transcript to opencode's public
# share backend (docs/privacy.md); "disabled" is the value that refuses it, and
# the manager's gateway proxies /chat/<id>/<anything> verbatim, so the refusal
# has to come from the chat's own server rather than from a route allowlist.
#
# DOES NOT PROVE: that the agent cannot exfiltrate the transcript some other
# way. Container egress is unrestricted in the MVP (issue #17 D5, Phase 2
# proxy), so an agent that wants the text out has curl. This probe is about the
# one publish path the product ships, not about containment of a hostile agent.
#
# It asserts against the SERVER, not against config/code-agents/opencode.json
# and not against the rendered file on the volume: a template nothing loads is
# a comment, which is the exact defect this probe was written to remove.
probe_share_disabled() {
  local chat_id="$1" verdict
  verdict="$(ca_get "/chat/$chat_id/config" | ca_read_share)"
  case "$verdict" in
    disabled)
      pass "/share refused: the running server resolved share=disabled"
      ;;
    unreadable)
      fail "/share: the chat's server did not answer GET /config with JSON"
      note "Nothing was proved either way — a silent pass here would be the bug."
      ;;
    absent)
      fail "/share: the running server reports NO share setting (upstream default)"
      note "config/code-agents/opencode.json sets it; the container is not loading that file."
      ;;
    *)
      fail "/share: the running server resolved share='$verdict', not 'disabled'"
      ;;
  esac
  return 0
}

# ca_read_share — stdin is a /config body; echo the share value, or a reason.
ca_read_share() {
  python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    print("unreadable"); raise SystemExit(0)
if not isinstance(doc, dict):
    print("unreadable"); raise SystemExit(0)
value = doc.get("share")
print("absent" if value is None else str(value))
' 2>/dev/null || echo unreadable
}

# ------------------------------------------ B5: external_directory = deny ---

# probe_external_directory_denied <chat_id>
#
# PROVES: every agent the chat's RUNNING server will accept a turn on resolved
# `permission.external_directory = deny`. That is the permission the tool layer
# consults before a read or write outside the workspace, and the per-agent
# resolution is the effective one — a config-level deny that some agent
# overrides is not a deny.
#
# DOES NOT PROVE: enforcement. Nothing here makes a tool call, so this says the
# policy is LOADED, not that a read of /etc/passwd is actually refused.
# Exercising the enforcement needs a model turn that attempts an out-of-
# workspace read, which is a live-brain manual step (the checklist at the end
# of check-code-agents.sh). The HARD bound is not this permission at all — it
# is the mount, which probe_cross_chat_reach below tests behaviourally.
#
# Subagents are excluded because they cannot be selected for a turn; agents
# with no `mode` are counted, because an unknown shape must not silently shrink
# the set being checked.
probe_external_directory_denied() {
  local chat_id="$1" verdict
  verdict="$(ca_get "/chat/$chat_id/agent" | ca_read_external_directory)"
  case "$verdict" in
    deny:*)
      pass "external_directory=deny on all ${verdict#deny:} selectable agent(s)"
      ;;
    unreadable)
      fail "external_directory: the chat's server did not answer GET /agent with JSON"
      ;;
    none)
      fail "external_directory: the server listed NO selectable agent to check"
      note "A probe with an empty subject passes for free; that is why this is a FAIL."
      ;;
    leak:*)
      fail "external_directory is not denied for: ${verdict#leak:}"
      ;;
    *)
      fail "external_directory: unreadable verdict '$verdict'"
      ;;
  esac
  return 0
}

# ca_read_external_directory — stdin is a /agent body; echo deny:<n>, leak:<list>,
# none, or unreadable.
ca_read_external_directory() {
  python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    print("unreadable"); raise SystemExit(0)
agents = doc if isinstance(doc, list) else doc.get("agents") if isinstance(doc, dict) else None
if not isinstance(agents, list):
    print("unreadable"); raise SystemExit(0)
seen, leaks = 0, []
for entry in agents:
    if not isinstance(entry, dict):
        continue
    if entry.get("mode") == "subagent":
        continue
    seen += 1
    permission = entry.get("permission")
    value = permission.get("external_directory") if isinstance(permission, dict) else None
    if value != "deny":
        leaks.append("%s=%s" % (entry.get("name", "?"), "absent" if value is None else value))
if not seen:
    print("none")
elif leaks:
    print("leak:" + ",".join(leaks))
else:
    print("deny:%d" % seen)
' 2>/dev/null || echo unreadable
}

# --------------------------------------- B1: another chat is out of reach ---

# probe_cross_chat_reach <a_container> <a_port> <b_container> <b_id> <b_dir>
#                        <b_port> <gateway_url>
#
# THE ONE PROBE HERE THAT TESTS BEHAVIOUR RATHER THAN POLICY. Two chats exist;
# each container stages a nonce in its OWN workspace — through the container,
# not from the host, because a rootless podman volume's files belong to a
# subordinate uid and a host-side write would fail for a reason that has
# nothing to do with isolation. Then chat A's container is asked to go and get
# chat B's. THREE VECTORS, reported as three verdicts:
#
#   1. THE FILESYSTEM. Tried three ways, but they are one vector, not three:
#      B's volume at its host path (/data/code-agents/chats/<B>/...), the path
#      issue #17 B1 names outright; relative traversal out of A's own mount
#      (/chat/../<B>/...); and a bounded find(1) for the marker filename
#      ANYWHERE in A's filesystem, compared by CONTENT so A finding its own
#      does not count. The scan subsumes the other two — no working runtime
#      lets a relative path escape a bind mount, so the traversal try is
#      expected to be redundant and is kept only because it costs one cat(1)
#      and names the vector explicitly when it does hit. One verdict.
#   2. B'S PUBLISHED PORT. The manager publishes each chat on
#      127.0.0.1:<port> of the HOST, so this needs the container->host route,
#      not the mount.
#   3. THE MANAGER'S OWN PROXY — the shortest path of the three and the one
#      that needs neither a mount bug nor a port guess. `/chat/<id>/<path>` is
#      a wildcard with NO per-chat authorization: Handler.proxy() looks the id
#      up and serves it, Handler.authed() compares one global PASSWORD, and
#      run_container() hands that same value to every chat container as
#      OPENCODE_SERVER_PASSWORD. Cited by symbol and not by line on purpose —
#      issue #115 carries the line numbers and owns the credential model; this
#      arm owns finding out whether the gateway is reachable from in here.
#
# THE CREDENTIAL IS NEVER PASSED IN. The script reads OPENCODE_SERVER_PASSWORD
# out of the container's OWN environment, which is both the repo's standing
# rule (a credential reaches a process through the environment, never argv —
# `podman exec` argv is world-readable in ps) and the more faithful test: the
# question is what the agent can do with what the agent already has.
#
# EVERY ARM HAS A POSITIVE CONTROL THAT EXERCISES THE ARM'S OWN PRECONDITION.
# That sentence used to be false for the network arm and it is the reason this
# probe was rewritten. The old control was `wget http://127.0.0.1:4096/session`
# — chat A's own server inside chat A's OWN netns. It proves wget, base64 and
# the credential work; it NEVER touches the container->host route that all
# three of the arm's target addresses depend on. Rootless podman's default is
# `allow_host_loopback=false` and the chat ports publish to 127.0.0.1 only, so
# on a brain where that route is dead the old control answered "ok", no NET
# line was emitted, and the probe printed a green isolation verdict for a
# vector it had never exercised. The controls now are:
#   * filesystem: A must read ITS OWN marker and it must hold A's nonce. If it
#     cannot, the probe says so and fails rather than recording misses.
#   * published port: A must reach ITS OWN published port on the host, over
#     the same three host addresses B is tried on. A miss there means the
#     route is dead, which is a SKIP. A hit at A's own port plus a miss at B's
#     is the only shape that is isolation.
#   * manager proxy: A must reach the gateway's /api/health. Unreachable is a
#     SKIP naming the reason wget gave, never a pass.
#   * THE CREDENTIAL, for both network arms. Every "it refused me" verdict is
#     isolation only if the thing refused was a key the plane accepts, so a
#     refusal is read as isolation only when some server took the same token:
#     the gateway itself (GWCTL:ok), or A's own published port (ROUTE ok), or
#     A's own server inside its netns (TOOL:ok). A container whose
#     OPENCODE_SERVER_PASSWORD is empty or wrong 401s everywhere, and that must
#     be a SKIP — the probe is broken — rather than a pass earned by having
#     nothing to be let in with.
# `TOOL:` (A's own server on loopback inside its netns) is kept, demoted from
# a gate on the port arm to two smaller jobs: the sub-reason a SKIP quotes (it
# separates "no wget in the image" from "the route is closed"), and the
# credential control the proxy arm consults before reading a 401 as isolation.
#
# DOES NOT PROVE: that no vector exists. It proves these three are closed on
# the brain it ran on. A shared kernel is a shared kernel (issue #17 Phase 3
# names micro-VMs).
probe_cross_chat_reach() {
  local a_container="$1" a_port="$2" b_container="$3" b_id="$4" b_dir="$5"
  local b_port="$6" gateway="${7:-}"
  local nonce_a nonce_b script out

  nonce_a="pai-own-$$-${RANDOM:-0}"
  nonce_b="pai-other-$$-${RANDOM:-0}"
  # Staged, then read back through the same container: a write that silently
  # went nowhere would turn the whole probe green for the worst reason there is.
  if [ "$(ca_stage_marker "$a_container" "$nonce_a")" != "$nonce_a" ]; then
    fail "cross-chat probe: chat A could not stage a marker in its own workspace"
    return 0
  fi
  if [ "$(ca_stage_marker "$b_container" "$nonce_b")" != "$nonce_b" ]; then
    fail "cross-chat probe: chat B could not stage a marker in its own workspace"
    note "Without a marker in B there is nothing for A to fail to reach."
    return 0
  fi

  script="$(ca_cross_chat_script "$b_id" "$b_dir" "$a_port" "$b_port" "$nonce_b" "$gateway")"
  out="$(ca_exec "$a_container" "$script")"

  ca_cross_chat_verdict "$nonce_a" "$out"
  return 0
}

# ca_stage_marker <container> <nonce> — write the marker into that container's
# own workspace and echo back what landed there.
ca_stage_marker() {
  ca_exec "$1" "printf '%s\n' '$2' > \"/chat/workspace/$CA_MARKER\" 2>/dev/null;
cat \"/chat/workspace/$CA_MARKER\" 2>/dev/null || true"
}

# ca_cross_chat_script <b_id> <b_dir> <a_port> <b_port> <nonce_b> <gateway_url>
#
# Emitted rather than inlined so the harness can read it, and written for
# BUSYBOX ASH (the base image is Alpine): no arrays, no [[, no ${var//}, no
# `local`. It runs WITHOUT errexit, and every arm is written so that a failing
# command is data rather than an abort.
#
# It prints one tagged line per observation and decides nothing:
#   OWN:<nonce>          the marker A found in its own workspace (the fs control)
#   READ:<path>          B's nonce, read at a path A could NAME
#   SCAN:<path>          B's nonce, found anywhere under / (the arm that subsumes)
#   TOOL:<answer>        A's own server on 127.0.0.1:4096, inside A's netns
#   ROUTE:<host>=<answer>  A dialling ITS OWN published port via that host
#                          address — the container->host route control
#   NET:<host>=<answer>    A dialling B's published port via that host address
#   GWCTL:<answer>       the manager gateway's /api/health, from inside A
#   GW:<answer>          the gateway's /chat/<B>/session, from inside A
#
# <answer> is `ok`, `http:<code>`, `down:<what wget said>`, `nowget`, or
# `nogateway`. The distinction is the whole point: "refused" and "could not be
# reached" are opposite results that both make wget exit non-zero.
#
# ROUTE/NET CARRY THE WHOLE ANSWER, not just a hit. The first cut emitted them
# only on `ok`, which folded "B refused me" into "B was not there" — the exact
# collapse the gateway arm below was rewritten to stop making. It is not
# reachable today (every container holds the same password, so B cannot 401 A),
# but the moment issue #115 is fixed with per-chat tokens it becomes the NORMAL
# answer, and "chat A reaches the host but NOT chat B's published port" would
# then be a false statement about reachability printed under a PASS.
ca_cross_chat_script() {
  local b_id="$1" b_dir="$2" a_port="$3" b_port="$4" nonce_b="$5" gateway="$6"
  cat <<EOS
own=\$(cat "/chat/workspace/$CA_MARKER" 2>/dev/null || true)
if [ -n "\$own" ]; then echo "OWN:\$own"; fi

for p in "$b_dir/workspace/$CA_MARKER" "/chat/../$b_id/workspace/$CA_MARKER"; do
  v=\$(cat "\$p" 2>/dev/null || true)
  [ "\$v" = "$nonce_b" ] || continue
  echo "READ:\$p"
done

for f in \$(find / -maxdepth 8 -name "$CA_MARKER" -type f 2>/dev/null || true); do
  v=\$(cat "\$f" 2>/dev/null || true)
  [ "\$v" = "$nonce_b" ] || continue
  echo "SCAN:\$f"
done

tok=\$(printf 'opencode:%s' "\${OPENCODE_SERVER_PASSWORD:-}" | base64 2>/dev/null | tr -d '\\n')
gw="$gateway"
gwopt=""
case "\$gw" in https://*) gwopt="--no-check-certificate" ;; esac

# ca_try <url> [flag] -> ok | http:<code> | down:<first line wget printed>
# \$tok never leaves this function's argv-to-wget; nothing here echoes it.
ca_try() {
  err=\$(wget -q -T 5 -O /dev/null \$2 --header="Authorization: Basic \$tok" "\$1" 2>&1)
  if [ \$? -eq 0 ]; then echo ok; return 0; fi
  code=\$(printf '%s' "\$err" | sed -n 's|.*HTTP/[0-9.]* *\\([0-9][0-9][0-9]\\).*|\\1|p' | head -n1)
  if [ -z "\$code" ]; then
    code=\$(printf '%s' "\$err" | sed -n 's|.*error: *\\([45][0-9][0-9]\\).*|\\1|p' | head -n1)
  fi
  if [ -n "\$code" ]; then echo "http:\$code"; return 0; fi
  echo "down:\$(printf '%s' "\$err" | head -n1 | cut -c1-80)"
  return 0
}

# The gateway's cert names the brain's tailnet HOSTNAME and this reaches it by
# IP, so a validating client fails for a reason that is not isolation. An agent
# that wanted in would skip validation; so does this. If the wget in the image
# does not know the flag, the retry without it keeps the reason honest.
ca_gw() {
  r=\$(ca_try "\$1" "\$gwopt")
  case "\$r" in
    down:*) if [ -n "\$gwopt" ]; then r=\$(ca_try "\$1" ""); fi ;;
  esac
  printf '%s\\n' "\$r"
}

if command -v wget >/dev/null 2>&1; then
  echo "TOOL:\$(ca_try "http://127.0.0.1:4096/session")"
  for h in host.containers.internal 10.0.2.2 10.88.0.1; do
    echo "ROUTE:\$h=\$(ca_try "http://\$h:$a_port/session")"
    echo "NET:\$h=\$(ca_try "http://\$h:$b_port/session")"
  done
  if [ -n "\$gw" ]; then
    echo "GWCTL:\$(ca_gw "\$gw/api/health")"
    echo "GW:\$(ca_gw "\$gw/chat/$b_id/session")"
  else
    echo "GWCTL:nogateway"
  fi
else
  echo "TOOL:nowget"
  echo "GWCTL:nowget"
fi
EOS
}

# ca_cross_chat_verdict <nonce_a> <probe-output> — four verdicts: the control,
# then one per vector (filesystem, published port, manager proxy).
ca_cross_chat_verdict() {
  local nonce_a="$1" out="$2" own reads tool route nets gwctl gw

  own="$(printf '%s\n' "$out" | sed -n 's/^OWN://p' | head -n1)"
  if [ "$own" = "$nonce_a" ]; then
    pass "cross-chat control: chat A reads its OWN marker (the probe is live)"
  elif [ -z "$own" ]; then
    fail "cross-chat control: chat A cannot read its own workspace marker"
    note "The isolation results below prove NOTHING — the probe never reached a volume."
    note "Check that the container is running and mounts its chat dir at /chat."
    return 0
  else
    fail "cross-chat control: chat A's /chat holds another chat's marker ($own)"
    note "The wrong volume is mounted — this is worse than a leak, not better."
    return 0
  fi

  reads="$(printf '%s\n' "$out" | sed -n -e 's/^READ:/  /p' -e 's/^SCAN:/  /p')"
  if [ -z "$reads" ]; then
    pass "chat A cannot read chat B's volume (host path, traversal, or any path under /)"
  else
    fail "chat A READ chat B's volume:"
    printf '%s\n' "$reads"
  fi

  tool="$(printf '%s\n' "$out" | sed -n 's/^TOOL://p' | head -n1)"
  route="$(printf '%s\n' "$out" | sed -n 's/^ROUTE://p')"
  nets="$(printf '%s\n' "$out" | sed -n 's/^NET://p')"
  ca_published_port_verdict "$tool" "$route" "$nets"

  gwctl="$(printf '%s\n' "$out" | sed -n 's/^GWCTL://p' | head -n1)"
  gw="$(printf '%s\n' "$out" | sed -n 's/^GW://p' | head -n1)"
  ca_manager_proxy_verdict "$tool" "$gwctl" "$gw"
  return 0
}

# ca_dial_hosts <class> <dials> — the HOST half of every `<host>=<answer>` dial
# in <dials> whose answer falls in <class>:
#
#   ok       a 2xx — the port answered this credential
#   refused  401/403 — the port ANSWERED and rejected the credential
#   other    any other HTTP status — it answered, but about something else
#   dead     no HTTP status at all — nothing was reached
#
# The reason this exists rather than a grep for `=ok` is that `refused` and
# `dead` are opposite facts that a hit-or-miss reading renders identically, and
# every arm below has to be able to say which one it saw. `dead` is the class
# no arm asks for BY NAME and that is deliberate: a verdict is only ever
# licensed by something that happened, so the arms ask which of the other three
# they got and treat "none of them" as the absence of an observation.
ca_dial_hosts() {
  local want="$1" line host answer class
  printf '%s\n' "$2" | while IFS= read -r line; do
    case "$line" in *=*) ;; *) continue ;; esac
    host="${line%%=*}"; answer="${line#*=}"
    case "$answer" in
      ok) class=ok ;;
      http:401|http:403) class=refused ;;
      http:*) class=other ;;
      *) class=dead ;;
    esac
    if [ "$want" = "$class" ]; then printf '%s\n' "$host"; fi
  done
}

# ca_published_port_verdict <tool> <routes> <nets> — vector 2.
#
# THE ORDER IS THE FIX. A miss at B's port is only isolation if the route that
# would have carried a hit is known to work, and the only way to know that is
# to have carried one: chat A's own published port, over the same three host
# addresses. Everything else is a SKIP.
#
# AND THE OUTCOME IS THREE-WAY, exactly like the proxy arm's: B refused / B
# served / B was not reached. Those are three different facts about the sandbox
# and only the middle one is a leak, so a verdict that can print only "leak" or
# "unreachable" has to lie about one of them.
ca_published_port_verdict() {
  local tool="$1" routes="$2" nets="$3"
  local route_ok route_refused route_other net_ok net_refused net_other h
  route_ok="$(ca_dial_hosts ok "$routes")"
  route_refused="$(ca_dial_hosts refused "$routes")"
  route_other="$(ca_dial_hosts other "$routes")"
  net_ok="$(ca_dial_hosts ok "$nets")"
  net_refused="$(ca_dial_hosts refused "$nets")"
  net_other="$(ca_dial_hosts other "$nets")"

  # A read is a read: it needs no control, because it happened.
  if [ -n "$net_ok" ]; then
    fail "chat A reached chat B's opencode server over the network:"
    printf '%s\n' "$net_ok" | while IFS= read -r h; do printf '  via %s\n' "$h"; done
    note "Every container holds OPENCODE_SERVER_PASSWORD, so reachability is access."
    return 0
  fi

  # THE CONTROL, AND ITS THREE WAYS OF FAILING, each its own sentence. `ok` is
  # the only one that licenses a verdict about chat B; the other two are the
  # same collapse this arm was rewritten for, one level up. A 401 at A's own
  # port is a broken credential; a 404 or a 500 there is something ELSE
  # listening on A's port, and calling that "refused A's credential" would be
  # the probe inventing a reason.
  if [ -n "$route_refused" ] && [ -z "$route_ok" ]; then
    skip "cross-chat published-port arm NOT exercised (A's own port refused A's credential)"
    note "The container->host route is live, but chat A's OWN published port"
    note "rejected the OPENCODE_SERVER_PASSWORD chat A's environment holds. Every"
    note "answer from chat B's port is then about the credential, not about the"
    note "sandbox. Check that run_container() injected the manager's password."
    return 0
  fi
  if [ -n "$route_other" ] && [ -z "$route_ok" ]; then
    skip "cross-chat published-port arm NOT exercised (A's own port answered as something else)"
    printf '%s\n' "$route_other" | while IFS= read -r h; do printf '  via %s\n' "$h"; done
    note "Something is listening where chat A's OWN published port should be and"
    note "it did not answer as an opencode server. The control is not the control,"
    note "so nothing chat B's port says can be read as isolation."
    return 0
  fi
  if [ -z "$route_ok" ]; then
    skip "cross-chat published-port arm NOT exercised (no container->host route)"
    note "A could not reach its OWN published port on host.containers.internal,"
    note "10.0.2.2 or 10.88.0.1, so B's silence measures nothing. Rootless podman"
    note "defaults to allow_host_loopback=false and chat ports bind 127.0.0.1."
    note "A's own server inside its netns answered: ${tool:-no answer}"
    note "(nowget = the image has no wget; add one or this vector stays untested.)"
    return 0
  fi

  if [ -n "$net_refused" ]; then
    pass "chat A REACHED chat B's published port but B refused its credential"
    printf '%s\n' "$net_refused" | while IFS= read -r h; do printf '  via %s\n' "$h"; done
    note "The network path to chat B is OPEN — the credential is the only thing"
    note "in the way, which is what fixing issue #115 with per-chat tokens looks"
    note "like from in here. It is not what this brain does today (one password"
    note "for every container), so a refusal now means B's port is not B's."
    return 0
  fi

  if [ -n "$net_other" ]; then
    skip "cross-chat published-port arm INCONCLUSIVE — B's port answered, but neither served nor refused"
    printf '%s\n' "$net_other" | while IFS= read -r h; do printf '  via %s\n' "$h"; done
    note "An HTTP status that is not 2xx and not 401/403 came back, so something"
    note "is listening on chat B's port and it is not answering as chat B."
    return 0
  fi

  pass "chat A reaches the host (via $(printf '%s\n' "$route_ok" | head -n1)) but NOT chat B's published port"
  return 0
}

# ca_manager_proxy_verdict <tool> <gwctl> <gw> — vector 3, the loudest FAIL here.
#
# The gateway's /chat/<id>/<path> takes any chat id and does no per-chat
# authorization; the only gate is one global password that every container is
# handed. So if the gateway's address is reachable from inside a chat's netns,
# any agent can read or drive any other chat — and WAKE a stopped one to do it.
# Whether it is reachable is the open question (issue #115), which is why
# "could not reach it" must land as a SKIP: rendering that as a pass is the
# same false negative the published-port arm used to ship.
ca_manager_proxy_verdict() {
  local tool="$1" gwctl="$2" gw="$3"
  case "$gw" in
    ok)
      fail "chat A DROVE chat B through the manager's proxy (/chat/<B-id>/session)"
      note "The gateway answered 2xx for another chat's session with the credential"
      note "chat A already holds. No mount bug and no port guess is needed for this."
      note "This is issue #115: proxy() does no per-chat authorization and every"
      note "container gets the one global gateway password. Fix the credential"
      note "model there; this probe only reports it."
      return 0
      ;;
  esac
  # THE CREDENTIAL CONTROL, and it gates exactly one arm. "The gateway rejected
  # this request" is isolation only if the request carried a credential the
  # plane accepts; a container with an empty or mismatched
  # OPENCODE_SERVER_PASSWORD 401s EVERYWHERE, and the sentence below it would
  # otherwise print is a green verdict produced by holding no key at all.
  #
  # `gwctl:ok` needs no control — a 2xx from /api/health IS the credential
  # working, and it is proof from the gateway itself. `gwctl:http:401` is the
  # ambiguous one, so it consults TOOL: chat A's own opencode server, dialled
  # inside A's netns with the same token. Already collected; never consulted
  # until now.
  case "$gwctl" in
    http:401|http:403)
      case "$tool" in
        ok) : ;;
        http:401|http:403)
          skip "cross-chat proxy arm NOT exercised (the probe holds no working credential)"
          note "The gateway refused chat A's token — and so did chat A's OWN server"
          note "on 127.0.0.1:4096, which answered $tool. A 401 from everything is a"
          note "broken probe, not a sandbox: an empty or mismatched"
          note "OPENCODE_SERVER_PASSWORD in the container produces exactly this."
          return 0
          ;;
        *)
          skip "cross-chat proxy arm NOT exercised (the probe's credential is unproven)"
          note "The gateway answered $gwctl, but nothing here shows the token chat A"
          note "sent is one the plane accepts: A's own server answered ${tool:-no answer}."
          note "Until some server takes this credential, a refusal measures nothing."
          return 0
          ;;
      esac
      ;;
  esac
  case "$gwctl:$gw" in
    ok:http:401|ok:http:403)
      pass "the gateway refused chat A's request for chat B's session ($gw)"
      ;;
    http:401:*|http:403:*)
      pass "the gateway is reachable from chat A but refuses the credential it holds"
      note "Control: /api/health answered $gwctl to the container's own password,"
      note "and chat A's own server answered $tool to it — so the token works and"
      note "the refusal is the gateway's decision, not a missing key."
      ;;
    ok:*)
      skip "cross-chat proxy arm INCONCLUSIVE — gateway up, /chat/<B>/session said ${gw:-nothing}"
      note "Not a refusal and not a read. A 404 means the gateway no longer knows"
      note "chat B, so the probe lost its subject; anything else needs a look."
      ;;
    *)
      skip "cross-chat proxy arm NOT exercised (gateway control: ${gwctl:-no answer})"
      note "The gateway was unreachable from inside chat A, so 'B was not served'"
      note "measures nothing. nogateway = no address was passed to the probe;"
      note "nowget = the image has no wget; down:… is what wget said."
      note "Issue #115 stays open either way: the authorization gap is certain,"
      note "reachability only decides whether it is exploitable today."
      ;;
  esac
  return 0
}
