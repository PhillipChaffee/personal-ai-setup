# Unit manifests: the contract

A **unit** is one installable piece of this setup — the pinned goose CLI, the VPS brain,
the code-agent plane. A **unit manifest** is one YAML file describing what that unit
*actually is today*: what installs it, what it puts on disk, which secrets it needs, which
`check-*.sh` proves it works, and which of those things **do not exist yet**.

The validator is [`scripts/verify/check-units.sh`](../../scripts/verify/check-units.sh)
(a thin wrapper over [`units_lint.py`](../../scripts/verify/units_lint.py)). It speaks to
nothing, needs no credentials, and needs no goose — it is a text gate, and it runs in
`data-lint.yml` on every push.

---

## The one rule that makes these files worth having

**A manifest describes TODAY'S REALITY, not the intended end state.**

This directory exists because eight of this repo's units have nothing that installs them
and eleven have no verify script, and until now that was true *invisibly* — spread across
two installers, a docs tree and a reader's memory. A manifest that papers over a gap is
strictly worse than no manifest: it converts an unknown into a wrong known, and it does it
in a file whose whole claim is to be machine-checked.

So the schema has a **place to record every absence**, and the validator **fails when an
absence is unrecorded**:

| The gap | Where it goes | What the validator does |
|---|---|---|
| Nothing installs this unit | `installer: null` | Legal only with non-empty `manual_steps`, or `host: checklist` |
| No verify script exists | `verify: []` | **Requires** a `blockers` entry with `id: no-verify` |
| No runbook exists | `runbook: null` | **Requires** a `blockers` entry with `id: no-runbook` |
| The installer function is not written yet | `installer.status: planned` | Asserts the function **does not exist** in the named script |

That last row is the load-bearing one. `status: planned` is not a TODO comment — it is a
falsifiable assertion in the opposite direction from the usual: it fails the moment the
function *appears*, telling you to flip the status. The absence is checked as hard as the
presence, which is what keeps `planned` from rotting into a lie.

At the time of writing, `grep -rn 'unit_' scripts/ config/ .github/ bin/` returns **zero
hits**. Every manifest therefore carries `status: planned`, and #37 — which writes the
`unit_*()` functions — flips them to `present` one at a time, with the validator refusing
any that is claimed before it is written.

**#36 changes no install behaviour whatsoever.** `git diff --stat origin/main --
scripts/mac/bootstrap-mac.sh scripts/vps/deploy-vps.sh` is empty, by construction.

---

## File layout

One file per unit, named `<id>.yaml`, where `<id>` matches the `id:` field, which matches
the filename stem.

```
config/units/
├── README.md              # this file
├── base-toolchain.yaml
├── base-secrets.yaml
└── base-goose.yaml
```

The three above form a **closed subgraph** (`base-toolchain` and `base-secrets` require
nothing; `base-goose` requires both), which is why they land first: `requires` resolution
and `owns` disjointness are exercised for real rather than trivially. The remaining
fifteen units listed in epic #30 arrive in a follow-up.

---

## Schema

**All 17 keys are REQUIRED.** A key with nothing to say is present and explicitly `null`
or `[]` — never omitted. An **unknown top-level key is a hard FAIL**, because an assertion
key that nothing reads asserts nothing, forever.

`notes` is the single free-text escape hatch. Everything else is checked.

```yaml
---
# ---- identity -------------------------------------------------------------
id: base-goose                    # kebab-case; == the filename stem
manifest_version: 1
verified_on: "2026-09-07"         # QUOTED. See "Why verified_on is quoted".
summary: Pinned goose CLI and Desktop cask, four custom providers.

# ---- placement ------------------------------------------------------------
host: mac                         # mac | vps | both | checklist
tier: base                        # base | default_on | opt_in
requires: [base-toolchain, base-secrets]    # unit ids; the graph must be acyclic

# ---- money ----------------------------------------------------------------
# Each entry is cross-checked VERBATIM: `line` and `amount` must appear on the
# SAME LINE of `source`. No figure originates here. Empty for most units.
cost:
  - line: Together AI inference (min $5 top-up; sensitive tier + default hub)
    amount: ~$5–10/mo
    source: README.md

