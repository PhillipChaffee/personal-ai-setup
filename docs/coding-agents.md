# Coding agents on the brain

The brain runs a set of coding agents inside **herdr**
(github.com/herdrdev/herdr) — a terminal runtime whose server owns real
terminal panes. Each pane holds a shell or an agent CLI. Clients attach over
SSH and render the panes; the server keeps running when every client leaves.

This plane replaced the per-chat container plane on 2026-09-24
([`docs/adr/0001`](adr/0001-pivot-to-herdr-and-wizard-front-door.md)); the
runbook is [`docs/setup/70-coding-agents.md`](setup/70-coding-agents.md).

## The shape

- **One server, real panes.** `herdr server` runs under systemd as a dedicated
  low-privilege user whose home IS the encrypted volume (`/data/herdr`). Real
  PTYs, no containers. The systemd sandbox makes the service see only
  `/data/herdr` on the whole machine: `TemporaryFileSystem=/data:ro` turns the
  rest of the LUKS volume into an empty read-only mount, `BindPaths` binds the
  home back in writable, and `ProtectHome=true` removes `/home` entirely.
- **The agent set is chosen at setup time.** The wizard's agent screen (and
  `deploy-vps.sh --coding-agents`) carries the catalog: OpenCode ★ and Pi ★
  first-class (official herdr integrations — lifecycle authority), plus
  Claude Code, Codex and Grok Build in the catalog (session-identity wiring
  where herdr offers none). Unpicked means nothing written anywhere.
- **The Mac attaches as a client.** `herdr machine add herdr@<brain>` — the
  SSH target is the herdr user, because that user owns the 0600 Unix socket.
  No coding agent installs on the Mac; the repo plans around no phone client.
- **Billing is the default biller** (Together AI) unless a pick chose Zen or
  its vendor key; the credential rows are copied pick-aware into
  `/data/herdr/secrets.env` and asserted exactly by `check-herdr.sh`.

## Why coding-agent work is not in the shared history

The hub's `sessions.db` is the single chat history, and every Goose surface —
Desktop, CLI — is a client to the same brain. Coding agents deliberately do
NOT join it, and the reason is the same as under the old plane:

1. **Different lifecycle.** A pane is a working session tied to a git
   worktree and a task, not a conversation with one memory. It lives and dies
   with its worktree; the hub's history persists.
2. **Different credential model.** The herdr user holds billing keys and a
   scoped git PAT — never the stack secrets (`GOOSE_SERVER__SECRET_KEY`,
   provider keys) that the hub's environment carries. Sharing one history
   would mean sharing one trust boundary; the isolation model (herdr.yaml's
   notes) exists so it never has to.
3. **Different observability.** `herdr api` (the 0600 socket) and the pane
   itself are the surfaces for what an agent is doing — blocked, working,
   done — not the hub's chat log.

## What carries over from the old plane

- **Isolation by dedicated user plus namespace.** A pane can run any program
  and reach the network, and can read only what the herdr user can read: not
  `/data/secrets.env`, not the life vault, not `/home/agent`, no sudo, and —
  by the namespace — nothing on `/data` outside `/data/herdr`. `check-herdr.sh`
  probes all of it live, with positive controls.
- **The git credential is the allowlist.** The old `repos.json` gate is gone;
  the fine-grained PAT's scope is the gate (TN7).
- **Deploy when nothing is mid-turn.** A herdr restart restores layout and
  resumes agent sessions, but pane processes die on stop.
- **The disk gate** (75% of the volume, T9) and the clone-vs-worktree hygiene
  (T10) carry over into `check-herdr.sh`.

## What the pivot genuinely lost

The old manager refused Zen's free-model ids on the wire (a runtime 403). A
herdr pane is a full CLI with the billing env, and nothing intercepts its
model choice — the privacy rule lives in
[`docs/model-routing.md`](model-routing.md) hard rule 1 instead. That is the
one enforcement the pivot lost, and it is recorded as a blocker in herdr.yaml
rather than silently accepted.
