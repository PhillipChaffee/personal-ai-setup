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
  Nothing else. (The app's base-branch picker reads
  `/repos/:owner/:repo/branches` and `/repos/:owner/:repo`, which need only the
  mandatory `Metadata: read` every fine-grained PAT carries — no extra
  permission, nothing to re-issue.)
- Expiry: your call; add the rotation to your calendar — the rotation table
  in [`docs/security.md`](../security.md) has the steps.

Add both to `/data/secrets.env` on the brain (names ship in
`config/env/secrets.env.example`):

```ini
OPENCODE_SERVER_PASSWORD=<the hex string>
GITHUB_CODE_AGENT_PAT=<the fine-grained PAT>
```

## 2. Deploy

```bash
ssh agent@<your-brain>.<your-tailnet>.ts.net
cd ~/personal-ai-setup && ./scripts/vps/deploy-vps.sh --only code-agents
```

`--only code-agents` runs the brain core (which is never skippable) plus this
one unit, which is what you want when the rest of the brain is already
deployed. A plain `./scripts/vps/deploy-vps.sh` does the same thing plus the
other three units; both are fine here.

The unit installs podman (rootless), builds the `code-agent:local` image
(first build pulls the OpenCode base — a few minutes), installs
`code-agent-manager.service`, and — because both secrets are now present —
enables it. Expect `code agents: restarted (manager on the tailnet, port
4300)` in the output.

**This is the one unit worth deselecting if you do not want it.** It is opt-in
now: `./scripts/vps/deploy-vps.sh --without code-agents` skips the apt
install, the subuid range, the linger setting and the image build entirely, and
`check-code-agents.sh` then reports SKIP instead of FAIL. Note that skipping
does not *remove* anything an earlier deploy installed. Note too that
`check-code-agents.sh` cannot tell "you deselected this" apart from "the
install failed" — if you did select the unit and the check is skipping, re-run
`deploy-vps.sh --only code-agents` and read its output.

## 3. Fill in the repo allowlist

Deploy copied the template to `/data/code-agents/repos.json` (no-clobber).
One entry per repo the agents may touch. The fields are documented in the
file's `_readme`; the rules that matter:

- **Only repos you own or trust** — cloned repo content (AGENTS.md, .claude/)
  steers the agent, and the allowlist is the trust boundary.
- **Only Tier 1/2 repos** ([`docs/privacy.md`](../privacy.md)) — never the
  life vault. The verify script fails if it sees it.
- `allow_push: true` only where you're happy for pushes to skip the
  permission ask. Default (`false`) = every push asks on your device.
- Keep `setup` commands light (2 vCPU / 4 GB) or set `edit_only: true`.

Restart nothing — the manager reads the file per request.

**Two ways to add one, and they write the same file.**

*Over SSH, with an editor* — the original path, and still the one to use when
you are changing an existing entry, removing one, or fixing a file the manager
has refused to write to:

```bash
ssh agent@<your-brain>.<your-tailnet>.ts.net
$EDITOR /data/code-agents/repos.json
```

*Over the API* — `POST /api/repos`, which the app's Repositories sheet calls
and which you can drive from the Mac. `tier` is **required** and `3` is
refused; `setup`, `edit_only`, `allow_push` and `public_throwaway` are
optional and default to the safe value:

```bash
curl -u "opencode:$OPENCODE_SERVER_PASSWORD" \
  -X POST "https://<your-brain>.<your-tailnet>.ts.net:4300/api/repos" \
  -d '{"name":"my-repo","url":"https://github.com/me/my-repo.git","tier":2}'
```

The route refuses before it writes anything: a missing or `3` tier, a flag
that is not a JSON boolean (`"allow_push": "false"` is a **refusal**, never
read as true), a duplicate `name`, and a repo the PAT cannot read — a GitHub
404 there means either the repo does not exist *or* your token is not scoped
to it, and from the brain those are indistinguishable. A 5xx from GitHub is
"could not check", and nothing is written on that either. On success the new
repo is live immediately; the reply is the same six-field row `GET /api/repos`
serves, and `tier` is recorded in the file but deliberately not on the wire.

**`url` must be `https://github.com/<owner>/<repo>`** (a trailing `.git` is
fine) and nothing else — not an scp-style `git@github.com:owner/repo`, not a
bare `owner/repo`, and above all not some other host. The check the route makes
is "can the PAT read `<owner>/<repo>`", so a URL pointing anywhere else would be
written on the strength of an answer GitHub gave about a *different* address;
and the containers clone with `GH_TOKEN` over HTTPS and hold no SSH key, so the
https form is also the only one a chat can actually clone. Editing the file by
hand over SSH is unchanged and still accepts the older shapes.

**An authorisation that can reach a repo is still not an allowlist entry.**
Your PAT may be scoped to twenty repos; `repos.json` is the smaller set you
chose, and it stays the Tier 1/2 gate. A GitHub connection must never imply an
entry — which is why this route takes a URL you type rather than offering a
picker of everything your account can see.

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
