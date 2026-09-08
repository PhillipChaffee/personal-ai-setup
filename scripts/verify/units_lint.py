#!/usr/bin/env python3
"""units_lint.py — validate config/units/*.yaml against that directory's README.

A unit manifest describes what one installable piece of this setup ACTUALLY IS
TODAY: what installs it, what it puts on disk, which secrets it needs, which
check-*.sh proves it works — and, crucially, which of those things do not exist
yet. Eight of this repo's eighteen units have nothing that installs them and
eleven have no verify script. A manifest that papers over that is worse than no
manifest, so the schema has a place to record every absence and this file FAILS
when an absence is unrecorded.

WHY A TRACKED .py AND NOT A HEREDOC. This follows the tree's newest pattern,
check-goose-template.sh + goose_template.py: the work is a YAML parse, a
topological sort and six cross-file joins, which is Python's job; the verdict
counting and the exit-code convention are lib.sh's. check-units.sh is that seam.
It also means ruff and mypy --strict read this file, which a heredoc forecloses.

THE EIGHT PROPERTIES, and what each catches that the others do not:

  P1 schema & identity   `id` == filename stem, manifest_version == 1, all 17
                         keys present, every enum/type/regex — and an unknown
                         TOP-LEVEL KEY IS FATAL. This is an escalation, not a
                         port: check-connectors.sh makes an unknown top-level
                         key a note(). An assertion key nothing reads asserts
                         nothing, forever, and it does it in a file whose whole
                         claim is to be machine-checked.
  P2 graph               every `requires` names an existing manifest, and the
                         graph is acyclic (Kahn; the residual is the cycle).
  P3 installer           the two-state rule. `status: planned` asserts the
                         function DOES NOT EXIST — it fails the moment #37
                         writes it, which is what stops `planned` rotting into
                         a lie. `status: present` asserts defined exactly once
                         AND called exactly once, because a unit_*() that is
                         never called is an installer section that silently
                         stopped running.
  P4 footprint           every (kind, target) pair is claimed by EXACTLY ONE
                         unit. Epic #30's own table double-claims two brew
                         casks; this is what caught it.
  P5 references          `verify` entries resolve and are claimed at most once,
                         and — REVERSE — every check-*.sh outside UNCLAIMABLE
                         is claimed. Runbook and manual-step docs resolve,
                         `#anchor` included. `verify: []` demands a `no-verify`
                         blocker; `runbook: null` demands a `no-runbook` one.
  P6 secrets             CONDITIONED ON `store`. A blanket "every key appears
                         in secrets.env.example" rule would force a false entry
                         for TODOIST_API_KEY, which routes through goose's
                         per-extension secret store precisely so connector #1
                         cannot read connector #2's credentials.
  P7 freshness           `verified_on` parses, is never in the future, and is
                         not stale.
  P8 installer table     bootstrap-mac.sh resolves --with/--without/--only
                         against a COPY of this catalog: UNIT_IDS, REQUIRES_*
                         and OWNS_* are bash globals, because the selection has
                         to be computed before `uv` (and therefore PyYAML)
                         exists on a fresh Mac. This is the check that stops the
                         copy from drifting — and it is the reason the copy is
                         allowed to exist. It also closes the catalog over
                         config/skills/: a skill directory no unit claims is a
                         skill the installer will never install.

THE ADVISORY SPLIT. P5-reverse, P6-reverse and P7's age arm are NOTE under
--offline and FAIL under --strict. Every manifest carries the same
`verified_on`, so a 180-day FAIL in a required gate turns the whole catalog red
on one calendar day for whoever happens to push next — the fastest way to get a
gate deleted. The same split is what lets the catalog land incrementally: the
two reverse-closure checks cannot pass until all eighteen manifests exist.

    scripts/verify/check-units.sh              # --offline, what CI runs
    scripts/verify/check-units.sh --strict     # the monthly scheduled run
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Final

import yaml

if TYPE_CHECKING:
    from collections.abc import Iterable, Sequence

# Derived from __file__, never from the cwd or `git rev-parse`: data-lint.yml's
# negative tests run a COPY of the tree out of $RUNNER_TEMP and must validate
# that copy. A git-derived root would walk back up to the real checkout and
# validate it instead, leaving both negative tests inert. Same rule
# goose_template.py and check-connectors.sh apply to their own roots.
REPO_ROOT: Final = Path(__file__).resolve().parents[2]
UNITS_DIR: Final = REPO_ROOT / "config" / "units"
VERIFY_DIR: Final = REPO_ROOT / "scripts" / "verify"
SECRETS_EXAMPLE: Final = REPO_ROOT / "config" / "env" / "secrets.env.example"
KEYCHAIN_SCRIPT: Final = REPO_ROOT / "scripts" / "mac" / "keychain-secrets.sh"
SKILLS_DIR: Final = REPO_ROOT / "config" / "skills"
BOOTSTRAP_MAC: Final = REPO_ROOT / "scripts" / "mac" / "bootstrap-mac.sh"

MANIFEST_VERSION: Final = 1
SUMMARY_MAX: Final = 120
STALE_DAYS: Final = 180
# `config/skills/<name>` -- exactly three parts. A deeper path is a file INSIDE
# a skill, which is that skill's business rather than a claim on the directory.
SKILL_PATH_PARTS: Final = 3

# All 17 keys are required. A key with nothing to say is present and explicitly
# null or []; omitting it is a FAIL, and so is adding an eighteenth.
REQUIRED_KEYS: Final[frozenset[str]] = frozenset({
    "id",
    "manifest_version",
    "verified_on",
    "summary",
    "host",
    "tier",
    "requires",
    "cost",
    "installer",
    "verify",
    "runbook",
    "secrets",
    "owns",
    "manual_steps",
    "blockers",
    "uninstall",
    "notes",
})

HOSTS: Final[frozenset[str]] = frozenset({"mac", "vps", "both", "checklist"})
TIERS: Final[frozenset[str]] = frozenset({"base", "default_on", "opt_in"})
STORES: Final[frozenset[str]] = frozenset({
    "vps",
    "mac_keychain",
    "goose_secret_store",
    "none",
})
OWN_KINDS: Final[frozenset[str]] = frozenset({
    "repo_file",
    "brew_formula",
    "brew_cask",
    "home_path",
    "data_path",
    "systemd_unit",
    "container_image",
    "manual",
})
SEVERITIES: Final[frozenset[str]] = frozenset({"note", "warn", "fail"})
INSTALLER_STATUSES: Final[frozenset[str]] = frozenset({"planned", "present"})

# The only two scripts that install anything. Naming a third would mean the
# catalog had drifted from the tree without anyone saying so.
MAC_INSTALLER: Final = "scripts/mac/bootstrap-mac.sh"
INSTALLER_SCRIPTS: Final[frozenset[str]] = frozenset({
    MAC_INSTALLER,
    "scripts/vps/deploy-vps.sh",
})

# P8's mapping between an `owns` kind and the prefix bootstrap-mac.sh's OWNS_*
# table uses for it. The three kinds here are exactly the ones the --dry-run
# plan can print; repo_file and manual describe the repo and a human, neither of
# which is something the installer puts on the machine.
OWN_KIND_PREFIX: Final[dict[str, str]] = {
    "brew_formula": "brew:",
    "brew_cask": "cask:",
    "home_path": "home:",
}

# check-*.sh files that no unit can legitimately claim, with the reason. These
# are repo/CI gates rather than unit checks, so demanding an owner for them
# would mint a fake unit to hold them.
UNCLAIMABLE: Final[dict[str, str]] = {
    "check-coverage.sh": "a repo-wide coverage gate, not a unit's proof",
    "check-goose-template.sh": "a generated-artifact gate, not a unit's proof",
    # This file's own driver. A unit claiming it would be asserting that the
    # validator proves something about that unit, when what it actually does is
    # validate every manifest including that one.
    "check-units.sh": "this validator's own driver, not a unit's proof",
}

# The record shapes. Each entry must be a mapping whose keys are EXACTLY these.
RECORD_FIELDS: Final[dict[str, frozenset[str]]] = {
    "cost": frozenset({"line", "amount", "source"}),
    "secrets": frozenset({"key", "store", "secret", "optional"}),
    "owns": frozenset({"kind", "target"}),
    "manual_steps": frozenset({"id", "summary", "doc", "blocking"}),
    "blockers": frozenset({"id", "severity", "detail"}),
}

# Fields whose only job is to say something, and which must therefore say it.
# `installer: null` is legal ONLY because `manual_steps` is non-empty, so a step
# with an empty summary discharges the obligation to explain what a human does
# instead while explaining nothing; an absence recorded as "" is not recorded.
NON_EMPTY_TEXT: Final[dict[str, tuple[str, ...]]] = {
    "manual_steps": ("summary",),
    "blockers": ("detail",),
}

SECRET_KEY_RE: Final = re.compile(r"^[A-Z][A-Z0-9_]*$")
KEBAB_RE: Final = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
ENV_KEY_RE: Final = re.compile(r"^([A-Z][A-Z0-9_]*)=", re.MULTILINE)
KEYCHAIN_VARS_RE: Final = re.compile(r'^VARS="([^"]*)"', re.MULTILINE)


# ------------------------------------------------------------------ output --


def emit(line: str) -> None:
    print(line)  # noqa: T201 -- this IS the reporting surface


def report(label: str, findings: Sequence[str], notes: Sequence[str] = ()) -> list[str]:
    """Turn one property's findings into the repo's PASS/FAIL/NOTE line shape."""
    lines = [f"FAIL  {f}" for f in findings]
    if not findings:
        lines.append(f"PASS  {label}")
    lines.extend(f"NOTE  {n}" for n in notes)
    return lines


# ------------------------------------------------------------- yaml helpers --


def mappings(value: object) -> list[dict[str, object]]:
    """Return the mapping entries of a list, ignoring anything else.

    Shape violations are P1's job to report; every other property reads through
    this so a malformed entry produces ONE finding rather than a traceback.
    """
    if not isinstance(value, list):
        return []
    return [entry for entry in value if isinstance(entry, dict)]


def strings(value: object) -> list[str]:
    if not isinstance(value, list):
        return []
    return [entry for entry in value if isinstance(entry, str)]


def text_field(record: dict[str, object], key: str) -> str:
    value = record.get(key)
    return value if isinstance(value, str) else ""


@dataclass(frozen=True)
class Manifest:
    stem: str
    path: Path
    data: dict[str, object]

    @property
    def uid(self) -> str:
        """The manifest's own `id`, falling back to the stem when it is absent."""
        value = self.data.get("id")
        return value if isinstance(value, str) else self.stem

    def list_of(self, key: str) -> list[dict[str, object]]:
        return mappings(self.data.get(key))

    def blocker_ids(self) -> set[str]:
        return {text_field(b, "id") for b in self.list_of("blockers")}


