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
- **`Restart=always`** — survives crashes; `--enable-scheduler` keeps automations alive.

## Disk: the LUKS design

A dedicated Hetzner Volume, formatted LUKS2 (`scripts/vps/luks-setup.sh`, one-time),
mounted at `/data`. Everything stateful lives there:

```
/data
├── secrets.env          # all runtime secrets, chmod 600
├── goose-data/          # symlink target of ~/.local/share/goose
│   └── sessions.db      # the shared chat history — encrypted at rest
├── life-vault/          # clone of the SEPARATE private vault repo
└── (Google OAuth tokens, MCP state)
```

The root disk holds only the OS and this repo's code — nothing on it is sensitive. The
volume is `noauto` in crypttab/fstab: it does **not** unlock at boot (no passphrase is
stored on the machine). After a reboot the stack is down until you run one command over
SSH:

```bash
sudo /home/agent/personal-ai-setup/scripts/vps/luks-unlock.sh
```

which prompts for the passphrase, opens and mounts the volume, and starts `goose-serve`.
Manual unlock is the accepted cost of not storing the key server-side; reboots are rare
(unattended-upgrades only forces them for kernel updates).

## Secrets handling, per platform

- **Mac** — everything in the macOS Keychain via `scripts/mac/keychain-secrets.sh`
  (wraps `security add-generic-password` / `find-generic-password`; the store prompt
  never puts the secret in shell history). Goose itself keeps provider keys in the
  Keychain by default — **never set `GOOSE_DISABLE_KEYRING`** on the Mac, which would
  downgrade to a plaintext `secrets.yaml`.
- **Brain** — headless Linux has no keyring, so secrets live in `/data/secrets.env`,
  `chmod 600`, owned by `agent`, on the encrypted volume, injected via systemd
  `EnvironmentFile`. The variable roster (names only) is
  `config/env/secrets.env.example`.
- **Git** — nothing, ever. Enforced by `.gitignore`, the gitleaks pre-commit hook, and
  CI; audited by the [public-repo.md](public-repo.md) checklist.

The full secret roster: `OPENCODE_ZEN_API_KEY`, `TOGETHER_API_KEY`,
`GOOSE_SERVER__SECRET_KEY`, `NTFY_TOPIC`, `NTFY_EMAIL`, `TAVILY_API_KEY` (optional),
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
| `OPENCODE_SERVER_PASSWORD` | Generate locally (`openssl rand -hex 32`) | Update secrets.env, `sudo systemctl restart code-agent-manager`, re-enter in the app's Code settings. Container env is baked at creation: recreate each chat's container to rotate it there too (`podman rm code-agent-<id>`, then wake — the volume keeps all state) |
| `GITHUB_CODE_AGENT_PAT` | GitHub → Settings → Developer settings → Fine-grained tokens | Keep scope: allowlisted repos only, Contents + Pull requests. Update secrets.env, restart code-agent-manager; new chats get the new token immediately, existing chats after a container recreate (`podman rm` + wake, volume preserved) |
| LUKS passphrase | `sudo cryptsetup luksChangeKey /dev/disk/by-id/<volume>` | Update the password manager first; test unlock before closing the session |
| SSH bootstrap key | `ssh-keygen`, update tfvars + Hetzner | Rarely needed once Tailscale SSH is live |

### If the brain goes silent

Check `tailscale status` from the Mac; if the node is offline, use the Hetzner console
(web VNC) to inspect. Most common cause after an unplanned reboot: `/data` locked —
run the unlock drill. Full triage in [troubleshooting.md](troubleshooting.md).
