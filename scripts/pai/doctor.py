#!/usr/bin/env python3
"""Read-only inspection of a personal-ai install: what is here, and what drifted.

Nothing in this file writes. `pai doctor --fix` is a later ticket (#34) and will
need goose's ACP API, because goose serde-round-trips config.yaml -- the live
file on the author's Mac has 21 extensions and zero comments against a template
declaring 7 with 195 comment lines. That is also why this compares only the
fields the template DECLARES: goose adds keys of its own (`bundled`,
`description`, `display_name`) to everything it touches, and diffing whole
objects would report those as drift forever.

THE OWNERSHIP RULE, which is the decision that makes the output legible:
doctor reports drift on everything it can see, but only the keys the repo's own
templates declare are ever called drift. Extensions goose added by itself are
listed once, informationally, and never touched.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

import yaml

Level = Literal["PASS", "FAIL", "NOTE"]

# The fields a template entry can declare. Anything outside this set is goose's
# own bookkeeping and is not ours to have an opinion about.
DECLARED_FIELDS = (
    "enabled",
    "type",
    "cmd",
    "args",
    "env_keys",
    "available_tools",
    "uri",
    "timeout",
)

# A template value equal to one of these, or wrapped in angle brackets, is a
# placeholder the reader is told to replace. Without this rule doctor reports
# drift forever on a correctly personalised machine.
PLACEHOLDER_LITERALS = frozenset({"you@example.com"})


@dataclass(frozen=True)
class Finding:
    """One line of doctor output. `fix` renders as an indented continuation."""

    level: Level
    text: str
    fix: str | None = None


def _emit(line: str) -> None:
    print(line)  # noqa: T201 -- this IS the reporting surface


def is_placeholder(value: object) -> bool:
    """Return True when a template value is meant to be replaced by the reader."""
    if not isinstance(value, str):
        return False
    if value in PLACEHOLDER_LITERALS:
        return True
    return value.startswith("<") and value.endswith(">")


def load_yaml(path: Path) -> dict[str, Any]:
    """Parse a YAML mapping, or return {} when it is absent or not a mapping."""
    try:
        with path.open(encoding="utf-8") as handle:
            raw: Any = yaml.safe_load(handle)
    except (OSError, yaml.YAMLError):
        return {}
    return raw if isinstance(raw, dict) else {}


def extensions_of(config: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Return the `extensions:` map, with non-mapping entries dropped."""
    raw = config.get("extensions")
    if not isinstance(raw, dict):
        return {}
    return {k: v for k, v in raw.items() if isinstance(k, str) and isinstance(v, dict)}


def compare_extension(
    name: str,
    template: dict[str, Any],
    live: dict[str, Any] | None,
) -> list[Finding]:
    """Compare one extension on the fields the template declares, and only those."""
    if live is None:
        return [
            Finding(
                "FAIL",
                f"extension {name!r} is declared by the repo but absent from the live config",
                "scripts/mac/bootstrap-mac.sh installs it; or copy the block by hand",
            ),
        ]
    findings: list[Finding] = []
    for field in DECLARED_FIELDS:
        if field not in template:
            continue
        want, got = template[field], live.get(field)
        if want == got:
            continue
        if is_placeholder(want):
            findings.append(
                Finding("NOTE", f"{name}.{field} is personalised (template ships a placeholder)"),
            )
            continue
        findings.append(
            Finding(
                "FAIL",
                f"{name}.{field}: live {got!r} != declared {want!r}",
                "restore it from config/goose/config.yaml (--fix arrives in #34)",
            ),
        )
    if not findings:
        findings.append(Finding("PASS", f"extension {name} matches every declared field"))
    return findings


def check_extensions(template_cfg: dict[str, Any], live_cfg: dict[str, Any]) -> list[Finding]:
    """Every template-declared extension, plus one NOTE for goose's own additions."""
    template = extensions_of(template_cfg)
    live = extensions_of(live_cfg)
    findings: list[Finding] = []
    for name in sorted(template):
        findings.extend(compare_extension(name, template[name], live.get(name)))
    theirs = sorted(set(live) - set(template))
    if theirs:
        findings.append(
            Finding(
                "NOTE",
                f"not ours, never touched ({len(theirs)}): {', '.join(theirs)}",
            ),
        )
    return findings


