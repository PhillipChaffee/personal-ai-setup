<!--
Global OpenCode rules template. scripts/mac/bootstrap-mac.sh installs this file
(no-clobber) to ~/.config/opencode/AGENTS.md, where OpenCode applies it to every
session. Edit the installed copy to taste. Stack-specific rules (Python, Django,
Linear tickets, design docs, writing voice) live in config/opencode/project-rules/
and are opted into per project via the project's AGENTS.md or its opencode.json
"instructions" array.
-->

# Global Rules

Skills and other rules refer to the sections below by their original rule names:
`engineering`, `minimal-changes`, `code-organization`, `comment-style`,
`look-it-up`, `subagents`, `plan-steps`, `merge-requests`.

## Engineering Guidelines

Some items below assume the work stack (Django/DRF services, Celery, a shared
model repo); apply the analogous pattern in other stacks.

- **Scope and simplicity**
  - Question every addition. Prefer reusing existing abstractions (serializers, utilities, Django builtins) over creating new ones.
  - Keep MRs focused. If something is nice-to-have but not required for the current ticket, skip it.
  - Don't build ahead of demand. If a feature isn't needed yet, don't add it.

- **Architecture and code placement**
  - Views must be thin — only transform input and delegate to a service or task. Business logic does not belong in views, admin actions, or serializers.

  ```python
  # Bad: logic in the view
  class OrderCreateView(APIView):
      def post(self, request):
          # ... 50 lines of processing, validation, side effects ...

  # Good: view delegates to service
  class OrderCreateView(APIView):
      def post(self, request):
          data = LeadCreateSerializer(data=request.data)
          data.is_valid(raise_exception=True)
          lead_services.create_lead(data.validated_data)
  ```

  - Heavy or risky work goes in background tasks. Anything that calls external APIs, processes large datasets, or could block a request should be a Celery task.
  - Shared models belong in the shared repo. If both `service-b` and `service-a` use the same model, enum, or validation logic, it should live in `shared/`.
  - Prefer standalone utility functions over `@staticmethod` — they are easier to test and reuse.

- **Migration and deploy safety**
  - Safe column removal pattern: (1) add the new column, (2) migrate all code to use it, (3) defer the old column from the default manager, (4) delete the old column in a follow-up MR. Never drop a column in the same MR that stops using it.
  - Flag risky migrations or schema changes on hot tables as needing an after-hours deploy.
  - Flag changes that affect agent config, call flow, or scheduling as needing production verification on a non-live agent.

- **Commits**
  - Never amend commits or force-push. Create new commits instead — amended history breaks other developers' local branches and CI traceability.

- **Feature flags and rollout**
  - Gate risky changes behind feature flags. Use your feature-flag provider (or equivalent) to control rollout. Include `tenant_id` in the user context so changes can be enabled for a single company first.
  - When adding behavioral changes, surface the need for a feature flag and incremental rollout (one company first, then expand gradually).

## Minimal Changes

### Make the Smallest Change That Works

- Limit edits to only the files and lines necessary to accomplish the task.
- Avoid tangential refactors, style changes, or "while I'm here" improvements unless explicitly requested.

### Extract Utility Functions Instead of Duplicating

- Before writing new logic, search for existing functions that do the same or similar thing.
- If the same pattern appears in two or more places, extract it into a shared utility function.
- Prefer refactoring existing code into a reusable helper over copy-pasting and tweaking.

### Consider Deleting Code

- Removing code is often the best solution — fewer lines means fewer bugs and less maintenance.
- If a feature, branch, or abstraction is no longer needed, delete it rather than working around it.
- When simplifying logic, check whether entire functions, classes, or files can be removed.

## Code Organization & Placement

Where code lives is a first-class concern. Apply these rules when writing or moving code in any repository, in any language.

### Placement decision

For every new function, class, dataclass, enum, constant, or module, ask: "Where would a reader look for this?" Put it there — not in the file you happen to be editing.

- Entry points (e.g. `main.py`, `app.py`, `index.ts`, route/handler files) stay thin: wiring and orchestration only. Domain logic, helpers, and data shapes go in the module that owns the domain.
- Data shapes (dataclasses, enums, DTOs, TypedDicts, interfaces) belong in the package's existing models/types module when one exists. Do not define them inline next to their first consumer.
- Generic helpers belong in the package's existing utils/helpers module when one exists. Check for that module — and whether the helper already exists in it — before writing a new one.
- Before writing any new helper, search the package and shared libraries for an existing implementation.

