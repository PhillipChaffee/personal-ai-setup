#!/usr/bin/env python3
"""uninstall.py — `pai remove <id>`: why a unit cannot be removed, and what is kept.

THIS FILE DELETES NOTHING. Not behind a flag, not for one unit, not ever — the
module imports no `shutil`, calls no `unlink`/`rmtree`/`rmdir`, and opens no
file for writing, and scripts/verify/test-pai.sh asserts that LEXICALLY as well
as by hashing a fixture before and after. `pai remove` is a READER over the
`uninstall: {supported, reason}` block that all eighteen manifests already
carry, and over their `owns:` lists. It prints, it refuses, it exits 2.

WHY THE REMOVING HALF IS NOT HERE, since "a remove that removes nothing" is a
claim that has to be justified rather than apologised for:

  1. NOTHING CAN TELL WHAT THE INSTALLER WROTE FROM WHAT YOU WROTE. Every
     install in this repo is no-clobber — `copy_no_clobber` and `install_skill`
     in scripts/mac/bootstrap-mac.sh both KEEP a pre-existing destination and
     say "kept existing". So `~/.agents/skills/ship` may be the repo's copy or
     the one you wrote before you ever ran the bootstrap, and the installer
     recorded no difference between those two histories. Driving `rm` off
     `owns:` deletes both. The only sound predicate is content equality against
     the repo source, and that is the removing half's problem to solve.
  2. REMOVAL IS WORSE THAN ABSENCE UNTIL `pai doctor` LEARNS "DELIBERATELY
     ABSENT". check_skills (scripts/pai/doctor.py) FAILs when any directory
     under config/skills/ is missing from ~/.agents/skills, and --fix
     explicitly does not repair it (OUT_OF_SCOPE: "--fix touches goose's
     extension config and nothing else"). So removing the eleven coding-pack
     skills today would leave `pai doctor` printing
     `FAIL 11 of 12 shipped skills are not installed` forever, with no --fix
     path and a remedy line telling you to re-run the bootstrap.
  3. AN ACP EXTENSION REMOVED HERE IS RE-ADDED BY THE NEXT `doctor --fix`,
     which plans "absent from the live config -> add it" for every key the
     repo's templates declare. A removal a routine repair undoes is not a
     removal.

So AC #1 (`remove` then `verify <id>` fails) and AC #6 (install -> verify ->
remove -> verify end to end) of issue #43 are UNMET and say so out loud, here
and in the PR that shipped this file. AC #2, #3 and #4 are met in full, for all
eighteen units, today: every one of them refuses, with its own written reason,
and names every target it would keep regardless.

THE CLASSIFICATION IS THE FEATURE. Of the eighteen units, ZERO are cleanly
reversible, two (coding-pack, opencode) are partially reversible with a named
residue, and sixteen are unsupported with a concrete reason. Every one of those
reasons is in the manifest, not here — this file has no vocabulary of its own to
drift from the data.

    pai remove <id>      refuse, with the manifest's reason. Writes nothing.
    pai remove --help    the above, plus the two doctor facts.

Exit: 0 for --help, 2 for everything else. Nothing here returns 0 for a unit
id, because nothing here removes anything.
"""

from __future__ import annotations

import os
import re
import sys
import textwrap
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final

import yaml

# The kinds this repo's `owns:` vocabulary allows, and the ONE of them a remover
# could ever legitimately act on.
#
# This is a KIND RULE, not a blocklist of four data paths. A blocklist would be
# correct for exactly the four paths AC #4 names and silently wrong for the
# nineteenth manifest, whose `data_path` nobody thought to add. Everything
# outside this set is retained structurally — see RETAIN_REASON, which has an
# entry for every other kind and is asserted to be total.
REMOVABLE_KINDS: Final[frozenset[str]] = frozenset({"home_path"})

