---
name: mr-review
description: >-
  Review a GitLab merge request end-to-end, or catch a reviewer up on MR status.
  Always opens with product overview, what the change does, and review-state
  summary; posts findings as unpublished draft notes. Use when reviewing a
  GitLab MR, given an MR link, or asking where an MR stands.
---

# GitLab MR Review

Review a GitLab MR and post **every** finding as an **unpublished draft note** written in the reviewer's voice. Draft notes are visible only to their author until published, so the reviewer edits and selectively publishes them in the GitLab UI. This skill never publishes drafts. Every run opens with an MR overview and review-state summary (Step 3); that summary alone is the deliverable when the user only asks where an MR stands.

## Dependencies

This skill hard-depends on a GitLab MCP and composes one other skill plus optionally one rule:

- **GitLab MCP (required)** — every MR read and draft-note write goes through a GitLab MCP exposing `get_merge_request`, `get_merge_request_diffs`, `mr_discussions`, `list_draft_notes`, `create_draft_note`, and `whoami` (e.g. `@zereight/mcp-gitlab`). Without one configured, this skill cannot run.
- **Code review skill** (`~/.agents/skills/code-review/SKILL.md`) — provides the review methodology, severity labels, checklists, and feedback format. Used in **review-only mode** (see Step 6) so it produces the curated summary without prompting for walkthrough or fix application. Read it before reviewing.
- **MR comment voice rule** (when available, e.g. in your global `AGENTS.md`) — defines the reviewer's preferred writing voice. Otherwise, use a concise, direct, professional tone.

## Review Priorities

These are the highest-priority areas. The code-review skill covers general correctness/security/performance, but **weight these six areas most heavily** — they represent recurring review feedback:

### 1. Pydantic over raw containers

- New structured data should use `pydantic.BaseModel`, not raw dicts, `TypedDict`, or `dataclasses`.
- `dataclasses.dataclass` is acceptable only for small internal containers with trusted inputs and no validation needs.
- Flag any new `TypedDict`, `NamedTuple`, or plain dict used where a Pydantic model would be clearer.

### 2. Use existing libraries / builtins instead of writing code

- If a standard library function, a Pydantic validator, or an already-imported third-party library can do the job, prefer that over hand-rolled logic.
- Common misses: reimplementing `itertools`, `collections`, `functools`, date math, URL parsing, retry logic that `tenacity` already provides, manual JSON schema that Pydantic generates for free.
- Flag custom utility functions that duplicate what a dependency already exposes.

### 3. DRY

- Same logic in multiple places with minor variations.
- Copy-pasted blocks (even with small tweaks).
- Magic strings/numbers repeated across files.
- Configuration values hardcoded in multiple locations.
- Similar conditionals checking the same thing in different ways.

### 4. SOLID

- **SRP**: Classes/functions doing multiple unrelated things.
- **OCP**: Adding features requires modifying existing code instead of extending.
- **DIP**: High-level modules directly instantiating low-level concrete classes.
- Focus on SRP and DIP — they're the most common violations.

### 5. Code placement

- New functions, classes, and methods should live in the module/file where they logically belong, not just wherever the author happened to be editing.
- Flag functions added to a file when they don't relate to that file's core responsibility. Ask: "Does this belong in `X` or would `Y` be a better home?"
- Common smells:
  - A utility/helper added to a domain-specific service file instead of a shared utils module.
  - A model method added to a service layer or vice versa.
  - Business logic stuffed into a route handler, callback, or serializer.
  - A function that only operates on data from module B but lives in module A.
- When the codebase already has a clear module structure, new code should follow it. If there's an existing `utils/`, `models/`, `services/` breakdown, new code should land in the right bucket.
- Consider cohesion: functions in the same file should be related. If a new function has no relationship to its neighbors, it probably belongs elsewhere.

### 6. Naming

