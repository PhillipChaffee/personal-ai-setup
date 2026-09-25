# Phase 1b — Mac setup

The Mac gets two tools: **Goose** (Desktop + CLI) and the supporting kit (uv,
node, jq, Tailscale). One bootstrap script installs everything and lays down
the config templates; one secrets script puts your keys in the Keychain; then
you verify. The coding agents are not on this list — they run on the brain
under herdr (Phase 3), and the Mac reaches them as a client.

Prerequisite: [10-accounts.md](10-accounts.md) §1–2 done — you have
`OPENCODE_ZEN_API_KEY` and `TOGETHER_API_KEY` ready to paste.

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
  `block-goose` cask (Goose Desktop), `uv`, `node`, `jq`, and
  `tailscale`. Install reference:
  [goose installation docs](https://github.com/aaif-goose/goose/blob/main/documentation/docs/getting-started/installation.md).
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
  | `config/skills/*/` | `~/.agents/skills/` |

  The ported OpenCode agents and the global AGENTS.md stay in
  `config/opencode/` — paste them into a self-installed OpenCode by hand (they
  left the shipped install with the herdr pivot, 2026-09-25).

The four custom-provider JSONs are the heart of it: they define the
`together` (default), `zen-openai`, `zen-anthropic`, and `zen-free` providers
(endpoints and model lists per [`docs/model-routing.md`](../model-routing.md)). Goose picks
them up from `~/.config/goose/custom_providers/` automatically — reference:
[custom providers](https://github.com/aaif-goose/goose/blob/main/documentation/docs/getting-started/providers.md).

### Skills, agents, and global rules

The last three rows are the part of the install that is easiest to miss,
because nothing on this machine is named after it.

**`~/.agents/skills/`** is a single directory read by **both** tools: OpenCode
treats it as its agent-compatible global skills dir (if you run OpenCode — the
repo ships no OpenCode install or config; you input your own settings), and
goose ≥ 1.16 reads
skills from it too. Each skill is a directory holding a Claude-compatible
`SKILL.md` — a short instruction file the model loads when the task matches.
The bootstrap installs them **atomically** (copy to a temp dir, then `mv`), so
an interrupted run can never leave a half-copied skill that the no-clobber rule
would then keep forever.

One unit puts the skills there — the eleven Cursor-ported ones (`code-review`,
`ship`, `deep-research`, …), from the Cursor port, dispatching into the OpenCode
subagents. What was ported, adapted and dropped is
[`docs/cursor-port.md`](../cursor-port.md).

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

The bootstrap is three **units**, one per manifest in
[`config/units/`](../../config/units/README.md). With no flags all three run,
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
| `coding-pack` | the eleven ported skills, the agents, `AGENTS.md` | — |

```bash
./scripts/mac/bootstrap-mac.sh --dry-run              # what would happen, and nothing else
./scripts/mac/bootstrap-mac.sh --only base-toolchain  # just uv/node/jq/Tailscale
./scripts/mac/bootstrap-mac.sh --without base-goose   # toolchain + coding-pack, no goose
```

Three things worth knowing before you use them:

- **`--only` replaces the default set; `--with` adds to it.** `--only coding-pack`
  installs one unit — coding-pack requires nothing since the OpenCode unit left
  the catalog — and leaves the goose units out. `--with coding-pack`
  installs all three, because coding-pack was already in the default set.
- **Excluding something another unit needs is refused, not half-done.**
  `--without base-toolchain` also drops `base-goose` and says so on stdout,
  because nothing else needs base-toolchain. But `--only base-goose --without
  base-toolchain` names base-goose explicitly, so it exits `2` naming both rather
  than installing goose onto a machine where its dependency never ran.
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

It prompts for **the secrets your installed units actually need, and nothing
else** — on a base install that is exactly `OPENCODE_ZEN_API_KEY` and
`TOGETHER_API_KEY`. The roster comes from the unit manifests, so it is the same
list `pai secrets --host mac` prints, each name carrying that manifest's own
one-line description. Values are stored with `security add-generic-password`;
the prompt reads input without echo, so secrets never land in your shell
history. It also wires your shell startup to export the variables by reading
them back from the Keychain at shell init, so nothing is ever written to disk
in plaintext.

When you add an add-on later, name it and only its secrets are asked for:

```bash
./scripts/mac/keychain-secrets.sh --units herdr              # one add-on's Keychain names
./scripts/mac/keychain-secrets.sh --units connectors         # the Tavily key
./scripts/mac/keychain-secrets.sh --rewrite-only             # just refresh ~/.zshrc
```

Where a value is meant to be generated rather than pasted — the code-agent
buzz topic —
type `generate` at the hidden prompt and openssl mints one straight into the
Keychain; it is never printed. The `~/.zshrc` block is **rewritten in place**
between its `# >>> personal-ai keychain exports` markers on every run, so
re-running is safe and needs no hand-editing. Everything outside those markers
is left byte-for-byte alone, and if the markers are ever mangled (two of them,
one missing, out of order) the script refuses and changes nothing.

Two rules that make this safe long-term:

- **Never set `GOOSE_DISABLE_KEYRING`** on the Mac — it downgrades goose's own
  secret storage to a plaintext `~/.config/goose/secrets.yaml`.
- The custom providers reference keys **by env var name** (`api_key_env` in
  the JSON) — that's why every doc and script in this repo uses the same
  variable names. Don't rename them.

Open a **new terminal** after this step so the exports are live, and check by
length — never by printing part of a key:

```bash
echo "${#OPENCODE_ZEN_API_KEY} chars"   # non-zero means the export worked
```

## 3. OpenCode → Zen

OpenCode is no longer part of this install: the coding agents run on the brain
under herdr (Phase 3), and the repo ships no OpenCode config for anyone —
people input their own settings. There is nothing to do here. What step 2
stored still matters: the Mac's goose providers and the verify scripts bill
against Zen through `$OPENCODE_ZEN_API_KEY`.

If you run OpenCode locally anyway, two things to know:

- **Nothing here configures it.** There is no shipped `opencode.json`, no
  credential write, no `/connect` step — you point OpenCode at Zen yourself.
- **The routing rules still apply.** Set models with `/models` per the
  [routing table](../model-routing.md): **`kimi-k2.6`** for
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
   list minimal for now — connector adoption is [Phase 2](../connecting.md)
   territory, and every shipped connector fragment starts disabled.

Desktop apps launched from Finder don't inherit your shell environment. The
config templates and `keychain-secrets.sh` handle this, but if Desktop ever
reports a missing API key while the CLI works fine, launch it once from a
terminal (`open -a Goose`) or follow the `launchctl setenv` hint that
`keychain-secrets.sh` prints — and see
[`docs/troubleshooting.md`](../troubleshooting.md).

## 5. Verify — don't skip

Two checks, in order, each designed to settle a known ambiguity before it
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
```

Both green means: keys are stored correctly, all three Goose providers
and both Zen wire formats work.
Failures: [`docs/troubleshooting.md`](../troubleshooting.md) has a section for
each (base_url 404s, Zen auth, model IDs).

Optional smoke test of the fallback hub itself:

```bash
goose run --provider zen-openai --model kimi-k2.6 -t "Reply with exactly: local goose ok"
```

## Done — where you are now

- Goose Desktop + CLI work locally against all three providers.
- The Cursor-ported skills are in place for goose (and for any OpenCode you
  run yourself).
- This is the complete **Phase 1** stack: usable on
  day one, no server.

Next: Phase 3 stands up the brain and demotes this Mac
setup to fallback duty.
