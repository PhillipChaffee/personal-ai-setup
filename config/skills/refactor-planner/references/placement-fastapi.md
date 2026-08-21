# Placement reference — FastAPI service

Loaded by `refactor-placement-scout` when the orchestrator detects `project type: fastapi-service`.

Anchored on [zhanymkanov/fastapi-best-practices](https://github.com/zhanymkanov/fastapi-best-practices) (Netflix Dispatch–inspired domain layout).

---

## Detected style cues

Common FastAPI sub-styles the scout should distinguish:

- **Domain-shaped** (target) — top-level folders inside `src/` are domain names (`auth/`, `users/`, `posts/`); each domain owns its own `router.py`, `schemas.py`, `models.py`, `service.py`, etc.
- **Layer-shaped** (drift) — top-level folders are layer names (`controllers/`, `models/`, `services/`); harder to scale, less screams the domain.
- **Integration-shaped** (variant) — domain folders organize around external integrations (your telephony provider, Stripe, your telephony provider). Defensible when the service is primarily an integration broker; flag as drift only if the integrations are actually internal-domain logic in disguise.

---

## Layer placement (where each kind of code lives)

### Top of `src/` — global stuff

- `main.py` — FastAPI app entry; mounts routers; lifespan.
- `config.py` — global settings (Pydantic `BaseSettings`).
- `database.py` — DB engine, sessionmaker; minimal.
- `pagination.py` — shared pagination helpers if non-trivial.
- `dependencies.py` — global dependencies (auth, request id) if shared across many domains.

Avoid top-level `utils.py` / `helpers.py` / `common.py` (Grab-bag File). If a helper is truly cross-domain, give it a domain name (`time_utils.py`, `phone_formatting.py`).

### Per-domain folder — `src/<domain>/`

Each domain is a folder with these files (omit when not needed):

- `router.py` — FastAPI router; HTTP route handlers; thin (parse → service call → format).
- `schemas.py` — Pydantic models for request/response.
- `models.py` — DB ORM models for this domain.
- `service.py` — business logic for this domain (write side).
- `dependencies.py` — domain-specific FastAPI dependencies.
- `constants.py` — domain-specific constants and error codes.
- `config.py` — domain-specific Pydantic settings.
- `exceptions.py` — domain-specific exceptions (e.g. `PostNotFound`).
- `utils.py` — domain-specific non-business helpers (response normalization, data enrichment).

If the domain grows, promote `service.py` to `service/` package with files split by sub-domain.

### Tests

Tests mirror `src/`: `tests/<domain>/test_<file>.py`.

---

## Universal principles applied to FastAPI

- **Async-first** — handlers and services should be `async`. Sync only when justified (e.g. CPU-bound, called from sync code).
- **One Pydantic `BaseSettings` per domain**, not one global mega-settings — easier to compose and reuse across services.
- **Dependencies are reusable + cached** — declare common dependencies once and re-use; FastAPI caches per-request.
- **Validate at the boundary** — Pydantic in `schemas.py` validates incoming requests; never accept raw `dict[str, Any]`.

---

## Common FastAPI drift the scout should flag

- **Top-level `controllers/` / `services/` / `models/` folders** as the primary layout — Layer-shaped vs Domain-shaped Drift. Verdict: `warning` (it works but doesn't scale; aligning is a Strategic ROI).
- **Business logic in `router.py`** — Misplaced Function/Class. Verdict: `error`.
- **`models.py` shared across domains at top level** — Misplaced Class. Verdict: `warning`. Each domain should own its DB models.
- **Single global `BaseSettings`** with all environment variables — Grab-bag File. Verdict: `warning`. Domain-specific settings classes are easier to maintain.
- **Sync handlers without justification** — flag for review (not always a smell; performance-sensitive paths may legitimately use sync).
- **External SDK calls inside a domain service** (e.g. `telephony_client.send(...)` directly in `posts/service.py`) — Misplaced Function/Class. Integration calls belong in an integration-specific service or a dedicated integration module.

---

## What "aligned" looks like (target shape)

```
fastapi-service/
├── alembic/
├── src/
│   ├── main.py
│   ├── config.py
│   ├── database.py
│   ├── pagination.py
│   ├── auth/
│   │   ├── router.py
│   │   ├── schemas.py
│   │   ├── models.py
│   │   ├── service.py
│   │   ├── dependencies.py
│   │   ├── constants.py
│   │   ├── exceptions.py
│   │   └── utils.py
│   ├── users/
│   │   └── ...
│   └── posts/
│       └── ...
├── tests/
│   ├── auth/
│   ├── users/
│   └── posts/
├── pyproject.toml
└── ...
```
