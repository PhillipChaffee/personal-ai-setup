# Email/calendar providers: the extension convention

The brain can manage more than one communication surface. Today nothing ships
wired in: the `config/connectors/` registry holds the vetting records for the
services that were investigated (some adopted — Todoist — and some deliberately
not — IMAP+CalDAV, Proton), and this document is the
contract any **additional provider** (Outlook / Microsoft 365, Fastmail or any
IMAP/SMTP + CalDAV host, Proton via Bridge) must satisfy to join, and the
conventions its wiring must follow so the stack stays one coherent thing
instead of a pile of one-off integrations. This is the doorway, deliberately
built before the guests arrive.

## The shape: one MCP server per provider family

The pattern this repo settled on: a **self-hosted MCP server**, authenticated by
credentials **you** own, running as a goose stdio extension, with all state on
the encrypted volume. Each provider family gets the same treatment:

| Provider family | Covers | Server family to vet | Auth model |
|---|---|---|---|
| Microsoft Graph | Outlook.com, Microsoft 365 mail + calendar | an MS Graph MCP server | Your own Entra ID app registration |
| Generic IMAP/SMTP + CalDAV | Fastmail, mailbox.org, most hosts | an IMAP/SMTP MCP server + a CalDAV MCP server | App passwords / tokens from the host |
| Proton | Proton Mail/Calendar | generic IMAP/SMTP server via **Proton Bridge** running on the brain | Bridge-local credentials |

No specific third-party server is endorsed here on purpose: the MCP ecosystem
churns, and each candidate must pass the vetting bar below **at adoption
time**.

## The vetting bar

Before any server is wired into `config/goose/config.yaml`:

1. **Maintenance state.** Active repo, responsive maintainer, released within
   the last few months, no pile of open auth-breakage issues.
2. **Self-hosted auth, no third party.** The server runs locally (stdio) or on
   the brain; credentials are yours (own OAuth app, app password, Bridge).
   Nothing that proxies your mailbox through someone else's service — the only
   parties are you and the provider.
3. **Credential storage you can point at the encrypted volume.** Token/state
   files must live in a directory you can relocate (or symlink) onto `/data`.
4. **Tool surface fits its job.** Read what it needs, write only what it must —
   with a way to restrict scope (a `--permissions`-style flag) so the consent
   and the per-request context stay small.
5. **A privacy row first.** [privacy.md](privacy.md) gets a provider policy
   row (retention, training, where the data lands) **before** the first
   session touches it. Until classified, a provider's content routes nowhere.

## Naming and config conventions

- **Extension instances:** `mail-<provider>` — e.g. `mail-msgraph`,
  `mail-fastmail`, `mail-proton`; a matching `cal-<provider>` where calendar
  is a separate server.
- **Secrets:** `<PROVIDER>_*` prefixes in `secrets.env` /
  Keychain — e.g. `MSGRAPH_CLIENT_ID`, `FASTMAIL_APP_PASSWORD`. Multiple
  accounts on one provider use the server's native multi-account mechanism if
  it has one, else one extension instance per account
  (`mail-fastmail-side`), each with its own env vars.
- **Account roster:** a provider with several accounts gets its own roster var
  (e.g. `USER_MSGRAPH_EMAILS`), first entry = that provider's default account.
- **Verification:** `check-mcp.sh` grows one smoke test per configured
  provider account; `check-connectors.sh --smoke <id>` derives the tool
  surface from a real `tools/list`.
- **Runbook:** each provider gets `docs/setup/3x-<provider>.md` covering app
  registration/app-password creation, the consent-or-credential dance, token
  storage on `/data`, and its check-mcp verification.

## Acceptance

- [ ] the provider's MCP server passes the vetting bar above, at adoption time
- [ ] `config/connectors/<provider>.yaml` written against the registry
      contract ([`config/connectors/README.md`](../config/connectors/README.md))
- [ ] per-account consent/tokens documented and stored on the encrypted volume
- [ ] `check-mcp.sh` verifies each configured account
- [ ] docs: setup runbook per provider; privacy.md row per provider

Trigger for building the first provider: the day a real second provider joins
your life (a work M365 tenant, a Fastmail migration) — not before. The
vetting records in `config/connectors/` are the head start: the two
investigated-and-not-adopted entries record what killed each candidate last
time.