# Why each non-removable kind is non-removable, one line each. Keyed by every
# `owns[].kind` outside REMOVABLE_KINDS; `retained()` looks each entry up here,
# so a kind added to config/units/README.md without a line here is a KeyError at
# the first manifest that uses it rather than a silently unexplained RETAIN.
RETAIN_REASON: Final[dict[str, str]] = {
    "data_path": "user data. Never removed, by design — this is the whole of AC #4",
    "repo_file": "the git checkout; removing it would delete this repo, not the install",
    "brew_formula": "a machine-global Homebrew formula this repo installs but does not own",
    "brew_cask": "a machine-global Homebrew cask this repo installs but does not own",
    "systemd_unit": "a system service; disabling one is a privileged, host-side operation",
    "container_image": "a container image shared with every chat that ever ran",
    "manual": "not a thing on disk: an account, a console setting, or a human step",
}

# `~/` followed by path components made only of these characters. NOT a prefix
# strip and NOT a split on whitespace.
#
# SIX OF THE TWENTY-FIVE `home_path` TARGETS IN config/units/ ARE PROSE, and
# units_lint.py existence-checks only `repo_file`, so nothing else in this repo
# would ever notice:
#
#   ~/.zshrc (personal-ai keychain exports block)
#   ~/.config/goose (symlink into /data/goose/config)
#   ~/.local/share/goose (symlink into /data/goose/data)
#   ~/.local/state/goose (symlink into /data/goose/state)
#   ~/.config/goose/secrets.yaml (per-extension connector entries)
#   ~/.ssh/life-vault-deploy (git deploy key on the brain)
#
# A resolver that strips the parenthetical answers `~/.zshrc` and
# `~/.config/goose` — a whole shell profile and goose's entire config tree, for
# targets whose text says the opposite. The character class has no space and no
# parenthesis in it precisely so all six fall out as UNRESOLVABLE rather than as
# something shorter than they say.
HOME_TARGET_RE: Final = re.compile(r"^~/([A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*)$")

# A unit id, and the reason it is validated rather than pasted into a path:
# `pai remove ../../../etc/passwd` would otherwise open a file outside
# config/units/ and report on it. Same spelling as units_lint.py's KEBAB_RE.
UNIT_ID_RE: Final = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")

# The width the manifest reasons are re-wrapped to. They are YAML block scalars
# whose line breaks are an artefact of the file, not of the sentence.
WRAP: Final = 76


@dataclass(frozen=True)
class Owned:
    """One `owns:` entry: what kind of thing it is, and how the manifest spells it."""

    kind: str
    target: str


@dataclass(frozen=True)
class Retained:
    """One thing `pai remove` would keep no matter what, with the reason it keeps it."""

    kind: str
    target: str
    why: str


@dataclass(frozen=True)
class Manifest:
    """The five fields of a unit manifest that `pai remove` reads. Nothing else."""

    unit_id: str
    tier: str
    supported: bool
    reason: str
    owns: tuple[Owned, ...]


def _emit(line: str) -> None:
    print(line)  # noqa: T201 -- this IS the reporting surface


def known_ids(repo: Path) -> list[str]:
    """Every unit id in the catalogue, from the filenames — no YAML parsed.

    The stem IS the id: units_lint.py's P1 asserts `id` == filename stem on
    every push, so globbing is the cheap half of a fact that is already gated.
    """
    return sorted(p.stem for p in (repo / "config" / "units").glob("*.yaml"))


def load_manifest(repo: Path, unit_id: str) -> Manifest | None:
    """Read one manifest, or None if it is absent, unreadable or not a mapping.

    The degraded arms are the same three load_units() in doctor.py handles, for
    the same reason: check-units.sh is the validator and it runs on every push,
    but it cannot stop an editor creating a half-written file between two of its
    runs. A traceback out of a command whose entire job is to refuse safely
    would be a poor answer to `pai remove`.
    """
    path = repo / "config" / "units" / f"{unit_id}.yaml"
    try:
        with path.open(encoding="utf-8") as handle:
            data: Any = yaml.safe_load(handle)
    except (OSError, yaml.YAMLError):
        return None
    if not isinstance(data, dict):
        return None
    block = data.get("uninstall")
    block = block if isinstance(block, dict) else {}
    owns = [
        Owned(str(entry.get("kind", "")), str(entry.get("target", "")))
        for entry in data.get("owns") or ()
        if isinstance(entry, dict)
    ]
    return Manifest(
        unit_id=str(data.get("id", unit_id)),
        tier=str(data.get("tier", "")),
        supported=block.get("supported") is True,
        reason=" ".join(str(block.get("reason", "")).split()),
        owns=tuple(owns),
    )


