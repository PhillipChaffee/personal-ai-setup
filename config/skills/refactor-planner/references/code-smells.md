# Code smell catalog

Authoritative smell-name list for `refactor-code-scout`. Every finding the scout returns must use a smell name from this file (verbatim).

Two families: **Behavioral / size / complexity** and **Naming**. Placement / cohesion / boundary smells live in the placement scout's evaluation, not here.

Anchored on Fowler's *Refactoring* 2nd ed. plus modern naming-smell additions.

---

## Behavioral / size / complexity

### Long Method

A function that does too much or is too long to read in one screen.

- **Signs:** > 30 lines (heuristic, not contract); multiple unrelated concerns; extracted comments would naturally break it into named blocks; difficult to test as a unit.
- **Severity hint:** HIGH when the method spans validation + workflow + side effects + persistence; MEDIUM when long but single-concern; LOW when borderline and the body is straightforward.
- **False positives:** functions that are linear data transformations (no branching, no side effects) — length isn't the smell, complexity is.

### Large Class

A class with too many responsibilities, fields, or methods.

- **Signs:** > 200 lines (heuristic); > ~10 public methods; methods cluster into 2+ unrelated groups; "and" appears in attempts to summarize what the class does.
- **Severity hint:** HIGH when the class has 2+ unrelated reasons to change; MEDIUM when many cohesive methods; LOW when borderline.
- **False positives:** cohesive value objects with many small accessors; data classes with many fields are not Large Class if behavior is minimal.

### Long Parameter List

A function signature with too many parameters.

- **Signs:** > 4 parameters (heuristic); parameters always passed together at call sites; parameters that are pieces of a coherent concept.
- **Severity hint:** HIGH when 3+ params always travel together (Data Clump); MEDIUM when many independent params suggest the function is doing too much.
- **False positives:** stable interfaces with default values; pytest fixtures injecting test infrastructure.

### Deep Nesting

Multiple levels of nested conditionals, loops, or `try`/`except`.

- **Signs:** > 3 levels of indentation in a function body; arrow-shaped code; pyramids of `if`/`else`.
- **Severity hint:** HIGH when nesting hides the happy path; MEDIUM when straightforward but visually heavy; LOW when one extra level for an intentional guard.
- **False positives:** state machines and parsers can legitimately nest deeply.

### Duplicated Code

The same logic appears in multiple places.

- **Signs:** identical or near-identical blocks in 2+ locations; minor parameterization could unify them; the same fix applied in two places when one breaks.
- **Severity hint:** HIGH when divergence between copies is causing bugs; MEDIUM when 3+ copies and stable; LOW when 2 copies of trivial logic.
- **False positives:** **incidental duplication** (similar shape, different intent) that would force the wrong abstraction. Apply the **Rule of Three** — duplication is cheaper than the wrong abstraction.

### Primitive Obsession

Domain concepts represented as raw primitives (`str`, `int`, `dict`, `tuple`).

