# Privacy: data classification and what each provider is allowed to see

Your stance, decided up front: cloud inference is acceptable **with strict no-training /
zero-retention policies**, and sensitive material may live on the VPS brain **given
full-disk encryption at rest and encrypted communications everywhere**. This document
turns that stance into rules you (and every recipe) can follow mechanically.

The operational counterpart is [model-routing.md](model-routing.md) — the routing table is
this policy compiled into model choices.

## The three data tiers

Classify by the most sensitive content present. A session or document containing one
medical sentence is Tier 3, whole.

| Tier | What it is | Examples | Allowed routes |
|---|---|---|---|
| 1 — Public / general | Nothing about you beyond what you'd post publicly | Code without personal context, public research, drafting a blog post, general Q&A | Any **paid** model (Zen or Together). Zen free models are additionally allowed only for throwaway, non-personal code |
| 2 — Personal, not sensitive | Your life's logistics | Email triage, calendar, todos, travel plans, non-sensitive journal notes, contacts | Zen **paid** models or Together. Never Zen free models |
| 3 — Sensitive (health / finance) | Anything from the life vault or that belongs there | Medical records Q&A, appointment and follow-up notes, insurance/billing, budget, ledger, account details | **Together (ZDR default, HIPAA/BAA posture) or Zen paid open models only.** Never Claude/GPT via Zen (30-day retention), never free models |

Two rules of thumb that catch most edge cases:

- Inbox triage is Tier 2 but can surface Tier 3 content (a bill, a lab result). That's why
  `inbox-triage` runs on `minimax-m2.7` — a Zen **paid open** model (zero retention, no
  training), which is acceptable even when Tier 3 content drifts through. It must never be
  moved to `claude-sonnet-5` or a free model.
- If you're unsure which tier something is, it's the higher one.
- **Code-agent chats** (`docs/code-agents.md`) are classified **at the allowlist gate**,
  not per message: `/data/code-agents/repos.json` may only contain repos you classify
  Tier 1 or 2 — the life vault and anything Tier 3 never enter it. Zen-free models are
  refused unless a repo is explicitly flagged `public_throwaway` (hard rule 1). If a chat
  trips over sensitive content anyway, abort it — never continue the session. Chat
  transcripts live in per-chat volumes on the encrypted `/data`, and the phone app caches
  transcripts on-device — consistent with the trusted-client-device stance in
  [security.md](security.md).

## Provider policy summary (verified as of 2026-08-20)

| Route | Retention | Training on your data | Compliance | Verdict |
|---|---|---|---|---|
| Zen — paid open models (Kimi, GLM, MiniMax, DeepSeek, Qwen) | Zero retention, US-hosted | No | — | Tiers 1–3 |
| Zen — free models (big-pickle, Nemotron frees, Muse Spark Contributor, …) | Feedback programs | **Yes** — explicitly may train (Muse Spark Contributor trains Meta models; NVIDIA says "do not submit personal or confidential data") | — | Tier 1 throwaway code only |
| Zen — Claude / GPT (Anthropic/OpenAI-billed) | **30 days** per upstream policy | No | — | Tiers 1–2 only |
| Together AI | ZDR by default — inputs/outputs not stored (temporary performance caching may apply; check org Privacy settings) | No, without explicit org-admin opt-in (off by default) | SOC 2 Type 2; HIPAA posture, BAAs available | Tiers 1–3, the home of Tier 3 |

