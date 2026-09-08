#!/usr/bin/env python3
"""Inspect a personal-ai install: what is here, what drifted, and -- opt in -- fix it.

READ-ONLY BY DEFAULT, AND THAT IS STILL THE CONTRACT. `pai doctor`, `pai status`
and `pai list` write nothing, anywhere, ever; scripts/verify/test-pai.sh proves
it by hashing every byte of a fixture before and after. What changed in #34 is
that ONE verb was added beside them, and it is the first mutating thing in this
tool:

    pai doctor                  report. writes nothing.
    pai doctor --dry-run        say exactly what --fix WOULD do. writes nothing.
    pai doctor --fix            re-assert, over goose's ACP config API, the keys
                                the repo's own templates declare. WRITES.
    pai doctor --fix --migrate-envs
                                additionally perform the one announced, one-way
                                `envs` migration described below.

--fix is opt-in, it is never implied, and `--dry-run` is the reading of it that
costs nothing -- the plan it prints is the same plan, line for line, that --fix
would then execute.

WHY IT CANNOT JUST EDIT config.yaml. goose serde-round-trips that file: the live
file on the author's Mac has 21 extensions and zero comments against a template
declaring 7 with 195 comment lines, so a file-copying "fix" is undone by the
next thing goose writes. The supported surface is the ACP config API, which
scripts/pai/goosecfg.py speaks -- imported LAZILY, inside the --fix branch, so
that plain `pai doctor` keeps no dependency on it at all.

THE OWNERSHIP RULE, which is the decision that makes the output legible:
doctor reports drift on everything it can see, but only the keys the repo's own
templates declare are ever called drift. Extensions goose added by itself are
listed once, informationally, and never touched. --fix inherits that rule and
narrows it further -- see REFUSALS on `plan_fix`, which is the list worth
reading before trusting this with a live config.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final, Literal

import yaml

Level = Literal["PASS", "FAIL", "NOTE", "FIXED", "WOULD"]

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
                "re-assert it over ACP: pai doctor --dry-run, then pai doctor --fix",
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
    """Print findings; return the process exit code. WRITES NOTHING."""
    _emit("doctor reports drift on everything; --fix re-asserts only what the repo's")
    _emit("own templates declare, and only over goose's ACP config API.")
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


# --------------------------------------------------------------------------
# --fix: the only mutating path in this file
# --------------------------------------------------------------------------

# `builtin` and `platform` blocks are goose's OWN extensions, declared here only
# so their on/off state is written down. ACP's `config/extensions/add` speaks
# `type: mcp` and nothing else, so `set-enabled` is the only lever that reaches
# one -- which is exactly enough for `apps`, the security-relevant case, and
# exactly nothing for the rest.
PLATFORM_TYPES = frozenset({"builtin", "platform"})

# Printed on every --fix and --dry-run. It is the reader's answer to "what did
# this just decide not to touch", and it is deliberately the first NOTE.
OUT_OF_SCOPE = Finding(
    "NOTE",
    "--fix touches goose's extension config and nothing else: skills, .goosehints, "
    "provider wiring and the model catalogue are owned by bootstrap-mac.sh and "
    "sync-models.sh, which is why they are not repaired here",
    "plain `pai doctor` reports those; it is still the whole picture",
)


@dataclass(frozen=True)
class Repair:
    """One extension --fix would re-assert, with the before/after that justifies it.

    `lines` is rendered at PLAN time, not at report time, so `--dry-run` and
    `--fix` print byte-identical text under different tags. A dry run that
    described the work differently from the work would be worth nothing.
    """

    name: str
    lines: tuple[str, ...]
    template: dict[str, Any]
    envs: dict[str, str]
    enable: bool
    # True when the repair is a single `set-enabled` rather than a full add:
    # the builtin/platform case, where nothing else is reachable.
    enabled_only: bool


def refuse_split_brain(home: Path) -> str:
    """Say why --fix must not run against this home, or '' when it may.

    `PAI_HOME` retargets everything doctor READS. It retargets nothing doctor
    WRITES: the ACP endpoint is whatever goose answers, which is this machine's
    real config. So `PAI_HOME=/tmp/fixture pai doctor --fix` would diagnose a
    fixture and repair the live install. Refused, unless the caller has also
    named the endpoint (`GOOSE_ACP_URL`) or the binary (`PAI_GOOSE_BIN`) and so
    has said out loud which goose it means.
    """
    if home == Path.home():
        return ""
    if os.environ.get("GOOSE_ACP_URL") or os.environ.get("PAI_GOOSE_BIN"):
        return ""
    return (
        f"refusing --fix: PAI_HOME={home} is not $HOME, so --fix would diagnose that "
        "home and repair this machine's goose. Set GOOSE_ACP_URL (or PAI_GOOSE_BIN) "
        "to name the goose you mean."
    )


def field_matches(field: str, want: Any, got: Any) -> bool:  # noqa: ANN401 -- YAML values
    """Compare one declared field the same way goosecfg's read-back proves it.

    THE PLANNER MUST BE NO STRICTER THAN THE PROVER, or --fix never converges:
    it would re-apply an extension whose write goosecfg then certifies as
    correct, on every run, forever. Two fields need that care.

    `env_keys` is a SUPERSET comparison because goose appends the NAME of every
    promoted env value to it -- a successful migration legitimately widens the
    list, and equality would false-FAIL on exactly the operation that worked.

    `available_tools` is compared as a SET because goosecfg.prove_allowlist
    does; a reordering is not a difference in what the agent may call.
    """
    if field == "env_keys":
        return set(want or ()) <= set(got or ())
    if field == "available_tools" and isinstance(want, list) and isinstance(got, list):
        return set(want) == set(got)
    return bool(want == got)


def diff_fields(template: dict[str, Any], live: dict[str, Any]) -> list[tuple[str, Any, Any]]:
    """Every declared field where the live entry disagrees, as (field, live, declared)."""
    diffs: list[tuple[str, Any, Any]] = []
    for field in DECLARED_FIELDS:
        if field not in template or is_placeholder(template[field]):
            continue
        got = live.get(field)
        if field_matches(field, template[field], got):
            continue
        diffs.append((field, got, template[field]))
    return diffs


def keep_promoted_env_keys(
    template: dict[str, Any],
    live: dict[str, Any] | None,
) -> dict[str, Any]:
    """Return the template block widened by any `env_keys` name goose added itself.

    THE PAYLOAD IS THE WHOLE ENTRY: `config/extensions/add` is a full replace,
    not a merge (measured), so re-sending the template's `env_keys` verbatim
    DELETES every name that is not in it. That is not hypothetical -- it is
    exactly what --migrate-envs appends. Without this, the next repair of any
    other field silently un-wires the value that migration promoted: the secret
    stays in goose's store, the extension stops being handed it, and NOTHING
    reports it, because `field_matches` compares env_keys as a superset and goes
    on calling the narrowed list a match.

    It is also the ownership rule read correctly. A name the repo's template does
    not declare is not the repo's to remove, for the same reason the fourteen
    extensions goose added by itself are listed and never touched.
    """
    declared = [str(k) for k in template.get("env_keys") or ()]
    extra = sorted({str(k) for k in (live or {}).get("env_keys") or ()} - set(declared))
    if not extra:
        return template
    return {**template, "env_keys": [*declared, *extra]}


def plan_envs(
    name: str,
    live_block: dict[str, Any],
    *,
    migrate: bool,
) -> tuple[dict[str, str] | None, list[Finding]]:
    """Decide what happens to an extension's inline `envs`. Returns None to REFUSE it.

    MEASURED on goose 1.46.0, and this is the single most dangerous fact in the
    whole feature: `envs` is unreadable over ACP in BOTH directions, and ANY ACP
    write leaves disk `envs: {}`. So re-asserting an extension that carries an
    inline value DESTROYS that value -- silently, as a side effect of fixing
    something else entirely. The author's own machine has
    `workspace-mcp.envs.USER_GOOGLE_EMAIL` populated, so this is the common case,
    not the corner.

    Re-sending the value as `server.env` does not preserve it either: goose
    PROMOTES it into its secret store, appends the name to `env_keys`, and still
    writes `envs: {}`. That is a one-way door on a live machine, so it is opt-in
    behind --migrate-envs. Without the flag the extension is not touched AT ALL,
    and the NOTE names the remedy.

    THE VALUE NEVER APPEARS -- not in a plan, not in a report, not in an
    exception. Only the KEY is ever named, and the proof that the migration
    landed is goosecfg's `config/read {isSecret: true}` returning non-null.

    Values are read from the LIVE config, never the template: --fix migrates a
    value that already exists and never invents one, so an unpersonalised
    machine gets its placeholder dropped rather than promoted.
    """
    raw = live_block.get("envs")
    if not isinstance(raw, dict) or not raw:
        return {}, []
    real = {str(k): str(v) for k, v in raw.items() if not is_placeholder(v)}
    notes = [
        Finding("NOTE", f"{name}.envs.{key} still holds the template's placeholder -- dropped")
        for key in sorted({str(k) for k in raw} - set(real))
    ]
    if not real:
        return {}, notes
    keys = ", ".join(sorted(real))
    if not migrate:
        notes.append(
            Finding(
                "NOTE",
                f"{name} NOT TOUCHED: any ACP write erases inline `envs`, and this live "
                f"config still holds {keys}",
                "re-run as `pai doctor --fix --migrate-envs` to promote it into goose's "
                "secret store instead -- one way, and the value is never printed",
            ),
        )
        return None, notes
    notes.append(
        Finding(
            "NOTE",
            f"{name}.envs: migrating {keys} into goose's secret store -- ONE WAY. The "
            "value leaves config.yaml, env_keys gains the name, and the read-back "
            "proves only that the key is set, never what it is",
        ),
    )
    return real, notes


def plan_platform(
    name: str,
    template: dict[str, Any],
    live: dict[str, Any] | None,
) -> tuple[list[Repair], list[Finding]]:
    """Plan a builtin/platform extension: `enabled`, and deliberately nothing else.

    `set-enabled` is the only ACP call that reaches one (proven working on
    `apps` specifically, both ways, persisting to disk). Comparing anything else
    here would be worse than useless: LiveEntry.to_disk() infers `type` from the
    server shape a builtin does not have, so `type` would read as drift on every
    run and no call could ever clear it.
    """
    if live is None:
        return [], [
            Finding(
                "NOTE",
                f"{name} is a builtin/platform extension and is absent from the live "
                "config; ACP's add speaks `type: mcp` only, so --fix cannot create one",
                "`goose configure` -> Toggle Extensions, once",
            ),
        ]
    want = bool(template.get("enabled"))
    if bool(live.get("enabled")) == want:
        return [], []
    line = f"{name}.enabled: live {live.get('enabled')!r} -> declared {want!r}"
    return [Repair(name, (line,), template, {}, want, enabled_only=True)], []


def plan_mcp(
    name: str,
    template: dict[str, Any],
    live: dict[str, Any] | None,
    live_block: dict[str, Any],
    *,
    migrate_envs: bool,
) -> tuple[list[Repair], list[Finding]]:
    """Plan one repo-declared MCP extension, and say what it will not do.

    TWO REFUSALS, NOT ONE, and the distinction is what makes playwright and
    tavily fixable at all. An extension with no non-empty snake_case allowlist
    is APPLIED and left disabled; only ENABLING it is refused. Collapsing them
    would leave two of the four shipped fragments permanently unrepairable,
    since both ship with their allowlist commented out.
    """
    notes: list[Finding] = []
    if "availableTools" in template:
        return [], [
            Finding(
                "NOTE",
                f"{name} declares camelCase `availableTools`, which goose accepts and "
                "then stores as NOTHING -- meaning every tool allowed. Refused before "
                "any write",
                "rename it to snake_case `available_tools` in config/goose/extensions.d/",
            ),
        ]
    allow = template.get("available_tools")
    has_allow = isinstance(allow, list) and bool(allow)
    want_enabled = bool(template.get("enabled"))
    if want_enabled and not has_allow:
        notes.append(
            Finding(
                "NOTE",
                f"{name} declares `enabled: true` with no non-empty `available_tools`; "
                "it will be applied and left DISABLED. An absent allowlist means every "
                "tool is allowed, so enabling it is refused",
                "add the snake_case allowlist to config/goose/extensions.d/",
            ),
        )
    envs, env_notes = plan_envs(name, live_block, migrate=migrate_envs)
    notes.extend(env_notes)
    if envs is None:
        return [], notes
    wanted = keep_promoted_env_keys(template, live)
    enable = want_enabled and has_allow
    lines: tuple[str, ...]
    if live is None:
        state = "enabled" if enable else "disabled"
        lines = (f"{name}: absent from the live config -> add it, {state}",)
    else:
        diffs = diff_fields(wanted, live)
        if not diffs:
            return [], notes
        lines = tuple(f"{name}.{f}: live {g!r} -> declared {w!r}" for f, g, w in diffs)
    return [Repair(name, lines, wanted, envs, enable, enabled_only=False)], notes


def plan_fix(
    template_cfg: dict[str, Any],
    live: dict[str, dict[str, Any]],
    live_cfg: dict[str, Any],
    *,
    migrate_envs: bool,
) -> tuple[list[Repair], list[Finding]]:
    """Work out every repair and every refusal, WITHOUT performing any of them.

    REFUSALS -- the list to read before pointing this at a live config. --fix
    will not touch:

      1. any live extension the repo's templates do not declare (goose's own 14
         on the author's Mac). Listed once, never written.
      2. a builtin/platform extension that is absent -- ACP cannot create one.
      3. any field of a builtin/platform other than `enabled` -- `set-enabled`
         is the only lever that reaches one.
      4. a template value that is a placeholder (`you@example.com`, `<...>`).
         That is personalisation; --fix never invents a value.
      5. inline `envs` values, unless --migrate-envs is given: any ACP write
         erases them, so the default is to leave the whole extension alone.
      6. a template declaring camelCase `availableTools` -- refused BEFORE any
         write, because goose would accept it and store no allowlist at all.
      7. enabling anything with no non-empty snake_case allowlist.
      8. everything outside goose's extension config -- skills, .goosehints,
         provider wiring, the model catalogue, `active_provider`.

    Every one of those is a NOTE. NOTEs do NOT set the exit code, on purpose:
    items 1 and 8 are structural and no fix can ever clear them, and an exit
    code that is permanently 1 is how a checker gets ignored.
    """
    template = extensions_of(template_cfg)
    live_blocks = extensions_of(live_cfg)
    repairs: list[Repair] = []
    notes: list[Finding] = [OUT_OF_SCOPE]
    platform = sorted(n for n, b in template.items() if b.get("type") in PLATFORM_TYPES)
    if platform:
        notes.append(
            Finding(
                "NOTE",
                f"builtin/platform ({', '.join(platform)}): only `enabled` is reachable "
                "over ACP -- set-enabled is the sole lever, and every other declared "
                "field on them is reported by `pai doctor`, never repaired here",
            ),
        )
    for name in sorted(template):
        block = template[name]
        if block.get("type") in PLATFORM_TYPES:
            more, said = plan_platform(name, block, live.get(name))
        else:
            more, said = plan_mcp(
                name, block, live.get(name), live_blocks.get(name) or {},
                migrate_envs=migrate_envs,
            )
        repairs.extend(more)
        notes.extend(said)
    theirs = sorted(set(live) - set(template))
    if theirs:
        notes.append(
            Finding("NOTE", f"not ours, never touched ({len(theirs)}): {', '.join(theirs)}"),
        )
    return repairs, notes


def apply_repair(client: Any, repair: Repair) -> str:  # noqa: ANN401 -- goosecfg.AcpClient
    """Perform one repair and PROVE it landed. Returns '' on success, else why not.

    SUCCESS FROM THE CALL IS NOT EVIDENCE -- that is goosecfg's whole design and
    it applies to `set-enabled` too, which answers `{}` whatever it did. So the
    enabled-only path reads back here rather than believing the reply;
    goosecfg.apply_extension already does the equivalent for the full path, and
    restores the pre-image's enabled state on any failure after the write.
    """
    import goosecfg  # noqa: PLC0415 -- lazy on purpose; see the module docstring

    try:
        if repair.enabled_only:
            client.set_enabled(repair.name, enabled=repair.enable)
            entry = client.get(repair.name)
            if entry is None or entry.enabled != repair.enable:
                return "set-enabled reported success and the read-back disagrees"
        else:
            goosecfg.apply_extension(
                client, repair.name, repair.template, envs=repair.envs, enable=repair.enable,
            )
    except goosecfg.GooseCfgError as exc:
        return f"{exc.reason}: {exc.detail}" if exc.detail else exc.reason
    return ""


def fix_report(
    repairs: list[Repair],
    notes: list[Finding],
    outcomes: list[tuple[Repair, str]],
    *,
    dry_run: bool,
) -> int:
    """Print the plan (or the result) and return the exit code.

    0 nothing fixable remains, 1 something fixable does. A dry run that found
    work to do is a 1 for the same reason a FAIL is: the drift is still there.
    Refusals are NOTEs and never move the number.
    """
    fixed = unfixed = 0
    for repair in repairs if dry_run else []:
        for line in repair.lines:
            _emit(f"WOULD  {line}")
    for repair, why in outcomes:
        for line in repair.lines:
            _emit(f"{'FAIL ' if why else 'FIXED'}  {line}")
        if why:
            _emit(f"       goose did not keep it -- {why}")
            unfixed += 1
        else:
            fixed += 1
    for note in notes:
        _emit(f"NOTE   {note.text}")
        if note.fix:
            _emit(f"       fix: {note.fix}")
    _emit("")
    if dry_run:
        _emit(
            f"== dry run: {len(repairs)} would be re-asserted, {len(notes)} refused; "
            "NOTHING WAS WRITTEN ==",
        )
        return 1 if repairs else 0
    _emit(f"== fix: {fixed} fixed, {unfixed} unfixed, {len(notes)} refused ==")
    return 1 if unfixed else 0


def fix(repo: Path, home: Path, *, dry_run: bool, migrate_envs: bool) -> int:
    """`pai doctor --fix` -- the only thing in this file that writes.

    Exit: 0 nothing fixable remains, 1 an unfixed FAIL, 2 refused or no goose
    reachable and none spawnable.

    There is NO journal and there is deliberately no cache. The plan is computed
    from the live ACP listing every time, so a goose restart that put a key back
    is detected and re-asserted by exactly the same code path as the first run.
    That is also what makes --fix idempotent by construction: run it twice and
    the second run finds nothing, because the read-back IS the state.
    """
    import goosecfg  # noqa: PLC0415 -- lazy on purpose; see the module docstring

    refusal = refuse_split_brain(home)
    if refusal:
        print(f"doctor.py: {refusal}", file=sys.stderr)  # noqa: T201
        return 2
    template_cfg = load_yaml(repo / "config" / "goose" / "config.yaml")
    live_path = home / ".config" / "goose" / "config.yaml"
    live_cfg = load_yaml(live_path)
    mode = "DRY RUN -- nothing will be written" if dry_run else "WRITING"
    _emit(f"== pai doctor --fix ({mode}) ==")
    _emit(f"target: {os.environ.get('GOOSE_ACP_URL') or 'an ephemeral goose serve on loopback'}")
    # The ONE input that does not come from the live ACP listing. Inline `envs`
    # are unreadable over the wire in both directions, so the refusal that keeps
    # a write from erasing them is computed from this file -- and PAI_HOME can
    # point it at a machine other than the one GOOSE_ACP_URL is serving. Named
    # out loud rather than assumed, because being wrong about it is silent.
    _emit(f"inline `envs` read from: {live_path}")
    _emit("")
    try:
        with goosecfg.connect() as client:
            live = {e.config_key: e.to_disk() for e in client.list_extensions()}
            repairs, notes = plan_fix(template_cfg, live, live_cfg, migrate_envs=migrate_envs)
            outcomes = [] if dry_run else [(r, apply_repair(client, r)) for r in repairs]
    except goosecfg.GooseCfgError as exc:
        # Everything a repair can raise is caught by apply_repair, so what
        # reaches here is the SESSION failing: nothing answered, nothing was
        # spawnable, the listing came back malformed, or the ephemeral server
        # would not shut down. All four are exit 2 -- "this could not run" --
        # rather than exit 1, "this ran and found drift". A session that dies
        # after some repairs landed reports none of them; the next run's
        # read-back is what recovers, since there is no journal to be wrong.
        print(f"doctor.py: no usable goose ACP session ({exc})", file=sys.stderr)  # noqa: T201
        print(  # noqa: T201
            "  Point GOOSE_ACP_URL at a running `goose serve` (plus "
            "GOOSE_SERVER__SECRET_KEY), or PAI_GOOSE_BIN at a goose binary --fix may "
            "spawn. On the brain the permanent goose-serve.service must be used: two "
            "writers on one config.yaml is a lost update.",
            file=sys.stderr,
        )
        return 2
    return fix_report(repairs, notes, outcomes, dry_run=dry_run)


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


@dataclass(frozen=True)
class Secret:
    """One `secrets:` row of one manifest, flattened for `pai secrets`."""

    key: str
    store: str
    prompt: str
    generate: str | None
    optional: bool


@dataclass(frozen=True)
class Unit:
    """One row of `pai list`, flattened from one config/units/<id>.yaml manifest."""

    id: str
    tier: str
    host: str
    summary: str
    requires: tuple[str, ...]
    cost: str
    manual_steps: int
    secrets: tuple[Secret, ...]
    # Not columns -- the two counts in the footer, which are the whole reason
    # config/units/ exists: a majority of units have nothing that installs them
    # or nothing that verifies them, and that was invisible until it was
    # counted. The numbers are deliberately NOT written down here: they are the
    # directory's, they move with every manifest, and check-units.sh is the
    # thing that has a verdict about them.
    has_installer: bool
    # `verify` is the manifest's list VERBATIM, entries included -- an entry may
    # carry arguments (`scripts/verify/check-security.sh --local`), which is the
    # whole reason brain.yaml can name the mode its check has to run in. Nothing
    # here splits or resolves it; `pai verify` does, because it is the thing
    # that has to run it.
    verify: tuple[str, ...]

    @property
    def has_verify(self) -> bool:
        """Whether this unit claims any verify script. The footer's second count."""
        return bool(self.verify)