def check_skills(repo: Path, home: Path) -> list[Finding]:
    """Every skill the repo ships must be installed under ~/.agents/skills."""
    shipped = {p.name for p in (repo / "config" / "skills").glob("*") if p.is_dir()}
    if not shipped:
        return [Finding("NOTE", "the repo ships no skills")]
    installed = {p.name for p in (home / ".agents" / "skills").glob("*") if p.is_dir()}
    missing = sorted(shipped - installed)
    if missing:
        return [
            Finding(
                "FAIL",
                f"{len(missing)} of {len(shipped)} shipped skills are not installed: "
                f"{', '.join(missing)}",
                "re-run scripts/mac/bootstrap-mac.sh (it is no-clobber)",
            ),
        ]
    return [Finding("PASS", f"all {len(shipped)} shipped skills are installed")]


def check_providers(repo: Path, home: Path) -> list[Finding]:
    """Compare provider wiring, but NOT the model catalogue.

    A byte-compare here is wrong, and measurably so: the repo ships 165 models
    for `together` while a live install held 17, ten of them not in the repo's
    list at all. That is `scripts/sync-models.sh` doing its documented job --
    both sides are supposed to move. Reporting it as drift would put four
    permanent FAILs in front of the reader and teach them to ignore the output.

    What cannot legitimately drift is the wiring: base_url, engine, and the
    NAME of the key env var (never its value). Those are compared; the
    catalogue difference is reported as a count, as information.
    """
    src = repo / "config" / "goose" / "custom_providers"
    dst = home / ".config" / "goose" / "custom_providers"
    findings: list[Finding] = []
    for path in sorted(src.glob("*.json")):
        live_path = dst / path.name
        if not live_path.is_file():
            findings.append(Finding("FAIL", f"provider {path.stem} is not installed"))
            continue
        try:
            want = json.loads(path.read_text(encoding="utf-8"))
            got = json.loads(live_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            findings.append(Finding("FAIL", f"provider {path.stem} is unreadable or not JSON"))
            continue
        if not isinstance(want, dict) or not isinstance(got, dict):
            findings.append(Finding("FAIL", f"provider {path.stem} is not a JSON object"))
            continue
        bad = [f for f in ("base_url", "engine", "api_key_env") if want.get(f) != got.get(f)]
        if bad:
            findings.append(
                Finding("FAIL", f"provider {path.stem} wiring differs: {', '.join(bad)}"),
            )
            continue
        n_want = len(want.get("models", []) or [])
        n_got = len(got.get("models", []) or [])
        if n_want != n_got:
            findings.append(
                Finding(
                    "NOTE",
                    f"provider {path.stem}: wiring matches; catalogue differs "
                    f"({n_want} in repo, {n_got} live) — expected, sync-models.sh owns it",
                ),
            )
        else:
            findings.append(Finding("PASS", f"provider {path.stem} matches"))
    return findings


def check_goosehints(home: Path) -> list[Finding]:
    """Report whether the hints file still holds its shipped <placeholders>."""
    hints = home / ".config" / "goose" / ".goosehints"
    if not hints.is_file():
        return [Finding("NOTE", ".goosehints is not installed")]
    text = hints.read_text(encoding="utf-8", errors="replace")
    if "<" in text and ">" in text:
        return [
            Finding(
                "FAIL",
                ".goosehints still contains <placeholder> markers",
                "edit ~/.config/goose/.goosehints -- name, email, timezone",
            ),
        ]
    return [Finding("PASS", ".goosehints has been personalised")]


def run(cmd: list[str]) -> str:
    """Best-effort capture of a read-only command; '' when it cannot run."""
    try:
        out = subprocess.run(  # noqa: S603 -- fixed argv, no shell
            cmd,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout


def check_opencode_shadowing() -> list[Finding]:
    """Two installs on PATH is a pinning failure in a repo built on pins."""
    found = [line for line in run(["/usr/bin/which", "-a", "opencode"]).splitlines() if line]
    if len(found) <= 1:
        return []
    return [
        Finding(
            "FAIL",
            f"opencode resolves {len(found)} ways; the first wins: {found[0]}",
            "a self-updating vendor install shadowing brew's defeats the pin (#38)",
        ),
    ]


def collect(repo: Path, home: Path) -> list[Finding]:
    """Every check, in report order."""
    template_cfg = load_yaml(repo / "config" / "goose" / "config.yaml")
    live_cfg = load_yaml(home / ".config" / "goose" / "config.yaml")
    findings = check_extensions(template_cfg, live_cfg)
    findings.extend(check_skills(repo, home))
    findings.extend(check_providers(repo, home))
    findings.extend(check_goosehints(home))
    # PATH describes the MACHINE, not the home being inspected. Running it
    # against a fixture would report this Mac's opencode situation as if it
    # were the fixture's, which is both wrong and un-fixable by the reader.
    if home == Path.home():
        findings.extend(check_opencode_shadowing())
    return findings


def report(findings: list[Finding]) -> int:
    """Print findings; return the process exit code."""
    _emit("doctor reports drift on everything; --fix (#34) re-asserts only what the")
    _emit("repo's own templates declare.")
    _emit("")
    for finding in findings:
        _emit(f"{finding.level:<4}  {finding.text}")
        if finding.fix:
            _emit(f"      fix: {finding.fix}")
    failed = sum(1 for f in findings if f.level == "FAIL")
    passed = sum(1 for f in findings if f.level == "PASS")
    _emit("")
    _emit(f"== summary: {passed} passed, {failed} failed ==")
    return 1 if failed else 0


def inventory(repo: Path, home: Path) -> int:
    """`pai status` -- what is on this machine, no verdicts."""
    live = extensions_of(load_yaml(home / ".config" / "goose" / "config.yaml"))
    template = extensions_of(load_yaml(repo / "config" / "goose" / "config.yaml"))
    skills = sorted(p.name for p in (home / ".agents" / "skills").glob("*") if p.is_dir())
    _emit(f"home           {home}")
    _emit(f"goose config   {len(live)} extensions live, {len(template)} declared by the repo")
    on = sorted(k for k, v in live.items() if v.get("enabled"))
    _emit(f"enabled        {', '.join(on) or '-'}")
    _emit(f"skills         {len(skills)} installed")
    version = run(["/usr/bin/env", "goose", "--version"]).strip()
    _emit(f"goose          {version or 'not found'}")
    return 0


def catalogue(repo: Path) -> int:
    """`pai list` -- what the REPO ships. Manifest-driven at #36; a scan today."""
    checks = sorted(p.name for p in (repo / "scripts" / "verify").glob("check-*.sh"))
    skills = sorted(p.name for p in (repo / "config" / "skills").glob("*") if p.is_dir())
    conns = sorted(p.stem for p in (repo / "config" / "connectors").glob("*.yaml"))
    recipes = sorted(p.stem for p in (repo / "recipes").glob("*.yaml"))
    for label, items in (
        ("verify", checks),
        ("skills", skills),
        ("connectors", conns),
        ("recipes", recipes),
    ):
        _emit(f"{label:<12} {len(items)}")
        for item in items:
            _emit(f"  {item}")
    _emit("")
    _emit("(derived from the tree; becomes manifest-driven at #36)")
    return 0


def main(argv: list[str]) -> int:
    """Dispatch. Exit 0 ok, 1 findings, 2 usage."""
    repo = Path(__file__).resolve().parents[2]
    home = Path(os.environ.get("PAI_HOME", str(Path.home())))
    command = argv[1] if len(argv) > 1 else ""
    if command == "doctor":
        return report(collect(repo, home))
    if command == "status":
        return inventory(repo, home)
    if command == "list":
        return catalogue(repo)
    print(f"doctor.py: unknown command {command!r}", file=sys.stderr)  # noqa: T201
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
