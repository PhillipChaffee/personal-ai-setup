# Placement reference — Python package / library

Loaded by `refactor-placement-scout` when the orchestrator detects `project type: python-package`.

Anchored on the [PyPA `src` vs flat layout discussion](https://packaging.python.org/en/latest/discussions/src-layout-vs-flat-layout/) and the [Real Python project layout guide](https://www.realpython.com/ref/best-practices/project-layout/), with [PEP 561](https://peps.python.org/pep-0561/) for typed packages.

---

## Detected style cues

Two main layouts; both are valid; the scout's job is to evaluate against the chosen layout, not to force a preference.

- **`src/` layout** — importable code lives under `src/<package>/`. PyPA-recommended for libraries that will be installed/distributed; prevents accidental imports from the project root and forces tests to use the installed package.
- **Flat layout** — importable code lives at the project root in `<package>/`. Simpler for in-process apps; doesn't require an editable install for development.

Pick a side. If the project's documentation states a choice, honor it; don't flag drift just because the project chose flat over `src/` (both are valid).

---

## Layer placement (where each kind of code lives)

### Project root

- `pyproject.toml` — project metadata, dependencies, build system.
- `README.md`, `LICENSE`, `CHANGELOG.md` — distribution metadata.
- `.gitignore`, CI configs.
- `tests/` — top-level tests directory (PyPA-recommended).

### Inside the import package (`src/<pkg>/` or `<pkg>/`)

- `__init__.py` — defines the public API. Re-export the names callers should use; keep internal modules unexported.
- `py.typed` — empty marker file. **Required** by [PEP 561](https://peps.python.org/pep-0561/) for the package to ship inline type hints. Without it, consumers won't get type checking.
- Module files organized by concern. Domain-shaped buckets if the package is non-trivial.
- Tests can live inside the package (`<pkg>/tests/`) or at the top-level `tests/` mirroring the package — both are defensible. Honor the chosen convention.

### Public API discipline

The public API is whatever `__init__.py` re-exports. Internal modules and underscore-prefixed names are **not** the public API.

- Cross-package consumers should import from the public API only.
- `from other_pkg._internal import X` is a Cross-package Reach-In smell.

---

## Universal principles applied to Python packages

- **One package, one purpose.** A package should be cohesive enough that its name describes its responsibility.
- **Public API is small.** Every name in `__init__.py` is a commitment to backwards compatibility.
- **Type hints + `py.typed`** for any package that ships types.
- **`pyproject.toml` per package** — for multi-package workspaces, each package owns its own dependencies and build config.

---

## Common Python-package drift the scout should flag

- **No `__init__.py` re-exports**, callers reaching into internal modules — Inappropriate Intimacy. Verdict: `warning` (consider if the project intentionally wants no public-API curation).
- **Missing `py.typed`** in a typed package — Convention Drift. Verdict: `warning`.
- **`utils.py` / `helpers.py` / `common.py` as a leaf file** — Grab-bag File. Verdict: `warning`. Promote cohesive groups to named modules.
- **Tests neither alongside the package nor at top-level `tests/`** — pick one, document it.
- **Mega-package** — many unrelated concerns in one package. Consider splitting if the package has 2+ reasons to change.

---

## What "aligned" looks like (target shape — `src/` layout, PyPA-recommended)

```
my-pkg/
├── pyproject.toml
├── README.md
├── LICENSE
├── src/
│   └── my_pkg/
│       ├── __init__.py        # public API re-exports
│       ├── py.typed           # PEP 561 marker
│       ├── core.py
│       └── ...
└── tests/
    ├── __init__.py
    └── test_core.py
```

## What "aligned" looks like (target shape — flat layout)

```
my-pkg/
├── pyproject.toml
├── README.md
├── LICENSE
├── my_pkg/
│   ├── __init__.py
│   ├── py.typed
│   ├── core.py
│   └── ...
└── tests/
    └── test_core.py
```

(Tests-inside-the-package — `my_pkg/tests/` — is a defensible variant; flag only if neither convention is documented.)