# One template for the header and every row, so a column added to one cannot
# drift from the other. Widths are FIXED, not measured: the longest id in
# epic #30's catalogue is 17 characters and the longest tier is `default_on`,
# and a `max()` over the rows would be one more thing to get wrong on an empty
# directory. An over-long value pushes its row right; it is never truncated.
UNIT_ROW = "{id:<18}  {tier:<11}  {host:<10}  {manual:>6}  {cost:<30}  {requires}"


def load_units(repo: Path) -> tuple[list[Unit], list[str]]:
    """Flatten config/units/*.yaml into rows, plus the stems that would not parse.

    THE RENDERER ASSUMES VALID INPUT. scripts/verify/check-units.sh is the sole
    validator and it runs in CI on every push; re-checking a field here would
    add a branch that buys an assertion already made, and this file is the one
    the 85% per-file coverage floor is measured against. The single exception is
    a file the gate cannot stop an editor from creating between two of its runs
    -- a syntax error, or a half-written file that is not a mapping at all.
    Those stems are listed rather than crashing the menu.

    A missing config/units/ yields ([], []) -- Path.glob on an absent directory
    is empty, it does not raise.
    """
    units: list[Unit] = []
    unreadable: list[str] = []
    for path in sorted((repo / "config" / "units").glob("*.yaml")):
        try:
            with path.open(encoding="utf-8") as handle:
                data: Any = yaml.safe_load(handle)
        except (OSError, yaml.YAMLError):
            unreadable.append(path.stem)
            continue
        if not isinstance(data, dict):
            # A zero-byte or comment-only manifest -- `touch config/units/x.yaml`
            # while drafting -- parses to None, and a stray top-level list parses
            # to a list. Neither raises YAMLError, so the arm above never sees
            # them and `.get` would traceback out of a read-only menu. Same
            # class of half-written file, so the same degraded handling.
            unreadable.append(path.stem)
            continue
        units.append(
            Unit(
                id=str(data.get("id", path.stem)),
                tier=str(data.get("tier", "-")),
                host=str(data.get("host", "-")),
                summary=str(data.get("summary", "")),
                requires=tuple(data.get("requires") or ()),
                # AMOUNTS ONLY. The manifest's sibling `line` is the verbatim
                # README budget row the validator cross-checks -- a sentence,
                # not a column. No figure originates here or in the manifest.
                cost=" + ".join(str(c["amount"]) for c in data.get("cost") or ()) or "-",
                manual_steps=len(data.get("manual_steps") or ()),
                secrets=tuple(
                    Secret(
                        key=str(row["key"]),
                        store=str(row["store"]),
                        prompt=str(row["prompt"]),
                        # `generate: null` is the common case and stays None;
                        # anything else is the `openssl rand -hex N` command
                        # check-units.sh has already constrained to that shape.
                        generate=None if row["generate"] is None else str(row["generate"]),
                        optional=bool(row["optional"]),
                    )
                    for row in data.get("secrets") or ()
                ),
                has_installer=data.get("installer") is not None,
                # str() per entry, not tuple(...): check-units.sh rejects a
                # non-string entry, but this renderer runs between two of its
                # runs and a mapping here would reach `pai verify` as a python
                # repr on a command line.
                verify=tuple(str(v) for v in data.get("verify") or ()),
            ),
        )
    return units, unreadable


