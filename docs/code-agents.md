# Code agents: per-chat OpenCode containers on the brain

Claude Code-style autonomous coding sessions, self-hosted. Every code chat runs
in **its own container** on the brain, works in its own workspace on a dedicated
branch, streams live to your devices, asks permission before anything gated
(including `git push`), and delivers a PR. Idle chats spin down to zero
CPU/RAM and wake with everything intact when you tap them.

Companion docs: [setup/70-code-agents.md](setup/70-code-agents.md) (the
runbook), [model-routing.md](model-routing.md) and [privacy.md](privacy.md)
(the rules that bind model choice), [security.md](security.md) (the network
posture all of this lives under). Product definition + acceptance criteria:
repo issue #17; the app workstream: goose-phone-app#2.

## The pieces

| Piece | Role |
|---|---|
| `code-agent:local` image | OpenCode + git + gh on the official OpenCode base (`config/code-agents/Containerfile`) |
| Chat container | One per chat: `opencode serve` on a loopback port, CPU/mem-capped, only its own volume mounted |
| Chat volume | `/data/code-agents/chats/<id>/` — `workspace/` (the repo clone, on an `agent/<id>` branch) + `home/` (opencode config, auth, the chat's own transcript DB, caches). The chat's ENTIRE state; survives spin-down and image upgrades |
| Session manager | `scripts/vps/code-agent-manager.py` under `code-agent-manager.service`: create/wake/stop/delete, the metadata index, idle spin-down, and the TLS+auth gateway that fronts every chat on the tailnet (port 4300) |
| Repo allowlist | `/data/code-agents/repos.json` (from `config/code-agents/repos.example.json`) — the trust boundary; untracked, per-user |
| Clients | goose-phone-app's Code tab (primary), the OpenCode desktop app, or any browser at a chat's URL — all through the gateway |

## How a chat lives

1. **Create** (app "new session", or
   `POST /api/chats {"repo","task","model"?,"base"?}`):
   the manager checks the allowlist, validates `base` against GitHub before it
   builds anything, makes the volume, clones the repo — from `base` when one
   was named, otherwise the repo's default HEAD — and checks out `agent/<id>`
   *in a throwaway container* (the PAT arrives only as
   an env var — nothing token-shaped is written to disk), runs the repo's
   declared `setup` command if any, renders the chat's opencode config, seeds
   Zen auth, and starts the container. Commits in this workspace use the
   `code-agent` git identity — never your personal one.
2. **Work**: the agent codes autonomously. Explicitly gated actions —
   `git push` by default, anything you add to the permission config — block
   until you answer the ask on whatever device you're on. Everything else
   runs without asks (`--auto` posture; explicit denies always hold).
3. **Idle spin-down**: no traffic and no busy session for
   `CODE_AGENT_IDLE_SECONDS` (default 15 min) → the container is stopped.
   The volume — code, branch, uncommitted working tree, transcript — stays.
4. **Wake**: any request to the chat (opening it in the app is enough) starts
   the container again; the app shows your cached transcript instantly while
   that happens.
5. **Deliver**: you ask for a PR; the agent pushes its branch (approve the
   ask) and runs `gh pr create`. Merging is yours. A delivered branch means
   the volume is disposable.
6. **Delete**: removes the container; `?purge=1` removes the volume too.
   Stopped chats are otherwise kept — delete them when the footprint warning
   in `check-code-agents.sh` says so.

## Git: conventions, not walls

The **default** flow is branch-per-chat + PR — it is what makes review work
from a phone. It is deliberately *not* enforced by credential tricks: the
agent holds the (fine-grained, allowlist-scoped) PAT inside its container and
does its own git work, exactly like Claude Code. The guardrail is the
permission system: `git push*` is `ask` unless a repo's allowlist entry sets
`"allow_push": true`. Approve a push to `main` and it happens — your repos,
your call.

## Trust, isolation, and the honest limits

- **The allowlist is the trust boundary.** OpenCode ingests `AGENTS.md` and
  `.claude/` (CLAUDE.md, skills) from whatever it clones — repo content can
  steer the agent, and nobody is watching a headless run. Only list repos you
  own or trust. (`OPENCODE_DISABLE_CLAUDE_CODE*` env vars exist upstream if
  you ever want repo-supplied config off.)
- **The container is the blast-radius bound.** A chat sees its own volume and
  nothing else: no `/data/secrets.env`, no life vault, no goose history, no
  other chat's files. Its environment carries only what it needs — model
  key(s) + the git PAT. CPU/memory caps keep a test suite from starving the
  interactive brain. `check-code-agents.sh --probe` verifies all of this.
- **Egress is unrestricted (accepted risk, MVP).** The agent's shell can
  reach the internet — it needs the model APIs and GitHub anyway. Combined
  with repo-content injection this is a data-exfiltration path; the accepted
  posture is: trusted repos only, container-bounded secrets, and a Phase 2
  upgrade to an allowlist proxy (OpenCode honors `HTTPS_PROXY`).
- **Session-to-session isolation is per-container**, restored by this design;
  micro-VMs (Firecracker/gVisor-class) are the Phase 3 hardening if wanted.

## Models, privacy, cost

- Default model: `opencode/deepseek-v4-flash` (Zen paid open — cheap,
  Tier-3-safe posture, big context). Pick **any** catalog model per chat;
  the routing table row and hard rules live in
  [model-routing.md](model-routing.md).
- **Zen free models are refused** unless the repo is flagged
  `public_throwaway` — free models train on your data
  ([privacy.md](privacy.md) hard rule 1). The manager enforces this at
  create time.
- **Only Tier 1/2 repos are allowlistable.** The life vault never goes in
  `repos.json` (the verify script fails if it appears). If a chat trips over
  something sensitive anyway: abort it — never continue.
- Cost: `opencode stats` inside a chat (or aggregated per project) reports
  tokens **and dollars**. A typical deepseek-v4-flash chat is cents; the Zen
  account cap remains the runaway backstop.

## Operations quick reference

```bash
# state of the world
curl -u opencode:$OPENCODE_SERVER_PASSWORD https://<brain>:4300/api/chats

# start a chat from a shell (the app is the normal surface)
curl -u opencode:$OPENCODE_SERVER_PASSWORD -X POST https://<brain>:4300/api/chats \
  -H 'Content-Type: application/json' \
  -d '{"repo":"personal-ai-setup","task":"fix the flaky verify script"}'

# what the app's base-branch picker shows (default marked)
curl -u ... https://<brain>:4300/api/repos/<name>/branches

# wake / stop / delete
curl -u ... -X POST   https://<brain>:4300/api/chats/<id>/wake
curl -u ... -X POST   https://<brain>:4300/api/chats/<id>/stop
curl -u ... -X DELETE 'https://<brain>:4300/api/chats/<id>?purge=1'

# logs
journalctl -u code-agent-manager -f        # manager + lifecycle
podman logs code-agent-<id>                # one chat's opencode server

# health
scripts/verify/check-code-agents.sh --probe

# full integration test — NO containers, NO VPS, no API key: the manager
# runs for real against a stub engine + a protocol-faithful mock OpenCode
# server. It walks the whole lifecycle: auth, guards, clone/branch/setup,
# base branches (listing them, cutting a chat from one, and refusing a bad
# one without building anything), SSE live-streaming through the proxy, the
# blocking permission flow, busy-guarded idle spin-down, wake with state
# intact, purge — plus the agent notifications, against a recording fake ntfy
# (fires once per edge, never re-fires, and the payload carries no content).
scripts/verify/test-code-agent-manager.sh
# ...or keep the same stack up to drive other clients at it
# (e.g. goose-phone-app: cargo run -p opencode-client --example smoke):
scripts/verify/test-code-agent-manager.sh --serve

# the two Python gates CI runs on every push — run them before you push
ruff check .    # strict lint: the whole rule set (ruff.toml)
mypy            # strict typing over every .py (mypy.ini)

# coverage of the manager: the same harness, with the interpreter swapped.
# CI does this on every push and reports to Coveralls (see .coveragerc).
MANAGER_PY="coverage run --parallel-mode --data-file=$PWD/.coverage" \
  scripts/verify/test-code-agent-manager.sh
coverage combine --data-file="$PWD/.coverage"
coverage report --data-file="$PWD/.coverage"    # ~81% of the manager today
```

Tunables (env on the unit, defaults in the manager): `CODE_AGENT_IDLE_SECONDS`
(900), `CODE_AGENT_MAX_ACTIVE` (2 — the cpx21 guideline; a create/wake beyond
it queues nothing, it refuses with a clear message), `CODE_AGENT_MEM` (1200m),
`CODE_AGENT_CPUS` (1.5), `CODE_AGENT_PORT` (4300).

**A chat parked on a permission ask does not count toward `MAX_ACTIVE`.** It
has to be exempt, because a blocked session reports busy on `/session/status`,
so the reaper reads it as working and refreshes its activity clock on every
pass — it can never go idle again while the ask is unanswered. Counting it
would mean two ignored asks take the whole plane offline, with the 409 advising
you to wait for an idle spin-down that provably cannot arrive.
`GET /api/health` reports `blocked` alongside `active` so `active: 3,
max_active: 2` reads as the state it is; the running-container count can exceed
the cap by the number of asks nobody has answered yet.

## Getting told (optional)

Set `NTFY_AGENT_TOPIC` and the phone buzzes once when a turn ends, and once —
at high priority — when an agent parks waiting for permission to push. The
second is the one that matters: a blocked agent is doing nothing at all until
you answer it. Subscribe the ntfy app to that topic
([setup §6a](setup/10-accounts.md)); leave the variable empty and nothing is
sent.

It rides the reaper's existing sweep, so the latency is up to
`CODE_AGENT_REAPER_INTERVAL` (60s), and every read it makes goes direct to
`127.0.0.1:<chat port>` rather than through the gateway proxy — going through
the proxy would mark each chat active and pin every container open, which is
the failure mode the idle spin-down exists to prevent.

What it will and will not tell you:

- **One buzz per turn**, not one per tool call. The manager arms a chat when it
  proxies an accepted prompt and fires when that chat next reports idle, so a
  five-tool turn is a single notification with no debounce timer involved.
- **Stopping a turn yourself is not news** — an abort disarms without firing.
  Neither does an idle spin-down, a delete or a crash.
- **"A turn ended", not "done".** Nothing here can tell a clean completion from
  a provider error without reading the transcript, which is exactly what it
  must not do.
- **The payload carries nothing** — a kind, an opaque handle and a count. No
  repo name, no chat title, no command. See
  [privacy.md](privacy.md#the-agent-channel-ntfy_agent_topic--a-second-choke-point-not-a-second-rule);
  the buzz says "go look" and the app tells you what happened.
- **It does not survive a deploy.** Restarting the manager stops every chat
  container (`ExecStopPost`), which destroys OpenCode's in-memory pending-ask
  map — so an ask survives the phone sleeping and survives idle spin-down, but
  not a `deploy-vps.sh` or a crash loop. Deploy when nothing is mid-turn.
- Probe chats (`check-code-agents.sh --probe`, the verify harness) never buzz.

## Failure behavior

Create/wake failures alert through the standard channel (`notify.sh` → ntfy,
component + failure class only — never model output). A PR being opened is the
"done" signal — and since the PRs land on your own repos, **GitHub's native
notification email covers delivery** (repo, branch, PR link) with zero extra
plumbing; keep PR notifications on for your account. The manager and
every chat are gated on `/data` (`RequiresMountsFor`), so after a reboot the
whole plane stays down until `luks-unlock.sh` — then recovers by itself.
Symptom-indexed fixes: [troubleshooting.md](troubleshooting.md).
