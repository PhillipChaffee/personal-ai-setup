# Named refactoring catalog

Authoritative refactoring-name list for the `refactor-planner` orchestrator (Step 7: smell → refactoring mapping). Used to:

1. Pick a named refactoring to address each smell the scouts surface.
2. Generate the optional one-line "Suggested direction" hint per finding.
3. Provide before/after sketches for the produced plan's phases.

Three families: **Logic / size**, **Naming (renames)**, **Placement (moves)**. Anchored on Fowler's *Refactoring* 2nd ed.

---

## Logic / size

### Extract Method

Pull a code block out of a function into a new function with a name describing its intent.

- **Use when:** Long Method; Deep Nesting; Duplicated Code (block appears in 2+ functions).
- **Before:**
  ```python
  def process_order(order):
      # validation
      if not order.items:
          raise ValueError("empty order")
      if not order.customer:
          raise ValueError("no customer")
      # ... pricing, persistence, notifications follow ...
  ```
- **After:**
  ```python
  def process_order(order):
      _validate_order(order)
      # ... pricing, persistence, notifications ...

  def _validate_order(order):
      if not order.items:
          raise ValueError("empty order")
      if not order.customer:
          raise ValueError("no customer")
  ```

### Extract Class

Pull a cluster of fields and methods out of a class into a new class.

- **Use when:** Large Class; the class has 2+ unrelated reasons to change.
- **Before:** `User` class handles auth, profile, payments.
- **After:** `User`, `UserProfile`, `UserPayments` — each with one reason to change.

### Inline Method

Replace a method call with its body when the method's name doesn't add clarity.

- **Use when:** Lazy Element on a method; the indirection isn't earning its keep.

### Inline Variable

Replace a temp variable with the expression that computes it when the variable name isn't more descriptive than the expression.

- **Use when:** Lazy Element on a variable; one-line temps that don't aid readability.

### Replace Conditional with Polymorphism

Replace a `switch`/`type-code` dispatch with a class hierarchy where each subclass owns one branch.

- **Use when:** Switch Statements / Type-Code that recurs across the codebase; Shotgun Surgery (adding a new type forces edits to many switches).
- **Before:**
  ```python
  def get_speed(vehicle):
      if vehicle.kind == "car":
          return vehicle.base * 1.0
      elif vehicle.kind == "bike":
          return vehicle.base * 0.8
  ```
- **After:**
  ```python
  class Vehicle: ...
  class Car(Vehicle):
      def speed(self): return self.base * 1.0
  class Bike(Vehicle):
      def speed(self): return self.base * 0.8
  ```

### Introduce Parameter Object

Group a Data Clump into a named object that carries them together.

- **Use when:** Long Parameter List; Data Clumps.
- **Before:** `schedule_call(start_dt, end_dt, tz, recurring)`
- **After:** `schedule_call(window: CallWindow)` where `CallWindow` carries the four fields.

### Replace Magic Number with Symbolic Constant

Name a magic number/string at module level with intent.

- **Use when:** Magic Numbers / Magic Strings.
- **Before:** `if attempt < 3:`
- **After:** `MAX_RETRY_ATTEMPTS = 3` then `if attempt < MAX_RETRY_ATTEMPTS:`.

### Replace Nested Conditional with Guard Clauses

Flatten arrow-shaped code by exiting early on edge cases.

- **Use when:** Deep Nesting.
- **Before:**
  ```python
  def f(x):
      if x:
          if x.valid:
              return x.value
      return None
  ```
- **After:**
  ```python
  def f(x):
      if x is None:
          return None
      if not x.valid:
          return None
      return x.value
  ```

### Decompose Conditional

Extract the predicate, the then-branch, and the else-branch into named functions.

- **Use when:** Long, complex `if`/`else` blocks where each branch is non-trivial.

### Split Loop

Split a loop that does multiple things into separate loops, one per concern.

- **Use when:** a loop body computes/mutates several unrelated things; performance impact is negligible.

### Extract Variable

Name a sub-expression to reveal its intent.

- **Use when:** an expression is dense or repeated within a function.

### Combine Functions into Class

Group functions that operate on the same data into a class.

- **Use when:** several module-level functions all take the same first argument and mutate or query it; they want to be methods.

### Combine Functions into Transform

Group derivation functions that share inputs into a single transform that produces an enriched record.

- **Use when:** multiple selector-style functions repeatedly recompute derived fields from the same source.

### Split Phase

Separate two consecutive phases of computation into separate functions or modules with a clean handoff.

- **Use when:** parsing-then-execution, fetch-then-transform, or any pipeline where stages are tangled.

