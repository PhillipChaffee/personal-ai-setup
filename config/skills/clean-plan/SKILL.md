---
name: clean-plan
description: Clean an implementation plan (`.agents/plans/` by convention) so a simple implementer model can execute it. Strips the plan to only what the implementer needs, fleshes out underspecified steps so the model can execute without making decisions, verifies frontmatter todos match the plan body, checks compliance with the plan-steps rule when accessible, reorganizes steps into the optimal implementation order, and flags any work the AI cannot do on its own. Use when the user asks to clean, slim, prune, tidy, or prep a plan for an agent to implement.
---

# Clean Plan

Edit an implementation plan in place so a **simple implementer model** can execute it top-to-bottom. Two principles drive every edit:

1. **Strip to need.** The plan contains only what the implementer needs to implement or execute it — no justifications, history, or process commentary.
2. **Flesh out to zero decisions.** Every step carries enough detail that a simple model can execute it without making a single decision.

The skill removes fluff, aligns the frontmatter `todos` with the plan body, checks the plan against the plan-steps rule when one is accessible, reorganizes steps into the right execution order, fleshes out underspecified steps, and flags work that requires a human.

The user reviews changes with `git diff` after the skill completes — never auto-commit.

## Target Resolution

Pick the plan to clean in this order:

1. User specified a file path → use that.
2. A `.agents/plans/*.plan.md` (or `plans/*.plan.md`) file referenced in the conversation → use that.
3. Exactly one plan file modified in `git status` → use that.
4. Otherwise → ask the user which plan.

Plan files are markdown with YAML frontmatter:

```
---
name: ...
overview: ...
todos:
  - id: ...
    content: ...
    status: pending
isProject: false
---

# Title

## Section 1
...
```

The `todos` list is the canonical work breakdown. Body sections expand each todo with file paths, code, and edge cases.

## Pre-flight

Before editing:

1. Read the entire plan once. Capture starting line count, the full `todos` list (id + content), and an outline of body sections.
2. If the file already has uncommitted edits the user might want to keep, surface them with `git diff --stat <plan path>` and confirm before overwriting.
3. State the plan name + starting line count back to the user as a one-liner so they know what's being cleaned.

## Workflow

Run these passes in order. Each pass either edits the plan or asks the user a focused question. Don't batch unrelated questions — ask in context as you encounter them so the user can keep state in their head.

### Pass 1 — Todos ↔ body cross-check

Build two views:

- **Todo view**: every entry in frontmatter `todos`.
- **Body view**: every concrete work item described in the body (one per H2/H3 section, plus inline references like "add helper X" / "update test Y" / "extend method Z").

Reconcile, asking the user only when it's a real mismatch:

- **Todo with no body coverage** → ask: "Todo `[id]` (`[content]`) has no body section. Add a section, drop the todo, or fold into another todo?"
- **Body work with no todo** → ask: "The body describes `[work]` but no todo covers it. Add a new todo, or fold into todo `[id]`?"
- **Todo content drifted from body** (e.g., todo says "add tests for X" but the body adds tests for X *and* Y) → ask which is canonical.
- **Typos or minor wording differences** with the same intent → fix the todo silently to mirror the body's wording.

Keep the frontmatter todo order in sync with the order body sections will appear after Pass 4.

### Pass 2 — Plan-steps rule compliance

If a plan-steps rule is accessible from where the skill is running — already loaded via the global rules (`~/.config/opencode/AGENTS.md`), the project's `AGENTS.md`, or a file listed in `opencode.json` `instructions` — verify the plan complies with it. If no plan-steps rule is accessible, skip this pass.

Check against what the rule actually says, not a remembered copy of it:

- Every step the rule requires (e.g. branch setup at the start; per-commit CI lint+test and commits in the middle; final CI lint+test, pre-MR checklist, and MR creation at the end) exists as **both** a body section and a frontmatter todo.
- Required steps sit in the position the rule prescribes (beginning / middle / end). Pass 4's tiers mirror this structure — note ordering violations here and fix them there.

For a missing required step: add it as a body section and matching todo in the rule-prescribed position, and report the addition in the chat summary. This is rule compliance, not scope expansion. If the plan explicitly opts out of a required step (e.g. "no MR — scratch spike"), ask the user instead of silently adding it.

### Pass 3 — Strip to only what the implementer needs

The test for every paragraph, diagram, and code block: **does the implementer model need this to implement or execute the plan?** If not, remove it. Context that explains, justifies, or documents — but doesn't change what the implementer types — goes. Default for each category:

| Category | Default action |
|----------|---------------|
| Justifications about past iterations of the plan ("we used to do X, then…") | Remove |
| "Decision recap" / "Why this approach" sections after the decision is settled | Fold any remaining hard constraints into the relevant body section; remove the rest |
| "Verified scope" research notes (your analytics tool counts, code search results, ticket links) | Keep one-line summaries that justify a non-obvious choice (e.g. "Acme dormant — no migration needed"); drop the rest |
| Cross-references that duplicate visible content | Remove |
| Caveats that repeat a prior point earlier in the plan | Remove the duplicate |
| Process commentary from previous reviews ("after the adversarial pass we added…") | Remove |
| Adjectives that don't constrain behavior ("careful", "robust", "elegant", "clean") | Remove |
| **Architecture / data-flow diagrams (mermaid, ASCII)** | **Keep** — they orient the agent. Ask before removing one. |
| **Code blocks showing concrete model / serializer / view / SQL** | **Keep** |
| **File paths and line numbers** | **Keep** |
| **Cross-service contract / deploy-order notes** | **Keep** |
| **Edge-case prose ("when X is null, do Y")** | **Keep** |
| "Out of scope" sections | Keep, but trim to one bullet per item |

When uncertain whether a section is fluff: **ask the user**, quoting the section title and ~3 lines, with the options "remove / compress / keep".

### Pass 4 — Reorganize for execution order

Sequence the body and the todos so an agent can implement top-to-bottom. Apply this tier order, grouping by repo (`service-b/` together, `service-a/` together) within each tier:

1. Branch setup / prerequisites
2. Schema and model definitions
3. Migrations (immediately after the model changes that need them)
4. Services / business logic
5. Serializers / API layer
6. Admin / views / controllers / templates
7. Cross-service integration changes (consumer-side after producer-side)
8. Tests (after the code they test)
9. Documentation
10. **Pre-MR manual steps** (one-off scripts, prior-MR dependencies, your feature-flag provider prep, manual credential creation) — things the human does mid-implementation, before MRs ship
11. CI lint+test → pre-MR checklist → commit and create MRs (always last for the agent's part of the work)
12. **Post-deploy human checklist** (production smoke tests, non-live agent verification, customer admin config, manual rollout / your feature-flag provider prod flips, after-hours deploy coordination) — clearly labeled, written for a human to execute AFTER MRs have merged and deployed

The split between tiers 10, 11, and 12 is the most common cleanup miss: anything that depends on the deployed code already running in production must live in tier 12, after `commit-mrs`. If you find a step in tier 10 whose preconditions only exist post-deploy, move it to tier 12.

**Major reorder** (move sections across tiers, split a section, merge two sections, swap repo order): ask first with a one-line summary of the proposed move. Moving a step between tier 10 and tier 12 always counts as major because it changes when the human acts.

**Minor reorder** (within a tier): just do it.

After reordering body sections, reorder the frontmatter `todos` to match.

### Pass 5 — Tighten and flesh out step descriptions

The target audience is a simple implementer model: it executes instructions literally and should never have to make a decision. Each step must be tight (no fluff) **and** complete (no gaps the implementer has to fill by choosing).

Tighten — for each remaining body section and each todo:

- Start with a clear action verb: `Add`, `Replace`, `Remove`, `Wire`, `Run`, `Update`, `Switch`, `Migrate`.
- Name the file when the step touches one specific file (e.g. ``[`service-b/website/agents/models.py`](service-b/website/agents/models.py)``).
- Inline only the code that has to be in that exact form. Drop illustrative snippets where one prose line conveys the same constraint.
- Keep prose constraints that can't be expressed in code (e.g. "must run inside a transaction", "no external API calls inside this lock").

Flesh out — scan each step for decisions it silently delegates to the implementer, and resolve them in the plan:

- **Vague targets** ("update the serializer", "add a test") → name the exact file, class/function, and field. If the plan doesn't say, look it up in the codebase and write it in.
- **Unstated choices** (names for new functions/fields/flags, nullable vs. default, which existing helper to reuse, where a new file lives) → pick one and state it. If you can't determine the right choice from the codebase, ask the user — don't leave the choice to the implementer.
- **Implied behavior** ("handle the error case") → spell out what to do (log and continue? raise? return None?).
- **Ambiguous ordering or scope** ("update the tests" — which ones?) → enumerate.

The bar: an implementer following the plan should only ever be transcribing decisions into code, never making them. If a step could be implemented two materially different ways, the plan is underspecified — fix it.

Don't over-shrink: if a constraint or edge case lives only in prose, that prose stays.

#### Examples

Before (fluff and adjectives):

```
We should carefully add a robust new helper that cleanly handles the
edge cases we discussed in the design doc. The helper should be defined
near the existing `clone_settings` function so
that future readers can find related cloning helpers in one place.
```

After:

```
Add `clone_shared_settings(source, target)` next
to `clone_settings` in `orders/services.py`.
Per target version, iterate source rows and either update the same-`alias`
row or create a fresh `SharedPromptVariable`.
```

Before (illustrative code that adds nothing over prose):

````
- Add a serializer field for the new value:
  ```python
  shared_prefix = serializers.CharField(allow_null=True, required=False)
  ```
````

After:

```
- Add `shared_prefix` to the `AgentVersion` serializer (nullable, optional).
```

### Pass 6 — Identify human-only work

Scan the cleaned plan for steps an AI agent cannot complete on its own. There are two flavors with different placement — the distinction is **when the human acts**, not what the work is.

**Category A — Mid-execution human-only.** Steps a human does *as part of the implementation* before the MRs ship. These belong in tier 10 of Pass 4 (or are flagged out-of-band when they're not really plan steps). The agent flags Category A items in the chat summary and keeps the body un-annotated.

Examples:
- Linear ticket ID lookup when the agent doesn't know which ticket is correct.
- Prior-MR dependencies the human must coordinate (e.g. "wait for MR #123 to merge").
- One-off data imports or credential creation that must happen before this MR can ship.
- your feature-flag provider flag definition / setup that must precede the code change.

**Category B — Post-deploy verification and customer rollout.** Steps that can only happen *after* the MRs have merged and deployed. The agent puts these in the plan body as a labeled "Post-deploy human checklist" section in tier 12 of Pass 4 — written as a numbered checklist the human can follow once the agent's work is done.

Examples:
- Production smoke tests / non-live agent verification.
- Customer admin configuration (e.g. "set `shared_prefix` on the Acme parent agent version, add a `SharedPromptVariable` mapping with alias `velocify_id`").
- Manual rollout commands or your feature-flag provider prod toggle flips.
- Production data backfill that requires live DB access.
- Coordinated or after-hours deploy steps.

**Decision rule** for ambiguous steps: ask "could the human do this *before* MRs merge?" If yes → Category A (chat summary, body stays clean). If the step's preconditions only exist after the deployed code is running → Category B (write it into the post-deploy checklist in the body).

If a step is genuinely Category B but currently sits before `commit-mrs` in the plan, move it to the post-deploy checklist section as part of Pass 4. This is the correction the skill is most likely to need.

## Output

When the passes complete:

1. The plan file is saved in place. The user reviews with `git diff <plan path>`.
2. Print a chat summary in this exact shape:

```
## Plan cleaned: <plan name>

Size: <starting> → <final> lines (<pct>% change — stripping shrinks, fleshing out may grow)

### Key changes
- <one line per significant edit category, e.g. "Removed 3 'Verified scope' research blocks (~40 lines)">
- <one line per significant reorganization, e.g. "Moved service-a-side reader before service-a-side tests">
- <one line per fleshed-out step, e.g. "Specified serializer field name and nullability in `backend-serializer` — was left to the implementer">
- <one line per todo↔body fix, e.g. "Added missing todo `backend-cloning-tests` to match new body section">
- <one line per plan-steps compliance fix, e.g. "Added missing `pre-mr-checklist` section + todo (required by plan-steps rule)">

### Mid-execution human steps (Category A — not in plan body)
- <step name / location> — <why a human is needed>
- ...

### Post-deploy checklist (Category B — captured in plan body)
N items captured under the "Post-deploy human checklist" section after `commit-mrs`.

### Open questions (resolve before implementing)
- <question> — <section / todo id>
- ...

Review with `git diff <plan path>` and accept or reject hunks.
```

Omit any heading whose section is empty.

## Things this skill does NOT do

- Run code, migrations, tests, or commands described by the plan.
- Create commits, branches, or MRs.
- Re-evaluate whether the plan's *approach* is correct (use `looping-plan-review` or `plan-review` for that).
- Add new requirements or expand the plan's scope. (Fleshing out an existing step with the detail needed to execute it is not scope expansion, and neither is adding a step the plan-steps rule requires; adding steps neither the plan nor the rule calls for is.)
- Rewrite working code samples to be "more idiomatic" or "cleaner".
- Annotate Category A (mid-execution) human-only steps inside the plan body — those stay in the chat summary only. Category B (post-deploy) human steps do go in the body, as a labeled checklist after `commit-mrs`.

## Relationship to other plan skills

- `looping-plan-review` / `plan-review`: review the *substance* of the plan (premise, architecture, placement, naming, completeness, risks, feasibility). Run substance review first — `ship` uses `looping-plan-review`. Phase 1 architecture constraints must already be encoded in Design/Changes steps (paths, names, diagrams) before clean; this skill still strips “why we decided” prose.
- `clean-plan` (this skill): final prep pass after substance review is clean. Optimizes the plan for a simple implementer model to read and execute top-to-bottom without making decisions.

## When uncertain, ask

The point of this skill is to slim a plan **without losing context the implementing agent needs**. When you can't tell whether a paragraph, diagram, or code block is fluff, quote the specific lines and ask the user — never delete silently. Likewise, when fleshing out a step requires a choice you can't resolve from the codebase, ask the user rather than guessing — a wrong decision baked into the plan gets faithfully implemented by the simple model. A plan with one extra paragraph is recoverable; a plan missing the constraint that drove the design is not.
