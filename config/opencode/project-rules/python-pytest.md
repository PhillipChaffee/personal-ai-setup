<!-- Project rule: pytest best practices for clear, reliable, maintainable tests.
     Use by pasting into a project's AGENTS.md or listing this file's path in the project's opencode.json "instructions" array. -->

# Pytest

Applies when working on Python test files (`test_*.py`, `*_test.py`, `conftest.py`) or pytest configuration (`pyproject.toml`, `pytest.ini`, `tox.ini`, etc.).

- **Test discipline**
  - Add tests when adding logic. New business logic, service functions, and non-trivial utilities should have unit tests. Don't merge logic changes without covering the happy path and at least one edge case.
  - Test before refactoring. When refactoring existing code that lacks tests, add tests for the current behavior first, then refactor with confidence.
  - Put testable logic in standalone functions, not in views, admin classes, or model methods that are hard to instantiate in tests.

- **Default to pytest-native style**
  - Write tests as plain functions named `test_*` using plain `assert` (no `unittest.TestCase`).
  - Prefer readable, specific test names that describe behavior (not implementation).
  - Keep each test focused: one behavior per test (multiple assertions are fine if they verify the same behavior).

- **Use fixtures for Arrange (and teardown), not ad-hoc setup**
  - Use fixtures to provide a consistent, explicit test context ("arrange"), and to manage teardown safely.
  - Keep fixture dependencies minimal; avoid long "fixture chains" that make failures hard to diagnose.
  - Prefer the narrowest scope that stays fast and isolated:
    - Default is function scope (best isolation).
    - Use broader scopes (`module`/`session`) only for expensive setup, and ensure no state leaks between tests.
  - Put setup/teardown in fixtures (often using `yield` for teardown) instead of manual setup/cleanup in tests:

    ```python
    import pytest


    @pytest.fixture
    def temp_env(monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("FEATURE_FLAG", "1")
    ```

  - Use `autouse=True` sparingly (it hides dependencies). Prefer explicit fixture parameters in tests.

- **Prefer built-in pytest fixtures/helpers over custom plumbing**
  - Use `tmp_path` / `tmp_path_factory` for filesystem work (prefer these over legacy `tmpdir`).
  - Use `monkeypatch` for patching env vars, attributes, cwd, `sys.path`, etc. (auto-restores after the test).
  - Use `capsys`/`capfd` for stdout/stderr assertions; use `caplog` for log assertions.
  - Use `recwarn` / `pytest.warns(...)` for warning assertions.

- **Parametrize for data-driven tests (and per-case marks)**
  - Use `@pytest.mark.parametrize` when it reduces duplication and keeps cases readable.
  - Prefer `pytest.param(...)` when a single case needs a mark (e.g., `skipif`, `xfail`) or a label.

    ```python
    import pytest


    @pytest.mark.parametrize(
        ("expr", "expected"),
        [
            ("3+5", 8),
            ("2+4", 6),
            pytest.param("6*9", 42, marks=pytest.mark.xfail(reason="example of a known bug")),
        ],
    )
    def test_eval(expr: str, expected: int) -> None:
        assert eval(expr) == expected
    ```

- **Assert exceptions and warnings explicitly**
  - Use the context-manager form of `pytest.raises` and `pytest.warns` for clarity.
  - Use `match=` to assert important parts of an error message (avoid full-string matches unless stable).
  - Avoid adding custom assertion messages unless they add real clarity; pytest's assertion rewriting is
    usually more informative than `assert x == y, "message"`.

    ```python
    import pytest


    def myfunc() -> None:
        raise ValueError("Exception 123 raised")


    def test_raises_with_message() -> None:
        with pytest.raises(ValueError, match=r".*123.*"):
            myfunc()
    ```

- **Use marks intentionally (and register custom marks)**
  - Use built-in marks like `skip`, `skipif`, and `xfail`, always with a `reason=...` that explains why.
  - Register custom marks (e.g., `slow`, `integration`) in config and enable strict marker checking to
    prevent typos from silently creating new marks.

    ```toml
    # pyproject.toml (pytest 9+ native TOML types)
    [tool.pytest]
    addopts = ["--strict-markers", "--import-mode=importlib"]
    testpaths = ["tests"]
    markers = [
      "slow: long-running tests (deselect with '-m \"not slow\"')",
      "integration: talks to external systems",
    ]
    ```
  - If you're on an older pytest, use `pytest.ini`/`tox.ini`, or `pyproject.toml` with
    `[tool.pytest.ini_options]` (INI-style options).

- **Avoid flaky tests (make failures actionable)**
  - Don't rely on test ordering or shared global state; ensure tests clean up after themselves.
  - If tests run in parallel (e.g., via `pytest-xdist`), avoid mutating shared resources unless isolated.
  - Avoid overly strict assertions:
    - Use `pytest.approx(...)` for floating-point comparisons.
  - Avoid running pytest helpers (`pytest.raises`, `pytest.warns`, etc.) from multiple threads (not thread-safe).

- **Filesystem example: tmp_path**

```python
from pathlib import Path

CONTENT = "hello"


def test_writes_file(tmp_path: Path) -> None:
    p = tmp_path / "hello.txt"
    p.write_text(CONTENT, encoding="utf-8")
    assert p.read_text(encoding="utf-8") == CONTENT
```