def render_catalogue(units: list[Unit], unreadable: list[str]) -> None:
    """Print the menu: one padded row per unit with its summary underneath.

    `summary` is a line of its own rather than a column. It is up to 120
    characters by schema, so as a column it would have to be truncated -- and a
    truncated summary is exactly the kind of almost-right value this catalogue
    was built to stop shipping.
    """
    _emit(
        UNIT_ROW.format(
            id="id",
            tier="tier",
            host="host",
            manual="manual",
            cost="cost",
            requires="requires",
        ),
    )
    for unit in units:
        _emit(
            UNIT_ROW.format(
                id=unit.id,
                tier=unit.tier,
                host=unit.host,
                manual=unit.manual_steps,
                cost=unit.cost,
                requires=", ".join(unit.requires) or "-",
            ),
        )
        _emit(f"    {unit.summary}")
    _emit("")
    _emit(
        f"{len(units)} units — {sum(1 for u in units if not u.has_installer)} with no "
        f"installer, {sum(1 for u in units if not u.has_verify)} with no verify script.",
    )
    if unreadable:
        _emit(f"unreadable ({len(unreadable)}): {', '.join(sorted(unreadable))}")


def catalogue(repo: Path) -> int:
    """`pai list` -- the units this repo ships, read from config/units/.

    Always 0: `list` reports what the manifests say, including that a unit has
    no installer and no verify script. Those absences are the catalogue's
    content, not its failure -- check-units.sh is what has a verdict about them.
    """
    units, unreadable = load_units(repo)
    render_catalogue(units, unreadable)
    return 0


