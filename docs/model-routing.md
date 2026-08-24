# Model routing

One table decides which model handles which job. It exists for two reasons: cost stays
predictable, and — more importantly — each class of your data only ever reaches providers
whose retention policy is allowed to hold it. The policy behind the tiers lives in
[privacy.md](privacy.md); this file is the operational reference you consult when wiring a
recipe, starting a session, or wondering why a job is pinned to a given provider.

All prices are per 1M tokens (input/output), **verified as of 2026-08-20** against the
provider catalogs ([opencode.ai/docs/zen](https://opencode.ai/docs/zen) and Together's
pricing/model pages). Both catalogs churn — re-verify at signup and monthly via
`scripts/verify/pin-models.sh`.

## The routing table

| Job class | Route | Model | Price |
|---|---|---|---|
| Interactive coding (daily) | OpenCode → Zen | `kimi-k2.6` | $0.95/$4.00 |
| Coding escalation | OpenCode → Zen | `claude-sonnet-5` | $2/$10 |
| Throwaway/non-personal code | OpenCode → Zen | `big-pickle` (free) | $0 — **never personal data** |
| Hub daily driver (brain) — **default** | Goose → `together` | `Qwen/Qwen3.5-397B-A17B` | $0.60/$3.60 (ZDR — private by default) |
| Hub premium alternative (non-sensitive) | Goose → `zen-anthropic` | `claude-sonnet-5` | $2/$10 (30-day retention) |
| Hub cost-saver | Goose → `zen-openai` | `kimi-k2.6` | $0.95/$4.00 |
| Scheduled automations | Goose → `zen-openai` | `minimax-m2.7` | $0.30/$1.20 |
| Automation fallback | Goose → `together` | `openai/gpt-oss-120b` | $0.15/$0.60 (verified tool-caller) |
| Sensitive doc Q&A | Goose → `together` | `Qwen3.5-397B-A17B` | $0.60/$3.60 (ZDR/HIPAA) |
| Sensitive long-context (big PDFs) | Goose → `together` | DeepSeek V4 Flash | $0.14/$0.28, 1M ctx |
| Code agents (brain, per-chat containers) | OpenCode in container → Zen/Together | **owner's choice at kick-off** — default `deepseek-v4-flash` | Zen: peak/off-peak; Together alt $0.14/$0.28 |
| Backup phone chat (Pal Chat) | Together direct | gpt-oss-120b / Qwen3.5 | cheap, ZDR |
| Image/screenshot chats | Goose → `together` | `google/gemma-4-31B-it` | serverless vision, ZDR |
| Embeddings (roadmap RAG) | Together | M2-BERT-80M-32K | ~$0.01 |

Notes on reading the table:

- `together`, `zen-openai`, `zen-anthropic`, and `zen-free` are the four Goose custom
  providers defined in `config/goose/custom_providers/`. `together` (the **default**) and
  `zen-openai` speak OpenAI chat-completions; `zen-anthropic` speaks Anthropic messages
  (its `base_url` is `https://opencode.ai/zen` — goose appends `/v1/messages` itself);
  `zen-free` is Zen's $0 models split into their own provider so the "trains on your
  data" boundary stays visible in the model picker (hard rule 1).
- Each provider ships a broad model catalog, and `scripts/sync-models.sh` refreshes all
  four lists from the live Zen and Together `/models` endpoints. **Catalog breadth is for
  manual picking; it does not loosen routing.** The table above still decides what runs
  each *job*, and the hard rules below still bound what any picked model may see.
- Want OpenAI's models in goose? Zen's GPT-5.x models are Responses-API-only and
  unreachable from goose (see below), so the direct route is goose's built-in `openai`
  provider — uncomment the block in `config/goose/config.yaml` and add `OPENAI_API_KEY`.
  Treat it like `zen-anthropic`: ~30-day retention, hard rule 2 applies. (OpenCode
  reaches Zen's GPT models natively, and OpenAI's open-weight `gpt-oss` models are
  already on `together`.)
- "OpenCode → Zen" rows run in the OpenCode CLI (your coding driver), connected to Zen via
  `/connect`. They never pass through Goose or the brain.
- The **code agents** row is the one deliberately unpinned job class: model choice is
  per-chat at kick-off (`docs/code-agents.md`), defaulting to `deepseek-v4-flash`. The
  hard rules still bind — the session manager refuses zen-free models for any repo not
  flagged `public_throwaway` in the allowlist, and only Tier 1/2 repos are allowlistable
  at all, so the free-tier and retention rules cannot be violated by a model pick.
- Together model IDs are full registry IDs: `openai/gpt-oss-120b`,
  `Qwen/Qwen3.5-397B-A17B`, and `deepseek-ai/DeepSeek-V4-Flash-0731` — Together publishes dated
  variants of DeepSeek V4 Flash, so confirm the exact live ID with
  `scripts/verify/pin-models.sh` before pinning it anywhere new.
- DeepSeek V4 Flash is priced differently per route: flat $0.14/$0.28 with 1M context on
  Together, peak/off-peak priced on Zen. The sensitive long-context row deliberately uses
  Together — cheaper, bigger context, and the right privacy posture.
- Zen sells at cost with only card-processing fees on top; Together is standard serverless
  pricing. Neither has a subscription.

## Hard rules — these override convenience, always

1. **Zen free models never see personal data.** All six free models (`big-pickle`,
   MiMo-V2.5 Free, Hy3 Free, the Nemotron frees, Muse Spark Contributor) are explicitly
   exempt from Zen's zero-retention/no-training policy — they may train on your prompts
   ([Zen docs](https://opencode.ai/docs/zen)). Free tier is for throwaway, non-personal
   code only. Nothing from email, calendar, the vault, or any chat that mentions your life.
2. **Claude and GPT models billed through Zen never see health or finance data.**
   Anthropic- and OpenAI-billed requests carry 30-day retention per those providers'
   policies — the one exception to Zen's zero-retention posture. `claude-sonnet-5` (and
   the optional `openai` provider) are fine for general and personal-but-not-sensitive
   work, but the moment a session touches medical records, insurance, billing, or the
   budget, it belongs on the sensitive tier.
3. **Sensitive tier = Together (ZDR default, HIPAA/BAA posture) or Zen paid open models
   only.** The vault recipes (`vault-qa`, `health-followups`, `budget-checkin`) pin
   Together. Zen's paid open models (Kimi, GLM, MiniMax, DeepSeek, Qwen — zero retention,
   no training) are the acceptable fallback if Together is down or rate-limited. Never
   Claude/GPT via Zen, never a free model.
4. **Recipes pin their model.** Every recipe in `recipes/` carries an explicit
   `goose_provider`/`goose_model` in its settings so a changed session default can never
   silently reroute a sensitive job.

## How to switch models

Four levers, from most to least persistent:

- **Default provider/model** — `goose configure` (interactive) sets `GOOSE_PROVIDER` and
  `GOOSE_MODEL` in `~/.config/goose/config.yaml`. This is what interactive sessions use
  when nothing else overrides them. The Desktop app's model picker changes the same
  default.
- **Per run** — `goose run` (and `goose session`) accept overrides:

  ```bash
  goose run --provider together --model "Qwen/Qwen3.5-397B-A17B" -t "..."
  ```

- **Per recipe** — recipes pin their own model in the settings block, which beats the
  session default whenever that recipe runs (interactively or scheduled):

  ```yaml
  settings:
    goose_provider: together
    goose_model: "Qwen/Qwen3.5-397B-A17B"
  ```

- **Environment** — `GOOSE_PROVIDER`/`GOOSE_MODEL` env vars: a manual override
  lever only. They outrank config for the process they're set in, which is
  exactly why `scripts/common/run-recipe.sh` and the systemd fallback units
  deliberately do **not** set them — recipe-pinned models (hard rule 4) must
  always win on headless runs.

In OpenCode, `/models` switches interactively and `opencode.json` pins defaults; see
`config/opencode/opencode.json`.

## Zen GPT-5.x models: unreachable from Goose, accepted

Zen serves each model family in its native wire format. GPT-5.x (and Grok/Muse) live only
behind `https://opencode.ai/zen/v1/responses` — the OpenAI **Responses API** — while Goose
custom providers speak only OpenAI chat-completions, Anthropic messages, or Ollama
formats. So GPT-5.x via Zen is simply not addressable from Goose, and no route in the
table uses it. If you ever want a GPT model for coding, OpenCode reaches it natively; for
the hub, the Claude/Kimi/MiniMax lineup covers the same ground. This is an accepted
limitation, not a bug to fix.

## Model drift

Zen deprecates aggressively (18 models retired in the seven months before 2026-08-20,
including Kimi K2, GLM 4.x, and Qwen3 Coder) and Together's catalog churns almost as fast.
A pinned ID that 404s is the most likely way an automation dies quietly.

`scripts/verify/pin-models.sh` diffs every model ID pinned in `config/` and `recipes/`
against the live catalogs (`https://opencode.ai/zen/v1/models` and
`https://api.together.xyz/v1/models`) and reports anything missing or renamed. Run it
monthly and after any provider announcement. When a model disappears, update this table,
the custom-provider JSONs, and any recipe that pinned it — in the same commit.