@dataclass
class Findings:
    """One property's verdict: hard failures, plus advisory lines."""

    hard: list[str] = field(default_factory=list)
    soft: list[str] = field(default_factory=list)

    def resolve(self, *, strict: bool) -> tuple[list[str], list[str]]:
        """Fold the advisory lines into failures under --strict."""
        if strict:
            return ([*self.hard, *self.soft], [])
        return (self.hard, self.soft)


# ------------------------------------------------------------------ loading --


def load_manifests() -> tuple[list[Manifest], list[str]]:
    if not UNITS_DIR.is_dir():
        return ([], [f"config/units/ does not exist at {UNITS_DIR}"])
    units: list[Manifest] = []
    problems: list[str] = []
    for path in sorted(UNITS_DIR.glob("*.yaml")):
        try:
            parsed: object = yaml.safe_load(path.read_text(encoding="utf-8"))
        except yaml.YAMLError as exc:
            problems.append(f"{path.name} is not parseable YAML: {exc}")
            continue
        if not isinstance(parsed, dict):
            problems.append(f"{path.name} does not parse to a mapping")
            continue
        units.append(Manifest(stem=path.stem, path=path, data=parsed))
    return (units, problems)


# -------------------------------------------------- markdown link resolution --


def slugify(heading: str) -> str:
    """Slug a markdown heading the way GitHub anchors it."""
    kept = [char if char.isalnum() else "-" if char in " -_" else "" for char in heading.lower()]
    return re.sub(r"-+", "-", "".join(kept)).strip("-")


