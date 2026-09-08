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
                         Installer LINE references must be in range and must
                         never be continued as a bare `:400` — a carve
                         renumbers them and only a written-out filename is
                         findable by the sweep that re-anchors them.
  P6 secrets             CONDITIONED ON `store`. A blanket "every key appears
                         in secrets.env.example" rule would force a false entry
                         for TODOIST_API_KEY, which routes through goose's
                         per-extension secret store precisely so connector #1
                         cannot read connector #2's credentials. Since #39 the
                         mac_keychain roster IS this field, so its arm cannot be
                         "the key is in keychain-secrets.sh" -- that would
                         compare the generator with itself. It closes over
                         docs/setup/10-accounts.md's Mac Keychain column
                         instead, and over the (key, store) rows themselves:
                         two rows for one pair must agree on `prompt` and
                         `generate`, or the roster's own text depends on which
                         manifest is read first.
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
                         AND IT RUNS THE SCRIPT. (a)-(d) read the declarations;
                         between them and any answer a user sees sits a `case`
                         dispatch, and one word changed inside it plans a
                         one-unit install with no uv while every declaration
                         still matches. So (f) executes `--dry-run --only <id>`
                         for every id and compares what it PRINTS to the
                         manifests, in a THROWAWAY $HOME it then asserts is
                         still empty. See dry_run_plan() for both halves.
                         (a) also rejects a REPEATED id: every other arm here
                         compares sets, and a doubled UNIT_IDS entry is the one
                         divergence that survives both the set comparisons and
                         (f) -- see prop_installer_table().

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
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Final

import yaml

if TYPE_CHECKING:
    from collections.abc import Iterable, Mapping, Sequence

# Derived from __file__, never from the cwd or `git rev-parse`: data-lint.yml's
# negative tests run a COPY of the tree out of $RUNNER_TEMP and must validate
# that copy. A git-derived root would walk back up to the real checkout and
# validate it instead, leaving both negative tests inert. Same rule
# goose_template.py and check-connectors.sh apply to their own roots.
REPO_ROOT: Final = Path(__file__).resolve().parents[2]
UNITS_DIR: Final = REPO_ROOT / "config" / "units"
VERIFY_DIR: Final = REPO_ROOT / "scripts" / "verify"
SECRETS_EXAMPLE: Final = REPO_ROOT / "config" / "env" / "secrets.env.example"
SKILLS_DIR: Final = REPO_ROOT / "config" / "skills"
BOOTSTRAP_MAC: Final = REPO_ROOT / "scripts" / "mac" / "bootstrap-mac.sh"
# The credential checklist whose "Mac Keychain" column P6 closes over. It is a
# DOC, deliberately: after #39 the Keychain roster is the manifests, so the only
# remaining cross-file statement about it that a human wrote by hand is this
# table -- and the table sent the reader to store TODOIST_API_KEY in a place the
# validator forbids.
ACCOUNTS_DOC: Final = REPO_ROOT / "docs" / "setup" / "10-accounts.md"
ACCOUNTS_DOC_REL: Final = "docs/setup/10-accounts.md"
MAC_COLUMN: Final = "Mac Keychain"
VAR_COLUMN: Final = "Variable / form"

MANIFEST_VERSION: Final = 1
SUMMARY_MAX: Final = 120
PROMPT_MAX: Final = 200
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

# The same three kinds as bootstrap-mac.sh's --dry-run SPELLS them, read back
# for P8(f). Two spellings of one mapping is the price of comparing what the
# installer prints against what the manifests say instead of against itself.
DRY_RUN_KIND_PREFIX: Final[dict[str, str]] = {
    "brew formula": "brew:",
    "brew cask": "cask:",
    "file": "home:",
}
PLAN_HEADER_RE: Final = re.compile(r"^==> plan \((\d+) units, in dependency order\):$")
PLAN_ID_RE: Final = re.compile(r"^  [a-z0-9-]+$")
OWNS_HEADER: Final = "==> would install:"
OWNS_LINE_RE: Final = re.compile(r"^  (brew formula|brew cask|file) +(\S.*)$")
# A bound, not a tuning knob. The closure and cascade loops in bootstrap-mac.sh
# are `while [ $PASS -lt 8 ]`, so --dry-run is milliseconds; anything near this
# is a hang, and a lint that hangs a CI job is worse than one that fails it.
DRY_RUN_TIMEOUT: Final = 60
# How many entries of a polluted throwaway $HOME to name before summarising. The
# finding is "it wrote at all"; a hundred-line dump of a half-finished install
# would bury every other finding in the run.
HOME_INTRUDERS_SHOWN: Final = 5

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
    # `prompt` and `generate` arrived with #39. They are what `pai secrets`
    # projects and what keychain-secrets.sh renders, so a row without them is a
    # key nothing can ask a human for.
    "secrets": frozenset({"key", "store", "secret", "optional", "prompt", "generate"}),
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
# `generate` is EXECUTED by keychain-secrets.sh, so the schema is a whitelist of
# one shape rather than a free command string: the script reads the byte count
# out of it and runs openssl itself, and never evaluates the manifest's text.
GENERATE_RE: Final = re.compile(r"^openssl rand -hex ([1-9][0-9]{0,2})$")
# A variable name inside backticks, which is how the credential checklist writes
# every one of them.
DOC_KEY_RE: Final = re.compile(r"`([A-Z][A-Z0-9_]{2,})`")


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


