# personal-ai-setup

A self-owned personal AI stack you can rebuild from scratch with the contents of this repo: one always-on [Goose](https://github.com/aaif-goose/goose) agent ("the brain") on a hardened, Terraform-managed VPS holds your single chat history and runs all scheduled automations; your Mac and iPhone are thin clients to it over Tailscale; inference goes to [OpenCode Zen](https://opencode.ai/docs/zen) (at-cost gateway, zero-retention tiers) and [Together AI](https://docs.together.ai) (ZDR/HIPAA posture, for the sensitive tier); [OpenCode](https://github.com/anomalyco/opencode) is the dedicated coding driver on the Mac. It covers coding, writing and research, personal admin (Gmail, Calendar, Todoist), background automations, and — behind a stricter privacy tier — healthcare records Q&A and budgeting. No hosted-assistant subscriptions, no lock-in, roughly $15–35/mo all-in.

**This repo is public by design.** It contains only templates, scripts, and docs with placeholders — never secrets, tokens, tailnet hostnames, ntfy topics, or personal data. Real secrets live in untracked files (`secrets.env`, `terraform.tfvars`, OAuth JSONs) and your actual life data lives in a **separate private repo** (see `vault-template/`). Guardrails: `.gitignore`, a gitleaks pre-commit hook, a gitleaks CI workflow, and the checklist in `docs/public-repo.md`.

## Architecture

```
iPhone                          Mac laptop                       VPS "brain" (Hetzner, Terraform-managed)
──────                          ──────────                       ────────────────────────────────────────
Goose iOS app ◄── tunnel ─────────────────────────────────────►  goose serve --enable-scheduler (systemd)
ntfy app ◄────────────────────────────────────────────────────    ├─ sessions.db ─── THE shared history
Telegram gw (fallback) ◄──────────────────────────────────────    ├─ native scheduler ── THE automations
Pal Chat (backup) ─┐            Goose Desktop ◄─ remote ACP ─►    ├─ MCP: workspace-mcp, Todoist, search
Siri Shortcut ─────┤            OpenCode CLI (coding, local)      ├─ life-vault clone (private repo)
                   │            goose CLI (offline fallback)      └─ all state on LUKS-encrypted volume
                   └────────────────────────────────────────►┌──►  Zen API / Together API (HTTPS)
                                                             │
        Tailscale tailnet (WireGuard) — the ONLY path to the brain; zero public inbound ports
```

## Component map

| Surface | Role |
|---|---|
| **VPS "brain"** (Hetzner CX22-class, Ubuntu 24.04) | Runs `goose serve --enable-scheduler` under systemd. Owns the one shared chat history (`sessions.db`) and all scheduled automations. All state — sessions, secrets, OAuth tokens, life-vault clone — sits on a LUKS-encrypted volume at `/data`. Reachable only over Tailscale, TLS + shared-secret auth, zero public inbound ports. |
| **Goose** (hub agent, on the brain) | General-purpose agent under Linux Foundation / AAIF governance — explicitly "not just for code": research, writing, automation, personal admin. MCP-native extensions, built-in Memory, custom providers for Zen and Together, recipes + built-in cron scheduler. Pinned to stable 1.x (2.0 is in RC churn). |
| **Goose Desktop** (Mac) | Full desktop UI, attached to the brain as a remote client — same sessions as the phone. Also hosts the Scheduler UI (pause / run-now / per-run history). |
| **goose CLI** (Mac) | Local offline fallback hub when the brain is unreachable. |
| **OpenCode CLI** (Mac) | The daily coding driver — a dedicated open-source coding agent with first-party Zen integration (`/connect`), per-agent cheap-model routing, and the same MCP servers. Runs locally; coding sessions don't need the brain. |
| **Goose iOS app** | Primary phone surface: thin remote client tunneling to the brain (experimental; fallback chain documented in `docs/setup/40-phone-setup.md`). |
| **Pal Chat** (iPhone) | BYOK backup chat straight to Together — works even if the brain is down. Backup precisely because its history is device-local. |
| **ntfy** | Push notifications from automations (topic name is a secret; sensitive jobs push counts/titles only, never PHI). |
| **Telegram gateway** | Fallback phone channel, startable on the brain. |
| **Siri Shortcut** | Voice one-shots from the phone. |
| **Tailscale** | WireGuard mesh — the only network path to the brain. |
| **OpenCode Zen** | At-cost pay-as-you-go inference gateway, one key, per-family wire formats. Zero-retention/no-training on its hosted open models; caveats per tier in `docs/privacy.md`. |
| **Together AI** | OpenAI-compatible inference over 200+ open models. ZDR by default, no training without opt-in, SOC 2, HIPAA/BAA posture — the sensitive (health/finance) tier lives here exclusively. |

## Repo map

```
.
├── README.md                           # you are here
├── .gitignore                          # keeps secrets, tfstate/tfvars, OAuth tokens out of a public repo
├── .pre-commit-config.yaml             # gitleaks secret scan before every commit
├── .github/workflows/secret-scan.yml   # gitleaks CI over full history on every push/PR
├── docs/
│   ├── setup/
│   │   ├── 00-overview.md              # START HERE — phases, milestones, budget
│   │   ├── 10-accounts.md              # Zen (auto-reload OFF!), Together, Tailscale, Todoist, Hetzner, ntfy
│   │   ├── 20-mac-setup.md             # Mac bootstrap: Goose Desktop+CLI, OpenCode, Keychain secrets
│   │   ├── 30-google-oauth.md          # own GCP OAuth app for Gmail/Calendar MCP (7-day token trap)
│   │   ├── 40-phone-setup.md           # Goose iOS pairing + fallback chain, ntfy, Pal Chat, Siri
│   │   ├── 50-vps-brain.md             # terraform apply → LUKS → deploy → schedules → reboot drill
│   │   └── 60-vault-setup.md           # create the PRIVATE life-vault repo, ingest docs, clone to brain
│   ├── model-routing.md                # which model for which job + hard privacy rules
│   ├── privacy.md                      # data classification per provider tier; encryption model & residual risk
│   ├── automations.md                  # add/manage scheduled workflows; scheduler-bug fallback flip
│   ├── security.md                     # threat model, LUKS design, Tailscale-only exposure, serve TLS/secret
│   ├── public-repo.md                  # what may/may-not be committed; go-public checklist
│   ├── troubleshooting.md              # base_url 404s, scheduler bugs, pairing, LUKS, rate limits
│   └── roadmap.md                      # SearXNG, memory, budgeting-app API, vault RAG
├── infra/terraform/
│   ├── main.tf                         # Hetzner server, SSH key, deny-all firewall, volume, cloud-init
│   ├── variables.tf                    # tokens/keys as sensitive variables (values live in tfvars)
│   ├── outputs.tf                      # bootstrap IP, volume id
│   ├── terraform.tfvars.example        # placeholders — copy to terraform.tfvars (gitignored)
│   └── templates/cloud-init.yaml.tftpl # first boot: agent user, ufw, tailscale up, tooling, goose CLI
├── config/
│   ├── goose/
│   │   ├── config.yaml                 # goose settings + MCP extensions (developer, memory, workspace, Todoist, playwright)
│   │   ├── custom_providers/
│   │   │   ├── zen-openai.json         # Zen /chat/completions: minimax-m2.7, kimi-k2.6, glm-5.1, deepseek-v4-flash
│   │   │   ├── zen-anthropic.json      # Zen /messages: claude-sonnet-5, claude-haiku-4-5, qwen3.7-plus
│   │   │   └── together.json           # Together: gpt-oss-120b, Qwen3.5-397B, DeepSeek V4 Flash (sensitive tier)
│   │   └── goosehints.example          # identity, routing rules, vault path, PHI standing rules
│   ├── opencode/opencode.json          # OpenCode: Zen models + Together provider, cheap small_model
│   ├── mcp/workspace-mcp.env.example   # Google Workspace MCP env template
│   └── env/secrets.env.example         # every secret VAR NAME (no values) — copy to /data/secrets.env
├── recipes/                            # automations, registered on the brain's native scheduler
│   ├── morning-brief.yaml              # daily 07:00 digest → ntfy
│   ├── inbox-triage.yaml               # 3×/weekday: Gmail labels + drafts, NEVER auto-send
│   ├── weekly-review.yaml              # Sunday 17:00 review, emailed to self
│   ├── health-followups.yaml           # Sunday 18:30, Together-only, PHI-free push (counts only)
│   ├── vault-qa.yaml                   # on-demand sensitive doc Q&A (Together, long-context)
│   └── budget-checkin.yaml             # monthly vs budget.md — ships paused
├── scripts/
│   ├── mac/
│   │   ├── bootstrap-mac.sh            # brew installs (pinned), config templates, Keychain prompts
│   │   └── keychain-secrets.sh         # store/read API keys in the macOS Keychain
│   ├── vps/
│   │   ├── deploy-vps.sh               # on the brain: copy configs, symlink state dirs to /data, install units, register schedules
│   │   ├── luks-setup.sh               # one-time: luksFormat the volume, mount /data
│   │   ├── luks-unlock.sh              # after (rare) reboots: unlock /data, start the stack
│   │   ├── register-schedules.sh       # idempotent `goose schedule add` per recipe
│   │   └── systemd/
│   │       ├── goose-serve.service     # the always-on brain unit (EnvironmentFile, tailnet-bound, TLS)
│   │       └── fallback/               # DISABLED systemd-timer units if the native scheduler bites
│   ├── common/
│   │   ├── run-recipe.sh               # headless runner + failure watchdog (one retry, alert on failure)
│   │   └── notify.sh                   # push via ntfy
│   └── verify/
│       ├── check-providers.sh          # curl every inference endpoint with your keys
│       ├── check-goose.sh              # goose smoke test per provider (settles base_url semantics)
│       ├── check-mcp.sh                # Gmail / Todoist / Playwright smoke test
│       ├── check-brain.sh              # serve status, cross-device history, run-now, pairing
│       ├── check-security.sh           # public port scan, LUKS state, gitleaks
│       └── pin-models.sh               # detect model-catalog drift vs pinned IDs (run monthly)
└── vault-template/                     # skeleton for the SEPARATE PRIVATE vault repo — no real data here
    ├── health/                         # records/, insurance/, billing/, appointments.md
    ├── finance/                        # ledger.csv, budget.md
    └── admin/                          # reference.md
```

## Start here

**[`docs/setup/00-overview.md`](docs/setup/00-overview.md)** walks the whole build in five phases: (1) day-1 minimal viable on the Mac + Pal Chat, (2) admin plumbing (Tailscale, Google OAuth, Todoist), (3) stand up the brain — the milestone is the same chat history on Desktop and iPhone plus an automatic morning brief, (4) sensitive tier + private vault, (5) go public + roadmap. Each phase ends with a verify script; don't skip them — they settle exactly the things most likely to be broken.

## Principles

1. **One brain, one history.** The hub agent runs only on the VPS; its `sessions.db` is the single chat history. Every device — Desktop, iPhone, CLI — is a client to the same brain, so a conversation started anywhere continues everywhere.
2. **Native Goose automations.** Scheduled work is Goose recipes registered on Goose's built-in scheduler (`goose schedule add`), manageable from Desktop's Scheduler UI — not bare cron. Each scheduled recipe delivers its own result as an explicit final `scripts/common/notify.sh` step; `scripts/common/run-recipe.sh` acts as a failure watchdog (one retry, then a high-priority alert) for manual and fallback-timer runs. Disabled systemd-timer fallbacks ship in-repo in case of scheduler bugs.
3. **Privacy tiers.** Every job class is pinned to a provider tier (`docs/model-routing.md`, `docs/privacy.md`). Health and finance data go to Together AI only (ZDR/HIPAA posture). Zen free models never see personal data. Claude/GPT via Zen never see health/finance data. Push notifications never contain PHI.
4. **Everything as code.** Infrastructure is Terraform, configs are templates, host state is scripts + systemd units, and every manual step is a runbook. A dead laptop or dead VPS is an inconvenience, not a loss.
5. **Public-repo hygiene.** Safe by construction: only placeholders are committed; secrets are injected from untracked files; gitleaks runs at commit time and in CI over full history; `docs/public-repo.md` gates the flip to public.

## Budget

All figures verified as of 2026-08-20 — re-verify at signup (`scripts/verify/pin-models.sh` catches model/price drift monthly).

| Item | ~Cost |
|---|---|
| Hetzner CX22-class VPS + encrypted volume | ~€5–7/mo |
| OpenCode Zen inference (PAYG — **disable auto-reload, set a cap**) | ~$5–20/mo typical |
| Together AI inference (min $5 top-up; sensitive tier + backups) | ~$5–10/mo |
| Tailscale (personal plan), ntfy public topic, Todoist free tier | $0 |
| Pal Chat (backup phone client) | ~$7 one-time |
| **Total** | **~$15–35/mo** — comfortably inside the $50/mo budget |

Daily-driver routing keeps costs predictable: scheduled automations run on `minimax-m2.7` ($0.30/$1.20 per 1M tokens), daily coding on `kimi-k2.6` ($0.95/$4.00), escalating to `claude-sonnet-5` ($2/$10) only when needed; the sensitive tier on Together tops out at `Qwen3.5-397B` ($0.60/$3.60). Full table with hard rules: [`docs/model-routing.md`](docs/model-routing.md).