---

## Naming (renames)

### Change Function Declaration (= Rename Function)

Rename a function and/or change its parameter list.

- **Use when:** Mysterious Name on a function; Stale Name; signature has Long Parameter List that's better as a Parameter Object (combine with Introduce Parameter Object).
- **Note:** The orchestrator must propose the **actual new name**, not "rename for clarity."

### Rename Variable

Rename a variable, attribute, or local name.

- **Use when:** Mysterious Name; Inconsistent Vocabulary; Stale Name; Hungarian / type-prefix; non-idiomatic abbreviation.

### Rename Field (= rename DB column or model attribute)

Rename a persistent field on an ORM model. **Generates a database migration.**

- **Use when:** Mysterious Name on a model field; column name diverged from semantic meaning.
- **Critical:** This is **not** a pure rename. Follow the **expand-contract / Parallel Change** pattern:
  1. Add the new column.
  2. Migrate code to use the new column.
  3. Defer the old column from default reads.
  4. Drop the old column in a follow-up release.
- Codified locally in the Engineering Guidelines of your global rules (`~/.config/opencode/AGENTS.md`) — "safe column removal sequence."

### Rename Class

Rename a class.

- **Use when:** Mysterious Name; Stale Name (class behavior outgrew its name).
- **Watch for:** import statement updates everywhere the class is used; if the class is part of a public API, follow the same expand-contract pattern (alias old, deprecate, drop).

### Rename Module

Rename a Python module (a `.py` file).

- **Use when:** the file's content has shifted; Mysterious Name on the module itself.
- **Watch for:** import paths update across the codebase; `__init__.py` re-exports may need adjustment.

### Rename File

Rename a non-Python file (config, template, doc) to better describe contents.

- **Use when:** Naming-as-Documentation principle; the path is no longer descriptive.

### Rename Directory

Rename a directory (package, module group, app) to a better-named bucket.

- **Use when:** Layer-shaped vs Domain-shaped Drift (a directory named after a framework layer would scream more clearly with a domain name); Mysterious Name on a folder.
- **Watch for:** import paths cascade; CI configs, Helm values, Dockerfiles may reference the path.

---

## Placement (moves)

Each move includes both **source** and **destination** path in the produced plan.

### Move Function

Move a function from one module to another (or one file to another).

- **Use when:** Misplaced Function (the function's responsibility belongs in a different module per the placement reference); Feature Envy (the function uses another module's data more than its own).

### Move Class

Move a class from one module to another.

- **Use when:** Misplaced Class; the class belongs in a different layer (e.g. domain class currently sitting in the HTTP layer).

### Move Field

Move a field from one class to another.

- **Use when:** Feature Envy at the field level; a field is more naturally owned by a collaborator class.

### Move Statements Into Function

Move statements from a caller into the called function when they're always called together.

- **Use when:** the same setup/teardown statements appear at every call site of a function.

### Move Statements Out Of Function

Move statements that don't belong out of a function (the inverse of the above).

- **Use when:** a function does too much; some of its statements are concerns of the caller.

### Pull Up Method / Field

Move a method or field from a subclass to a superclass.

- **Use when:** the same method appears in multiple subclasses; it's truly common behavior.

### Push Down Method / Field

Move a method or field from a superclass to a specific subclass.

- **Use when:** a method on a superclass is only used by some subclasses; pushing it down keeps the superclass focused.

### Extract Module

Pull a cohesive set of functions/classes out of one module into a new module.

- **Use when:** Grab-bag File; Divergent Change at the module level; multiple unrelated concerns in one file.

### Extract File

Pull a single class or function out of a multi-class file into its own file.

- **Use when:** the parent file is becoming a Large Class container; one of its contents has earned its own home.

### Extract Package

Pull a cohesive set of modules into a new package (a directory with `__init__.py`).

- **Use when:** a logical bucket has emerged inside a single mega-module; multiple files want a shared namespace.
- **In a multi-service workspace:** if the extracted package would be reused by both `service-b/` and `service-a/`, it goes to `shared/` (per the `engineering` rule).

---

## How to use this catalog

1. For each in-scope smell from the scout output, pick **one** named refactoring from this catalog.
2. The optional "Suggested direction" line on a scout finding cites a refactoring name from this catalog (e.g. "Consider Extract Method").
3. For Renames, the orchestrator proposes the **actual new name** in the plan's "Renames proposed" table.
4. For Moves, the orchestrator proposes the **actual destination path** in the plan's "Moves proposed" table.
5. Schema-touching renames (Rename Field on a DB column; public API renames) are flagged for **expand-contract** and never single-step.