def check_secret_prompt(stem: str, key_name: str, entry: dict[str, object]) -> list[str]:
    """Check the two fields the prompt is rendered from.

    `prompt` is THE hint a human sees at keychain-secrets.sh's hidden prompt.
    Before #39 the hints lived in a `case` in that script with a `*) echo ""`
    arm, so TELEGRAM_BOT_TOKEN and NTFY_EMAIL prompted with an empty
    parenthetical -- a naked variable name for a feature nobody had been told to
    create. Emptiness is therefore a FAIL, and so is a single space: `( )`
    renders identically to a reader and slips past any "is it empty" grep.

    The tab rule is not cosmetic either: `pai secrets` emits one TAB-separated
    row per key, so a tab inside a prompt silently shifts every later column.
    """
    out: list[str] = []
    prompt = entry.get("prompt")
    where = f"{stem}.secrets['{key_name}']"
    if not isinstance(prompt, str) or not prompt.strip():
        out.append(f"{where}.prompt must be a non-empty string — it is what "
                   f"keychain-secrets.sh shows at the hidden prompt, and an empty one is "
                   f"the naked '( )' this field exists to make impossible")
        prompt = ""
    elif "\n" in prompt or "\t" in prompt or len(prompt) > PROMPT_MAX:
        out.append(f"{where}.prompt must be a single line of at most {PROMPT_MAX} chars "
                   f"with no tab (the roster is TAB-separated)")
    generate = entry.get("generate")
    if generate is None:
        return out
    if not isinstance(generate, str) or not GENERATE_RE.match(generate):
        out.append(f"{where}.generate must be null or an `openssl rand -hex N` command — "
                   f"keychain-secrets.sh reads N out of it and runs openssl itself, so no "
                   f"other shape is executable")
    elif generate not in prompt:
        # B5's rule, and the reason it is not "generate ⇒ no prompt": the same
        # key is generated on one host and TRANSCRIBED on the other, so the
        # prompt has to stay and has to say which of the two this row is.
        out.append(f"{where}.generate is '{generate}' but the prompt does not offer it "
                   f"verbatim — a mintable secret whose prompt does not say so is prompted "
                   f"for by hand forever")
    return out


def check_secret_fields(unit: Manifest) -> list[str]:
    """Check each secret's key spelling, store enum, flags, prompt and generate."""
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
        out.extend(check_secret_prompt(unit.stem, key_name, entry))
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


