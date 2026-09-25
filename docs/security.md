# Security model

What the brain defends against, how, and the drills that keep the defenses real.
Companion to [privacy.md](privacy.md) (which providers may see what) and
[public-repo.md](public-repo.md) (keeping this repo publishable).

## Threat model

**Defended against:**

| Threat | Defense |
|---|---|
| Stolen/copied disk, provider snapshot, disk disposal | LUKS2 on the `/data` volume — all state encrypted at rest |
| Public-internet scanning and exploitation | Zero public inbound ports (Hetzner Cloud Firewall + ufw); everything rides the tailnet |
| This repo leaking (it's meant to go public) | No secrets by construction; gitleaks pre-commit + CI; go-public checklist |
| Token/key theft in transit or from casual host access | HTTPS/WireGuard everywhere; keys in macOS Keychain / `/data/secrets.env` (0600, on the encrypted volume); goose serve TLS + shared secret + cert pinning |

**Accepted (documented, deliberate):**

- **A live-compromised hypervisor.** While `/data` is unlocked, Hetzner (or an attacker
  with hypervisor access) could read memory. No cloud VPS defends against this; accepted
  per the "cloud with strict policies" stance. See the residual-risk section of
  [privacy.md](privacy.md).
- **A compromised Mac.** Client devices hold pairing credentials and tailnet
  membership by design; device security (FileVault, OS updates) is assumed, not
  provided by this repo.

## Network exposure: zero public inbound ports

Two independent layers deny all public inbound traffic:

1. **Hetzner Cloud Firewall** (Terraform-managed, `infra/terraform/main.tf`): no inbound
   rules at all. Applied at the provider edge, before packets reach the VM.
2. **ufw** on the host (cloud-init): default deny incoming, allow outgoing.

The only path in is the **Tailscale tailnet** — WireGuard, key-authenticated devices,
outbound-only connections, so it works under the deny-all rules. That includes SSH:
after bootstrap, SSH is **Tailscale SSH** (authenticated by tailnet identity, no public
port 22, no host-managed authorized_keys to rot —
[Tailscale SSH docs](https://tailscale.com/kb/1193/tailscale-ssh)). `goose serve` (3284)
binds the Tailscale IP only, never `0.0.0.0`; the herdr plane binds **no TCP at all** —
its whole API is a mode-0600 Unix socket owned by the herdr user
(`check-herdr.sh` asserts both, UN1).

Verify from outside the tailnet after every infra change — `scripts/verify/check-security.sh`
runs an external port scan and fails if anything public answers.

## goose serve hardening

The brain's agent endpoint (`goose serve`, port 3284, systemd unit
`scripts/vps/systemd/goose-serve.service`):

- **Binds the tailnet address** — unreachable off-tailnet even before auth.
- **TLS** (`--tls`) — encrypted even on-tailnet; Goose Desktop pins the
  certificate fingerprint, so a swapped endpoint fails loudly.
- **Shared-secret auth** — `GOOSE_SERVER__SECRET_KEY`, loaded from `/data/secrets.env`
  via systemd `EnvironmentFile`, required from every client.
- **`RequiresMountsFor=/data`** — the service cannot start (and cannot write plaintext
  state to the root disk) unless the encrypted volume is unlocked and mounted.
- **`GOOSE_PATH_ROOT=/data/goose`** — config, data *and* state on the encrypted volume.
  See [the LUKS section](#goose-keeps-state-in-three-places-and-only-one-of-them-was-relocated).
- **`Restart=always`** — survives crashes.
- **The `apps` platform extension is turned off.** goose 1.46.0 ships it *enabled by
  default* (its ACP surface, `_goose/unstable/apps/{list,export,import,delete}`, is listed
  in `crates/goose/acp-meta.json` at the v1.46.0 tag). Tool calls an app initiates are
  dispatched without passing through the permission manager, which makes an imported app
  an unreviewed route to every other extension's tools — shell commands, every MCP tool
  there is. `config/goose/config.yaml` sets `apps: enabled: false`; the brain loses
  nothing, since its client is Goose Desktop. On a brain deployed before
  that template landed, confirm with `goose configure` → Toggle Extensions.

## The coding-agent plane: herdr, the dedicated user and the credential scope

The brain's second agent surface, and the one this page said nothing about until
this section existed. `herdr server` runs under systemd as a dedicated **herdr
user** whose home is the encrypted volume (`/data/herdr`); the unit's namespace
(`TemporaryFileSystem=/data:ro` + `BindPaths=/data/herdr` + `ProtectHome=true`)
makes the service see nothing else on `/data` and nothing of `/home`. Concept
and operations are in [coding-agents.md](coding-agents.md); what belongs here is
the trust boundary and who can move it.

- **No network surface at all.** The whole API is a mode-0600 Unix socket owned
  by the herdr user; `ss -tlnp` must never show a herdr process (UN1). The
  client path is SSH — your normal OpenSSH authentication — with no new port on
  either side.
- **The credential scope IS the allowlist.** The old `repos.json` gate is gone:
  a pane clones whatever the fine-grained `GITHUB_CODE_AGENT_PAT` can reach, so
  the PAT's selected-repositories scope — chosen by you at issue time — is the
  boundary, and GitHub is where it is audited and revoked. The repo records this
  as the TN7 rule: no allowlist file ever comes back.
- **The herdr user cannot reach the stack secrets.** `/data/secrets.env` (0600,
  agent-owned), the life vault, `/home/agent`, the goose sessions database and
  every other user's process environment are out of reach — by permissions, by
  Ubuntu's 0750 homes, and by the kernel's ptrace scope. The herdr env carries
  exactly the picked agents' billing rows and the PAT, never the goose secret;
  `check-herdr.sh` asserts the exact set (T5) and probes the boundary live
  (T8/TN2/TN3).
- **Billing keys, not stack keys.** A pane's environment holds what it needs to
  bill (Together/Zen/vendor rows) and to clone (the PAT). The prompt-injection
  blast radius is the PAT's repo scope and the billing account, not the stack.
- **Panes are not sandboxed beyond that.** herdr ships no sandbox: outbound
  network is unrestricted and a pane can run any program the herdr user can
  execute. That is the same accepted risk the containers carried, recorded in
  herdr.yaml's blockers rather than claimed away.
- **Teardown is manual, by decision.** Nothing in the repo deletes the plane —
  no automated teardown exists (the herdr epic §8). Legacy remnants (the old
  manager unit, port 4300, the automations timers) fail `check-brain.sh`'s
  legacy arm until the human has torn them down by hand.

**One residual worth knowing.** The old manager 403'd Zen's free-model ids on
the wire; a herdr pane is a full CLI and nothing intercepts its model choice.
The privacy rule (free models never see personal data) is now a docs rule —
[model-routing.md](model-routing.md) hard rule 1 — enforced by discipline, not
by a gate. It is the one enforcement the pivot genuinely lost.

## Disk: the LUKS design

A dedicated Hetzner Volume, formatted LUKS2 (`scripts/vps/luks-setup.sh`, one-time),
mounted at `/data`. Everything stateful lives there:

```text
/data
├── secrets.env          # all runtime secrets, chmod 600
├── goose/               # GOOSE_PATH_ROOT — goose's config, data AND state (0700)
│   ├── config/          # config.yaml, .goosehints, memory/, secrets.yaml (0600)
│   ├── data/            # sessions.db — the shared chat history
│   └── state/           # logs/llm_request.*.jsonl — raw provider request/response bodies
├── goose-data -> goose/data   # the old path, kept as a symlink
└── herdr/               # the coding-agent runtime: config, state, repos, worktrees
```

The root disk holds only the OS and this repo's code — nothing *written from now on* is
sensitive — though that is true only because of the path root, the subsection just below,
and only going forward: see the residual note there. The
volume is `noauto` in crypttab/fstab: it does **not** unlock at boot (no passphrase is
stored on the machine). After a reboot the stack is down until you run one command over
SSH:

```bash
sudo /home/agent/personal-ai-setup/scripts/vps/luks-unlock.sh
```

which prompts for the passphrase, opens and mounts the volume, and starts `goose-serve`.
Manual unlock is the accepted cost of not storing the key server-side; reboots are rare
(unattended-upgrades only forces them for kernel updates).

### goose keeps state in three places, and only one of them was relocated

Worth its own heading because it was wrong for a while, and "the root disk holds nothing
sensitive" was therefore false as written. goose splits its state across three XDG
directories — `~/.config/goose`, `~/.local/share/goose`, `~/.local/state/goose` — and the
original design symlinked only the middle one. Config (including `secrets.yaml`) and state
(including `logs/llm_request.*.jsonl`, the **raw request and response bodies** exchanged
with inference providers) were left on the unencrypted root disk.

`GOOSE_PATH_ROOT=/data/goose` in `goose-serve.service` relocates all three together
(verified against goose 1.46.0) — and `goose-serve` is the only unit on the box that
runs a goose process, so it is the only unit that must. Because a `goose` invoked by
hand over SSH inherits no unit's environment,
`deploy-vps.sh` additionally leaves all three home-directory paths as symlinks into
`/data/goose` — and `scripts/verify/check-security.sh --local` fails if any of them
resolves outside `/data`.

**Residual: the migration does not erase the past.** The move is a cross-device copy plus
unlink; unlinking frees blocks, it does not overwrite them. Anything goose logged before
the path root existed — chat sessions, `secrets.yaml`, raw provider request/response bodies
— may remain **recoverable from the unencrypted root disk until those blocks are reused**.
`deploy-vps.sh` prints this at migration time, and [privacy.md](privacy.md) records it in
the residual-risk section. Treat it as a reason to rotate anything that was in
`secrets.yaml` pre-migration, and to destroy (not resell/hand back) the root volume if the
server is ever decommissioned — a snapshot of it taken earlier is likewise still
plaintext.

This matters more once connectors exist, not less: a credential typed in an
interactive client is
written by goose to `<config_dir>/secrets.yaml`, mode 0600. That is deliberate —
per-extension `envKeys` are what keep one connector's credential out of every other
connector's process environment (goose does no `env_clear`) — but it is only an acceptable
trade with the config dir on the LUKS volume. Full write-up in [privacy.md](privacy.md);
the manifest-side contract is in
[`config/connectors/README.md`](../config/connectors/README.md).

## Secrets handling, per platform

- **Mac** — everything in the macOS Keychain via `scripts/mac/keychain-secrets.sh`
  (wraps `security add-generic-password` / `find-generic-password`; the store prompt
  never puts the secret in shell history). It asks for the secrets kept there by the
  units you *name* with `--units`, defaulting to `base` + `default_on`; the same roster,
  names and prompts only, is what `pai secrets --host mac` prints — read "The bare form
  is not an audit of your Keychain" below before treating it as one. It then regenerates
  the marked export block in `~/.zshrc` in place, leaving every line outside the markers
  untouched. Where `~/.zshrc` is a symlink into a dotfiles repo it writes *through* the
  link and takes the mode from the file at the end of it, so a file naming every
  credential on the machine never lands at the symlink's own 0755. Goose itself keeps
  provider keys in the Keychain by default — **never set `GOOSE_DISABLE_KEYRING`** on the
  Mac, which would downgrade to a plaintext `secrets.yaml`.
- **Brain** — headless Linux has no keyring, so stack-wide secrets live in
  `/data/secrets.env`, `chmod 600`, owned by `agent`, on the encrypted volume, injected
  via systemd `EnvironmentFile`. The variable roster (names only) is
  `config/env/secrets.env.example`. Per-extension credentials go somewhere else on
  purpose — goose's own store, `/data/goose/config/secrets.yaml` (0600), reached through
  each extension's `env_keys` — so that one connector's credential is not in every other
  connector's environment. Both files are on `/data`; neither is ever read back to a
  client (`config/read` on a secret returns a usable prefix in clear).
- **Git** — nothing, ever. Enforced by `.gitignore`, the gitleaks pre-commit hook, and
  CI; audited by the [public-repo.md](public-repo.md) checklist.

**The roster is not written down here.** It was, and it drifted: this paragraph listed
nine names against `secrets.env.example`'s fourteen and `keychain-secrets.sh`'s ten. Ask
the manifests instead — they are what both the prompts and the checked
[credential checklist](setup/10-accounts.md#credential-checklist) come from:

```bash
pai secrets --host mac                            # the base + default_on roster
pai secrets --host mac --units herdr             # one add-on's Keychain names
pai secrets --host mac --all                      # every name the catalog can put there
pai secrets --host vps                            # what /data/secrets.env must hold
```

**The bare form is not an audit of your Keychain.** It projects the *default* selection
— every `base` and `default_on` unit — and nothing in it knows which add-ons you actually
installed, so on a Mac running `herdr`-era add-ons and `connectors` it still prints two
names. Name the add-ons with `--units`, or use `--all`, when the question is "does my
Keychain hold everything it should".

Outside env vars entirely, and therefore outside every roster above: the LUKS passphrase
(password manager only) and the Tailscale auth key (typed at the Terraform prompt, never
written to `terraform.tfvars`).

## Host hygiene

- Dedicated non-root **`agent`** user runs everything; no other services on the box.
- SSH: keys-only from first boot (cloud-init), then Tailscale SSH; password auth never
  enabled.
- **unattended-upgrades** for automatic security patches.
- Goose pinned to 1.x (2.0 is in RC churn); upgrades are deliberate, via the deploy
  script, not automatic.

## Operational drills

Run these on a schedule — an untested recovery path is a broken one.

### Reboot/unlock drill (quarterly, and after any kernel update)

1. `sudo reboot` on the brain.
2. Wait ~1 min; confirm the node returns on `tailscale status` from the Mac.
3. `ssh agent@<your-brain>.<your-tailnet>.ts.net` (Tailscale SSH).
4. `sudo /home/agent/personal-ai-setup/scripts/vps/luks-unlock.sh` — enter the passphrase
   from your password manager.
5. `systemctl status goose-serve` shows active; run `scripts/verify/check-brain.sh`.

### Key rotation

Rotate on any suspicion of exposure, and annually as routine. Pattern is always: generate
new → update stores (Keychain on Mac, `/data/secrets.env` on brain) → restart consumers
(`sudo systemctl restart goose-serve`) → revoke old.

| Secret | Where to rotate | Notes |
|---|---|---|
| `OPENCODE_ZEN_API_KEY` | Zen console (opencode.ai) | Keychain on the Mac (goose's Zen providers and the verify scripts read it), `/data/secrets.env` on the brain. The bootstrap no longer writes any OpenCode credential file |
| `TOGETHER_API_KEY` | Together dashboard → API keys | Keychain on the Mac and `/data/secrets.env` on the brain |
| `GOOSE_SERVER__SECRET_KEY` | Generate locally (`openssl rand -hex 32`) | Update secrets.env, restart goose-serve, re-enter on the Desktop client |
| Tailscale | Admin console → Machines / Keys | Auth keys are one-time (bootstrap); rotate device keys by re-authing; remove stale devices |
| `GITHUB_CODE_AGENT_PAT` | GitHub → Settings → Developer settings → Fine-grained tokens | The scope IS the allowlist (no repos.json exists any more). Update `/data/secrets.env`, then re-run `deploy-vps.sh --only herdr` to rewrite the herdr env, then revoke the old token at GitHub — panes hold it until the env is rewritten |
| LUKS passphrase | `sudo cryptsetup luksChangeKey /dev/disk/by-id/<volume>` | Update the password manager first; test unlock before closing the session |
| SSH bootstrap key | `ssh-keygen`, update tfvars + Hetzner | Rarely needed once Tailscale SSH is live |

### If the brain goes silent

Check `tailscale status` from the Mac; if the node is offline, use the Hetzner console
(web VNC) to inspect. Most common cause after an unplanned reboot: `/data` locked —
run the unlock drill. Full triage in [troubleshooting.md](troubleshooting.md).
