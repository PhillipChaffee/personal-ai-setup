---
name: pre-mr-checklist
description: >-
  Run a pre-merge-request checklist on code changes to catch common issues before
  creating an MR. Checks inline imports, feature gate metrics, Helm values, type
  annotations, logging format, test coverage, Pydantic usage, and secrets. Use when
  the user wants to check code before an MR, asks for a pre-push review, or mentions
  "pre-MR checklist".
---

# Pre-MR Checklist

Scan changed files for common issues that should be resolved before creating a merge request.

## Prerequisites

Check #2 (Feature gate / experiment metrics) verifies gates and metrics against your
feature-flag provider when the project uses one. Prefer whatever read-only tooling that
provider already exposes in your environment. If no provider tooling is available, use a
code-only heuristic: name the gates/experiments in the diff and propose success, guardrail,
and operational metrics from the gated behavior.

## Workflow

1. Compute the merge-base and list changed files:
   `git diff --name-only $(git merge-base main HEAD)..HEAD`
2. Read each changed file
3. Run every check below against the changed files
4. Report findings grouped by severity (blockers first, then suggestions), with file paths and
   line numbers
5. Suggest fixes for each finding
6. Run the `ci-lint-test` skill to execute lint and
   test steps locally and verify CI will pass before the MR is created

## Checks

Run all checks against the changed files. Only report findings for code that was added or modified
in this branch — skip pre-existing issues in unchanged lines.

### 1. No inline imports

Imports belong at the top of the file. Flag any `import` or `from ... import` statement that appears
inside a function, method, or conditional block.

**Exceptions** (do not flag these):
- `TYPE_CHECKING` blocks (`if TYPE_CHECKING:`)
- Documented circular-import workarounds (comment must explain why)
- Deferred expensive imports with an explaining comment

**Example finding:**
```
blocker: [service/src/foo.py:42] Inline import `from bar import Baz` inside `do_thing()`.
Move to top of file.
```

### 2. Feature gate / experiment metrics

If the project uses a feature-flag provider, and the change uses `is_feature_enabled`,
`is_feature_gate_enabled`, `is_feature_enabled_for_account`, `check_gate`, `get_experiment`,
or similar feature management calls, run the four steps below for each gate/experiment found.

#### Step 2a: Extract gate/experiment names and understand the gated behavior

- Extract the gate/experiment name (the string argument to the call).
- Read both branches of the conditional (gate on vs gate off) to understand what behavior is
  being changed.
- Note the surrounding context: what service, what user-facing flow, what data is affected.

#### Step 2b: Reason about what metrics SHOULD exist

Based on the gated behavior, propose metrics needed to evaluate whether the gate/experiment is
successful. Consider three categories:

- **Success metrics**: What should improve if the gate works?
- **Guardrail metrics**: What should NOT get worse? (e.g., error rate, latency, drop-off)
- **Operational metrics**: What would help debug issues? (e.g., gate evaluation count)

For each proposed metric, note the name, what it measures, what underlying event would power
it, and whether the code already logs that event.

#### Step 2c: Verify in your feature-flag provider

Prefer whatever read-only tooling that provider already exposes in your environment (MCP, CLI,
or API). Confirm the gate/experiment exists and that the proposed metrics are attached or can
be created from events the code already logs.

If provider tooling is unavailable, skip provider verification and report only the proposed
metrics with a note that verification was skipped.

#### Step 2d: Produce a metrics report

For each gate/experiment, separate:

- What already exists and is properly configured
- What exists in the provider but needs to be attached
- What needs to be created (and from which logged events)
- Whether underlying events are already logged in code

### 3. New env vars added to Helm values

If the change references a new environment variable (via `os.environ`, `os.getenv`, settings
models, or similar):

- Search `helm/values.yaml`, `helm/values.dev.yaml`, and `helm/values.prod.yaml` in the same
  repo for the variable name.
- Flag if the variable is missing from any of those files.