def parse_home_target(target: str, home: Path) -> Path | None:
    """Resolve a `home_path` target to a real path, or None when it is prose.

    None is the safe answer and it is returned for anything that is not exactly
    `~/` plus plain path components: the six prose targets listed on
    HOME_TARGET_RE, and any `..` component. The `..` guard is separate from the
    regex on purpose — `.` and `..` both match `[A-Za-z0-9._-]+`, so without it
    `~/../evil` resolves to a sibling of $HOME.
    """
    match = HOME_TARGET_RE.match(target.strip())
    if match is None:
        return None
    parts = match.group(1).split("/")
    if any(part in (".", "..") for part in parts):
        return None
    return home.joinpath(*parts)


def refusal_for(manifest: Manifest) -> list[str]:
    """Why `pai remove` will not remove this unit. NEVER EMPTY, for any input.

    Three arms, in this order, and the order is the safety argument:

      base       a base unit is the install itself. Removing it is uninstalling
                 personal-ai, which this command does not do at any tier. Its
                 manifest reason is printed too — AC #2 asks for the reason, not
                 for a different message.
      declared   `uninstall.supported: false`, which is all eighteen manifests
                 today. The reason is the MANIFEST'S, verbatim modulo
                 re-wrapping. Nothing here has a fallback string, so a manifest
                 that stopped explaining itself would print an empty reason —
                 which is why units_lint.py's check_uninstall requires a
                 non-empty reason in BOTH states.
      unwritten  `supported: true`, which no manifest says today. It still
                 refuses, because the removing half of this command does not
                 exist. A unit that declares itself removable must not become
                 removable by declaration.
    """
    lines: list[str] = []
    if manifest.tier == "base":
        lines.append(
            "this is a `tier: base` unit — it is the install itself, and "
            "`pai remove` does not uninstall personal-ai.",
        )
    if not manifest.supported:
        lines.append(f"the manifest says so: {manifest.reason}")
    elif not lines:
        lines.append(
            "the manifest declares `uninstall.supported: true`, but the removing half "
            "of this command is not written — see `pai remove --help`. A unit does not "
            "become removable by declaring itself removable.",
        )
    return lines


def retained(manifest: Manifest) -> list[Retained]:
    """Everything this unit owns that a remover would keep even if one existed.

    Kind-driven, so the answer for a nineteenth manifest is right before anyone
    has read it: everything outside REMOVABLE_KINDS is retained, and
    RETAIN_REASON says why for each kind. This is where AC #4 lives — /data,
    /data/goose, /data/code-agents, /data/life-vault and /data/tls are all
    `data_path`, and `data_path` is not a removable kind.
    """
    return [
        Retained(item.kind, item.target, RETAIN_REASON[item.kind])
        for item in manifest.owns
        if item.kind not in REMOVABLE_KINDS
    ]


def _wrapped(text: str, indent: str) -> list[str]:
    # break_on_hyphens=False: without it "machine-global" wraps as "machine-" /
    # "global", which reads as two words in a sentence quoted from a manifest.
    return textwrap.wrap(
        text, width=WRAP, initial_indent=indent, subsequent_indent=indent, break_on_hyphens=False,
    )


def report(manifest: Manifest, home: Path) -> None:
    """Print the refusal, then every target that is kept regardless.

    GROUPED BY KIND, with the reason printed once per kind rather than once per
    target: 65 of the catalogue's 131 `owns` entries are `repo_file`, and a
    per-entry reason turns the one line a reader needs into wallpaper.
    """
    _emit(f"== pai remove {manifest.unit_id} ==")
    _emit("")
    _emit(f"REFUSED  {manifest.unit_id} was not removed, and nothing was written.")
    for line in refusal_for(manifest):
        for wrapped in _wrapped(line, "         "):
            _emit(wrapped)

    keep = retained(manifest)
    if keep:
        _emit("")
        _emit(f"RETAINED ({len(keep)}), and kept even by a `pai remove` that did remove things:")
        for kind in dict.fromkeys(item.kind for item in keep):
            _emit(f"  {kind} — {RETAIN_REASON[kind]}")
            for item in keep:
                if item.kind == kind:
                    _emit(f"    RETAIN  {item.target}")

    homes = [item for item in manifest.owns if item.kind in REMOVABLE_KINDS]
    if homes:
        _emit("")
        _emit(f"THE ONLY KIND A REMOVER COULD EVER TOUCH ({len(homes)}), untouched here:")
        for owned in homes:
            resolved = parse_home_target(owned.target, home)
            _emit(f"    RETAIN  {owned.target}")
            detail = (
                f"resolves to {resolved}"
                if resolved is not None
                else "PROSE, not a path — nothing can resolve it, so nothing could remove it"
            )
            _emit(f"              {detail}")