- Names must be descriptive, intuitive, and self-documenting.
- Flag: single-letter vars outside short loops, type suffixes (`user_list`, `data_dict`), vague names (`handle`, `process`, `data`, `info`, `manager`, `utils`), abbreviations that aren't universally understood.
- Variable names should tell you what the value *represents*, not what type it is.
- Function names should tell you what they *do*, not how they do it.

## Workflow

### Step 1: Fetch the MR and understand product purpose

Extract `project_id` and `merge_request_iid` from the GitLab URL or user input.

```
GitLab URL pattern: https://gitlab.com/{group}/{project}/-/merge_requests/{iid}
→ project_id = "{group}/{project}", merge_request_iid = "{iid}"
```

Fetch in parallel:

1. **MR details** — `get_merge_request` tool (need `diff_refs` for inline comments, and the **description** for product purpose)
2. **MR diffs** — `get_merge_request_diffs` tool (exclude `poetry.lock`, `package-lock.json`, etc.)
3. **Existing discussions** — `mr_discussions` tool (avoid duplicating existing feedback)
4. **Authenticated GitLab identity** — `whoami` tool (token identity only — see "Resolve the human reviewer" below)
5. **Approval state** — call `get_merge_request_approval_state` only if `get_merge_request` does not already supply enough for the Step 3 snapshot (approvals given + whether rules are unmet). Prefer the dedicated tool when rule/approver detail is needed.
6. **Pipelines** — `list_merge_request_pipelines` tool; take the latest by `created_at` or `id`

Page `mr_discussions` until exhausted (`per_page` 100, increment `page`) before building any thread inventory. Do not stop at the first page.

Save `diff_refs.base_sha`, `diff_refs.head_sha`, `diff_refs.start_sha` — required for inline comments.

#### Understand product purpose

Read the MR title and description carefully. Extract:

- **What product/user problem is this solving?** Look for Problem/Why sections, linked tickets, or the title.
- **What is the intended behavior change?** Look for Fix/What/How sections or infer from the description.
- **What constraints or context shaped the approach?** Look for mentions of deadlines, backward compatibility, deployment order, or technical debt.

Summarize the product purpose in 1-2 sentences. This understanding drives the overview in Step 3 and the alternative-approaches analysis in Step 4. Keep this summary — you will present it to the user in Step 3.

If the MR description is empty or unclear, note this as a finding (the MR should document its purpose). Still infer the purpose from the code changes as best you can.

#### Resolve the human reviewer (lazy)

`whoami` returns the identity of the **GitLab MCP token**, not necessarily the person asking for the review. Cloud agents, CI bots, and shared PATs often authenticate as a bot or unrelated account.

**Lazy resolution.** Product overview, what-it-does, and MR snapshot never require `reviewer_username`. Resolve identity only when needed for: the "Your comments" table, Step 7 dedupe against the reviewer's threads, or posting draft notes.

When identity is needed, resolve `reviewer_username` in this order and **stop at the first match**:

1. **User override** — if the user already named whose review this is (e.g. "review as your-username"), use that username.
2. **Non-bot `whoami`** — use the `whoami` username if it is not a bot/service account. Treat as bot when `bot: true` (if exposed) **or** username/name matches `/bot|service_account|cursor|renovate|coderabbit|incident/i`. Prefer this over MR-reviewer auto-pick even if the user is not yet listed on the MR.
3. **Single human MR reviewer who authored notes** — if the MR has exactly one non-bot entry in `reviewers` **and** that username authored at least one non-system discussion note, use that username. Do not auto-pick a reviewer who has never commented.
4. **Ask** — only if personal threads / drafts still need a username; ask and wait. Do not Ask solely to build the product overview or MR snapshot.

Bot detection for discussion authors / reviewers uses username/name heuristics (GitLab reviewer objects often omit `bot: true`).

#### Posting identity hard-stop

Draft notes are private to the **authenticated token** author until published. Before any `create_draft_note` (Step 9):

1. State in the report (and before posting): `reviewer_username` (or "unresolved") and `posting_username` from `whoami`.
2. If `posting_username` is a bot/service/shared account, **do not call `create_draft_note`**. Tell the user drafts would land under that account and ask them to switch the GitLab MCP to a human token, or to explicitly confirm "post under bot anyway."
3. If drafts were already created under the wrong author in a prior run, clean up with `list_draft_notes` / `delete_draft_note` under that same token.

