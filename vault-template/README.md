# Life vault

This is the skeleton of your **private** life vault — the sensitive tier of
the personal-ai setup: medical records, insurance and billing paperwork,
appointment notes, the budget. Seed a separate private repository from this
template (`docs/setup/60-vault-setup.md` in the personal-ai-setup repo walks
through it), then delete the `EXAMPLE` rows and start filling it with real
life.

## The rules (non-negotiable)

These are the operational form of the personal-ai-setup repo's
`docs/privacy.md` — everything in this vault is **Tier 3 (sensitive)** by
definition:

1. **This content never enters the public `personal-ai-setup` repo.** The
   flow is one-way, forever: template → vault. Never copy a file back — not
   even "just one example". The public repo's secret-scanning guardrails do
   not see this repo; separation *is* the guardrail.
2. **Only ZDR / no-training models may read vault content.** Allowed
   (verified as of 2026-08-20):
   - **Together AI** — the home of this tier (ZDR by default, HIPAA/BAA
     posture): `Qwen/Qwen3.5-397B-A17B` for Q&A,
     `deepseek-ai/DeepSeek-V4-Flash` for long documents.
   - **Zen paid open models** (Kimi/GLM/MiniMax/DeepSeek — zero retention) as
     the fallback when Together is unavailable.
   - Never Claude or GPT models billed via Zen (30-day retention), and never
     any free model (they may train on your data).
3. **This repository must be private.** Check the visibility toggle twice at
   creation, and never add collaborators or mirrors.
4. **Data, not credentials.** Insurance member IDs, provider phone numbers,
   and dates belong here; passwords, API keys, PINs, and full financial
   account/card numbers never do — those live in the Keychain, in
   `/data/secrets.env`, or in your password manager. See
   `admin/reference.md`'s header.
5. **Nothing from the vault goes into a push notification.** Automations that
   read this vault report counts and neutral titles only.

## Where it lives

- **Canonical working copy:** `/data/life-vault` on the brain — the
  LUKS-encrypted volume, so the vault is unreadable at rest and absent until
  the volume is unlocked. This is the copy the agent (and the
  `health-followups` / `budget-checkin` automations) reads and writes.
- **The private git remote is the backup.** The weekly `health-followups`
  automation is the only one that syncs on its own: it pulls (`--ff-only`)
  before reading, then commits and pushes its own append with a short
  generic message. Everything else is manual — commit and push after
  meaningful hand edits, and on the brain run `git -C /data/life-vault pull`
  before a `vault-qa` or `budget-checkin` run if you have pushed edits from
  the Mac (those two recipes never touch git or the network). Restoring the
  vault after any disaster is `git clone` + nothing else.
- An optional clone on the Mac is fine (FileVault-encrypted disk); phones,
  cloud drives, and sync services are not.

## Directory map

| Path | What goes in it |
|---|---|
| `health/records/` | Medical records: visit summaries, lab results, imaging reports, discharge notes — each original PDF **plus** a markdown conversion with the same basename |
| `health/insurance/` | Policies, coverage summaries, EOBs, prior-auth letters |
| `health/billing/` | Medical bills, receipts, payment disputes and their paper trails |
| `health/appointments.md` | Running log of appointments, follow-ups owed, and questions to ask — the file the weekly `health-followups` automation maintains |
| `finance/ledger.csv` | Transaction ledger (`date,amount,category,note`) — input to `budget-checkin` |
| `finance/budget.md` | Monthly category targets — what `budget-checkin` compares the ledger against |
| `admin/reference.md` | Non-secret reference info: policy numbers, provider contacts, important dates |

## Conventions the automations rely on

- **Keep the paths above stable.** `health-followups` appends to
  `health/appointments.md` by path; `budget-checkin` reads
  `finance/ledger.csv` and `finance/budget.md` by path.
- **Name documents date-first** so listings sort chronologically and the
  agent can reason about recency: `2026-03-12-dental-visit.md` (and
  `2026-03-12-dental-visit.pdf` beside it).
- **Ledger amounts are positive numbers = money spent** (see
  `finance/budget.md` for the full convention).
- `health/appointments.md` must keep its `## Follow-ups` heading — the
  automation maintains checkbox items under it and its success check greps
  for that exact heading.
