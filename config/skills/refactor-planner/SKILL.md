---
name: refactor-planner
description: Use when the user asks for a refactor plan, refactoring strategy, or plan to clean up or restructure code before touching it; mentions paying down technical debt or tech debt in a specific area; wants to design behavior-preserving changes to a file, function, module, or directory before implementation; or says they want to refactor X but plan it first.
---

# Refactor Planner

Produce a structured, behavior-preserving refactoring plan for a specified target (file, function, module, or directory). The plan is **executor-ready**: each phase has an id, files, validation command, atomic commit message, and rollback instruction so a future executor (or you, manually) can pick it up phase-by-phase.

## When to use / when not to use

**Use** when:
- Refactoring before adding features in an area.
- Modernizing legacy code with a known target end-state.
- Planning multi-step cleanup that needs sequencing and test gates.
- Paying down technical debt in a defined scope.

**Do not use** when:
- The request is "review this diff" — that's the `cr-*` code-review family.
- The request is for an architecture rewrite or system redesign — use a design-doc / planning flow.
- The change is a single-line tweak — just make the change.
- The request is to fix a bug — use the bug-fix flow; this skill is behavior-preserving.

## Architecture

You orchestrate two readonly scout subagents in parallel:

- **`refactor-code-scout`** — detects behavioral / size / complexity smells and naming smells in the target files.
- **`refactor-placement-scout`** — detects placement / cohesion smells and Convention Drift findings against framework best practices for the detected project type.

Both scouts return *findings*, never *fixes*. Synthesis into the executor-ready plan is your job. The pattern mirrors `code-review` (parallel readonly reviewers + main-agent synthesis).

## Reference files (loaded on demand)

Lean SKILL.md; detail lives in on-demand reference files under `references/` next to this SKILL.md (installed at `~/.agents/skills/refactor-planner/references/`):

- `references/code-smells.md` — full smell catalog. **Consumed by**: `refactor-code-scout` (mandatory load).
- `references/refactoring-catalog.md` — named-refactoring catalog with before/after sketches. **Consumed by**: this skill (Step 7) for smell→refactoring mapping.
- `references/placement-django.md` — HackSoft Django placement. **Consumed by**: `refactor-placement-scout` when project type is `django-app`.
- `references/placement-fastapi.md` — Netflix Dispatch domain layout. **Consumed by**: `refactor-placement-scout` when `fastapi-service`.
- `references/placement-python-package.md` — PyPA src-vs-flat. **Consumed by**: `refactor-placement-scout` when `python-package`.
- `references/placement-helm.md` — Helm chart structure. **Consumed by**: `refactor-placement-scout` when `helm-chart`.
- `references/placement-clean-architecture.md` — Clean Architecture / DDD / hexagonal. **Consumed by**: `refactor-placement-scout` when applicable as evaluation target.
- `references/placement-cli.md` — CLI tool placement. **Consumed by**: `refactor-placement-scout` when `cli-tool`.
- `references/placement-tests.md` — test suite layout. **Consumed by**: `refactor-placement-scout` when `test-suite`.

## Workflow

### Step 1 — Gather inputs

Ask the user if any are missing or ambiguous:

- **Target path(s)** — file, function, directory, or module to refactor.
- **Goal / motivation** — cleanup vs preparing for a feature vs paying down debt. Drives scope and depth.
- **Scope cap** — file vs module vs directory vs whole package. Prevents drift into a bigger refactor than the user intended.
- **Test coverage state** — does the target have tests? Is the user willing to add characterization tests as Step 0 if not?

If the user says "refactor X" without details, ask all four. If they give clear scope and goal, ask only what's still ambiguous.

### Step 2 — Establish baseline

Snapshot the "before" state so the refactor doesn't regress it:

- **Read every target file in full.** Don't judge code you haven't read. (You'll do an initial pass; the scouts will re-read in their isolated contexts.)
- **Identify the project / package containing the target** — the smallest unit that owns its own dependency manifest and test runner. Infer from the workspace (e.g. `service-b/`, `service-a/`, `shared/<package>/`).
- **Detect the project's tooling** — read `pyproject.toml` (or equivalent) to discover the dependency manager (Poetry / uv / hatch / pdm / pip), test runner (pytest / unittest / nose), linter (ruff / pylint / flake8 / black), and type checker (mypy / pyright / basedpyright). **Use whatever the project actually has** — never hardcode `poetry run` commands.
- **Locate tests covering the target.**
- **Run the project's test command** on the relevant path to confirm green. If no tests exist or any fail, **Step 0 of the produced plan must be characterization tests for current behavior** — universal "test before refactor" principle (Fowler), codified locally in the `python-pytest` rule.
- **Run the project's lint and type-check commands** and record output as the baseline that the refactor must not regress.
- **Record current `git rev-parse HEAD`** so any phase can roll back to a known-good base.

### Step 3 — Detect project type

Look at filesystem signals around the target:

- `apps.py` / `models.py` / `views.py` adjacent → `django-app`
- `main.py` with `FastAPI()` plus `routes/` or `routers/` → `fastapi-service`
- `Chart.yaml` → `helm-chart`
- `pyproject.toml` without an app entry point → `python-package`
- `__main__.py` + `commands/` → `cli-tool`
- `tests/` directory or `test_*.py` only → `test-suite`
- Multiple matches → `mixed`

Project type drives which `references/placement-<type>.md` the placement scout loads.

### Step 4 — Map dependencies

Use Grep + targeted reads:

- **Callers** — who calls into the target? File paths and line numbers.
- **Callees** — what does the target call?
- **Cross-service / cross-deployable consumers** — does another deployable depend on a request/response shape, message-broker schema, or event format the target produces or consumes? If the target is on a contract surface, the produced plan must call out **consumer-first deploy ordering**. Apply this to any inter-service contract (e.g. service-b↔service-a).

Pass the resulting dependency map to both scouts in Step 5.

### Step 5 — Fan out scouts in parallel

Spawn both readonly scouts simultaneously via the task tool, in a single message containing both calls:

- First call: the `refactor-code-scout` agent (`~/.config/opencode/agents/refactor-code-scout.md`)
- Second call: the `refactor-placement-scout` agent (`~/.config/opencode/agents/refactor-placement-scout.md`)

Run both scouts on `opencode/kimi-k2.6`. Pass the model explicitly. If a named scout agent is
unavailable, use `general` with its `~/.config/opencode/agents/` definition inlined and the same model.

**Inputs to pass to `refactor-code-scout`**:
- Target paths
- Project type (from Step 3)
- Dependency map (from Step 4)
- Path to `references/code-smells.md` (mandatory load)
- Path to `references/refactoring-catalog.md` (for optional "suggested direction" hints)

**Expected output**: structured findings of behavioral / size / complexity smells + naming smells (or the exact-match no-findings line).

**Inputs to pass to `refactor-placement-scout`**:
- Target paths
- Project type (from Step 3)
- Dependency map (from Step 4)
- The Universal placement principles inline (see below)
- Path to the matching `references/placement-<type>.md`

**Expected output**: detected architectural style + placement smells (Findings table with Confidence + ROI) + Convention Drift rule-violation tuples + placement summary (or the exact-match no-findings line).

#### Universal placement principles (pass inline to placement scout)

These apply to all project types. They live here in SKILL.md (not in a reference file) because they're short, timeless, and always relevant:

- **Cohesion (Common Closure Principle)** — things that change together stay together; things that don't change together don't stay together.
- **Low coupling** — modules know as little about each other as possible. Interfaces over implementations. No circular dependencies.
- **Dependency direction** — high-level policy on top, low-level details below; dependencies flow inward only. Domain depends on nothing.
- **Screaming architecture** — top-level folders name the *domain* (`payments/`, `users/`, `leads/`), not the *framework layer* (`controllers/`, `models/`). Reading the directory tree should reveal *what the system does*, not *what framework it uses*.
- **Locality of behavior** — related changes happen in nearby files. If touching one feature requires editing 5+ scattered files, you have Shotgun Surgery.
- **Visibility / encapsulation** — minimize public API. Use `__init__.py` re-exports as the package's contract; don't reach into internal modules from outside the package.
- **Symmetry / consistency** — similar things in similar places. Principle of least surprise.
- **Naming describes structure** — file/folder paths are documentation. `metadata_parsing.py` good; `helpers.py` / `utils.py` / `common.py` / `misc.py` as leaf files bad (they become dumping grounds — universal anti-pattern).
- **Bucket size discipline (heuristics, not contract)** — files ≲ 300 lines, classes ≲ 200 lines, functions ≲ 30 lines, folders ≲ 15–25 files. Crossing a threshold is a smell signal, not an automatic refactor trigger.
- **Single responsibility per bucket** — a file, class, or module should have one reason to change. Multiple unrelated reasons → Extract Module / Class.
- **Tests mirror source** — for any non-trivial test suite, `tests/<module>/test_<thing>.py` mirrors `src/<module>/<thing>.py`.

### Step 6 — Synthesize scout findings

Collect both scouts' outputs.

- **Deduplicate** where overlap occurs. If a Long Method is also Misplaced (write-side workflow buried in `views.py`), credit it once with both lenses noted in the description.
- **Rank consolidated smells** by HIGH / MEDIUM / LOW.
- **"Start here" pointer** — explicitly call out the highest-impact issue at the top, so the user knows where to begin.
- **Keep Convention Drift findings in their own section** — separate from in-scope refactorings. Each tuple is opt-in per row; the user may choose to defer alignment to a follow-up.

If both scouts returned the exact-match no-findings line, the plan can simply say "no actionable refactor identified — the target is already in good shape" and stop.

### Step 7 — Map smells to named refactorings

For each smell that's in scope (HIGH and MEDIUM by default; LOW only if trivial), pick a named refactoring from `references/refactoring-catalog.md`. Three families:

- **Logic / size**: Extract Method, Extract Class, Inline Method, Inline Variable, Replace Conditional with Polymorphism, Introduce Parameter Object, Replace Magic Number with Symbolic Constant, Replace Nested Conditional with Guard Clauses, Decompose Conditional, Split Loop, Extract Variable, Combine Functions into Class, Combine Functions into Transform, Split Phase.
- **Naming (renames)**: Change Function Declaration (= Rename Function, also covers parameter changes), Rename Variable, Rename Field (= rename DB column in any ORM — generates a migration; flag for **expand-contract / Parallel Change** pattern), Rename Class, Rename Module, Rename File, Rename Directory. **Propose the actual new name** — don't say "rename for clarity."
- **Placement (moves)**: Move Function (across files/modules), Move Class, Move Field, Move Statements Into / Out Of Function, Pull Up Method / Field, Push Down Method / Field, Extract Module / File / Package (when a logical bucket has emerged). **Each move includes both source and destination path.**

### Step 8 — Sequence as smallest verifiable steps

Each step should be:

- **Independently testable** — running the validation command after this step passes/fails the step on its own.
- **Atomic-commit shaped** — one named refactoring per phase. No mixing.
- **Test-gated** — the validation command runs and passes before moving to the next step.
- **Rollback-able** — a clean `git revert <commit>` or restore-from-base instruction.

**Default order**:

1. **Renames first** — cheap, high-clarity, unblocks reasoning for later phases.
2. **Moves next** — once names are correct, it's clear what should live where.
3. **Logic refactorings last** — Extract Method, Replace Conditional, etc. Easier when names and locations are settled.

**Observe and adapt**: the plan is best-effort, not a contract. Note in the plan output that later phases may shift after earlier phases land — re-evaluate after each.

### Step 9 — Final naming/placement consistency check

Before producing output:

- **For every proposed Move**: confirm the destination matches what the placement scout's reference recommended for the project type. If the scout flagged Convention Drift on the destination shape, the move should align toward the recommendation, not perpetuate the drift.
- **For every Rename**: confirm the new name matches the language's case conventions (PEP 8 for Python, similar canonical guides for other languages) and the repo's existing vocabulary for the concept (grep the codebase for existing names of the same concept).

## Naming guardrails (apply to every Rename you propose)

### Universal naming principles

- **PEP 8 case conventions** (Python):
  - `snake_case.py` for files and module-level identifiers.
  - `PascalCase` for classes and `TypedDict` / Pydantic / dataclass types.
  - `UPPER_SNAKE_CASE` for module-level constants.
  - `_leading_underscore` for module-private; `__double_leading` only for name-mangled class internals.
  - Test files: `test_*.py`; test functions: `test_*`.
- **Reveal intent over brevity** — `customer_id` beats `cId`; `pending_request_count` beats `n`.
- **Functions are verb phrases**; classes and modules are noun phrases.
- **Booleans and predicates read like questions** — `is_active`, `has_pending_items`, `should_retry`.
- **Consistent vocabulary** — if a concept has an established name in the codebase, don't introduce variants. Grep for existing names before proposing a new one.
- **No abbreviations unless broadly idiomatic in the language/ecosystem or domain-standard in the project** — accept `ctx`, `db`, `id`, `pk`, `api`, `tz`, `req`/`res`. Reject ad-hoc abbreviations of domain words (`ag` for `agent`, `cmpny` for `company`).
- **No type-prefix / Hungarian** — never `str_name`, `dict_options`, `list_items`, `bool_active`.
- **Module/file names describe contents** — `metadata_parsing.py` good; `helpers.py` / `misc.py` / `common.py` as leaf files bad.
- **Logs carry enough identifiers to correlate a unit of work end-to-end** — refactorings that touch logging must preserve or add domain-relevant correlation IDs.

### Schema-touching renames are not pure renames

- **DB-column renames** (Rename Field on an ORM model) generate migrations and require the **expand-contract pattern** (Parallel Change): add new column → migrate code to use it → defer old → drop in follow-up release. Codified locally in the `engineering` rule.
- **Public-API renames** (HTTP endpoint, GraphQL field, gRPC method, message broker topic) break consumers. Same expand-contract pattern with consumer-first deploy ordering.

## Other guardrails

### Universal refactoring guardrails

- **Best practice is the target; local convention is the current state** — when they conflict, default to recommending best practice and flag the deviation as a Convention Drift finding (placement scout produces these). Honor local convention only when an explicit project rule documents the deviation as deliberate.
- **Iron law: behavior preservation** — green tests before AND after each step. If tests can't run or aren't green, Step 0 of the plan is fixing that.
- **80/20 — don't refactor everything** — surface the highest-leverage smells first; flag low-impact items as "out of scope unless trivial" rather than padding the plan.
- **Know when to stop** — perfect is not the goal. The plan ends when the target is "good enough"; aim for shipping value, not architectural beauty.
- **Observe and adapt** — sequence is a best-effort plan, not a contract; revisit later phases after earlier ones land.
- **No scope creep** — refactoring only; no feature additions, no unrelated bug fixes mixed in.
- **Prefer deletion over abstraction** when code is no longer needed.
- **Rule of Three** — don't abstract until a pattern repeats 3+ times. Duplication is cheaper than the wrong abstraction.
- **Atomic commits** — one refactoring per commit, never amend or force-push shared branches.
- **Cross-service contracts** — if the target touches a request/response shape consumed by another deployable, require consumer-first deploy ordering.
- **Schema/migration safety** — DB schema changes follow expand-contract: add new field → migrate code → defer old → drop in follow-up.
- **Architectural best practices to honor by default** (move local code *toward* these when refactoring):
  - Thin web/API layers; business logic in a service layer.
  - Use framework built-ins before building custom.
  - Validate external data at boundaries (Pydantic, DRF serializers, JSON Schema, similar).
  - ORM features (managers, querysets, `select_related`/`prefetch_related`) before raw SQL or N+1 loops.
  - Async work in background tasks for anything that calls external APIs, processes large datasets, or could block a request.

### Repo-specific conventions (honor when refactoring in this workspace)

These are stricter or different from generic best practice and are documented as deliberate in this workspace. Don't export them as universal advice:

- **Type-annotate all functions** including tests (per the `python` rule).
- **Pydantic models for new DTOs** over `TypedDict` / `dataclass` / raw `dict`s (per the `python` rule).
- **Standalone functions over `@staticmethod`** (per the `engineering` rule).
- **Class section headers** `Properties` / `Public methods` / `Private methods` with the specific `===`/`---` comment style (per the `python-class-sections` rule).
- **100-character line limit** (per the `python` rule).
- **No commit amends or force-pushes**, even on personal branches (per the `engineering` rule).
- **`models.TextChoices`** for Django string enum fields (per the `python` rule).

## Output format (executor-ready plan)

Produce the plan as markdown with the following sections, in order. Return the markdown inline and offer to save it to `.agents/plans/refactor_<target>_<hash>.plan.md`.

```markdown
# Refactor plan: <target>

## Goal
<1–2 sentences on what & why>

## Target
<files / dirs / symbols in scope>

## Project / package
<the smallest unit owning its own dependency manifest and test runner>

## Detected tooling
- Dependency manager: <poetry | uv | hatch | pdm | pip>
- Test runner: <pytest | unittest | ...>
- Linter: <ruff | pylint | flake8 | ...>
- Type checker: <mypy | pyright | basedpyright | ...>

## Base commit
`<git rev-parse HEAD>`

## Baseline snapshot
- Tests: <command> — <pass | fail with summary>
- Lint: <command> — <clean | N issues>
- Types: <command> — <clean | N issues>

## Dependencies & consumers
<callers, callees, any cross-service contract surface; explicit deploy-order callout if relevant>

## Project type detected
<django-app | fastapi-service | python-package | helm-chart | cli-tool | test-suite | mixed> — references loaded: <list>

## Detected architectural style
<from placement-scout, e.g. "Layered Django app with services.py write side; no selectors split. Closest to HackSoft styleguide.">

## Strengths
- (1–3 bullets surfaced by either scout, optional)

## Smells found

### Start here
<one-line pointer to the highest-impact finding>

### Behavioral / size / complexity
- [HIGH] <smell name> at `path:line` — <why it matters> (Confidence: high; Suggested: <one-line refactoring name>)
- [MEDIUM] ...

### Naming
- [HIGH] ...

### Placement / cohesion
- [HIGH] <smell name> at `path:line` — <why it matters> (Confidence: high; ROI: Quick Win | Strategic)
- ...

## Renames proposed

| old name | new name | kind | rationale |
|----------|----------|------|-----------|
| `cId` | `customer_id` | variable | Inconsistent Vocabulary — repo uses `customer_id` |
| `oldField` | `new_field` | db_field | Mysterious Name — flagged for expand-contract migration |

## Moves proposed

| from | to | kind | rationale |
|------|-----|------|-----------|
| `app/views.py:88-142` | `app/services.py` | function | write-side workflow misplaced in HTTP layer per HackSoft styleguide |

## Convention Drift findings (opt-in per row)

- **Rule:** <named expectation>
  - **Source:** `references/placement-<type>.md` (locator)
  - **Observation:** `path:line` — <description>
  - **Verdict:** error | warning | accepted
  - **Suppression citation:** (only if `accepted`) — path + quoted clause
  - **Remediation:** <one line>
  - **Trade-off:** (optional, only when non-obvious)

## Placement summary
<one paragraph: where things end up after the in-scope refactor lands — 30-second sanity check>

## Phases

### Phase 1: <slug>
- **id:** phase-1-<slug>
- **kind:** rename | move | extract | inline | replace | combine | split | mixed
- **status:** pending
- **description:** <one sentence on the named refactoring>
- **files:** `path/a`, `path/b` (source), `path/c` (destination, for moves)
- **before sketch (≤10 lines):**
  ```
  <illustrative current code>
  ```
- **after sketch (≤10 lines):**
  ```
  <illustrative target code>
  ```
- **validation:** `<exact test command>` and `<lint command>` and `<type command>`; for DB renames, include migration step.
- **commit_message:** `refactor(<scope>): <atomic shape>`
- **rollback:** `git revert <commit-sha>` (or restore-from-base instruction)

### Phase 2: <slug>
...

## Sequence & parallelizability
<strict order vs independent steps; observe-and-adapt note>

## Risks
- <missed call sites for renames>
- <cross-service contract impact for moves>
- <migration ordering for DB field renames>

## Out of scope
- <explicit list of things deliberately not touched, prevents scope creep>

## Stop criteria
<when to call the refactor done — usually "all phases land green; no new HIGH smells from re-running scouts">
```