# THE INSTALLER LINE REFERENCES. Manifests cite the installers by line
# (`deploy-vps.sh:634`), and a carve renumbers the whole file — so every one of
# those citations has to be re-anchored by hand, and the sweep that finds them
# is `grep -rn 'deploy-vps.sh:[0-9]'`. A CONTINUATION written as a bare `:400`
# is invisible to that sweep, which is not a hypothetical: #37 and #41 both
# re-anchored every prefixed reference and left the bare ones pointing at
# unrelated code (`:400`, once the migration block moved, became a comment
# about stopping goose units). Both halves are checked here:
#
#   * a bare `:N`/`:N-M` whose nearest preceding filename is an installer must
#     be written out in full, and
#   * an explicit `<installer>:N`/`:N-M` must be IN RANGE for that file.
#
# Range is the weaker half by a distance — it cannot tell a right line from a
# wrong one — so it is the ban on bare continuations that does the work.
#
# SCOPED TO THE TWO INSTALLERS deliberately. Manifests carry bare continuations
# for README.md budget rows, notify.sh, opencode.json and a dozen others, and
# those files do not get carved; a repo-wide ban would be 27 more edits for a
# risk that has never fired.
#
# AND NEAREST-PRECEDING-FILENAME IS THE WHOLE ATTRIBUTION RULE, which means one
# shape gets through: a bare ref that follows some OTHER filename, even though
# the reference it continues is an installer's. Measured against #41's own
# mistakes — of the eleven bare installer continuations this rule was written
# for, it flags ten; brain.yaml's `the script says so itself at :242-244` is the
# eleventh, and it is missed because `secrets.yaml` and `config.yaml` appear
# between it and the `deploy-vps.sh:390-516` it continues. The obvious widening
# — flag a bare ref whenever an installer appears anywhere earlier in the same
# paragraph — was tried and rejected: on this tree it fires on eight refs, of
# which exactly one is that bug and seven are correct references to cli.sh,
# check-code-agents.sh, opencode.json, secrets.env.example and security.md. Ten
# of eleven with no false positives beats eleven of eleven with seven.
_FILENAME: Final = (
    r"[\w@][\w./@-]*\."
    r"(?:sh|py|ya?ml|md|json|txt|service|timer|tftpl|example|toml|cfg|conf|lock)"
)
# The lookbehind is what keeps URLs (`https://brain.ts.net:3284`), clock times
# and `§6-10` out of it: a bare reference's colon follows whitespace or an
# opening bracket, never a word, dot, slash or hyphen.
LINE_REF_RE: Final = re.compile(
    rf"(?P<file>{_FILENAME})(?P<explicit>:\d+(?:-\d+)?)?"
    r"|(?P<bare>(?<![\w./#-]):\d+(?:-\d+)?)",
)


def installer_line_counts() -> dict[str, int]:
    """Line count per installer BASENAME, for the range half of the check."""
    counts: dict[str, int] = {}
    for rel in INSTALLER_SCRIPTS:
        path = REPO_ROOT / rel
        if path.is_file():
            counts[Path(rel).name] = len(path.read_text(encoding="utf-8").splitlines())
    return counts


def check_line_refs(unit: Manifest, counts: dict[str, int]) -> list[str]:
    """Bare `:NNN` continuations of an installer reference, and out-of-range refs."""
    text = unit.path.read_text(encoding="utf-8")
    installers = {Path(rel).name for rel in INSTALLER_SCRIPTS}
    out: list[str] = []
    context = ""
    for match in LINE_REF_RE.finditer(text):
        line_no = text.count("\n", 0, match.start()) + 1
        name = match.group("file")
        if name:
            context = Path(name).name
            span = match.group("explicit")
            if span and context in counts:
                first, _, last = span[1:].partition("-")
                lo, hi = int(first), int(last or first)
                if lo < 1 or hi < lo or hi > counts[context]:
                    out.append(f"{unit.stem}.yaml:{line_no} cites {context}{span}, which is "
                               f"out of range — {context} has {counts[context]} lines")
            continue
        if context in installers:
            out.append(f"{unit.stem}.yaml:{line_no} continues a {context} reference as a bare "
                       f"'{match.group('bare')}' — write it as {context}{match.group('bare')}, "
                       f"or a carve will renumber it and no sweep will find it")
    return out


def collect_verify(unit: Manifest, claimed: dict[str, list[str]]) -> list[str]:
    """Check one unit's `verify` list and record what it claims.

    AN ENTRY IS A PATH PLUS OPTIONAL ARGUMENTS. `pai verify` derives its whole
    roster from this field, and check-security.sh's two modes are two different
    checks: bare, it wants a public IP and refuses without one; `--local` is the
    host-posture pass brain.yaml actually claims. With a bare path as the only
    legal shape, brain's second verify script could only ever be run by hand.

    The arguments are NOT validated. This gate cannot know a check's option
    vocabulary without keeping a copy of it, and the script itself already
    refuses an unknown flag with exit 2 — the copy is the thing worth avoiding.
    What IS enforced is the head: one repo-relative scripts/verify/check-*.sh
    that exists, so a typo cannot become a silently absent check.
    """
    scripts = strings(unit.data.get("verify"))
    if not scripts and "no-verify" not in unit.blocker_ids():
        return [f"{unit.stem}.verify is empty without a blockers entry id: no-verify — "
                f"eleven units have no verify script and the manifest is where that "
                f"stops being invisible"]
    out: list[str] = []
    for ref in scripts:
        # split(), not split(" "): a double space between path and flag would
        # otherwise make head an empty string and the message unreadable.
        head = ref.split()[0] if ref.split() else ""
        name = Path(head).name
        if head != f"scripts/verify/{name}" or not name.startswith("check-"):
            out.append(f"{unit.stem}.verify '{ref}' must start with a "
                       f"scripts/verify/check-*.sh path (arguments may follow)")
        elif not (REPO_ROOT / head).is_file():
            out.append(f"{unit.stem}.verify '{ref}' does not exist")
        else:
            claimed.setdefault(name, []).append(unit.stem)
    return out


