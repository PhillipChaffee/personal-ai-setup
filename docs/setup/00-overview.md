# Setup overview — start here

## What you're building

A self-owned personal AI stack: one always-on Goose agent (the **brain**) on a
small, hardened, Terraform-managed VPS holds your single chat history and runs
all scheduled automations; your Mac and iPhone are thin clients to it over
Tailscale; inference is pay-as-you-go against OpenCode Zen and Together AI with
strict per-tier privacy rules; OpenCode is the dedicated coding agent on the
Mac. It handles coding, writing/research, personal admin (Gmail, Calendar,
Todoist), background automations, and — on a stricter tier — healthcare records
Q&A and budgeting.

The architecture diagram and component map live in the
[README](../../README.md). The privacy tiers and hard routing rules live in
[`docs/model-routing.md`](../model-routing.md) and
[`docs/privacy.md`](../privacy.md) — skim both before Phase 1 so the tier
system is in your head while you create accounts.

## The five phases

Work through them in order; each builds on the last and ends with a verify
script. Total hands-on time: roughly a weekend, spread out however you like.

| Phase | Doc | Time | Milestone |
|---|---|---|---|
| 1 — Day-1 minimal viable | [10-accounts.md](10-accounts.md) → [20-mac-setup.md](20-mac-setup.md) | ~1–2 h | You can chat with your own models from the Mac (OpenCode + goose CLI) and from the iPhone (Pal Chat) — no server, working on day one. |
| 2 — Admin plumbing | [30-google-oauth.md](30-google-oauth.md) (+ Tailscale/Todoist from [10-accounts.md](10-accounts.md)) | ~2–3 h | Goose on the Mac reads your Gmail, Calendar, and Todoist through your own OAuth app — no aggregator in the middle. |
| 3 — The brain | [50-vps-brain.md](50-vps-brain.md) → [40-phone-setup.md](40-phone-setup.md) | ~3 h | **The same chat history on Desktop and iPhone, and the morning brief arrives automatically.** This is the payoff phase. |
| 4 — Sensitive tier | [60-vault-setup.md](60-vault-setup.md) | ~1–2 h | Your health and finance documents are answerable from the phone, pinned to Together (ZDR/HIPAA tier), with PHI-free push notifications. |
| 5 — Go public + roadmap | [`docs/public-repo.md`](../public-repo.md), [`docs/roadmap.md`](../roadmap.md) | ~1 h | Guardrails green (gitleaks full-history scan, placeholder audit) and the repo flipped public; roadmap items queued. |

Phase details, verification steps, and the exact scripts each phase runs are in
the per-phase docs. The one rule: **don't skip the verify scripts** — they were
written to settle exactly the things most likely to be silently broken
(provider base-URL semantics, Zen auth headers, cross-device session
visibility, open ports).

## Monthly budget

Approved budget is $50+/mo; expected spend sits well under it. Figures verified
as of 2026-08-20 — re-verify at signup, and run `scripts/verify/pin-models.sh`
monthly to catch price/model drift.

| Item | ~Cost/mo |
|---|---|
| Hetzner CX22-class VPS + LUKS-encrypted volume | ~$5 (≈€5–7) |
| Inference at expected usage (Zen + Together combined) | ~$10–30 |
| Tailscale personal plan, ntfy public topic, Todoist free tier | $0 |
| Pal Chat backup client | ~$7 one-time |
| **Total** | **~$15–35/mo** |

The inference range is wide because it tracks your usage directly — that's the
point of PAYG. What keeps it near the bottom of the range:

- Scheduled automations run on `minimax-m2.7` ($0.30/$1.20 per 1M tokens), not
  a frontier model.
- Daily coding runs on `kimi-k2.6` ($0.95/$4.00), escalating to
  `claude-sonnet-5` ($2/$10) only when needed.
- The sensitive tier tops out at `Qwen3.5-397B` ($0.60/$3.60), with big-PDF
  work on DeepSeek V4 Flash ($0.14/$0.28).
- **Zen auto-reload gets disabled and a monthly cap set on day one**
  ([10-accounts.md](10-accounts.md)) — the two settings that stop a runaway
  loop from becoming a runaway bill.

## Conventions

These hold everywhere in the repo — docs, configs, scripts. If something you
read contradicts them, the thing you read is wrong.

**Where secrets live.** Never in this repo — it is public by design.

| Platform | Location | Managed by |
|---|---|---|
| Mac | macOS Keychain | `scripts/mac/keychain-secrets.sh` (never set `GOOSE_DISABLE_KEYRING`) |
| VPS brain | `/data/secrets.env` — chmod 600, on the LUKS volume | copied from `config/env/secrets.env.example`; loaded by systemd `EnvironmentFile` |
| Terraform | `infra/terraform/terraform.tfvars` — gitignored | copied from `terraform.tfvars.example` |
| LUKS passphrase | your password manager only | nowhere on any machine |

Canonical secret variable names, used identically on every platform:
`OPENCODE_ZEN_API_KEY`, `TOGETHER_API_KEY`, `GOOSE_SERVER__SECRET_KEY`,
`NTFY_TOPIC`, `TAVILY_API_KEY` (optional), `GOOGLE_OAUTH_CLIENT_ID`,
`GOOGLE_OAUTH_CLIENT_SECRET`. The full annotated list is
`config/env/secrets.env.example`.

**Provider names.** Goose knows exactly four custom providers, named
`together` (the default), `zen-openai` (Zen's `/chat/completions` models),
`zen-anthropic` (Zen's `/messages` models), and `zen-free` (Zen's $0 models,
which train on your data — kept separate so the boundary is visible in the
picker). Recipes, docs, and scripts all reference these names — keep them
verbatim, since a renamed provider silently breaks every recipe pinned to it.
Each ships a broad model list; `scripts/sync-models.sh` refreshes all of them
from the live catalogs.

**Where recipes live.** Automations are recipe YAMLs in `recipes/` in this
repo, registered on the **brain's** native scheduler by
`scripts/vps/register-schedules.sh`. Nothing is scheduled on the Mac — no
launchd, no cron — so a sleeping laptop never affects an automation. The
scheduler copies recipes at registration time: after editing a recipe, re-run
`register-schedules.sh` (see [`docs/automations.md`](../automations.md)).

**When something breaks.** [`docs/troubleshooting.md`](../troubleshooting.md)
is symptom-indexed and covers the known failure modes end to end.
