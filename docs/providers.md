# Email/calendar providers: the extension convention

The brain manages your whole communication surface, not one mailbox. Today that
means N Google accounts through one `workspace-mcp` instance
([30-google-oauth.md §8](setup/30-google-oauth.md)); this document is the
contract any **additional provider** (Outlook / Microsoft 365, Fastmail or any
IMAP/SMTP + CalDAV host, Proton via Bridge) must satisfy to join, and the
conventions its wiring must follow so the stack stays one coherent thing
instead of a pile of one-off integrations. No non-Google provider ships wired
in yet — this is the doorway, deliberately built before the guests arrive.

## The shape: one MCP server per provider family

Google set the pattern: a **self-hosted MCP server**, authenticated by
credentials **you** own, running as a goose stdio extension, with all state on
the encrypted volume. Each provider family gets the same treatment:

| Provider family | Covers | Server family to vet | Auth model |
|---|---|---|---|
| Google | Gmail, Calendar, Tasks | `workspace-mcp` (wired in) | Your own GCP OAuth app |
| Microsoft Graph | Outlook.com, Microsoft 365 mail + calendar | an MS Graph MCP server | Your own Entra ID app registration |
| Generic IMAP/SMTP + CalDAV | Fastmail, mailbox.org, most hosts | an IMAP/SMTP MCP server + a CalDAV MCP server | App passwords / tokens from the host |
| Proton | Proton Mail/Calendar | generic IMAP/SMTP server via **Proton Bridge** running on the brain | Bridge-local credentials |

No specific third-party server is endorsed here on purpose: the MCP ecosystem
churns, and each candidate must pass the vetting bar below **at adoption
time** — the same bar workspace-mcp passed.

## The vetting bar (what workspace-mcp had to clear)

Before any server is wired into `config/goose/config.yaml`:

1. **Maintenance state.** Active repo, responsive maintainer, released within
   the last few months, no pile of open auth-breakage issues.
2. **Self-hosted auth, no third party.** The server runs locally (stdio) or on
   the brain; credentials are yours (own OAuth app, app password, Bridge).
   Nothing that proxies your mailbox through someone else's service — the only
   parties are you and the provider.
3. **Credential storage you can point at the encrypted volume.** Token/state
   files must live in a directory you can relocate (or symlink) onto `/data`,
   like `/data/workspace-mcp` today.
4. **Tool surface fits recipes.** Read mail/calendar, create drafts, send —
   with a way to restrict scope (workspace-mcp's `--tools` equivalent) so the
   consent and the per-request context stay small.
5. **A privacy row first.** [privacy.md](privacy.md) gets a provider policy
   row (retention, training, where the data lands) **before** the first
   recipe touches it. Until classified, a provider's content routes nowhere.

## Naming and config conventions

- **Extension instances:** `mail-<provider>` — e.g. `mail-msgraph`,
  `mail-fastmail`, `mail-proton`; a matching `cal-<provider>` where calendar
  is a separate server. `workspace-mcp` keeps its name (grandfathered; it's
  also more than mail).
- **Secrets:** `<PROVIDER>_*` prefixes in `secrets.env` /
  Keychain — e.g. `MSGRAPH_CLIENT_ID`, `FASTMAIL_APP_PASSWORD`. Multiple
  accounts on one provider follow the Google pattern: the server's native
  multi-account mechanism if it has one, else one extension instance per
  account (`mail-fastmail-side`), each with its own env vars.
- **Account roster:** each provider gets its own roster var mirroring
  `USER_GOOGLE_EMAILS` (e.g. `USER_MSGRAPH_EMAILS`), first entry = that
  provider's default account. The **delivery primary stays the Google
  primary** (`USER_GOOGLE_EMAIL`): one self-addressed email from one account,
  no matter how many providers feed the digest.
- **Recipes:** the sweep recipes gain one parameter per provider roster
  (like `google_accounts`), and every non-Google item in a digest is tagged
  by account exactly like a secondary Google account's. Hard rules extend
  mechanically: drafts stay inside their provider+account; nothing is ever
  sent from anywhere but the Google primary.
- **Verification:** `check-mcp.sh` grows one smoke test per configured
  provider account, same as its per-account Gmail sweep.
- **Runbook:** each provider gets `docs/setup/3x-<provider>.md` covering app
  registration/app-password creation, the consent-or-credential dance, token
  storage on `/data`, and its check-mcp verification — the shape of
  [30-google-oauth.md](setup/30-google-oauth.md).

## Acceptance (mirrors issue #10)

- [ ] N accounts across ≥2 providers appear in one morning brief, items
      labeled by account
- [ ] inbox-triage sweeps all accounts; drafts stay within each account;
      summary email still single + self-addressed from the primary
- [ ] per-account consent/tokens documented and stored on the encrypted volume
- [ ] `check-mcp.sh` verifies each configured account
- [ ] docs: setup runbook per provider; privacy.md row per provider

Trigger for building the first non-Google provider: the day a real second
provider joins your life (a work M365 tenant, a Fastmail migration) — not
before. The multi-Google half already exercises every seam the providers will
use: per-call account addressing, roster env vars, rendered scheduled
recipes, per-account verification.
