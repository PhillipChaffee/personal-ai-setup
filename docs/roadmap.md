# Roadmap

Later milestones, in rough priority order. None of these blocks daily use — the
stack in `docs/setup/00-overview.md` is complete without them. Each entry says
what it replaces and what triggers doing it. Project facts verified as of
2026-08-20; re-check the linked repos before starting any of these.

## Self-hosted search: SearXNG on the VPS + mcp-searxng

Today web search runs on Tavily's free tier (1,000 credits/mo) or Exa's
unauthenticated tier (150 calls/day) — fine for briefs and occasional research,
but metered, key-gated, and a third party sees every query. The upgrade is a
[SearXNG](https://github.com/searxng/searxng) container on the brain (it
aggregates 70+ engines, holds no account, keeps no logs under your control) with
[ihor-sokoliuk/mcp-searxng](https://github.com/ihor-sokoliuk/mcp-searxng) wired
into Goose as a stdio extension pointing at `http://127.0.0.1:8080`. Result:
unlimited, keyless, private search for every interactive session, and
`TAVILY_API_KEY` can be deleted from `secrets.env`. Do it when you start hitting
the free-tier ceilings — the container is one compose file on the VPS and the
extension swap is one block in `config/goose/config.yaml`. Bind SearXNG to
localhost only (the brain's zero-public-inbound rule applies; see
`docs/security.md`).

## Basic Memory (local-first knowledge graph)

Goose's built-in Memory extension loads **every** saved memory into **every**
prompt — cost grows linearly with what the agent knows about you, and on paid
inference that's a per-request tax.
[basicmachines-co/basic-memory](https://github.com/basicmachines-co/basic-memory)
(AGPL, ~3.3k stars, actively maintained) replaces that with a local-first
markdown knowledge graph: plain files with wikilinks and observations, semantic
and hybrid search, retrieval on demand instead of blanket injection. Because it
operates over ordinary markdown, it can sit directly on a directory you keep on
the encrypted `/data` volume — the agent's long-term memory becomes reviewable,
git-versioned files like everything else in the stack. Do it
when the Memory extension's contents stop fitting in a screenful, or when you
notice memory tokens dominating small requests.

## Pick a todo app (none wired in yet)

No task manager is part of the stack yet — the `todoist` extension in
`config/goose/config.yaml` ships `enabled: false` as a worked example, and
nothing depends on tasks.
Criteria when choosing: a real API or first-party MCP server (Todoist has
`https://ai.todoist.net/mcp` with one typed personal API token — still the
lowest-friction option), export path, and no-training data posture. To adopt
one: flip the extension on (or swap its `uri`) and re-run
`scripts/verify/check-mcp.sh`.

## Budgeting app with a real API

Finance tracking is deliberately not built in — the automations pivot removed
the ledger/CSV flow with everything else it scheduled (2026-09-23), and any
restart of it is a fresh decision. The bar a budgeting integration must clear:
**(1) official, documented API** the agent can
read without scraping; **(2) full data export** so leaving is always possible
(no lock-in); **(3) a no-training / no-data-sale policy** compatible with the
finance tier in `docs/privacy.md`. Candidates: **YNAB** (mature official REST
API, strong export), **Actual Budget** (open source, self-hostable on this same
VPS — the best privacy fit if its API surface covers what you need),
and **Lunch Money** (developer-friendly API, indie, US-centric). Once picked:
add its key to `secrets.env`, write a connector manifest against the registry
contract, and add its privacy.md row before the first session touches it.

## RAG with Together embeddings

Stuffing whole documents into DeepSeek V4 Flash's 1M
context — the simple approach this setup used before the pivot — re-reads
everything on every question. When your long-document corpus outgrows that
(hundreds of documents, or answers start missing things), add retrieval: embed
the corpus with Together's
**M2-BERT-80M-32K** retrieval model (~$0.01 per 1M tokens), store vectors in SQLite/sqlite-vec on `/data` (encrypted
at rest like everything else), and retrieve top-k chunks before
answering. Embeddings stay inside the Together privacy tier, so no new
provider-classification work is needed (`docs/privacy.md` already covers it).
This pairs naturally with Basic Memory above — same files, two access paths
(graph traversal and vector similarity).

## Non-Google email/calendar providers (Outlook, Fastmail/IMAP, Proton)

No provider is wired in today; the "whole communication surface" goal still has
other providers on it — Outlook /
Microsoft 365 via an MS Graph MCP server, Fastmail-style hosts via generic
IMAP/SMTP + CalDAV servers, Proton via Bridge. The doorway is already built:
[providers.md](providers.md) fixes the vetting bar, the extension/env naming
conventions, the per-provider roster
pattern. What remains per provider is picking a server that clears
the bar, a privacy.md policy row, a `docs/setup/3x-<provider>.md` runbook,
and a check-mcp smoke test. Trigger: the day a real second provider joins
your life (a work M365 tenant, a Fastmail migration) — not before.