# `pai units --field <name>` -- the machine-readable projections. Deliberately a
# CLOSED vocabulary: this is the roster `pai verify` runs, so a misspelt field
# must be a usage error and never an empty list that reads as "no checks".
UNIT_FIELDS: Final = ("id", "verify")

# The `host:` vocabulary, and it is config/units/README.md's, not this file's --
# check-units.sh is the validator. Repeated here only so `--host` can refuse an
# unknown value rather than silently selecting nothing.
UNIT_HOSTS: Final = ("mac", "vps", "both", "checklist")


def unit_values(units: list[Unit], field: str) -> list[str]:
    """Flatten one field of every unit into a de-duplicated, ordered list.

    Order is the manifest order load_units already fixed (sorted by filename),
    and duplicates are dropped at FIRST appearance. Two units may legitimately
    name the same check -- check-units.sh's P5 forbids it today, but the
    de-duplication is here so that rule can relax without `pai verify` running
    the same script twice and double-counting its verdict.
    """
    out: list[str] = []
    for unit in units:
        for value in (unit.verify if field == "verify" else (unit.id,)):
            if value not in out:
                out.append(value)
    return out


def projection(repo: Path, argv: list[str]) -> int:
    """`pai units --field <field> [--host <host>]` -- one value per line.

    THE POINT IS THAT NOTHING DOWNSTREAM KEEPS ITS OWN COPY. cli.sh's verify
    roster was a hardcoded string, and it had drifted: it named `check-brain`
    and `check-code-agents` but not `check-security`, so one of brain's two
    verify scripts was reachable only by typing its path (brain.yaml recorded
    that as a blocker). Deriving it means a unit that gains a check gains it in
    `pai verify` too, with no second edit.

    An unreadable manifest is exit 1 WITH the readable values still on stdout.
    A roster is the one place where "some of the manifests parsed" must not be
    silently equivalent to "that is all of them" -- the caller loses a check and
    nothing says so. `pai list` prints the same stems and returns 0, because a
    menu reporting a broken manifest is reporting, not failing.
    """
    field = ""
    host = ""
    rest = list(argv)
    while rest:
        flag = rest.pop(0)
        if flag in ("--field", "--host"):
            if not rest:
                print(f"doctor.py: {flag} needs a value", file=sys.stderr)  # noqa: T201
                return 2
            value = rest.pop(0)
            if flag == "--field":
                field = value
            else:
                host = value
        else:
            print(f"doctor.py: unknown option {flag!r}", file=sys.stderr)  # noqa: T201
            return 2
    if field not in UNIT_FIELDS:
        print(  # noqa: T201
            f"doctor.py: units --field must be one of {', '.join(UNIT_FIELDS)} "
            f"(got {field!r})",
            file=sys.stderr,
        )
        return 2
    if host and host not in UNIT_HOSTS:
        print(  # noqa: T201
            f"doctor.py: units --host must be one of {', '.join(UNIT_HOSTS)} (got {host!r})",
            file=sys.stderr,
        )
        return 2
    units, unreadable = load_units(repo)
    if host:
        # `both` is kept for every host: it is the manifests' word for "this
        # machine too", so `--host vps` means vps-only PLUS both. Filtering
        # `--host both` therefore selects exactly the units every machine has,
        # which is the same rule applied to itself rather than a special case.
        units = [u for u in units if u.host in (host, "both")]
    for value in unit_values(units, field):
        _emit(value)
    if unreadable:
        print(  # noqa: T201
            f"doctor.py: unreadable manifest(s): {', '.join(sorted(unreadable))} — "
            f"this projection is missing whatever they declare",
            file=sys.stderr,
        )
        return 1
    return 0


