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

# probe_cross_chat_reach <a_container> <b_container> <b_id> <b_dir> <b_port>
#
# THE ONE PROBE HERE THAT TESTS BEHAVIOUR RATHER THAN POLICY. Two chats exist;
# each container stages a nonce in its OWN workspace — through the container,
# not from the host, because a rootless podman volume's files belong to a
# subordinate uid and a host-side write would fail for a reason that has
# nothing to do with isolation. Then chat A's container is asked to go and get
# chat B's, four ways:
#
#   1. B's volume at its host path (/data/code-agents/chats/<B>/...) — the path
#      B1 names outright.
#   2. Out of A's own mount by relative traversal (/chat/../<B>/...).
#   3. Any path at all: a bounded find(1) for the marker filename anywhere in
#      A's filesystem, compared by CONTENT so A finding its own does not count.
#   4. Over the network: B's opencode server on the host's published port. A
#      filesystem-only probe would miss this entirely, and it is the vector
#      that does not depend on the mount being right.
#
# THE CREDENTIAL IS NEVER PASSED IN. The script reads OPENCODE_SERVER_PASSWORD
# out of the container's OWN environment, which is both the repo's standing
# rule (a credential reaches a process through the environment, never argv —
# `podman exec` argv is world-readable in ps) and the more faithful test: the
# question is what the agent can do with what the agent already has.
#
# EVERY ARM HAS A POSITIVE CONTROL, because the failure mode of a probe like
# this is passing for a reason that has nothing to do with isolation:
#   * filesystem: A must be able to read ITS OWN marker, and it must contain
#     A's nonce. If it cannot, the probe reports that and fails rather than
#     recording four clean misses as four clean misses.
#   * network: A must be able to reach its OWN opencode server on 127.0.0.1
#     inside its netns with the same credential and the same tool. If it
#     cannot, the network arm is reported as NOT EXERCISED (a skip), never as
#     a pass — "wget is missing" and "the host is unreachable" produce the same
#     exit status and mean opposite things.
#
# DOES NOT PROVE: that no vector exists. It proves these four are closed. A
# shared kernel is a shared kernel (issue #17 Phase 3 names micro-VMs).
probe_cross_chat_reach() {
  local a_container="$1" b_container="$2" b_id="$3" b_dir="$4" b_port="$5"
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

  script="$(ca_cross_chat_script "$b_id" "$b_dir" "$b_port" "$nonce_b")"
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

# ca_cross_chat_script <b_id> <b_dir> <b_port> <nonce_b>
#
# Emitted rather than inlined so the harness can read it, and written for
# BUSYBOX ASH (the base image is Alpine): no arrays, no [[, no ${var//}.
ca_cross_chat_script() {
  local b_id="$1" b_dir="$2" b_port="$3" nonce_b="$4"
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
if command -v wget >/dev/null 2>&1; then
  if wget -q -T 5 -O /dev/null --header="Authorization: Basic \$tok" \
      "http://127.0.0.1:4096/session" 2>/dev/null; then
    echo "NETCTL:ok"
  else
    echo "NETCTL:unreachable"
  fi
  for h in host.containers.internal 10.0.2.2 10.88.0.1; do
    wget -q -T 5 -O /dev/null --header="Authorization: Basic \$tok" \
      "http://\$h:$b_port/session" 2>/dev/null || continue
    echo "NET:\$h"
  done
else
  echo "NETCTL:nowget"
fi
EOS
}

# ca_cross_chat_verdict <nonce_a> <probe-output> — three verdicts, one per arm.
ca_cross_chat_verdict() {
  local nonce_a="$1" out="$2" own reads netctl nets

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

  netctl="$(printf '%s\n' "$out" | sed -n 's/^NETCTL://p' | head -n1)"
  nets="$(printf '%s\n' "$out" | sed -n 's/^NET:/  via /p')"
  if [ -n "$nets" ]; then
    fail "chat A reached chat B's opencode server over the network:"
    printf '%s\n' "$nets"
    note "Every container holds OPENCODE_SERVER_PASSWORD, so reachability is access."
  elif [ "$netctl" = "ok" ]; then
    pass "chat A cannot reach chat B's server on the host's published port"
  else
    skip "cross-chat network arm NOT exercised (control: ${netctl:-no answer})"
    note "A's own server was unreachable from inside A, so 'B unreachable' proves nothing."
    note "nowget = the image has no wget; add one, or this vector stays untested."
  fi
  return 0
}