def heading_slugs(path: Path) -> set[str]:
    slugs: set[str] = set()
    fenced = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.lstrip().startswith("```"):
            fenced = not fenced
        elif not fenced and line.startswith("#"):
            slugs.add(slugify(line.lstrip("#").strip()))
    return slugs


def resolve_doc(ref: str) -> str:
    """Return a complaint about `path` or `path#anchor`, or "" when it resolves."""
    rel, _, anchor = ref.partition("#")
    path = REPO_ROOT / rel
    if not path.is_file():
        return f"'{rel}' does not exist"
    if anchor and anchor not in heading_slugs(path):
        return f"anchor '#{anchor}' is not a heading in {rel}"
    return ""


# ------------------------------------------------------ P1 schema & identity --


def check_records(unit: Manifest, key: str) -> list[str]:
    """Every entry under `key` is a mapping whose keys are exactly the schema's."""
    value = unit.data.get(key)
    if not isinstance(value, list):
        return [f"{unit.stem}.{key} must be a list"]
    wanted = RECORD_FIELDS[key]
    out: list[str] = []
    for index, entry in enumerate(value):
        if not isinstance(entry, dict):
            # Bare strings under `blockers` are the tempting shorthand, and they
            # drop the severity that makes a blocker actionable.
            out.append(f"{unit.stem}.{key}[{index}] must be a mapping, not {type(entry).__name__}")
            continue
        got = set(entry)
        if got != wanted:
            missing = ", ".join(sorted(wanted - got)) or "-"
            extra = ", ".join(sorted(got - wanted)) or "-"
            out.append(f"{unit.stem}.{key}[{index}] fields wrong "
                       f"(missing: {missing}; extra: {extra})")
    return out


def check_identity(unit: Manifest) -> list[str]:
    out: list[str] = []
    data = unit.data
    if not isinstance(data.get("id"), str):
        # Without this arm `uid` falls back to the stem and the comparison below
        # compares the stem with itself, so `id: null` and `id: 12345` pass the
        # one check whose entire job is to catch an id that is not the stem.
        out.append(f"{unit.stem}.id must be a string")
    elif unit.uid != unit.stem:
        out.append(f"{unit.stem}.yaml declares id '{unit.uid}' — id must equal the filename stem")
    if data.get("manifest_version") != MANIFEST_VERSION:
        out.append(f"{unit.stem}.manifest_version must be {MANIFEST_VERSION}")
    summary = data.get("summary")
    if not isinstance(summary, str) or not summary.strip():
        out.append(f"{unit.stem}.summary must be a non-empty string")
    elif len(summary) > SUMMARY_MAX or "\n" in summary:
        out.append(f"{unit.stem}.summary must be a single line of at most {SUMMARY_MAX} chars")
    out.extend(
        f"{unit.stem}.{key} must be one of {sorted(allowed)}"
        for key, allowed in (("host", HOSTS), ("tier", TIERS))
        if data.get(key) not in allowed
    )
    return out


def check_types(unit: Manifest) -> list[str]:
    out: list[str] = []
    data = unit.data
    # Quoted, so it is still a string here. A bare 2026-09-07 parses to a
    # datetime.date and would silently satisfy a laxer check.
    if not isinstance(data.get("verified_on"), str):
        out.append(f"{unit.stem}.verified_on must be a QUOTED string (bare dates parse to a date)")
    out.extend(
        f"{unit.stem}.{key} must be a list"
        for key in ("requires", "verify")
        if not isinstance(data.get(key), list)
    )
    out.extend(
        f"{unit.stem}.{key} must be a string or null"
        for key in ("runbook", "notes")
        if data.get(key) is not None and not isinstance(data.get(key), str)
    )
    return out


