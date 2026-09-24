# Phase 2 — Stand up the brain

The payoff phase (~3 h). At the end: one always-on Goose agent on a hardened
VPS owns your chat history; Desktop is the window onto
it. **Milestone: your chat history lives on the brain.**

Prerequisites: Phase 1 done and verified; Hetzner account + API token
([10-accounts.md §5](10-accounts.md)); Tailscale MagicDNS + HTTPS enabled
([10-accounts.md §3](10-accounts.md)); a password manager entry ready to
receive the LUKS passphrase. Design background, if you want it before the
doing: [`docs/security.md`](../security.md).

Steps are ordered — each depends on the previous. Commands run on the Mac
unless the prompt says `agent@brain`.

## 1. Terraform: create the infrastructure

Everything Hetzner-side — server (Ubuntu 24.04), SSH key, deny-all cloud
firewall, the data volume, and cloud-init — is declared in
`infra/terraform/`. No console clicking.

1. Generate a **Tailscale auth key** for the VPS: admin console → Settings →
   Keys → Generate auth key — make it **reusable**, **pre-authorized**, and
   **tagged** (e.g. `tag:server`), as `infra/terraform/variables.tf` requires:
   pre-authorized means the node joins with no approval click, and a
   reusable, tagged key survives a re-provision. Auth keys expire (90 days
   max) — regenerate before re-applying.
2. Fill in the variables:

   ```bash
   cd infra/terraform
   cp terraform.tfvars.example terraform.tfvars   # gitignored — NON-SECRET inputs only
   ```

   Edit `terraform.tfvars`: `ssh_public_key` (your public key, for
   bootstrap/rescue), plus server type/location/timezone if the defaults don't
   suit. The **timezone matters**: sessions, logs, and any scheduled work you
   add later run in the brain's local time.

   The two secrets do **not** go in that file. `hcloud_token` (from
   10-accounts §5) and `tailscale_authkey` (step 1) have no default, so
   Terraform prompts for them — you paste each one at the prompt and neither
   is ever written to disk.
3. Apply:

   ```bash
   terraform init
   terraform plan     # read it — it should create a handful of resources, nothing more
   terraform apply
   ```

   Both commands prompt for `hcloud_token` and `tailscale_authkey`; input is
   not echoed. Have the Tailscale key from step 1 on your clipboard.

   Do **not** save the plan to a file (`terraform plan -out=tfplan`). A saved
   plan is a ZIP containing every resolved input variable, including both
   secrets, and it is not human-readable — so a leak inside one is invisible
   to `grep` and to content-based secret scanners. CI rejects tracked plan and
   state files by path for exactly this reason.

Cloud-init then runs unattended on first boot: creates the non-root `agent`
user, sets ufw default-deny, joins the tailnet with the auth key, and
installs the base toolchain including the pinned goose CLI (see
`infra/terraform/templates/cloud-init.yaml.tftpl`).

## 2. Confirm boot, tailnet join, and zero exposure

Give first boot a couple of minutes, then from the Mac:

```bash
tailscale status | grep <brain-hostname>       # the node appears on your tailnet
ssh agent@<your-brain>.<your-tailnet>.ts.net   # Tailscale SSH — the only way in
```

On the brain, confirm provisioning finished cleanly:

```bash
cloud-init status --wait    # must end "done", not "error"
```

There is deliberately **no public SSH**: the Hetzner firewall has no inbound
rules and ufw default-denies, so the tailnet is the only path from the very
first boot. If cloud-init died before the tailnet join (rare), use the
Hetzner web console (VNC) to debug — never "temporarily" open port 22.

## 3. LUKS: create and mount the encrypted `/data` (one-time)

First get this repo onto the brain (the scripts live in it; `deploy-vps.sh`
keeps it updated from here on):

```bash
agent@brain$ git clone https://github.com/<you>/personal-ai-setup /home/agent/personal-ai-setup
```