# ---------------------------------------------------------------- pai secrets --
#
# THE ROSTER IS THE MANIFESTS. Before #39 the Mac's roster was a nine-name
# string at keychain-secrets.sh:12 with a `case` of hints beside it whose
# default arm was `echo ""`, and it prompted for every name on every run --
# including a Telegram bot token for a gateway that only ever runs on the brain.
# This projection replaces both: one row per key, carrying the manifest's own
# `prompt`, restricted to the units a machine actually has.
#
# `--host` NAMES THE STORE, NOT THE UNIT'S HOST. A vps-hosted unit can still
# need a value in the Mac's Keychain -- `brain`'s GOOSE_SERVER__SECRET_KEY is
# minted on the brain and transcribed into the Mac client -- so filtering by
# `unit.host` here would drop exactly the rows a laptop needs.
HOST_STORES = {"mac": "mac_keychain", "vps": "vps"}

# What a machine has when nobody said otherwise: every base unit plus every
# default_on one. NOT "tier: base" -- bootstrap-mac.sh installs opencode and
# coding-pack too, so a base-only rule would leave a default install short.
DEFAULT_TIERS = frozenset({"base", "default_on"})

# key, required-or-optional, the generate command or "-", and the prompt.
# TAB-separated because the only consumer is a bash `read -r` loop on macOS's
# bash 3.2, and check-units.sh forbids a tab inside a prompt so the last column
# cannot be split by accident.
ROSTER_ROW = "{key}\t{need}\t{generate}\t{prompt}"


