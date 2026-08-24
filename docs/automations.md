# Automations: Cursor-style workflows, natively in Goose

Scheduled background jobs — the morning brief, inbox triage, the weekly review — run on
the brain using Goose's own recipe + scheduler machinery. No bare cron UX: you get a
dashboard, run-now, pause, and per-run history, the way Cursor does automations, but on
infrastructure you own.

## The concepts

| Piece | Role |
|---|---|
| Recipe YAML (`recipes/*.yaml`) | **The workflow.** Instructions, extensions it may use, and a pinned `goose_provider`/`goose_model` per [model-routing.md](model-routing.md) |
| `goose schedule` | **The trigger.** Native cron registration against the brain's scheduler |
| Desktop Scheduler UI | **The dashboard.** Pause/resume, run-now, per-schedule session history — visible from Goose Desktop connected to the brain |
| `sessions.db` on `/data` | **The run log.** Every scheduled run lands as a session in the same shared history your interactive chats use, inspectable from any surface |

One dependency to understand: the scheduler is **in-process**. It fires only while
`goose serve --enable-scheduler` is running — which is exactly what the systemd unit
(`scripts/vps/systemd/goose-serve.service`, `Restart=always`) guarantees on the brain.
Nothing here runs on your Mac or phone.

## Current roster

Crons are 6-field (seconds first), evaluated in the brain's local timezone (set in
Terraform). Staggered deliberately — Together's rate limits are dynamic and dislike
bursts.

| Recipe | Schedule (cron) | Model | Delivery |
|---|---|---|---|
| `morning-brief` | `0 0 7 * * *` (daily 07:00) | zen-openai / `minimax-m2.7` | self-addressed email `Morning brief — <date>` |
| `inbox-triage` | `0 0 9,13,17 * * MON-FRI` | zen-openai / `minimax-m2.7` | Gmail labels + drafts (**never auto-send** to anyone else); self-addressed email `Inbox triage — action needed` ONLY when action-needed items exist, otherwise no email (final message `NO_ACTION_NEEDED`) |
| `weekly-review` | `0 0 17 * * SUN` (Sun 17:00) | zen-openai / `kimi-k2.6` | self-addressed email `Weekly review — <date>` — the report is **sent**, not left as a draft |
| `health-followups` | `0 30 18 * * SUN` (Sun 18:30) | together / `Qwen/Qwen3.5-397B-A17B` | pulls, appends to, commits + pushes `/data/life-vault/health/appointments.md`; self-addressed email `Health follow-ups` whose body is the PHI-free count line only (`Health review ready: N items`) |
| `vault-qa` | on-demand, not scheduled | together / `deepseek-ai/DeepSeek-V4-Flash-0731` | interactive session on the brain; developer extension only |
| `budget-checkin` | `0 0 9 1 * *` (1st of month, 09:00) | together / `openai/gpt-oss-120b` | self-addressed email `Budget check-in` vs `budget.md` — **disable after deploy** until you've picked a budgeting source |

**Multiple Google accounts:** with `USER_GOOGLE_EMAILS` set
([30-google-oauth.md §8](setup/30-google-oauth.md)), `morning-brief`,
`inbox-triage`, and `weekly-review` sweep every listed account (items tagged
by account; labels and drafts stay inside the account that owns the message)
while delivery stays one self-addressed email from the primary. The recipes
carry the roster as a `google_accounts` parameter: `register-schedules.sh`
stores it on each schedule (`goose schedule add --params`) so the scheduler
applies it at fire time, and `run-recipe.sh` passes the same value on manual
and fallback-timer runs. The vault recipes stay primary-only by design.

`scripts/vps/register-schedules.sh` registers this roster idempotently and prints
`goose schedule list` when done.

**Vault-dependent recipes are skipped until their inputs exist.** `health-followups`
needs `/data/life-vault/health/appointments.md` and `budget-checkin` needs
`/data/life-vault/finance/ledger.csv`; before Phase 4 those files do not exist, and a
registered recipe would fail on every fire and trip the watchdog's alert. The script
skips them (and unregisters them if an earlier deploy added them), naming the missing
path. They register themselves once the vault is cloned and the file is real — no extra
step. `REGISTER_ALL=1` overrides this if you want the whole roster regardless.

