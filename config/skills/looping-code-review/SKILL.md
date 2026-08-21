---
name: looping-code-review
description: Iteratively run the multi-agent code review, apply only the smallest safe fixes without materially growing the MR, test, push, and re-review until the verifier confirms no true blockers remain. Use when the user asks to "loop on review", "review and fix until clean", "iterate until the MR is ready", or wants review findings fixed and re-verified on the current MR branch.
---

# Looping Code Review (Fix-Test-Push-Re-Review Loop)

Drive an MR branch to "ready" by repeating a tight loop: run the planned multi-agent `code-review` skill, have a triage subagent pick the smallest safe fixes from the latest findings, implement only those fixes, run focused tests and CI-style checks, commit and push to the current branch, then re-review. The goal is to resolve blockers without making the MR harder to review: hold or reduce its size whenever possible, prefer deletion or replacement over new abstractions, and enforce the growth budget below. Exit only when the verifier reports no true blockers and every remaining finding is a nit or an explicitly deferred follow-up.

This skill orchestrates; the underlying review mechanics live in the `code-review` skill (reviewers, verifier, output format) and the local CI mechanics live in the `ci-lint-test` skill. The plan-side analogue is `looping-plan-review`.

## When to use

- The user wants an MR branch iterated to mergeable quality, not just a one-shot review.
- A prior review produced findings and the user asked to "fix and re-check".
- The user explicitly asks for a looping/iterative review workflow.

Do NOT use this skill for reviewing an MR you don't own (use `mr-review`) or for a single advisory review (use `code-review` directly).

## Scope contract (read before the first iteration)

Establish scope once, up front, and hold it constant across iterations:

1. **The diff under review** is the current branch vs its target (usually `git diff main...HEAD` or the MR's target branch). New commits from this loop extend that diff; nothing else does.
2. **User-declared out-of-scope items stay out of scope.** If the user has excluded an area (e.g. Console/frontend changes, consumer-contract updates in another repo, deploy policy), reviewers may still flag it, but do NOT implement fixes there — record the finding as a deferred follow-up instead. The single exception: the finding independently breaks service-b behavior in the diff under review (e.g. the service-b change itself crashes or corrupts data regardless of the consumer). In that case fix the service-b side only.
3. **Broad perf, architecture, and deploy-policy findings are follow-ups, not loop work**, unless they are actively unsafe (data loss, security hole, guaranteed outage). "This could be restructured" or "this could be faster" never blocks the loop.
4. **Minimal changes** (per the `minimal-changes` rule in the global OpenCode rules, `~/.config/opencode/AGENTS.md`): no refactors, no renames, no "while I'm here" cleanups. Every commit in the loop must be traceable to a specific confirmed finding.

### MR size budget

Before iteration 1, record the target-branch diff's insertions and deletions and the
pre-loop HEAD. Keep this baseline fixed for the entire loop; never reset it after an
iteration.

```
baseline_changed_lines = baseline_insertions + baseline_deletions
growth_budget = min(200, max(50, ceil(baseline_changed_lines * 0.20)))
maximum_changed_lines = baseline_changed_lines + growth_budget
```

The budget applies to the final MR's total changed lines (insertions + deletions), not
only net additions. Also track the loop's net code growth:
`(current_insertions - current_deletions) - (baseline_insertions - baseline_deletions)`.
Target zero or negative net growth when a safe fix allows it.

This is a ceiling, not a quota. Deletions are preferred only when they directly resolve
a confirmed finding; unrelated deletion never creates credit for more work. Tests count
toward the budget and must not be omitted to fit it. If the smallest safe fix for a
blocker would exceed the ceiling, stop and get explicit user approval for that named
blocker and estimated final size before proceeding. Defer non-blocking findings that
would exceed it.

## The loop

Copy this checklist and track progress each iteration:

```
Iteration N:
- [ ] Step 1: Run planned multi-agent code review (review-only mode)
- [ ] Step 2: Check exit criteria — done?
- [ ] Step 3: Triage subagent picks smallest safe fixes
- [ ] Step 4: Implement only the selected fixes
- [ ] Step 5: Focused tests + CI-style checks
- [ ] Step 6: Commit and push to the current branch
- [ ] Step 7: Loop back to Step 1
```

### Step 1: Run the planned multi-agent code review

Invoke the `code-review` skill in **review-only mode**. Its mandatory
planning step selects reviewers, focus briefs, and any justified model elevations before review.

In addition to the current diff and changed files, pass:

- The current implementation plan, if one exists.
- User-declared out-of-scope areas and model preferences.
- The latest review/verifier summary, when this is iteration 2+.
- The fixed baseline, current changed-line count, net code growth, and remaining budget.

Always run the complete planned review plus verifier after every push, even if the last iteration
only changed one file. Skipping re-review misses regressions introduced by fixes.

Use only model IDs available in the current OpenCode setup (see `docs/model-routing.md`). Never
invent or silently substitute an unavailable model. Reviewer dispatch and fallback follow the
self-contained `code-review` skill.

### Step 2: Check exit criteria

Read the verifier-filtered summary. The loop is **done** when ALL of the following hold:

- The verifier confirms **zero true blockers** (no confirmed show-stopper bugs).
- Every remaining confirmed finding is either a **nit** or has been **explicitly deferred** as a follow-up (with the user's agreement or per the scope contract).
- The latest focused tests and CI-style checks pass on the pushed HEAD.
- The final target-branch diff is within the fixed MR size budget, unless the user
  explicitly approved an exception for a named blocker.

If done, go to **Wrap-up**. Otherwise continue to Step 3.

Anti-stall rule: if two consecutive iterations produce the same confirmed blocker with no viable minimal fix, or the only safe fix would exceed the MR size budget, stop looping and escalate to the user with the finding, why the minimal fix failed, the estimated final size, and the options — do not silently widen scope to force convergence.

### Step 3: Triage — decide the smallest safe fixes

Launch a **single general-purpose triage subagent** (the `general` agent via the task tool) on `opencode/kimi-k2.6` with:

- The current diff and changed file paths.
- The full verifier-filtered summary from Step 1 (confirmed findings, rephrased findings, rejected findings with reasons).
- The scope contract from this skill, including the user's out-of-scope declarations.
- The fixed baseline, current changed-line count, net code growth, and remaining budget.

The triage subagent must return, for each confirmed finding, exactly one of:

| Decision | Meaning |
|----------|---------|
| `fix-now` | Blocker or cheap correctness fix; include the smallest safe change that resolves it |
| `defer` | Real but out of loop scope (broad refactor, perf/architecture/deploy-policy, user-excluded area); record as follow-up |
| `nit-skip` | Nit not worth a commit this iteration (may batch with a fix-now touching the same file) |

For every `fix-now`, the triage output must state the concrete minimal change (file, function, what to edit) and estimated changed-line impact — not a rewrite plan. Prefer the fix that touches the fewest lines, has zero or negative net growth when practical, and introduces no new abstractions. If two findings share a root cause, one fix covers both. Mark a non-blocking fix `defer` when its estimate would exceed the remaining budget.

The main agent applies the triage decisions as-is unless a decision plainly violates the scope contract, in which case correct it and note the correction.

### Step 4: Implement only the selected fixes

Apply the `fix-now` changes exactly as scoped by triage. Rules:

- Touch only the files and lines the fixes require.
- Add or update tests when a fix changes behavior (per the pytest rule: happy path + one edge case).
- Do not fold in deferred findings, style cleanups, or opportunistic improvements.
- If a fix turns out to require a broader change than triage anticipated, stop, mark it `defer`, and surface it to the user rather than expanding scope.

After implementation and before testing or committing, recalculate the full target-branch
diff against the fixed baseline. If it exceeds `maximum_changed_lines`, shrink or defer
the selected fix. For a blocker with no smaller safe fix, stop for explicit user approval;
never commit or push an unapproved over-budget diff.

### Step 5: Focused tests and CI-style checks

Always test before pushing — never push unverified fixes.

1. **Focused tests first**: run the specific test files/tests covering the changed code (e.g. `poetry run pytest path/to/test_file.py -x`) in the affected repo.
2. **CI-style checks**: run the `ci-lint-test` skill for each changed repo — lint, format check, type check, then the relevant test suite.
3. Fix failures caused by your changes and re-run until clean. Environment-caused failures (missing secrets, unavailable services) may be reported as warnings, not silently ignored.

### Step 6: Commit and push

When the user asked for pushed updates, always push — do not accumulate local-only commits across iterations.

- Commit to the **current MR branch** (or current branch if no MR exists). Never switch branches, never amend, never force-push.
- One commit per logical fix (or one commit for a batch of small related fixes from the same iteration), using conventional commits (`fix: ...`, `test: ...`).
- Reference the finding in the commit body when it aids traceability.
- `git push` to the existing remote branch so the MR updates in place.

### Step 7: Repeat

Return to Step 1 and rerun the complete planned review against the updated branch.
Each iteration's summary should show strictly
fewer confirmed blockers and include the baseline, current size, net growth, and
remaining budget. If blockers do not decrease, apply the anti-stall rule from Step 2.

## Wrap-up

When the exit criteria are met, report to the user:

```
## Looping review complete — N iterations

**Final verdict**: <verifier verdict from the last review>
**Fixed this loop**: 
- <finding> — <commit SHA / short description>

**Deferred follow-ups** (agreed out of scope):
- <finding> — <why deferred, suggested ticket if warranted>

**Remaining nits** (left as-is):
- <finding>

**MR size**: <baseline changed lines> → <final changed lines>; <net code growth>;
<growth budget used>
**Verification**: <focused tests + ci-lint-test results on final HEAD>
```

Offer to file follow-up tickets for deferred findings (per the linear-tickets rule) but do not create them unprompted.

## Guardrails (hard rules)

- **No broad refactors, no scope creep.** Every change maps to a confirmed `fix-now` finding.
- **Do not materially grow the MR.** Keep the fixed baseline, prefer zero or negative
  net growth, and never exceed the growth budget without explicit user approval for a
  named blocker.
- **Don't implement broad perf/architecture/deploy-policy findings** unless actively unsafe — defer them.
- **Respect user-declared out-of-scope areas** (Console, consumer contracts, other repos) unless the service-b behavior in the diff is independently broken.
- **Always test before pushing**; always push when the user requested pushed updates.
- **Planner-selected review after every push** — never skip re-review because a fix "was small".
- **Never invent or silently substitute model slugs.**
- **Never amend or force-push**; new commits only.
