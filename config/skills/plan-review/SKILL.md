---
name: plan-review
description: >-
  Plan and perform thorough plan and design reviews using a planner, parallel
  specialized subagents, and a verifier. Use when reviewing technical designs,
  architecture proposals, implementation plans, or when the user asks for
  plan/design feedback. Supports review-only and architecture-alignment modes
  for loop callers such as looping-plan-review.
---

# Plan Review (Multi-Agent Orchestrator)

Run a comprehensive plan review by planning reviewer dispatch, launching the selected
specialized reviewers in parallel, filtering their findings through a verifier subagent,
then producing a curated summary. The user can reply freeform with decisions, ask to walk
through blockers one at a time, and optionally hand accepted fixes to an implementer
subagent that edits the plan in place. Includes **review-only** and
**architecture-alignment** modes for callers (e.g. `looping-plan-review`).

## Target Resolution

Determine what plan to review:

1. **User specifies file** — read that file
2. **User pastes plan** — use the pasted content
3. **Open markdown/doc file** — review that document
4. **Conversation context** — review the plan discussed in conversation

Gather the full plan text before launching subagents.

## Calibration reference

A well-scoped plan is ~100 lines with self-contained Problem / Design / Changes / Non-goals /
Validation sections. Reviewers should not flag a plan in that shape as "missing Success
Criteria" or "missing Observability" subsections — those concerns are only worth surfacing
when something is actually wrong, not when a section header is absent.

## Planning (mandatory)

Before launching reviewers, run exactly one **Plan Review Planner** subagent.

The planner runs on `opencode/claude-sonnet-5` — reviewer dispatch is a deep-reasoning
call, and the model is pinned in `pr-planner`'s frontmatter. Launching agents by name is
all the model selection this skill ever does; every reviewer's model is pinned the same
way.

Pass the planner the full plan text, change purpose, user priorities, scope constraints, prior
verifier findings when re-reviewing, and any mode hint (`architecture-alignment` or full
review). It returns the selected reviewer set, focus briefs, verifier instructions, and flags
for domains that need extra depth on this plan — which reads as: make sure the deep-tier
reviewers (`pr-adversarial`, `pr-architecture`) are in the selected set. Cross-service
contracts, irreversible schema/deploy sequencing, auth or security boundaries, or a strategic
rethink where premises are ambiguous all point that way.

Selection hints for the planner:

- Treat **Organization** as a default pick when the plan adds files, moves symbols, or
  introduces helpers, dataclasses, or enums.
- Treat **Naming** as a default pick when the plan introduces or renames public symbols,
  modules, or API fields.
- In **architecture-alignment** mode, prefer Architecture, Organization, Naming, Problem &
  Scope, Adversarial, and Simplification (see planner agent).

Dispatch the planner via the task tool as the `pr-planner` agent. If unavailable, use `general`
with `~/.config/opencode/agents/pr-planner.md` inlined.

## Reviewers

Launch the planner-selected reviewers in one message using parallel task tool calls. Pass each
reviewer the full plan text and its planner-authored focus brief.

The reviewers are global OpenCode agents in `~/.config/opencode/agents/`:

| Agent | File | Domain |
|-------|------|--------|
| Problem & Scope | `pr-problem-scope.md` | Clarity, success criteria, scope boundaries |
| Adversarial | `pr-adversarial.md` | Premises, hidden assumptions, strategic pre-mortem |
| Architecture & Design | `pr-architecture.md` | Structure, coupling, contracts, system fit |
| Organization | `pr-organization.md` | File/folder/symbol placement in the planned change |
| Naming | `pr-naming.md` | Identifier and module naming in the planned change |
| Simplification & Maintainability | `pr-simplification.md` | Over-engineering, reuse misses, plan bloat |
| Technical Feasibility | `pr-feasibility.md` | Soundness, alternatives, hidden prerequisites |
| Risk & Rollback | `pr-risk-rollback.md` | Failure modes, mitigations, blast radius, observability |
| Completeness & Sequencing | `pr-completeness.md` | Step ordering, dependencies, validation checkpoints |

Each reviewer:

- Is read-only (`permission` with `edit: deny` — cannot modify files)
- Returns structured findings or a clean verdict
- The Feasibility agent may read codebase files to verify plan assumptions

Reviewers run on the models pinned in their agent frontmatter — `opencode/kimi-k2.6` for
the seven structural reviewers (Problem & Scope, Feasibility, Risk & Rollback,
Completeness, Organization, Naming, Simplification), `opencode/claude-sonnet-5` for
`pr-adversarial` and `pr-architecture`. Escalating on a high-stakes plan means making sure
those deep-tier reviewers are in the selected set — never switching an agent's model at
launch. Keep prompts self-contained.