That also removes the old `budget-checkin` caveat: goose 1.x still has no `schedule
pause` CLI, but the recipe no longer registers active on a fresh brain, so there is
nothing to pause until you actually have a ledger.

## Adding a new automation, end to end

1. **Write the recipe** — copy the closest existing file in `recipes/` and edit. Keep the
   pinned model consistent with the routing table (sensitive data → `together`), keep the
   extension list minimal (each MCP server's tools cost context on every turn), and have
   the recipe's explicit final step deliver its result as ONE self-addressed email via
   the Gmail send tool — sender and recipient are both the PRIMARY account
   (`USER_GOOGLE_EMAIL`; the first roster entry when `USER_GOOGLE_EMAILS` is set), and
   the instructions must forbid emailing anyone else.

2. **Test it headless once**, exactly the way unattended runs execute:

   ```bash
   GOOSE_MODE=auto GOOSE_MAX_TURNS=50 GOOSE_CONTEXT_STRATEGY=summarize \
   GOOSE_DISABLE_SESSION_NAMING=true \
   goose run --recipe recipes/my-job.yaml --no-session --quiet --output-format json
   ```

   Or equivalently `scripts/common/run-recipe.sh recipes/my-job.yaml`, which sets that
   exact environment for you and adds the watchdog's retry + failure alerting (delivery
   still comes from the recipe's own self-addressed email step). Headless runs
   can't answer prompts or ask clarifying questions — `GOOSE_MODE=auto` plus the turn cap
   is what keeps an ambiguous recipe from hanging or running away.

3. **Register the trigger** on the brain:

   ```bash
   goose schedule add --schedule-id my-job \
     --cron "0 0 8 * * *" \
     --recipe-source /home/agent/personal-ai-setup/recipes/my-job.yaml
   ```

   Better: add the same line to `scripts/vps/register-schedules.sh` (it's idempotent) so
   the roster stays reproducible, then re-run it. If your recipe declares the
   `google_accounts` parameter and you use `USER_GOOGLE_EMAILS`, add `--params
   google_accounts="$USER_GOOGLE_EMAILS"` to the `schedule add` (or just add the job to
   `register-schedules.sh`, which does it for you) — without it the run sweeps only the
   primary account.

4. **Confirm in the Scheduler UI** — open Goose Desktop (connected to the brain), find
   the schedule, hit run-now in the Desktop Scheduler UI, and check that the email
   arrives in your inbox and the run's session looks right. CLI equivalent:
   `scripts/common/run-recipe.sh my-job`, then
   `goose schedule sessions --schedule-id my-job`. `goose schedule run-now --schedule-id
   my-job` also works and is handy for a quick check — verified against goose 1.46.0, it
   runs the job **synchronously in the CLI process** and prints the failure inline — but
   because it runs in that process, a dropped SSH session kills the run mid-flight, and it
   does not load `/data/secrets.env` or add the watchdog's retry + failure alert. Prefer
   the wrapper for anything you care about finishing.

Day-to-day management: `goose schedule list` / `run-now` / `sessions` / `remove` on the
brain, or the Desktop Scheduler UI for pause/resume and history. Reference:
[Goose CLI commands](https://github.com/aaif-goose/goose/blob/main/documentation/docs/guides/goose-cli-commands.md).

## Delivery: recipes email their own results, plus a failure watchdog

Everything lands in your email inbox. There is no phone push app anywhere in the
system — ntfy is only the failure-alert transport below, with no app subscribed to
it. Two distinct channels, deliberately kept apart:

- **Content: each scheduled recipe sends ONE self-addressed email via the Gmail send
  tool as its explicit final step.** Sender and recipient are both the owner's
  **primary** account (`USER_GOOGLE_EMAIL`) — the recipes' instructions make that
  single send the only permitted Gmail write to any recipient, so delivery stays a
  fixed step, never model improvisation. The subjects: `Morning brief — <date>` (daily),
  `Inbox triage — action needed` (ONLY when action-needed items exist — otherwise
  no email at all and the final message is exactly `NO_ACTION_NEEDED`),
  `Weekly review — <date>` (the report is **sent**, not left as a draft),
  `Health follow-ups` (body is the PHI-free count line `Health review ready: N items`
  and nothing else — [privacy.md](privacy.md)), and `Budget check-in` (dormant until
  you enable the recipe).
- **Failures: `scripts/common/run-recipe.sh` is a headless runner + failure
  watchdog** — it wraps the systemd fallback timers and manual tests, never the
  native-scheduler runs. It sets the canonical headless environment, runs the recipe,
  and on a nonzero exit retries ONCE after a 60-second sleep (a blind retry:
  Together's `x-ratelimit-reset` header is not visible through goose's exit status).
  Only after the retry also fails does it send a high-priority failure alert via
  `scripts/common/notify.sh`, which publishes to `https://ntfy.sh/$NTFY_TOPIC` and —
  when `NTFY_EMAIL` is set — has ntfy.sh forward the alert to that address via its
  email gateway (an `Email:` header on the publish). ntfy.sh's free tier caps
  email forwarding at ~5/day: fine for rare failure alerts, and exactly why content
  does NOT travel this channel. `NTFY_TOPIC` stays required (it's the transport, and
  the topic name is still a secret); the plain topic push still happens too,
  harmless with no app subscribed. The watchdog does **not** deliver success
  output — the recipe already emailed that itself; the final text is simply logged
  to stdout (journald keeps it on timer runs).

**Documented limitation:** on the native-scheduler path there is no wrapper, so a run
that crashes *before* its final email step delivers nothing at all. That failure is
visible in the Desktop Scheduler UI and in the run's session history
(`goose schedule sessions --schedule-id <id>`) — look there whenever an expected email
does not arrive. Fallback-timer and manual `run-recipe.sh` runs additionally get the
watchdog's failure alert.

## Fallback: when the native scheduler misbehaves

**Known failure mode (goose 1.46, headless):** scheduled fires can create the
run's session and then never start the agent — the session sits at one
message (the prompt), no log file appears, no email arrives, and nothing
alerts (the native path has no watchdog). If you see that signature, don't
debug it — flip to the timers below; the wrapper path adds a real failure
alert on every run.


The scheduler has known bugs — background jobs running in chat mode and blocking tool
execution ([block/goose#3882](https://github.com/block/goose/issues/3882)) and Scheduler
UI timing/session-loading failures
([block/goose#5045](https://github.com/block/goose/issues/5045)). (These issue links use
the `block/goose` org where they were filed; goose has since moved to the Linux
Foundation's `aaif-goose` org, which the rest of this repo links to — both currently
serve the same project.) Symptoms: runs not
firing on time, runs hanging mid-tools, or the UI showing stale state.

The repo ships **disabled** systemd units: the template service
`scripts/vps/systemd/fallback/goose-recipe@.service` plus four timers —
`morning-brief.timer`, `inbox-triage.timer`, `weekly-review.timer`, and
`health-followups.timer` in the same directory, installed by deploy-vps.sh as
`goose-recipe@<id>.timer`. They drive the very same recipes through `run-recipe.sh` —
same models, same delivery (the recipes still email their own results), OS-grade
scheduling, no Goose scheduler involved, plus the watchdog's retry and failure alert.
`budget-checkin` has no fallback timer — it ships paused; if the native scheduler is
broken while you actually use it, add a timer modeled on the shipped four.

To flip one job to the fallback (on the brain):

```bash
# 1. stop the native trigger for that job
goose schedule remove --schedule-id inbox-triage

# 2. enable the shipped timer
sudo systemctl enable --now goose-recipe@inbox-triage.timer

# 3. confirm it's armed and watch a run
systemctl list-timers 'goose-recipe@*'
journalctl -u goose-recipe@inbox-triage.service -f
```

To flip everything at once:

```bash
for id in morning-brief inbox-triage weekly-review health-followups; do
  goose schedule remove --schedule-id "$id"
  sudo systemctl enable --now "goose-recipe@${id}.timer"
done
```

To revert once the bugs are fixed (check the issues above before upgrading Goose):

```bash
sudo systemctl disable --now goose-recipe@inbox-triage.timer
/home/agent/personal-ai-setup/scripts/vps/register-schedules.sh   # re-registers natively
```

Trade-off while on the fallback: runs still land in headless output and the emails
still arrive, but you lose the Scheduler UI dashboard view until you flip back. Timer
runs use `--no-session`, so inspect them via `journalctl` rather than session history.
