# personal-ai-setup

[![Coverage Status](https://coveralls.io/repos/github/PhillipChaffee/personal-ai-setup/badge.svg?branch=main)](https://coveralls.io/github/PhillipChaffee/personal-ai-setup?branch=main)
[![python-lint](https://github.com/PhillipChaffee/personal-ai-setup/actions/workflows/python-lint.yml/badge.svg)](https://github.com/PhillipChaffee/personal-ai-setup/actions/workflows/python-lint.yml)
[![secret-scan](https://github.com/PhillipChaffee/personal-ai-setup/actions/workflows/secret-scan.yml/badge.svg)](https://github.com/PhillipChaffee/personal-ai-setup/actions/workflows/secret-scan.yml)

Build your own personal AI — one agent with one memory, available on your phone and laptop, running your automations around the clock — out of open-source parts and pay-as-you-go inference. No hosted-assistant subscriptions, no lock-in, and your sensitive data only ever reaches zero-data-retention endpoints.

This repo is the complete, reproducible blueprint: Terraform for the server, config templates for every component, ready-made automations, a verify script for every piece that has one, and step-by-step runbooks. It is an installer with a menu rather than a ceremony — one command gets you a working AI on the Mac, and everything past that is an add-on you pick off the list below. Running cost, all in: **~$15–35/month**.

**What you get:**

- **One AI, one history.** A [Goose](https://github.com/aaif-goose/goose) agent (the "brain") runs 24/7 on a small hardened VPS. Your laptop and phone are thin clients to it — start a conversation anywhere, continue it everywhere. (The phone app is experimental; a fallback chain is documented.)
- **Automations that just happen.** A morning brief in your inbox at 7:00, inbox triage that labels and drafts (never sends to anyone but you), a Sunday weekly review — all Goose recipes on its native scheduler, managed from a UI, each emailing you its own result (failures alert separately via [ntfy](https://ntfy.sh)'s email gateway).
- **A serious coding agent.** [OpenCode](https://github.com/anomalyco/opencode) on your laptop, wired to the same inference accounts — plus **code agents on the brain**: Claude Code-style autonomous coding chats, each in its own container, kicked off and reviewed from your phone ([`docs/code-agents.md`](docs/code-agents.md)).
- **A private tier for life admin.** Email, calendar, and todos via MCP; health records and budget Q&A behind hard privacy rules — that data only ever reaches [Together AI](https://docs.together.ai) (zero-data-retention default, SOC 2, HIPAA posture), never free models, never providers that retain.
- **Cheap, flexible inference.** [OpenCode Zen](https://opencode.ai/docs/zen) (at-cost gateway: Kimi, GLM, MiniMax, DeepSeek, Claude…) plus Together AI (200+ open models). Broad model catalogs ship in the configs; `scripts/sync-models.sh` refreshes them from the live catalogs. Swap any of it — that's the point.

## Install

You need a Mac, an iPhone, a terminal and a handful of pay-as-you-go accounts;
the full list is in [Before you start](#before-you-start). Then:

```bash
git clone https://github.com/PhillipChaffee/personal-ai-setup.git
cd personal-ai-setup
./scripts/mac/bootstrap-mac.sh
```

That is the base install, and it **runs start to finish without asking you
anything**. It puts the goose CLI and Desktop, OpenCode, the toolchain and the
skills/agents/rules onto the Mac at the versions pinned in `config/pins.yaml`,
never overwriting a file you already have. Re-running it is safe.

Want a subset? The flags resolve against the same `config/units/*.yaml` catalog
the menu below is generated from:

```bash
./scripts/mac/bootstrap-mac.sh --dry-run              # print the plan, touch nothing
./scripts/mac/bootstrap-mac.sh --only base-goose      # that unit plus what it requires
./scripts/mac/bootstrap-mac.sh --without coding-pack  # everything except that one
./scripts/mac/bootstrap-mac.sh --help                 # the units, in dependency order
```

Excluding a unit that something else still needs is refused with exit 2, rather
than half-installed.

**Two things after the bootstrap are interactive on purpose.** Both are
credentials or consent that no script may invent on your behalf:

- **Your API keys** — `scripts/mac/keychain-secrets.sh` prompts for each one
  silently, never echoes a value, and asks before it appends anything to
  `~/.zshrc`.
- **The Tailscale sign-in** — you sign the Mac into your own tailnet, from the
  app the bootstrap installed.

OpenCode's Zen credential is *not* a third one: the bootstrap writes
`~/.local/share/opencode/auth.json` itself, from `$OPENCODE_ZEN_API_KEY`. If the
first bullet above is where you set that key for the first time, then the
bootstrap ran before the key existed — open a new terminal and re-run either the
bootstrap or `scripts/mac/opencode-auth.sh` on its own.

**The brain is different: it cannot be made unattended, by design.** It has five
interactive points, and every one of them is key material this repo deliberately
stores nowhere. `terraform apply` prompts for the Hetzner token and the Tailscale
auth key on *every* run and keeps neither. `luks-setup.sh` makes you type
`FORMAT` in capitals, then takes the volume passphrase twice. And
`luks-unlock.sh` asks for that passphrase again after every reboot, because the
crypttab entry is written `noauto` on purpose — the key to the disk is never on
the disk. Anything that promised you a one-command brain would be promising to
store that passphrase somewhere.

Once something is installed, four read-only commands tell you where you stand:

```bash
bin/pai list      # what the repo ships
bin/pai status    # what is installed on this machine
bin/pai doctor    # what drifted between this machine and the repo's templates
bin/pai verify    # run the checks the manifests claim: one table, one exit code
```

Everything personal stays out of your clone — see
[Adapting it to you](#adapting-it-to-you).

## Add-ons

Everything past the base is a unit in `config/units/`, and the table below is
rendered from those manifests. **Verified by** is deliberately empty wherever
nothing proves a unit yet: this repo would rather show you the gap than describe
one that is not there. `bin/pai list` prints the same catalog on your machine.

<!-- GENERATED — do not edit between the markers; `bin/pai docs --write`
     re-renders this and CI fails when it is stale. The rows, and their order,
     come entirely from config/units/*.yaml: adding a manifest adds a row here
     and nothing else has to be touched. -->
<!-- pai-docs:begin units-menu -->

| Add-on | Tier | Host | What it is | Installed by | Verified by |
|---|---|---|---|---|---|
| [base-goose](docs/setup/20-mac-setup.md) | base | mac | Pinned goose CLI and Desktop cask, four custom providers, config template. | `bootstrap-mac.sh` | `check-goose.sh`, `check-providers.sh` |
| [base-secrets](docs/setup/20-mac-setup.md) | base | both | Keychain roster on the Mac, /data/secrets.env on the brain, and the deploy gate. | by hand | — |
| [base-skills](docs/setup/20-mac-setup.md) | base | mac | The connect-service skill, copied into ~/.agents/skills where goose and OpenCode both read it. | `bootstrap-mac.sh` | — |
| [base-toolchain](docs/setup/20-mac-setup.md) | base | mac | macOS guard, Homebrew presence check, and the uv/node/jq formulae. | `bootstrap-mac.sh` | — |
| [coding-pack](docs/cursor-port.md) | default_on | mac | Eleven ported Cursor skills, 30 OpenCode subagents, and the global AGENTS.md rule set. | `bootstrap-mac.sh` | — |
| [goose-desktop](docs/setup/20-mac-setup.md) | default_on | mac | Human-only, turn OFF Desktop auto-update and pick the custom providers on first run. | by hand | — |
| [opencode](docs/setup/20-mac-setup.md) | default_on | mac | The OpenCode CLI from anomalyco/tap, ~/.config/opencode/opencode.json, and the Zen credential the bootstrap writes. | `bootstrap-mac.sh` | `check-opencode.sh` |
| [automations](docs/automations.md) | opt_in | vps | The three non-vault recipes, register-schedules.sh, and the disabled fallback timers. | `deploy-vps.sh` | — |
| [brain](docs/setup/50-vps-brain.md) | opt_in | vps | Hetzner VPS, LUKS /data, goose's path root on it, and goose-serve over tailnet TLS. | `deploy-vps.sh` (planned) | `check-brain.sh`, `check-security.sh --local` |
| [code-agents](docs/setup/70-code-agents.md) | opt_in | vps | Rootless podman, the code-agent image, and the per-chat session manager. | `deploy-vps.sh` | `check-code-agents.sh` |
| [connectors](docs/connecting.md) | opt_in | both | The connector vetting registry and the three disabled extension fragments. | by hand | `check-connectors.sh` |
| [google-workspace](docs/setup/30-google-oauth.md) | opt_in | both | workspace-mcp extension for Gmail/Calendar/Tasks, and its OAuth tokens on /data. | `deploy-vps.sh` | `check-mcp.sh` |
| [life-vault](docs/setup/60-vault-setup.md) | opt_in | vps | The private vault repo cloned to /data/life-vault, its template, and vault-qa. | by hand | — |
| [ntfy-alerts](docs/automations.md) | opt_in | both | notify.sh and the ntfy topic that carries automation failure alerts. | by hand | — |
| [phone-kit](docs/setup/40-phone-setup.md) | opt_in | checklist | iPhone surfaces - Telegram pairing, Tailscale, Pal Chat, a Siri Shortcut. | by hand | — |
| [tailnet](docs/setup/10-accounts.md) | opt_in | both | Human-only, the Tailscale account, the client sign-ins, and the MagicDNS + HTTPS-cert toggles. | by hand | — |
| [telegram-gateway](docs/setup/40-phone-setup.md) | opt_in | vps | goose's Telegram gateway on the brain, a selectable unit enabled only with a token. | `deploy-vps.sh` | — |
| [vault-automations](docs/setup/60-vault-setup.md) | opt_in | vps | health-followups and budget-checkin, gated on the vault files they read. | `deploy-vps.sh` (planned) | — |

<!-- pai-docs:end units-menu -->

`(planned)` means the manifest names an installer function that does not exist
yet — the unit is real and its runbook works, but today you install it by hand.
`by hand` means the manifest names no installer at all: sometimes because nothing
*could* (an App Store download, a browser toggle, a key you type), sometimes
because nothing does yet. Each manifest says which, and `check-units.sh` fails
if one of them stops saying it.

## Before you start

| You need | Notes |
|---|---|
| A Mac + an iPhone | The runbooks are written for this pair. **The brain itself is Linux** (Ubuntu 24.04) — goose is not the Mac-only part. What *is* Mac-only is the laptop's secret store (macOS Keychain) and Homebrew; a Linux laptop needs a keyring backend that does not exist here yet. Android likewise substitutes steps. Component-by-component table: [`docs/setup/00-overview.md`](docs/setup/00-overview.md#supported-platforms). |
| Comfort with a terminal | You'll run scripts, `terraform apply`, and paste commands over SSH. Every step is written out; no improvisation required. |
| ~$15–35/month | Breakdown in [Budget](#budget). The two inference accounts are pay-as-you-go with hard caps. |
| Accounts you'll create | OpenCode Zen, Together AI, Hetzner (VPS), Tailscale, a Google Cloud OAuth app for your own Gmail/Calendar (a todo app like Todoist is optional). Each has a runbook with the gotchas called out. |

## Architecture

```text
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
| **OpenCode CLI** (Mac) | The daily coding driver — dedicated open-source coding agent with first-party Zen integration (the credential the bootstrap writes), per-agent cheap-model routing, and the same MCP servers. Runs locally; coding sessions don't need the brain. |
| **Code agents** (on the brain) | Claude Code-style autonomous coding chats: one container per chat (idle chats spin down, volumes persist), live streaming + permission asks to your devices, any model per chat, PRs as the deliverable. Managed by `code-agent-manager` behind the tailnet on port 4300. See [`docs/code-agents.md`](docs/code-agents.md). |
| **Goose iOS app** | Primary phone surface: thin remote client tunneling to the brain (experimental; fallback chain documented in `docs/setup/40-phone-setup.md`). |
| **Pal Chat** (iPhone) | BYOK backup chat straight to Together — works even if the brain is down. Backup precisely because its history is device-local. |
| **ntfy / Telegram / Siri Shortcut** | Failure-alert channel (topic publish forwarded to your email via ntfy's gateway — no app to install); fallback phone channel; voice one-shots. |
| **Tailscale** | WireGuard mesh — the only network path to the brain. |
| **OpenCode Zen** | At-cost pay-as-you-go inference gateway, one key, per-family wire formats. Zero-retention/no-training on its hosted open models; caveats per tier in `docs/privacy.md`. |
| **Together AI** | OpenAI-compatible inference over 200+ open models. ZDR by default, no training without opt-in, SOC 2, HIPAA/BAA posture — the sensitive (health/finance) tier lives here exclusively. |

## Repo map

<!-- GENERATED — do not edit between the markers; `bin/pai docs --write`
     re-renders this. The SHAPE (which paths appear, in which order, carrying
     which note) is MAP_ENTRIES in scripts/verify/docs_lint.py: hand-written,
     ordered, and reviewed like prose. Every COUNT comes from the filesystem on
     each render, so no number here can drift — that is what this whole gate is
     for. The hand-written half is held honest by two assertions: an annotated
     path that stops existing fails, and so does a new directory that no line
     here covers. -->
<!-- pai-docs:begin repo-map -->

```text
.
├── README.md                          # you are here: install, the add-on menu, the budget
├── LICENSE                            # MIT
├── bin/pai                            # the one entry point: doctor, status, list, units, verify, docs
├── .gitignore                         # keeps secrets, tfstate/tfvars, OAuth tokens out of a public repo
├── .pre-commit-config.yaml            # gitleaks, ruff, yamllint, shellcheck before every commit
├── .github/workflows/                 # the CI gates: secret scan, lint, types, coverage, install tests
├── .coveragerc                        # coverage scope and the project floor
├── .markdownlint-cli2.jsonc           # markdownlint config
├── lychee.toml                        # the offline link and anchor checker's config
├── mypy.ini                           # the --strict roster; every tracked .py is on it
├── ruff.toml                          # ruff with every rule on; exceptions justified in place
├── package.json                       # markdownlint-cli2 only, pinned by package-lock.json
├── docs/
│   ├── index.md                       # the GitHub Pages landing page (LOAD-BEARING EXTERNALLY)
│   ├── app-privacy-policy.md          # the URL on the Google OAuth consent screen (LOAD-BEARING EXTERNALLY)
│   ├── _config.yml                    # Jekyll config for those two pages
│   ├── setup/                         # 8 runbooks, in order; START at 00-overview.md
│   ├── connecting.md                  # adding a connector, end to end
│   ├── model-routing.md               # which model for which job + hard privacy rules
│   ├── privacy.md                     # data classification per provider tier; encryption model and residual risk
│   ├── automations.md                 # add/manage scheduled workflows; scheduler-bug fallback flip
│   ├── code-agents.md                 # code agents: per-chat containers, lifecycle, git/permission model
│   ├── providers.md                   # email/calendar provider convention (multi-account today, more next)
│   ├── cursor-port.md                 # the Cursor kit ported to Goose + OpenCode: what went where and why
│   ├── security.md                    # threat model, LUKS design, Tailscale-only exposure, serve TLS/secret
│   ├── public-repo.md                 # what may/may-not be committed; go-public checklist
│   ├── troubleshooting.md             # base_url 404s, scheduler bugs, pairing, LUKS, rate limits
│   └── roadmap.md                     # SearXNG, memory, budgeting-app API, vault RAG
├── infra/terraform/                   # Hetzner server, deny-all firewall, encrypted volume, cloud-init
├── config/
│   ├── units/                         # 18 unit manifests — the add-on menu above is rendered from these
│   ├── pins.yaml                      # the versions the installers pin and the checks compare against
│   ├── goose/config.yaml              # GENERATED from config.base.yaml + extensions.d/
│   ├── goose/extensions.d/            # 4 MCP extension fragments, one file each
│   ├── goose/custom_providers/        # together (DEFAULT), zen-openai, zen-anthropic, zen-free (trains on data)
│   ├── goose/goosehints.example       # identity, routing rules, vault path, PHI standing rules
│   ├── goose/acp-contract.json        # the captured ACP method list check-connectors.sh asserts against
│   ├── opencode/opencode.json         # OpenCode: Zen models + Together provider, cheap small_model
│   ├── opencode/AGENTS.md             # global coding/workflow rules template
│   ├── opencode/agents/               # 30 review/research subagents
│   ├── opencode/project-rules/        # per-project rule snippets (python, django, linear…) — paste-in
│   ├── skills/                        # 12 skills, Claude-compatible SKILL.md (→ ~/.agents/skills) — read by BOTH OpenCode and goose
│   ├── connectors/                    # 5 connector manifests + the contract in that directory's README
│   ├── code-agents/                   # the code-agent image, per-chat opencode config, repo-allowlist template
│   ├── mcp/workspace-mcp.env.example  # Google Workspace MCP env template
│   └── env/secrets.env.example        # every secret VAR NAME (no values) — copy to /data/secrets.env
├── recipes/                           # 7 goose recipes; which of them are scheduled is docs/automations.md's table
├── scripts/
│   ├── pai/                           # the `pai` dispatcher, doctor, goosecfg
│   ├── mac/                           # bootstrap-mac.sh, keychain-secrets.sh
│   ├── vps/                           # deploy-vps.sh, LUKS setup/unlock, schedule registration, systemd units
│   ├── common/                        # run-recipe.sh (failure watchdog), notify.sh (alerts to ntfy's email gateway)
│   ├── sync-models.sh                 # refresh provider model lists from the live Zen/Together catalogs
│   └── verify/                        # 12 check-*.sh, plus the harnesses and the fakes they drive
└── vault-template/                    # skeleton for the SEPARATE PRIVATE vault repo — no real data here
```

<!-- pai-docs:end repo-map -->

## Adapting it to you

The repo is a template; your identity and choices live outside it or in a handful of obvious places:

- **Identity**: `config/goose/goosehints.example` has `<placeholders>` for your name/email/timezone; `infra/terraform/terraform.tfvars.example` for your SSH public key and region. Secrets go in your Keychain (Mac) and `/data/secrets.env` (brain) — never in the repo. The two Terraform secrets (Hetzner token, Tailscale auth key) are stored nowhere at all: Terraform prompts for them on each `plan`/`apply`.
- **Different VPS host**: everything host-specific is confined to `infra/terraform/`. Porting to DigitalOcean/Vultr means rewriting that one directory; nothing else cares.
- **Different models/providers**: providers are JSON files in `config/goose/custom_providers/`; the job→model routing (and the privacy rules that constrain it) is `docs/model-routing.md`. Any OpenAI- or Anthropic-compatible endpoint slots in.
- **Different apps**: Gmail/Calendar (and an optional todo app — a disabled Todoist entry ships as the worked example) are MCP servers declared in `config/goose/config.yaml` — swap for your own. The todo and budgeting choices are deliberately undecided (see `docs/roadmap.md`).
- **Your data**: real life data lives in a **separate private repo** you create from `vault-template/`. This repo stays publishable; that one never is.

## Principles

1. **One brain, one history.** The hub agent runs only on the VPS; its `sessions.db` is the single chat history. Every device — Desktop, iPhone, CLI — is a client to the same brain, so a conversation started anywhere continues everywhere. That is the invariant of the base install, and every add-on on the menu above preserves it. Exactly one add-on deliberately does not put its chats in `sessions.db`, and it explains itself in its own doc: [`docs/code-agents.md`](docs/code-agents.md#why-code-agent-chats-are-not-in-the-shared-history).
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
| Code agents on the brain (containers) | no new account — bills to the Zen/Together lines above, plus disk |
| Pal Chat (backup phone client) | ~$7 one-time |
| **Total** | **~$15–35/mo** |

Code agents are the one line that can move the total on their own: an autonomous coding chat consumes far more per session than a conversation, and several can run at once. They default to `opencode/deepseek-v4-flash` (cheap, big context) and refuse Zen's free models unless a repo is flagged `public_throwaway`; `opencode stats` inside a chat reports actual spend. They also consume **disk** — each chat gets its own volume under `/data/code-agents`, on the same 10 GB volume as everything else by default, so `check-code-agents.sh` fails once they occupy 75% of it. Grow `data_volume_size` (Hetzner volumes grow without recreation) or delete old chats; see [`docs/code-agents.md`](docs/code-agents.md).

Routing keeps costs predictable: scheduled automations run on `minimax-m2.7` ($0.30/$1.20 per 1M tokens), daily coding on `kimi-k2.6` ($0.95/$4.00), escalating to `claude-sonnet-5` ($2/$10) only when needed; the default hub and sensitive tier run on Together's `Qwen3.5-397B` ($0.60/$3.60). Full table with hard rules: [`docs/model-routing.md`](docs/model-routing.md).

## License

[MIT](LICENSE). Fork it, rebuild it, make it yours.
