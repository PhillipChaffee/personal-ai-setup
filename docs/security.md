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
[Tailscale SSH docs](https://tailscale.com/kb/1193/tailscale-ssh)). `goose serve` (3284)
and `code-agent-manager` (4300) each bind the Tailscale IP only, never `0.0.0.0`; the
per-chat OpenCode servers behind the manager bind **loopback** and are reachable only
through it.

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

## The code plane: the manager, the containers and the allowlist

The brain's second agent endpoint, and the one this page said nothing about until
this section existed. `code-agent-manager.py` (port **4300**, systemd unit
`code-agent-manager.service`) fronts one `opencode serve` container per code chat.
Concept and operations are in [code-agents.md](code-agents.md); what belongs here
is the trust boundary and who can move it.

- **Same network posture as `goose serve`** — binds the tailnet address, TLS from
  the brain's tailnet cert, HTTP Basic on every route including the proxy. There is
  no unauthenticated path.
- **`/data/code-agents/repos.json` is the boundary.** A chat can only ever be made
  from a repo listed there, so the file — not the PAT, not the tailnet — is what
  decides where a code agent can read and write. It is untracked, per-user, and
  `deploy-vps.sh` never clobbers it, so **no deploy restores it if it is lost**.
- **Only Tier 1/2 repos may be listed** ([privacy.md](privacy.md)); the life vault
  and anything Tier 3 never enter it. That is a human judgment and cannot be
  validated server-side, which is why `POST /api/repos` **requires** `tier` in the
  request body, refuses `3`, and refuses an absent one rather than defaulting.
- **An authorisation that can reach a repo is still not an allowlist entry.** The
  PAT is scoped to a set of repos; `repos.json` is a strictly smaller set that you
  chose. A GitHub connection must never imply an entry, which is why the route
  takes a URL you typed rather than offering a list to pick from
  ([#99](https://github.com/PhillipChaffee/personal-ai-setup/issues/99) is deferred
  on exactly that ground). The route's GitHub check is a **precondition**, not a
  grant: it only refuses repos the PAT cannot read.
- **Two flags default to the safe value and are never inferred.**
  `allow_push: true` makes `git push` run with no permission ask;
  `public_throwaway: true` permits Zen free models, which per the provider table
  may train on your data. Both default `false`, both are read strictly — a body
  saying `"allow_push": "false"` is **refused**, never read as truthy — and neither
  is ever guessed from the repo's GitHub visibility. A public repo is not
  automatically a throwaway.

### What the write route rests on, since #115 is fixed

`POST /api/repos` widens the trust boundary, so the question is who can reach it.
`authed()` answers only "do you know `OPENCODE_SERVER_PASSWORD`", and that used to
include **every code agent**: `run_container` handed each container the gateway's
own password as its `OPENCODE_SERVER_PASSWORD`. A prompt-injected agent in one repo
could then have added another repo to the allowlist and opened a chat on it —
lateral movement becoming privilege escalation.

That is [#115](https://github.com/PhillipChaffee/personal-ai-setup/issues/115) and
it is **fixed**. Each container now gets a derived per-chat secret,
`HMAC-SHA256(OPENCODE_SERVER_PASSWORD, "code-agent/<epoch>/<chat-id>")`, which opens
that chat's own server on its own loopback and nothing else; the gateway password
never enters a container. So the callers of the write route are the ones that were
always meant to hold that password, and the route needs **no second secret and no
out-of-band confirmation** — the two compensating controls it would otherwise have
required. (An `ntfy` confirmation was never available anyway: a notification is
never itself answerable, [privacy.md](privacy.md).)

**Residual, and it is the same one the proxy has.** `authed()` is still a single
shared secret with no per-chat identity, so anything *else* holding it — the phone
app, anyone on the tailnet — can both drive any chat and now widen the allowlist.
Rotate `OPENCODE_SERVER_PASSWORD` (below) on any suspicion; every agent that ran
before #115 held the old value. Separately, and **not** fixed by that mechanism:
every container still receives the same `GITHUB_CODE_AGENT_PAT` as `GH_TOKEN`, so
one chat can reach any allowlisted repo, not only its own. GitHub will not mint a
per-chat PAT.

**The file is never destroyed by a failed write.** The writer reads the raw JSON
and refuses on anything it cannot parse — it deliberately does not go through
`load_repos()`, which answers "empty allowlist" for a corrupt file (the safe
direction for a reader, catastrophic for a writer). Writes are a temp file plus a
rename, with the file and its directory fsynced, so a concurrent reader sees the
whole old file or the whole new one and a crash cannot leave an empty boundary.
`_readme` and every entry's `tier` survive byte-for-byte.

## Disk: the LUKS design

A dedicated Hetzner Volume, formatted LUKS2 (`scripts/vps/luks-setup.sh`, one-time),
mounted at `/data`. Everything stateful lives there:

```text
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
pai secrets --host mac --units google-workspace   # one add-on's Keychain names
pai secrets --host mac --all                      # every name the catalog can put there
pai secrets --host vps                            # what /data/secrets.env must hold
```

**The bare form is not an audit of your Keychain.** It projects the *default* selection
— every `base` and `default_on` unit — and nothing in it knows which add-ons you actually
installed, so on a Mac running `google-workspace` and `ntfy-alerts` it still prints two
names. Name the add-ons with `--units`, or use `--all`, when the question is "does my
Keychain hold everything it should".

Outside env vars entirely, and therefore outside every roster above: the LUKS passphrase
(password manager only), the Tailscale auth key (typed at the Terraform prompt, never
written to `terraform.tfvars`), the `life-vault` deploy key, and the Google OAuth token
files on `/data`.

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
| `OPENCODE_ZEN_API_KEY` | Zen console (opencode.ai) | Also re-run `scripts/mac/opencode-auth.sh` on the Mac to rewrite `~/.local/share/opencode/auth.json` |
| `TOGETHER_API_KEY` | Together dashboard → API keys | Also update Pal Chat on the phone |
| `GOOSE_SERVER__SECRET_KEY` | Generate locally (`openssl rand -hex 32`) | Update secrets.env, restart goose-serve, re-enter on Desktop and iOS clients |
| Tailscale | Admin console → Machines / Keys | Auth keys are one-time (bootstrap); rotate device keys by re-authing; remove stale devices |
| Google OAuth client secret | GCP console → Credentials | Re-run the workspace-mcp auth flow; re-transfer tokens per `docs/setup/30-google-oauth.md` |
| `NTFY_TOPIC` | Pick a new random topic | Update secrets.env + Keychain; old topic is burned |
| `NTFY_AGENT_TOPIC` | Pick a new random topic | The code-agent buzz channel, rotated INDEPENDENTLY of `NTFY_TOPIC` — that separation is the whole reason it is a second variable. Update secrets.env + Keychain, `sudo systemctl restart code-agent-manager`, then re-subscribe the phone's ntfy app to the new topic. Unlike every other row here this is not only a read credential: whoever holds it can also SEND, i.e. put a notification on your lock screen, so rotate on any suspicion at all. Removing the phone from the tailnet does **not** revoke it — delivery goes over the public internet, never the tailnet. Leaving it empty turns the feature off outright |
| `OPENCODE_SERVER_PASSWORD` | Generate locally (`openssl rand -hex 32`) | Update secrets.env, `sudo systemctl restart code-agent-manager`, re-enter in the app's Code settings. **No `podman rm` by hand.** Since #115 a container's password is `HMAC-SHA256(this value, "code-agent/<epoch>/<chat-id>")`, so changing this changes every derived secret; container env is baked at creation and `podman start` reuses it, so a container from before the rotation can only be *rebuilt*, never fixed. It rebuilds itself lazily, per chat, at the first wake or request after the restart: the container answers the manager 401, the manager rebuilds it from the volume and retries, and the caller sees a normal 200. Note the restart alone does NOT do it — the startup sweep only sees a bumped `CRED_EPOCH`, which a rotation does not move — so a chat you never open stays on the old secret until you open it, which is harmless. Every agent that ran before #115 held the OLD value, so rotate when deploying it |
| `GITHUB_CODE_AGENT_PAT` | GitHub → Settings → Developer settings → Fine-grained tokens | Keep scope: allowlisted repos only, Contents + Pull requests. Update secrets.env, restart code-agent-manager; new chats get the new token immediately, existing chats after a container recreate (`podman rm` + wake, volume preserved) |
| LUKS passphrase | `sudo cryptsetup luksChangeKey /dev/disk/by-id/<volume>` | Update the password manager first; test unlock before closing the session |
| SSH bootstrap key | `ssh-keygen`, update tfvars + Hetzner | Rarely needed once Tailscale SSH is live |

### If the brain goes silent

Check `tailscale status` from the Mac; if the node is offline, use the Hetzner console
(web VNC) to inspect. Most common cause after an unplanned reboot: `/data` locked —
run the unlock drill. Full triage in [troubleshooting.md](troubleshooting.md).
