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
4. You do **not** need to pre-register scopes — workspace-mcp requests
   exactly what its `--permissions` levels declare, at auth time (§5).

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

  ```
  uvx workspace-mcp@1.25.0 --permissions gmail:send calendar:full tasks:manage --tool-tier core
  ```

  Three things in that line earn their place:

  | Piece | Why |
  |---|---|
  | `@1.25.0` | `uvx workspace-mcp` resolves to whatever is newest *at spawn time*. Pinning is what makes the tool list and the consent screen below reproducible instead of "whatever shipped this week". |
  | `--permissions <service>:<level>` | Selects the services **and** the OAuth scopes. Levels are cumulative per service — gmail: `readonly < organize < drafts < send < full`; calendar: `readonly < full`; tasks: `readonly < manage < full`. |
  | `--tool-tier core` | Caps per-request context. Measured at these permissions on 2026-08-23: `core` = **10** tools, `extended` = 20, `complete` = 26 — and **omitting the flag is the same as `complete`**, not a middle ground. 120+ across all services. |

  `--permissions` **replaces** the older `--tool-tier core --tools gmail
  calendar tasks`, which was inverted least privilege: `--tools` picks
  *services*, so consent asked for all 14 scopes those three services can use
  while the recipes need far fewer. The two flags are mutually exclusive
  upstream — passing both is a startup error, so don't reintroduce `--tools`.

  **This entry is deliberately write-capable**, and that is the one judgement
  call in the line. `calendar:full` + `tasks:manage` mean the interactive
  session — the phone chat, Goose Desktop — can actually move a meeting and
  tick a task, which is most of the point of having it. The `available_tools`
  allowlist grants exactly the matching write tools (`manage_event`,
  `manage_task`), so credential and allowlist agree: a tight allowlist over a
  broad token would surrender the capability while keeping the risk.

  Each recipe narrows further than this entry does, because a scheduled job
  should not inherit the interactive session's reach. `morning-brief`,
  `weekly-review` and `health-followups` each declare their **own**
  workspace-mcp block with `calendar:readonly`; `inbox-triage` /
  `budget-checkin` ask for no calendar at all. Verified over stdio on
  2026-08-23: `calendar:readonly` is a real level (hand the server a bogus one
  and it prints its own table — gmail `readonly|organize|drafts|send|full`,
  calendar `readonly|full`, tasks `readonly|manage|full` — then exits 1), and
  `--permissions gmail:send calendar:readonly --tool-tier core` registers 6
  tools with `get_events` and `list_calendars` present and `manage_event`
  **gone**. So "the calendar is read-only in this run" is a property of the
  wiring, not a promise in a prompt.

  The entry also carries a snake_case `available_tools` allowlist naming those
  10 tools. **The spelling is load bearing** — goose silently discards a
  camelCase `availableTools`, and an absent or empty allowlist means *every*
  tool is allowed, so the typo fails open. The mechanics and the proof are in
  [`config/connectors/README.md`](../../config/connectors/README.md).

  One consequence of writing out all 10: the allowlist equals the server's
  entire published surface at these args, so a tool *count* can no longer tell
  "the allowlist bit" apart from "the allowlist was dropped" — both come back
  as 10. What catches the camelCase typo here is the connector validator
  (client-side schema check) and the `extensions/add` → `extensions/list`
  roundtrip, not the count.

  One caveat, verified at 1.25.0: at `core` tier, `list_tasks` / `get_task` /
  `manage_task` all require a `task_list_id`, and the only tools that hand one
  out (`list_task_lists`, `get_task_list`) are `complete` tier — so Tasks is
  reachable only via the API's `@default` list alias. No recipe uses Tasks
  today. If one starts to, drop `--tool-tier core` rather than widening
  `--permissions`.
- `config/mcp/workspace-mcp.env.example` — the env vars the server reads:
  `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET` (from §4, via the
  Keychain exports). Nothing pins a credentials directory — token files go
  to workspace-mcp's default state dir (next section).

Nothing to invent here — follow the comments in those two files.

## 6. The first-run OAuth dance (Mac)

