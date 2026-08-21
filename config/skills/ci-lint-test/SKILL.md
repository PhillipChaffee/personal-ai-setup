---
name: ci-lint-test
description: Parse a project's CI pipeline file (.gitlab-ci.yml) and run all lint and test steps locally before pushing. Use when preparing to push changes, verifying CI will pass, or when the user asks to run pipeline steps, check CI locally, or test before push.
---

# CI Lint and Test Runner

Run lint and test steps from the CI pipeline file locally to verify CI will pass before pushing.

## Workflow

Copy this checklist and track progress:

```
Task Progress:
- [ ] Step 1: Find and parse CI pipeline file
- [ ] Step 2: Identify lint/test jobs
- [ ] Step 3: Extract runnable commands
- [ ] Step 4: Run commands locally
- [ ] Step 5: Fix any failures
- [ ] Step 6: Re-run to verify fixes
```

## Step 1: Find and Parse Pipeline File

Look for `.gitlab-ci.yml` in the project root:

```bash
ls -la .gitlab-ci.yml
```

Read the file to understand the pipeline structure.

## Step 2: Identify Lint/Test Jobs

Look for jobs in stages like:
- `lint`, `lint-test`, `test`, `check`, `validate`
- Jobs with names containing: `lint`, `test`, `check`, `format`, `type`

Focus on jobs that run code quality checks, NOT build/deploy jobs.

**Common patterns to identify:**
- Jobs using `pytest`, `ruff`, `mypy`, `black`, `flake8`, `eslint`, `jest`
- Jobs in early pipeline stages
- Jobs that don't require CI-specific services (docker, kubernetes, etc.)

## Step 3: Extract Runnable Commands

From each lint/test job, extract the `script:` section. Filter out:

| Skip These | Reason |
|------------|--------|
| `pip install` / `poetry install` | Assume dependencies already installed |
| `apt-get`, `yum` | System package managers |
| `git config` | CI-specific git configuration |
| `docker` commands | Requires Docker service |
| `aws`, `your-cluster-cli`, `helm` | Deployment commands |
| CI variable references like `$CI_*` | Not available locally |

**Keep these commands** (common lint/test commands):
- `poetry run pytest` / `pytest`
- `poetry run ruff check` / `ruff check`
- `poetry run ruff format --check` / `ruff format --check`
- `poetry run mypy` / `mypy`
- `poetry run black --check` / `black --check`
- `npm test` / `npm run test`
- `npm run lint`
- `make test` / `make lint`

## Step 4: Run Commands Locally

Run each extracted command in sequence. For Poetry projects, typical order:

```bash
# Linting (run first - faster feedback)
poetry run ruff check .
poetry run ruff format --check .
poetry run mypy .

# Tests (run after linting passes)
poetry run pytest
```

For npm/Node projects:

```bash
npm run lint
npm test
```

**If a command fails**, stop and proceed to Step 5.

## Step 5: Fix Failures

### Ruff Check Failures
```bash
poetry run ruff check --fix .
```
Then review remaining errors and fix manually.

### Ruff Format Failures
```bash
poetry run ruff format .
```
This auto-fixes formatting issues.

### Mypy Failures
- Add type annotations
- Fix type mismatches
- Use `# type: ignore[error-code]` as last resort

### Pytest Failures
- Read the test output carefully
- Fix failing assertions or update tests if behavior intentionally changed
- Check mock setups match function signatures

## Step 6: Verify All Fixes

Re-run all lint/test commands to confirm everything passes:

```bash
# Example for Poetry project
poetry run ruff check . && poetry run ruff format --check . && poetry run mypy . && poetry run pytest
```

Only push when all commands pass.

## Quick Reference

| Framework | Lint Command | Test Command |
|-----------|--------------|--------------|
| Poetry/Python | `poetry run ruff check . && poetry run mypy .` | `poetry run pytest` |
| npm/Node | `npm run lint` | `npm test` |
| Make | `make lint` | `make test` |
| Go | `go vet ./...` | `go test ./...` |
| Rust | `cargo clippy` | `cargo test` |

## Handling Special Cases

### Jobs with `extends:`
Follow the inheritance chain to get the full job definition.

### Jobs with `include:`
Note that external files may define additional jobs. Check for local includes.

### Jobs with `needs:` or `dependencies:`
Skip jobs that depend on build artifacts - these can't run locally.

### Jobs with `services:`
Skip jobs requiring docker services (databases, etc.) unless user has them running.

## Self-Improvement

After running this skill, reflect on the execution:

- Were there CI commands or patterns not covered by the workflow?
- Did you encounter edge cases in pipeline parsing (e.g., `include:`, `extends:`, docker-dependent jobs)?
- Were the filtering rules sufficient for identifying runnable commands?
- Did any tool-specific guidance need expansion (Poetry, npm, Make, etc.)?

If you identified gaps or learned new patterns during execution, ask the user:

```
I noticed [specific pattern/gap] while running the CI lint/test workflow.
Would you like me to update this skill to include guidance on [improvement]?
```
