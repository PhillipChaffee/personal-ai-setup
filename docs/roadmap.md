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
unlimited, keyless, private search for every recipe and interactive session, and
`TAVILY_API_KEY` can be deleted from `secrets.env`. Do it when you start hitting
the free-tier ceilings — the container is one compose file on the VPS and the
extension swap is one block in `config/goose/config.yaml`. Bind SearXNG to
localhost only (the brain's zero-public-inbound rule applies; see
`docs/security.md`).

## Basic Memory over the vault

Goose's built-in Memory extension loads **every** saved memory into **every**
prompt — cost grows linearly with what the agent knows about you, and on paid
inference that's a per-request tax.
[basicmachines-co/basic-memory](https://github.com/basicmachines-co/basic-memory)
(AGPL, ~3.3k stars, actively maintained) replaces that with a local-first
markdown knowledge graph: plain files with wikilinks and observations, semantic
and hybrid search, retrieval on demand instead of blanket injection. Because it
operates over ordinary markdown, it can sit directly on top of (or alongside)
the life-vault clone at `/data/life-vault` — the agent's long-term memory and
your canonical records become the same reviewable, git-versioned files. Do it
when the Memory extension's contents stop fitting in a screenful, or when you
notice memory tokens dominating small requests. Migration is low-risk: keep the
built-in extension for standing preferences, move facts/notes into the vault.

## Budgeting app with a real API (replace the ledger.csv flow)

Phase 4 starts finance tracking deliberately simple: `finance/ledger.csv` +
`budget.md` in the private vault, with the monthly `budget-checkin` recipe
reading them. The upgrade is a proper budgeting app the agent can query.
Selection criteria, in order: **(1) official, documented API** the agent can
read without scraping; **(2) full data export** so leaving is always possible
(no lock-in); **(3) a no-training / no-data-sale policy** compatible with the
finance tier in `docs/privacy.md`. Candidates: **YNAB** (mature official REST
API, strong export), **Actual Budget** (open source, self-hostable on this same
VPS — the best privacy fit if its API surface covers what the recipes need),
and **Lunch Money** (developer-friendly API, indie, US-centric). Once picked:
add its key to `secrets.env`, point `budget-checkin.yaml` at the API instead of
`ledger.csv`, and keep the CSV as an export target rather than the source of
truth. Trigger: the first month manual CSV upkeep gets skipped is the sign the
flow needs to be automatic.

## Vault RAG with Together embeddings

`vault-qa` currently answers by stuffing documents into DeepSeek V4 Flash's 1M
context — simple and surprisingly durable, but it re-reads everything on every
question. When the vault outgrows that (hundreds of documents, or answers start
missing things), add retrieval: embed the vault with Together's
**M2-BERT-80M-32K** retrieval model (~$0.01 per 1M tokens — embedding the whole
vault costs pennies), store vectors in SQLite/sqlite-vec on `/data` (encrypted
at rest like everything else), and have `vault-qa` retrieve top-k chunks before
answering. Embeddings stay inside the Together privacy tier, so no new
provider-classification work is needed (`docs/privacy.md` already covers it).
This pairs naturally with Basic Memory above — same files, two access paths
(graph traversal and vector similarity).

## Watch the goose mobile roadmap (remote ACP + push)

The iOS pairing fallback chain in `docs/setup/40-phone-setup.md` exists because
mobile access is experimental and the documented pairing path assumes Goose
Desktop, not a headless brain. Upstream's stated direction is **HTTP/remote
Agent Client Protocol plus push messaging for long-running work**
([mobile-access docs](https://github.com/aaif-goose/goose/blob/main/documentation/docs/experimental/remote-access/mobile-access.md),
[announcement](https://aaif-goose.github.io/goose/blog/2026/01/20/goose-mobile-apps/)).
If that ships, the phone connects to `goose serve` the same way Desktop does —
no tunnel, no Cloudflare relay (removing the caveat in `docs/privacy.md`), and
native push could replace ntfy for run notifications. Nothing to build now:
check the goose release notes when running the monthly `pin-models.sh` pass,
and simplify `40-phone-setup.md` the release it lands.

## Optional: self-hosted ntfy

The public ntfy.sh server sees your notification traffic and rate-limits
topics; the topic name is the only secret. Self-hosting ntfy on the brain
(binary or container, behind Tailscale) keeps notification **content** entirely
on your infrastructure and removes rate limits. One honest caveat from the ntfy
docs: **instant** iOS delivery still requires forwarding poll requests through
the central ntfy.sh server because of iOS background restrictions — so
self-hosting improves content privacy but doesn't fully cut the third party out
on iOS. Since the PHI-free push rule (`docs/privacy.md`) already guarantees
nothing sensitive transits ntfy.sh, this is a nice-to-have, not a gap. Do it if
notification volume grows, or fold it in when goose-native push (previous item)
makes ntfy optional anyway.
