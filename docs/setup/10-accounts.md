# Phase 1a — Accounts and credentials

Everything account-shaped, in one sitting (~30–45 min). Each section is
create → configure the gotchas → collect the credential. The
[checklist at the end](#credential-checklist) tracks every credential and where
it goes. Prices, tiers, and console defaults verified as of 2026-08-20 —
consoles move buttons around, but the gotchas themselves are policy, not UI.

Do the first two (Zen + Together) now — they're all Phase 1 needs. Tailscale
can wait until Phase 2, Hetzner until Phase 3, and Todoist is **optional**
(only if you adopt it as your todo app); they're included here so all account
work lives in one doc.

## 1. OpenCode Zen

Your main inference gateway: at-cost PAYG, one key, curated models
(<https://opencode.ai/docs/zen>).

1. Open the OpenCode console (linked from the docs page above), sign up, and
   add a payment method.
2. Buy initial credit. Top up in **larger increments** — card processing fees
   are passed through at 4.4% + $0.30 per transaction, so ten $5 top-ups cost
   noticeably more than one $50.
3. **IMMEDIATELY, before anything else** — two cost-control settings in
   billing:
   - **Disable auto-reload.** It is ON by default and reloads **+$20 every
     time the balance drops below $5** — which means a runaway agent loop or a
     leaked key spends real money in $20 slugs, and Zen's own docs note
     auto-reload can blow past your monthly limit. Turn it off; top up
     manually.
   - **Set a monthly workspace usage limit.** $20–30 matches the expected
     budget in [00-overview.md](00-overview.md). This is the backstop the
     auto-reload toggle isn't.
4. Copy the API key. This is `OPENCODE_ZEN_API_KEY` — one key for all Zen
   models and endpoints.
5. Sanity check (also proves the key before you store it):

   ```bash
   curl -sS https://opencode.ai/zen/v1/models \
     -H "Authorization: Bearer <YOUR-ZEN-API-KEY>" | head -c 400
   ```

Privacy notes that shape how this key gets used (details in
[`docs/privacy.md`](../privacy.md)): Zen's hosted open models are
zero-retention/no-training; the **free** models train on your data (never send
them anything personal); Claude/GPT via Zen carry 30-day retention (never
health/finance data).

## 2. Together AI

The sensitive tier: OpenAI-compatible, ZDR by default, SOC 2, HIPAA/BAA
posture (<https://docs.together.ai>).

1. Sign up at <https://api.together.ai>.
2. Buy credit — **expect no signup credit** (the old $25 free credit was
   retired; sources indicate a ~$5 minimum purchase). ~$5–10 is plenty to
   start.
3. **Organization Settings → Privacy:** confirm both toggles are **OFF** —
   storing prompts/responses, and sharing data for training. They default off
   and are admin-only, but this tier holds your health data: verify with your
   own eyes rather than trusting the default
   (<https://docs.together.ai/docs/privacy-and-security>).
4. Create an API key. This is `TOGETHER_API_KEY`.
5. Sanity check:

   ```bash
   curl -sS https://api.together.xyz/v1/models \
     -H "Authorization: Bearer <YOUR-TOGETHER-API-KEY>" | head -c 400
   ```

One behavior to know now: rate limits are dynamic and grow with successful
usage, so a brand-new account may see 429s on bursty jobs for the first weeks
(handled — see [`docs/troubleshooting.md`](../troubleshooting.md)).

## 3. Tailscale

The only network path to the brain. Free personal plan.

1. Create an account at <https://tailscale.com> (sign-in via an identity
   provider; pick the one you'll keep).
2. Install the client on the **Mac** and the **iPhone** and sign both into
   your tailnet.
3. In the admin console, under DNS: enable **MagicDNS** and **HTTPS
   certificates**. Both are required later — MagicDNS gives the brain a stable
   `<hostname>.<your-tailnet>.ts.net` name, and the cert support backs TLS to
   `goose serve`.
4. No credential to collect today. In Phase 3 you'll generate a **Tailscale
   auth key** for the VPS (admin console → Settings → Keys) — that goes only
   into `infra/terraform/terraform.tfvars`, and
   [50-vps-brain.md](50-vps-brain.md) tells you when.

## 4. Todoist (optional — skip unless you've adopted it)

No todo app is wired in by default: the `todoist` extension ships
`enabled: false` in `config/goose/config.yaml`, and no recipe depends on
tasks. If you later pick Todoist as your todo app:

1. Create an account at <https://todoist.com>. Free tier is fine.
2. That's it — **no API key**. Todoist's first-party MCP server at
   `https://ai.todoist.net/mcp` initiates OAuth in your browser the first time
   Goose connects to it (Phase 2), so there is nothing to copy or store.

## 5. Hetzner (VPS provider)

1. Create an account at <https://www.hetzner.com/cloud> (new accounts may hit
   an identity-verification step — do this ahead of Phase 3 so it isn't a
   blocker).
2. Create a project (e.g. `personal-ai`).
3. In the project: **Security → API tokens → Generate API token**, permissions
   **Read & Write**. This token can create and destroy servers — treat it like
   a root password.
4. It goes in exactly one place: `infra/terraform/terraform.tfvars`
   (gitignored). Never in the Keychain scripts, never in `secrets.env`, never
   in the repo.

## 6. ntfy (failure-alert transport)

ntfy carries exactly one thing in this setup: **failure alerts** from the
automation watchdog, forwarded to your email. Automation *results* don't go
through it at all — each recipe emails you directly via Gmail
([`docs/automations.md`](../automations.md)). No app to install, nothing to
subscribe to, and no account either — ntfy topics are open-by-name, which
means **the topic name is the entire secret**. Anyone who knows it can read
and send on it.

1. Generate a topic name nobody will guess:

   ```bash
   openssl rand -hex 12
   ```

2. Treat the result exactly like a password: store it as `NTFY_TOPIC` (Mac
   Keychain now, `/data/secrets.env` in Phase 3). Never commit it, never paste
   it into an issue or chat.
3. Decide where failure alerts land: your own email address, stored as
   `NTFY_EMAIL` alongside the topic (Keychain now, `/data/secrets.env` in
   Phase 3). Recommended, and not a secret — it's just your address; when set,
   `scripts/common/notify.sh` adds an `Email:` header so ntfy.sh forwards each
   alert to your inbox.
4. Test end-to-end:

   ```bash
   curl -H "Email: <your-email>" -d "ntfy wired up" https://ntfy.sh/<your-topic>
   ```

   The message should arrive in your inbox within a minute or two.

One number to know: ntfy.sh's free tier caps email forwarding at roughly
5/day — plenty for rare failure alerts, and exactly why the recipes email
their content directly instead of through this channel. Standing rule
regardless of topic secrecy: alerts carry the recipe name only, **never model
output or PHI** ([`docs/privacy.md`](../privacy.md)). Self-hosting ntfy is a
roadmap item ([`docs/roadmap.md`](../roadmap.md)).

## 7. Web search key (optional)

Optional — briefs and research recipes degrade gracefully without search, and
the roadmap replaces this with self-hosted SearXNG anyway.

- **Tavily** (recommended if you want a key): free tier of 1,000 credits/mo.
  Sign up at <https://tavily.com>, copy the key → `TAVILY_API_KEY`.
- **Exa** alternative: its official MCP has a free unauthenticated tier
  (~150 calls/day) — no key, no account, nothing to store.

## Generated secrets (not accounts)

For completeness — these appear in the checklist but are generated by you, not
issued by a service:

- `GOOSE_SERVER__SECRET_KEY` — shared secret authenticating clients to
  `goose serve`. Generate in Phase 3 with `openssl rand -hex 32`.
- **LUKS passphrase** — encrypts everything at rest on the brain. Generate in
  Phase 3; lives **only** in your password manager. If you lose it, a reboot
  turns the brain's data into noise — there is no recovery path.
- `GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET` — created in
  Phase 2 when you build your own GCP OAuth app
  ([30-google-oauth.md](30-google-oauth.md)).

## Credential checklist

Every credential this setup will ever hold, and where each one goes. "Keychain"
means stored via `scripts/mac/keychain-secrets.sh`; "secrets.env" means
`/data/secrets.env` on the brain (Phase 3), template at
`config/env/secrets.env.example`.

| Credential | Variable / form | Mac Keychain | Brain secrets.env | Elsewhere | Collected in |
|---|---|---|---|---|---|
| OpenCode Zen API key | `OPENCODE_ZEN_API_KEY` | yes | yes | — | §1 (now) |
| Together AI API key | `TOGETHER_API_KEY` | yes | yes | Pal Chat on iPhone (Phase 1) | §2 (now) |
| ntfy topic | `NTFY_TOPIC` | yes | yes | — | §6 (now) |
| Failure-alert email (recommended; not a secret) | `NTFY_EMAIL` | yes | yes | — | §6 (now) |
| Tavily key (optional) | `TAVILY_API_KEY` | yes | yes | — | §7 |
| Hetzner API token | `hcloud_token` in `terraform.tfvars` | no | no | `terraform.tfvars` only | §5 (Phase 3) |
| Tailscale auth key | `tailscale_authkey` in `terraform.tfvars` | no | no | `terraform.tfvars` only | Phase 3 |
| goose serve shared secret | `GOOSE_SERVER__SECRET_KEY` | yes (Desktop connects with it) | yes | Goose iOS app (pairing) | Phase 3 |
| Google OAuth client | `GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET` | yes | yes | — | Phase 2 ([30-google-oauth.md](30-google-oauth.md)) |
| LUKS passphrase | (passphrase) | no | no | password manager **only** | Phase 3 |
| Todoist (optional) | none — browser OAuth on first MCP connect | — | — | — | §4 |

Cross-check before moving on: everything in the "now" rows exists, the two Zen
cost-control settings are flipped, the Together privacy toggles are verified
off, and the ntfy test email reached your inbox. Then continue to
[20-mac-setup.md](20-mac-setup.md).