def select_units(units: list[Unit], names: list[str]) -> tuple[list[Unit], int]:
    """Return the units to project over: an explicit list, or the default set."""
    if not names:
        return ([u for u in units if u.tier in DEFAULT_TIERS], 0)
    known = {u.id: u for u in units}
    unknown = [name for name in names if name not in known]
    if unknown:
        print(  # noqa: T201
            f"doctor.py: unknown unit(s): {', '.join(unknown)}", file=sys.stderr,
        )
        # Loudly, because the alternative is an empty roster: a typo'd
        # `--units googl-workspace` that prompted for nothing would read as
        # "this add-on needs no secrets" and be believed.
        return ([], 2)
    return ([known[name] for name in names], 0)


def roster(units: list[Unit], store: str) -> list[Secret]:
    """Every distinct key those units keep in `store`, sorted, one row per key.

    De-duplication is by KEY, and it takes the first row in id order: two rows
    for one (key, store) pair must already agree on prompt and generate, which
    check-units.sh asserts. `optional` is the AND of the rows -- a key that any
    selected unit requires is required.
    """
    found: dict[str, Secret] = {}
    for unit in units:
        for entry in unit.secrets:
            if entry.store != store:
                continue
            first = found.get(entry.key)
            if first is None or (first.optional and not entry.optional):
                found[entry.key] = entry
    return [found[key] for key in sorted(found)]