def prop_references(units: Sequence[Manifest], *, strict: bool) -> Findings:
    result = Findings()
    claimed: dict[str, list[str]] = {}
    counts = installer_line_counts()
    for unit in units:
        result.hard.extend(collect_verify(unit, claimed))
        result.hard.extend(check_docs(unit))
        result.hard.extend(check_line_refs(unit, counts))
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


def table_cells(line: str) -> list[str]:
    """Split one markdown table row into trimmed cells, or [] if it is not one."""
    stripped = line.strip()
    if not stripped.startswith("|") or not stripped.endswith("|"):
        return []
    return [cell.strip() for cell in stripped[1:-1].split("|")]


def credential_table(lines: Sequence[str]) -> tuple[list[str], int]:
    """Find the credential checklist: its header cells, and the row after it."""
    for index, line in enumerate(lines):
        cells = table_cells(line)
        if MAC_COLUMN in cells and VAR_COLUMN in cells:
            return (cells, index + 1)
    return ([], 0)


def read_mac_cell(cells: list[str], var_at: int, mac_at: int) -> tuple[dict[str, bool], str]:
    """Read one credential row: the keys it names, and whether they are Keychain'd."""
    if len(cells) <= max(var_at, mac_at):
        return ({}, f"{ACCOUNTS_DOC_REL}: credential row '{cells[0]}' has only "
                    f"{len(cells)} cells")
    verdict = cells[mac_at].lower()
    # "yes (transcribe)" and "yes (Desktop connects with it)" both exist and both
    # mean yes; the cell is prose with a verdict at the front.
    if not verdict.startswith(("yes", "no")):
        return ({}, f"{ACCOUNTS_DOC_REL}: the '{MAC_COLUMN}' cell for '{cells[0]}' reads "
                    f"'{cells[mac_at]}' — it must start with yes or no")
    stored = verdict.startswith("yes")
    return (dict.fromkeys(DOC_KEY_RE.findall(cells[var_at]), stored), "")


def doc_mac_column() -> tuple[dict[str, bool], list[str]]:
    """Read the Mac Keychain verdict per variable out of the credential checklist.

    Returns ({KEY: stored_in_the_keychain}, complaints). An EMPTY mapping with no
    complaint is impossible by construction: a table that cannot be found, or is
    found and yields no rows, is itself a complaint. That guard is the whole
    difference between a closure and a pair of empty sets agreeing with each
    other.
    """
    if not ACCOUNTS_DOC.is_file():
        return ({}, [f"{ACCOUNTS_DOC_REL} does not exist, so the Mac Keychain column "
                     f"cannot be checked against the manifests"])
    lines = ACCOUNTS_DOC.read_text(encoding="utf-8").splitlines()
    header, start = credential_table(lines)
    if not header:
        return ({}, [f"{ACCOUNTS_DOC_REL} has no table with both a '{VAR_COLUMN}' and a "
                     f"'{MAC_COLUMN}' column — P6's doc closure is inert without it"])
    var_at, mac_at = header.index(VAR_COLUMN), header.index(MAC_COLUMN)
    marks: dict[str, bool] = {}
    problems: list[str] = []
    for line in lines[start:]:
        cells = table_cells(line)
        if not cells:
            break  # The table ended; everything after it is prose.
        if set("".join(cells)) <= set("-: "):
            continue  # The |---|---| separator row.
        row, complaint = read_mac_cell(cells, var_at, mac_at)
        if complaint:
            problems.append(complaint)
            continue
        for key, stored in row.items():
            marks[key] = marks.get(key, False) or stored
    if not marks:
        problems.append(f"{ACCOUNTS_DOC_REL}: found the credential table but no `VARIABLE` "
                        f"rows in it — P6's doc closure would pass against anything")
    return (marks, problems)


def check_secret(stem: str, key: str, store: str, env: set[str], mac: set[str]) -> str:
    """Check one secret against the source of truth its `store` names."""
    if store == "vps" and key not in env:
        return (f"{stem}.secrets: {key} has store: vps but is absent from "
                f"config/env/secrets.env.example")
    if store == "goose_secret_store" and (key in env or key in mac):
        return (f"{stem}.secrets: {key} has store: goose_secret_store but appears in the global "
                f"roster — per-extension storage is what stops connector #1 reading connector #2")
    return ""


