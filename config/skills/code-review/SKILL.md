---
name: code-review
description: Plan and perform thorough code reviews using parallel specialized subagents, then verify findings and produce a curated summary. Use when reviewing pull requests, git diffs, code changes, or when the user asks for a code review.
---

# Code Review (Multi-Agent Orchestrator)

Run a comprehensive code review by planning reviewer dispatch, launching the selected specialized reviewers in parallel, filtering their findings through a verifier subagent, then producing a curated summary. The user can reply freeform with decisions, ask to walk through blockers one at a time, and optionally hand accepted fixes to an implementer subagent that edits the source files in place. Includes a **review-only mode** for callers (e.g. `mr-review`) that want just the curated summary.

## Scope Resolution

Determine what code to review using this priority:

1. **User specifies scope** — branch name, commit SHA, PR number/URL, or file paths
2. **On a feature branch** — all changes vs main/master (`git diff main...HEAD`)
3. **Staged changes** — `git diff --staged`
4. **Unstaged changes** — `git diff`
5. **Latest commit** — `git show HEAD`

Gather the diff and changed file paths before launching subagents.

## Planning (mandatory)

Before launching reviewers, run exactly one **cr-planner** subagent.

`cr-planner` runs on `opencode/claude-sonnet-5` — planning reviewer dispatch is a
deep-reasoning role (see the personal-ai-setup repo's `docs/model-routing.md`), and the model is pinned in the agent's
frontmatter. Do not downgrade it for simple diffs; a cheap plan that picks the wrong
reviewers costs more than it saves.

Pass the planner the diff, changed file paths, change purpose, user priorities, scope constraints,
and prior verifier findings when re-reviewing. It returns the selected reviewer set, focus briefs,
and verifier instructions.

Selection hint for the planner: treat **Code Organization** as a default pick whenever the
diff adds new files, moves or renames symbols, or introduces helpers, dataclasses, or enums.

Invoke the `cr-planner` agent via the task tool. If the named agent is unavailable, use a
general-purpose subagent with `cr-planner.md` inlined and the same model.

## Reviewers

Launch the planner-selected reviewers in one message using parallel task tool calls. Pass each reviewer
the diff, changed file paths, and its planner-authored focus brief.

The reviewers are OpenCode agents in `~/.config/opencode/agents/` (agent name = filename
without `.md`):

| Agent | File | Domain |
|-------|------|--------|
| Security | `cr-security.md` | Injection, auth, secrets, data exposure |
| Correctness | `cr-correctness.md` | Logic bugs, edge cases, None handling |
| Performance | `cr-performance.md` | N+1 queries, blocking ops, memory, hot paths |
| Architecture | `cr-architecture.md` | SRP, coupling, layering, cross-service contracts |
| Test Quality | `cr-test-quality.md` | Coverage gaps, anti-patterns, test ROI |
| Deployment Safety | `cr-deployment-safety.md` | Migrations, deploy order, feature flags, rollback |
| Simplification | `cr-simplification.md` | Over-engineering, duplication, change atomicity |
| Code Organization | `cr-organization.md` | File/folder placement, module homes, moved-symbol hygiene |

Each reviewer:
- Is read-only (its agent `permission` denies edits — it cannot modify files)
- Returns structured findings or an exact "no issues" string

Reviewers run on the models pinned in their agent frontmatter (see the personal-ai-setup
repo's `docs/model-routing.md`): `opencode/kimi-k2.6` for every reviewer — diff-reading
review work stays on the daily tier; the deep tier (`opencode/claude-sonnet-5`) belongs to
`cr-planner` and `cr-verifier`. When the changeset is clearly high stakes —
cross-service contracts, schema/deploy sequencing, auth or security boundaries,
concurrency/state-machine behavior, or a large heterogeneous changeset with ambiguous
intent — make sure the planner selected the reviewers matching those stakes rather than
economizing on the reviewer set. Pass prompts self-contained.

Example (auth + hot-table migration + cross-service field): launch each selected reviewer as its
own subagent — `cr-security`, `cr-deployment-safety`, and `cr-architecture` each get their own
run, and `cr-verifier` runs separately afterwards. Never collapse the review into one umbrella
reviewer.

If a named reviewer agent is unavailable, use a general-purpose subagent with the matching agent
file from `~/.config/opencode/agents/` inlined and the same model. Never skip a selected reviewer.

## Verification

After the selected reviewers complete (but before synthesis), launch **cr-verifier** as a single subagent to filter the reviewer findings. The verifier tags each finding as `confirmed`, `false_positive`, or `needs_rephrase`.

`cr-verifier` runs on `opencode/claude-sonnet-5` — false-positive filtering across a large,
conflicting, or high-stakes finding set is deep-reasoning work, and the model is pinned in the
agent's frontmatter. If the named agent is unavailable, use a general-purpose subagent with
`cr-verifier.md` inlined and the same model.

**Input to pass**: the git diff + changed file paths, the planner's verifier instructions, and all
selected reviewer outputs concatenated with source attribution (e.g. `[Security]`, `[Correctness]`).

**Process the verifier output per finding**:
- `confirmed` → include in the curated summary
- `needs_rephrase` → apply the rephrased text, then include
- `false_positive` → list in a "Findings rejected by verifier" section with the verifier's reason (the user can override if they disagree)

All findings (blockers, suggestions, nits) go through the verifier — not just blockers.

## Synthesis

After the reviewers and the verifier have returned:

1. **Collect** confirmed and rephrased findings from the verifier output.
2. **Deduplicate** — if two agents flag the same issue from different angles (e.g., Security and Correctness both flag a missing None check on auth), merge into one finding and note both perspectives.
3. **Categorize** — separate into show-stopper bugs (must fix), architectural concerns (design rethink), smaller suggestions, and nits.
4. **Rank** within each category by severity.
5. **Collapse clean reviewers** — reviewers that returned "no issues" get a one-line summary in the All Clear section.
6. **Produce the curated summary** (see "Output Format" below). Do NOT pass reviewer outputs verbatim.

## Output Format

Produce a single curated summary. Omit any section that would be empty.

```
## Code review summary

**Verdict**: Ready to Merge | Needs Attention | Needs Work
**Counts**: N blockers • N suggestions • N nits • N findings rejected by verifier

## The big picture
<1-2 sentence framing>

## Show-stopper bugs (only if any)
N. **<title>** — `file:line`. <explanation + suggested fix>

## Architectural concerns (only if any)
N. **<title>**. <explanation + approach>

## Smaller suggestions (only if any)
- <terse one-liner per finding with `file:line`>

## Nits (only if any)
- <one-liner per finding>

## Findings rejected by verifier (only if any)
- <terse one-liner per rejected finding + verifier's reason>

## All Clear (only if any reviewers returned clean)
- <reviewer>: <one-line summary>

## Questions to clarify intent (only if any)
N. **<question>** — context

---
Reply with your decisions, or say "walk me through" to step through each blocker.
```

## Walkthrough mode

Triggered by the user saying "walk me through" or close variant after the summary. Start at **blocker #1** (no pre-prompt). For each blocker in order:

1. **Re-state in full detail**: title, `file:line`, code excerpt from the diff, what the verifier confirmed.
2. **Explain why it's a blocker**: concrete impact, what breaks.
3. **Propose 1-3 specific fixes** with trade-offs.
4. **Ask**: "Accept fix [N] / Reject the finding (give reason) / Discuss further / Move to next".
5. **Record the decision in chat** (visible to the user).
6. **Move to the next blocker**.

When all blockers are done, also offer to walk suggestions if there are any (user can decline).

At the end of the walkthrough, summarize all captured decisions and transition to the **Fix step** (see next section).

## Fix step (final, opt-in)

After the walkthrough (or after a freeform decisions reply), surface a "ready to apply" confirmation:

```
Decisions captured:
- Accept fix #1: <title>
- Accept fix #3: <title>
- Accept fix #5: <title>
- Reject #2 (reason: <user's reason>)
- Defer #4

Apply 3 approved fixes now via the implementer subagent? [yes / no / edit list]
```

- **yes** → launch the implementer subagent with the diff + the list of approved fixes. The implementer edits source files in place and returns a summary. Report the summary back to the user.
- **no** → end. The user applies fixes manually.
- **edit list** → let the user toggle the apply-list (drop an accepted fix, add a deferred one) and re-prompt.

After fixes apply, suggest: "If you want to verify nothing regressed, re-run the code-review skill and re-run your tests."

Use the named **cr-implementer** agent on `opencode/kimi-k2.6`. If the named agent is
unavailable, use a general-purpose subagent with `cr-implementer.md` inlined and the same model.

## Review-only mode

Some callers want only the curated summary as a result, not an interactive walkthrough/fix flow. Most notably `mr-review` invokes `code-review` to surface findings as GitLab MR comments; the walkthrough and fix step are inappropriate for an external MR you don't own.

Enter review-only mode when **either**:

- The user message explicitly requests it (e.g. "review only — don't walk through or fix"), OR
- Another skill invokes `code-review` and signals review-only intent (the caller's wording should make this explicit, e.g. "Follow code-review/SKILL.md in review-only mode").

In review-only mode:

1. Run the planner (same as default mode).
2. Run the selected reviewers in parallel.
3. Run the verifier.
4. Emit the curated summary in the same format — **but omit** the trailing `--- Reply with your decisions, or say "walk me through" ...` line.
5. **Halt immediately** after emitting the summary. Do NOT prompt for walkthrough. Do NOT prompt for fixes. Do NOT launch the implementer subagent.

Callers take the summary findings and do whatever they want with them downstream (e.g. post as MR comments via the GitLab MCP).

## Verdict Guidelines

- **Ready to Merge** — all reviewers clean or only nits; no blockers or suggestions.
- **Needs Attention** — has medium-severity issues or important suggestions worth addressing.
- **Needs Work** — has critical/high blockers that must be fixed.

## Scope Boundaries

Only review files in the changeset. If an agent flags an issue outside the diff, include it as an `out-of-scope:` note suggesting a follow-up.

## Communication Style

- Use "we" or "this code" instead of "you".
- Explain the *why* for every finding.
- Assume positive intent.
- Use reviewer output as input; produce a curated summary that's scannable in one read. Drop into per-blocker mode when asked. Hand off accepted fixes to the implementer subagent.
