# Coding agents on the brain (herdr)

The brain runs **herdr** (github.com/herdrdev/herdr) — a terminal runtime whose
server owns real terminal panes, each holding a coding-agent CLI. A client
attaches over SSH and renders the panes; the server keeps running when every
client leaves. This replaces the per-chat container plane (deleted 2026-09-24,
`docs/adr/0001`); the concepts doc is [`docs/coding-agents.md`](../coding-agents.md).

You reach the plane from the Mac only — the repo ships no phone client and no
coding agent for the Mac. The agent set is chosen **at setup time** by the
wizard's agent screen (OpenCode ★ and Pi ★ first-class; Claude Code, Codex and
Grok Build in the catalog). This runbook is the hand-run path for the same
thing: `deploy-vps.sh --with herdr --coding-agents <list>`.

## 1. What setup does

One unit, `herdr`, does all of it (config/units/herdr.yaml):

- creates the dedicated **herdr user** whose home IS the encrypted volume
  (`/data/herdr`, login shell `/bin/bash` — a real shell, because the SSH
  remote-attach bridge runs every command through the login shell);
- installs the **digest-pinned** herdr binary at `/data/herdr/bin/herdr`
  (sha256 asserted against `config/pins.yaml`; the official install.sh cannot
  pin);
- seeds the server config with **all six keys explicit** — `onboarding=false`,
  `update.version_check=false`, `update.manifest_check=false`,
  `experimental.pane_history=false`, `session.resume_agents_on_restore=true`,
  `[worktrees] directory=/data/herdr/worktrees` — so upstream defaults at 0.x
  cadence can never change the brain's behavior silently;
- for every **picked** agent: installs the pinned CLI, pre-creates its config
  dir, runs `herdr integration install` where an official integration exists,
  and lands its credential. **Unpicked = nothing written anywhere.**
- copies exactly the picked agents' credential rows + `GITHUB_CODE_AGENT_PAT`
  into `/data/herdr/secrets.env` (0600, owner herdr) — never the goose secret;
- writes the systemd unit: the service sees **only `/data/herdr`** on the
  whole machine (`TemporaryFileSystem=/data:ro` + `BindPaths=/data/herdr` +
  `ProtectHome=true`), and the environment block (HOME, XDG_CONFIG_HOME,
  XDG_STATE_HOME) matches the herdr user's shell init, so the SSH bridge and
  the server resolve the same socket.

Everything herdr writes lives under `/data/herdr`: `config/`, `state/`,
`repos/` (reference-only canonical clones), `worktrees/` (one checkout per
task, branch `agent/<name>`), `bin/`, and the per-agent dirs.

## 2. Issue the git PAT

The coding agents clone and push **as themselves**, in panes, with a
fine-grained GitHub PAT. There is no allowlist file any more — **the
credential's scope IS the allowlist**:

1. GitHub → Settings → Developer settings → Fine-grained personal access
   tokens → Generate new token.
2. **Repository access: Only select repositories** — pick exactly the repos
   the agents should reach. This scope is the gate.
3. Permissions: **Contents: Read and write**, **Pull requests: Read and
   write**. Nothing else.
4. Put the value in `/data/secrets.env` as `GITHUB_CODE_AGENT_PAT=...`.

Rotation is the same as any secret: new token → update `/data/secrets.env` →
re-run `deploy-vps.sh --only herdr` (it rewrites the herdr env) → revoke the
old one at GitHub.

## 3. Fill the credential rows

The herdr env is the **union of the picked agents' rows** per the agent
catalog, copied from `/data/secrets.env` on every deploy — add the rows for
the agents you intend to pick, then deploy:

| Picked agent | Row it bills through | Fallback |
|---|---|---|
| OpenCode ★ | `TOGETHER_API_KEY` | — |
| Pi ★ | `TOGETHER_API_KEY` | — |
| Grok Build | `TOGETHER_API_KEY` (BYOK config) | — |
| Claude Code | `ANTHROPIC_API_KEY` (vendor) | `OPENCODE_ZEN_API_KEY` (Zen) |
| Codex | `OPENAI_API_KEY` (vendor) | `OPENCODE_ZEN_API_KEY` (Zen) |

Rules the installer enforces, deterministically:

- **Vendor beats Zen.** When both a vendor key and the Zen key are present,
  the vendor key wins — the wizard displays the vendor as the pick default.
- A picked agent with **neither** row present fails the deploy loudly rather
  than provisioning a half-credentialed pane.
- The goose serve secret is **never** copied into the herdr env, and
  `check-herdr.sh` asserts the exact set against the recorded pick list.

Grok Build rides Together's model catalog; Grok's own models need `XAI_API_KEY`
(paid-only API, a new account) — a documented opt-in the installer never wires.

## 4. Authorize your Mac key for herdr

Clients attach over SSH **as the herdr user** — the server's own user owns the
0600 API socket, and a different SSH identity cannot reach it. So the Mac's
public key must be authorized for `herdr@<brain>`:

```bash
# on the brain (over your normal agent SSH session)
sudo install -d -o herdr -g herdr -m 700 /data/herdr/.ssh
sudo tee /data/herdr/.ssh/authorized_keys < ~/.ssh/authorized_keys >/dev/null   # or paste your Mac key(s)
sudo chown herdr:herdr /data/herdr/.ssh/authorized_keys
chmod 600 /data/herdr/.ssh/authorized_keys
```

Nothing in the installer touches SSH config — this step is yours. The herdr
user has a real login shell (`/bin/bash`) on purpose: sshd runs the remote
attach bridge through it, and the shell init the installer wrote points its
PATH and XDG vars at the same paths the systemd unit uses.

## 5. Attach from the Mac

With the key in place, from the Mac (on the tailnet, with herdr already
installed locally):

```bash
herdr machine add herdr@<your-brain>.<your-tailnet>.ts.net
```

The brain's panes appear next to your local ones. Nothing installs on the Mac
and nothing pins the client — client/server version drift is safe by the
endpoint-generation contract (0.9.x advertises generation 1). Plain
`ssh herdr@<brain>` reaches the same server as a TUI.

## 6. Verify

```bash
./scripts/verify/check-herdr.sh          # from the Mac, with BRAIN_HOST set
# or on the brain itself:
scripts/verify/check-herdr.sh
```

It asserts the service and its namespace contract, the six-key config, the
pick-aware env set against `agents.list`, the pinned binary and agent CLIs,
the isolation boundary (what the herdr user can and cannot read), the 0600
socket, worktree hygiene (no clone ever lands in `worktrees/`), and the
75%-of-volume disk gate.

## 7. Working in panes

- **One canonical clone per repo** at `/data/herdr/repos` — reference only.
  Agents clone in panes with the scoped PAT; herdr never clones.
- **One worktree per task** under `/data/herdr/worktrees`, always on an
  explicit branch: `herdr worktree create --branch agent/<name> --base <ref>`.
  A `.git` directory under `worktrees/` is a clone that landed in the wrong
  place — the check fails until it moves.
- **Deploy when nothing is mid-turn.** Every deploy restarts `herdr.service`;
  the layout and agent sessions resume, but a mid-turn pane does not come
  back mid-turn.
- **Free models never see personal data** (`docs/model-routing.md`, hard rule
  1). This is a docs rule, not a runtime gate: a pane is a full CLI and
  nothing intercepts its model choice.

## 8. Upgrades and version pins

Everything is pinned in `config/pins.yaml` (`herdr:` and `coding_agents:`).
Bump a pin, re-run `deploy-vps.sh --with herdr --coding-agents <list>`, and
the version guards reinstall exactly the moved piece. `herdr update` is never
run — the binary must not update itself (`update.*` checks are off).
