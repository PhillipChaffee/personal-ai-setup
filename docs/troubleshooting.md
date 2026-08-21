# Troubleshooting

Symptom → cause → fix, ordered by how often each one bites. Every fix points at a
script or doc in this repo. Facts about upstream bugs and endpoints verified as of
2026-08-20 — re-check the linked issues if a fix stops working.

Quick index:

| Symptom | Jump to |
|---|---|
| Goose custom provider returns 404 / "model not found" on every call | [Custom-provider 404s](#custom-provider-404s-base_url-path-semantics) |
| Zen `claude-*` / `qwen3.7-*` models fail auth (401/403) | [Zen /messages auth failures](#zen-messages-auth-failures-bearer-vs-x-api-key) |
| A scheduled job didn't fire | [Scheduler job didn't fire](#goose-scheduler-job-didnt-fire) |
| Together calls return 429 | [Together 429s](#together-429s-dynamic-rate-limits) |
| Brain unreachable from the Mac after it slept | [Tailscale after Mac sleep](#tailscale-unreachable-after-mac-sleep) |
| Brain unreachable after a VPS reboot | [Brain down after reboot](#brain-unreachable-after-a-vps-reboot-luks) |
| Google MCP asks you to re-authenticate every week | [workspace-mcp 7-day re-auth](#workspace-mcp-re-auth-every-7-days) |
| Goose iOS app won't pair with the brain | [iOS pairing fails](#goose-ios-pairing-fails) |
| A model ID that used to work is rejected | [Model ID rejected](#model-id-rejected-deprecated) |

---

## Custom-provider 404s (base_url path semantics)

**Symptom.** Every request through a Goose custom provider (`zen-openai`,
`zen-anthropic`, or `together`) fails with an HTTP 404, an HTML error page, or a
JSON "not found" — even though `curl` against the raw API works fine with the same
key.

**Cause.** Goose's custom-provider JSON has ambiguous `base_url` semantics: the
documented example uses a **full** endpoint path
(`https://opencode.ai/zen/v1/chat/completions`), but depending on version the
engine may append the path itself, so a bare base
(`https://opencode.ai/zen/v1`) is what actually works — or vice versa. Get it
wrong and Goose calls `…/v1/chat/completions/chat/completions` (404) or `…/v1`
(404). This is a known open question upstream. JSON can't carry comments, so the
both-variants table lives in `config/goose/custom_providers/README.md`.

**Fix** (guided-manual — the script tests the shipped variant and tells you how
to swap; it doesn't flip anything itself):

1. Run the check — one goose run per provider against the shipped variant
   (A, full path); on a failure it prints the swap instructions, including
   both URL forms, for that provider:

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
`claude-haiku-4-5`, `qwen3.7-plus`) return 401/403 "invalid api key" or similar,
while `zen-openai` models work with the same `OPENCODE_ZEN_API_KEY`.

**Cause.** OpenCode Zen serves Claude/Qwen on the Anthropic Messages endpoint
(`https://opencode.ai/zen/v1/messages`), and the exact auth header for direct
calls is **not officially documented**. Community setups pass the Zen key as a
Bearer token (`Authorization: Bearer …`), but Anthropic-native clients — which is
what Goose's `anthropic` engine is — send `x-api-key` plus an `anthropic-version`
header instead. One of the two shapes will be rejected.

**Fix.**

1. Let the probe script settle it — it curls `…/zen/v1/messages` with **both**
   header shapes and prints which one succeeds:

   ```bash
   scripts/verify/check-providers.sh
   ```

2. If Goose's `anthropic` engine sends the losing header, add the winning one
   explicitly via the `headers` field in
   `config/goose/custom_providers/zen-anthropic.json`.
3. If neither shape works from Goose, use the documented fallback: **drop the
   `zen-anthropic` provider entirely**. Claude stays available through OpenCode on
   the Mac (Zen is its first-party gateway), and the hub's daily driver falls back
   to `zen-openai`/`kimi-k2.6` — see `docs/model-routing.md`.

## Goose scheduler job didn't fire

**Symptom.** A registered automation (say `morning-brief`) produced no push, no
session, nothing — `goose schedule sessions --schedule-id morning-brief` shows no
run at the expected time.

**Cause.** Goose's scheduler is **in-process**: it only ticks while a goose
process is running. On the brain that means `goose serve --enable-scheduler`
under the `goose-serve` systemd unit. If the unit is down (crash, reboot with
LUKS still locked, failed deploy), every schedule silently misses. On top of
that, the scheduler has known upstream bugs — background jobs running in chat
mode and blocking tools ([block/goose#3882](https://github.com/block/goose/issues/3882))
and timing/session-loading failures
([block/goose#5045](https://github.com/block/goose/issues/5045)).

**Fix.**

1. Is the brain process up?

   ```bash
   ssh agent@<brain> systemctl status goose-serve
   ssh agent@<brain> journalctl -u goose-serve --since "-6h" --no-pager
   ```

   If it's down because `/data` is locked, see
   [Brain unreachable after a VPS reboot](#brain-unreachable-after-a-vps-reboot-luks).
2. Is the schedule registered? `goose schedule list` on the brain. If missing or
   stale, re-run `scripts/vps/register-schedules.sh` — note the scheduler keeps
   its **own copy** of each recipe at registration time, so editing a YAML in the
   repo does nothing until you re-register.
3. Test the job directly: `goose schedule run-now --schedule-id morning-brief`
   (or from Desktop's Scheduler UI). If run-now works but cron firings don't,
   you're likely hitting the upstream bugs.
4. If the native scheduler keeps misbehaving, **flip that job to the shipped
   systemd-timer fallback** — the one-command procedure is in
   `docs/automations.md`. The fallback timers call the same recipes through the
   same deterministic wrapper (`scripts/common/run-recipe.sh`), so delivery and
   notifications are unchanged.

**Note — there is nothing to debug on the Mac.** All schedules live on the
brain's scheduler by design; this setup deliberately installs **no launchd
plists and no crontabs on the Mac**, so a closed laptop lid can never be the
reason an automation missed.

## Together 429s (dynamic rate limits)

**Symptom.** Recipes pinned to the `together` provider (health-followups,
vault-qa, budget-checkin, automation fallback) intermittently fail with HTTP 429,
especially in the first weeks of the account.

**Cause.** Together's rate limits are **dynamic, per-organization and per-model**
— no fixed published tiers. Limits scale with the model's live capacity and your
recent successful usage: steady traffic grows your allowance, sudden bursts get
throttled, and a fresh account with no history has very little headroom
([docs](https://docs.together.ai/docs/rate-limits)).

**Fix.**

1. Know what the wrapper does — and doesn't: on fallback-timer and manual runs,
   `scripts/common/run-recipe.sh` retries the `goose run` **once** after a flat
   60-second sleep, and only if the retry also fails does it send the failure
   alert. The retry is deliberately blind: every 429 carries an
   `x-ratelimit-reset` header (seconds to wait), but the header is not visible
   through goose's exit status, so the wrapper can't honor it. If you write
   your own callers against the raw API, honor the header instead of
   hammering. (Native-scheduler runs have no wrapper; a 429-killed run shows
   up in the Scheduler UI / per-schedule session history.)
2. Keep crons staggered. The shipped schedule already spaces Together-heavy jobs
   (health-followups Sun 18:30, budget-checkin monthly 09:00); if you add new
   recipes, don't land two Together jobs in the same minute — see the cron table
   in `docs/automations.md`.
3. Expect it to fade: after a couple of weeks of successful daily traffic the
   dynamic limit rises on its own.
4. If a job is bulk-shaped (many independent calls), consider Together's Batch
   API — separate rate pool, up to 50% off on selected models.

## Tailscale unreachable after Mac sleep

**Symptom.** After the Mac wakes from sleep, Goose Desktop can't reach the brain,
`tailscale status` hangs or shows peers offline, and pings to `<brain>.<your-tailnet>.ts.net`
time out — but the brain is fine (the iPhone still reaches it).

**Cause.** Known macOS Tailscale client bug: the client fails to re-establish
connectivity after longer sleeps until it is relaunched
([tailscale/tailscale#1134](https://github.com/tailscale/tailscale/issues/1134),
[#17937](https://github.com/tailscale/tailscale/issues/17937)).

**Fix.** Quit Tailscale from the menu bar and reopen it (or toggle the VPN off/on
in System Settings → VPN). Connectivity returns within seconds. If Desktop still
shows a dead session afterwards, disconnect/reconnect the remote brain in
Desktop's settings. Confirm with `scripts/verify/check-brain.sh` from the Mac.

## Brain unreachable after a VPS reboot (LUKS)

**Symptom.** Nothing reaches the brain — Desktop, iPhone, `check-brain.sh` all
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

## workspace-mcp re-auth every 7 days

**Symptom.** Gmail/Calendar tools work for a few days, then start failing with
invalid/expired-token errors, and the Google consent screen pops up again. Repeat
weekly.

**Cause.** Your GCP OAuth consent screen is still in **"Testing"** publishing
status. Google auto-expires all refresh tokens for Testing-status external apps
after exactly 7 days
([Google's notice](https://support.google.com/cloud/answer/15549945)). This is
the single most common trap with self-hosted Google MCP servers.

**Fix.** Google Cloud Console → APIs & Services → OAuth consent screen →
**Publish app** → status becomes **"In production"**. For a personal app you can
ignore the verification flow — you'll see an "unverified app" warning at consent
time, which is fine. Re-authenticate **once more** after publishing; that new
refresh token is long-lived. Full walkthrough (and how to move tokens to the
brain): `docs/setup/30-google-oauth.md`.

## Goose iOS pairing fails

**Symptom.** The Goose iOS app can't pair with, or loses connection to, the
brain.

**Cause.** Mobile access is an **experimental** Goose feature, and pairing an iOS
client to a *headless* `goose serve` (rather than to Goose Desktop) is the least
proven link in this whole setup — upstream docs describe Desktop-initiated
pairing. The tunnel also relays through Cloudflare infrastructure (outbound-only;
see `docs/privacy.md`), so an upstream change can break it without notice.

**Fix.** Walk the fallback chain in order — it's laid out step-by-step in
`docs/setup/40-phone-setup.md`:

1. **Retry headless pairing** against the brain (transient tunnel failures are
   common; check `journalctl -u goose-serve` for pairing log lines).
2. **Desktop-initiated tunnel**: connect Goose Desktop to the remote brain, start
   the tunnel/pairing from Desktop, pair the phone against that. Sessions still
   live on the brain.
3. **Telegram gateway on the brain**: `goose gateway start telegram` gives full
   chat access from the Telegram app — computer-independent, same sessions.
4. **Pal Chat** direct to Together — always works, but chat-only and
   device-local history; it's the backup of last resort by design.

Also watch the goose mobile roadmap (remote ACP + push notifications) — see
`docs/roadmap.md`; when that ships, most of this chain collapses into one step.

## Model ID rejected (deprecated)

**Symptom.** A previously working model returns 400/404 "model not found" or
"deprecated" — from Goose, OpenCode, or a recipe that has run fine for months.

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

2. Update the affected IDs in `config/goose/custom_providers/*.json`,
   `config/opencode/opencode.json`, and any recipe `settings.goose_model` that
   pins the retired model; consult `docs/model-routing.md` before substituting so
   the replacement stays in the right privacy tier (never move a sensitive job
   off Together just because a model vanished).
3. Redeploy configs to the brain (`scripts/vps/deploy-vps.sh`) and re-run
   `scripts/verify/check-goose.sh`.

Run `pin-models.sh` monthly even when nothing is broken — catching a deprecation
notice beats catching a 404 at 07:00 when the morning brief fails.
