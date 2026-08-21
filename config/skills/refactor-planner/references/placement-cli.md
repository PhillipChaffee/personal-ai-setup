# Placement reference — CLI tool

Loaded by `refactor-placement-scout` when the orchestrator detects `project type: cli-tool` (presence of `__main__.py` + a `commands/` directory or a Click/Typer app entry).

---

## Layer placement (where each kind of code lives)

### Package root

- `__init__.py` — package init; may re-export the CLI entry for `python -m <pkg>` invocation.
- `__main__.py` — entry point for `python -m <pkg>`. Thin: imports the CLI app and runs it.
- `cli.py` (or `app.py`) — the Click / Typer / argparse app definition; root command and group declarations.
- `config.py` — global settings (env-var loading, defaults).
- `version.py` — version string / `__version__`.

### `commands/`

One sub-command per file. Each file declares its command with the CLI framework's decorator and the command's logic delegates to a service / library function.

- `commands/__init__.py` — re-export commands or register them.
- `commands/<verb>.py` per sub-command (e.g. `commands/list.py`, `commands/create.py`).

If sub-commands are grouped (multi-level CLIs), use a sub-directory per group:

```
commands/
├── users/
│   ├── __init__.py
│   ├── create.py
│   ├── list.py
│   └── delete.py
└── projects/
    └── ...
```

### Library logic

The CLI is a **thin entry point**. The actual work lives in:

- `<pkg>/services/` (or domain-named modules) — the library functions that commands call into.
- This split lets the same logic be reused from a Python API or a future web service without duplication.

### Tests

Tests mirror the source. CLI tests use the framework's testing utilities (Click's `CliRunner`, Typer's `CliRunner`).

---

## Universal principles applied to CLI tools

- **CLI is presentation layer.** Parse args, call into services, format output. No business logic in command handlers.
- **One command, one file.** Sub-commands shouldn't share a file unless they're trivially small.
- **Use Click or Typer** for non-trivial CLIs — they handle help, types, validation, completion.
- **`config.py` per CLI**, not global env-var spelunking inside command handlers.
- **Output formats** (`--json`, `--yaml`, `--text`) belong in formatter modules, not in command handlers.

---

## Common CLI drift the scout should flag

- **Business logic in `commands/<verb>.py`** instead of delegating to a service — Misplaced Function/Class. Verdict: `error`.
- **Multiple sub-commands in one file** when they have unrelated concerns — Grab-bag File. Verdict: `warning`.
- **`argparse` in a non-trivial CLI** — modernize to Click/Typer if the CLI has > a few commands and > a few flags. Verdict: `warning`.
- **Direct `os.environ.get(...)` calls scattered through command handlers** — Misplaced configuration. Verdict: `warning`. Centralize in `config.py`.
- **`print` calls instead of a formatter abstraction** when the CLI supports multiple output formats — Misplaced Function/Class. Verdict: `warning`.
- **Tests that invoke the CLI via subprocess** instead of using the framework's test runner — slower, harder to debug. Verdict: `warning`.

---

## What "aligned" looks like (target shape)

```
my-cli/
├── pyproject.toml
├── README.md
├── src/
│   └── my_cli/
│       ├── __init__.py
│       ├── __main__.py             # python -m my_cli
│       ├── cli.py                  # Click/Typer app, root group
│       ├── config.py               # settings
│       ├── version.py
│       ├── commands/
│       │   ├── __init__.py
│       │   ├── users/
│       │   │   ├── __init__.py
│       │   │   ├── create.py
│       │   │   └── list.py
│       │   └── projects/
│       │       └── ...
│       ├── services/               # library logic; reusable from non-CLI consumers
│       │   ├── users.py
│       │   └── projects.py
│       └── formatters/
│           ├── json_formatter.py
│           └── text_formatter.py
└── tests/
    └── commands/
        ├── users/
        │   ├── test_create.py
        │   └── test_list.py
        └── ...
```
