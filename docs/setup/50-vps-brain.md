# Phase 3 — Stand up the brain

The payoff phase (~3 h). At the end: one always-on Goose agent on a hardened
VPS owns your chat history and your automations; Desktop and iPhone are
windows onto it. **Milestone: the same session visible on Desktop and phone,
and a morning brief that arrives by itself.**

Prerequisites: Phases 1–2 done and verified; Hetzner account + API token
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
   cp terraform.tfvars.example terraform.tfvars   # gitignored — real secrets go here
   ```

   Edit `terraform.tfvars`: `hcloud_token` (from 10-accounts §5),
   `ssh_public_key` (your public key, for bootstrap/rescue), `tailscale_authkey`
   (step 1), plus server type/location/timezone if the defaults don't suit.
   The **timezone matters**: automation crons fire in the brain's local time
   ([`docs/automations.md`](../automations.md)).
3. Apply:

   ```bash
   terraform init
   terraform plan     # read it — it should create a handful of resources, nothing more
   terraform apply
   ```

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
counterpart is `luks-unlock.sh` (step 10).

## 4. Secrets onto the encrypted volume

```bash
agent@brain$ cp /home/agent/personal-ai-setup/config/env/secrets.env.example /data/secrets.env
agent@brain$ chmod 600 /data/secrets.env
agent@brain$ nano /data/secrets.env
```

Fill every variable with the real values from your Keychain/notes:
`OPENCODE_ZEN_API_KEY`, `TOGETHER_API_KEY`, `NTFY_TOPIC`, `NTFY_EMAIL`
(recommended — the address failure alerts are emailed to), `TAVILY_API_KEY`
(optional), `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET` — and
generate the one new secret now:

```bash
openssl rand -hex 32    # → GOOSE_SERVER__SECRET_KEY in /data/secrets.env
```

Keep `GOOSE_SERVER__SECRET_KEY` at hand (password manager): Desktop and the
iOS app authenticate with it in steps 7–8. This file is the brain's entire
secret store — 0600, owned by `agent`, on the encrypted volume, injected into
services via systemd `EnvironmentFile`, never anywhere else.

## 5. Transfer the Google OAuth tokens

Follow [30-google-oauth.md §7](30-google-oauth.md) — either rsync the Mac's
working token directory (`~/.google_workspace_mcp/`) into
`/data/workspace-mcp/` on the brain (path a, fastest) or run the one-time
`ssh -L` consent dance on the brain (path b). Either way the tokens sit on
the encrypted volume; step 6's deploy symlinks `~/.google_workspace_mcp` →
`/data/workspace-mcp` so workspace-mcp finds them at its default location.
Come back when a Gmail tool call works from the brain.

## 6. Deploy the stack

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
- creates the two symlinks that keep state on the encrypted volume:
  `~/.local/share/goose` → `/data/goose-data` (so `sessions.db` — the shared
  history — lives encrypted) and `~/.google_workspace_mcp` →
  `/data/workspace-mcp` (so the Google OAuth tokens do too);
- installs and starts the systemd unit
  (`scripts/vps/systemd/goose-serve.service`): `goose serve` bound to the
  **Tailscale IP**, port **3284**, `--tls`, shared-secret auth,
  `--enable-scheduler`, `Restart=always`, `RequiresMountsFor=/data`;
- runs `scripts/vps/register-schedules.sh` to register the full automation
  roster (note: `budget-checkin` registers **active** — goose 1.x has no pause
  CLI; pause it in the Desktop Scheduler UI or remove it until you have a
  budgeting source) — see [`docs/automations.md`](../automations.md).

Then give the brain a **real TLS certificate** for its tailnet name — iOS
and every stock client trust it natively, and it's a one-liner because
Tailscale mints Let's Encrypt certs for `ts.net` names (this is why
[10-accounts.md §3](10-accounts.md) enabled MagicDNS **and HTTPS
Certificates**):

```bash
agent@brain$ sudo ~/personal-ai-setup/scripts/vps/renew-tls-cert.sh
```

That issues the cert to `/data/tls/` and restarts goose-serve with it; the
weekly `tls-cert-renew.timer` (installed by deploy) keeps it renewed — LE
certs expire in ~90 days, so don't skip the timer. Confirm everything:

```bash
agent@brain$ systemctl status goose-serve
agent@brain$ goose schedule list
# from the Mac — strict TLS must validate with NO -k:
mac$ curl -s -o /dev/null -w '%{http_code}\n' https://<your-brain>.<your-tailnet>.ts.net:3284/status
```

(If you skip the real cert, serve falls back to its self-signed one — then
Desktop must pin the fingerprint from
`journalctl -u goose-serve | grep -i fingerprint`, and iOS clients will
refuse the connection outright.)

## 7. Connect Goose Desktop to the brain

On the Mac, in Goose Desktop: Settings → the remote/server connection pane
(named "Remote server" / advanced settings depending on version — reference:
[remote goose server](https://github.com/aaif-goose/goose/blob/main/documentation/docs/guides/remote-goose-server.md)):

- Address: `https://<your-brain>.<your-tailnet>.ts.net:3284`
- Remote working directory: `/home/agent` (blank sends your Mac's local
  path, which doesn't exist on the brain)
- Secret key: the `GOOSE_SERVER__SECRET_KEY` from step 4
- Certificate fingerprint: **leave empty** when using the real LE cert from
  step 6 — CA validation covers it, and a pinned fingerprint would break at
  the cert's automatic ~60-day renewal. Pin the fingerprint ONLY on the
  self-signed fallback path.

Desktop now shows the **brain's** sessions and the Scheduler UI for the
brain's automations. Sessions you start here execute on the brain and land in
its history. The Mac-local goose remains available as the offline fallback —
that's by design ([20-mac-setup.md](20-mac-setup.md)).

## 8. Pair the iPhone

Follow the fallback chain in [40-phone-setup.md §1](40-phone-setup.md):
headless tunnel attempt from the brain first, then Desktop-initiated tunnel,
then the Telegram gateway, with Pal Chat as the floor. Whichever path sticks,
the test that matters is in the next step.

## 9. VERIFY — the Phase 3 checklist

Two scripts plus five live tests. Run all of it; this phase has the most
moving parts and every test below guards a specific failure mode.

```bash
agent@brain$ /home/agent/personal-ai-setup/scripts/verify/check-brain.sh
# goose-serve service active, serve /status over TLS, the 5-schedule roster,
# an optional run-now live fire, and the manual cross-device checklist

agent@brain$ /home/agent/personal-ai-setup/scripts/verify/check-security.sh --local
# host checks: /data is a real mountpoint (LUKS mounted), secrets.env is 0600,
# ufw active with default-deny incoming, gitleaks scan of the repo clone

# From the Mac — the external probe targets the brain's PUBLIC IP:
./scripts/verify/check-security.sh "$(cd infra/terraform && terraform output -raw server_public_ip)"
# probes ports 22/80/443/3284 over the open internet (not the tailnet) — zero
# ports may answer
```

Then, by hand:

1. **Cross-device session visibility** — start a session in Desktop
   (connected to the brain), send one message; open the phone surface and
   find that session; reply from the phone; see the reply on Desktop. This is
   the milestone that matters: one history, every surface.
2. **Automation fires and delivers** — on the brain:
   `goose schedule run-now --schedule-id morning-brief` → the digest email
   (`Morning brief — <date>`, self-addressed) arrives in your inbox within
   a couple of minutes.
3. **Triage never emails anyone but you** — run-now `inbox-triage`, then
   check Gmail: labels applied and **drafts** created; the only send allowed
   is the recipe's self-addressed "Inbox triage — action needed" summary
   (absent when nothing needs action). If anything left the outbox to any
   other recipient, stop and fix before trusting it on a schedule.
4. **Failures are loud** — force one:
   `scripts/common/run-recipe.sh recipes/does-not-exist.yaml` → a failure
   alert must arrive (emailed to `NTFY_EMAIL` via ntfy's gateway). A silent
   failure path is the one thing this stack isn't allowed to have.
5. **Reboot drill** — step 10, now, while everything is fresh.

## 10. Reboot drill

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

The brain is primary from here on: sessions on it, automations on it, all
state on `/data`. Routine operations:

- **Manage automations** — [`docs/automations.md`](../automations.md)
  (add/edit recipes, run-now, the scheduler-bug fallback flip).
- **Upgrade** — re-run `deploy-vps.sh` after a deliberate `git pull`;
  goose stays version-pinned.
- **Drills and rotation** — [`docs/security.md`](../security.md#operational-drills).
- **Something's wrong** — [`docs/troubleshooting.md`](../troubleshooting.md),
  symptom-indexed.

Next: [60-vault-setup.md](60-vault-setup.md) — the sensitive tier.