Sources: [Zen docs — privacy section](https://opencode.ai/docs/zen) (zero-retention
statement, free-model and 30-day exceptions);
[Together privacy & security](https://docs.together.ai/docs/privacy-and-security) (ZDR,
opt-in training, HIPAA/BAA);
[Together SOC 2 announcement](https://www.together.ai/blog/soc-2-compliance).

During Together signup, confirm in Organization Settings → Privacy that the
store-prompts and share-for-training toggles are **off** (they default off; see
`docs/setup/10-accounts.md`).

## Connector data sources (the other axis)

The table above is about **inference routes**: where data *goes* once a session sends it,
and what the provider on the far end may keep. This table is about **data sources**: where
data *comes from* — what a connected service can pull into a session in the first place.
They are genuinely different questions, and a connector answers only the second one. Adding
Todoist introduces no new inference route; it introduces a new pile of your text that the
existing routes can now be handed.

Every connector needs a row here **before its first call** — that is what
`privacy.row_added: true` in a [connector manifest](../config/connectors/README.md) asserts,
and `scripts/verify/check-connectors.sh` fails any manifest whose row is missing (a Tier 3
manifest fails twice over). The row is what makes the tier a decision recorded in advance
rather than a label applied to data already in a request log.

Each row carries an HTML comment holding the connector's `id:`. That marker — spelled
`<!-- connector: ID -->` — is the exact string the validator greps for, so a row keeps
counting through a retitled display name, a reworded description, or a reformatted table.
Add the marker in the same edit as the row; a row without one does not exist as far as the
gate is concerned.

| Connector | What it can surface | Tier | Route and delivery rule |
|---|---|---|---|
| **Google Workspace** <!-- connector: google-workspace --> | Gmail message bodies and attachments' metadata, Calendar events and attendees, Tasks — across every account on the `USER_GOOGLE_EMAILS` roster | 2, routinely surfaces 3 | Zen **paid open** models or Together. Never Zen free; never Claude/GPT via Zen for a sweep, because a bill or a lab result drifts through inbox triage by design. Digests carry subjects and summaries, never bodies |
| **Todoist** <!-- connector: todoist --> | Task and project names, notes, due dates, labels. Doist hosts the MCP server itself, so this text transits Doist — the party that already stores it, and no fourth one | 2 | Tier 1–2 routes (Zen paid, Together). Never free models. If health or money detail ends up in a task title, that session is Tier 3 and routes as Tier 3 |
| **IMAP + CalDAV (generic)** <!-- connector: imap-caldav --> | Whole message bodies from any mailbox it is pointed at, plus CalDAV event titles, times and attendees. Scope is whatever the account can read — there is no server-side filter | 2, routinely surfaces 3 | Same as Google Workspace: Zen paid open or Together, never free, never a 30-day-retention route for a sweep |
| **Proton Mail** <!-- connector: proton-mail --> | Read-only Proton mailbox contents, message bodies included, decrypted by a Proton Bridge running on the brain — so the plaintext exists on the encrypted `/data` volume and nowhere else at rest | 2, routinely surfaces 3 | Same as above. The Bridge adds no third party; the mail content itself is what sets the tier |
| **Health Records** <!-- connector: health-records --> | Clinical documents exported from your own patient portal and committed to the life vault: visit notes, lab results, medication lists, diagnoses, insurance and billing | **3** | **Together (ZDR, HIPAA/BAA posture) or a Zen paid open model only**, pinned before the first call — never Claude/GPT via Zen, never free models. Delivery stays PHI-free: counts and neutral titles only, no condition, medication, provider or dollar amount |

Two things this table deliberately does *not* do. It does not re-tier per message: a
connector is classified by the most sensitive content it **can** surface, so "2, routinely
surfaces 3" means the sweep that reads it is pinned as if it were 3. And it does not replace
the provider table: a connector whose data reaches a *new* provider needs a row in both, and
the bar for that provider is in [providers.md](providers.md).

## The encryption model

**At rest.** Everything stateful on the brain lives on a dedicated Hetzner Volume
encrypted with LUKS2 and mounted at `/data`: goose's own state, the private life-vault
clone, `/data/secrets.env`, and the Google OAuth tokens. Hetzner snapshots, disk reuse,
and hardware disposal therefore never expose plaintext state. Details in
[security.md](security.md).

"goose's own state" is three directories, not one — and that distinction was, for a
while, the hole in this section:

| goose dir | Default location | What is in it |
|---|---|---|
| config | `~/.config/goose` | `config.yaml`, `.goosehints`, `memory/`, and `secrets.yaml` (mode 0600) — where a credential goes when there is no keyring |
| data | `~/.local/share/goose` | `sessions.db` — your entire chat history, including every tool result — and `schedule.json` |
| state | `~/.local/state/goose` | `logs/llm_request.*.jsonl` — described by goose's own documentation as the raw request and response data sent to language-model providers |

Only **data** was relocated originally, by a `~/.local/share/goose → /data/goose-data`
symlink. Config and state stayed where they defaulted, on the **unencrypted root disk** —
which meant `llm_request` logs holding verbatim email bodies and life-vault text, and a
`secrets.yaml` holding connector credentials, sat outside the LUKS volume. Until this was
fixed, this document's claim that the root disk "holds only the OS and this public repo's
code" was **false**, and it is recorded here rather than quietly deleted because the class
of mistake — an application splitting its state across three XDG directories while you
relocate one — will recur with the next thing installed on the brain.

What makes the claim true is one line in
[`goose-serve.service`](../scripts/vps/systemd/goose-serve.service):

```
Environment=GOOSE_PATH_ROOT=/data/goose
```

which relocates config, data **and** state together under one absolute root (verified
against goose 1.46.0). `scripts/vps/deploy-vps.sh` migrates an existing brain into that
layout without touching session history, and additionally points
`~/.config/goose`, `~/.local/share/goose` and `~/.local/state/goose` at it as symlinks —
because `goose` run by hand over SSH does *not* inherit the systemd unit's environment,
and would otherwise quietly recreate the split. `scripts/verify/check-security.sh --local`
asserts that all three resolve under `/data`.

Two honest residuals. Migration is a cross-device move: it unlinks the root-disk copy but
does not wipe the freed blocks, so anything logged *before* the migration may remain
recoverable from the unencrypted disk until it is overwritten. And `llm_request` logging
is unconditional — it happens regardless of tier, which is why the tier of a session has
to be decided by the routing before the call, never as a filter afterwards
([connecting.md](connecting.md)).

**In transit.** The brain is reachable only over your Tailscale tailnet — WireGuard
encryption end to end, no public inbound ports. On top of that, `goose serve` runs TLS
with a shared secret (`GOOSE_SERVER__SECRET_KEY`) and clients pin its certificate
fingerprint, so even on-tailnet traffic is encrypted and authenticated twice over. All
egress to inference providers and MCP services is HTTPS.

**The honest residual risk.** VPS disk encryption protects data at rest — snapshots,
recycled disks, an attacker who obtains the volume. It does **not** protect against a
live-compromised hypervisor: while the volume is unlocked and mounted, the host machine's
operator (or an attacker with hypervisor access) can in principle read memory, including
the LUKS key and decrypted data. There is no practical defense against this short of not
using a cloud VPS. This risk is **accepted**, consistent with the "cloud is fine with
strict policies" stance: Hetzner is a reliable European provider, and the realistic
threats (snapshot exposure, disk disposal, opportunistic scanning) are all covered. If
your threat model ever grows to include the hosting provider itself, the design ports to
a homelab box unchanged — that's the exit path, documented in
[roadmap.md](roadmap.md).

## The Goose iOS tunnel and Cloudflare

The Goose iOS app reaches the brain through an **outbound-only** websocket tunnel that
relays via Cloudflare's infrastructure. This means: no inbound port is opened on the
brain (good), but session traffic transits a Cloudflare relay in addition to the
Goose-level encryption (a third party in the phone path that the Mac path — Desktop over
Tailscale — does not have).

If that's unacceptable to you, the alternatives, in order of preference:

1. **Don't pair the iOS app.** Use Goose Desktop over Tailscale on the Mac as the only
   interactive brain client; automation results arrive by email.
2. **Telegram gateway** on the brain — moves the relay trust from Cloudflare to Telegram;
   different party, same shape of trade-off.
3. **Pal Chat** direct to Together — bypasses the brain entirely (device-local history,
   ZDR provider), at the cost of losing the shared history.

The tunnel is a pragmatic accepted trade for now; the Goose mobile roadmap (native remote
ACP over your own network) is the thing to watch for removing it — see
[roadmap.md](roadmap.md).

## Delivery channels: never PHI, never account numbers

Content delivery is a self-addressed email per recipe (your own Gmail, end to
end). Failure alerts go through ntfy (`https://ntfy.sh/$NTFY_TOPIC`) and its
email gateway. The public ntfy server sees every alert message, and the topic
name is only a shared secret — treat alert content as if it could
be read. The rule:

- **Sensitive jobs report counts and neutral titles only.** Good: `health-followups: 3
  items appended`. Bad: anything naming a condition, medication, provider, dollar amount,
  or account. The detail lives in the vault on the encrypted volume; the message just tells
  you to go look.
- Non-sensitive jobs (morning brief, inbox triage) may email digests, but keep them to
  subjects/summaries — no message bodies.
- All failure alerts go through `scripts/common/notify.sh` — one choke point, so the rule is
  enforced in one place. Recipes never assemble their own ntfy requests.

### The agent channel (`NTFY_AGENT_TOPIC`) — a second choke point, not a second rule

There are now **two** ntfy channels, and the rule is one choke point *per
channel* rather than one for the whole box. The second is the code-agent
channel: the phone buzzes when a code-agent turn ends, or when an agent is
parked waiting for permission to push. It is assembled in exactly one function
— `notify_agent()` in `scripts/vps/code-agent-manager.py` — and nothing else
may send on it. It deliberately does **not** call `notify.sh`, which attaches
an `Email:` header whenever `NTFY_EMAIL` is set and would burn the ~5/day
forwarding cap the failure alerts depend on.

Its payload is content-free **by construction**, not by review:

```json
{ "kind": "ask" | "turn", "handle": "<opaque random>", "count": 1 }
```

plus a fixed neutral title ("A code agent is waiting on you", "A code agent
turn ended"). The app fetches the truth back over the tailnet once it is open;
the push only has to say "go look". Every field an implementer reaches for
first is contaminated, which is exactly why the list is this short: a chat id
embeds the repository name (`f"{repo}-{suffix}"` — one private repo name per
notification), a chat title defaults to the first 80 characters of your own raw
prompt, and a bash ask's metadata is the literal shell command.
`scripts/verify/test-code-agent-manager.sh` asserts their absence against the
recorded bytes rather than against anyone's intentions.

**The bar for this channel is the lock screen, not the app.** A notification
renders on a *locked* phone, and iOS's Show Previews setting is per-device —
the brain cannot read it and cannot enforce it. A body that is safe behind Face
ID is not safe here, and no header we can send makes it so. For the same reason
a notification is never itself answerable: no Allow/Deny buttons, ever. The tap
only opens the app, and the app re-reads the real pending ask over the tailnet
before showing anything actionable.

Both `NTFY_TOPIC` and `NTFY_AGENT_TOPIC` are secrets: they live in the Keychain
(Mac) and `/data/secrets.env` (brain), never in this repo. See
[public-repo.md](public-repo.md). They are separate values on purpose —
subscribing a phone to the agent topic turns that topic from a read-only leak
into a **write channel onto your lock screen** (anyone who learns it can plant
"code agent wants to push to main" there), so it has to be rotatable without
taking the failure-alert backstop down with it.

## Multiple accounts (and, later, multiple providers)

With a `USER_GOOGLE_EMAILS` roster ([30-google-oauth.md §8](setup/30-google-oauth.md)),
the sweep recipes read every listed account. Two things change, and one rule keeps
everything honest:

- **Classification doesn't care which account content came from.** A second Gmail's
  inbox is Tier 2 like the first, and can surface Tier 3 content the same way — the
  tier table above applies per *content*, not per account. Nothing about the model
  routing changes.
- **Digests aggregate across accounts into the primary inbox.** The one self-addressed
  delivery email (always sent from and to the **primary** account) now carries
  subjects/summaries from every account on the roster — so a secondary account's
  content ends up stored in the primary account's mailbox. If that crossing is
  unacceptable for some account, leave it off the roster; it stays reachable
  interactively without ever appearing in a digest.
- **The send rule tightens rather than loosens:** the single self-addressed email from
  the primary is still the *only* send; secondary accounts are never sent from at all
  (inbox-triage's drafts stay inside the account that owns the thread).

Non-Google providers are not wired in yet; the bar any future provider must clear —
including a policy row in this document *before* adoption — is defined in
[providers.md](providers.md).
