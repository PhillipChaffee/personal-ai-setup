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

## Why code-agent chats are not in the shared history

The README's first principle is *one brain, one history*: the hub agent runs only
on the VPS, its `sessions.db` is the single chat history, and every device is a
client to the same brain. This add-on is the one deliberate carve-out from that,
and the carve-out belongs here rather than in the README because the base install
does not contain it — a reader who never installs code agents should not have to
learn an exception to a rule they will never hit.

**A code chat's transcript lives in its own per-chat volume, never in
`sessions.db`.** Each chat gets `/data/code-agents/chats/<id>/home/`, which holds
that chat's own OpenCode config, auth and transcript database. Nothing about a
code chat is written into the hub agent's history, and nothing in the hub agent's
history is visible to a code chat.

Three reasons, in the order they actually decided it:

1. **Isolation is the point of the container.** A chat is handed one repo clone
   and its own volume precisely so that a compromised or confused agent cannot
   reach anything else. A shared history file that every chat could read and
   write would be a hole straight through that boundary — and it would be the
   one file in the system holding your life-admin conversations.
2. **They are different agents.** The hub is `goose`; a code chat is `opencode`
   in a container. They have different transcript formats, different tool
   surfaces and different lifecycles (a code chat spins down when idle and wakes
   with its state intact). Merging the two stores would mean inventing a
   translation layer that no feature asks for.
3. **Coding volume would drown the history.** An autonomous coding session emits
   orders of magnitude more turns than a conversation. The value of `sessions.db`
   is that "continue what I was saying" works from any device; a shared store
   would bury that under diff chatter.

What *is* unified is the client: the phone app's Code tab and your chat live in
the same application, and the manager's index is what makes the list of chats the
same on every device. The unification is in the UI, on purpose — not in the store.

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

### "Agent-authored" is a convention, and here is how you find out it stopped

`config/code-agents/AGENTS.md` is the container's standing instruction file —
the manager renders it into every chat volume beside the opencode config, where
opencode loads it as global instructions for whatever repo the chat cloned. It
tells the agent to open its pull requests itself and to put
`Agent-authored: …` first in the body.

**Nothing enforces that.** The agent writes the body; the manager performs no
git operation after create-time and never touches the PR. An agent that omits
the line produces a pull request indistinguishable from a human's, and no check
in this repo can make it otherwise.

There *is* a test that the instruction file names the marker
(`test-code-agent-manager.sh`), and it is worth being precise about what it
does: it is a **drift-lock between two strings in this repo**, not evidence
about any pull request. `AGENTS.md`'s label and the `AGENT_PR_MARKER` constant
the manager greps for have to stay spelled the same, because renaming one
without the other makes every pull read `agent_authored: false` — which is
indistinguishable from a model that quietly stopped following the convention.

What exists instead is an **observable**: the manager's GitHub sweep reads each
pull request's body and reports `agent_authored` on `GET /api/pulls` and
`GET /api/chats/<id>/pulls` — `true` when the marker is there, `false` when it
is not, and **absent** when GitHub sent no body (the field is a measurement, so
"not asked" is not "no"). A convention that quietly stopped being followed
shows up as a `false` on a list you already look at.

