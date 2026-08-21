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
| `morning-brief` | `0 0 7 * * *` (daily 07:00) | zen-openai / `minimax-m2.7` | ntfy digest |
| `inbox-triage` | `0 0 9,13,17 * * MON-FRI` | zen-openai / `minimax-m2.7` | Gmail labels + drafts (**never auto-send**); ntfy only if action needed |
| `weekly-review` | `0 0 17 * * SUN` (Sun 17:00) | zen-openai / `kimi-k2.6` | self-addressed Gmail draft (**never sent**) + ntfy report |
| `health-followups` | `0 30 18 * * SUN` (Sun 18:30) | together / `Qwen/Qwen3.5-397B-A17B` | pulls, appends to, commits + pushes `/data/life-vault/health/appointments.md`; PHI-free push ("Health review ready: N items") |
| `vault-qa` | on-demand, not scheduled | together / `deepseek-ai/DeepSeek-V4-Flash-0731` | interactive session on the brain; developer extension only |
| `budget-checkin` | `0 0 9 1 * *` (1st of month, 09:00) | together / `openai/gpt-oss-120b` | ntfy summary vs `budget.md` — **disable after deploy** until you've picked a budgeting source |

`scripts/vps/register-schedules.sh` registers this whole roster idempotently and prints
`goose schedule list` when done. One caveat it announces loudly: goose 1.x has no
`schedule pause` CLI, so on a headless deploy `budget-checkin` registers **active**.
Pause it from the Desktop Scheduler UI once connected to the brain, or
`goose schedule remove --schedule-id budget-checkin` until you have a budgeting source —
its first fire would otherwise be the 1st of the month at 09:00.

## Adding a new automation, end to end

1. **Write the recipe** — copy the closest existing file in `recipes/` and edit. Keep the
   pinned model consistent with the routing table (sensitive data → `together`), keep the
   extension list minimal (each MCP server's tools cost context on every turn), include
   the developer extension, and have the recipe's explicit final step deliver via
   `scripts/common/notify.sh` — never a hand-rolled curl.

2. **Test it headless once**, exactly the way unattended runs execute:

   ```bash
   GOOSE_MODE=auto GOOSE_MAX_TURNS=50 GOOSE_CONTEXT_STRATEGY=summarize \
   GOOSE_DISABLE_SESSION_NAMING=true \
   goose run --recipe recipes/my-job.yaml --no-session --quiet --output-format json
   ```

   Or equivalently `scripts/common/run-recipe.sh recipes/my-job.yaml`, which sets that
   exact environment for you and adds the watchdog's retry + failure alerting (delivery
   still comes from the recipe's own notify.sh step). Headless runs
   can't answer prompts or ask clarifying questions — `GOOSE_MODE=auto` plus the turn cap
   is what keeps an ambiguous recipe from hanging or running away.

3. **Register the trigger** on the brain:

   ```bash
   goose schedule add --schedule-id my-job \
     --cron "0 0 8 * * *" \
     --recipe-source /home/agent/personal-ai-setup/recipes/my-job.yaml
   ```

   Better: add the same line to `scripts/vps/register-schedules.sh` (it's idempotent) so
   the roster stays reproducible, then re-run it.

4. **Confirm in the Scheduler UI** — open Goose Desktop (connected to the brain), find
   the schedule, hit run-now, and check that the push arrives and the run's session looks
   right. CLI equivalent: `goose schedule run-now --schedule-id my-job`, then
   `goose schedule sessions --schedule-id my-job`.

Day-to-day management: `goose schedule list` / `run-now` / `sessions` / `remove` on the
brain, or the Desktop Scheduler UI for pause/resume and history. Reference:
[Goose CLI commands](https://github.com/aaif-goose/goose/blob/main/documentation/docs/guides/goose-cli-commands.md).

## Delivery: an explicit notify step, plus a failure watchdog

Every scheduled recipe delivers its own notification — and the machinery around it is
built so that transport is a fixed script, never model improvisation:

- **`scripts/common/notify.sh` is the only path to ntfy.** It POSTs to
  `https://ntfy.sh/$NTFY_TOPIC` with the topic injected from the environment. Each
  scheduled recipe carries the developer extension and invokes notify.sh as its
  **explicit final step** (`/home/agent/personal-ai-setup/scripts/common/notify.sh`
  on the brain) with the finished summary — the recipe's instructions forbid any other
  shell/network use, so this stays the single choke point for the PHI-free push rule
  ([privacy.md](privacy.md)): `health-followups` pushes only the count line
  `Health review ready: N items`. One deliberate exception to "always notify":
  `inbox-triage` runs notify.sh only when action-needed items exist — otherwise it
  sends nothing and its final message is exactly `NO_ACTION_NEEDED`.
- **`scripts/common/run-recipe.sh` is a headless runner + failure watchdog** — it wraps
  the systemd fallback timers and manual tests, never the native-scheduler runs. It
  sets the canonical headless environment, runs the recipe, and on a nonzero exit
  retries ONCE after a 60-second sleep (a blind retry: Together's `x-ratelimit-reset`
  header is not visible through goose's exit status). Only after the retry also fails
  does it send a high-priority failure alert via notify.sh. It does **not** deliver
  success output — the recipe already did that itself; the final text is simply logged
  to stdout (journald keeps it on timer runs).

**Documented limitation:** on the native-scheduler path there is no wrapper, so a run
that crashes *before* its final notify step produces no push at all. That failure is
visible in the Desktop Scheduler UI and in the run's session history
(`goose schedule sessions --schedule-id <id>`) — look there whenever an expected push
does not arrive. Fallback-timer and manual `run-recipe.sh` runs additionally get the
watchdog's failure alert.

## Fallback: when the native scheduler misbehaves

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
same models, same delivery (the recipes still notify themselves), OS-grade scheduling,
no Goose scheduler involved, plus the watchdog's retry and failure alert.
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

Trade-off while on the fallback: runs still land in headless output and pushes still
arrive, but you lose the Scheduler UI dashboard view until you flip back. Timer runs use
`--no-session`, so inspect them via `journalctl` rather than session history.
