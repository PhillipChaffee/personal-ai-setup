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

## The encryption model

**At rest.** Everything stateful on the brain lives on a dedicated Hetzner Volume
encrypted with LUKS2 and mounted at `/data`: the Goose data directory
(`~/.local/share/goose` symlinked to `/data/goose-data`, so `sessions.db` — your entire
chat history — is encrypted), the private life-vault clone, `/data/secrets.env`, and the
Google OAuth tokens. The unencrypted root disk holds only the OS and this public repo's
code. Hetzner snapshots, disk reuse, and hardware disposal therefore never expose
plaintext state. Details in [security.md](security.md).

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

The `NTFY_TOPIC` value itself is a secret: it lives in the Keychain (Mac) and
`/data/secrets.env` (brain), never in this repo. See
[public-repo.md](public-repo.md).
