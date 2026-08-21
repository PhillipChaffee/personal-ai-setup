---
name: looping-plan-review
description: >-
  Two-phase plan review loop: architecture alignment with the user, then
  implementation convergence until Approve. Use when the user asks to loop on
  plan review, align architecture before implementing, or when the ship skill
  runs its plan_review phase.
---

# Looping Plan Review (Architecture Align → Implementation Converge)

Drive a plan to "ready" in two phases:

1. **Phase 1 — Architecture alignment**: review placement, naming, product-goal fit, and
   system fit; gate with the user until they declare aligned (or auto-ack once in
   fully-autonomous mode when the verdict is not Questions Only / unclear goal).
2. **Phase 2 — Implementation convergence**: mirror `looping-code-review` for plans —
   review-only plan-review → triage → `pr-implementer` → re-review until Approve with zero
   blockers.

This skill orchestrates; review mechanics live in the `plan-review` skill.
The plan-side analogue of `looping-code-review`.

## When to use

- The user wants architecture aligned before implementing a plan.
- The user asks to "loop on plan review", "align the plan architecture", or "iterate until
  the plan is ready".
- The `ship` skill runs its `plan_review` phase.

Do NOT use this skill for code MR loops (use `looping-code-review`) or a single advisory
plan review (use `plan-review` directly).

## Scope contract (read before Phase 1)

Establish scope once, up front, and hold it constant across both phases:

1. **The plan under review** is the resolved plan file (or pasted text written to a path).
   Loop edits extend that plan only; nothing else.
2. **User-declared out-of-scope items stay out of scope.** Reviewers may still flag them;
   record as deferred follow-ups. Exception: a finding that makes the plan itself invalid
   (broken AC, impossible ordering, missing mandatory plan-steps sections) — fix the plan
   text only.
3. **Broad restructuring / rollout redesign findings are follow-ups** unless the plan is
   actively unsafe (wrong deploy order causing outage, missing AC).
4. **Minimal changes**: every plan edit maps to a confirmed finding. No opportunistic
   rewrites.

### Plan length budget (Phase 2)

Before Phase 2 iteration 1, record `plan_baseline_lines` (line count of the plan file).
Keep this baseline fixed for the entire Phase 2 loop.

```
growth_ceiling = max(1.5 × plan_baseline_lines, 200)
```

Current plan length must stay within `growth_ceiling`. Prefer zero or negative net growth
when a safe fix allows it. If the smallest safe fix for a blocker would exceed the ceiling,
stop for explicit user approval (non-FA) or abort with `stop_reason` (FA).

## Ship mode gates

| Mode | Phase 1 | Phase 2 |
|------|---------|---------|
| `plan-gated` / `continue-after-plan` | Gate each iteration until user says aligned | Strategic escalations pause for user |
| `fully-autonomous` | One non-interactive pass; auto-ack only when not Questions Only / unclear goal | Auto tactical loop until Approve or anti-stall; Questions Only hard-stops |

When invoked outside `ship`, treat the session like `plan-gated` (interactive Phase 1)
unless the user explicitly requests autonomous mode.

## Phase 1 — Architecture alignment

Copy this checklist each iteration:

```
Phase 1 iteration N:
- [ ] Step 1: Run plan-review in review-only + architecture-alignment mode
- [ ] Step 2: Present alignment proposal (placement, naming, product goal, system fit)
- [ ] Step 3: Human gate — aligned? / feedback? / clarify product goal?
- [ ] Step 4: Apply feedback and loop to Step 1, or encode alignment and exit Phase 1
```

### Step 1: Architecture-focused review

Invoke the `plan-review` skill in **review-only** and
**architecture-alignment** mode. Pass the full plan text, user out-of-scope areas, and prior
Phase 1 feedback when re-running.

### Step 2: Alignment proposal

Synthesize a scannable proposal covering:

1. **Placement + naming** — where code will live; proposed names (Reader Test).
2. **Product-goal fit** — whether the planned fix solves the stated problem. If the goal is
   ambiguous, **pause and ask clarifying questions** before proposing alignment.
3. **System fit** — how the change sits in service-b / service-a / shared / existing patterns.

Include confirmed blockers and structural findings from the review. Questions Only or unclear
product goal → do not declare Phase 1 complete.

### Step 3: Human gate

- **plan-gated / continue-after-plan / interactive**: wait until the user declares the
  architecture aligned (or equivalent), or gives feedback / answers clarifying questions.
  If the user refuses, abandons, or otherwise cannot align, set
  `stop_reason: phase1_alignment_unreachable` and hard-stop — do **not** set
  `phase1_aligned` or enter Phase 2 (ship maps this to impossible-progress).
- **fully-autonomous**: run Phase 1 once; do not wait. If the Phase 1 verdict is
  **Questions Only** or the product goal is still unclear, set `stop_reason` and hard-stop —
  do **not** set `phase1_aligned` or enter Phase 2. Otherwise set
  `phase1_aligned: {at, acker: fully-autonomous}` in run-state / `decisions[]` and continue
  to Phase 2.

### Step 4: Apply feedback or encode outcomes

- **Feedback / clarifying answers** (interactive modes): apply the edits to the plan, then
  **return to Step 1** for another architecture-alignment pass. Do **not** enter Phase 2 until
  the user declares aligned (or FA auto-ack is allowed under Step 3).