def check_cost(unit: Manifest) -> list[str]:
    """Cross-check each cost entry VERBATIM against the file it names.

    `line` and `amount` must appear on the SAME LINE of `source`, which is what
    README.md:92-93 and the field table at :157 both promise. Shape-checking the
    three keys and stopping there leaves `cost` a place to type a number nobody
    reads — a field that looks checked, is documented as checked, and is not.
    """
    out: list[str] = []
    for index, entry in enumerate(unit.list_of("cost")):
        where = f"{unit.stem}.cost[{index}]"
        source = text_field(entry, "source")
        line = text_field(entry, "line")
        amount = text_field(entry, "amount")
        if not (source and line and amount):
            out.append(f"{where} needs a non-empty line, amount and source")
        elif Path(source).is_absolute() or ".." in Path(source).parts:
            out.append(f"{where} source '{source}' must be a repo-relative path")
        elif not (REPO_ROOT / source).is_file():
            out.append(f"{where} source '{source}' does not exist")
        elif not any(
            line in row and amount in row
            for row in (REPO_ROOT / source).read_text(encoding="utf-8").splitlines()
        ):
            out.append(f"{where} '{line}' and '{amount}' are not on the same line of "
                       f"{source} — cost figures are quoted from a budget row, never invented")
    return out


def check_non_empty(unit: Manifest) -> list[str]:
    """Require the fields whose only job is to say something to say it."""
    out: list[str] = []
    for key, fields in NON_EMPTY_TEXT.items():
        for index, entry in enumerate(unit.list_of(key)):
            out.extend(
                f"{unit.stem}.{key}[{index}].{name} must be a non-empty string"
                for name in fields
                if not text_field(entry, name).strip()
            )
    return out


def check_string_lists(unit: Manifest) -> list[str]:
    """Report list entries that are not strings, which `strings()` would drop.

    A `requires` entry that is a mapping vanishes from the graph and a `verify`
    entry that is a mapping vanishes from the claim table — silently, with both
    properties still reporting PASS. Filtering is how the other checks avoid a
    traceback; saying nothing about what was filtered is how one typo turns a
    checked field into an unchecked one.
    """
    out: list[str] = []
    for key in ("requires", "verify"):
        value = unit.data.get(key)
        if not isinstance(value, list):
            continue  # check_types already reported the type.
        out.extend(
            f"{unit.stem}.{key}[{index}] must be a string, not {type(entry).__name__}"
            for index, entry in enumerate(value)
            if not isinstance(entry, str)
        )
    return out


def check_uninstall(unit: Manifest) -> list[str]:
    value = unit.data.get("uninstall")
    if not isinstance(value, dict) or set(value) != {"supported", "reason"}:
        return [f"{unit.stem}.uninstall must be a mapping with exactly: supported, reason"]
    if not isinstance(value.get("supported"), bool):
        return [f"{unit.stem}.uninstall.supported must be a boolean"]
    if not value["supported"] and not text_field(value, "reason").strip():
        return [f"{unit.stem}.uninstall.supported is false but reason is empty"]
    return []


def check_entry_ids(unit: Manifest) -> list[str]:
    """Check the kebab-case ids that must be unique within one manifest."""
    out: list[str] = []
    for key in ("manual_steps", "blockers"):
        seen: set[str] = set()
        for entry in unit.list_of(key):
            entry_id = text_field(entry, "id")
            if not KEBAB_RE.match(entry_id):
                out.append(f"{unit.stem}.{key} id '{entry_id}' must be kebab-case")
            elif entry_id in seen:
                out.append(f"{unit.stem}.{key} id '{entry_id}' is used twice in this unit")
            seen.add(entry_id)
    return out


def check_enums(unit: Manifest) -> list[str]:
    """Check the enum and boolean fields inside blockers and manual_steps."""
    out: list[str] = [
        f"{unit.stem}.blockers['{text_field(entry, 'id')}'].severity must be one "
        f"of {sorted(SEVERITIES)}"
        for entry in unit.list_of("blockers")
        if entry.get("severity") not in SEVERITIES
    ]
    out.extend(
        f"{unit.stem}.manual_steps['{text_field(entry, 'id')}'].blocking must be a boolean"
        for entry in unit.list_of("manual_steps")
        if not isinstance(entry.get("blocking"), bool)
    )
    return out


def check_secret_fields(unit: Manifest) -> list[str]:
    """Check each secret's key spelling, store enum and two boolean flags."""
    out: list[str] = []
    for entry in unit.list_of("secrets"):
        key_name = text_field(entry, "key")
        if not SECRET_KEY_RE.match(key_name):
            out.append(f"{unit.stem}.secrets key '{key_name}' must match [A-Z][A-Z0-9_]*")
        if entry.get("store") not in STORES:
            out.append(f"{unit.stem}.secrets['{key_name}'].store must be one of {sorted(STORES)}")
        out.extend(
            f"{unit.stem}.secrets['{key_name}'].{flag} must be a boolean"
            for flag in ("secret", "optional")
            if not isinstance(entry.get(flag), bool)
        )
    return out