If a named reviewer is unavailable, use `general` with the matching agent file from
`~/.config/opencode/agents/` inlined. Never skip a selected reviewer.

### When the task tool is unavailable

If the task tool is missing (nested subagent or restricted toolset), **do not**
invent a single-pass self-review or fake Approve. Prefer this sequential role-artifact fallback
on the current agent:

1. Run the planner role inline (read `pr-planner.md`) and record the selected roster in the
   synthesis artifact — same selection rules as the Task path, including the
   `architecture-alignment` preference set when that mode is active.
2. Read each selected agent file under `~/.config/opencode/agents/` and run those roles **in order**,
   writing a distinct artifact for each under
   `.agents/plans/<TICKET-OR-PLAN-STEM>.plan-review-fanout/`, then `pr-verifier`.
   If the planner artifact cannot be produced, fall back to the mode default only:
   - **architecture-alignment**: `pr-architecture`, `pr-organization`, `pr-naming`,
     `pr-problem-scope`, `pr-adversarial`, `pr-simplification`, then `pr-verifier`.
   - **default / review-only**: the full roster
     (`pr-problem-scope`, `pr-feasibility`, `pr-risk-rollback`, `pr-completeness`,
     `pr-adversarial`, `pr-architecture`, `pr-organization`, `pr-naming`,
     `pr-simplification`, then `pr-verifier`).
3. Do **not** run `pr-implementer` in this fallback path (implementer remains opt-in after the
   curated summary, same as the Task path).
4. Synthesize `.agents/plans/<TICKET-OR-PLAN-STEM>.plan-review.md` with the same output contract
   as the parallel Task path (verdict, tiers, curated findings).
5. Hard-stop only if the required agent files are missing or per-role artifacts cannot be
   produced.

When `ship` or `looping-plan-review` invokes this skill, follow that caller's nesting rule —
this section is the plan-review-native fallback so standalone `plan-review` works in the same
environments. Callers must not hardcode a divergent role list; this skill is the source of truth.

## Reviewer tiers

| Tier | Reviewers | Nature of findings |
|------|-----------|--------------------|
| **Strategic** (rethink candidates) | Problem & Scope, Adversarial | Premise, approach, and framing. Findings usually require reconsidering the problem or the chosen approach — a human decision, not a rewrite. |
| **Structural** (fix-in-place unless approach change) | Architecture, Organization, Naming, Simplification | Placement, naming, coupling, and simplicity. Tactical fixes unless the finding requires a different approach → treat as strategic escalation for the implementer. |
| **Tactical** (fix-in-place candidates) | Technical Feasibility, Risk & Rollback, Completeness & Sequencing | Concrete library swaps, step reorderings, missing rollback plans, missing feature flags, unspecified validation checkpoints. |

## Verification

After the selected reviewers complete (but before synthesis), launch the **Plan Review Verifier**
as a single subagent to filter the reviewer findings. The verifier tags each finding as
`confirmed`, `false_positive`, or `needs_rephrase`. Deduplicate near-duplicate findings in the parent chat **before** launching the verifier (merge same root cause; keep source tags). The verifier filters and rephrases; it does not own cross-reviewer deduplication.

Use the **pr-verifier** agent — false-positive filtering across a conflicting finding set
is a deep-reasoning role, and its model (`opencode/claude-sonnet-5`) is pinned in its
frontmatter. If the agent is unavailable, use `general` with `pr-verifier.md` inlined.

**Input to pass**: the full plan text, the planner's verifier instructions, and all selected
reviewer outputs concatenated with source attribution (e.g. `[Problem & Scope]`,
`[Architecture]`, `[Organization]`, `[Naming]`).

**Process the verifier output per finding**:

- `confirmed` → include in the curated summary
- `needs_rephrase` → apply the rephrased text, then include
- `false_positive` → list in a "Findings rejected by verifier" section with the verifier's
  reason (the user can override if they disagree)

All findings (blockers, suggestions, nits) go through the verifier — not just blockers.

## Synthesis

After the reviewers and the verifier have returned:

1. **Collect** confirmed and rephrased findings from the verifier output.
2. **Deduplicate** any remaining overlaps the verifier did not collapse — if two agents flag the
   same gap from different angles, merge into one finding (attribute to both).
3. **Tier** — each finding inherits its reviewer's tier (Strategic / Structural / Tactical).
4. **Rank** within each tier — blockers, suggestions, nits.
5. **Produce the curated summary** (see "Output Format" below). Do NOT pass reviewer outputs
   verbatim.

## Output Format

Produce a single curated summary. Omit any section that would be empty.

