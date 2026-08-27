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
- **A compromised phone or Mac.** Client devices hold pairing credentials and tailnet
  membership by design; device security (passcode, FileVault, OS updates) is assumed, not
  provided by this repo.
- **The lock screen, once `NTFY_AGENT_TOPIC` is set.** Subscribing a phone to the
  code-agent channel puts a rendering surface outside the tailnet and outside the app
  container: notifications arrive on a *locked* screen, and iOS's Show Previews setting is
  per-device and unreadable from the brain. This is accepted only because the payload is
  content-free by construction — a kind, an opaque handle and a count, never a repo name,
  a chat title or a tool argument ([privacy.md](privacy.md)). The topic name is also a
  **write** capability in that direction: anyone who learns it can plant a plausible-looking
  notification there, which is why the notification is never itself answerable and why the
  app re-reads the real ask over the tailnet before offering any button.

## Network exposure: zero public inbound ports

Two independent layers deny all public inbound traffic:

1. **Hetzner Cloud Firewall** (Terraform-managed, `infra/terraform/main.tf`): no inbound
   rules at all. Applied at the provider edge, before packets reach the VM.
2. **ufw** on the host (cloud-init): default deny incoming, allow outgoing.

The only path in is the **Tailscale tailnet** — WireGuard, key-authenticated devices,
outbound-only connections, so it works under the deny-all rules. That includes SSH:
after bootstrap, SSH is **Tailscale SSH** (authenticated by tailnet identity, no public
port 22, no host-managed authorized_keys to rot —
[Tailscale SSH docs](https://tailscale.com/kb/1193/tailscale-ssh)). `goose serve` binds
the Tailscale IP only, never `0.0.0.0`.

Verify from outside the tailnet after every infra change — `scripts/verify/check-security.sh`
runs an external port scan and fails if anything public answers.

## goose serve hardening

The brain's agent endpoint (`goose serve`, port 3284, systemd unit
`scripts/vps/systemd/goose-serve.service`):

- **Binds the tailnet address** — unreachable off-tailnet even before auth.
- **TLS** (`--tls`) — encrypted even on-tailnet; clients (Goose Desktop, iOS app) pin the
  certificate fingerprint, so a swapped endpoint fails loudly.
- **Shared-secret auth** — `GOOSE_SERVER__SECRET_KEY`, loaded from `/data/secrets.env`
  via systemd `EnvironmentFile`, required from every client.
- **`RequiresMountsFor=/data`** — the service cannot start (and cannot write plaintext
  state to the root disk) unless the encrypted volume is unlocked and mounted.
- **`GOOSE_PATH_ROOT=/data/goose`** — config, data *and* state on the encrypted volume.
  See [the LUKS section](#goose-keeps-state-in-three-places-and-only-one-of-them-was-relocated).
- **`Restart=always`** — survives crashes; `--enable-scheduler` keeps automations alive.
- **The `apps` platform extension is turned off.** goose 1.46.0 ships it *enabled by
  default* (its ACP surface, `_goose/unstable/apps/{list,export,import,delete}`, is listed
  in `crates/goose/acp-meta.json` at the v1.46.0 tag). Tool calls an app initiates are
  dispatched without passing through the permission manager, which makes an imported app
  an unreviewed route to every other extension's tools — Gmail send, the shell, the vault.
  `config/goose/config.yaml` sets `apps: enabled: false`; the brain loses nothing, since
  its clients are Goose Desktop, the iOS app and the scheduler. On a brain deployed before
  that template landed, confirm with `goose configure` → Toggle Extensions.

## Disk: the LUKS design

A dedicated Hetzner Volume, formatted LUKS2 (`scripts/vps/luks-setup.sh`, one-time),
mounted at `/data`. Everything stateful lives there:

```
/data
├── secrets.env          # all runtime secrets, chmod 600
├── goose/               # GOOSE_PATH_ROOT — goose's config, data AND state (0700)
│   ├── config/          # config.yaml, .goosehints, memory/, secrets.yaml (0600)
│   ├── data/            # sessions.db — the shared chat history — and schedule.json
│   └── state/           # logs/llm_request.*.jsonl — raw provider request/response bodies
├── goose-data -> goose/data   # the old path, kept as a symlink
├── workspace-mcp/       # Google OAuth tokens
├── code-agents/         # per-chat OpenCode volumes + repos.json
└── life-vault/          # clone of the SEPARATE private vault repo
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
(verified against goose 1.46.0); the fallback `goose-recipe@.service` and the
`goose-telegram-gateway.service` set the same value — every unit that runs a goose process
does, or that unit alone would keep writing `llm_request` logs to the root disk and quietly
undo the rest. Because a `goose` invoked by hand over SSH inherits no unit's environment,
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

This matters more once connectors exist, not less: a credential typed on the phone is
written by goose to `<config_dir>/secrets.yaml`, mode 0600. That is deliberate —
per-extension `envKeys` are what keep one connector's credential out of every other
connector's process environment (goose does no `env_clear`) — but it is only an acceptable
trade with the config dir on the LUKS volume. Full write-up in [privacy.md](privacy.md);
the manifest-side contract is in
[`config/connectors/README.md`](../config/connectors/README.md).

## Secrets handling, per platform

- **Mac** — everything in the macOS Keychain via `scripts/mac/keychain-secrets.sh`
  (wraps `security add-generic-password` / `find-generic-password`; the store prompt
  never puts the secret in shell history). Goose itself keeps provider keys in the
  Keychain by default — **never set `GOOSE_DISABLE_KEYRING`** on the Mac, which would
  downgrade to a plaintext `secrets.yaml`.
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

The full secret roster: `OPENCODE_ZEN_API_KEY`, `TOGETHER_API_KEY`,
`GOOSE_SERVER__SECRET_KEY`, `NTFY_TOPIC`, `NTFY_AGENT_TOPIC` (optional), `NTFY_EMAIL`,
`TAVILY_API_KEY` (optional),
`GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET` — plus, outside env vars: the LUKS
passphrase (password manager only), the Tailscale auth key (Terraform tfvars, untracked),
and the Google OAuth token files on `/data`.

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
5. `systemctl status goose-serve` shows active; run `scripts/verify/check-brain.sh`;
   confirm the next scheduled digest email arrives.

### Key rotation

Rotate on any suspicion of exposure, and annually as routine. Pattern is always: generate
new → update stores (Keychain on Mac, `/data/secrets.env` on brain) → restart consumers
(`sudo systemctl restart goose-serve`) → revoke old.

| Secret | Where to rotate | Notes |
|---|---|---|
| `OPENCODE_ZEN_API_KEY` | Zen console (opencode.ai) | Also re-run `/connect` in OpenCode on the Mac |
| `TOGETHER_API_KEY` | Together dashboard → API keys | Also update Pal Chat on the phone |
| `GOOSE_SERVER__SECRET_KEY` | Generate locally (`openssl rand -hex 32`) | Update secrets.env, restart goose-serve, re-enter on Desktop and iOS clients |
| Tailscale | Admin console → Machines / Keys | Auth keys are one-time (bootstrap); rotate device keys by re-authing; remove stale devices |
| Google OAuth client secret | GCP console → Credentials | Re-run the workspace-mcp auth flow; re-transfer tokens per `docs/setup/30-google-oauth.md` |
| `NTFY_TOPIC` | Pick a new random topic | Update secrets.env + Keychain; old topic is burned |
| `NTFY_AGENT_TOPIC` | Pick a new random topic | The code-agent buzz channel, rotated INDEPENDENTLY of `NTFY_TOPIC` — that separation is the whole reason it is a second variable. Update secrets.env + Keychain, `sudo systemctl restart code-agent-manager`, then re-subscribe the phone's ntfy app to the new topic. Unlike every other row here this is not only a read credential: whoever holds it can also SEND, i.e. put a notification on your lock screen, so rotate on any suspicion at all. Removing the phone from the tailnet does **not** revoke it — delivery goes over the public internet, never the tailnet. Leaving it empty turns the feature off outright |
| `OPENCODE_SERVER_PASSWORD` | Generate locally (`openssl rand -hex 32`) | Update secrets.env, `sudo systemctl restart code-agent-manager`, re-enter in the app's Code settings. Container env is baked at creation: recreate each chat's container to rotate it there too (`podman rm code-agent-<id>`, then wake — the volume keeps all state) |
| `GITHUB_CODE_AGENT_PAT` | GitHub → Settings → Developer settings → Fine-grained tokens | Keep scope: allowlisted repos only, Contents + Pull requests. Update secrets.env, restart code-agent-manager; new chats get the new token immediately, existing chats after a container recreate (`podman rm` + wake, volume preserved) |
| LUKS passphrase | `sudo cryptsetup luksChangeKey /dev/disk/by-id/<volume>` | Update the password manager first; test unlock before closing the session |
| SSH bootstrap key | `ssh-keygen`, update tfvars + Hetzner | Rarely needed once Tailscale SSH is live |

### If the brain goes silent

Check `tailscale status` from the Mac; if the node is offline, use the Hetzner console
(web VNC) to inspect. Most common cause after an unplanned reboot: `/data` locked —
run the unlock drill. Full triage in [troubleshooting.md](troubleshooting.md).
