# Phase 1b — Mac setup

The Mac gets three tools: **Goose** (Desktop + CLI), **OpenCode** (the coding
driver), and the supporting kit (uv, node, jq, Tailscale). One bootstrap
script installs everything and lays down the config templates; one secrets
script puts your keys in the Keychain; then you verify.

Prerequisite: [10-accounts.md](10-accounts.md) §1–2 and §6 done — you have
`OPENCODE_ZEN_API_KEY`, `TOGETHER_API_KEY`, and an `NTFY_TOPIC` ready to paste.

One framing note before you start: the goose you install here is the
**fallback/offline surface**. From Phase 3 on, the always-on brain on the VPS
is the primary hub — Goose Desktop attaches to it as a remote client, and the
Mac-local agent is what you use when the brain is unreachable or you're
offline. Don't invest in making the local goose perfect; it just has to work.

## 1. Run the bootstrap

From your clone of this repo:

```bash
./scripts/mac/bootstrap-mac.sh
```

What it does (it's idempotent — safe to re-run after a failed step):

- **Installs via Homebrew**: `block-goose-cli` (goose CLI) and the
  `block-goose` cask (Goose Desktop), `opencode`, `uv`, `node`, `jq`, and
  `tailscale`. Install reference:
  [goose installation docs](https://github.com/aaif-goose/goose/blob/main/documentation/docs/getting-started/installation.md),
  [OpenCode docs](https://opencode.ai/docs).
- **Pins goose to 1.x.** Goose releases roughly weekly and 2.0 is in churn;
  the script pins the CLI formula (`brew pin block-goose-cli`) and keeps the
  Desktop cask off auto-update, so goose upgrades only happen when you decide
  to. The brain (Phase 3) runs the same pinned major version.
- **Copies config templates, no-clobber** — existing files are never
  overwritten, so your local edits survive re-runs:

  | Template in repo | Destination |
  |---|---|
  | `config/goose/config.yaml` | `~/.config/goose/config.yaml` |
  | `config/goose/custom_providers/*.json` | `~/.config/goose/custom_providers/` |
  | `config/goose/goosehints.example` | `~/.config/goose/.goosehints` |
  | `config/opencode/opencode.json` | OpenCode's config dir (`~/.config/opencode/`) |

The three custom-provider JSONs are the heart of it: they define the
`zen-openai`, `zen-anthropic`, and `together` providers (endpoints and pinned
model lists per [`docs/model-routing.md`](../model-routing.md)). Goose picks
them up from `~/.config/goose/custom_providers/` automatically — reference:
[custom providers](https://github.com/aaif-goose/goose/blob/main/documentation/docs/getting-started/providers.md).

## 2. Store your keys in the Keychain

```bash
./scripts/mac/keychain-secrets.sh
```

It prompts for each secret in the canonical roster (`OPENCODE_ZEN_API_KEY`,
`TOGETHER_API_KEY`, `NTFY_TOPIC`, `TAVILY_API_KEY` if you have one; the Google
OAuth pair gets added in Phase 2) and stores them with
`security add-generic-password` — the prompt reads input without echo, so
secrets never land in your shell history. It also wires your shell startup to
export the variables by reading them back from the Keychain at shell init, so
nothing is ever written to disk in plaintext.

Two rules that make this safe long-term:

- **Never set `GOOSE_DISABLE_KEYRING`** on the Mac — it downgrades goose's own
  secret storage to a plaintext `~/.config/goose/secrets.yaml`.
- The custom providers reference keys **by env var name** (`api_key_env` in
  the JSON) — that's why every doc and script in this repo uses the same
  variable names. Don't rename them.

Open a **new terminal** after this step so the exports are live, and check:

```bash
echo "${OPENCODE_ZEN_API_KEY:0:6}..."   # should print the key's first chars
```

## 3. OpenCode → Zen

OpenCode is your coding agent, wired natively to Zen:

1. Run `opencode` in any project directory.
2. Type `/connect`, choose **OpenCode Zen**, paste your Zen API key.
3. Type `/models` and set the default per the
   [routing table](../model-routing.md): **`kimi-k2.6`** for daily coding,
   escalate to **`claude-sonnet-5`** manually when a problem deserves it, and
   use **`big-pickle`** (free) only for throwaway code that contains nothing
   personal — the free tier trains on your prompts.

`config/opencode/opencode.json` (already copied by the bootstrap) pins these
defaults plus the `together` provider so they survive across machines; the
`/connect` step is what stores the credential.

## 4. Goose Desktop first run

1. Launch Goose Desktop (first launch may ask macOS for the usual
   permissions).
2. On the provider/model screen, skip the built-in provider list and select
   the custom providers the bootstrap installed. Set the default to
   **`together` / `Qwen/Qwen3.5-397B-A17B`** (the hub daily driver — ZDR, so
   the default is also the most private option), with
   **`zen-anthropic` / `claude-sonnet-5`** as the premium switch for
   non-sensitive work and **`zen-openai` / `kimi-k2.6`** as the cost-saver —
   the model picker changes this in two clicks. (`zen-free` is in the picker
   too; its display name reminds you those models train on your data.)
3. Confirm the Developer extension is on (default) and leave the extension
   list minimal for now — MCP wiring for Gmail/Calendar/Todoist happens in
   Phase 2 ([30-google-oauth.md](30-google-oauth.md)).

Desktop apps launched from Finder don't inherit your shell environment. The
config templates and `keychain-secrets.sh` handle this, but if Desktop ever
reports a missing API key while the CLI works fine, launch it once from a
terminal (`open -a Goose`) or follow the `launchctl setenv` hint that
`keychain-secrets.sh` prints — and see
[`docs/troubleshooting.md`](../troubleshooting.md).

## 5. Verify — don't skip

Three checks, in order, each designed to settle a known ambiguity before it
can waste an evening:

```bash
# 1. Raw HTTPS to every provider endpoint with your real keys.
#    Also settles the Zen /messages auth-header question (Bearer vs x-api-key)
#    and prints which one worked.
./scripts/verify/check-providers.sh

# 2. A one-line goose run through EACH of the three custom providers.
#    Settles the custom-provider base_url path semantics (bare /v1 vs full
#    /chat/completions) against the pinned goose version — if a provider
#    404s, this is the script that tells you why and what to change.
./scripts/verify/check-goose.sh

# 3. One real OpenCode run end to end.
opencode run "Say 'opencode wired' and nothing else"
```

All three green means: keys are stored correctly, all three Goose providers
and both Zen wire formats work, and the coding driver bills against Zen.
Failures: [`docs/troubleshooting.md`](../troubleshooting.md) has a section for
each (base_url 404s, Zen auth, model IDs).

Optional smoke test of the fallback hub itself:

```bash
goose run --provider zen-openai --model kimi-k2.6 -t "Reply with exactly: local goose ok"
```

## Done — where you are now

- OpenCode codes against Zen on the Mac.
- Goose Desktop + CLI work locally against all three providers.
- Combined with Pal Chat on the phone
  ([40-phone-setup.md §4](40-phone-setup.md) — you can set that up today, it
  doesn't need the brain), this is the complete **Phase 1** stack: usable on
  day one, no server.

Next: [30-google-oauth.md](30-google-oauth.md) to give goose your Gmail,
Calendar, and Tasks — then Phase 3 stands up the brain and demotes this Mac
setup to fallback duty.