def secrets(repo: Path, flags: list[str]) -> int:
    """`pai secrets --host <mac|vps> [--units a,b,c | --all]`.

    Writes nothing and speaks to nothing: it reads config/units/ and prints. The
    consumer is scripts/mac/keychain-secrets.sh, which calls it twice -- once for
    the selection it prompts for, once with --all for the ~/.zshrc export block.
    """
    host = ""
    names: list[str] = []
    take_all = False
    rest = list(flags)
    while rest:
        flag = rest.pop(0)
        if flag in {"--host", "--units"} and rest:
            value = rest.pop(0)
            if flag == "--host":
                host = value
            else:
                names = [name for name in value.replace(",", " ").split() if name]
        elif flag == "--all":
            take_all = True
        else:
            print(f"doctor.py: bad option {flag!r}", file=sys.stderr)  # noqa: T201
            return 2
    if host not in HOST_STORES:
        print(  # noqa: T201
            f"doctor.py: secrets needs --host {'|'.join(sorted(HOST_STORES))}"
            f"{f' (got {host!r})' if host else ''}",
            file=sys.stderr,
        )
        return 2
    if take_all and names:
        print(  # noqa: T201
            "doctor.py: --all and --units contradict each other", file=sys.stderr,
        )
        return 2
    units, _ = load_units(repo)
    if take_all:
        chosen, rc = units, 0
    else:
        chosen, rc = select_units(units, names)
    if rc:
        return rc
    for entry in roster(chosen, HOST_STORES[host]):
        _emit(ROSTER_ROW.format(
            key=entry.key,
            need="optional" if entry.optional else "required",
            generate=entry.generate or "-",
            prompt=entry.prompt,
        ))
    return 0