- **Aligned** (user declared, or FA set `phase1_aligned` under Step 3): if the user declared
  aligned, set `phase1_aligned: {at, acker: user}` in run-state / `decisions[]` (FA already
  wrote its acker in Step 3). Write alignment decisions into the plan as **executable
  Design/Changes constraints** (concrete paths, names, diagrams) — not “why we decided” prose
  (`clean-plan` strips rationale). Then enter Phase 2.

Track `looping_plan_iterations.phase1`.

## Phase 2 — Implementation convergence

```
Phase 2 iteration N:
- [ ] Step 1: Run plan-review in review-only mode (full planner roster)
- [ ] Step 2: Check exit criteria — done?
- [ ] Step 3: Triage subagent picks smallest safe fixes
- [ ] Step 4: pr-implementer applies only fix-now tactical edits
- [ ] Step 5: Plan-structure check (plan-steps when applicable)
- [ ] Step 6: Commit plan edits when pushes were requested
- [ ] Step 7: Loop back to Step 1
```

### Step 1: Full plan review

Invoke `plan-review` in **review-only mode** (not architecture-alignment). Pass prior
verifier findings on re-review, baseline line count, remaining budget, and out-of-scope list.
Always re-run the full planned review after every plan edit.

### Step 2: Exit criteria

Phase 2 is **done** when ALL hold:

- Curated verdict is **Approve** with **zero confirmed blockers**.
- Every remaining confirmed finding is a **nit** or an **explicitly deferred non-blocker**
  (deferred blockers do not satisfy exit — fix-now, escalate, or abort).
- Plan length is within `growth_ceiling` (or user approved an exception).
- Latest plan-structure check passed.

If done, go to **Wrap-up**. Otherwise continue.

**Anti-stall**: same confirmed blocker across two consecutive iterations with no viable
tactical fix, or only safe fix exceeds budget → escalate to the user (non-FA) or abort with
`stop_reason` (FA). Do not silently widen scope.

**Questions Only**: hard-stop in all modes (including FA) — do not auto-answer open questions.

### Step 3: Triage

Launch a single general-purpose triage subagent (the `general` agent via the task tool) on
`opencode/kimi-k2.6` with the plan diff vs Phase 2 baseline, verifier-filtered summary, scope
contract, and budget.

For each confirmed finding, return exactly one of:

| Decision | Meaning |
|----------|---------|
| `fix-now` | Blocker or cheap correctness fix; include the smallest safe plan edit |
| `defer` | Real but out of loop scope; record as follow-up |
| `nit-skip` | Nit not worth an edit this iteration |

For every `fix-now`, state the concrete minimal change (section, AC id, exact edit) and
estimated line impact. Prefer fewest lines and zero/negative net growth.

### Step 4: Implement via pr-implementer

Launch the **pr-implementer** agent with only the `fix-now` findings.
Do not fold in deferred findings or opportunistic improvements.

On `STRATEGIC_ESCALATION`:

- **Non-FA**: pause for the user; do not silently rewrite approach/architecture. If the
  resolution changes approach/architecture, clear `phase1_aligned`, re-enter Phase 1, and
  require a fresh alignment before Phase 2 continues.
- **FA**: hard-stop as impossible-progress (`stop_reason: STRATEGIC_ESCALATION`). Do **not**
  auto-adopt approach/architecture changes in Phase 2 — that requires re-entering Phase 1 with
  a human (or a fresh FA Phase 1 after the user changes mode/scope).

Recalculate plan length against `growth_ceiling` before committing. Shrink or defer if over
budget unless the user approved the named blocker.

### Step 5: Plan-structure check

If the plan is an implementation plan, verify plan-steps essentials are still present
(Acceptance Criteria checklist; verify-AC / final CI / pre-MR / push steps when those were in
scope). Fix structural regressions as `fix-now` in the next iteration if missing.

### Step 6: Commit

When the caller requested pushed updates (e.g. `ship` run-state branch):

- Commit plan file edits on the current branch. Never amend, never force-push.
- One commit per logical fix batch; conventional commits (`fix(plan): ...`).
- Push when the caller asked for remote updates.

### Step 7: Repeat

Return to Phase 2 Step 1. Track `looping_plan_iterations.phase2`. Each iteration should show
strictly fewer confirmed blockers when progress is possible.

## Wrap-up

When Phase 2 exit criteria are met, report:

```
## Looping plan review complete — Phase 1: N iterations, Phase 2: M iterations

**Final verdict**: <Approve / ...>
**Phase 1 aligned**: <user | fully-autonomous> at <time>
**Fixed this loop**:
- <finding> — <commit SHA / short description>

**Deferred follow-ups**:
- <finding> — <why deferred>

**Remaining nits**:
- <finding>

**Plan size**: <baseline lines> → <final lines>; growth ceiling <ceiling>
**Verification**: <plan-structure check + last review-only summary>
**Constraints encoded**: confirm Phase 1 outcomes live in Design/Changes steps (not prose)
```

Offer to file follow-up tickets for deferred findings but do not create them unprompted.

## Guardrails (hard rules)

- **No broad plan rewrites** outside triage-selected `fix-now` edits (Phase 2) or explicit
  Phase 1 user feedback.
- **Do not materially grow the plan** past the length budget without approval.
- **Respect user out-of-scope** unless the plan is internally invalid.
- **Always re-run full review-only plan-review** after every Phase 2 edit.
- **Never invent or silently substitute model slugs.**
- **Never amend or force-push.**
- **Encode Phase 1 decisions as executable constraints** before clean-plan runs.
