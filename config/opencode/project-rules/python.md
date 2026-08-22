<!-- Project rule: Python tooling, typing, data modeling, logging, and Django/ORM conventions.
     Use by pasting into a project's AGENTS.md or listing this file's path in the project's opencode.json "instructions" array. -->

# Python

Applies when working on Python code (`*.py`, `pyproject.toml`, `poetry.lock`).

- **Tooling**
  - Use Poetry for dependency management.
  - Use Ruff for linting and formatting.
  - Use mypy for type checking.
  - Run Python commands through Poetry (examples):
    - `poetry run pytest`
    - `poetry run ruff check .`
    - `poetry run ruff format .`
    - `poetry run mypy .`
    - `poetry run python -m <module>`
    - `poetry run <migration-tool> <args>` (e.g., `poetry run alembic upgrade head`)

- **Typing**
  - Avoid `typing.Any` (disallowed by lint/type checking).
  - Prefer small `Protocol`s (structural typing) that include only the methods you actually call.
  - If a value is intentionally "unknown", prefer `object` over `Any`.
  - Prefer built-in / stdlib generic types over `typing` aliases:
    - Use `list[str]`, `dict[str, int]`, `set[int]`, `tuple[int, ...]`, etc (not `List[str]`, `Dict[...]`).
    - Prefer `collections.abc` for ABCs when available (e.g., `Iterable[str]`, `Sequence[int]`).

- **Data modeling**
  - Prefer Pydantic models (`pydantic.BaseModel`) for new "data classes" / structured DTOs.
  - Prefer Pydantic models over `TypedDict`, `dataclasses.dataclass`, raw `dict`s, or tuple-like structures for
    structured data.
  - Use `TypedDict` only when the value must remain a plain `dict` (e.g., interop with external libs or
    intentionally unvalidated JSON).
  - Use stdlib `dataclasses.dataclass` only for small internal containers where inputs are already trusted and you
    don't need validation/serialization helpers.

- **Type annotations**
  - All new functions must have argument and return type annotations (including pytest tests).

- **Testing**
  - Write tests with `pytest` (do not use `unittest`).
  - Prefer **class-based boundaries** (small facades) at module edges so behavior can be swapped in unit/integration tests.
  - When layering behavior (logging, caching, retries, auth), prefer **cooperative multiple inheritance**
    and `super()` (computed indirection) so behavior can be *composed* by controlling the MRO:
    - Each override should call `super()` (don't hard-call a specific base class).
    - Keep signatures compatible across the chain; for `__init__`, prefer the `**kwargs` pattern and forward
      with `super().__init__(**kwargs)`.
    - Compose concrete implementations by ordering mixins in the class definition; tests can swap in fakes by
      changing the composition.
    - Reference: `https://rhettinger.wordpress.com/2011/05/26/super-considered-super/`

    ```python
    from collections.abc import Sequence
    import logging


    logger = logging.getLogger(__name__)


    class UserApi:
        def fetch_usernames(self) -> Sequence[str]:
            ...


    class LoggingUserApi(UserApi):
        def fetch_usernames(self) -> Sequence[str]:
            logger.info("Fetching usernames")
            return super().fetch_usernames()


    class FakeUserApi(UserApi):
        def fetch_usernames(self) -> Sequence[str]:
            return ["alice", "bob"]


    class AppUserApi(LoggingUserApi, FakeUserApi):
        pass
    ```

- **Style**
  - Keep lines at 100 characters or fewer.
  - Prefer longer descriptive variable and function names when it improves clarity.

- **String formatting & logging**
  - Use f-strings for string interpolation, except in logging.
  - Never use f-strings in logging; use lazy formatting instead:

    ```python
    logger.info("Processed %s records for user_id=%s", record_count, user_id)
    ```

  - Always include identifiers in log lines. Every log statement in a request/domain flow should include `order_id`, `request_id`, `tenant_id`, or `resource_id` as appropriate.

    ```python
    # Bad
    logger.info("Scheduling next outbound")

    # Good
    logger.info("Scheduling next job for order_id=%s, request_id=%s", order_id, request_id)
    ```

  - Log errors for unexpected states. If a code path "should never happen," log an error — don't silently continue.

- **Exception logging**
  - Inside an `except` block, prefer `logger.exception("...")`.
  - Do not pass `exc` as a `%s` argument for traceback purposes; `logger.exception` includes it.

- **Error handling**
  - Ask "what happens if this is None/empty/missing?" for every input. Guard against missing data explicitly.
  - Don't use catch-all exception handlers unless the outer function already handles exceptions. Bare `except Exception` hides bugs. If a function doesn't raise, don't wrap it in a try/except.
  - Prefer `None` over sentinel values for defaults. When a field is optional, default to `None` rather than `False`, `0`, `""`, or a magic string.

    ```python
    # Bad: ambiguous default
    max_retries: int = 0  # Is 0 "not set" or "zero retries"?

    # Good: explicit absence
    max_retries: int | None = None
    ```

- **Imports**
  - Put all imports at the top of the file unless not possible (e.g., to avoid a circular import or to defer an expensive import).
  - `import datetime` at the top level, then reference as `datetime.date`, `datetime.time`, `datetime.timezone`. This avoids confusion between `datetime.datetime` and `datetime.date` and between the `time` module and `datetime.time`.

    ```python
    # Bad: ambiguous imports
    from datetime import datetime, time, timezone

    # Good: explicit module reference
    import datetime

    now = datetime.datetime.now(tz=datetime.timezone.utc)
    ```

- **Django and ORM**
  - Use `models.TextChoices` for string enum fields rather than plain strings or custom enum classes.
  - Use Django/DRF builtins before building custom (validators, permissions, filters, managers).
  - Use `select_related` / `prefetch_related` to avoid N+1 queries, especially on hot paths (e.g., agent config loading).

    ```python
    # Bad: extra query per iteration
    for lead in leads:
        print(lead.user.email)

    # Good: single query
    for lead in leads.select_related("user"):
        print(lead.user.email)
    ```

  - Use `lead.lead_type_id` instead of `lead.lead_type.id` when you only need the foreign key value — the `_id` accessor doesn't trigger a query.
  - Batch large writes and reads. Queries that touch tens of thousands of rows should be batched to avoid locking the database.
  - Keep transactions short. Don't call external APIs inside a database transaction. If a `select_for_update` lock is needed, add a short timeout.

    ```python
    # Bad: external API call inside transaction
    with transaction.atomic():
        obj = MyModel.objects.select_for_update().get(id=pk)
        result = external_api.call(obj.data)  # Could hang
        obj.status = result.status
        obj.save()

    # Good: fetch, call API, then update in short transaction
    obj = MyModel.objects.get(id=pk)
    result = external_api.call(obj.data)
    with transaction.atomic():
        obj = MyModel.objects.select_for_update(nowait=True).get(id=pk)
        obj.status = result.status
        obj.save()
    ```

- **External APIs**
  - Add rate limiting and backoff for bulk operations. When calling external APIs (your LLM observability tool, your telephony provider, your reputation provider, etc.) in loops or batches, add a countdown between batches (e.g., 0.5s) to avoid hitting rate limits.
  - Add timeouts to all external API calls. Never call an external service without a timeout.
