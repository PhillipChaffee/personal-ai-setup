# Phase 2 — Your own Google OAuth app (Gmail, Calendar, Tasks)

Goose reads your Gmail, Calendar, and Tasks through
[`taylorwilsdon/google_workspace_mcp`](https://github.com/taylorwilsdon/google_workspace_mcp)
("workspace-mcp"), a self-hosted MCP server — authenticated by an OAuth app
**you** create in your own Google Cloud project. No aggregator, no third party
holding a grant to your mailbox; the only parties are you and Google.

That self-ownership costs one somewhat fiddly console walk (~20 min). It
contains exactly one trap that will silently ruin the setup if missed —
it's called out in the box below. Console labels verified as of 2026-08-20;
Google moves buttons, but the policy behind the trap is stable.

## 1. Create the GCP project

1. Go to <https://console.cloud.google.com> and sign in with the Google
   account whose mail/calendar you want the agent to manage.
2. Create a new project (top bar → project picker → **New project**). Name it
   something like `personal-ai`. No billing account is required — the APIs
   below are free at personal volume.

## 2. Enable the three APIs

**APIs & Services → Library**, search and **Enable** each of:

- **Gmail API**
- **Google Calendar API**
- **Google Tasks API**

(Enable more later — Drive, Docs, Contacts — only if you actually wire those
tools in; every enabled service means more scopes on the consent screen and
more MCP tools eating context.)

## 3. Consent screen — and the one trap

**APIs & Services → OAuth consent screen** (newer consoles brand this
"Google Auth Platform"):

1. User type: **External**. ("Internal" is Workspace-org-only; a personal
   Gmail account must use External.)
2. Fill the required fields: app name (e.g. `personal-ai`), your email as
   user support email and developer contact. **No logo** — uploading one
   forces verification review.
3. **Homepage URL and privacy policy URL** (required to publish as of
   Google's 2026 console): point them at this project's GitHub Pages site —
   your fork's equivalent of
   `https://<you>.github.io/personal-ai-setup/` and
   `https://<you>.github.io/personal-ai-setup/privacy/`
   (`docs/index.md` and `docs/app-privacy-policy.md` in this repo; enable
   Pages: repo Settings → Pages → Deploy from branch → `main`, `/docs`).
   Under **Authorized domains**, add `<you>.github.io` — `github.io`
   subdomains count as domains you own.
4. You do **not** need to pre-register scopes — workspace-mcp requests what
   its enabled tools need at auth time.

> **⚠️ Publish to "In production" NOW — do not leave the app in "Testing".**
>
> An External OAuth app in **Testing** status has every refresh token
> auto-expired after **7 days** ([Google's policy](https://support.google.com/cloud/answer/15549945)).
> The symptom is nasty: everything works at setup, then exactly one week
> later every Gmail/Calendar tool call fails and the brain's inbox-triage
> automation dies quietly — and re-authing only buys another week, forever.
>
> On the consent screen page, under **Publishing status**, click
> **Publish app** → confirm. That's it — production status makes refresh
> tokens long-lived.
>
> Two expected side effects, both fine for personal use:
> - Google may show a list of "requirements for verification" — **ignore it**.
>   Verification is only mandatory for apps at scale; an unverified app in
>   production works indefinitely for its own developer.
> - During the OAuth dance you'll see a scary **"Google hasn't verified this
>   app"** interstitial. That's the expected cost of owning the app: click
>   **Advanced → Go to personal-ai (unsafe)**. "Unsafe" here means
>   "unverified by Google's review program" — the app is yours; you are
>   trusting yourself.

## 4. Create the OAuth client and collect credentials

**APIs & Services → Credentials → Create credentials → OAuth client ID**:

1. Application type: **Desktop app**. This matters: Desktop-type clients are
   allowed loopback (`http://localhost:<port>`) redirects without
   pre-registering redirect URIs — which is what makes both the Mac auth flow
   and the ssh-forwarded flow on the brain (§7b) work unchanged.
2. Name it (e.g. `workspace-mcp`), create, and you get a **Client ID** and
   **Client secret**. Optionally download the JSON as a backup copy.
3. Store them under the canonical names:

   ```bash
   ./scripts/mac/keychain-secrets.sh   # add GOOGLE_OAUTH_CLIENT_ID + GOOGLE_OAUTH_CLIENT_SECRET
   ```

   In Phase 3 the same two values also go into `/data/secrets.env` on the
   brain.

**Where these live, and git:** the client ID/secret live only in the Keychain
(Mac) and `/data/secrets.env` (brain). If you downloaded the client JSON,
keep it out of any repo — `.gitignore` blocks `gcp-oauth*.json`,
`credentials*.json`, and `*token*.json` as a guardrail, but the real rule is
that none of these files ever belongs inside a working tree.

## 5. Wire workspace-mcp into goose (Mac)

workspace-mcp runs as a **stdio** extension via `uvx` (installed by the
Phase 1 bootstrap) — goose starts and stops it per session; nothing listens
permanently.

The wiring lives in two template files the bootstrap already put in place:

- `config/goose/config.yaml` — the `workspace-mcp` stdio extension entry:
  `uvx workspace-mcp --tool-tier core`. The **`core` tool tier** keeps the
  tool count down (the full tier is 120+ tools and would flood every
  prompt's context); note it trims the tool *count*, not the services — the
  extension is not restricted to Gmail/Calendar/Tasks.
- `config/mcp/workspace-mcp.env.example` — the env vars the server reads:
  `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET` (from §4, via the
  Keychain exports). Nothing pins a credentials directory — token files go
  to workspace-mcp's default state dir (next section).

Nothing to invent here — follow the comments in those two files.

## 6. The first-run OAuth dance (Mac)

1. Start a goose session and ask something that forces a Gmail tool call:
   *"list the subjects of my 3 most recent emails"*.
2. A browser window opens: pick your account → the **unverified-app
   interstitial** (§3 — Advanced → continue) → review scopes → **Allow**.
3. The tool call completes. Done — this was the one-time user consent;
   workspace-mcp now holds a long-lived refresh token (because the app is in
   production) and refreshes access tokens silently from here on.

**Where the tokens live:** workspace-mcp writes its token files to its
default state dir — `~/.google_workspace_mcp/` (documented upstream as of
2026-08-20). **Verify after this first auth**: `ls -la ~/.google_workspace_mcp/`
should show the token files; if your version put them elsewhere, use that
path wherever this guide says `~/.google_workspace_mcp/`. These files **are**
access to your mailbox: they stay out of every repo (gitignored by pattern,
and outside the working tree anyway), and on the brain they'll sit on the
encrypted volume (§7).

Verify the full MCP surface while you're here:

```bash
./scripts/verify/check-mcp.sh   # Gmail subjects, Todoist, Playwright fetch
```

## 7. Getting the tokens onto the brain (Phase 3)

The brain runs the same workspace-mcp and needs the same credentials. Two
documented paths — (a) is easier if the Mac flow already works; (b)
re-runs the consent dance directly on the VPS. Do this at the
[50-vps-brain.md](50-vps-brain.md) step that points here.

### 7a. rsync the credential files from the Mac

Copy your working token directory to the encrypted volume over Tailscale SSH:

```bash
rsync -av ~/.google_workspace_mcp/ \
  agent@<your-brain>.<your-tailnet>.ts.net:/data/workspace-mcp/

ssh agent@<your-brain>.<your-tailnet>.ts.net \
  'chmod 700 /data/workspace-mcp && chmod -R go-rwx /data/workspace-mcp'
```

Plus the client ID/secret into `/data/secrets.env` (you'll have done this in
the secrets step of [50-vps-brain.md](50-vps-brain.md)). On the brain,
`deploy-vps.sh` symlinks `~/.google_workspace_mcp` → `/data/workspace-mcp`,
so workspace-mcp's default state dir — and every token in it — lives on the
LUKS volume, encrypted at rest. That symlink is what keeps the at-rest
guarantee honest: without it the tool would write tokens to the unencrypted
root disk.

The same refresh token working from two machines is fine — Google doesn't
bind it to a host. If you ever revoke access (Google Account → Security →
Third-party access), both copies die together; re-run the dance and re-sync.

### 7b. One-time OAuth dance on the VPS via `ssh -L`

If you'd rather each machine hold its own consent (or the Mac flow was
skipped): the VPS has no browser, so forward the loopback callback port to
your Mac and run the dance "as if" locally. workspace-mcp's callback
defaults to port 8000 (the auth flow prints the exact URL it's listening on;
adjust the forward if yours differs):

```bash
# On the Mac — open the tunnel and keep it open:
ssh -L 8000:localhost:8000 agent@<your-brain>.<your-tailnet>.ts.net
```

Then, **inside that SSH session** on the brain, make sure workspace-mcp's
default state dir points at the encrypted volume before any token is written
(`deploy-vps.sh` also sets this up, but this path may run before it):

```bash
mkdir -p /data/workspace-mcp && ln -sfn /data/workspace-mcp "$HOME/.google_workspace_mcp"
```

Now trigger the auth flow (a one-off headless goose run that calls a Gmail
tool does it):

```bash
cd /home/agent/personal-ai-setup
GOOSE_MODE=auto goose run --provider zen-openai --model minimax-m2.7 \
  -t "List the subjects of my 3 most recent emails" --no-session --quiet
```

The flow prints an `accounts.google.com` URL — open it in the **Mac's**
browser. Consent as in §6; Google redirects to `http://localhost:8000/...`,
which the tunnel delivers to workspace-mcp on the brain, which writes its
tokens under `~/.google_workspace_mcp/` — the symlink above, so they land in
`/data/workspace-mcp/` on the encrypted volume. Close the tunnel; done.

This works precisely because the OAuth client is **Desktop-type** (loopback
redirects allowed on any port, no URI registration) — don't "fix" it to a
Web-type client.

## Recap: every Google artifact and where it lives

| Artifact | Location | In git? |
|---|---|---|
| GCP project + OAuth app | Google's console, status **In production** | — |
| `GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET` | Mac Keychain; `/data/secrets.env` on the brain | **Never** (names only, in `config/env/secrets.env.example`) |
| Downloaded client JSON (optional) | Wherever you keep backups — not in a repo | **Never** (gitignored by pattern) |
| Token files | `~/.google_workspace_mcp/` (Mac — the tool's default state dir); `/data/workspace-mcp/` (brain, LUKS volume, via the `~/.google_workspace_mcp` symlink) | **Never** |

If Gmail tools start failing weeks from now, check the publishing status
first — the 7-day trap is the classic cause; see
[`docs/troubleshooting.md`](../troubleshooting.md#workspace-mcp-re-auth-every-7-days).

Next: finish Phase 2 verification (`scripts/verify/check-mcp.sh` green), then
on to the brain — [50-vps-brain.md](50-vps-brain.md).