def check_row_agreement(units: Sequence[Manifest]) -> list[str]:
    """One (key, store) pair, one prompt and one `generate`, however many rows.

    Duplicate rows are deliberate and load-bearing -- base-secrets and brain both
    claim GOOSE_SERVER__SECRET_KEY, ntfy-alerts and base-secrets both claim
    NTFY_TOPIC -- but `pai secrets` de-duplicates by key, so two rows that
    disagree make the roster's text depend on which manifest sorts first.
    """
    seen: dict[tuple[str, str], tuple[str, str, object]] = {}
    out: list[str] = []
    for unit in units:
        for entry in unit.list_of("secrets"):
            pair = (text_field(entry, "key"), text_field(entry, "store"))
            here = (text_field(entry, "prompt"), entry.get("generate"))
            first = seen.get(pair)
            if first is None:
                seen[pair] = (unit.stem, *here)
                continue
            owner, prompt, generate = first
            if (prompt, generate) != here:
                out.append(f"{unit.stem}.secrets: {pair[0]} (store: {pair[1]}) has a different "
                           f"prompt/generate than {owner}'s row for the same pair — one key in "
                           f"one store is asked for with one sentence")
    return out


def prop_secrets(units: Sequence[Manifest], *, strict: bool) -> Findings:
    result = Findings()
    env = env_example_keys()
    if not env:
        result.hard.append("config/env/secrets.env.example is missing or names no keys")
        return result
    claimed: set[str] = set()
    mac = {
        text_field(entry, "key")
        for unit in units
        for entry in unit.list_of("secrets")
        if text_field(entry, "store") == "mac_keychain"
    }
    for unit in units:
        for entry in unit.list_of("secrets"):
            key = text_field(entry, "key")
            claimed.add(key)
            complaint = check_secret(unit.stem, key, text_field(entry, "store"), env, mac)
            if complaint:
                result.hard.append(complaint)
    result.hard.extend(check_row_agreement(units))
    # THE MAC ARM, and it deliberately does not look at keychain-secrets.sh.
    # That script's roster IS this field now (`pai secrets --host mac`), so any
    # manifest-versus-generator rule would be true by construction. What is left
    # that a human wrote by hand is the credential checklist's column, and it was
    # wrong in exactly the way this closes: it told the reader to put
    # TODOIST_API_KEY in the Keychain, which `store: goose_secret_store` forbids.
    marks, problems = doc_mac_column()
    result.hard.extend(problems)
    if marks:
        doc_yes = {key for key, stored in marks.items() if stored}
        result.hard.extend(
            f"{key} has store: mac_keychain in the manifests but {ACCOUNTS_DOC_REL}'s "
            f"credential checklist does not say yes for it — the roster a human reads and the "
            f"roster keychain-secrets.sh prompts from must be the same roster"
            for key in sorted(mac - doc_yes)
        )
        result.hard.extend(
            f"{ACCOUNTS_DOC_REL}'s credential checklist says {key} lives in the Mac Keychain, "
            f"but no unit declares store: mac_keychain for it — keychain-secrets.sh will never "
            f"prompt for it"
            for key in sorted(doc_yes - mac)
        )
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