Use `reviewer_username` (not raw `whoami`) everywhere Step 3/7 refer to "your comments."

### Step 2: Check out the MR branch locally

Before reading code, check out the MR's source branch so all file reads reflect the actual changes:

1. **Identify the repo** — Determine which repo(s) the MR belongs to based on the `project_id` (e.g., `service-b/`, `service-a/`, `shared/`).
2. **Fetch and checkout** — In the relevant repo directory:
   ```
   git fetch origin <source_branch>
   git checkout <source_branch>
   ```
   The source branch name is available from the MR details (`source_branch` field).
3. **Verify** — Confirm the checkout succeeded and HEAD matches the MR's `head_sha`.

If the checkout fails (e.g., branch not found locally), fall back to fetching by the head SHA:
```
git fetch origin <head_sha>
git checkout <head_sha>
```

After the review is complete, remind the user that the repo is now on the MR branch and they may want to switch back.

### Step 3: Present the MR overview and review state

**This step always runs** — it produces the first thing the user sees, and it is the complete deliverable when the user only asked for an overview or status catch-up rather than a full review. Delegate code reading to read-only researcher subagents (e.g. `researcher-lite`); keep this step fast. Do not Ask for identity before presenting product overview + MR snapshot.

Classify the run as a **re-review** when **any** of these hold; otherwise **first review**:

- `reviewer_username` is known and authored at least one non-system discussion note, **or**
- the authenticated token already has unpublished draft notes on this MR, **or**
- the user explicitly asked for catch-up / re-review / "where is this MR at" after a prior review