### Moving code

- When a better home exists for something being touched, propose the move — do not silently keep appending to the wrong file.
- When moving a symbol: move its tests, update all imports, and update test patch/mock targets (e.g. `patch("old.module.symbol")`) in the same change.
- Renames and pure moves are their own commits, separate from behavior changes.

### Growth limits

- Do not let grab-bag files (`utils.py`, `helpers.py`, `common.py`, `misc.py`) accumulate unrelated functions — split by domain once a file loses a coherent theme.
- Do not grow entry-point files: if a change adds significant non-wiring logic to an entry point, extract a module first.
- Tests mirror source layout: tests for `package/module.py` live in `package/tests/test_module.py` (or the repo's established mirror convention).

## Comment & Docstring Style

A comment must add context the code cannot convey. If it restates the code, delete it.

### Content

- **Why, not what.** Explain the goal, trade-off, or constraint — never narrate the next line.

```python
# ❌ Narration / goal labels with no why
# Call the tool
# Try to recover the real tool result.

# ✅ The constraint the code can't convey
# The shielded task may have completed before the cancellation arrived; prefer
# its real result over the INTERRUPTED placeholder.
```

- **Present state only.** Never describe what the code used to do — no "moved", "was", "previously", "renamed from". Docs describe the code as it exists now.

```python
# ❌ """Coaching helpers (was part of utils.py before the split)."""
# ✅ """Coaching output formatting helpers."""
```

- **No roadmap.** No "for now", "interim", "will be", "until X lands". Future work lives in a plan or ticket, not the code.

- **No caller references in shared or leaf code.** Never "the caller" or enumerations of call sites; describe what an input *means*, not who supplies it. Carve-out: orchestrator code may name the modules it coordinates when explaining cross-module dataflow.

```python
# ❌ messages: In-turn callers pass turn.messages; the first-message render passes [].
# ✅ messages: The turn's Anthropic-format message list, flattened into the transcript view.
```

- **Don't over-narrow.** Describe the contract, not one usage pattern — a function taking `text` operates on "`text`", not "a streamed word".

### Form

- **Never create a lone `Args:`/`Returns:` section** just to document one newly added parameter in a docstring that had none — extend an existing section, fold the meaning into prose, or let the signature speak.
- **Match the host docstring's density.** Extensions follow the established style and length of the docstring being edited — no multi-paragraph grafts onto one-sentence docstrings.

## Look It Up

Do not answer from memory when the answer can be looked up. Look it up first.

### When this applies

Any factual question about APIs, tools, frameworks, CLI flags, config options,
error messages, product behavior, version-specific details, or "how do I / does
X support Y" questions.

### Source preference (in order)

1. **Official documentation** — vendor docs, language/framework reference, RFCs,
   man pages, and in-repo docs/READMEs.
2. **Primary sources** — source code, release notes, changelogs, or maintainer
   issues/PRs.
3. **Proven writeups** — only if official docs are missing or unclear: blogs,
   articles, or posts where someone solved this exact problem or answered this
   exact question. Prefer recent, version-matched sources.

### How to look things up

- Use web search, fetch, MCP, or local docs before stating a fact.
- Cite or link the source you used.
- If sources conflict, prefer official docs and say so.
- If you cannot find a reliable source, say that explicitly instead of guessing.

### Exceptions

- Pure reasoning, taste/style judgment, or synthesis from code already in context.
- Facts already established earlier in this conversation from a looked-up source.

## Subagent Use

Keep the main chat focused on orchestration, decisions, edits, and user communication. Delegate work that benefits from isolated context, parallel collection, or a specialized rubric.

Subagents are invoked via the task tool (or by @-mentioning an agent). The roster is the agent files in `~/.config/opencode/agents/` — agent name = filename without `.md`. Each agent pins its model in frontmatter.

### Decide Whether to Delegate

Work inline only when the task is a user-specified file read, one quick symbol lookup, a known fact, or a narrow check needed while actively editing.

Delegate unfamiliar code or architecture, multi-file tracing, debugging and root-cause analysis, code or plan review, tradeoff analysis, and web/MCP/external research. Split independent threads across subagents and launch them in parallel.

### Choose the Subagent

Choose by the work the agent must actually perform, not by the overall complexity of the parent task.

- `researcher-lite` (`opencode/minimax-m2.7`): mechanical retrieval from known sources, one-fact confirmation, a small bounded read, read-only repository search and file discovery, or command-only collection such as git state, test output, build output, or environment facts.
- `researcher-mid` (`opencode/kimi-k2.6`): normal multi-file or multi-source gathering, call-flow tracing, evidence comparison, and research summaries.
- `researcher-deep` (`opencode/claude-sonnet-5`): broad, ambiguous, high-stakes, security-sensitive, or novel evidence gathering. The `deep` label does not itself justify it — prefer `researcher-mid` unless the reasoning is genuinely hard.
- Named specialists — the `cr-*` code reviewers, `pr-*` plan reviewers, and `refactor-code-scout` / `refactor-placement-scout`: use when their rubric matches the task. Standard reviewers, scouts, and implementers run on `opencode/kimi-k2.6`; planners, verifiers, and the architecture/adversarial reviewers run on `opencode/claude-sonnet-5` (per their frontmatter).
- `research-planner` / `research-synthesizer` (`opencode/claude-sonnet-5`): decomposition and final synthesis inside the `deep-research` skill's pipeline — do not launch them for ordinary tasks.
- General-purpose subagent: use only as a carrier when a required named agent is unavailable. Inline that agent's definition from `~/.config/opencode/agents/` in the prompt and pin the same model.
- The `deep-research` skill: use only when the task truly needs planning, multiple collectors, and final synthesis.

### Model Selection

- `opencode/minimax-m2.7`: cheap, fast mechanical work — file reading, searches, command output, and mechanical lookup.
- `opencode/kimi-k2.6`: default for most subagent work — research, source interpretation, debugging, standard reviews, triage, scouts, and implementation.
- `opencode/claude-sonnet-5`: deep reasoning — planning, verification, synthesis, architecture and adversarial review, and rare, bounded, thinking-only work after all evidence has already been gathered.

Choose the lowest tier that can do the work reliably. Complexity alone does not justify `claude-sonnet-5`. It is justified when the remaining task is a difficult reasoning problem such as selecting among architectural options, synthesizing conflicting specialist findings, performing a strategic premortem, or decomposing a high-stakes plan.

### Prefer Thinking-Only Dispatch on the Deep Tier

Before dispatching a `claude-sonnet-5` subagent, ask: "Can this prompt be fully self-contained without asking the agent to inspect, fetch, search, or run anything?" If no, gather the missing information with the cheaper tiers first.

Outside a justified `researcher-deep` dispatch, do not use `claude-sonnet-5` to:

- read or search files, diffs, repositories, transcripts, logs, or command output
- fetch web, MCP, GitHub, GitLab, Notion, Linear, Sentry, Grafana, or other external data
- run shell commands, tests, builds, or diagnostics
- perform open-ended research, routine summarization, implementation, or source-dependent verification

Use a two-stage pipeline for complex work:

1. Collector agents on `opencode/minimax-m2.7` / `opencode/kimi-k2.6` gather facts, relevant excerpts, source references, constraints, competing findings, and unresolved questions.
2. A `claude-sonnet-5` reasoning agent receives one compact evidence packet and performs only the named decision, synthesis, critique, or planning task.

The `claude-sonnet-5` prompt must:

- contain the full evidence packet, not links or instructions to read more
- define one discrete reasoning question and the required output
- explicitly forbid tools, file reads, searches, and external fetches
- instruct the agent to list exact missing evidence and stop rather than gathering it

If the deep-tier agent reports an evidence gap, send that exact gap to a cheaper collector, then resume or rerun with the completed packet. Do not let the deep-tier agent expand its own scope.

### Review and Planning Defaults

Code and plan review agents that must inspect the diff, plan, or codebase stay on `opencode/kimi-k2.6`. A `claude-sonnet-5` planner or synthesizer may be added only after the cheaper agents provide the necessary evidence. Preserve the reason for escalation in its prompt.

Specialized single-shot skills keep their prescribed invocation. Do not override a workflow's required model or roster unless the workflow explicitly permits it.

### Dispatch Requirements

- Make prompts self-contained with the goal, sources, constraints, known facts, and output format.
- Launch independent work in parallel (multiple task tool calls in one message). Run dependent stages sequentially and pass forward curated evidence.
- The reviewer and researcher agents enforce read-only behavior via their `permission` config. When a general-purpose subagent must stay read-only, forbid edits in its prompt — do not strip the web or MCP access a researcher needs.
- Never paste raw subagent output. Curate, deduplicate, resolve conflicts, preserve source references, and surface gaps.

Skills own workflow-specific pipelines, rosters, rubrics, and exit criteria. This section owns shared delegation and model-selection policy.

## Plan Steps

Every implementation plan must include these steps in this order. Add them as both plan sections and frontmatter todos. Plans must also include an **Acceptance Criteria** section in the body (checklist of verifiable outcomes) and a **Verify acceptance criteria** end step (section + frontmatter todo) that the executor completes before declaring done.

### Beginning of every plan

- **Branch setup**: Create fresh feature branches from the repository's default branch in every repo that will be changed. Branch naming convention: `username/TICKET-ID-short-description` (e.g., `phillip/TICKET-1234-add-retry-logic`).
- **Acceptance Criteria**: Include an Acceptance Criteria section in the plan body with a short checklist of verifiable outcomes (`- [ ]` items). Each item must be checkable yes/no by the implementer against the finished work (observable behavior, file contents, or skill behavior) — not vague goals. Keep the list short (roughly ≤8 items when possible); if more are needed, the plan is probably too large. This is plan-level AC for the implementer, distinct from Linear ticket AC (they may overlap).

### Middle of every plan (implementation steps)

- **Commit organization**: If the work requires multiple commits, organize the implementation steps into logical commits. Each commit should be a coherent, reviewable unit with its own plan section and matching frontmatter todo(s).
- **Per-commit CI lint and test**: After completing the code changes for each commit, run the `ci-lint-test` skill for each changed repo included in that commit. Fix failures and re-run until clean.
- **Per-commit commit**: Actually commit the verified changes before moving on to the next commit's implementation steps.

### End of every plan (after all implementation steps)

- **Verify acceptance criteria**: Walk every Acceptance Criteria checkbox and confirm it is met against the actual changes. If any AC is unmet, fix the work (or update the plan with user approval) before proceeding to commit/MR/done. Report which AC were verified in the chat when finishing. Always include this section and frontmatter todo, even when Final CI / Pre-MR / Push are opted out — run it before declaring done.
- **Final CI lint and test**: Run the `ci-lint-test` skill for each changed repo as a final full verification. Fix failures and re-run until clean.
- **Pre-MR checklist**: Run the `pre-mr-checklist` skill on each changed repo. Fix all blockers.
- **Push and create MRs**: For single-commit plans, commit the verified changes before pushing. For multi-commit plans, use the commits created during implementation. Push and create GitLab MRs for each changed repo. Title must include the ticket ID (`TICKET-ID: Short description`). Assign self, add reviewer. MR descriptions must follow the merge-requests rule.

## Merge Requests

- **Title must include the ticket identifier** formatted as `TICKET-ID: Short description`.
  - If no ticket was provided, ask the user for it before creating the MR.
  - Never drop an existing ticket reference when updating a title.

```
# ✅ Good
TICKET-1234: Add retry logic for webhook delivery

# ❌ Bad — missing ticket
Add retry logic for webhook delivery
```

- **Description must have `## Problem`, `## Fix` (with `### Changes`), `## Impact`, and `## Test Plan` sections.**
  - `## Problem` describes the problem with concrete symptoms and real-world impact. Be specific — name the services, environments, and failure modes affected.
  - `## Fix` explains the solution approach at a high level, then lists specific changes under a `### Changes` sub-heading. Each bullet should have a **bold scope label** (file, module, or environment) followed by a description of the change in that scope.
  - `## Impact` states the consequences of the change — what improves, what trade-offs exist, and any residual risks.
  - `## Test Plan` lists concrete verification steps (lint, type checks, tests, manual verification, deploy checks).
  - If you don't have enough context to write any section, ask the user to explain before writing the description.

```markdown
# ✅ Good
## Problem

The `general` cluster NodePool in both dev and prod uses the default
`WhenUnderutilized` consolidation policy. This causes the autoscaler to evict
running pods (service-a, service-b, workers) whenever it considers a node
underutilized — even when those pods are the only replicas of a service.

In dev, this has been causing repeated e2e test failures: the autoscaler evicts
service-a/service-b pods mid-test, leading to service outages, dropped calls,
and test timeouts.

## Fix

Set `consolidationPolicy: "WhenEmpty"` on the `general` NodePool in both
environments. This matches the existing `on-demand` pool policy and ensures
the autoscaler only consolidates nodes that have zero running pods.

### Changes

- **dev** (`1-environments/dev/eks.yaml`): Add `consolidationPolicy: "WhenEmpty"`
  to general NodePool (keeps existing `consolidateAfter: "20m"`).
- **prod** (`1-environments/prod/eks.yaml`): Add `disruption` block with
  `consolidationPolicy: "WhenEmpty"` and `consolidateAfter: "20m"` to general
  NodePool (previously had no disruption config, defaulting to immediate
  `WhenUnderutilized`).

## Impact

- The autoscaler will still consolidate truly empty nodes after 20 minutes.
- Services with `minReplicas: 1` will no longer be disrupted by consolidation.
- Slightly higher cluster cost (nodes kept alive longer when underutilized),
  but prevents service disruptions.

## Test Plan

- [ ] Deploy modified dev manifest; verify `general` NodePool has
  `consolidationPolicy: "WhenEmpty"` and `consolidateAfter: "20m"` via
  `your-cluster-cli get nodepool general -o yaml`
- [ ] Run e2e test suite against dev; confirm no mid-test pod evictions for
  services with `minReplicas: 1`
- [ ] Check `your-cluster-cli describe node` and pod events — the autoscaler should not
  evict pods on underutilized nodes, only consolidate truly empty nodes
  after ~20 minutes
- [ ] Deploy modified prod manifest; repeat the `your-cluster-cli` verification

# ❌ Bad — vague problem, no changes list, no impact
## Problem

Pods keep getting evicted.

## Fix

Changed the consolidation policy to WhenEmpty in dev and prod.

## Impact

Should fix the issue.
```

- **Include a test plan** listing what was verified (lint, type checks, tests, manual verification).

### Keeping an MR Merge-Ready Without Ballooning the Diff

When iterating an open MR to merge-ready (conflicts, review comments, CI):

- Hold or reduce diff size. Prefer deletion or replacement over new abstractions. Tests count toward the diff and must not be omitted to keep it small.
- Fix only triaged, in-scope items: correctness, CI failures caused by this MR's scope, and style backed by an active rule. Never change CI workflows just to pass, and never touch unrelated code.
- Real restructure, performance, or architecture findings get surfaced and planned separately — never silently redesigned under merge-ready pressure.
- If fixes would grow the diff well beyond the reviewed baseline (roughly 20% is a good ceiling), stop and get explicit approval with a named blocker and an estimated final size before continuing.

### Self-Improvement

After writing an MR description, reflect on whether this section should be updated:

- **Missing conventions**: Did the MR require structure or sections not covered here (e.g., migration notes, deployment order, rollback plan)?
- **Unclear guidance**: Was the Why/What distinction hard to apply for this type of change?
- **New patterns**: Did you write a description format that worked well and should be captured as an example?

If you identified improvements, ask the user:

> "I noticed [specific observation] while writing this MR description. Would you like me to update the merge-requests rule to cover this?"

Do NOT apply changes automatically — let the user review and decide.

## Skill Authoring

Skills are Claude-compatible `SKILL.md` directories installed to `~/.agents/skills/<name>/` — the single global location read by both OpenCode and goose. This repo's skill templates live in `config/skills/`. Whenever you create or update a skill:

- Put workflow detail in the skill body. Keep frontmatter for discovery only.
- Frontmatter fields: `name` (required) and `description` (required); optionally `license`, `compatibility`, and `metadata` (a string map). Do not add other fields.
- `name`: lowercase letters, numbers, and hyphens only (`^[a-z0-9]+(-[a-z0-9]+)*$`); must match the parent folder name; max 64 chars.
- `description`: non-empty; max 1024 characters; third person; WHAT the skill does and WHEN to use it. Discovery text only, not a design doc.
- Prefer `description: >-` (folded block scalar) for anything longer than one short line, or whenever the text contains colons.

Never do this:

- Unquoted single-line `description:` containing a colon (e.g. `overview: ...` or `Modes: ...`) — YAML treats that as a nested mapping and the skill breaks.
- Em dashes, unescaped quotes, or XML angle brackets (`<` `>`) in frontmatter.
- Stuffing multi-paragraph workflow into `description`.

Validate after every create or update:

```bash
python3 -c "
import yaml
from pathlib import Path
text = Path('PATH/TO/SKILL.md').read_text()
fm = text.split('---', 2)[1]
data = yaml.safe_load(fm)
assert data.get('name')
assert isinstance(data.get('description'), str) and 0 < len(data['description']) <= 1024
print('OK', data['name'], len(data['description']))
"
```

If parse fails, fix the frontmatter before committing or declaring done.