# ---- what installs it -----------------------------------------------------
installer:                        # or null (see the table above)
  script: scripts/mac/bootstrap-mac.sh      # must exist and be executable
  function: unit_base_goose                 # == "unit_" + id.replace("-", "_")
  status: planned                           # planned | present

# ---- what proves it works -------------------------------------------------
# This IS the roster `pai verify` runs — it derives it from every manifest's
# `verify:`, so a unit that gains a check gains it in the sweep with no second
# edit anywhere. An entry may carry arguments after the path when the script's
# modes are different checks (`check-security.sh --local`); the arguments are
# not validated, because that would mean keeping a copy of each script's option
# vocabulary here, and the script already refuses an unknown flag with exit 2.
verify:
  - scripts/verify/check-goose.sh
  - scripts/verify/check-security.sh --local   # path + argv, when the mode matters
runbook: docs/setup/20-mac-setup.md         # or `path#anchor`, or null

# ---- credentials, BY NAME ONLY --------------------------------------------
# One row per (key, store). The SAME key in two stores is two rows, on purpose:
# a value can live on the brain and on the Mac and be checked against each
# store's own source of truth.
secrets:
  - key: TOGETHER_API_KEY         # [A-Z][A-Z0-9_]*
    store: mac_keychain           # vps | mac_keychain | goose_secret_store | none
    secret: true                  # false => a value, not a credential (e.g. an email)
    optional: false
    # What keychain-secrets.sh SHOWS at the hidden prompt. Non-empty, single
    # line, no tab (the roster is TAB-separated). There is no second hint
    # table anywhere: this is the text.
    prompt: >-
      Together AI key (docs/setup/10-accounts.md §2) — goose's together provider
      and opencode.json both read it by name
    # null, or exactly `openssl rand -hex N` — and then the prompt must contain
    # that command verbatim. A property of the ROW, not the key: a secret is
    # minted on one host and TRANSCRIBED on the other.
    generate: null

# ---- footprint ------------------------------------------------------------
# Every (kind, target) pair is claimed by EXACTLY ONE unit, repo-wide.
owns:
  - {kind: brew_formula, target: block-goose-cli}
  - {kind: repo_file,    target: config/goose/config.yaml}   # must exist on disk
  - {kind: home_path,    target: ~/.config/goose/config.yaml}

# ---- what a human still has to do -----------------------------------------
manual_steps:
  - id: edit-goosehints           # kebab-case, unique within the unit
    summary: Replace the <placeholders> in ~/.config/goose/.goosehints.
    doc: docs/setup/20-mac-setup.md          # resolves like `runbook`
    blocking: false

# ---- what is known to be wrong or missing ---------------------------------
# Never a bare string. Every blocker is a mapping with all three keys.
blockers:
  - id: goosehints-not-rendered   # kebab-case, unique within the unit
    severity: warn                # note | warn | fail
    detail: unit_base_goose() PRINTS a reminder rather than substituting.

# ---- can it be removed? ---------------------------------------------------
uninstall:
  supported: false
  reason: "`brew pin` is a machine-global side effect with no counterpart."

notes: null                       # free text; nothing reads it
```

### Field reference

| key | type | what makes it checkable |
|---|---|---|
| `id` | str | == filename stem |
| `manifest_version` | int | == `1` |
| `verified_on` | quoted `YYYY-MM-DD` | ISO-parses; never future; ≤180 days old |
| `summary` | str | non-empty, ≤120 chars, single line |
| `host` | enum | `mac` \| `vps` \| `both` \| `checklist` |
| `tier` | enum | `base` \| `default_on` \| `opt_in` |
| `requires` | list[str] | each names an existing manifest; graph acyclic |
| `cost` | list[{`line`,`amount`,`source`}] | `line` and `amount` on the same line of `source` |
| `installer` | null \| {`script`,`function`,`status`} | see below |
| `verify` | list[str] | `scripts/verify/check-*.sh` that exists, optionally + argv; claimed by ≤1 unit |
| `runbook` | null \| `path` \| `path#anchor` | file exists; anchor matches a `##` heading |
| `secrets` | list[{`key`,`store`,`secret`,`optional`,`prompt`,`generate`}] | `store`-conditioned; see below |
| `owns` | list[{`kind`,`target`}] | claimed by exactly one unit repo-wide |
| `manual_steps` | list[{`id`,`summary`,`doc`,`blocking`}] | `doc` resolves like `runbook` |
| `blockers` | list[{`id`,`severity`,`detail`}] | mappings only; bare strings are invalid |
| `uninstall` | {`supported`,`reason`} | `reason` non-empty in **both** states; `supported: true` also needs a non-`base` `tier` and a non-empty `owns`; see below |
| `notes` | null \| str | free text |