Do **not** treat "any human discussion thread" (e.g. the author's notes) as re-review by itself.

#### 3a. Build the overview (every run)

- **Product overview** — what the MR is about, the problem it solves, and why it's needed from a product standpoint. Build on the Step 1 product-purpose summary; when the description is thin, pull from the linked ticket.
- **What it does** — a short walkthrough of the change read from the checked-out branch: modules touched, new endpoints/tasks/models/migrations, and the end-to-end flow.
- **MR snapshot** — state, `detailed_merge_status`, approvals, `blocking_discussions_resolved`, latest pipeline status, `diverged_commits_count` behind target, last activity date.

#### 3b. Summarize the review so far (only when `reviewer_username` is known and this is a re-review)

Resolve identity now if not already resolved (lazy rules in Step 1). If identity cannot be resolved without Ask and the user only wanted status, omit this subsection and note that personal thread catch-up needs a username.

- **Prior threads** — threads authored by `reviewer_username`: the original ask, resolved/unresolved, and **how the fix was actually implemented** — verified against the checked-out branch code, not just the author's reply text.
- **Assessment** — one short judgment per thread: fix is good / pushback is reasonable / fix is incomplete or left unanswered.
- **What changed since the last review** — commits pushed after the reviewer's last review activity and what they touch.

Keep this thread inventory — Step 7 uses it to avoid duplicate comments. Page `mr_discussions` to exhaustion before building it.

#### 3c. Present and route

Present in this format (omit "Your comments" / "What changed" unless 3b ran):

```
**Verdict:** <one line: overall state — who or what is blocking, and what happened since last look>

**Identity:** reviewer=<reviewer_username or unresolved> posting=<whoami username>

### MR snapshot
<table: state, merge status, approvals, blocking discussions, pipeline, commits behind target, last activity>

### Product overview
<what the MR is about, what it does, why it's needed>

### Your comments → status   (only if 3b ran)
<table: # | your ask | status | how it was fixed | take on the fix>

### What changed since your last review   (only if 3b ran)
<bullets: commit → what it touches>

### What's left for you
<numbered list of concrete next actions>
```

Then route:

- **First review** — continue directly to Step 4; its gate is the pause point.
- **Re-review — Full re-review** — run Steps 5–10 on the whole MR; **skip Step 4** (alternatives gate) unless Step 3 flagged an approach-level risk.
- **Re-review — Review only what changed** — run Steps 5–10 scoped to commits since the last review round; skip Step 4 unless the approach itself changed.
- **Re-review — Stop here** — the overview was the goal; skip to Step 10 using the **overview-only report** (no draft counts, no publish reminders; still remind which repo is on the MR branch).
- On re-review, ask once how to proceed (full / only-changed / stop) and **do not proceed until the user responds**. Do not add a second pause at Step 4 after "full re-review."

### Step 4: Evaluate alternative approaches (gate)

**This step runs before the detailed code review.** If the overall approach is wrong, a line-by-line review is wasted effort.

#### 4a. Read changed files at a high level

Read the full changed files from the local repo (now on the MR branch) to understand *what* the MR does and *how* it accomplishes it. You don't need to trace every caller yet — focus on grasping the shape of the change: which modules are touched, what abstractions are introduced or modified, and what the end-to-end flow looks like.

#### 4b. Analyze alternative approaches

Using the **product purpose** from Step 1 and the high-level understanding from 4a, consider whether the same goal could have been achieved differently. Evaluate each of these lenses:

- **Configuration over code** — Could the behavior change be driven by a config/feature flag, database setting, or environment variable instead of a code change?
- **Existing abstractions** — Does the codebase already have a mechanism that could handle this (an existing hook, plugin system, event handler, middleware, etc.)?
- **Simpler implementation** — Could fewer files be touched, fewer abstractions introduced, or a more straightforward approach accomplish the same thing?
- **Different layer** — Would this be better handled at a different layer (e.g., database constraint instead of application validation, API gateway instead of per-service logic, frontend instead of service-b)?
- **Avoiding the change entirely** — Is there a reason the existing behavior is actually correct and the change is unnecessary?

Only surface alternatives that are **concretely better** (simpler, safer, more maintainable, or more consistent with existing patterns). Do not raise alternatives just for the sake of it.

#### 4c. Present to the user and wait

Present any alternative approaches to the user (product purpose was already shown in Step 3). Format:

```
### Alternative approaches
<If none: "No better alternatives identified — the approach looks reasonable. Proceeding with detailed review.">

<If alternatives exist, list each one:>
**Alternative [N]: <short title>**
<What the alternative is, why it's better, and any trade-offs.>
```

Then ask the user how to proceed:

- **Continue with review** — the current approach is fine, proceed to the detailed code review (Step 5+)
- **Stop — will request a rewrite** — the user will ask the MR author to take a different approach; skip the rest of the review
- **Continue but include alternative as a comment** — proceed with the detailed review and include the alternative approach as a general MR comment in the findings

**Do not proceed to Step 5 until the user responds.** If the user chooses to stop, skip to Step 10 (report) and remind them which repo is on the MR branch.

If the user already chose Full re-review in Step 3c, skip this gate and continue to Step 5 unless Step 3 flagged an approach-level risk.

### Step 5: Gather deep context

For each changed file, read as much surrounding code as needed to **fully understand the changes and verify correctness**. The goal is to catch bugs, broken flows, and incorrect assumptions — not just style issues. Since the MR branch is checked out locally (Step 2), all file reads will reflect the MR's actual state.

#### 5a. Read the full changed files

If you already read the full files in Step 4a, you can skip re-reading them. Otherwise, read the **entire** version of each changed file from the local repo (now on the MR branch), not just the diff hunks. You need the full picture to understand how the changes fit in.

#### 5b. Trace callers and callees

For every function/method/class that was **modified, added, or has a changed signature**:

- **Search for all callers** of that function across the codebase. Verify each call site is still correct after the change (argument order, new required params, changed return type, removed fields, etc.).
- **Read the functions it calls** to understand downstream effects. If the change alters what data flows into a downstream function, read that function to verify it still works.
- **Check imports** — if the MR adds/removes/renames exports, search for every file that imports them.

#### 5c. Trace data flow for changed models/types

If the MR changes a Pydantic model, dataclass, TypedDict, dict shape, or function return type:

- Search for every place that type is constructed, consumed, serialized, or deserialized.
- Check that all consumers handle the new shape (new fields, removed fields, type changes, Optional→required or vice versa).
- Pay special attention to API boundaries — if data crosses service boundaries, check the consumer-first deploy rules: if the change alters API response shapes, verify all consumers handle both old and new shapes during rollout.

#### 5d. Understand the broader flow

Read enough of the codebase to understand the end-to-end flow the changes touch. If a function is part of a request handler chain, read the full chain. If it's part of a background task pipeline, read the pipeline. The point is to verify:

- No existing code paths break due to the changes.
- Edge cases in the existing flow are still handled.
- The change is consistent with how the rest of the system works.

### Step 6: Review using code-review in review-only mode

Follow the code-review skill (`~/.agents/skills/code-review/SKILL.md`) in **review-only mode**: run the full reviewer + verifier + curated summary flow, then halt before any walkthrough or fix prompt. mr-review takes those findings and posts them as draft notes rather than applying them.

Signal review-only mode explicitly when invoking code-review so the orchestrator picks the halt-after-summary path:

1. Pass the MR diff and changed file paths as the review target, plus the **Review Priorities** above (Pydantic, builtins/libraries, DRY, SOLID, code placement, naming) and the **product purpose summary** from Step 1 as invocation context.
2. If the user chose "continue but include alternative as a comment" in Step 4c, include the alternative approach as a general finding in the results.
3. The code-review skill returns the curated summary with findings under Show-stopper bugs / Architectural concerns / Smaller suggestions / Nits. Map these to severity labels for posting: Show-stopper bugs → `blocker`, Architectural concerns → `blocker` or `suggestion` per impact, Smaller suggestions → `suggestion`, Nits → `nit`. Questions to clarify intent → `question`. **Do not collect or post `praise` comments** — skip any "this looks good" or positive-only findings.
4. For each finding, classify it as either:
   - **Line-specific**: tied to a particular file and line number → will become an inline diff comment.
   - **General**: applies to the MR as a whole (e.g., architectural concern, alternative approach, missing test coverage across files, cross-cutting pattern issue) → will become a non-positional MR note.

### Step 7: Check for existing comments

Before drafting anything, compare findings against existing MR discussions. **Do not** surface issues already covered by existing threads (from you or others). Use `reviewer_username` (resolved lazily per Step 1) and the thread inventory from Step 3 — compare findings against that inventory instead of re-fetching discussions. Do not re-call `whoami` here for identity. Also list existing draft notes (`list_draft_notes`) — a previous review run may have left drafts, and duplicating them would clutter the reviewer's queue.

### Step 8: Write comments in the reviewer's voice

Apply the active MR comment voice rule when available. Otherwise, use a concise, direct, professional tone. **Every comment must be written in the reviewer's voice** — the exact text gets posted as a draft note, and anything the reviewer publishes without editing goes out under their name, so each comment must be publish-ready as written.

#### Never blame people

Be direct about problems and history, never about people.

- When explaining why code ended up a certain way, cite the **commit SHA**, ticket, or architectural motivation — not the author.
- Do not write "`abc123` (alice) did X", "alice's refactor", or similar. The person is irrelevant to whether the change is safe now.
- Same rule for praise-framed blame ("alice probably intended…") and for MR authors under review: critique the diff, not the person.

#### Credit agent work as "AI"

When disclosing that an agent did research or scanning, say **AI** — never a model
or codename ("fable", "claude", "grok", etc.). Prefer "i had AI dig into…" / "i had AI
scan…" / "i had AI sweep…". This overrides any voice-guide examples that still say
"fable".

### Step 9: Post all findings as draft notes

Post **every** finding as a draft note using `create_draft_note` — no selection step, no asking which to post. Draft notes are unpublished: they are visible only to their author in the GitLab UI, where the reviewer edits, deletes, and publishes the ones they want to send.

**Before any `create_draft_note`, apply the posting-identity hard-stop from Step 1.** Do not post under a bot/service/shared token unless the user explicitly confirms "post under bot anyway."

**Never publish the drafts.** Do not call `bulk_publish_draft_notes` or `publish_draft_note`, and do not submit a review state (request changes / approve). Publishing is the reviewer's decision, made in the GitLab UI.

- **Inline diff comments** (with position): Post one draft per line-specific finding.
- **Overall MR note** (no position): Post a draft **only** for general (non-line-specific) findings. Do **not** post a summary-only note that just recaps inline comments.

For inline comments on **added lines**:

```json
{
  "position": {
    "base_sha": "<from diff_refs>",
    "head_sha": "<from diff_refs>",
    "start_sha": "<from diff_refs>",
    "position_type": "text",
    "new_path": "<file path>",
    "old_path": "<file path>",
    "new_line": <line number in new file>,
    "old_line": null
  }
}
```

For comments on **deleted or context lines**, use `old_line` instead and set `new_line` to null.

Calculate `new_line` from the diff hunk header: `@@ -old_start,old_count +new_start,new_count @@`. Count lines from `new_start`, incrementing for context lines (no prefix) and added lines (`+` prefix), skipping deleted lines (`-` prefix).

### Step 10: Report to user

Report depends on how the run exited:

- **Overview-only exit** (user chose Stop here, or asked only for status): report identity line, that no drafts were created, repo/branch reminder. Do not list draft findings or publish reminders.
- **Full review exit**: existing draft-note summary (counts, severity labels, publish reminder, repo/branch reminder). If posting was hard-stopped for a bot token, say so and list that zero drafts were created.

For a full review exit, summarize the drafts created:

- How many draft notes were created
- Each finding with its **severity label** (`blocker`, `suggestion`, `nit`, `question`), file/line (or `[general]`), and a brief summary — so the reviewer can triage in the GitLab UI knowing what to expect
- Link to the MR (drafts appear in the MR's Changes/Overview tabs, visible only to their author)
- Remind the reviewer that nothing is published — they edit, delete, and publish drafts from the GitLab UI
- If there were no findings, tell the user the MR looks clean and that no drafts were created
- **Reminder**: the repo is now on the MR branch — mention which repo and branch so the user can switch back if needed

## Iteration (optional)

If the user asks to re-review after the author pushes fixes:

1. Pull latest on the MR branch (`git pull origin <source_branch>`) and re-fetch MR details, diffs, discussions (paged to exhaustion), and pipelines (head_sha will have changed)
2. Re-run Step 3 — its review-so-far summary identifies resolved findings and what changed since the last round
3. List existing draft notes (`list_draft_notes`) and delete drafts (`delete_draft_note`) that the new code makes obsolete
4. Review per the user's routing choice in Step 3c (full re-review skips Step 4 unless approach risk)
5. Post new findings as draft notes only after the posting-identity hard-stop (same Step 9 flow) and report as in Step 10

## Line Number Calculation

Given a diff hunk `@@ -old_start,old_count +new_start,new_count @@`:

```
new_line_counter = new_start

For each diff line:
  if line starts with ' ' (context): new_line_counter += 1
  if line starts with '+' (added):   new_line_counter += 1  ← use this value for new_line
  if line starts with '-' (deleted): skip (don't increment new_line_counter)
```

## Notes

- Always exclude lock files from diffs (`poetry.lock`, `package-lock.json`, `yarn.lock`)
- Check for the current reviewer's existing comments using `reviewer_username` from Step 1 before posting to avoid duplicates
- When the MR is in a multi-repo workspace, read existing code from the repo path (which is on the MR branch after Step 2)
- If the MR touches API response shapes, check the consumer-first deploy rules: if the change alters API response shapes, verify all consumers handle both old and new shapes during rollout
- After the review, the repo will be on the MR branch — always remind the user in Step 10
- Draft notes stay private to their author until published — never call `bulk_publish_draft_notes` or `publish_draft_note`