**Example finding:**
```
blocker: [service/src/main.py:8] New env var `TRANSFER_TIMEOUT` referenced but not found
in service/helm/values.dev.yaml or service/helm/values.prod.yaml. Missing values = crash on deploy.
```

### 4. Type annotations on all new functions

Every new or modified function (including test functions) must have argument and return type
annotations. Flag any that are missing.

Do **not** flag:
- Decorators or lambdas
- Functions that already had missing annotations and were not modified in this branch

**Example finding:**
```
blocker: [service/src/utils.py:55] Function `calculate_delay` is missing return type annotation.
```

### 5. No f-strings in logging

Logging calls (`logger.debug`, `logger.info`, `logger.warning`, `logger.error`,
`logger.exception`, `logger.critical`) must use lazy `%s` formatting, not f-strings or
`.format()`.

Inside `except` blocks, prefer `logger.exception(...)` over `logger.error(...)` — it
automatically includes the traceback.

**Example finding:**
```
blocker: [service/src/service.py:73] f-string in logging call:
`logger.info(f"Processed {count} records")`. Use `logger.info("Processed %s records", count)`.
```

### 6. Tests for behavior changes

If the change modifies business logic, adds a new code path, or changes error handling:

1. Identify the changed symbols (function names, class names, method names) from the diff.
2. Search existing test files for references to those symbols — look for direct calls,
   parametrized test cases, fixtures, and shared test helpers that exercise the changed code.
3. Only flag missing coverage if no existing or new tests reference the changed symbols.

Do **not** flag:
- Pure refactors that don't change behavior (renames, moves, formatting)
- Configuration-only changes (Helm values, CI files)
- Changed code that is already covered by existing tests (even if the test file was not modified
  in this branch)

**Example finding:**
```
suggestion: [service/src/transfers/store.py:120] New method `handle_transfer_timeout` added
but no tests in test_store.py or other test files reference `handle_transfer_timeout` or
exercise the TransferTimeout path.
```

### 7. Pydantic models for new structured data

If the change introduces a new `TypedDict`, `dataclasses.dataclass`, or raw `dict` for a DTO,
API response, or structured data container, flag it and suggest using `pydantic.BaseModel`
instead.

**Exceptions** (do not flag):
- `TypedDict` used for interop with libraries that require plain dicts
- `dataclass` for small internal containers where validation is unnecessary (must be clearly
  internal-only)

**Example finding:**
```
suggestion: [service/src/models/booking.py:15] New `TypedDict` `BookingResponse` should be a
`pydantic.BaseModel` for validation and serialization.
```

### 8. No hardcoded secrets or credentials

Flag any strings that look like API keys, tokens, passwords, or connection strings hardcoded in
source files. Also flag sensitive data being logged (keys, tokens, PII).

Check that error messages and exception strings do not expose internal details (stack traces,
database schemas, internal hostnames).

**Example finding:**
```
blocker: [service/src/clients.py:12] Hardcoded API key `sk-abc123...`. Move to environment
variable and reference via settings.
```

## Output Format

```markdown
## Pre-MR Checklist Results

**Branch**: `feature/my-branch` (vs `main`)
**Files scanned**: 12

### Blockers (must fix)
- [file:line] Description and suggested fix
- [file:line] Description and suggested fix

### Suggestions (recommended)
- [file:line] Description and suggested fix

### Clean checks
- No inline imports found
- Type annotations present on all new functions
- ...

All checks passed / N issues found across M files.
```

List every finding with its file path and line number. Group by severity (blockers first, then
suggestions). End with a summary of which checks passed cleanly.

## Self-Improvement

After running the checklist, reflect on whether it should be updated:

- **New patterns**: Did the review surface a recurring issue not covered by any check?
- **Missing guidance**: Was a check ambiguous or hard to apply to this type of change?
- **Scope gaps**: Did you skip a finding because no check covered it, but it clearly should
  have been caught?

If you identified improvements, ask the user:

> "I noticed [specific observation] while running this checklist. Would you like me to update
> the pre-MR checklist skill to cover this?"

Do NOT apply changes automatically — let the user review and decide.
