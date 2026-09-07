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
verify:
  - scripts/verify/check-goose.sh
runbook: docs/setup/20-mac-setup.md         # or `path#anchor`, or null

# ---- credentials, BY NAME ONLY --------------------------------------------
secrets:
  - key: TOGETHER_API_KEY         # [A-Z][A-Z0-9_]*
    store: mac_keychain           # vps | mac_keychain | goose_secret_store | none
    secret: true                  # false => a value, not a credential (e.g. an email)
    optional: false

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
    detail: bootstrap-mac.sh:215-216 PRINTS a reminder rather than substituting.

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
| `verify` | list[path] | existing `scripts/verify/check-*.sh`; claimed by ≤1 unit |
| `runbook` | null \| `path` \| `path#anchor` | file exists; anchor matches a `##` heading |
| `secrets` | list[{`key`,`store`,`secret`,`optional`}] | `store`-conditioned; see below |
| `owns` | list[{`kind`,`target`}] | claimed by exactly one unit repo-wide |
| `manual_steps` | list[{`id`,`summary`,`doc`,`blocking`}] | `doc` resolves like `runbook` |
| `blockers` | list[{`id`,`severity`,`detail`}] | mappings only; bare strings are invalid |
| `uninstall` | {`supported`,`reason`} | `supported: false` needs a non-empty `reason` |
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

## The four rules that need their reason written down

### 1. Why `verified_on` is quoted

`yaml.safe_load` turns a bare `2026-09-07` into a `datetime.date` and a bare `24.10` into a
float. The validator wants a string it can parse itself and report verbatim, so the
quoting is part of the schema, not a style choice. `.yamllint.yml` also sets
`octal-values: forbid-implicit-octal`, so any `0600`-shaped value must be quoted too.

### 2. Why `installer` has two states and not an anchor scheme

The obvious alternative — a `# pai-unit: <id>` comment anchor in the installer, asserted to
occur exactly once — is **inexpressible for the base units**. `bootstrap-mac.sh:118` is a
single `FORMULAE` string serving `base-toolchain`, `base-goose` *and* `opencode`, and
`:131` is one cask loop serving `base-goose` *and* `base-toolchain`. No anchor can occur
once and mean anything there.

`status` needs no installer edit at all, which is the point: the proof that #36 changed no
install behaviour is an **empty diff**, and an empty diff needs no argument.

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
| `mac_keychain` | `scripts/mac/keychain-secrets.sh:12`'s `VARS` (10 names) | key must appear there |
| `goose_secret_store` | goose's own `secrets.yaml`, per-extension via `envKeys` | key must appear in **neither** |
| `none` | — | skipped |

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
PyYAML (falls back to `uv run --with pyyaml`). Speaks to nothing.

## What the validator checks

Seven properties. Each one has a negative control in `data-lint.yml` or in the notes
below, because an assertion that cannot fail is the only kind that is never noticed.

1. **Schema & identity** — `id` == stem, `manifest_version == 1`, all 17 keys present,
   every enum/type/regex, and **unknown top-level keys are FATAL**.
2. **Graph** — every `requires` entry names an existing manifest; the whole graph is
   acyclic (Kahn), and a cycle is reported as the residual node set.
3. **Installer** — the two-state rule above, plus `function` == `"unit_" + id` with
   hyphens as underscores, plus `script` exists and is executable.
4. **Footprint** — `owns` non-empty unless `host: checklist`; `repo_file` targets exist;
   every `(kind, target)` pair claimed by **exactly one** unit.
5. **References** — `verify` entries exist, match `check-*.sh`, and are claimed by at most
   one unit; **reverse**, every `check-*.sh` outside the `UNCLAIMABLE` set is claimed.
   `runbook` and `manual_steps[].doc` resolve, anchors included.
6. **Secrets** — the `store`-conditioned rules above, forward and reverse.
7. **Freshness** — `verified_on` parses, is not in the future, and is not stale.

`UNCLAIMABLE` is `{check-coverage.sh, check-goose-template.sh}`: both are repo/CI gates
rather than unit checks, so demanding an owner for them would mint a fake unit.

## Adding a unit

1. Read the two installers for what the unit **actually does today**. Do not read the
   docs — the drift between them is the reason this directory exists.
2. Copy the schema above. Fill every key; `null`/`[]` where there is nothing.
3. Where something is missing, **say so**: `installer: null`, `verify: []` with a
   `no-verify` blocker, `runbook: null` with a `no-runbook` blocker.
4. `scripts/verify/check-units.sh` and `yamllint --strict -c .yamllint.yml config/units/`.