```
## Plan review summary

**Verdict**: Approve | Request Changes | Questions Only
**Counts**: N blockers (strategic: A, structural: B, tactical: C) • N suggestions • N nits • N findings rejected by verifier

## The big picture
<1-2 sentence framing of where the plan stands and why>

## Strategic problems (only if any)
N. **<title>**. <2-3 sentence explanation; what decision the user has to make>

## Structural problems (only if any)
N. **<title>**. <1-2 sentences + the mechanical or naming/placement fix>

## Tactical problems (only if any)
N. **<title>**. <1-2 sentences + the mechanical fix>

## Verifiable factual errors (only if any)
- <bullet with file:line, quote, or specific concrete error>

## Findings rejected by verifier (only if any)
- <terse one-liner per rejected finding + verifier's reason>

## Questions for the user (only if any)
**Q1: <decision title>?** <options a/b/c laid out with trade-offs>
**Q2: ...**

---
Reply with your decisions, or say "walk me through" to discuss each blocker one at a time.
```

In **review-only** mode, omit the trailing `---` CTA line entirely.

## Walkthrough mode

Triggered by the user saying "walk me through" or close variant after the summary (not available
in review-only mode). Start at **blocker #1** (no pre-prompt). For each blocker in order:

1. **Re-state in full detail**: title, file:line / quote / code excerpt, what the verifier confirmed.
2. **Explain why it's a blocker**: concrete impact, what breaks.
3. **Propose 1-3 specific fixes** with trade-offs.
4. **Ask**: "Accept fix [N] / Reject the finding (give reason) / Discuss further / Move to next".
5. **Record the decision in chat** (visible to the user).
6. **Move to the next blocker**.

When all blockers are done, also offer to walk suggestions if there are any (user can decline).

At the end of the walkthrough, summarize all captured decisions and transition to the **Fix step**.

## Fix step (final, opt-in)

After the walkthrough (or after a freeform decisions reply), surface a "ready to apply"
confirmation (not available in review-only mode):

```
Decisions captured:
- Accept fix #1: <title>
- Accept fix #3: <title>
- Accept fix #5: <title>
- Reject #2 (reason: <user's reason>)
- Defer #4

Apply 3 approved fixes now via the implementer subagent? [yes / no / edit list]
```

- **yes** → launch the implementer subagent with the plan text + the list of approved fixes. The
  implementer edits the plan file in place and returns a summary. Report the summary back to the
  user.
- **no** → end. The user applies fixes manually.
- **edit list** → let the user toggle the apply-list and re-prompt.

After fixes apply, suggest: "If you want to verify nothing regressed, re-invoke `plan-review`."

Use the **pr-implementer** agent (its model, `opencode/kimi-k2.6`, is pinned in its
frontmatter). If the agent is unavailable, use `general` with `pr-implementer.md` inlined.

## Review-only mode

Enter review-only mode when **either**:

- The user message explicitly requests it (e.g. "review only — don't walk through or fix"), OR
- Another skill invokes `plan-review` and signals review-only intent (e.g. "Follow
  plan-review/SKILL.md in review-only mode").

In review-only mode:

1. Run the planner (same as default mode; honor architecture-alignment if also requested).
2. Run the selected reviewers in parallel.
3. Run the verifier.
4. Emit the curated summary in the same format — **but omit** the trailing
   `--- Reply with your decisions, or say "walk me through" ...` line.
5. **Halt immediately** after emitting the summary. Do NOT prompt for walkthrough. Do NOT
   prompt for fixes. Do NOT launch the implementer subagent.

## Architecture-alignment mode

Enter architecture-alignment mode when the user or caller skill requests it (e.g. Phase 1 of
`looping-plan-review`). This mode is always combined with **review-only**.

Instruct the planner with mode hint `architecture-alignment` so it prefers Architecture,
Organization, Naming, Problem & Scope, Adversarial, and Simplification. The curated summary
should emphasize (a) placement + naming, (b) product-goal fit, and (c) system fit. Still halt
after the summary — the caller owns the human gate.

## Verdict Guidelines

- **Approve** — no blockers in any tier; suggestions are optional improvements; plan is
  executable as-is.
- **Request Changes** — has blockers or critical gaps that must be addressed before execution.
  If any strategic blockers exist, the natural path is "walk me through" for per-blocker
  decisions, or freeform reply if the user already knows what they want.
- **Questions Only** — no blockers, but unanswered questions need clarification before
  proceeding.

## Communication Style

- Use "this plan" or "the approach" instead of "you".
- Use reviewer output as input; produce a curated summary that's scannable in one read. Drop
  into per-blocker mode when asked. Hand off accepted fixes to the implementer subagent.
- Assume positive intent.