def remove(repo: Path, home: Path, unit_id: str) -> int:
    """`pai remove <id>` — refuse, explain, and delete nothing. Always exit 2."""
    if not UNIT_ID_RE.match(unit_id):
        print(  # noqa: T201
            f"uninstall.py: {unit_id!r} is not a unit id (kebab-case, no slashes)",
            file=sys.stderr,
        )
        return 2
    manifest = load_manifest(repo, unit_id)
    if manifest is None:
        print(  # noqa: T201
            f"uninstall.py: no readable manifest for {unit_id!r}. "
            f"`pai list` is the catalogue; ids here: {', '.join(known_ids(repo)) or '(none)'}",
            file=sys.stderr,
        )
        return 2
    report(manifest, home)
    return 2


USAGE: Final = """\
Usage: pai remove <id>

  Print why <id> cannot be uninstalled, and every target that would be kept
  regardless. IT DELETES NOTHING, for any unit, with or without a flag — there
  is no --force and there will not be one until the two facts below stop being
  true.

  All eighteen units refuse today. Sixteen of them are unsupported with a
  reason in their manifest; two (coding-pack, opencode) are partially
  reversible, and are refused for these reasons rather than for the absence of
  code to do it:

    * REMOVING FILES LEAVES `pai doctor` PERMANENTLY RED. doctor's check_skills
      FAILs on any config/skills/ directory missing from ~/.agents/skills, and
      `doctor --fix` deliberately does not repair it ("--fix touches goose's
      extension config and nothing else"). Removing the eleven coding-pack
      skills would print `FAIL 11 of 12 shipped skills are not installed`
      forever, with no --fix path. doctor has no way to be told that a unit is
      DELIBERATELY absent.
    * REMOVING A goose EXTENSION IS UNDONE BY THE NEXT `doctor --fix`, which
      plans "absent from the live config -> add it" for every key the repo's
      own templates declare. A removal that a routine repair reverses is not a
      removal.

  And the install side cannot tell its own work from yours: copy_no_clobber and
  install_skill in scripts/mac/bootstrap-mac.sh both KEEP a pre-existing
  destination, so a skill directory may be the repo's copy or the one you wrote
  first, and nothing recorded which.

Exit: 0 for --help, 2 for everything else (refusal is the outcome, not an
error in the caller). Nothing here exits 0 for a unit id.

  PAI_HOME   resolve `home_path` targets against a different home (the tests
             use it); defaults to $HOME. It changes what is PRINTED and nothing
             else — this command has no writing surface for it to retarget.
"""


def main(argv: list[str]) -> int:
    """Dispatch. `remove` is consumed here because cli.sh forwards the verb."""
    repo = Path(__file__).resolve().parents[2]
    home = Path(os.environ.get("PAI_HOME", str(Path.home())))
    rest = argv[2:] if len(argv) > 1 and argv[1] == "remove" else None
    if rest is None:
        print(  # noqa: T201
            f"uninstall.py: unknown command {(argv[1] if len(argv) > 1 else '')!r} "
            f"(this file implements `pai remove` and nothing else)",
            file=sys.stderr,
        )
        return 2
    if rest and rest[0] in ("-h", "--help"):
        _emit(USAGE.rstrip("\n"))
        return 0
    if len(rest) != 1:
        print(  # noqa: T201
            f"uninstall.py: `pai remove` takes exactly one unit id (got {len(rest)})",
            file=sys.stderr,
        )
        print(USAGE.rstrip("\n"), file=sys.stderr)  # noqa: T201
        return 2
    return remove(repo, home, rest[0])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
