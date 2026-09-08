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
  | `config/skills/*/` | `~/.agents/skills/` |
  | `config/opencode/agents/*.md` | `~/.config/opencode/agents/` |
  | `config/opencode/AGENTS.md` | `~/.config/opencode/AGENTS.md` |

The four custom-provider JSONs are the heart of it: they define the
`together` (default), `zen-openai`, `zen-anthropic`, and `zen-free` providers
(endpoints and model lists per [`docs/model-routing.md`](../model-routing.md)). Goose picks
them up from `~/.config/goose/custom_providers/` automatically — reference:
[custom providers](https://github.com/aaif-goose/goose/blob/main/documentation/docs/getting-started/providers.md).

### Skills, agents, and global rules

The last three rows are the part of the install that is easiest to miss,
because nothing on this machine is named after it.

**`~/.agents/skills/`** is a single directory read by **both** tools: OpenCode
treats it as its agent-compatible global skills dir, and goose ≥ 1.16 reads
skills from it too. Each skill is a directory holding a Claude-compatible
`SKILL.md` — a short instruction file the model loads when the task matches.
The bootstrap installs them **atomically** (copy to a temp dir, then `mv`), so
an interrupted run can never leave a half-copied skill that the no-clobber rule
would then keep forever.

Two units put things there, and the split matters if you ever install
selectively:

- **`connect-service`** is the goose-native connect workflow (paired with
  `recipes/connect-service.yaml`). It is what reads a connector manifest when
  one exists and writes one when it does not.
- **the eleven Cursor-ported skills** (`code-review`, `ship`, `deep-research`,
  …) come from the Cursor port and dispatch into the OpenCode subagents. What
  was ported, adapted and dropped is [`docs/cursor-port.md`](../cursor-port.md).

**`~/.config/opencode/agents/`** holds the subagents those skills dispatch **by
name**, and **`~/.config/opencode/AGENTS.md`** is the global rule set OpenCode
reads in every project. Both are OpenCode-only; goose does not read either.
Per-project rule snippets deliberately stay in the repo
(`config/opencode/project-rules/`) — you paste the ones you want into a
project yourself.

Nothing here is overwritten on a re-run, so a skill or agent file you have
edited stays edited. The flip side: an edited file is also never *updated* —
delete it and re-run the bootstrap to take a new version from the repo.

### Choosing what to install

The bootstrap is five **units**, one per manifest in
[`config/units/`](../../config/units/README.md). With no flags all five run,
which is what the section above describes. The flags pick a subset:

| Flag | Meaning |
|---|---|
| `--with ID[,ID]` | add `ID` (and whatever it requires) to the default set |
| `--without ID[,ID]` | drop `ID`, and anything left needing it |
| `--only ID[,ID]` | install exactly `ID` plus what `ID` requires, nothing else |
| `--dry-run` | print the resolved plan and exit, touching nothing |

The units and their dependencies:

| Unit | What it installs | Requires |
|---|---|---|
| `base-toolchain` | uv, node, jq, the Tailscale cask | — |
| `base-goose` | goose CLI + Desktop cask, the pin, `~/.config/goose` | `base-toolchain` |
| `opencode` | the OpenCode CLI, `~/.config/opencode/opencode.json`, the Zen credential in `~/.local/share/opencode/auth.json` | `base-goose` |
| `base-skills` | the `connect-service` skill | `base-goose` |
| `coding-pack` | the eleven ported skills, the agents, `AGENTS.md` | `opencode` |

```bash
./scripts/mac/bootstrap-mac.sh --dry-run              # what would happen, and nothing else
./scripts/mac/bootstrap-mac.sh --without opencode     # goose only, no OpenCode
./scripts/mac/bootstrap-mac.sh --only base-toolchain  # just uv/node/jq/Tailscale
```

Three things worth knowing before you use them:

- **`--only` replaces the default set; `--with` adds to it.** `--only coding-pack`
  installs four units (coding-pack needs opencode, which needs base-goose, which
  needs base-toolchain) and leaves `connect-service` out. `--with coding-pack`
  installs all five, because coding-pack was already in the default set.
- **Excluding something another unit needs is refused, not half-done.**
  `--without opencode` also drops `coding-pack` and says so on stdout, because
  nothing else needs opencode. But `--only coding-pack --without opencode` names
  coding-pack explicitly, so it exits `2` naming both rather than installing
  OpenCode agents onto a machine with no OpenCode.
- **`--dry-run` really touches nothing** — no `$HOME`, no `brew`, not even a
  `uname`. It answers before the macOS check and before the Homebrew check, so
  it works on a Mac that has neither.

One residual: `pai doctor` is **not** selection-aware yet. On a selective
install it reports the units you left out as missing skills and tells you to
re-run the bootstrap. That is recorded on `coding-pack`'s manifest and is
tracked separately; nothing is actually wrong with the install.

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

OpenCode is your coding agent, wired natively to Zen, and **there is nothing to
do here** on a normal install: `bootstrap-mac.sh` writes
`~/.local/share/opencode/auth.json` (mode `600`) from `$OPENCODE_ZEN_API_KEY`,
and `config/opencode/opencode.json` — already copied by the bootstrap — pins the
models and the `together` provider so they survive across machines. There is no
`/connect` step any more. `/models` survives for exactly one case, the second
bullet below: those pins are the defaults for a **fresh** profile, and OpenCode
will keep a model it has already remembered.

Two cases where you do something:

- **You set the key for the first time in step 2 above.** The bootstrap ran
  before the key existed. Open a new terminal and run
  `./scripts/mac/opencode-auth.sh` (or the whole bootstrap again — it is
  idempotent). It tells you which of the two happened.
- **OpenCode has remembered a different model** from an earlier session.
  `opencode.json` only sets the defaults for a fresh profile, so type `/models`
  and set it per the [routing table](../model-routing.md): **`kimi-k2.6`** for
  daily coding, escalate to **`claude-sonnet-5`** manually when a problem
  deserves it, and use **`big-pickle`** (free) only for throwaway code that
  contains nothing personal — the free tier trains on your prompts.

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
   list minimal for now — MCP wiring for Gmail/Calendar happens in
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

# 3. The OpenCode unit: the config, the credential (existence, mode 600 and
#    contents), the ported agents, one real `opencode run`, and WHICH opencode
#    your PATH actually resolves to. Exits 2, not 1, if OpenCode is not
#    installed. This replaces the hand-typed `opencode run` that used to be
#    step 3 here — that line was the entire automated coverage this unit had.
./scripts/verify/check-opencode.sh
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