def prop_schema(units: Sequence[Manifest]) -> Findings:
    result = Findings()
    for unit in units:
        keys = set(unit.data)
        unknown = keys - REQUIRED_KEYS
        if unknown:
            result.hard.append(
                f"unknown top-level key(s) in {unit.stem}.yaml: {', '.join(sorted(unknown))} "
                f"— an assertion key nothing reads asserts NOTHING, forever",
            )
        missing = REQUIRED_KEYS - keys
        if missing:
            result.hard.append(
                f"{unit.stem}.yaml is missing required key(s): {', '.join(sorted(missing))} "
                f"(a key with nothing to say is present and explicitly null/[])",
            )
        result.hard.extend(check_identity(unit))
        result.hard.extend(check_types(unit))
        result.hard.extend(check_string_lists(unit))
        for key in RECORD_FIELDS:
            result.hard.extend(check_records(unit, key))
        result.hard.extend(check_cost(unit))
        result.hard.extend(check_non_empty(unit))
        result.hard.extend(check_entry_ids(unit))
        result.hard.extend(check_enums(unit))
        result.hard.extend(check_secret_fields(unit))
        result.hard.extend(check_uninstall(unit))
    return result


# ------------------------------------------------------------------ P2 graph --


def prop_graph(units: Sequence[Manifest]) -> Findings:
    result = Findings()
    known = {unit.stem for unit in units}
    edges: dict[str, list[str]] = {}
    for unit in units:
        deps = strings(unit.data.get("requires"))
        edges[unit.stem] = [dep for dep in deps if dep in known]
        for dep in deps:
            if dep not in known:
                result.hard.append(f"{unit.stem}.requires names unknown unit '{dep}'")
            elif dep == unit.stem:
                result.hard.append(f"{unit.stem}.requires names itself")
    # Kahn: whatever still has unmet dependencies once nothing more can be
    # settled IS the cycle, which is the only report a reader can act on.
    settled: set[str] = set()
    pending = dict(edges)
    while True:
        ready = [node for node, deps in pending.items() if all(d in settled for d in deps)]
        if not ready:
            break
        settled.update(ready)
        for node in ready:
            del pending[node]
    if pending:
        result.hard.append(f"requires cycle among: {', '.join(sorted(pending))}")
    return result


# -------------------------------------------------------------- P3 installer --


def function_lines(text: str, pattern: re.Pattern[str]) -> list[int]:
    return [text.count("\n", 0, match.start()) + 1 for match in pattern.finditer(text)]


def check_installer_fields(unit: Manifest, block: dict[str, object]) -> list[str]:
    """Check the three installer fields before any script is opened."""
    stem = unit.stem
    out: list[str] = []
    expected = "unit_" + unit.uid.replace("-", "_")
    func = text_field(block, "function")
    if func != expected:
        out.append(f"{stem}.installer.function must be '{expected}', not '{func}'")
    if text_field(block, "status") not in INSTALLER_STATUSES:
        out.append(f"{stem}.installer.status must be one of {sorted(INSTALLER_STATUSES)}")
    script = text_field(block, "script")
    if script not in INSTALLER_SCRIPTS:
        out.append(f"{stem}.installer.script must be one of {sorted(INSTALLER_SCRIPTS)}")
    elif not (REPO_ROOT / script).is_file():
        out.append(f"{stem}.installer.script '{script}' does not exist")
    elif not os.access(REPO_ROOT / script, os.X_OK):
        out.append(f"{stem}.installer.script '{script}' is not executable")
    return out


def check_installer_status(stem: str, script: str, func: str, status: str) -> list[str]:
    """Assert the named function's presence or absence in the named installer.

    `planned` asserts the function DOES NOT EXIST. That is the arm that keeps
    the status honest: it fails the moment #37 writes the function, handing the
    author a one-word edit instead of letting the claim rot.
    """
    text = (REPO_ROOT / script).read_text(encoding="utf-8")
    defined = function_lines(text, re.compile(rf"^{re.escape(func)}\s*\(\)", re.MULTILINE))
    if status == "planned":
        if defined:
            return [f"{stem}: status is 'planned' but {func}() is defined at "
                    f"{script}:{defined[0]} — flip status to present"]
        return []
    out: list[str] = []
    if len(defined) != 1:
        out.append(f"{stem}: status is 'present' but {func}() is defined {len(defined)} "
                   f"times in {script} (want exactly 1)")
    called = function_lines(text, re.compile(rf"^{re.escape(func)}\s*$", re.MULTILINE))
    if len(called) != 1:
        out.append(f"{stem}: {func}() is called {len(called)} times at top level in "
                   f"{script} (want exactly 1) — a function nobody calls installs nothing")
    return out


def prop_installer(units: Sequence[Manifest]) -> Findings:
    result = Findings()
    for unit in units:
        block = unit.data.get("installer")
        if block is None:
            # Legal, and the whole point of the schema — but only when the
            # manifest says what a human does instead.
            if not unit.list_of("manual_steps") and unit.data.get("host") != "checklist":
                result.hard.append(
                    f"{unit.stem}.installer is null but manual_steps is empty — say what a "
                    f"human does instead, or name the installer",
                )
            continue
        if not isinstance(block, dict) or set(block) != {"script", "function", "status"}:
            result.hard.append(
                f"{unit.stem}.installer must be null or a mapping with exactly: "
                f"script, function, status",
            )
            continue
        problems = check_installer_fields(unit, block)
        if problems:
            result.hard.extend(problems)
            continue
        result.hard.extend(check_installer_status(
            unit.stem,
            text_field(block, "script"),
            text_field(block, "function"),
            text_field(block, "status"),
        ))
    return result


# -------------------------------------------------------------- P4 footprint --