- **Signs:** validation logic for the same field scattered across functions; `dict[str, Any]` passed as a domain object; magic strings for status / type values; tuple unpacking that's positional rather than named.
- **Severity hint:** HIGH when the primitive has invariants that get violated (e.g. a `phone_number` string that's sometimes E.164 and sometimes not); MEDIUM when validation is duplicated; LOW for a one-off helper.
- **False positives:** simple enumerations may be fine as `Enum` rather than full value objects.

### Data Clumps

Groups of variables that always travel together.

- **Signs:** the same 3+ params/attributes appear together in many signatures; passing them individually feels repetitive; one missing makes the others meaningless.
- **Severity hint:** HIGH when the clump appears in 5+ places and changes together; MEDIUM when 3+ places; LOW for 2 places.
- **False positives:** params that look related but vary independently — e.g. `start` and `end` of unrelated ranges.

### Switch Statements / Type-Code

Conditional dispatch on a type code or shape, especially when repeated.

- **Signs:** `if obj.kind == "X" / elif obj.kind == "Y"` patterns; the same switch repeated across functions; new types require touching multiple switch sites (Shotgun Surgery).
- **Severity hint:** HIGH when the same switch is duplicated 3+ times; MEDIUM when one switch with many branches; LOW for a simple stable dispatch.
- **False positives:** dispatch tables that are intentionally explicit (e.g. parser, state machine).

### Speculative Generality

Abstractions, hooks, or generics with no real consumers.

- **Signs:** abstract base classes with one concrete subclass; parameters that are always passed the same value; "for future use" methods; protocols with one implementation.
- **Severity hint:** HIGH when the abstraction is making the code hard to read with no payoff; MEDIUM when the abstraction is small but unused; LOW when easily inlined.
- **False positives:** **the class is reused via plugin loader, factory, or framework-driven dispatch** (the abstraction has real consumers via dynamic loading). Check before flagging.

### Message Chains

Long sequences of method calls navigating object structure (`a.b.c.d.method()`).

- **Signs:** > 3 chained accessors; the caller knows about the internal shape of the callee's collaborators.
- **Severity hint:** HIGH when the chain crosses module/package boundaries (also Inappropriate Intimacy at the placement scout level); MEDIUM when within a module; LOW for builder-pattern fluent APIs that are intentionally chained.
- **False positives:** fluent builders, query builders, ORM querysets — chains are the API.

### Middle Man

A class or function that mostly delegates to another, adding little value.

- **Signs:** > half the methods just forward to another object's methods; the wrapper doesn't transform, validate, or coordinate.
- **Severity hint:** HIGH when the wrapper is hiding a clean alternative; MEDIUM when the wrapper has minor convenience; LOW for thin facades that document intent.
- **False positives:** **intentional wrapping** for interface boundary, port/adapter for testability, async-to-sync bridge, version compatibility shim.

### Magic Numbers / Magic Strings

Hardcoded values with no explanation.

- **Signs:** numeric literals in business logic (other than 0, 1, -1); string literals for status codes, types, modes; the same literal repeated in multiple places.
- **Severity hint:** HIGH when the same literal appears 3+ times; MEDIUM when the literal's meaning isn't obvious from context; LOW for one-off, obvious values.
- **False positives:** mathematical constants in scientific code; UI dimensions in styling; sentinel values that genuinely have no meaningful name.

---

## Naming

### Mysterious Name

A name that doesn't reveal what the thing does or means. Fowler 2nd ed. promotes this to a first-class smell.

- **Signs:** abbreviations, acronyms, or vague nouns that require reading the body to understand; names like `process`, `handle`, `data`, `result`, `info`; one-letter variables outside of trivial loops.
- **Severity hint:** HIGH when the mysterious name is on a public API or a frequently-touched function; MEDIUM when on internal helpers; LOW for one-off locals where context is clear.
- **False positives:** **domain-standard terms** (industry-specific acronyms documented elsewhere in the project) — check the project's vocabulary before flagging.

### Inconsistent Vocabulary

The same concept named different ways in different parts of the codebase.

- **Signs:** `customer_id` here, `cust_id` there, `cId` somewhere else; `user` in some modules and `account` in others when they mean the same thing.
- **Severity hint:** HIGH when the inconsistency causes friction at module boundaries; MEDIUM when within a single module; LOW for incidental local variation.
- **False positives:** terms that look the same but mean different things in different contexts (e.g. `user` in auth vs `user` as in "consumer of an API").

### Stale Names

A name that no longer reflects what the code actually does — usually because the code evolved but the name didn't.

- **Signs:** a function called `get_user` that now also creates the user if missing; a variable named `is_admin` that's actually a permission tier; a class `EmailNotifier` that now sends SMS too.
- **Severity hint:** HIGH when the stale name is misleading callers; MEDIUM when the name is just incomplete; LOW for cosmetic drift.
- **False positives:** name retained for backward-compat with an external API.

### Hungarian / Type-Prefix Encoding

Type information encoded in the name when type annotations carry it.

- **Signs:** `str_name`, `dict_options`, `list_items`, `bool_active`, `m_field`, `_p_pointer`. Type info belongs in annotations, not names.
- **Severity hint:** MEDIUM by default; HIGH if it's pervasive across the codebase and creating an inconsistent house style; LOW for single instances.
- **False positives:** **none, generally** — Hungarian is universally rejected in modern Python style.

### Non-idiomatic Abbreviations

Abbreviations of domain words that aren't broadly idiomatic in the language/ecosystem or domain-standard in the project.

- **Signs:** `ag` for `agent`, `cmpny` for `company`, `proc` for `process`, `mgr` for `manager`. Not in the broadly idiomatic list (`ctx`, `db`, `id`, `pk`, `api`, `tz`, `req`/`res`).
- **Severity hint:** MEDIUM by default; HIGH if pervasive; LOW for single instances.
- **False positives:** **domain-standard names from the project** (vendor names, established product terms documented in the project's vocabulary) are acceptable.

---

## How to use this catalog

1. The scout reads this file first, before judging code.
2. Every finding maps to **exactly one** smell name from this list (verbatim).
3. The "Severity hint" rows are guides, not contracts — calibration discipline ("not everything is HIGH") still applies.
4. False-positive notes are mandatory checks: if the FP fits, downgrade or omit.