The commit identity is separate and *is* enforced by the manager: it configures
`code-agent <code-agent@brain.invalid>` in the workspace at clone time, so a
delivered branch carries no personal name or email (issue #17 C4).

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
  interactive brain. `check-code-agents.sh --probe` verifies this **on the
  brain it is run on**: it stands a second chat up and makes chat A go after
  chat B three ways, one verdict each —
  1. **the filesystem**, tried at B's host path, by relative traversal out of
     A's own mount, and by a `find` over A's filesystem to a stated depth
     (`CA_SCAN_DEPTH`, 12 — deep enough to reach another chat's workspace
     inside rootless podman's own `…/storage/overlay/<id>/diff/` tree),
     compared by content. That is one vector tried three ways, not three
     vectors: the scan subsumes the other two *within its bound*, which is why
     the verdict prints the bound and why the two named paths are still tried
     by name.
  2. **chat B's published port on the host**, with the server password A's own
     container holds. Since #115 that is A's OWN derived secret and not B's, so
     a refusal here is now the expected answer even if the port is reachable.
  3. **the manager's own `/chat/<id>/<path>` proxy** — the shortest path of the
     three, needing neither a mount bug nor a port guess (see the proxy note
     below).

  Every arm's positive control exercises *that arm's own precondition*: A must
  read its own marker, and the **scan** must hand that same marker back before
  "nothing else anywhere" means anything; A must reach **its own** published
  port over a host address before B's silence at the same address means
  anything; A must reach the gateway's `/api/health`, and where the gateway
  answers 401 the probe first checks that A's own server both *takes* A's token
  and *refuses* a deliberately wrong one — a server enforcing nothing accepts
  everything, which is a chat holding no key rather than a plane refusing it. A
  miss whose instrument was never shown to work is reported as a SKIP, never
  counted as isolation. CI runs the same probes against fixtures
  (`test-verify-checks.sh`), which proves the probes fire — it proves nothing
  about podman.
- **The gateway proxy is still not per-chat authorized** — `/chat/<id>/<path>`
  authorizes no ids against callers, and `authed()` answers only "do you know
  the password". Anything holding `OPENCODE_SERVER_PASSWORD` (the app, anyone
  on the tailnet) reaches every chat.
  **What issue #115 closed is the narrower half: a chat container is no longer
  one of those holders.** Each container is baked with
  `HMAC-SHA256(OPENCODE_SERVER_PASSWORD, "code-agent/<epoch>/<chat-id>")`
  instead — derived, never stored, and useful only against that chat's own
  server on its own loopback port. So a code agent that can route to the
  gateway now gets a 401 there. Whether a container *can* route there is what
  the probe's third arm measures, and it is now measuring a refusal rather
  than a breach.
  Two things it does **not** fix, both deliberate: per-chat authorization in
  `proxy()` (see the previous paragraph), and `GH_TOKEN` — the same
  fine-grained PAT still goes into every container, because GitHub does not
  mint per-chat tokens.
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
- **The envelope this plane has to fit inside.** Code agents open no new
  account — the tokens bill to the Zen and Together lines already in the
  README's budget table, and the only new resource is disk. The whole stack is
  budgeted at **~$15–35/mo against ~$50 of headroom**
  ([README](../README.md#budget), [setup overview](setup/00-overview.md)), so
  the room a code chat has is roughly **$15/mo of token spend** before the
  total leaves that envelope. That is a lot of cents-per-chat work and very
  little of a large model run in a loop, which is why the default is
  `deepseek-v4-flash` and why `CODE_AGENT_MAX_ACTIVE` is 2. Check it the same
  way you'd check any other line: `opencode stats` per chat, the provider's own
  usage page for the month.

## The manager's whole HTTP surface

Every route below is authenticated (HTTP Basic, or `?auth_token=` for
EventSource); there is no unauthenticated path. Thirteen API rows plus the proxy
— **not** the five that issue #17 C1's "exposes exactly" sentence names. Rows,
not paths: `/api/chats` and `/api/repos` are each served under two verbs, and
the gate below is derived at verb granularity for exactly that reason.

**This table is generated-equivalent, not hand-maintained.**
`test-code-agent-manager.sh` derives the surface by driving the dispatcher —
every path its routing tables name, crossed with every verb it answers — and
asserts that the rows below equal that set exactly, in both directions, and
that the manager's own module docstring does too. A route added without a row
here fails the harness; so does a row here for a route that no longer exists,
and so does a **verb** added to a path that is already listed. Only a `|` table
row counts: the sentence about `GET /api/chats/<id>/pulls` further up this page
is prose and cannot stand in for a row.

| Route | What it does |
|---|---|
| `GET /api/health` | liveness, engine/image, chat counts, `active`/`blocked`, sweep stamp |
| `GET /api/repos` | the allowlist (names + flags) |
| `POST /api/repos` | add one entry: `{"name","url","tier"}` + optional `setup`/`edit_only`/`allow_push`/`public_throwaway`. `url` must be `https://github.com/<owner>/<repo>`, and the PAT must be able to read **that** repo — both **before** writing |
| `GET /api/repos/<name>/branches` | one allowlisted repo's branches, default marked |
| `GET /api/chats` | the metadata index merged with live container state (+ per-tree change stat) |
| `GET /api/permissions` | permission asks parked on every running chat |
| `GET /api/pulls` | every chat's pull requests, from the sweep's cache |
| `GET /api/chats/<id>/pulls` | one chat's pull requests, live from GitHub |
| `POST /api/chats` | create: allowlist check → volume → clone → branch → setup → container |
| `POST /api/chats/<id>/wake` | start a stopped chat's container |
| `POST /api/chats/<id>/stop` | stop a running chat's container |
| `POST /api/chats/<id>/pulls/<n>/merge` | merge one of that chat's pull requests |
| `DELETE /api/chats/<id>[?purge=1]` | remove the container; `purge` removes the volume |
| `* /chat/<id>/<path>` | reverse proxy to that chat's opencode server, waking it first |

The proxy is a **wildcard**: everything after the chat id is forwarded verbatim
to that chat's server, with no route allowlist of its own. That is deliberate —
the app and the OpenCode desktop client both speak the full opencode API — and
it is why the `/share` refusal has to come from the chat's own resolved config
(`"share": "disabled"`, probed by `check-code-agents.sh --probe`) rather than
from a blocked route here.

The `<id>` is **not authorized against the caller**, and that is not deliberate.
Authentication here answers "do you know the password", never "which chat are
you", so anything that can reach this gateway with the password can drive any
chat. That residual is the open half of issue #115.

What #115 closed is the chat containers' part in it: a container no longer
holds the gateway password. It is baked with
`HMAC-SHA256(OPENCODE_SERVER_PASSWORD, "code-agent/<epoch>/<chat-id>")`, which
opens that chat's own opencode server and nothing else — the manager derives it
per request and stores it nowhere. The epoch is an integer on each index entry
(`cred_epoch`), never the secret; a container below the current epoch is
recreated from its volume on wake, on proxy, and in one sweep at startup,
because `podman start` reuses env baked at create and so can never hand a
container a new credential.

The epoch only tracks a change to *this repo's source*, though. Rotating
`OPENCODE_SERVER_PASSWORD` changes every derived secret without moving it, so
those containers are found the other way: they answer the manager 401, and a
401 from a chat's own server means exactly one thing — rebuild it from the
volume and send the request again. That happens once per chat, at its first
wake or request after the rotation, and the caller sees the answer rather than
the 401 (`scripts/verify/test-code-agent-manager.sh` section 9f).

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

# every chat's pull requests in ONE request, from the manager's cache
curl -u ... https://<brain>:4300/api/pulls

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

## The pull-request cache

`GET /api/pulls` answers every chat's pull requests at once, from a snapshot a
background thread refreshes every `CODE_AGENT_GITHUB_INTERVAL` (300s). The
per-chat `GET /api/chats/<id>/pulls` still exists and is unchanged — it is the
interactive one, and it spends GitHub calls because a reader just asked for
them. The aggregate exists because the app's table polls, and the same table
swept client-side across 24 chats on a ten-second poll is 34,560 GitHub requests
an hour: 691% of a fine-grained PAT's budget.

Every chat in the index is named in exactly one of three places, and they are
three different claims:

| where | means |
|---|---|
| `pulls["<id>"]` | GitHub answered. `[]` means **nothing is open** — a measurement. |
| `unreachable` | GitHub was asked and would not say. **Retryable.** Render "unknown", never "nothing". |
| `no_remote` | Nothing to ask: a `_probe` chat, or a repo that left the allowlist. **Settled**, not retryable. |

A chat in `unreachable` or `no_remote` is **absent from `pulls` entirely** — it
is never given an empty list, because an empty list is a measurement and a
failure is not one. `as_of` is when the sweep that produced the answer started;
`as_of == 0.0` means no sweep has completed yet (a cold cache after a restart),
which is otherwise indistinguishable from GitHub being down for every chat at
once. `/api/health`'s `github_at` carries the same stamp, so a sweep thread that
died is visible from outside.

The route always answers 200: it serves a cache, and failure is per chat and
already on the wire.

## The per-tree change stat

The same sweep measures each tree's branch against its base with one GitHub
`compare` call, so `GET /api/chats` can carry a size for every row **without
waking a single container**. The only other source of change size is
`/chat/<id>/session/<sid>/diff`, which goes through the proxy and starts the
container — eight sleeping trees would mean eight cold starts.

```json
"stat": { "ahead": 3, "behind": 0, "commits": 3,
          "files": 7, "additions": 1769, "deletions": 289,
          "truncated": false }
```

**An absent `stat` is not zero, and the app must not render it as one.**

| situation | `stat` |
|---|---|
| branch pushed, ahead of base | present, exact |
| compare is `identical` | present, **all zeros** — a real measurement |
| **branch never pushed** (compare 404s) | **absent** |
| more than 300 files | present, `truncated: true` — `ahead`/`behind`/`commits` stay exact, the rest are lower bounds |
| GitHub failed, or the base could not be resolved | absent, and the chat is in `unreachable` |

That third row is the one that matters most: `allow_push` defaults to **false**,
so pushing is a permission ask and "never pushed" is the **dominant steady
state** for a sleeping tree. A row that draws an absent stat as "0 files
changed" will lie about most trees. Draw nothing, or draw "unknown".

Two more honest edges: `commits` is GitHub's `ahead_by`, not `total_commits`
(only `ahead_by` stays exact past GitHub's 10,000-commit cap); and the stat
measures the last **pushed** commit, while the `diff` route measures the working
tree — two numbers on one row that can legitimately disagree.

## Notifications

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