def prop_footprint(units: Sequence[Manifest]) -> Findings:
    result = Findings()
    claims: dict[tuple[str, str], list[str]] = {}
    for unit in units:
        owned = unit.list_of("owns")
        if not owned and unit.data.get("host") != "checklist":
            result.hard.append(f"{unit.stem}.owns is empty — a unit that installs nothing is a "
                               f"checklist, so say host: checklist")
        for entry in owned:
            kind = text_field(entry, "kind")
            target = text_field(entry, "target")
            if kind not in OWN_KINDS:
                result.hard.append(f"{unit.stem}.owns kind '{kind}' must be one "
                                   f"of {sorted(OWN_KINDS)}")
                continue
            if not target:
                result.hard.append(f"{unit.stem}.owns has an entry with an empty target")
                continue
            if kind == "repo_file" and not (REPO_ROOT / target).exists():
                result.hard.append(f"{unit.stem}.owns repo_file '{target}' does not exist")
            claims.setdefault((kind, target), []).append(unit.stem)
    for (kind, target), owners in sorted(claims.items()):
        if len(owners) > 1:
            result.hard.append(f"owns target '{target}' ({kind}) is claimed by {len(owners)} "
                               f"units: {', '.join(sorted(owners))}")
    return result


# ------------------------------------------------------------- P5 references --


def check_docs(unit: Manifest) -> list[str]:
    out: list[str] = []
    runbook = unit.data.get("runbook")
    if runbook is None:
        if "no-runbook" not in unit.blocker_ids():
            out.append(f"{unit.stem}.runbook is null without a blockers entry id: no-runbook")
    elif isinstance(runbook, str):
        complaint = resolve_doc(runbook)
        if complaint:
            out.append(f"{unit.stem}.runbook {complaint}")
    for step in unit.list_of("manual_steps"):
        complaint = resolve_doc(text_field(step, "doc"))
        if complaint:
            out.append(f"{unit.stem}.manual_steps['{text_field(step, 'id')}'].doc {complaint}")
    return out


def collect_verify(unit: Manifest, claimed: dict[str, list[str]]) -> list[str]:
    """Check one unit's `verify` list and record what it claims."""
    scripts = strings(unit.data.get("verify"))
    if not scripts and "no-verify" not in unit.blocker_ids():
        return [f"{unit.stem}.verify is empty without a blockers entry id: no-verify — "
                f"eleven units have no verify script and the manifest is where that "
                f"stops being invisible"]
    out: list[str] = []
    for ref in scripts:
        name = Path(ref).name
        if ref != f"scripts/verify/{name}" or not name.startswith("check-"):
            out.append(f"{unit.stem}.verify '{ref}' must be a scripts/verify/check-*.sh path")
        elif not (REPO_ROOT / ref).is_file():
            out.append(f"{unit.stem}.verify '{ref}' does not exist")
        else:
            claimed.setdefault(name, []).append(unit.stem)
    return out


def prop_references(units: Sequence[Manifest], *, strict: bool) -> Findings:
    result = Findings()
    claimed: dict[str, list[str]] = {}
    for unit in units:
        result.hard.extend(collect_verify(unit, claimed))
        result.hard.extend(check_docs(unit))
    for name, owners in sorted(claimed.items()):
        if len(owners) > 1:
            result.hard.append(f"{name} is claimed by {len(owners)} units: "
                               f"{', '.join(sorted(owners))}")
        if name in UNCLAIMABLE:
            result.hard.append(f"{name} is unclaimable ({UNCLAIMABLE[name]}) but "
                               f"{owners[0]} claims it")
    # REVERSE closure. Advisory offline: it cannot pass until all 18 manifests
    # exist, and that is exactly what lets the catalog land incrementally.
    suffix = "" if strict else " (catalog is incomplete; --strict fails)"
    result.soft.extend(
        f"{path.name} is claimed by no unit{suffix}"
        for path in sorted(VERIFY_DIR.glob("check-*.sh"))
        if path.name not in claimed and path.name not in UNCLAIMABLE
    )
    return result


# ---------------------------------------------------------------- P6 secrets --


def env_example_keys() -> set[str]:
    if not SECRETS_EXAMPLE.is_file():
        return set()
    return set(ENV_KEY_RE.findall(SECRETS_EXAMPLE.read_text(encoding="utf-8")))


def keychain_vars() -> set[str]:
    if not KEYCHAIN_SCRIPT.is_file():
        return set()
    match = KEYCHAIN_VARS_RE.search(KEYCHAIN_SCRIPT.read_text(encoding="utf-8"))
    return set(match.group(1).split()) if match else set()


def check_secret(stem: str, key: str, store: str, env: set[str], keychain: set[str]) -> str:
    """Check one secret against the source of truth its `store` names."""
    if store == "vps" and key not in env:
        return (f"{stem}.secrets: {key} has store: vps but is absent from "
                f"config/env/secrets.env.example")
    if store == "mac_keychain" and key not in keychain:
        return (f"{stem}.secrets: {key} has store: mac_keychain but is absent from "
                f"keychain-secrets.sh's VARS")
    if store == "goose_secret_store" and (key in env or key in keychain):
        return (f"{stem}.secrets: {key} has store: goose_secret_store but appears in the global "
                f"roster — per-extension storage is what stops connector #1 reading connector #2")
    return ""