### Deliberate absences

- **`display_name`** — `pai list`'s columns do not include it.
- **`provides`** — no consumer. A field nothing reads is the thing this directory exists
  to stop shipping.
- **`goose_config`** — [`goose_template.py`](../../scripts/verify/goose_template.py)
  already owns the fragment roster via `FRAGMENT_ORDER` and enforces one key per fragment.
  A manifest field checked only for existence would be a **third** roster for one fact.
  Name the fragment under `owns` instead.
- **`verified_against`** — [`config/pins.yaml`](../pins.yaml) has exactly one top-level
  key, `goose:`. A per-unit version map would mint a blocker for nearly every unit.
  Version facts go in `blockers`.
- **`values`** — merged into `secrets` via `secret: false`.

---

## The six rules that need their reason written down

### 1. Why `verified_on` is quoted

`yaml.safe_load` turns a bare `2026-09-07` into a `datetime.date` and a bare `24.10` into a
float. The validator wants a string it can parse itself and report verbatim, so the
quoting is part of the schema, not a style choice. `.yamllint.yml` also sets
`octal-values: forbid-implicit-octal`, so any `0600`-shaped value must be quoted too.

### 2. Why `installer` has two states and not an anchor scheme

The obvious alternative — a `# pai-unit: <id>` comment anchor in the installer, asserted to
occur exactly once — was **inexpressible for the base units** when this schema landed:
`bootstrap-mac.sh` had a single `FORMULAE` string serving `base-toolchain`, `base-goose`
*and* `opencode`, and one cask loop serving `base-goose` *and* `base-toolchain`. No anchor
could occur once and mean anything there.

`status` needs no installer edit at all, which is the point: the proof that #36 changed no
install behaviour is an **empty diff**, and an empty diff needs no argument. #37 then
carved those shared lines into one function per unit — and the function name is a better
anchor than a comment would have been, because the installer has to call it.

- `status: planned` ⇒ `unit_<id>()` is **not defined** in `script`. Fails if it appears.
- `status: present` ⇒ defined **exactly once**, and **called exactly once** at top level.

The second half of `present` matters on its own: a `unit_*()` that is defined and never
called is an installer section that silently stopped running.

### 3. Why `secrets` is conditioned on `store`

A blanket "every `secrets[].key` appears in `secrets.env.example`" rule forces a false
entry, because there are three stores and they disagree on purpose:

| `store` | Source of truth | Check |
|---|---|---|
| `vps` | [`config/env/secrets.env.example`](../env/secrets.env.example) (14 names) | key must appear there |
| `mac_keychain` | **these manifests** — `pai secrets --host mac` projects them | the Mac Keychain column of [`10-accounts.md`](../../docs/setup/10-accounts.md#credential-checklist) must agree, both ways |
| `goose_secret_store` | goose's own `secrets.yaml`, per-extension via `envKeys` | key must appear in **neither** |
| `none` | — | skipped |

The `mac_keychain` row changed with #39 and the reason is worth keeping. It used to say
"the key must appear in `keychain-secrets.sh`'s `VARS`" — but that script now *takes* its
roster from this field, so such a rule would compare the generator with itself and could
never fail. What is left that a human still writes by hand is the credential checklist in
the docs, so that is what the closure runs against: a `mac_keychain` row the table does
not mark `yes` fails, and a `yes` no manifest claims fails too. It caught two real bugs on
the day it landed (the table sent readers to put `TODOIST_API_KEY` in the Keychain, which
`store: goose_secret_store` forbids, and it never mentioned `TELEGRAM_BOT_TOKEN` at all).

Two more rules that only exist because the roster is now generated from here:

- **`prompt` is non-empty, single-line and tab-free.** It is the sentence a human reads at
  a hidden prompt. The nine-name `VARS` string had a `case` of hints beside it whose
  default arm was `echo ""`, so two of the ten names prompted with a naked `( )`.
- **Two rows for one `(key, store)` must carry the same `prompt` and `generate`.**
  Duplicate rows are legal and deliberate (`base-secrets` and `brain` both claim
  `GOOSE_SERVER__SECRET_KEY`), but the projection de-duplicates by key — so two rows that
  disagree would make the text depend on which manifest sorts first.

`config/connectors/todoist.yaml` routes `TODOIST_API_KEY` through goose's per-extension
secret store precisely so connector #1 cannot read connector #2's credentials
(see [`config/connectors/README.md`](../connectors/README.md), "Where secrets live"). A
blanket rule would demand that key be added to the global file — inverting the security
property the connector was written to have.

The **reverse** check (every key in `secrets.env.example` is claimed by some unit) is a
NOTE in `--offline` and a FAIL under `--strict`: a key legitimately lands before the unit
that consumes it is written.

### 4. Why staleness is a NOTE in the required job

Every manifest will carry the same `verified_on`, so a 180-day FAIL in a required gate
turns the whole catalog red on one calendar day, for whoever happens to push next. That is
the fastest way to get a gate deleted.

- **Future-dated ⇒ FAIL always.** There is no benign reason for it.
- **Older than 180 days ⇒ NOTE in `--offline`, FAIL under `--strict`.** `--strict` runs on
  a monthly schedule, where a red build is a work item rather than a blocked push.

The same split applies to the two reverse-closure checks (`verify` and `secrets`), which is
what lets the catalog land incrementally without a ratchet commit.

---

## Running it

```bash
scripts/verify/check-units.sh              # --offline is the default, and the CI gate
scripts/verify/check-units.sh --strict     # promotes the three advisory checks to FAIL
```

Exit `0` clean, `1` findings, `2` usage or a missing precondition. Needs `python3` with
PyYAML (falls back to `uv run --with pyyaml`). Speaks to no network. It does run one local
program — `bootstrap-mac.sh --dry-run`, once per unit, for P8(f) — which writes nothing and
needs neither Homebrew nor macOS.

### 5. Why the Mac installer keeps its own copy of this catalog

`scripts/mac/bootstrap-mac.sh` resolves `--with` / `--without` / `--only` against a table
of bash globals — `UNIT_IDS`, `REQUIRES_<ID>`, `OWNS_<ID>` — rather than by reading these
manifests. That is a duplication, and it is deliberate.

The selection has to be computed **before anything is installed**, and a YAML read there is
fail-closed where the rest of that script is fail-tolerant. The evidence is in the same
file: its pins comparison falls back from `python3 -c 'import yaml'` to `uv run --with
pyyaml`, and `uv` is installed by `unit_base_toolchain()` — the *first* unit. So
`--only coding-pack` on a fresh Mac could need a parser that does not exist yet, and a
PyYAML-less Mac would go from "installs everything" to "installs nothing". No test in this
repo could see it, because the harness dies on a missing PyYAML long before that path.

The copy is kept honest from this side instead, by **P8**. It lives in `scripts/verify/`,
where the manifests are the source of truth and where a YAML parser is a reasonable
precondition, and it fails on any divergence.

P8 checks the copy in two ways, because reading it is not enough. (a)–(d) below *read*
`bootstrap-mac.sh`, with regexes anchored on `^NAME="..."` — so they see the table's string
literals and nothing else. Between those literals and anything a user sees sits a `case`
dispatch (`requires_of`, `owns_of`), which the script uses instead of `${!ref}` because an
indirectly-read global is SC2034 to ShellCheck and a warning is a red gate here. One word
changed inside that dispatch produces a wrong install plan with every literal in the file
still matching the manifests perfectly. So **(f) runs the script**: for each unit id it
executes `bootstrap-mac.sh --dry-run --only <id>` and compares the plan and the "would
install" list to the closure and the `owns` entries computed here from the YAML. That is
what makes `--dry-run`'s "would install" list a claim about *this catalog* rather than a
restatement of that script — mechanically, by (d) for the declarations and by (f) for the
code that prints them.

Running the installer from a linter is safe because of what `--dry-run` is: pure
computation over the table, answered before the platform guard, the Homebrew guard and
every write. `test-base-install.sh`'s H2/H2b/H3 assert exactly that — a fresh `$HOME` stays
empty, a populated one stays byte-identical, and no `uname` is ever asked — so (f) forks a
bash and touches nothing, on any OS, with or without Homebrew.

That argument is correct today, and it is no longer the only thing holding. H2/H2b/H3 are a
**different harness in a different workflow**, while `check-units.sh` is a linter people run
locally and casually on their own Mac. On a tree where that bare `exit 0` has been broken,
inheriting the real `$HOME` would have the linter `brew install` and write into `~/.config`,
five times over, bounded only by the 60-second dry-run timeout. So (f) hands each child a
**throwaway `$HOME`** and asserts afterwards that it is still empty. That is behaviourally
free — all five transcripts are byte-identical (stdout, stderr, exit status) under a real
`$HOME` and under a throwaway one, which stays empty — because nothing before the `exit 0`
reads `$HOME` at all: the `OWNS_*` strings carry a **literal `~`**, which bash does not
expand inside the double-quoted assignment and which reaches the plan as a `printf`
argument. Negative control: `data-lint.yml`, "a `--dry-run` that writes into `$HOME` must
fail", which breaks that exit path and then asserts both that (f) names the write *and* that
the runner's own `$HOME` did not gain it — the second is what fails if the throwaway `$HOME`
is ever dropped.

### 6. Why `uninstall.supported: true` has three preconditions

[`scripts/pai/uninstall.py`](../../scripts/pai/uninstall.py) (`pai remove`) is the reader
for this block, and it has no vocabulary of its own — the sentence it prints is this
`reason`, verbatim modulo re-wrapping. These rules are the ones that keep that output from
becoming decoration.

- **`reason` is non-empty in BOTH states.** Only `supported: false` used to need one, so
  `{supported: true, reason: ""}` passed — and `pai remove` would print a blank
  explanation in the one state where a reader most needs to know what is left behind.
- **`supported: true` is refused on `tier: base`.** A base unit *is* the install; `pai
  remove` refuses it at the tier arm before it ever reads this block, so a manifest
  claiming otherwise makes a claim the tool contradicts. `base-skills` is what makes this
  arm non-trivial: its one `home_path` is as removable as anything in the catalogue, and
  nothing but the tier stops it.
- **`supported: true` requires a non-empty `owns`.** A unit that owns nothing has nothing
  to remove, so removing it is a no-op that reports success. This covers exactly ONE file:
  P4 already fails an empty `owns` unless `host: checklist`, so `phone-kit.yaml` — four
  apps and a Shortcut, all on a phone — is the only manifest the arm can reach. A rule
  whose coverage is one file is worth having only if nobody thinks it is doing more.

Kept honest in both directions: `test-pai.sh`'s remove probe feeds each rejected shape
through the real `check_uninstall` (so a rule dropped from the lint goes red) **and** greps
this section for the rule (so a rule dropped from here goes red). P1's advertised property
is "every manifest matches this README"; nothing else in the repo compares the two.

---

## What the validator checks

Eight properties. Each one has a negative control in `data-lint.yml` or in the notes
below, because an assertion that cannot fail is the only kind that is never noticed.

1. **Schema & identity** — `id` == stem, `manifest_version == 1`, all 17 keys present,
   every enum/type/regex, and **unknown top-level keys are FATAL**.
2. **Graph** — every `requires` entry names an existing manifest; the whole graph is
   acyclic (Kahn), and a cycle is reported as the residual node set.
3. **Installer** — the two-state rule above, plus `function` == `"unit_" + id` with
   hyphens as underscores, plus `script` exists and is executable.
4. **Footprint** — `owns` non-empty unless `host: checklist`; `repo_file` targets exist;
   every `(kind, target)` pair claimed by **exactly one** unit.
5. **References** — each `verify` entry STARTS with a `scripts/verify/check-*.sh` that
   exists (arguments may follow), and each is claimed by at most one unit; **reverse**,
   every `check-*.sh` outside the `UNCLAIMABLE` set is claimed.
   `runbook` and `manual_steps[].doc` resolve, anchors included.
6. **Secrets** — the `store`-conditioned rules above, forward and reverse, plus the
   `prompt`/`generate` rules and the Mac Keychain column of `10-accounts.md`.
7. **Freshness** — `verified_on` parses, is not in the future, and is not stale.
8. **Installer table** — `bootstrap-mac.sh`'s copy of this catalog (§5 above) matches it:
   (a) `UNIT_IDS` is exactly the units whose installer is that script with
   `status: present`, **listed once each** — the comparison behind it is over sets, so a
   repeat is called out on its own; (b) that list is a topological order of their
   `requires` graph, because the script's call order *is* that list, filtered;
   (c) each `REQUIRES_<ID>`
   equals the manifest's `requires` **intersected with `UNIT_IDS`**, so `base-goose`
   dropping `base-secrets` (which has `installer: null`) is asserted rather than assumed;
   (d) each `OWNS_<ID>` equals the manifest's `brew_formula` / `brew_cask` / `home_path`
   targets; (e) **reverse**, every `config/skills/<name>/` is claimed as a `repo_file` by
   exactly one unit; (f) **executed**, `--dry-run --only <id>` for every id prints a plan
   that is the manifests' `requires` closure in a topological order, and a "would install"
   list that is exactly those units' `owns` entries, in plan order.

8(f) is what covers the `case` dispatch (§5 above): (a)–(d) read the declarations, and a
one-word change to `requires_of` or `owns_of` leaves every declaration correct while
`--only base-goose` plans a one-unit install with no `uv`. Measured before it existed: that
mutation left `check-units.sh` green *and* `test-base-install.sh` at "49 passed, 0 failed".
It is skipped when (a)–(d) already failed — running `--only` against a table that does not
match the manifests would restate that divergence in a message about the dispatch, which
is not where the fault is. Negative control: `data-lint.yml`, "a case arm that ignores its
REQUIRES_* must fail".

8(a)'s "listed once each" is the one divergence neither the set comparisons nor 8(f) could
see. Doubling `coding-pack` in `UNIT_IDS` makes the default `--dry-run` announce "6 units",
list it twice and repeat its whole 13-line `would install` block — 47 lines where the golden
is 33 — and 8(f) compares `set(plan)` to the closure and derives the expected `owns` list by
walking the plan it was handed, so the duplication cancels on both sides. Measured on this
tree before the check existed: `check-units.sh` at "8 passed, 0 failed" in *both* modes
against that 47-line dry run. `test-base-install.sh`'s H1 golden did catch it, but that is a
different workflow, so "P8 fails on any divergence" was true only of the divergences P8 was
looking for. No separate negative control: the mutation is one word in `UNIT_IDS`, and what
would be at risk of going inert is P8 as a whole, which "a case arm that ignores its
REQUIRES_* must fail" already covers.

8(e) is the totality gate. The installer enumerates skills per unit by name rather than
globbing `config/skills/`, precisely so `--without opencode` cannot quietly install a
`coding-pack` skill. The cost is that a thirteenth skill directory would be installed by
nobody, so an unclaimed one is a FAIL naming the directory.

`UNCLAIMABLE` is `{check-coverage.sh, check-goose-template.sh, check-units.sh}`: all three
are repo/CI gates rather than unit checks, so demanding an owner for them would mint a fake
unit. `pai verify` lists them under "claimed by no unit" rather than running them —
`check-coverage.sh` in particular exits 2 with no `coverage.json`, which inside a sweep
would render as a permanent SKIP indistinguishable from a real missing precondition.

## Adding a unit

1. Read the two installers for what the unit **actually does today**. Do not read the
   docs — the drift between them is the reason this directory exists.
2. Copy the schema above. Fill every key; `null`/`[]` where there is nothing.
3. Where something is missing, **say so**: `installer: null`, `verify: []` with a
   `no-verify` blocker, `runbook: null` with a `no-runbook` blocker.
4. If the unit's installer is `scripts/mac/bootstrap-mac.sh` with `status: present`, add it
   to that script's `UNIT_IDS` / `REQUIRES_<ID>` / `OWNS_<ID>` table too, in a position
   that keeps `UNIT_IDS` topologically ordered. P8 fails until you do.
5. `scripts/verify/check-units.sh` and `yamllint --strict -c .yamllint.yml config/units/`.
