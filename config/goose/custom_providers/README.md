# Goose custom providers

These JSON files define the three named providers the whole setup routes
through (`zen-openai`, `zen-anthropic`, `together`). Install them by copying
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

## The `base_url` A/B caveat

Goose's docs example uses a **full** completions URL
(`.../v1/chat/completions`), but whether goose wants the full path or the bare
API base (`.../v1`) is not pinned down upstream — the docs themselves flag it,
and it may differ between goose versions. These files ship with the full-path
variant:

| Provider | Shipped (variant A, full path) | Variant B (bare base) |
|---|---|---|
| zen-openai | `https://opencode.ai/zen/v1/chat/completions` | `https://opencode.ai/zen/v1` |
| zen-anthropic | `https://opencode.ai/zen/v1/messages` | `https://opencode.ai/zen/v1` |
| together | `https://api.together.xyz/v1/chat/completions` | `https://api.together.xyz/v1` |

If a provider 404s or errors on first use, run `scripts/verify/check-goose.sh`
— it tests the shipped variant with one goose run per provider and, on a
failure, prints the swap instructions (both URL forms, per the table above).
The A/B is guided-manual: swap the `base_url` here to the other variant,
re-copy into `~/.config/goose/custom_providers/`, and re-run the script until
it passes. (Symptom of the wrong variant: HTTP 404, or a path like
`/chat/completions/chat/completions` in goose's error output.)

A second uncertainty applies to `zen-anthropic` only: Zen does not document
the auth header for direct `/messages` calls (Bearer vs `x-api-key`).
`scripts/verify/check-providers.sh` settles it; if goose's anthropic engine
sends the wrong one, the fallback is to drop `zen-anthropic` and reach Claude
via OpenCode only (see docs/troubleshooting.md).

## Adding or updating models

There is **no model auto-discovery** — goose only offers what `models[]`
lists, so new or renamed upstream models must be added here by hand:

1. Find the exact live ID:
   - Zen: `https://opencode.ai/zen/v1/models` (or <https://opencode.ai/docs/zen>)
   - Together: `https://api.together.xyz/v1/models`
   - or just run `scripts/verify/pin-models.sh`, which diffs everything pinned
     in this repo against both catalogs.
2. Append `{ "name": "<exact-id>", "context_limit": <tokens> }` to the right
   file. Keep IDs byte-exact (Together IDs are namespaced and case-sensitive,
   e.g. `Qwen/Qwen3.5-397B-A17B`).
3. Re-copy into `~/.config/goose/custom_providers/` and restart goose
   (on the brain: `systemctl restart goose-serve`).
4. If the model appears in `docs/model-routing.md` or a recipe, update those
   in the same commit.

One shipped ID needs confirming before you rely on it:
`deepseek-ai/DeepSeek-V4-Flash` in `together.json` — Together publishes dated
variants of this model (e.g. a `-0731` release), so confirm the exact live ID
with `scripts/verify/pin-models.sh` and correct the file if it differs.

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
