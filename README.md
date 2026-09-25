# personal-ai-setup

[![Coverage Status](https://coveralls.io/repos/github/PhillipChaffee/personal-ai-setup/badge.svg?branch=main)](https://coveralls.io/github/PhillipChaffee/personal-ai-setup?branch=main)
[![python-lint](https://github.com/PhillipChaffee/personal-ai-setup/actions/workflows/python-lint.yml/badge.svg)](https://github.com/PhillipChaffee/personal-ai-setup/actions/workflows/python-lint.yml)
[![secret-scan](https://github.com/PhillipChaffee/personal-ai-setup/actions/workflows/secret-scan.yml/badge.svg)](https://github.com/PhillipChaffee/personal-ai-setup/actions/workflows/secret-scan.yml)

Build your own personal AI — one agent with one memory, available on your laptop and on a small always-on server — out of open-source parts and pay-as-you-go inference. No hosted-assistant subscriptions, no lock-in, and your sensitive data only ever reaches zero-data-retention endpoints.

This repo is the complete, reproducible blueprint: Terraform for the server, config templates for every component, a verify script for every piece that has one, and step-by-step runbooks. It is an installer with a menu rather than a ceremony — one command gets you a working AI on the Mac, and everything past that is an add-on you pick off the list below. Running cost, all in: **~$15–35/month**.

**What you get:**

- **One AI, one history.** A [Goose](https://github.com/aaif-goose/goose) agent (the "brain") runs 24/7 on a small hardened VPS. Your laptop is a thin client to it — start a conversation on the Mac, continue it on the brain.
- **A serious coding agent.** [OpenCode](https://github.com/anomalyco/opencode) and Pi first-class under [herdr](https://github.com/herdrdev/herdr) on the brain — real terminal panes, the agent set chosen at setup (Claude Code, Codex, Grok Build in the catalog) ([`docs/coding-agents.md`](docs/coding-agents.md)).
- **A private tier for life admin.** Email, calendar, and todos via MCP; a connector registry that records which services were vetted, adopted, or deliberately not. Your sensitive data only ever reaches [Together AI](https://docs.together.ai) (zero-data-retention default, SOC 2, HIPAA posture), never free models, never providers that retain.
- **Cheap, flexible inference.** [OpenCode Zen](https://opencode.ai/docs/zen) (at-cost gateway: Kimi, GLM, MiniMax, DeepSeek, Claude…) plus Together AI (200+ open models). Broad model catalogs ship in the configs; `scripts/sync-models.sh` refreshes them from the live catalogs. Swap any of it — that's the point.

## Install

You need a Mac, a terminal and a handful of pay-as-you-go accounts;
the full list is in [Before you start](#before-you-start). Then:

```bash
git clone https://github.com/PhillipChaffee/personal-ai-setup.git
cd personal-ai-setup
./scripts/wizard/setup.sh
```

The wizard is the front door. It asks six questions — scope (fresh end-to-end
or the existing brain), which coding agents live in herdr panes, Mac extras,
the provisioning/teardown confirmations, the keys it captures, verify — and
then drives both installers: `bootstrap-mac.sh` locally and `deploy-vps.sh`
over SSH on the brain. It writes exactly the keys it captures or generates
into `/data/secrets.env` over SSH, stores the Mac's copies in the Keychain,
and prints everything a human must do by hand (Tailscale toggles, the LUKS
passphrase, terraform's prompts, Desktop connect). Nothing it does is
scheduled. Stop it any time and re-run — it remembers saved values.

Prefer to drive the installers yourself? The bootstrap below is the same
base install, and it **runs start to finish without asking you
anything**. It puts the goose CLI and Desktop, the toolchain and the
skills onto the Mac at the versions pinned in `config/pins.yaml`,
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
| [base-toolchain](docs/setup/20-mac-setup.md) | base | mac | macOS guard, Homebrew presence check, and the uv/node/jq formulae. | `bootstrap-mac.sh` | — |
| [coding-pack](docs/cursor-port.md) | default_on | mac | Eleven ported Cursor skills; the ported OpenCode agents and AGENTS.md stay in the repo as paste-in material. | `bootstrap-mac.sh` | — |
| [goose-desktop](docs/setup/20-mac-setup.md) | default_on | mac | Human-only, turn OFF Desktop auto-update and pick the custom providers on first run. | by hand | — |
| [herdr](docs/setup/70-coding-agents.md) | default_on | vps | The herdr server, its dedicated user and namespace, the pinned binary, and the coding-agent catalog. | `deploy-vps.sh` | `check-herdr.sh` |
| [brain](docs/setup/50-vps-brain.md) | opt_in | vps | Hetzner VPS, LUKS /data, goose's path root on it, and goose-serve over tailnet TLS. | `deploy-vps.sh` (planned) | `check-brain.sh`, `check-security.sh --local` |
| [connectors](docs/connecting.md) | opt_in | both | The connector vetting registry and the three disabled extension fragments. | by hand | `check-connectors.sh`, `check-mcp.sh` |
| [tailnet](docs/setup/10-accounts.md) | opt_in | both | Human-only, the Tailscale account, the client sign-ins, and the MagicDNS + HTTPS-cert toggles. | by hand | — |

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
| A Mac | The runbooks are written for the Mac. **The brain itself is Linux** (Ubuntu 24.04) — goose is not the Mac-only part. What *is* Mac-only is the laptop's secret store (macOS Keychain) and Homebrew; a Linux laptop needs a keyring backend that does not exist here yet. Component-by-component table: [`docs/setup/00-overview.md`](docs/setup/00-overview.md#supported-platforms). |
| Comfort with a terminal | You'll run scripts, `terraform apply`, and paste commands over SSH. Every step is written out; no improvisation required. |
| ~$15–35/month | Breakdown in [Budget](#budget). The two inference accounts are pay-as-you-go with hard caps. |
| Accounts you'll create | OpenCode Zen, Together AI, Hetzner (VPS), Tailscale (a todo app like Todoist is optional). Each has a runbook with the gotchas called out. |

## Architecture

```text
Mac laptop                       VPS "brain" (Hetzner, Terraform-managed)
────────                         ────────────────────────────────────────
Goose Desktop ◄── remote ACP ─────────────────────────────────►  goose serve (systemd)
                                                                  ├─ sessions.db ─── THE shared history
herdr app ◄──── SSH ──────────►                                   ├─ MCP: Todoist, search
Goose CLI (offline fallback)                                      ├─ coding agents: herdr panes
                                                                  ├─ inference ──► Zen API / Together API (HTTPS)
                                                                  └─ all state on LUKS-encrypted volume

        Tailscale tailnet (WireGuard) — the ONLY path to the brain; zero public inbound ports
```

| Surface | Role |
|---|---|
| **VPS "brain"** (Hetzner cpx21-class, Ubuntu 24.04) | Runs `goose serve` under systemd. Owns the one shared chat history (`sessions.db`). All state — sessions, secrets — sits on a LUKS-encrypted volume at `/data`. Reachable only over Tailscale, TLS + shared-secret auth, zero public inbound ports. |
| **Goose** (hub agent, on the brain) | General-purpose agent under Linux Foundation / AAIF governance — explicitly "not just for code": research, writing, personal admin. MCP-native extensions, built-in Memory, custom providers for Zen and Together. Pinned to stable 1.x (2.0 is in RC churn). |
| **Goose Desktop** (Mac) | Full desktop UI, attached to the brain as a remote client over goose's Agent Client Protocol ("remote ACP" in the diagram). |
| **goose CLI** (Mac) | Local offline fallback hub when the brain is unreachable. |
| **Coding agents** (on the brain, herdr) | The coding-agent runtime: herdr manages the agent panes (OpenCode, Pi, and the setup-time catalog), the wizard wires the picked set, and the Mac attaches over SSH — no coding agent installs on the Mac. See [`docs/coding-agents.md`](docs/coding-agents.md). |
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
├── README.md                     # you are here: install, the add-on menu, the budget
├── AGENTS.md                     # how agents work in this repo: the tracker, the labels, the domain docs
├── CONTEXT.md                    # the domain glossary: one term, one meaning, everywhere
├── LICENSE                       # MIT
├── bin/pai                       # the one entry point: doctor, status, list, units, verify, docs
├── .gitignore                    # keeps secrets, tfstate/tfvars, OAuth tokens out of a public repo
├── .pre-commit-config.yaml       # gitleaks, ruff, yamllint, shellcheck before every commit
├── .github/workflows/            # the CI gates: secret scan, lint, types, coverage, install tests
├── .coveragerc                   # coverage scope and the project floor
├── .markdownlint-cli2.jsonc      # markdownlint config
├── lychee.toml                   # the offline link and anchor checker's config
├── mypy.ini                      # the --strict roster; every tracked .py is on it
├── ruff.toml                     # ruff with every rule on; exceptions justified in place
├── package.json                  # markdownlint + jscpd, pinned by package-lock.json
├── docs/
│   ├── index.md                  # the GitHub Pages landing page (LOAD-BEARING EXTERNALLY)
│   ├── app-privacy-policy.md     # the URL on the Google OAuth consent screen (LOAD-BEARING EXTERNALLY)
│   ├── _config.yml               # Jekyll config for those two pages
│   ├── setup/                    # 5 runbooks, in order; START at 00-overview.md
│   ├── agents/                   # 3 agent-skills config files: issue tracker, triage labels, domain-doc rules
│   ├── adr/                      # 1 decisions, numbered oldest first
│   ├── connecting.md             # adding a connector, end to end
│   ├── model-routing.md          # which model for which job + hard privacy rules
│   ├── privacy.md                # data classification per provider tier; encryption model and residual risk
│   ├── coding-agents.md          # coding agents: the herdr runtime, the setup-time catalog, isolation
│   ├── providers.md              # email/calendar provider convention (multi-account today, more next)
│   ├── cursor-port.md            # the Cursor kit ported to Goose + OpenCode: what went where and why
│   ├── security.md               # threat model, LUKS design, Tailscale-only exposure, serve TLS/secret
│   ├── public-repo.md            # what may/may-not be committed; go-public checklist
│   ├── troubleshooting.md        # base_url 404s, pairing, LUKS, rate limits
│   └── roadmap.md                # SearXNG, memory, budgeting-app API
├── infra/terraform/              # Hetzner server, deny-all firewall, encrypted volume, cloud-init
├── config/
│   ├── units/                    # 9 unit manifests — the add-on menu above is rendered from these
│   ├── pins.yaml                 # the versions the installers pin and the checks compare against
│   ├── goose/config.yaml         # GENERATED from config.base.yaml + extensions.d/
│   ├── goose/extensions.d/       # 3 MCP extension fragments, one file each
│   ├── goose/custom_providers/   # together (DEFAULT), zen-openai, zen-anthropic, zen-free (trains on data)
│   ├── goose/goosehints.example  # identity, routing rules, PHI standing rules
│   ├── goose/acp-contract.json   # the captured ACP method list check-connectors.sh asserts against
│   ├── opencode/AGENTS.md        # global coding/workflow rules — paste-in for a self-installed OpenCode
│   ├── opencode/agents/          # 30 review/research subagents — paste-in for a self-installed OpenCode
│   ├── opencode/project-rules/   # per-project rule snippets (python, django, linear…) — paste-in
│   ├── skills/                   # 11 skills, Claude-compatible SKILL.md (→ ~/.agents/skills) — read by BOTH OpenCode and goose
│   ├── connectors/               # 3 connector manifests + the contract in that directory's README
│   ├── herdr/config.toml         # the herdr server config template: six keys, every one explicit
│   └── env/secrets.env.example   # every secret VAR NAME (no values) — copy to /data/secrets.env
└── scripts/
    ├── pai/                      # the `pai` dispatcher, doctor, goosecfg
    ├── wizard/                   # the front door: six questions, then it drives both installers
    ├── mac/                      # bootstrap-mac.sh, keychain-secrets.sh
    ├── vps/                      # deploy-vps.sh, LUKS setup/unlock, systemd units
    ├── sync-models.sh            # refresh provider model lists from the live Zen/Together catalogs
    └── verify/                   # 11 check-*.sh, plus the harnesses and the fakes they drive
```

<!-- pai-docs:end repo-map -->

## Adapting it to you

The repo is a template; your identity and choices live outside it or in a handful of obvious places:

- **Identity**: `config/goose/goosehints.example` has `<placeholders>` for your name/email/timezone; `infra/terraform/terraform.tfvars.example` for your SSH public key and region. Secrets go in your Keychain (Mac) and `/data/secrets.env` (brain) — never in the repo. The two Terraform secrets (Hetzner token, Tailscale auth key) are stored nowhere at all: Terraform prompts for them on each `plan`/`apply`.
- **Different VPS host**: everything host-specific is confined to `infra/terraform/`. Porting to DigitalOcean/Vultr means rewriting that one directory; nothing else cares.
- **Different models/providers**: providers are JSON files in `config/goose/custom_providers/`; the job→model routing (and the privacy rules that constrain it) is `docs/model-routing.md`. Any OpenAI- or Anthropic-compatible endpoint slots in.
- **Different apps**: the shipped MCP extensions are Todoist (disabled by default), Tavily search, and Playwright — swap in your own. The todo choice is deliberately undecided (see `docs/roadmap.md`).

## Principles

1. **One brain, one history.** The hub agent runs only on the VPS; its `sessions.db` is the single chat history. Every device — Desktop, CLI — is a client to the same brain, so a conversation started anywhere continues everywhere. That is the invariant of the base install, and every add-on on the menu above preserves it. Exactly one add-on deliberately does not put its chats in `sessions.db`, and it explains itself in its own doc: [`docs/coding-agents.md`](docs/coding-agents.md#why-coding-agent-work-is-not-in-the-shared-history).
2. **Privacy tiers.** Every job class is pinned to a provider tier (`docs/model-routing.md`, `docs/privacy.md`). Health and finance data go to Together AI only (ZDR/HIPAA posture). Zen free models never see personal data. Claude/GPT via Zen never see health/finance data.
3. **Everything as code.** Infrastructure is Terraform, configs are templates, host state is scripts + systemd units, and every manual step is a runbook. A dead laptop or dead VPS is an inconvenience, not a loss.
4. **Public-repo hygiene.** Safe by construction: only placeholders are committed; secrets are injected from untracked files; gitleaks runs at commit time and in CI over full history; `docs/public-repo.md` gates the flip to public.

## Budget

All figures verified as of 2026-08-20 — re-verify at signup (`scripts/verify/pin-models.sh` catches model/price drift monthly).

| Item | ~Cost |
|---|---|
| Hetzner cpx21-class VPS + encrypted volume | ~€6–9/mo |
| OpenCode Zen inference (PAYG — **disable auto-reload, set a cap**) | ~$5–20/mo typical |
| Together AI inference (min $5 top-up; sensitive tier + default hub) | ~$5–10/mo |
| Tailscale (personal plan) | $0 |
| Coding agents on the brain (herdr panes) | no new account — bills to the Zen/Together lines above, plus disk |
| **Total** | **~$15–35/mo** |

Coding agents are the one line that can move the total on their own: an agent turn consumes far more per session than a conversation, and several can run at once; `opencode stats` inside a pane reports actual spend. They also consume **disk** — canonical clones and per-task worktrees live under `/data/herdr`, on the same 10 GB volume as everything else by default, so `check-herdr.sh` fails once they occupy 75% of it. Grow `data_volume_size` (Hetzner volumes grow without recreation) or clean old worktrees; see [`docs/coding-agents.md`](docs/coding-agents.md).

Routing keeps costs predictable: daily chat on `kimi-k2.6` ($0.95/$4.00 per 1M tokens), escalating to `claude-sonnet-5` ($2/$10) only when needed; the default hub and sensitive tier run on Together's `Qwen3.5-397B` ($0.60/$3.60). Full table with hard rules: [`docs/model-routing.md`](docs/model-routing.md).

## License

[MIT](LICENSE). Fork it, rebuild it, make it yours.