**The race to know about first**: workspace-mcp runs
the `localhost:8000` OAuth callback listener, and workspace-mcp lives only as
long as the goose session that spawned it. A one-shot `goose run` prints
"authentication is required" and **exits — killing the listener — before you
can click Allow**; your consent then lands on a dead port ("Unable to
connect" at localhost:8000). The consent must complete **while a session is
alive**. Two ways:

- **Interactive** (Desktop or `goose session`): ask *"list the subjects of my
  3 most recent emails"*, and complete the browser consent while the session
  sits there. The session's next tool call succeeds.
- **Headless one-liner** — a run that holds the session open by retrying
  until consent lands:

  ```bash
  GOOSE_MODE=auto GOOSE_MAX_TURNS=40 goose run --no-session --quiet \
    --provider zen-openai --model minimax-m2.7 \
    -t "Call the Gmail search tool for my 3 most recent inbox subjects. The
  first call will say authentication is required and open a browser — I am
  consenting in parallel. Do not stop: re-call the tool, running 'sleep 20'
  between attempts, at least 15 times, until it returns real messages. Then
  output only the 3 subject lines."
  ```

In the browser: pick your account → the **unverified-app interstitial** (§3 —
Advanced → continue) → review scopes (13 of them: Gmail, Calendar, Tasks and
sign-in — nothing else, thanks to `--permissions`) → **Allow** → a localhost
"you can close this window" page means
the token was written. Expect Google's "Security alert" email about the new
grant — that's normal. This was the one-time consent; workspace-mcp now holds
a long-lived refresh token (because the app is in production) and refreshes
access tokens silently from here on.

**Do this consent from a goose session, not from a recipe run.** The stored
token holds whatever scopes the *granting* process asked for, and the
`config/goose/config.yaml` entry asks for the superset. A broader stored token
satisfies every recipe's narrower request; consenting from, say, `inbox-triage`
first would store a Gmail-only token and force a second consent round the next
time anything reads the calendar.

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

## 8. More Google accounts (optional)

One brain can manage several Google accounts — personal + side-project +
legacy. The mechanics (verified against workspace-mcp upstream as of
2026-08-21): stored consents are keyed **per account email** (one token file
per account, side by side in the same state dir), every tool takes a
`user_google_email` argument per call, and `USER_GOOGLE_EMAIL` is only the
**default** for calls that don't name an account — never a restriction. So
adding an account is one consent dance and one env var edit; nothing new in
the Google console.

1. **Keep one OAuth app.** The same client ID/secret from §4 serves every
   account — do not create a second GCP project or client.
2. **Run the consent dance once per account**, exactly as in §6 (or §7b on
   the brain), but sign in as the *additional* account in the browser. To
   trigger the flow for a specific account, make the prompt name it, e.g.
   in the §6 headless one-liner ask for
   *"...the 3 most recent inbox subjects of the account
   side-project@example.com — pass user_google_email=side-project@example.com
   on every call"*. The new account's token file lands next to the first
   one; nothing is overwritten.
3. **Get the new token onto the brain.** A consent completed on the Mac
   (§6) writes the token file only there — the brain's automations can't
   use it until you repeat the §7a rsync so it reaches
   `/data/workspace-mcp/`. The rsync never deletes anything; re-copying the
   primary account's token alongside is harmless (same refresh token, same
   client). Re-apply the §7a `chmod` afterwards. Alternatively run the
   consent directly on the brain via the §7b tunnel — then it's the Mac
   that's missing the token, which only matters if you use goose locally
   with that account.
4. **Declare the roster.** Set in `/data/secrets.env` (brain) — and export in
   your shell on the Mac if you want `check-mcp.sh` to sweep there too:

   ```bash
   # comma-separated, FIRST entry = the primary (same as USER_GOOGLE_EMAIL)
   USER_GOOGLE_EMAILS=you@example.com,side-project@example.com
   ```

   `USER_GOOGLE_EMAIL` stays set to the primary — it remains workspace-mcp's
   default account and the only account recipes ever send the self-addressed
   delivery email from.
5. **Tell the interactive assistant too.** The scheduled sweeps get the
   roster from step 4, but Desktop/Telegram sessions only know what the
   hints file says: add the new account to the "Google accounts:" line of
   `~/.config/goose/.goosehints` — on the Mac **and** on the brain (same
   path on both; `config/goose/goosehints.example` has the wording).
6. **Propagate to the automations** (brain): re-run
   `scripts/vps/register-schedules.sh`. The sweep recipes (morning-brief,
   inbox-triage, weekly-review) declare a `google_accounts` parameter, and
   the script stores the roster on each schedule (`goose schedule add
   --params`), so the scheduler applies it at fire time. `run-recipe.sh`
   (manual and fallback-timer runs) passes the same roster from the
   environment. Digest lines are tagged by account; drafts
   and labels stay inside the account that owns the message. The vault
   recipes (`health-followups`, `budget-checkin`) deliberately stay on the
   primary account only. Re-run the script whenever the roster changes — the
   stored schedule parameters only update when the schedules are re-registered.
7. **Verify:** `scripts/verify/check-mcp.sh` now runs the Gmail smoke test
   once per listed account (on the brain it reads the roster from
   `/data/secrets.env` by itself). A failure naming one account means that
   account's consent dance (step 2) never completed — or, on the brain,
   that step 3 was skipped and the token never left the Mac.

Two things to know before you turn this on: every listed account's mail and
calendar become Tier 2 data flowing through the same automations (see the
multi-account note in [`privacy.md`](../privacy.md)), and the digests
aggregate all accounts' items into one email delivered to the **primary**
inbox — if an account's content shouldn't land there, leave it off the
roster.

## Recap: every Google artifact and where it lives

| Artifact | Location | In git? |
|---|---|---|
| GCP project + OAuth app | Google's console, status **In production** | — |
| `GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET` | Mac Keychain; `/data/secrets.env` on the brain | **Never** (names only, in `config/env/secrets.env.example`) |
| `USER_GOOGLE_EMAIL` (primary) / `USER_GOOGLE_EMAILS` (roster, §8) | `/data/secrets.env` on the brain; on the Mac: `config.yaml` `envs:` (primary only) and shell env (roster) | **Never filled in** (names only; not secrets, but personal) |
| Downloaded client JSON (optional) | Wherever you keep backups — not in a repo | **Never** (gitignored by pattern) |
| Token files | `~/.google_workspace_mcp/` (Mac — the tool's default state dir); `/data/workspace-mcp/` (brain, LUKS volume, via the `~/.google_workspace_mcp` symlink) | **Never** |

If Gmail tools start failing weeks from now, check the publishing status
first — the 7-day trap is the classic cause; see
[`docs/troubleshooting.md`](../troubleshooting.md#workspace-mcp-re-auth-every-7-days).

Next: finish Phase 2 verification (`scripts/verify/check-mcp.sh` green), then
on to the brain — [50-vps-brain.md](50-vps-brain.md).