def prop_secrets(units: Sequence[Manifest], *, strict: bool) -> Findings:
    result = Findings()
    env = env_example_keys()
    keychain = keychain_vars()
    if not env:
        result.hard.append("config/env/secrets.env.example is missing or names no keys")
    if not keychain:
        result.hard.append("scripts/mac/keychain-secrets.sh is missing or has no VARS= roster")
    if result.hard:
        return result
    claimed: set[str] = set()
    for unit in units:
        for entry in unit.list_of("secrets"):
            key = text_field(entry, "key")
            store = text_field(entry, "store")
            claimed.add(key)
            complaint = check_secret(unit.stem, key, store, env, keychain)
            if complaint:
                result.hard.append(complaint)
    for key in sorted(env - claimed):
        result.soft.append(f"{key} is in secrets.env.example but no unit claims it"
                           f"{'' if strict else ' (catalog is incomplete; --strict fails)'}")
    return result


# -------------------------------------------------------------- P7 freshness --


def prop_freshness(units: Sequence[Manifest], *, strict: bool) -> Findings:
    result = Findings()
    today = dt.datetime.now(tz=dt.UTC).date()
    for unit in units:
        raw = unit.data.get("verified_on")
        if not isinstance(raw, str):
            continue  # P1 already reported the type.
        try:
            seen = dt.date.fromisoformat(raw)
        except ValueError:
            result.hard.append(f"{unit.stem}.verified_on '{raw}' is not an ISO YYYY-MM-DD date")
            continue
        age = (today - seen).days
        if age < 0:
            # No benign reason exists, so this arm is a FAIL in every mode.
            result.hard.append(f"{unit.stem}.verified_on {raw} is in the future")
        elif age > STALE_DAYS:
            result.soft.append(f"{unit.stem}.verified_on {raw} is {age} days old (>{STALE_DAYS})"
                               f"{'' if strict else ' — --strict fails on this'}")
    return result


# ------------------------------------------------------- P8 installer table --


def shell_words(text: str, name: str) -> list[str] | None:
    """Split the value of a `NAME="..."` bash assignment, or None if absent.

    Anchored at column 0 with MULTILINE so an occurrence inside a comment or a
    heredoc body cannot answer for the declaration. The value may span lines --
    OWNS_CODING_PACK does -- and a negated character class matches newlines, so
    no DOTALL is needed and no `"` can be swallowed.
    """
    match = re.search(rf'^{re.escape(name)}="([^"]*)"', text, re.MULTILINE)
    return None if match is None else match.group(1).split()


def shell_suffix(uid: str) -> str:
    """`base-toolchain` -> `BASE_TOOLCHAIN`, the REQUIRES_/OWNS_ variable half."""
    return uid.upper().replace("-", "_")


def mac_installer_units(units: Sequence[Manifest]) -> list[str]:
    """List the unit ids bootstrap-mac.sh claims to install TODAY, in catalog order."""
    out: list[str] = []
    for unit in units:
        block = unit.data.get("installer")
        if not isinstance(block, dict):
            continue
        if text_field(block, "script") != MAC_INSTALLER:
            continue
        if text_field(block, "status") == "present":
            out.append(unit.stem)
    return out


def owned_items(unit: Manifest) -> list[str]:
    """Spell this unit's `owns` entries the way the installer table spells them."""
    out: list[str] = []
    for entry in unit.list_of("owns"):
        prefix = OWN_KIND_PREFIX.get(text_field(entry, "kind"))
        target = text_field(entry, "target")
        if prefix and target:
            out.append(prefix + target)
    return out


def compare_sets(where: str, declared: Iterable[str], expected: Iterable[str]) -> list[str]:
    """Report what the bash table has that the manifests do not, and vice versa."""
    have = set(declared)
    want = set(expected)
    if have == want:
        return []
    missing = ", ".join(sorted(want - have)) or "-"
    extra = ", ".join(sorted(have - want)) or "-"
    return [f"{where} does not match the manifests (missing: {missing}; extra: {extra})"]


def check_table_order(ids: Sequence[str], requires: dict[str, list[str]]) -> list[str]:
    """P8(b): UNIT_IDS must be a topological order of the graph it spans.

    bootstrap-mac.sh calls its five units in UNIT_IDS order and filters that
    order rather than re-deriving one, so a unit listed before something it
    requires would install against a dependency that has not run yet.
    """
    seen: set[str] = set()
    out: list[str] = []
    for uid in ids:
        out.extend(
            f"UNIT_IDS lists {uid} before {dep}, which {uid} requires — "
            f"the call order is this list, filtered, so {dep} would never have run"
            for dep in requires.get(uid, [])
            if dep in ids and dep not in seen
        )
        seen.add(uid)
    return out


def check_skill_claims(units: Sequence[Manifest]) -> list[str]:
    """P8(e): every config/skills/<name>/ is claimed by exactly one unit.

    THE TOTALITY GATE. bootstrap-mac.sh installs skills from two hardcoded
    per-unit lists rather than from a glob, precisely so `--without opencode`
    cannot quietly install a coding-pack skill. The cost of that choice is that
    a thirteenth skill directory would be installed by nobody and noticed by
    nothing -- which is what this closes, and why it is a FAIL rather than the
    NOTE that `--offline` would turn a soft finding into.
    """
    if not SKILLS_DIR.is_dir():
        return [f"config/skills/ does not exist at {SKILLS_DIR}"]
    claims: dict[str, list[str]] = {}
    for unit in units:
        for entry in unit.list_of("owns"):
            if text_field(entry, "kind") != "repo_file":
                continue
            parts = Path(text_field(entry, "target")).parts
            if parts[:2] == ("config", "skills") and len(parts) == SKILL_PATH_PARTS:
                claims.setdefault(parts[2], []).append(unit.stem)
    out: list[str] = []
    for path in sorted(SKILLS_DIR.iterdir()):
        if not path.is_dir():
            continue
        owners = claims.get(path.name, [])
        if not owners:
            out.append(f"config/skills/{path.name}/ is claimed by no unit — nothing installs it")
        elif len(owners) > 1:
            out.append(f"config/skills/{path.name}/ is claimed by {len(owners)} units: "
                       f"{', '.join(sorted(owners))}")
    return out


