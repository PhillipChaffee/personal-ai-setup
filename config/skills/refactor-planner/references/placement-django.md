# Placement reference — Django app

Loaded by `refactor-placement-scout` when the orchestrator detects `project type: django-app`.

Anchored on the [HackSoft Django styleguide](https://github.com/HackSoftware/Django-Styleguide), with universal placement principles (cohesion, dependency direction, screaming architecture, etc.) applied on top.

The scout uses this file as the **canonical source** for "what good looks like" in a Django app. Convention Drift findings cite specific sections of this file by heading.

---

## Detected style cues

The scout starts by detecting which sub-style the app uses, then tailors evaluation. Common Django sub-styles:

- **Layered with services + selectors** — write side in `services.py`, read side in `selectors.py`. (HackSoft target.)
- **Layered with services only** — write *and* read both in `services.py`. Common drift; usually flagged as a Convention Drift opportunity to introduce `selectors.py` for read-heavy apps.
- **Fat-model** — business logic on model methods. Older Django pattern. Usually flagged as drift.
- **View-heavy** — business logic in `views.py`. Always flagged as drift.

---

## Layer placement (where each kind of code lives)

### Services (`services.py` or `services/`)

**Write-side workflows.** Functions that mutate state, orchestrate side effects, call external services, or coordinate multiple models.

- **Shape:** plain functions; type-annotated; **keyword-only arguments**; never receive `request`.
- **Errors:** raise **business exceptions** (custom or `django.core.exceptions.ValidationError`), not `rest_framework.exceptions`. The HTTP-bound exceptions belong in the API layer.
- **One service per workflow.** Don't bundle unrelated workflows into one service function.
- **Split by domain when `services.py` gets too big** — promote to `services/` package, with one file per sub-domain (e.g. `services/onboarding.py`, `services/payments.py`).

### Selectors (`selectors.py` or `selectors/`)

**Read-side queries.** Functions that fetch and shape data; isolated from the write side.

- **Shape:** same shape as services (plain functions, keyword-only args, type-annotated). Optimize querysets with `select_related` / `prefetch_related`.
- **Returns:** querysets, lists, or shaped dataclasses/Pydantic models — whatever the call site needs.
- **No mutation.** Selectors never write.
- **Pulled out of services when reads are non-trivial** — anything spanning multiple relations or N+1-prone properties.

### Models (`models.py` or `models/`)

**ORM only.** Field definitions, relations, model managers, and `clean()` validation.

- Properties **OK** for simple, non-relational, in-memory computations.
- Properties move to **selectors** when they: span multiple relations, would cause N+1 when serialized, depend on related counts/aggregations.
- **No business workflows on models** — those go to services.
- **No HTTP awareness** — models never know about `request`.

### APIs (`views.py` or `apis.py`)

**Thin HTTP layer.** Parse input, call service or selector, format output.

- Use `APIView` or `GenericAPIView`. Avoid mixin-heavy `ModelViewSet` for non-trivial logic — too much magic, hard to reason about.
- **One API per CRUD operation** — for a model with create/read/update/delete, four APIs.
- **Dedicated `InputSerializer` and `OutputSerializer`**, nested in the API class.
- **No business logic in APIs.** Validate input shape, call into services/selectors, serialize output.

### Admin (`admin.py`)

Django admin registrations and admin actions.

- **Complex admin actions delegate to services.** Admin is just another entry point — same logic, same services.

### Tasks (`tasks.py` or `tasks/`)

Celery (or equivalent) background work.

- **No business logic in tasks.** Tasks are entry points; they call services. (Same principle as APIs and admin actions.)
- **Idempotent.** Tasks may retry; they shouldn't double-apply effects.
- **Identifiers in logs** — every task should log enough correlation IDs to trace the unit of work.

### Forms (`forms.py`)

Django form definitions for non-DRF web Django (server-rendered templates). Skip if the app is API-only.

### Migrations (`migrations/`)

Auto-generated. **Never hand-edit** the schema migrations Django produces. For data migrations, generate an empty migration with `--empty -n <descriptive_name>` and fill in the operation logic.

### URLs (`urls.py`)

Per-app URL routes; mounted under the project's main `urls.py`.

### App config (`apps.py`)

Django `AppConfig`; minimal — usually just `default_auto_field` and signal registration if any.

### Tests (`tests/` directory or `test_*.py` siblings)

- Service tests are the most important — heavy, exhaustive, hit the database.
- Selector tests verify query shape and N+1 absence.
- API tests verify serialization and HTTP semantics, not business rules (those are in service tests).
- Mock external calls at the **service boundary**, not deeper.

### Cross-app utilities

Utilities used by 2+ apps go in a dedicated `common/` Django app (or `core/`), not as a loose top-level file.

---

## Apps as bounded contexts

Each Django app should be cohesive enough that you could **extract it into a separate package** if needed. If you can't, the app is too coupled.

- **One app, one purpose.**
- **Domain-named** (`leads/`, `payments/`, `chats/`), not framework-named (`api_app/`, `core_app/`).
- **No `apps/` mega-app** — multiple unrelated concerns in a single Django app is a Layer-shaped vs Domain-shaped Drift smell.

---

## Common Django drift the scout should flag

- **Business logic in views** (`views.py` doing more than parse-call-format) — Misplaced Function/Class. Verdict: `error`.
- **Fat models with workflow logic** (model methods that orchestrate, call external APIs, mutate other models) — Misplaced Function/Class. Verdict: `error`.
- **Signals that hide control flow** (`@receiver` doing business logic) — Misplaced Function/Class. Verdict: `warning` (signals can be appropriate for cross-cutting concerns; flag with care).
- **No `selectors.py` split** in a read-heavy app — Convention Drift, verdict `warning` (the HackSoft pattern is a target, not a hard rule; verdict depends on whether the app's reads are actually causing N+1 or test-bloat pain).
- **`request` passed into services** — Misplaced Function/Class. Verdict: `error`. Services should be HTTP-agnostic.
- **DRF exceptions raised in services** — Misplaced Function/Class. Verdict: `error`. Use business exceptions; let the API layer translate.
- **Mega-`services.py` / mega-`models.py`** — Grab-bag File. Verdict: `warning`. Split by domain when growth crosses ~300 lines.
- **`utils.py` with unrelated functions** — Grab-bag File. Verdict: `warning`. Promote cohesive groups into named modules.

---

## What "aligned" looks like (target shape)

```
service-b/website/<app>/
├── __init__.py
├── apps.py
├── models.py            # ORM only
├── services.py          # write-side workflows  (or services/ package)
├── selectors.py         # read-side queries     (or selectors/ package)
├── views.py             # thin HTTP layer       (or apis.py)
├── serializers.py       # shared serializers across APIs (per-API Input/Output serializers nest in the API class — see "APIs" above)
├── tasks.py             # Celery entry points   (or tasks/ package)
├── admin.py             # admin registrations + thin actions
├── urls.py
├── exceptions.py        # business exceptions
├── utils.py             # small cohesive helpers (or named module)
├── migrations/
└── tests/
    ├── test_services.py
    ├── test_selectors.py
    ├── test_apis.py
    └── ...
```
