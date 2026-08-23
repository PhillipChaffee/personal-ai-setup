# personal-ai-setup

Build your own personal AI — one agent with one memory, available on your phone and laptop, running your automations around the clock — out of open-source parts and pay-as-you-go inference. No hosted-assistant subscriptions, no lock-in, and your sensitive data only ever reaches zero-data-retention endpoints.

This repo is the complete, reproducible blueprint: Terraform for the server, config templates for every component, ready-made automations, verification scripts for each setup phase, and step-by-step runbooks. Follow it end to end and you'll have the whole thing running in a weekend for **~$15–35/month**.

**What you get:**

- **One AI, one history.** A [Goose](https://github.com/aaif-goose/goose) agent (the "brain") runs 24/7 on a small hardened VPS. Your laptop and phone are thin clients to it — start a conversation anywhere, continue it everywhere. (The phone app is experimental; a fallback chain is documented.)
- **Automations that just happen.** A morning brief in your inbox at 7:00, inbox triage that labels and drafts (never sends to anyone but you), a Sunday weekly review — all Goose recipes on its native scheduler, managed from a UI, each emailing you its own result (failures alert separately via [ntfy](https://ntfy.sh)'s email gateway).
- **A serious coding agent.** [OpenCode](https://github.com/anomalyco/opencode) on your laptop, wired to the same inference accounts — plus **code agents on the brain**: Claude Code-style autonomous coding chats, each in its own container, kicked off and reviewed from your phone ([`docs/code-agents.md`](docs/code-agents.md)).
- **A private tier for life admin.** Email, calendar, and todos via MCP; health records and budget Q&A behind hard privacy rules — that data only ever reaches [Together AI](https://docs.together.ai) (zero-data-retention default, SOC 2, HIPAA posture), never free models, never providers that retain.
- **Cheap, flexible inference.** [OpenCode Zen](https://opencode.ai/docs/zen) (at-cost gateway: Kimi, GLM, MiniMax, DeepSeek, Claude…) plus Together AI (200+ open models). Broad model catalogs ship in the configs; `scripts/sync-models.sh` refreshes them from the live catalogs. Swap any of it — that's the point.

## Before you start

| You need | Notes |
|---|---|
| A Mac + an iPhone | The runbooks are written for this pair. Linux laptop or Android phone work in principle (Goose and OpenCode are cross-platform) but you'll be substituting steps yourself. |
| Comfort with a terminal | You'll run scripts, `terraform apply`, and paste commands over SSH. Every step is written out; no improvisation required. |
| ~$15–35/month | Breakdown in [Budget](#budget). The two inference accounts are pay-as-you-go with hard caps. |
| A free weekend, roughly | Phase 1 gets you working AI in 1–2 hours; the full build is ~8–10 hours spread over the five phases. |
| Accounts you'll create | OpenCode Zen, Together AI, Hetzner (VPS), Tailscale, a Google Cloud OAuth app for your own Gmail/Calendar (a todo app like Todoist is optional). Each has a runbook with the gotchas called out. |

## Quickstart

1. **Fork or clone this repo.** Everything you deploy comes from your copy; everything personal stays out of it (see [Adapting it to you](#adapting-it-to-you)).
2. **Read [`docs/setup/00-overview.md`](docs/setup/00-overview.md)** — it frames the five phases. Then just follow them in order:

| Phase | What happens | Time | Milestone |
|---|---|---|---|
| [1 — Day-1 minimal viable](docs/setup/10-accounts.md) | Inference accounts, Mac bootstrap, keys in Keychain | 1–2 h | Working AI on Mac + phone, same day |
| [2 — Admin plumbing](docs/setup/30-google-oauth.md) | Your own Google OAuth app (+ Tailscale/Todoist steps from phase 1's doc) | 2–3 h | The agent reads your email, calendar, todos |
| [3 — The brain](docs/setup/50-vps-brain.md) | `terraform apply`, encrypted volume, deploy, pair devices | ~3 h | Same chat history on laptop + phone; morning brief arrives by itself |
| [4 — Sensitive tier](docs/setup/60-vault-setup.md) | Private life-vault repo, health/finance Q&A | 1–2 h | Ask questions about your own documents, privately |
| [5 — Go public + roadmap](docs/public-repo.md) | Publish your fork safely; future upgrades | 1 h | — |

3. **Run the verify script at the end of each phase** (`scripts/verify/`). Don't skip them — each one settles exactly the things most likely to be broken (API auth shapes, provider wiring, open ports, cross-device history).

## Architecture

```
iPhone                          Mac laptop                       VPS "brain" (Hetzner, Terraform-managed)
──────                          ──────────                       ────────────────────────────────────────
Goose iOS app ◄── tunnel ─────────────────────────────────────►  goose serve --enable-scheduler (systemd)
Email inbox ◄─ recipes' self-addressed results (Gmail) ───────    ├─ sessions.db ─── THE shared history
Telegram gw (fallback) ◄──────────────────────────────────────    ├─ native scheduler ── THE automations
Pal Chat (backup) ─┐            Goose Desktop ◄─ remote ACP ─►    ├─ MCP: workspace-mcp, Todoist, search
                   │            OpenCode app ◄─ HTTPS :4300 ──►   ├─ code agents: per-chat containers
Siri Shortcut ─────┤            OpenCode CLI (coding, local)      ├─ life-vault clone (private repo)
                   │            goose CLI (offline fallback)      └─ all state on LUKS-encrypted volume
                   └────────────────────────────────────────►┌──►  Zen API / Together API (HTTPS)
                                                             │
        Tailscale tailnet (WireGuard) — the ONLY path to the brain; zero public inbound ports
```

| Surface | Role |
|---|---|
| **VPS "brain"** (Hetzner cpx21-class, Ubuntu 24.04) | Runs `goose serve --enable-scheduler` under systemd. Owns the one shared chat history (`sessions.db`) and all scheduled automations. All state — sessions, secrets, OAuth tokens, life-vault clone — sits on a LUKS-encrypted volume at `/data`. Reachable only over Tailscale, TLS + shared-secret auth, zero public inbound ports. |
| **Goose** (hub agent, on the brain) | General-purpose agent under Linux Foundation / AAIF governance — explicitly "not just for code": research, writing, automation, personal admin. MCP-native extensions, built-in Memory, custom providers for Zen and Together, recipes + built-in cron scheduler. Pinned to stable 1.x (2.0 is in RC churn). |
| **Goose Desktop** (Mac) | Full desktop UI, attached to the brain as a remote client over goose's Agent Client Protocol ("remote ACP" in the diagram) — same sessions as the phone. Also hosts the Scheduler UI (pause / run-now / per-run history). |
| **goose CLI** (Mac) | Local offline fallback hub when the brain is unreachable. |
| **OpenCode CLI** (Mac) | The daily coding driver — dedicated open-source coding agent with first-party Zen integration (`/connect`), per-agent cheap-model routing, and the same MCP servers. Runs locally; coding sessions don't need the brain. |
| **Code agents** (on the brain) | Claude Code-style autonomous coding chats: one container per chat (idle chats spin down, volumes persist), live streaming + permission asks to your devices, any model per chat, PRs as the deliverable. Managed by `code-agent-manager` behind the tailnet on port 4300. See [`docs/code-agents.md`](docs/code-agents.md). |
| **Goose iOS app** | Primary phone surface: thin remote client tunneling to the brain (experimental; fallback chain documented in `docs/setup/40-phone-setup.md`). |
| **Pal Chat** (iPhone) | BYOK backup chat straight to Together — works even if the brain is down. Backup precisely because its history is device-local. |
| **ntfy / Telegram / Siri Shortcut** | Failure-alert channel (topic publish forwarded to your email via ntfy's gateway — no app to install); fallback phone channel; voice one-shots. |
| **Tailscale** | WireGuard mesh — the only network path to the brain. |
| **OpenCode Zen** | At-cost pay-as-you-go inference gateway, one key, per-family wire formats. Zero-retention/no-training on its hosted open models; caveats per tier in `docs/privacy.md`. |
| **Together AI** | OpenAI-compatible inference over 200+ open models. ZDR by default, no training without opt-in, SOC 2, HIPAA/BAA posture — the sensitive (health/finance) tier lives here exclusively. |

## Repo map

```
.
├── README.md                           # you are here
├── LICENSE                             # MIT
├── .gitignore                          # keeps secrets, tfstate/tfvars, OAuth tokens out of a public repo
├── .pre-commit-config.yaml             # gitleaks secret scan before every commit
├── .github/workflows/secret-scan.yml   # gitleaks CI over full history on every push/PR
├── docs/
│   ├── setup/00-overview.md … 60-vault-setup.md   # the five-phase runbooks — START at 00
│   ├── model-routing.md                # which model for which job + hard privacy rules
│   ├── privacy.md                      # data classification per provider tier; encryption model & residual risk
│   ├── automations.md                  # add/manage scheduled workflows; scheduler-bug fallback flip
│   ├── code-agents.md                  # code agents: per-chat containers, lifecycle, git/permission model
│   ├── providers.md                    # email/calendar provider convention (multi-account today, more providers next)
│   ├── cursor-port.md                  # the Cursor kit ported to Goose + OpenCode: what went where and why
│   ├── security.md                     # threat model, LUKS design, Tailscale-only exposure, serve TLS/secret
│   ├── public-repo.md                  # what may/may-not be committed; go-public checklist
│   ├── troubleshooting.md              # base_url 404s, scheduler bugs, pairing, LUKS, rate limits
│   └── roadmap.md                      # SearXNG, memory, budgeting-app API, vault RAG
├── infra/terraform/                    # Hetzner server, deny-all firewall, encrypted volume, cloud-init
├── config/
│   ├── goose/config.yaml               # goose settings + MCP extensions (developer, memory, workspace, Todoist, playwright)
│   ├── goose/custom_providers/         # together (DEFAULT), zen-openai, zen-anthropic, zen-free (trains on data — isolated on purpose)
│   ├── goose/goosehints.example        # identity, routing rules, vault path, PHI standing rules
│   ├── opencode/opencode.json          # OpenCode: Zen models + Together provider, cheap small_model
│   ├── opencode/AGENTS.md              # global coding/workflow rules template (→ ~/.config/opencode/AGENTS.md)
│   ├── opencode/agents/                # 30 review/research subagents (→ ~/.config/opencode/agents/)
│   ├── opencode/project-rules/         # per-project rule snippets (python, django, linear…) — paste-in
│   ├── skills/                         # 11 skills, Claude-compatible SKILL.md (→ ~/.agents/skills — read by BOTH OpenCode and goose)
│   ├── code-agents/                    # code-agent image, per-chat opencode config, repo-allowlist template
│   ├── mcp/workspace-mcp.env.example   # Google Workspace MCP env template
│   └── env/secrets.env.example         # every secret VAR NAME (no values) — copy to /data/secrets.env
├── recipes/                            # the six automations (brief, triage, review, health, vault-qa, budget)
├── scripts/
│   ├── mac/                            # bootstrap-mac.sh, keychain-secrets.sh
│   ├── vps/                            # deploy-vps.sh, LUKS setup/unlock, schedule registration, systemd units
│   ├── common/                         # run-recipe.sh (failure watchdog), notify.sh (failure alerts → ntfy email gateway)
│   ├── sync-models.sh                  # refresh provider model lists from the live Zen/Together catalogs
│   └── verify/                         # phase smoke-test scripts + model-drift detector
└── vault-template/                     # skeleton for the SEPARATE PRIVATE vault repo — no real data here
```

## Adapting it to you

The repo is a template; your identity and choices live outside it or in a handful of obvious places:

- **Identity**: `config/goose/goosehints.example` has `<placeholders>` for your name/email/timezone; `infra/terraform/terraform.tfvars.example` for your SSH key, Tailscale auth key, region. Secrets go in your Keychain (Mac) and `/data/secrets.env` (brain) — never in the repo.
- **Different VPS host**: everything host-specific is confined to `infra/terraform/`. Porting to DigitalOcean/Vultr means rewriting that one directory; nothing else cares.
- **Different models/providers**: providers are JSON files in `config/goose/custom_providers/`; the job→model routing (and the privacy rules that constrain it) is `docs/model-routing.md`. Any OpenAI- or Anthropic-compatible endpoint slots in.
- **Different apps**: Gmail/Calendar (and an optional todo app — a disabled Todoist entry ships as the worked example) are MCP servers declared in `config/goose/config.yaml` — swap for your own. The todo and budgeting choices are deliberately undecided (see `docs/roadmap.md`).
- **Your data**: real life data lives in a **separate private repo** you create from `vault-template/`. This repo stays publishable; that one never is.

## Principles

1. **One brain, one history.** The hub agent runs only on the VPS; its `sessions.db` is the single chat history. Every device — Desktop, iPhone, CLI — is a client to the same brain, so a conversation started anywhere continues everywhere. *One deliberate carve-out:* **code-agent chats** live in their own per-chat volumes on the brain (`docs/code-agents.md`), never in `sessions.db` — coding sessions and life-admin history stay structurally separate, unified only in the client UI.
2. **Native Goose automations.** Scheduled work is Goose recipes registered on Goose's built-in scheduler (`goose schedule add`), manageable from Desktop's Scheduler UI — not bare cron. Each scheduled recipe delivers its own result as an explicit final step: one self-addressed email via the Gmail send tool. `scripts/common/run-recipe.sh` acts as a failure watchdog (one retry, then a high-priority alert through `scripts/common/notify.sh`, emailed via ntfy's gateway) for manual and fallback-timer runs. Disabled systemd-timer fallbacks ship in-repo in case of scheduler bugs.
3. **Privacy tiers.** Every job class is pinned to a provider tier (`docs/model-routing.md`, `docs/privacy.md`). Health and finance data go to Together AI only (ZDR/HIPAA posture). Zen free models never see personal data. Claude/GPT via Zen never see health/finance data. Delivery emails and failure alerts never contain PHI.
4. **Everything as code.** Infrastructure is Terraform, configs are templates, host state is scripts + systemd units, and every manual step is a runbook. A dead laptop or dead VPS is an inconvenience, not a loss.
5. **Public-repo hygiene.** Safe by construction: only placeholders are committed; secrets are injected from untracked files; gitleaks runs at commit time and in CI over full history; `docs/public-repo.md` gates the flip to public.

## Budget

All figures verified as of 2026-08-20 — re-verify at signup (`scripts/verify/pin-models.sh` catches model/price drift monthly).

| Item | ~Cost |
|---|---|
| Hetzner cpx21-class VPS + encrypted volume | ~€6–9/mo |
| OpenCode Zen inference (PAYG — **disable auto-reload, set a cap**) | ~$5–20/mo typical |
| Together AI inference (min $5 top-up; sensitive tier + default hub) | ~$5–10/mo |
| Tailscale (personal plan), ntfy failure-alert emails (free tier) | $0 |
| Pal Chat (backup phone client) | ~$7 one-time |
| **Total** | **~$15–35/mo** |

Routing keeps costs predictable: scheduled automations run on `minimax-m2.7` ($0.30/$1.20 per 1M tokens), daily coding on `kimi-k2.6` ($0.95/$4.00), escalating to `claude-sonnet-5` ($2/$10) only when needed; the default hub and sensitive tier run on Together's `Qwen3.5-397B` ($0.60/$3.60). Full table with hard rules: [`docs/model-routing.md`](docs/model-routing.md).

## License

[MIT](LICENSE). Fork it, rebuild it, make it yours.