# Exactly the flags `doctor` accepts. An unknown one is a usage error rather
# than a silently ignored word: `pai doctor --fx` must not read as a plain,
# harmless `pai doctor`, and `pai doctor --fix --dry-run` must not read as a
# write.
DOCTOR_FLAGS = frozenset({"--fix", "--dry-run", "--migrate-envs"})


def doctor(repo: Path, home: Path, flags: list[str]) -> int:
    """`pai doctor [--dry-run|--fix [--migrate-envs]]`.

    THE DEFAULT IS READ-ONLY AND STAYS READ-ONLY. Mutation needs `--fix`
    spelled out; `--dry-run` is the same plan with the writing removed, and it
    wins when both are given -- the conservative reading of a contradictory
    command line is the one that does not touch anything.
    """
    unknown = [f for f in flags if f not in DOCTOR_FLAGS]
    if unknown:
        print(f"doctor.py: unknown option {unknown[0]!r}", file=sys.stderr)  # noqa: T201
        return 2
    fixing, dry = "--fix" in flags, "--dry-run" in flags
    if not fixing and not dry:
        if "--migrate-envs" in flags:
            print(  # noqa: T201
                "doctor.py: --migrate-envs only means something with --fix", file=sys.stderr,
            )
            return 2
        return report(collect(repo, home))
    return fix(repo, home, dry_run=dry, migrate_envs="--migrate-envs" in flags)


def main(argv: list[str]) -> int:
    """Dispatch. Exit 0 ok, 1 findings, 2 usage."""
    repo = Path(__file__).resolve().parents[2]
    home = Path(os.environ.get("PAI_HOME", str(Path.home())))
    command = argv[1] if len(argv) > 1 else ""
    if command == "doctor":
        return doctor(repo, home, argv[2:])
    if command == "status":
        return inventory(repo, home)
    if command == "list":
        return catalogue(repo)
    if command == "units":
        return projection(repo, argv[2:])
    if command == "secrets":
        return secrets(repo, argv[2:])
    print(f"doctor.py: unknown command {command!r}", file=sys.stderr)  # noqa: T201
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
