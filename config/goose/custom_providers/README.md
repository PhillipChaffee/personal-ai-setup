# Goose custom providers

These JSON files define the four named providers the whole setup routes
through (`together` — the default, `zen-openai`, `zen-anthropic`, and
`zen-free` — Zen's $0 models split out because they train on your data;
the separate provider keeps that boundary visible in every model picker).
Install them by copying
into `~/.config/goose/custom_providers/` (`deploy-vps.sh` copies them
no-clobber on the brain — it never overwrites an existing copy, so after
editing a template re-copy it, or merge by hand using the diff hint the
script prints). JSON has no comments, so the caveats live here.

Upstream reference:
<https://github.com/aaif-goose/goose/blob/main/documentation/docs/getting-started/providers.md>
— fields are `name`, `engine` (`openai` | `anthropic` | `ollama`),
`display_name`, `api_key_env`, `base_url`, `models[]` (`name` +
`context_limit`), optional `headers`, `supports_streaming`, `requires_auth`.
The API key is read from the env var named by `api_key_env`, never from the
file.

## `base_url` semantics (verified against goose v1.46.0)

Tested against goose v1.46.0 with a local mock server (2026-08-21), the two
engines treat `base_url` differently:

- **`engine: openai`** — goose appends `/chat/completions` only when the URL
  doesn't already end with it, so **both** the full path and the bare base
  work (`…/zen/v1/chat/completions` and `…/zen/v1` produce the same request;
  no double-append). These files ship the full-path form. Auth is sent as
  `Authorization: Bearer <key>`.
- **`engine: anthropic`** — goose **always appends `/v1/messages`** to
  `base_url`, so the base_url must NOT include it. That's why
  `zen-anthropic.json` ships `https://opencode.ai/zen` (goose requests
  `https://opencode.ai/zen/v1/messages`, exactly Zen's documented endpoint).
  A base_url ending in `/v1/messages` produces a doubled
  `…/v1/messages/v1/messages` path and 404s. Auth is sent as `x-api-key:
  <key>` plus `anthropic-version: 2023-06-01` — no Bearer header.

| Provider | Shipped base_url | Also valid |
|---|---|---|
| zen-openai | `https://opencode.ai/zen/v1/chat/completions` | `https://opencode.ai/zen/v1` |
| zen-anthropic | `https://opencode.ai/zen` | — (must not include `/v1/messages`) |
| together | `https://api.together.xyz/v1/chat/completions` | `https://api.together.xyz/v1` |

If a provider still 404s on first use (a future goose version could change
the append behavior), run `scripts/verify/check-goose.sh` — it tests each
shipped provider with one goose run and prints swap instructions on failure.
(Symptom of a wrong variant: HTTP 404, or a doubled path like
`/chat/completions/chat/completions` in goose's error output.)

The `zen-anthropic` auth question is settled (verified against the live
endpoint, 2026-08-21): Zen's `/messages` accepts `x-api-key` (HTTP 200) and
rejects `Authorization: Bearer` (401) — and `x-api-key` is exactly what
goose's anthropic engine sends, so `zen-anthropic` works as shipped.
`scripts/verify/check-providers.sh` re-probes both headers on every run in
case this ever changes.

## Adding or updating models

There is **no model auto-discovery** — goose only offers what `models[]`
lists. The shipped lists are broad (compiled from the catalogs verified
2026-08-20), and the primary way to keep them broad is the sync script:

```bash
scripts/sync-models.sh          # dry run: fetch live catalogs, show diffs
scripts/sync-models.sh --write  # rewrite these files from the live catalogs
```

It pulls `https://opencode.ai/zen/v1/models` and
`https://api.together.xyz/v1/models` (using your keys), buckets Zen models by
wire format (claude/qwen3.5+ → `zen-anthropic`; $0/`-free`/big-pickle →
`zen-free`; gpt/grok/gemini/muse excluded — Responses/Google formats goose
cannot speak; everything else → `zen-openai`), keeps Together's chat-type
models, and refuses to write an empty list. Run it on first setup with real
keys — it corrects any shipped ID the providers have since renamed — and
whenever `scripts/verify/pin-models.sh` (the read-only drift checker) warns.
After `--write`: re-copy the changed files into
`~/.config/goose/custom_providers/`, restart goose (brain:
`systemctl restart goose-serve`), and update any renamed ID pinned in
`recipes/` or `docs/model-routing.md`.

To add a single model by hand instead: append
`{ "name": "<exact-id>", "context_limit": <tokens> }` to the right file,
keeping IDs byte-exact (Together IDs are namespaced and case-sensitive).

A few shipped IDs are best-effort until your first live sync confirms them:
`deepseek-ai/DeepSeek-V4-Flash`, `deepseek-ai/DeepSeek-V3.1`, and the Llama 4
IDs in `together.json` (Together publishes dated/suffixed variants), and
`kimi-k2.7-code`, `claude-opus-4-8`, `claude-sonnet-4-6` on Zen (IDs inferred
from Zen's naming pattern). `sync-models.sh --write` settles all of them.

Mind the routing rules when adding models: only ZDR/no-training endpoints
belong in `together` and the Zen open-model set; never add a Zen free model
here as a default for anything personal (docs/model-routing.md, hard rule 1).

## `context_limit` is best-effort

The values shipped here are taken from provider catalogs as of 2026-08-20 and
only steer goose's local context management (when to summarize/truncate) —
they are not enforced by, or verified against, the serving side. Providers
also change serving windows without renaming models (Together serves some
models below the model's native context). If a model errors on long inputs,
lower its `context_limit`; a too-low value merely summarizes earlier than
necessary, so round down when unsure.