Then generate a strong passphrase **into your password manager first** — it
will exist nowhere else, and without it a rebooted brain's data is noise
([`docs/security.md`](../security.md#disk-the-luks-design)).

The script refuses to run without an explicit `--device` (it will not guess
a device to destroy; run bare, it only lists candidates). Terraform knows the
volume's stable device path — print it on the Mac, then pass it on the brain:

```bash
# On the Mac — print the data volume's device path, paste it below:
cd infra/terraform && terraform output -raw data_volume_linux_device
# → e.g. /dev/disk/by-id/scsi-0HC_Volume_12345678
```

```bash
agent@brain$ sudo /home/agent/personal-ai-setup/scripts/vps/luks-setup.sh \
  --device /dev/disk/by-id/scsi-0HC_Volume_<id-from-terraform-output>
```

The script `luksFormat`s that device (LUKS2 — prompting for the passphrase
and a typed `FORMAT` confirmation), adds `noauto` crypttab/fstab entries (so
no key is ever stored on the machine and nothing auto-unlocks at boot), and
opens + mounts it at `/data`. One-time only; after any future reboot the
counterpart is `luks-unlock.sh` (step 7).

## 4. Secrets onto the encrypted volume

```bash
agent@brain$ cp /home/agent/personal-ai-setup/config/env/secrets.env.example /data/secrets.env
agent@brain$ chmod 600 /data/secrets.env
agent@brain$ nano /data/secrets.env
```

Fill every variable with the real values from your Keychain/notes:
`OPENCODE_ZEN_API_KEY`, `TOGETHER_API_KEY`, `TAVILY_API_KEY` (optional) — and
generate the one new secret now:

```bash
openssl rand -hex 32    # → GOOSE_SERVER__SECRET_KEY in /data/secrets.env
```

Keep `GOOSE_SERVER__SECRET_KEY` at hand (password manager): Desktop
authenticates with it in step 6. This file is the brain's entire
secret store — 0600, owned by `agent`, on the encrypted volume, injected into
services via systemd `EnvironmentFile`, never anywhere else.

## 5. Deploy the stack

```bash
agent@brain$ /home/agent/personal-ai-setup/scripts/vps/deploy-vps.sh
```

The script is idempotent — it's also the upgrade path later. It:

- clones/updates this repo at `/home/agent/personal-ai-setup`;
- **validates `/data/secrets.env`** (every required variable present) and
  fails early if not;
- **copies** the config templates into place, no-clobber — an existing
  (possibly edited) copy is never overwritten; when a repo template has
  diverged from the live file the script prints a diff hint and leaves the
  merge to you;
- **migrates goose's state onto the encrypted volume** and keeps it there:
  `/data/goose` becomes `GOOSE_PATH_ROOT`, holding `config/` (config.yaml,
  `.goosehints`, `memory/`, `secrets.yaml`), `data/` (`sessions.db` — the
  shared history) and `state/`
  (`logs/llm_request.*.jsonl`, the raw provider request/response bodies).
  `~/.config/goose`, `~/.local/share/goose` and `~/.local/state/goose` are
  symlinked into it, so a `goose` you run by hand over SSH reads the same
  files the service does. Existing session history is moved, never deleted,
  and re-running is a no-op. Rationale: [`docs/privacy.md`](../privacy.md);
- installs and starts the systemd unit
  (`scripts/vps/systemd/goose-serve.service`): `goose serve` bound to the
  **Tailscale IP**, port **3284**, `--tls` (self-signed — clients pin the
  fingerprint), shared-secret auth,
  `Restart=always`, `RequiresMountsFor=/data`,
  `GOOSE_PATH_ROOT=/data/goose`.

### Choosing what gets installed

One of the pieces above is a **selectable unit**; everything else is the
brain core, which always runs:

| unit | what it is | what skipping it costs |
| --- | --- | --- |
| `code-agents` | rootless podman, the `code-agent:local` image, `/data/code-agents`, `code-agent-manager.service` | no code agents ([70-code-agents.md](70-code-agents.md)) |

```bash
# see the plan without touching anything
agent@brain$ ~/personal-ai-setup/scripts/vps/deploy-vps.sh --dry-run

# skip the expensive one: no apt install, no subuid range, no image build
agent@brain$ ~/personal-ai-setup/scripts/vps/deploy-vps.sh --without code-agents
```

`code-agents` is the one worth a decision. Selected, it apt-installs podman +
uidmap + slirp4netns and grants the `agent` user a subordinate id range **on
the first deploy** — both are guarded, so later deploys skip them — and then
enables linger and runs a **multi-minute `podman build`** on **every** deploy,
whether or not the feature is ever enabled. Deselected, none of that happens
and `check-code-agents.sh` reports SKIP rather than FAIL.

Three things to know:

- **The brain core is not selectable.** The path-root migration, the goose
  config install, the systemd unit files, the `goose-serve` restart and the
  `/status` gate run on every invocation, including `--only code-agents`. Every
  selective run prints one line saying so.
- **Deselecting is not uninstalling.** Nothing removes what an earlier deploy
  already installed; `--without code-agents` on a brain that already has the
  plane leaves the image, the volumes, the subuid range and the linger setting
  exactly where they are. `pai remove` does not exist yet.
- **Deselecting is also not freezing.** `--without code-agents` on a brain that
  already has the plane does not restart `code-agent-manager.service`, so a
  deploy whose `git pull` shipped new manager code leaves the **old process**
  serving the new file — with `check-code-agents.sh --probe` still green,
  because the old process answers `/api/health`, `/api/chats`, stop, wake and
  delete identically. A route added in that deploy 404s, and a 404 from a stale
  process is indistinguishable from a route that was never written. This is the
  same `enable --now`-is-a-no-op failure the explicit `systemctl restart` in the
  unit body exists to prevent, now reachable by choice rather than by accident.
  If you deselected the unit and then pulled manager changes, re-run
  `--only code-agents` (or `sudo systemctl restart code-agent-manager.service`).
  Deploy when nothing is mid-turn: the restart SIGTERMs every chat container.

If the unit fails, the deploy stops there and names it — `ERROR: unit
'code-agents' failed`, plus which units completed and which never ran — and
the safety-net trap brings `goose-serve` back up before exiting. Re-run just
that one with `--only code-agents`.

Confirm everything:

```bash
agent@brain$ systemctl status goose-serve
# from the Mac — grab the fingerprint for pinning in step 6:
mac$ ssh agent@<your-brain>.<your-tailnet>.ts.net \
    "sudo journalctl -u goose-serve -n 50 --no-pager" | grep -iE 'listen|fingerprint'
```

`goose serve` runs `--tls` with its **self-signed** cert — there is no CA or
renewal machinery (the phone client it existed for is gone from this repo's
story). Goose Desktop pins the cert fingerprint from the journalctl line
above.

## 6. Connect Goose Desktop to the brain

On the Mac, in Goose Desktop: Settings → the remote/server connection pane
(named "Remote server" / advanced settings depending on version — reference:
[remote goose server](https://github.com/aaif-goose/goose/blob/main/documentation/docs/guides/remote-goose-server.md)):

- Address: `https://<your-brain>.<your-tailnet>.ts.net:3284`
- Remote working directory: `/home/agent` (blank sends your Mac's local
  path, which doesn't exist on the brain)
- Secret key: the `GOOSE_SERVER__SECRET_KEY` from step 4
- Certificate fingerprint: **pin the SHA-256 fingerprint** from the
  journalctl line printed at the end of the deploy — goose serve runs a
  self-signed cert, so CA validation does not apply.

Desktop now shows the **brain's** sessions. Sessions you start here execute
on the brain and land in its history. The Mac-local goose remains available
as the offline fallback — that's by design
([20-mac-setup.md](20-mac-setup.md)).

## 7. VERIFY — the Phase 2 checklist

Two scripts plus live tests. Run all of it; this phase has the most
moving parts and every test below guards a specific failure mode.

```bash
agent@brain$ /home/agent/personal-ai-setup/scripts/verify/check-brain.sh
# goose-serve service active, serve /status over TLS, and the manual checklist

agent@brain$ /home/agent/personal-ai-setup/scripts/verify/check-security.sh --local
# host checks: /data is a real mountpoint (LUKS mounted), secrets.env is 0600,
# ufw active with default-deny incoming, gitleaks scan of the repo clone

# From the Mac — the external probe targets the brain's PUBLIC IP:
./scripts/verify/check-security.sh "$(cd infra/terraform && terraform output -raw server_public_ip)"
# probes ports 22/80/443/3284/4300/4310 over the open internet (not the
# tailnet) — zero ports may answer. 4300/4310 are the code plane: the gateway
# and a per-chat opencode server (docs/code-agents.md)
```

Then, by hand:

1. **Session lands in the shared history** — start a session in Desktop
   (connected to the brain), send one message, and see the reply land in the
   brain's history. This is the milestone that matters: one history.
2. **Reboot drill** — step 8 below, now, while everything is fresh.

## 8. Reboot drill

Reboots are rare but the recovery path must be muscle memory
([`docs/security.md`](../security.md#operational-drills)):

```bash
agent@brain$ sudo reboot
# wait ~1 min; from the Mac:
tailscale status                                  # node returns
ssh agent@<your-brain>.<your-tailnet>.ts.net
agent@brain$ sudo /home/agent/personal-ai-setup/scripts/vps/luks-unlock.sh
# prompts for the LUKS passphrase (password manager), mounts /data, starts goose-serve
agent@brain$ systemctl status goose-serve         # active
agent@brain$ /home/agent/personal-ai-setup/scripts/verify/check-brain.sh
```

Until `luks-unlock.sh` runs, the stack is deliberately down
(`RequiresMountsFor=/data` blocks the service) — the brain never writes
plaintext state to the unencrypted root disk. That manual unlock is the
accepted cost of storing no key server-side.

## Done — and day-2 operations

The brain is primary from here on: sessions on it, all
state on `/data`. Routine operations:

- **Upgrade** — re-run `deploy-vps.sh` after a deliberate `git pull`;
  goose stays version-pinned.
- **Drills and rotation** — [`docs/security.md`](../security.md#operational-drills).
- **Something's wrong** — [`docs/troubleshooting.md`](../troubleshooting.md),
  symptom-indexed.

Next: [`docs/public-repo.md`](../public-repo.md) — guardrails, then the flip.
