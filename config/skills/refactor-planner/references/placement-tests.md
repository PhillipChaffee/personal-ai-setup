# Placement reference — Test suite

Loaded by `refactor-placement-scout` when the orchestrator detects `project type: test-suite` (the target is primarily test code: a `tests/` directory or a collection of `test_*.py` files).

Anchored on pytest conventions plus universal test-organization principles.

---

## Layer placement (where each kind of test lives)

### Tests mirror source

For any non-trivial test suite, `tests/<module>/test_<thing>.py` mirrors `src/<module>/<thing>.py`. The mirror makes it trivial to:

- Find the test for a given source file (and vice versa).
- Run only the tests for the module you're touching.
- Detect untested modules (a missing mirror is a coverage gap).

```
src/
├── payments/
│   ├── invoice.py
│   └── payment.py
└── users/
    └── auth.py

tests/
├── payments/
│   ├── test_invoice.py
│   └── test_payment.py
└── users/
    └── test_auth.py
```

### Test type folders (when needed)

If the suite has distinct test types with different runtime / setup costs, separate them at the top level:

```
tests/
├── unit/                  # fast, isolated, no I/O
├── integration/           # touches DB, external services
├── e2e/                   # full-system, slow
├── property/              # hypothesis tests
└── performance/           # benchmarks
```

Each subtype mirrors `src/` internally if the suite is large enough.

### `conftest.py`

Pytest fixtures and hooks. Place at the **smallest scope that suffices**:

- Top-level `tests/conftest.py` — fixtures used everywhere.
- Per-module `tests/<module>/conftest.py` — fixtures only that module uses.
- Per-class — `@pytest.fixture(scope="class")` inside a test file.

The smaller the scope, the faster failures localize and the cleaner the dependency graph.

### Markers

Custom markers (`slow`, `integration`, `e2e`, `flaky`) registered in `pyproject.toml` / `pytest.ini`:

```toml
[tool.pytest.ini_options]
addopts = ["--strict-markers"]
markers = [
  "slow: long-running tests (deselect with '-m \"not slow\"')",
  "integration: talks to external systems",
  "e2e: full end-to-end tests",
]
```

`--strict-markers` enforces that every marker is declared, preventing typos from silently creating new marks.

---

## Universal principles applied to test suites

- **Group by behavior, not by file.** A test name describes what's being verified, not which file/function is exercised.
- **One behavior per test.** Multiple assertions are fine if they verify the same behavior; "and" in the test name is a smell.
- **Pytest-native style** — plain functions named `test_*`, plain `assert`, fixtures for arrange/teardown. No `unittest.TestCase` for new tests.
- **Use built-in fixtures** — `tmp_path`, `monkeypatch`, `capsys`, `caplog` over ad-hoc plumbing.
- **Parametrize for data-driven tests** — `@pytest.mark.parametrize` reduces duplication.
- **Avoid shared mutable state** — order-dependent tests are flaky; clean up after yourself.

---

## Common test-suite drift the scout should flag

- **Tests not mirroring source** when the suite is non-trivial (10+ files, 100+ tests) — Convention Drift. Verdict: `warning`. Mirror improves discoverability.
- **`conftest.py` at top level with everything** in it, including fixtures only one test uses — Grab-bag File. Verdict: `warning`. Push fixtures to the smallest scope that suffices.
  - **Exception:** intentional **fixture chains** (composable building blocks where each fixture depends on the previous, e.g. `company → payments_group → plan → catch_all_rule`) are not Grab-bag — keep them in conftest even when only a subset of tests uses every link. The smell is unrelated fixtures lumped together, not fixture chains with partial usage.
- **`unittest.TestCase`** in new tests when the suite is otherwise pytest-native — Convention Drift. Verdict: `warning`.
- **Custom markers without `--strict-markers`** registered — Convention Drift. Verdict: `warning`. Typos silently create new marks.
- **Test files mixing unit / integration / e2e** without separation — Mixed responsibility. Verdict: `warning`. Separate by speed/setup cost.
- **`test_*.py` files at the source-package root** alongside production code (without a `tests/` separation) — generally a Layer-shaped vs Domain-shaped Drift smell, **but** PyPA's tests-inside-the-package pattern is a defensible alternative for small libraries. Honor whichever the project documents.
- **Tests using subprocess to invoke functions** that could be called directly — slow, hard to debug. Verdict: `warning`.
- **Mocked everything** — tests that mock out the system under test verify the mock, not the code. Verdict: `warning`.

---

## What "aligned" looks like (target shape)

```
project/
├── src/
│   └── my_pkg/
│       ├── payments/
│       │   ├── invoice.py
│       │   └── payment.py
│       └── users/
│           └── auth.py
└── tests/
    ├── conftest.py                      # global fixtures
    ├── unit/
    │   ├── payments/
    │   │   ├── conftest.py              # payments-only fixtures
    │   │   ├── test_invoice.py
    │   │   └── test_payment.py
    │   └── users/
    │       └── test_auth.py
    ├── integration/
    │   └── payments/
    │       └── test_invoice_api.py
    └── e2e/
        └── test_checkout_flow.py
```
