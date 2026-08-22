# Placement reference — Clean Architecture / DDD / hexagonal

Loaded by `refactor-placement-scout` when the orchestrator detects a project that follows (or claims to follow) Clean Architecture / Domain-Driven Design / hexagonal / ports-and-adapters.

Anchored on Robert C. Martin's *Clean Architecture*, Eric Evans's *Domain-Driven Design*, and Alistair Cockburn's *Hexagonal Architecture*, with Python implementations referenced from [pycabook](https://github.com/pycabook/pycabook), [MartinKalema/clean-architecture-ddd-python](https://github.com/MartinKalema/clean-architecture-ddd-python), and [alefeans/python-clean-architecture](https://github.com/alefeans/python-clean-architecture).

This file is also useful as a **target architecture for evaluation** even when the project doesn't fully follow Clean Architecture — it gives the scout vocabulary for "this code is in the wrong layer" findings against any project that has even an implicit layer separation.

---

## The four canonical layers

Dependencies flow **inward only**. Outer layers depend on inner; inner layers depend on nothing outer.

### Domain layer (innermost)

**Pure business model.** No framework imports, no DB, no HTTP, no I/O.

- **Entities** — objects with identity (`Order`, `User`, `Loan`).
- **Value Objects** — immutable, no identity (`Email`, `Money`, `PhoneNumber`).
- **Aggregates** — entity clusters that enforce invariants together.
- **Domain Events** — `OrderPlaced`, `PaymentReceived`.
- **Repository interfaces** — `Protocol`s describing how the application layer fetches/persists. **No SQL here**, just the interface.
- **Domain services** — domain logic that doesn't fit on a single entity (rare; usually a sign you should rethink).

The domain layer **must not import from the application, infrastructure, or presentation layers**. If it does, dependency direction is inverted.

### Application layer

**Use cases.** Orchestrate domain objects to fulfill a request.

- **Command handlers** — write-side operations (`CreateOrderHandler`, `RefundPaymentHandler`).
- **Query handlers** — read-side operations (CQRS-friendly).
- **Ports** — interfaces (`Protocol`s) for outbound dependencies (`EmailSender`, `PaymentGateway`). The application layer depends on the port; infrastructure provides the adapter.
- **Application services** — coordinate multiple use cases when needed.

The application layer depends only on the domain layer (inward).

### Infrastructure layer

**Adapters.** Concrete implementations of the ports.

- **Repositories** — concrete `OrderRepository(SQLAlchemyRepository)` implementing the domain's repository interface.
- **External clients** — `StripeClient(PaymentGateway)`, `SendGridSender(EmailSender)`.
- **Frameworks** — Django ORM, SQLAlchemy, Alembic migrations live here.
- **Persistence concerns** — DB session management, transactions, caching.

Depends on application + domain layers (inward).

### Presentation layer (outermost)

**Entry points.** HTTP, CLI, message-queue consumers, scheduled jobs.

- **HTTP routers / controllers** — parse request, call application-layer command/query handler, format response.
- **CLI commands** — same shape, different entry.
- **Workers / consumers** — same shape, listening to a queue.

Depends on application + domain (and sometimes infrastructure for wiring), but **never the other way**.

---

## Bounded contexts

Organize folders by **feature / domain**, not by layer.

```
src/
├── payments/                  # bounded context
│   ├── domain/
│   ├── application/
│   ├── infrastructure/
│   └── presentation/
├── users/
│   └── ...
└── shared_kernel/            # cross-context interfaces
    └── ...
```

This is **screaming architecture** at the directory-tree level: reading `src/` tells you what the system does, not what framework it uses.

Avoid the inverse:

```
src/
├── controllers/      # ← layer-shaped, drift signal
├── services/
├── repositories/
└── models/
```

---

## Common Clean-Architecture drift the scout should flag

- **Domain layer imports from infrastructure** — Layer Violation. Verdict: `error`. Domain depends on nothing outer.
- **Concrete framework type in the domain** (`django.db.models.Model`, `pydantic.BaseModel`, `sqlalchemy.Column`) — Layer Violation. Verdict: `error`. Domain entities should be pure Python.
- **HTTP awareness in the application layer** (`request`, `Response`, status codes) — Layer Violation. Verdict: `error`. HTTP belongs in presentation.
- **Repository implementation in the domain layer** instead of the interface — Layer Violation. Verdict: `error`.
- **Layer-shaped top-level folders** (`controllers/`, `services/`, `repositories/`) — Layer-shaped vs Domain-shaped Drift. Verdict: `warning` (it works for small projects, breaks down at scale).
- **Cross-context reach-in** — `users/domain/User` imported directly from `payments/application/`, bypassing a shared kernel or anti-corruption layer — Inappropriate Intimacy. Verdict: `warning`.

---

## How to use this file when the project doesn't fully follow Clean Architecture

Most real projects don't strictly follow Clean Architecture. The scout uses this file's **vocabulary** to articulate placement findings even in non-Clean projects:

- "Business logic in `views.py`" → presentation layer doing application-layer work.
- "External API call inside a domain service" → infrastructure concern leaking into domain.
- "Concrete repository class imported by domain code" → dependency direction inverted.

Use the layer terminology to make findings **portable** across project styles.

---

## What "aligned" looks like (target shape)

```
src/
├── payments/                          # bounded context
│   ├── domain/
│   │   ├── entities.py
│   │   ├── value_objects.py
│   │   ├── events.py
│   │   └── ports/                    # interfaces
│   │       ├── repositories.py       # InvoiceRepository (Protocol)
│   │       └── gateways.py           # PaymentGateway (Protocol)
│   ├── application/
│   │   ├── commands/
│   │   │   ├── create_invoice.py
│   │   │   └── refund_payment.py
│   │   └── queries/
│   │       └── get_invoice.py
│   ├── infrastructure/
│   │   ├── repositories.py           # SQLAlchemy implementations
│   │   └── gateways/
│   │       └── stripe.py             # PaymentGateway adapter
│   └── presentation/
│       ├── http.py                   # FastAPI router
│       ├── cli.py
│       └── workers.py
├── users/
│   └── ...
└── shared_kernel/
    └── ...
```