def prop_installer_table(units: Sequence[Manifest]) -> Findings:
    result = Findings()
    result.hard.extend(check_skill_claims(units))
    if not BOOTSTRAP_MAC.is_file():
        result.hard.append(f"{MAC_INSTALLER} is missing — its unit table cannot be checked")
        return result
    text = BOOTSTRAP_MAC.read_text(encoding="utf-8")
    declared = shell_words(text, "UNIT_IDS")
    if declared is None:
        result.hard.append(f'{MAC_INSTALLER} declares no UNIT_IDS="..." — the flag surface '
                           f'resolves --with/--without/--only against that table')
        return result
    expected = mac_installer_units(units)
    result.hard.extend(compare_sets("UNIT_IDS", declared, expected))
    by_stem = {unit.stem: unit for unit in units}
    requires: dict[str, list[str]] = {
        uid: [dep for dep in strings(by_stem[uid].data.get("requires")) if dep in expected]
        for uid in expected
    }
    result.hard.extend(check_table_order(declared, requires))
    for uid in expected:
        if uid not in declared:
            continue  # compare_sets already named it.
        suffix = shell_suffix(uid)
        # `requires` is already intersected with the installer's own ids:
        # base-goose requires base-secrets, which has installer: null, so the
        # bash table elides it. That elision is asserted here, not assumed.
        for name, want in (
            (f"REQUIRES_{suffix}", requires[uid]),
            (f"OWNS_{suffix}", owned_items(by_stem[uid])),
        ):
            words = shell_words(text, name)
            if words is None:
                result.hard.append(f'{MAC_INSTALLER} declares no {name}="..." for unit {uid}')
                continue
            result.hard.extend(compare_sets(name, words, want))
    return result


# -------------------------------------------------------------------- driver --

PROPERTY_LABELS: Final[tuple[str, ...]] = (
    "P1 schema & identity: every manifest matches config/units/README.md",
    "P2 graph: every `requires` resolves and the graph is acyclic",
    "P3 installer: every installer.status matches the installers as they are",
    "P4 footprint: every (kind, target) is claimed by exactly one unit",
    "P5 references: verify scripts and runbooks resolve, and absences are recorded",
    "P6 secrets: every key matches the roster its `store` names",
    "P7 freshness: every verified_on parses and is not in the future",
    "P8 installer table: bootstrap-mac.sh's unit table matches the manifests",
)


def run_checks(*, strict: bool) -> list[str]:
    units, problems = load_manifests()
    lines = [f"FAIL  {p}" for p in problems]
    if not units:
        lines.append("FAIL  no readable manifests found in config/units/")
        return lines
    lines.append(f"NOTE  {len(units)} manifest(s): {', '.join(u.stem for u in units)}")
    results = (
        prop_schema(units),
        prop_graph(units),
        prop_installer(units),
        prop_footprint(units),
        prop_references(units, strict=strict),
        prop_secrets(units, strict=strict),
        prop_freshness(units, strict=strict),
        prop_installer_table(units),
    )
    for label, found in zip(PROPERTY_LABELS, results, strict=True):
        hard, soft = found.resolve(strict=strict)
        lines.extend(report(label, hard, soft))
    lines.extend(catalog_facts(units))
    return lines


def catalog_facts(units: Iterable[Manifest]) -> list[str]:
    """Restate the honest findings as lines a reader cannot miss.

    These are counts, not assertions: the point of the manifests is that eight
    units have no installer and eleven have no verify script, and a gate that
    only ever prints PASS would bury that.
    """
    ordered = list(units)
    no_installer = [u.stem for u in ordered if u.data.get("installer") is None]
    no_verify = [u.stem for u in ordered if not strings(u.data.get("verify"))]
    no_runbook = [u.stem for u in ordered if u.data.get("runbook") is None]
    return [
        f"NOTE  {len(no_installer)}/{len(ordered)} unit(s) have no installer: "
        f"{', '.join(no_installer) or '-'}",
        f"NOTE  {len(no_verify)}/{len(ordered)} unit(s) have no verify script: "
        f"{', '.join(no_verify) or '-'}",
        f"NOTE  {len(no_runbook)}/{len(ordered)} unit(s) have no runbook: "
        f"{', '.join(no_runbook) or '-'}",
    ]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="units_lint.py",
        description="Validate config/units/*.yaml. Speaks to nothing.",
    )
    parser.add_argument("--offline", action="store_true", help="default; kept for symmetry")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="promote the three reverse/staleness checks from NOTE to FAIL",
    )
    args = parser.parse_args(argv)
    lines = run_checks(strict=bool(args.strict))
    for line in lines:
        emit(line)
    return 1 if any(line.startswith("FAIL  ") for line in lines) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
