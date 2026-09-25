# Troubleshooting

Symptom → cause → fix, ordered by how often each one bites. Every fix points at a
script or doc in this repo. Facts about upstream bugs and endpoints verified as of
2026-08-20 — re-check the linked issues if a fix stops working.

Quick index:

| Symptom | Jump to |
|---|---|
| Goose custom provider returns 404 / "model not found" on every call | [Custom-provider 404s](#custom-provider-404s-base_url-path-semantics) |
| Zen `claude-*` / `qwen3.7-*` models fail auth (401/403) | [Zen /messages auth failures](#zen-messages-auth-failures-bearer-vs-x-api-key) |
| Together calls return 429 | [Together 429s](#together-429s-dynamic-rate-limits) |
| Brain unreachable from the Mac after it slept | [Tailscale after Mac sleep](#tailscale-unreachable-after-mac-sleep) |
| Brain unreachable after a VPS reboot | [Brain down after reboot](#brain-unreachable-after-a-vps-reboot-luks) |
| A model ID that used to work is rejected | [Model ID rejected](#model-id-rejected-deprecated) |

---

## Custom-provider 404s (base_url path semantics)

**Symptom.** Every request through a Goose custom provider (`zen-openai`,
`zen-anthropic`, or `together`) fails with an HTTP 404, an HTML error page, or a
JSON "not found" — even though `curl` against the raw API works fine with the same
key.

**Cause.** The two engines treat `base_url` differently (as of goose
v1.46.0): the `openai` engine appends
`/chat/completions` only when the URL doesn't already end with it, so both the
full path and the bare `…/v1` base work; the `anthropic` engine **always
appends `/v1/messages`**, so its base_url must not include it — a base_url
ending in `/v1/messages` produces a doubled `…/v1/messages/v1/messages` path
and 404s. A future goose version could change the append behavior, which is
why this check exists. The semantics table lives in
`config/goose/custom_providers/README.md` (JSON can't carry comments).

**Fix** (guided-manual — the script tests the shipped variant and tells you how
to swap; it doesn't flip anything itself):

1. Run the check — one goose run per provider against the shipped base_url;
   on a failure it prints the swap instructions, including the valid URL
   forms, for that provider:

   ```bash
   scripts/verify/check-goose.sh
   ```

2. Edit the failing provider's JSON in `config/goose/custom_providers/` (and
   its deployed copy in `~/.config/goose/custom_providers/`), swapping
   `base_url` to the other variant — the full variants table is in
   `config/goose/custom_providers/README.md`.
3. Re-run `check-goose.sh` until all three providers pass, and keep only the
   winning variant in both copies so nobody re-tries the loser.

The same ambiguity exists independently per engine (`openai` vs `anthropic`), so
`zen-openai` passing does not prove `zen-anthropic` will — test all three.

## Zen /messages auth failures (Bearer vs x-api-key)

**Symptom.** Models on the `zen-anthropic` provider (`claude-sonnet-5`,
`claude-haiku-4-5`, …) return 401/403 "invalid api key" or similar, while
`zen-openai` models work with the same `OPENCODE_ZEN_API_KEY`.

**What's known (as of 2026-08-21).** Zen's
`/messages` accepts `x-api-key` (200) and **rejects** `Authorization: Bearer`
(401). Goose's `anthropic` engine sends `x-api-key` plus
`anthropic-version: 2023-06-01` (as of goose v1.46.0), so
`zen-anthropic` authenticates correctly as shipped — a 401 here means the key
itself is wrong, missing from the environment (are the Keychain exports in
your shell? see `scripts/mac/keychain-secrets.sh`), or Zen changed its auth.

**Fix.**

1. Re-probe both header shapes — the script prints which one succeeds now:

   ```bash
   scripts/verify/check-providers.sh
   ```

2. If Zen ever flips to Bearer-only, goose's anthropic engine can't
   authenticate natively — add the winning header explicitly via the
   `headers` field in `config/goose/custom_providers/zen-anthropic.json`, or
   use the fallback: **drop the `zen-anthropic` provider**. Claude stays
   available through OpenCode on the Mac, and the hub's daily driver falls
   back to `zen-openai`/`kimi-k2.6` — see `docs/model-routing.md`.

## A client gets a TLS error (or Desktop suddenly can't connect)

**Symptom.** Desktop refuses the brain's TLS — the pinned fingerprint no
longer matches.

**Cause.** `goose serve` runs `--tls` with its **self-signed** cert and clients
pin its SHA-256 fingerprint. The fingerprint changes when the cert is
regenerated (a re-provisioned volume, a fresh `goose serve` state) — there is
no CA and no renewal machinery (2026-09-23: the LE cert path left with the
phone story).

**Fix.** Re-read the fingerprint on the brain —
`sudo journalctl -u goose-serve -n 50 --no-pager | grep -i fingerprint` — and
re-pin it in Desktop's connection settings. Verify from any tailnet machine:
`curl -sk https://<brain>.<tailnet>.ts.net:3284/status` (the `-k` is expected:
the cert is self-signed; only the clients pin).

## Together 429s (dynamic rate limits)

**Symptom.** Sessions on the `together` provider intermittently fail with HTTP 429,
especially in the first weeks of the account.

**Cause.** Together's rate limits are **dynamic, per-organization and per-model**
— no fixed published tiers. Limits scale with the model's live capacity and your
recent successful usage: steady traffic grows your allowance, sudden bursts get
throttled, and a fresh account with no history has very little headroom
([docs](https://docs.together.ai/docs/rate-limits)).

**Fix.**

1. Retry later, not harder: every 429 carries an `x-ratelimit-reset` header
   (seconds to wait). goose does not surface it, so a hand-retry should wait
   rather than hammer. If you write your own callers against the raw API,
   honor the header instead.
2. Expect it to fade: after a couple of weeks of successful daily traffic the
   dynamic limit rises on its own.
3. If a workload is bulk-shaped (many independent calls), consider Together's
   Batch API — separate rate pool, up to 50% off on selected models.

## Tailscale unreachable after Mac sleep

**Symptom.** After the Mac wakes from sleep, Goose Desktop can't reach the brain,
`tailscale status` hangs or shows peers offline, and pings to `<brain>.<your-tailnet>.ts.net`
time out — but the brain is fine.

**Cause.** Known macOS Tailscale client bug: the client fails to re-establish
connectivity after longer sleeps until it is relaunched
([tailscale/tailscale#1134](https://github.com/tailscale/tailscale/issues/1134),
[#17937](https://github.com/tailscale/tailscale/issues/17937)).

**Fix.** Quit Tailscale from the menu bar and reopen it (or toggle the VPN off/on
in System Settings → VPN). Connectivity returns within seconds. If Desktop still
shows a dead session afterwards, disconnect/reconnect the remote brain in
Desktop's settings. Confirm with `scripts/verify/check-brain.sh` from the Mac.

## Brain unreachable after a VPS reboot (LUKS)

**Symptom.** Nothing reaches the brain — Desktop, `check-brain.sh` all
fail — typically after a Hetzner maintenance reboot or a manual one. SSH over the
tailnet still works.

**Cause.** This is by design: `/data` is a **LUKS-encrypted volume that does not
auto-unlock** (the passphrase exists only in your password manager). After any
reboot the volume is locked, `/data` is unmounted, and `goose-serve` refuses to
start because the unit declares `RequiresMountsFor=/data`. Tailscale and SSH live
on the root disk, so the host itself comes back reachable.

**Fix.**

```bash
ssh agent@<brain>
sudo /home/agent/personal-ai-setup/scripts/vps/luks-unlock.sh
```

The script prompts for the passphrase, unlocks and mounts `/data`, and starts
`goose-serve`. Then verify from the Mac:

```bash
scripts/verify/check-brain.sh
```

If even tailnet SSH is dead, use the Hetzner Cloud web console to log in and
check that `tailscaled` is running; the full runbook is in
`docs/setup/50-vps-brain.md` (reboot drill section).

## Model ID rejected (deprecated)

**Symptom.** A previously working model returns 400/404 "model not found" or
"deprecated" — from Goose or OpenCode, or a provider pinned months ago.

**Cause.** Both gateways churn their catalogs. Zen deprecates aggressively
(18 models retired in the ~7 months before 2026-08-20 — Qwen3 Coder, Kimi K2,
GLM 4.x, and more; see the deprecation table at
<https://opencode.ai/docs/zen>), and Together retires superseded checkpoints
(e.g. Kimi-K2-Instruct-0905 → K2.6). Custom providers have **no** model
discovery: the explicit `models` lists in `config/goose/custom_providers/*.json`
go stale silently.

**Fix.**

1. Run the drift check — it diffs every pinned ID against the live catalogs
   (`https://opencode.ai/zen/v1/models` and `https://api.together.xyz/v1/models`)
   and prints what disappeared and what the current nearest successor is:

   ```bash
   scripts/verify/pin-models.sh
   ```

2. Update the affected IDs in `config/goose/custom_providers/*.json`;
   consult `docs/model-routing.md` before substituting so the replacement
   stays in the right privacy tier (never move a sensitive job off Together
   just because a model vanished).
3. Redeploy configs to the brain (`scripts/vps/deploy-vps.sh`) and re-run
   `scripts/verify/check-goose.sh`.

Run `pin-models.sh` monthly even when nothing is broken — catching a deprecation
notice beats catching a 404 mid-session.

## A coding-agent pane won't start, resume, or answer

Symptoms: `herdr machine add` fails, a pane shows an agent that never starts,
or `check-herdr.sh` goes red.

- **`herdr machine add` fails at the SSH step.** The SSH target must be the
  **herdr user** (`herdr@<brain>`) — the server's own user owns the 0600
  socket, and no other identity can reach it. Your Mac's key must be in
  `/data/herdr/.ssh/authorized_keys` first (docs/setup/70-coding-agents.md §4),
  and after a reboot `/data` is locked until `luks-unlock.sh` runs, so the
  user's home (and its keys) is absent by design (`RequiresMountsFor=/data`).
- **`machine add` says the remote binary was not found.** The bridge resolves
  `herdr` from the login shell's PATH or at `$HOME/.local/bin/herdr`; the
  installer provides both. If a manual install moved things, re-run
  `deploy-vps.sh --only herdr` rather than hand-editing PATHs.
- **The check reports "herdr.service not active".** After a reboot this is
  EXPECTED until `luks-unlock.sh` runs. Otherwise:
  `journalctl -u herdr -n 50`. The unit starts against a missing
  `/data/herdr/secrets.env` never — the installer always writes the file
  (server-only runs write an empty one), so its absence means a deploy was
  interrupted: re-run `deploy-vps.sh --only herdr`.
- **The check reports an env-set mismatch.** `/data/herdr/secrets.env` is
  written pick-aware from `/data/secrets.env` + `agents.list` and is never
  hand-edited. A mismatch means the pick list or the roster changed outside a
  deploy — update `/data/secrets.env` (and `agents.list` via a re-deploy with
  the right `--coding-agents`), never the herdr env directly.
- **A clone fails inside a pane.** The PAT lacks that repo — the credential
  scope IS the allowlist (docs/setup/70-coding-agents.md §2). Issue a new
  fine-grained token with the repo selected, update `/data/secrets.env`,
  re-run the deploy, revoke the old token.
- **A pane wrote outside `/data/herdr`?** It cannot, by namespace — a clone
  pointed outside it fails, and `check-herdr.sh` probes the boundary. If the
  probe itself fails, the namespace or the permissions regressed: re-run the
  deploy, then `systemd-analyze verify /etc/systemd/system/herdr.service`.
- **An agent session didn't resume after a server restart.** Native resume
  needs the official integrations (opencode/pi) at min versions and the agent
  config dirs the installer pre-creates. Re-run `deploy-vps.sh --only herdr`
  and check `herdr integration list`.
- **The plane went red after a herdr update was run by hand.** Never run
  `herdr update` on the brain — the binary is digest-pinned and the update
  checks are off. Reinstall from the pin:
  `deploy-vps.sh --only herdr`.

## `pai remove <id>` refuses, for every unit

That is what it does. `pai remove` is a **reader**: it prints the manifest's own
`uninstall.reason`, lists every target it would keep regardless, and exits 2 having
written nothing. There is no `--force`, and no unit is exempt — all eighteen refuse.

**Why there is no removing half yet.** Two facts in this tree make a removal today
worse than the absence it produces:

- **`pai doctor` would stay permanently red.** `check_skills` FAILs when any directory
  under `config/skills/` is missing from `~/.agents/skills`, and `doctor --fix`
  deliberately does not repair it ("--fix touches goose's extension config and nothing
  else"). Removing `coding-pack`'s eleven skills would print
  `FAIL 11 of 12 shipped skills are not installed` forever, with a remedy line telling
  you to re-run the bootstrap and no `--fix` path. doctor has no way of being told that
  a unit is *deliberately* absent.
- **A removed goose extension comes straight back.** `doctor --fix` plans
  "absent from the live config → add it" for every key the repo's own templates declare.
  A removal that a routine repair reverses is not a removal.

**And the install side cannot tell its own work from yours.** `copy_no_clobber` and
`install_skill` in `scripts/mac/bootstrap-mac.sh` both keep a pre-existing destination
and print `kept existing`. So `~/.agents/skills/ship` may be this repo's copy or the one
you wrote first, and nothing on disk records which. A remover driven off `owns:` deletes
both; the only sound predicate is content equality against the repo source.

**What it does tell you.** `pai remove brain` names `/data` and
`/data/goose` as retained; `pai remove herdr` names `/data/herdr` and its
tree. Data paths are not a
removable kind — that is structural, not a list someone has to remember to
extend. `pai remove --help` states the two doctor facts above.

**To back a unit out by hand,** the manifest's `reason` is the procedure: it is written
per unit in `config/units/<id>.yaml`, and `pai remove <id>` prints it.