def dry_run_plan(uid: str) -> tuple[list[str], list[str], list[str]]:
    """RUN `bootstrap-mac.sh --dry-run --only <uid>`; return (plan, owns, problems).

    P8(f) EXECUTES the installer rather than reading it, and that is the whole
    point of it. (a)-(d) above are regexes anchored on `^NAME="..."`, so they
    see the string LITERALS and nothing else; the `case` dispatch that maps an
    id to one of those literals -- chosen over `${!ref}` because an indirectly
    read global is SC2034 to ShellCheck, and a warning is a red gate here -- sits
    between the literals and every user-visible answer, and no amount of reading
    the declarations covers it. Measured: rewriting one arm to `printf '%s' ""`
    makes `--only base-goose` plan a one-unit install with no uv, and the
    declarations still match the manifests perfectly.

    WHY RUNNING IT IS SAFE, and why that argument is no longer relied on alone.
    `--dry-run` answers from pure computation over the table and exits BEFORE
    the platform guard, the Homebrew guard and every write; that is true today,
    and test-base-install.sh's H2/H2b/H3 assert it as "a fresh $HOME stays
    empty, a populated one stays byte-identical, and no `uname` is ever asked".
    But H2/H2b/H3 are a DIFFERENT harness in a DIFFERENT workflow, and this file
    is a LINTER -- run casually, locally, on somebody's actual Mac. On a tree
    where that bare `exit 0` has been broken, check-units.sh inheriting the real
    $HOME would `brew install` and write into ~/.config, five times over,
    bounded only by DRY_RUN_TIMEOUT. A safety property one workflow proves is
    not a safety property another workflow may assume.

    So THE CHILD GETS A THROWAWAY $HOME, and check_child_home() asserts
    afterwards that it is still empty. Defence in depth: the containment no
    longer depends on the installer being correct, only on it being run here.

    BEHAVIOURALLY FREE, and measured rather than assumed: all five
    `--dry-run --only <id>` transcripts are byte-identical (stdout, stderr and
    exit status) under the real $HOME and under a throwaway one, which is empty
    afterwards in every case. The reason is that nothing before the `exit 0`
    reads $HOME at all -- the OWNS_* strings carry a LITERAL `~`, which bash
    does not expand inside the double-quoted assignment and which reaches the
    plan as a printf argument, so `~/.config/goose/config.yaml` is printed, not
    resolved. The first `"$HOME/..."` in bootstrap-mac.sh is inside a unit body.

    PAI_EXEC is scrubbed from the child's environment: it is the test seam, and
    a developer with it exported would otherwise hit the containment gate's
    exit 2 and see this property fail for a reason that is not about the table.
    """
    env = {k: v for k, v in os.environ.items() if k != "PAI_EXEC"}
    with tempfile.TemporaryDirectory(prefix="units-lint-dry-run-home-") as sandbox:
        env["HOME"] = sandbox
        try:
            proc = subprocess.run(  # noqa: S603 - fixed argv, no shell, path derived from __file__
                [str(BOOTSTRAP_MAC), "--dry-run", "--only", uid],
                capture_output=True, text=True, timeout=DRY_RUN_TIMEOUT, env=env, check=False,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            return ([], [], [f"{MAC_INSTALLER} --dry-run --only {uid} could not be run: {exc}"])
        # BEFORE the exit-status check, deliberately. "It wrote into $HOME" is a
        # worse finding than "it exited 3", and a broken dry-run path that
        # writes and then fails would otherwise be reported only as the failure.
        #
        # PER UNIT, not once for the run, and that is the opposite call from the
        # os.access() check in check_dispatch(). That one is a fact about the
        # FILE, so five copies of it are five copies of one sentence. This is a
        # fact about one CHILD PROCESS: each --only walks its own plan under its
        # own $HOME, so "which invocation wrote" is the reproducer, and
        # collapsing them would throw away the only thing that narrows it.
        if breach := check_child_home(uid, env, sandbox):
            return ([], [], breach)
        if proc.returncode != 0:
            # stderr's FIRST line only. On a non-zero exit stdout still holds the
            # whole plan, and echoing 25 lines of it buries the complaint that
            # actually explains the exit -- "unknown unit id", say, or the
            # containment gate.
            why = next((line for line in proc.stderr.splitlines() if line.strip()), "(no stderr)")
            return ([], [], [f"{MAC_INSTALLER} --dry-run --only {uid} exited {proc.returncode}, "
                             f"not 0: {why}"])
        return parse_dry_run(uid, proc.stdout)


def check_child_home(uid: str, env: Mapping[str, str], sandbox: str) -> list[str]:
    """Assert the --dry-run child was contained: throwaway $HOME, nothing in it.

    THE FIRST ARM IS WRITTEN AGAINST `env`, the mapping the child was actually
    handed, and not against `sandbox` alone -- that is the whole point of it.
    Delete `env["HOME"] = sandbox` in dry_run_plan() and this SAYS SO, where an
    emptiness check phrased only over `sandbox` would go on inspecting a
    directory no process ever had and pass forever. An assertion whose subject
    is not the thing under test is the inert kind, and inert containment reads
    exactly like real containment right up until the day it matters.

    Negative control: data-lint.yml, "a --dry-run that writes into $HOME must
    fail". It breaks the dry-run path so it writes a named directory, and then
    checks BOTH that this reports it AND that the runner's own $HOME did not
    gain that directory -- so the control fails if the sandbox stops being used,
    whichever of the two lines above someone removed.
    """
    handed = env.get("HOME")
    if handed != sandbox:
        return [f"P8(f) ran {MAC_INSTALLER} --dry-run --only {uid} with $HOME={handed!r} rather "
                f"than the throwaway {sandbox!r} — this is a linter, and it must not point an "
                f"installer at a real home directory"]
    intruders = sorted(p.name for p in Path(sandbox).iterdir())
    if not intruders:
        return []
    shown = ", ".join(intruders[:HOME_INTRUDERS_SHOWN])
    rest = len(intruders) - HOME_INTRUDERS_SHOWN
    return [f"{MAC_INSTALLER} --dry-run --only {uid} wrote {len(intruders)} entr"
            f"{'y' if len(intruders) == 1 else 'ies'} into its $HOME ({shown}"
            f"{f', +{rest} more' if rest > 0 else ''}) — --dry-run must exit before every write, "
            f"so on a real $HOME this run would have installed something"]


def parse_dry_run(uid: str, out: str) -> tuple[list[str], list[str], list[str]]:
    """Split a --dry-run transcript into (plan ids, owns items, problems).

    STRICT, and fail-closed on every shape it does not recognise: a parser that
    shrugged at an unexpected line would turn a garbled plan into an empty list,
    and an empty list compares equal to an empty expectation. The `owns` items
    come back in the `brew:`/`cask:`/`home:` spelling owned_items() uses, so the
    two sides of the comparison are built from different sources.

    WHITESPACE-TOLERANT ON THE COLUMN, deliberately: the exact rendering is
    pinned bytewise by test-base-install.sh's H1 and H4 goldens. What this owns
    is the SEMANTICS -- which units, which kinds, which targets, in which order.
    """
    lines = out.splitlines()
    if not lines or (head := PLAN_HEADER_RE.match(lines[0])) is None:
        return ([], [], [f"{MAC_INSTALLER} --dry-run --only {uid} did not open with a plan "
                         f"header: {(lines[0] if lines else '')!r}"])
    count = int(head.group(1))
    plan = [line[2:] for line in lines[1 : 1 + count]]
    rest = lines[1 + count :]
    if len(plan) != count or any(not PLAN_ID_RE.match(line) for line in lines[1 : 1 + count]):
        return ([], [], [f"{MAC_INSTALLER} --dry-run --only {uid} announced {count} unit(s) but "
                         f"did not print {count} indented unit id(s)"])
    if not rest or rest[0] != OWNS_HEADER:
        return ([], [], [f"{MAC_INSTALLER} --dry-run --only {uid} did not print "
                         f"{OWNS_HEADER!r} after its plan"])
    owns: list[str] = []
    for line in rest[1:]:
        match = OWNS_LINE_RE.match(line)
        if match is None:
            return ([], [], [f"{MAC_INSTALLER} --dry-run --only {uid} printed a 'would install' "
                             f"line in no recognised kind: {line!r}"])
        owns.append(DRY_RUN_KIND_PREFIX[match.group(1)] + match.group(2))
    return (plan, owns, [])


def requires_closure(uid: str, requires: dict[str, list[str]]) -> set[str]:
    """Return the units `--only <uid>` must install, per the MANIFESTS.

    Computed here from `requires` rather than read out of the installer, which
    is what makes the comparison in check_dispatch() a comparison of two
    independent things instead of the script agreeing with itself.
    """
    seen = {uid}
    stack = [uid]
    while stack:
        for dep in requires.get(stack.pop(), []):
            if dep not in seen:
                seen.add(dep)
                stack.append(dep)
    return seen


def check_dispatch(
    by_stem: dict[str, Manifest], expected: Sequence[str], requires: dict[str, list[str]],
) -> list[str]:
    """P8(f): what `--dry-run --only <id>` actually PRINTS, for every id."""
    # ONCE, not once per unit: P3 already reports an unexecutable installer per
    # manifest that names it, and five more copies of the same sentence here
    # buries every other finding in the run.
    if not os.access(BOOTSTRAP_MAC, os.X_OK):
        return [f"{MAC_INSTALLER} is not executable — P8(f) cannot run its --dry-run"]
    out: list[str] = []
    for uid in expected:
        plan, owns, problems = dry_run_plan(uid)
        if problems:
            out.extend(problems)
            continue
        want_plan = requires_closure(uid, requires)
        if set(plan) != want_plan:
            missing = ", ".join(sorted(want_plan - set(plan))) or "-"
            extra = ", ".join(sorted(set(plan) - want_plan)) or "-"
            out.append(f"--only {uid} plans {len(plan)} unit(s), not the manifests' requires "
                       f"closure (missing: {missing}; extra: {extra}) — requires_of()'s case "
                       f"dispatch, not REQUIRES_*, is what resolves that")
            continue
        seen: set[str] = set()
        for pid in plan:
            out.extend(
                f"--only {uid} plans {pid} before {dep}, which {pid} requires — the units run "
                f"in the order this plan prints them"
                for dep in requires.get(pid, [])
                if dep in plan and dep not in seen
            )
            seen.add(pid)
        want_owns = [item for pid in plan for item in owned_items(by_stem[pid])]
        if owns != want_owns:
            # The FIRST divergence, not both lists: a 25-item dump buries the
            # one line that moved, and the printer emits them in plan order, so
            # the first mismatch is where the wrong OWNS_* was reached. zip's
            # strict=False is load bearing -- the lists differ in LENGTH here as
            # often as in content (a dropped brew formula is the mutation this
            # exists for), and raising would replace a diagnostic with a crash.
            at = next((i for i, (a, b) in enumerate(zip(owns, want_owns, strict=False)) if a != b),
                      min(len(owns), len(want_owns)))
            got = owns[at] if at < len(owns) else "(end of list)"
            want = want_owns[at] if at < len(want_owns) else "(end of list)"
            out.append(f"--only {uid} would install {len(owns)} item(s), not the {len(want_owns)} "
                       f"its plan's manifests own; first divergence at item {at + 1}: printed "
                       f"{got}, manifests say {want} — owns_of()'s case dispatch, not OWNS_*, "
                       f"is what prints that")
    return out


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
    # The declaration findings, kept apart from the skill-closure ones above:
    # P8(f) below is only meaningful against a table that already matches, and
    # an unclaimed config/skills/ directory says nothing about that table.
    table: list[str] = []
    table.extend(compare_sets("UNIT_IDS", declared, expected))
    # compare_sets is a SET comparison, so {a, b, a} == {a, b} and a repeated id
    # walks straight through it. Not academic: UNIT_IDS is the list the plan loop
    # filters, so doubling `coding-pack` makes the default --dry-run announce
    # "6 units", print coding-pack twice, and repeat its whole 13-line `would
    # install` block -- 47 lines where the golden is 33. (f) below cannot see it
    # either: it compares set(plan) to the closure, and builds the expected owns
    # list by walking the plan it was handed, so the duplication cancels out on
    # both sides of that comparison. Measured on this tree before this check
    # existed: check-units.sh --offline AND --strict both at "8 passed, 0 failed"
    # against that 47-line dry run. The only gate that caught it was
    # test-base-install.sh's H1 golden, which runs in a different workflow, so
    # P8's own "fails on any divergence" was overstated until this arm existed.
    table.extend(
        f"UNIT_IDS lists {uid} {declared.count(uid)} times — the plan loop filters this "
        f"list rather than re-deriving one, so a repeated id is announced and printed twice"
        for uid in sorted(set(declared))
        if declared.count(uid) > 1
    )
    by_stem = {unit.stem: unit for unit in units}
    requires: dict[str, list[str]] = {
        uid: [dep for dep in strings(by_stem[uid].data.get("requires")) if dep in expected]
        for uid in expected
    }
    table.extend(check_table_order(declared, requires))
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
                table.append(f'{MAC_INSTALLER} declares no {name}="..." for unit {uid}')
                continue
            table.extend(compare_sets(name, words, want))
    result.hard.extend(table)
    # P8(f). Everything above this line READS the file; this RUNS it. See
    # dry_run_plan() for why the declarations matching is not the same claim as
    # the installer resolving them, and why --dry-run is the safe way to ask.
    # Skipped when the declarations already diverge: --only against a table that
    # does not match the manifests would restate that divergence a second time,
    # in a message about the dispatch, which is not where the fault is.
    if not table:
        result.hard.extend(check_dispatch(by_stem, expected, requires))
    return result


# -------------------------------------------------------------------- driver --

PROPERTY_LABELS: Final[tuple[str, ...]] = (
    "P1 schema & identity: every manifest matches config/units/README.md",
    "P2 graph: every `requires` resolves and the graph is acyclic",
    "P3 installer: every installer.status matches the installers as they are",
    "P4 footprint: every (kind, target) is claimed by exactly one unit",
    "P5 references: verify scripts, runbooks and installer line refs resolve",
    "P6 secrets: every key matches the roster its `store` names, and the Mac column agrees",
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
        description="Validate config/units/*.yaml. Speaks to no network.",
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
