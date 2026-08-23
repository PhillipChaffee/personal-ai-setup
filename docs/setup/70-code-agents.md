# Phase 6 — Code agents (optional add-on)

Claude Code-style coding sessions on the brain: per-chat containers, live
streaming to your devices, permission asks for pushes, PRs as the deliverable.
Concept and day-to-day operations: [`docs/code-agents.md`](../code-agents.md).
Requires Phase 3 (the brain) complete; ~30–45 minutes.

## 1. Create the two secrets

On any machine:

```bash
openssl rand -hex 32     # -> OPENCODE_SERVER_PASSWORD
```

Then the GitHub credential — a **fine-grained** PAT
(github.com → Settings → Developer settings → Personal access tokens →
Fine-grained):

- **Repository access**: *Only select repositories* — exactly the repos you
  will allowlist in step 3. Never "All repositories".
- **Permissions**: Contents (read/write) + Pull requests (read/write).
  Nothing else.
- Expiry: your call; add the rotation to your calendar — the rotation table
  in [`docs/security.md`](../security.md) has the steps.

Add both to `/data/secrets.env` on the brain (names ship in
`config/env/secrets.env.example`):

```
OPENCODE_SERVER_PASSWORD=<the hex string>
GITHUB_CODE_AGENT_PAT=<the fine-grained PAT>
```

## 2. Deploy

```bash
ssh agent@<your-brain>.<your-tailnet>.ts.net
cd ~/personal-ai-setup && ./scripts/vps/deploy-vps.sh
```

The code-agents section installs podman (rootless), builds the
`code-agent:local` image (first build pulls the OpenCode base — a few
minutes), installs `code-agent-manager.service`, and — because both secrets
are now present — enables it. Expect
`code agents: enabled (manager on the tailnet, port 4300)` in the output.

## 3. Fill in the repo allowlist

Deploy copied the template to `/data/code-agents/repos.json` (no-clobber).
Edit it: one entry per repo the agents may touch. The fields are documented
in the file's `_readme`; the rules that matter:

- **Only repos you own or trust** — cloned repo content (AGENTS.md, .claude/)
  steers the agent, and the allowlist is the trust boundary.
- **Only Tier 1/2 repos** ([`docs/privacy.md`](../privacy.md)) — never the
  life vault. The verify script fails if it sees it.
- `allow_push: true` only where you're happy for pushes to skip the
  permission ask. Default (`false`) = every push asks on your device.
- Keep `setup` commands light (2 vCPU / 4 GB) or set `edit_only: true`.

Restart nothing — the manager reads the file per request.

## 4. Verify

```bash
./scripts/verify/check-code-agents.sh --probe
```

The probe creates a scratch chat (no network, no credential), checks the
container cannot reach `/data`, checks the environment carries no stack
secrets, exercises stop → wake with state intact, and deletes it. Everything
should PASS; the manual checklist at the end is for after step 5.

Then confirm the network posture is unchanged, from your Mac:

```bash
./scripts/verify/check-security.sh "$(cd infra/terraform && terraform output -raw server_public_ip)"
```

## 5. Point your clients at it

The code plane speaks HTTP with Basic auth behind the brain's tailnet TLS
cert — server `https://<your-brain>.<your-tailnet>.ts.net:4300`, username
`opencode`, password `OPENCODE_SERVER_PASSWORD`.

- **goose-phone-app** (Code tab — goose-phone-app#2): enter the server +
  credentials in Settings alongside your goose server. One app, Home and
  Code.
- **OpenCode desktop app** (secondary): add a remote server with a chat's
  URL (`.../chat/<id>`) to open that chat directly.
- **Any browser** on the tailnet works against a chat's URL too.

First real run: pick a repo, ask for something small ("tighten the README's
quickstart"), watch it stream, then ask it to open a PR and approve the push
ask when it pops. The PR email arrives from GitHub itself.

## Troubleshooting

Symptom-indexed entries live in
[`docs/troubleshooting.md`](../troubleshooting.md) (manager unreachable,
probe failures, wake timeouts, zen auth). Quick first moves:
`journalctl -u code-agent-manager -n 50` and
`podman logs code-agent-<id>`.
