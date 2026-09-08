#!/usr/bin/env python3
"""docs_lint.py -- render the generated regions of this repo's docs, and prove them.

THE ENGINE, NOT ONE REGION. A generated block with no checker rots faster than a
hand-written one, because it reads as authoritative. So the renderer and the gate
ship together and are the same file: `--check` re-renders every region and
compares it to the committed bytes, `--write` splices the render back in.

Two regions today, both in README.md:

  repo-map    the directory tree, plus the counts the README used to state in
              prose. It said "11 skills" against 12 directories in
              config/skills/ and "the six automations" against 7 files in
              recipes/. Neither number had anywhere to be checked.
  units-menu  one row per config/units/*.yaml: tier, host, summary, what
              installs it, what verifies it. Adding a manifest adds a row.

ADDING A REGION is three things: a renderer, an entry in REGIONS, and markers in
the target file. Nothing else changes -- the marker parser, --check, --write and
check-docs.sh are region-agnostic, and EXTRA_CHECKS is where a region's own
assertions go. That extensibility is deliberate: issue #44 adds regions to
docs/setup/ and docs/automations.md on top of this file rather than minting a
second engine with a second marker syntax.

WHAT DERIVES WHAT, stated here so the region comment in README.md can point at it:

  * the repo map's SHAPE (which paths appear, in which order, with which note)
    is MAP_ENTRIES, hand-written and ordered. Not sorted(glob) -- the same
    argument goose_template.py's FRAGMENT_ORDER docstring makes: a filesystem
    order is a different, still-valid, still-byte-different document, and the
    annotations are prose that no glob can produce.
  * the repo map's COUNTS come from the filesystem, every render.
  * the menu's ROWS come from config/units/*.yaml, ordered by (tier, id) with
    tier in TIER_ORDER -- again not raw sorted(glob), or the render would depend
    on the order the directory happens to enumerate in.

The hand-written half is held honest by A2 (an annotated path must exist) and A3
(a directory child that no map path covers must be added), so "hand-written" does
not mean "unchecked".

THE ASSERTIONS, and what each catches that the others do not:

  A1  every region re-renders to exactly the committed bytes. Catches an added
      skill, a deleted manifest, a changed summary -- anything that moves a
      count or a row. Nothing else here catches those.
  A2  every non-empty MapEntry.path exists. The annotations are STATIC DATA, so
      deleting an annotated doc leaves A1 perfectly green; only A2 sees it.
  A3  every non-ignored direct child of COVERED_DIRS is on the map, or is a
      prefix of something on it. Catches a NEW directory, which A1 and A2 are
      both blind to -- neither knows about a path nobody wrote down.
  A4  every MUST_COUNT directory carries a count_glob and a `{n}` in its note.
      This is the anti-regression for "11 skills": without it, someone
      "simplifies" a note to a literal number and A1 happily compares that
      hand-typed number to itself forever.
  A5  exactly one begin and one end marker per region, in that order, each alone
      on its own line at column 0. Runs FIRST and gates --write: a file with two
      begin markers would otherwise have everything between the first begin and
      the end replaced, silently deleting whatever sat in between.
  A6  no rendered cell contains a bare `|`. units_lint caps a summary's length
      and says nothing about pipes, and one pipe in a summary shifts every
      column of that row.
  A7  every menu unit cell is a plain id or a COMPLETE link. `runbook: ""` is a
      manifest state a human can type, and it renders `[id]()` -- a link that
      lychee reports one job later with a much worse message.
  A8  the two EXTERNALLY REGISTERED permalinks still say what they say, and no
      third file has quietly minted one. BE CLEAR ABOUT WHAT THIS IS: a string
      comparison, not a proof. docs/index.md's `permalink: /` is the GitHub
      Pages landing page and docs/app-privacy-policy.md's `permalink: /privacy/`
      is the URL on a Google OAuth consent screen, and NOTHING IN CI CAN FETCH
      EITHER -- lychee runs --offline. All this asserts is that the two strings
      are unchanged and the inventory is closed, which is enough to turn a
      silent rename into a review conversation and is not enough to tell you the
      page is up.

NOT ASSERTED, deliberately: "every manifest id appears in the menu" and "the row
count equals the manifest count". The renderer globs config/units/, so A1 already
fails on both an added and a removed manifest; a second check over the same glob
would only be able to disagree with itself.

WHY scripts/verify/ AND NOT scripts/pai/. .coveragerc's `source = scripts` omits
scripts/verify/*, and check-coverage.sh applies an 85% per-file floor the instant
a measured file is committed. This file is a CI gate with a shell driver, exactly
like goose_template.py, so it belongs on the exempt side of that line -- it is
still read by ruff (`select = ["ALL"]`) and by `mypy --strict` via mypy.ini.

    scripts/verify/check-docs.sh            # --check, what CI runs
    scripts/verify/check-docs.sh --write    # re-render the regions in place
    scripts/verify/test-docs-lint.sh        # the negative harness for all of it
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Final

import yaml

if TYPE_CHECKING:
    from collections.abc import Callable, Sequence

# Derived from __file__, never from the cwd or `git rev-parse`: test-docs-lint.sh
# runs a COPY of the tree out of a temp directory and must validate that copy. A
# git-derived root would walk back up to the real checkout and validate it
# instead, leaving every negative probe inert while still exiting 0. Same rule
# units_lint.py, goose_template.py and check-connectors.sh apply to their roots.
REPO_ROOT: Final = Path(__file__).resolve().parents[2]
UNITS_DIR: Final = REPO_ROOT / "config" / "units"

# HTML comments, so they are invisible in rendered Markdown. MD033 (inline HTML)
# is off in .markdownlint-cli2.jsonc:25, and these sit OUTSIDE any fenced block
# -- a marker inside a ```text fence renders literally, which is the one place
# this syntax can go wrong.
MARKER_BEGIN: Final = "<!-- pai-docs:begin {name} -->"
MARKER_END: Final = "<!-- pai-docs:end {name} -->"

# A5's expectation, named rather than inlined so the message and the test agree.
MARKERS_PER_REGION: Final = 1

# A3's scope: the directories whose direct children must all be on the map.
# Direct children only -- the map is a map, not a file listing, and
# config/goose/extensions.d/ is named by config/goose/... covering it.
COVERED_DIRS: Final[tuple[str, ...]] = ("", "config", "docs", "scripts")

# Names A3 does not require the map to mention, with the reason for each. Any
# name beginning with "." is skipped too (dotfiles are tooling config; the map
# names the ones worth naming and is not required to name them all).
#
# The build artifacts below are .gitignore'd, are NOT dotfiles, and DO appear at
# the repo root after a local coverage run. A3 walks the FILESYSTEM -- it must,
# because the negative harness runs against a copied tree with no .git -- so it
# cannot ask git what is ignored, and without these it is red on a Mac that has
# ever run coverage locally and green in CI. That split is the worst kind of gate.
MAP_IGNORE: Final[dict[str, str]] = {
    "node_modules": "npm ci artifact, .gitignore'd",
    "package-lock.json": "the lockfile package.json's own map entry names",
    "__pycache__": "interpreter artifact",
    "coverage.json": "coverage artifact",
    "coverage.xml": "coverage artifact",
    "lcov.info": "coverage artifact",
    "htmlcov": "coverage artifact",
}

# A4's roster: directories whose SIZE is a fact the README states. Every one of
# these must carry a count_glob and a `{n}` placeholder, so the number can only
# ever come from the tree. This set is the answer to "11 skills".
MUST_COUNT: Final[frozenset[str]] = frozenset({
    "config/connectors",
    "config/goose/extensions.d",
    "config/opencode/agents",
    "config/skills",
    "config/units",
    "docs/setup",
    "recipes",
    "scripts/verify",
})

# A8's frozen inventory: every permalink this repo has handed to something
# outside it. `/` is the GitHub Pages landing page; `/privacy/` is registered on
# a Google OAuth consent screen, where a 404 is a verification risk rather than a
# docs nit. Adding a third entry here is the deliberate act of publishing a URL.
PERMALINKS: Final[dict[str, str]] = {
    "docs/index.md": "/",
    "docs/app-privacy-policy.md": "/privacy/",
}

PERMALINK_RE: Final = re.compile(r"^permalink:\s*(\S.*?)\s*$", re.MULTILINE)

# The menu's row order. `sorted()` over the tier STRINGS would give
# base, default_on, opt_in by luck of the alphabet; this says it on purpose, so
# renaming a tier cannot silently reorder the table.
TIER_ORDER: Final[tuple[str, ...]] = ("base", "default_on", "opt_in")

MENU_HEADER: Final[tuple[str, ...]] = (
    "Add-on", "Tier", "Host", "What it is", "Installed by", "Verified by",
)

# A7's shape. Both groups are `+`, not `*`: `[](x)` and `[x]()` must NOT match.
MENU_LINK_RE: Final = re.compile(r"^\[[^\]]+\]\([^)]+\)$")


@dataclass(frozen=True)
class MapEntry:
    """One line of the repo map.

    `label` is what is printed (the map flattens `goose/config.yaml` onto one
    line rather than nesting it, exactly as the hand-written map did); `path` is
    the repo-relative thing that must actually exist. They differ on purpose, and
    A2 checks the path rather than the label because only one of them is a fact.
    """

    depth: int
    label: str
    path: str = ""
    note: str = ""
    count_glob: str | None = None


def row(depth: int, label: str, path: str = "", note: str = "",
        glob: str | None = None) -> MapEntry:
    return MapEntry(depth=depth, label=label, path=path, note=note, count_glob=glob)


# THE MAP. Hand-written and ordered -- see the module docstring. Every `{n}` is
# filled from the filesystem at render time; every `path` is checked by A2; every
# direct child of COVERED_DIRS must be covered by some `path` (A3).
MAP_ENTRIES: Final[tuple[MapEntry, ...]] = (
    row(0, "."),
    row(1, "README.md", "README.md", "you are here: install, the add-on menu, the budget"),
    row(1, "LICENSE", "LICENSE", "MIT"),
    row(1, "bin/pai", "bin/pai",
        "the one entry point: doctor, status, list, units, verify, docs"),
    row(1, ".gitignore", ".gitignore",
        "keeps secrets, tfstate/tfvars, OAuth tokens out of a public repo"),
    row(1, ".pre-commit-config.yaml", ".pre-commit-config.yaml",
        "gitleaks, ruff, yamllint, shellcheck before every commit"),
    row(1, ".github/workflows/", ".github/workflows",
        "the CI gates: secret scan, lint, types, coverage, install tests"),
    row(1, ".coveragerc", ".coveragerc", "coverage scope and the project floor"),
    row(1, ".markdownlint-cli2.jsonc", ".markdownlint-cli2.jsonc", "markdownlint config"),
    row(1, "lychee.toml", "lychee.toml", "the offline link and anchor checker's config"),
    row(1, "mypy.ini", "mypy.ini", "the --strict roster; every tracked .py is on it"),
    row(1, "ruff.toml", "ruff.toml", "ruff with every rule on; exceptions justified in place"),
    row(1, "package.json", "package.json", "markdownlint-cli2 only, pinned by package-lock.json"),
    row(1, "docs/", "docs"),
    row(2, "index.md", "docs/index.md",
        "the GitHub Pages landing page (LOAD-BEARING EXTERNALLY)"),
    row(2, "app-privacy-policy.md", "docs/app-privacy-policy.md",
        "the URL on the Google OAuth consent screen (LOAD-BEARING EXTERNALLY)"),
    row(2, "_config.yml", "docs/_config.yml", "Jekyll config for those two pages"),
    row(2, "setup/", "docs/setup", "{n} runbooks, in order; START at 00-overview.md", "*.md"),
    row(2, "connecting.md", "docs/connecting.md", "adding a connector, end to end"),
    row(2, "model-routing.md", "docs/model-routing.md",
        "which model for which job + hard privacy rules"),
    row(2, "privacy.md", "docs/privacy.md",
        "data classification per provider tier; encryption model and residual risk"),
    row(2, "automations.md", "docs/automations.md",
        "add/manage scheduled workflows; scheduler-bug fallback flip"),
    row(2, "code-agents.md", "docs/code-agents.md",
        "code agents: per-chat containers, lifecycle, git/permission model"),
    row(2, "providers.md", "docs/providers.md",
        "email/calendar provider convention (multi-account today, more next)"),
    row(2, "cursor-port.md", "docs/cursor-port.md",
        "the Cursor kit ported to Goose + OpenCode: what went where and why"),
    row(2, "security.md", "docs/security.md",
        "threat model, LUKS design, Tailscale-only exposure, serve TLS/secret"),
    row(2, "public-repo.md", "docs/public-repo.md",
        "what may/may-not be committed; go-public checklist"),
    row(2, "troubleshooting.md", "docs/troubleshooting.md",
        "base_url 404s, scheduler bugs, pairing, LUKS, rate limits"),
    row(2, "roadmap.md", "docs/roadmap.md", "SearXNG, memory, budgeting-app API, vault RAG"),
    row(1, "infra/terraform/", "infra/terraform",
        "Hetzner server, deny-all firewall, encrypted volume, cloud-init"),
    row(1, "config/", "config"),
    row(2, "units/", "config/units",
        "{n} unit manifests — the add-on menu above is rendered from these", "*.yaml"),
    row(2, "pins.yaml", "config/pins.yaml",
        "the versions the installers pin and the checks compare against"),
    row(2, "goose/config.yaml", "config/goose/config.yaml",
        "GENERATED from config.base.yaml + extensions.d/"),
    row(2, "goose/extensions.d/", "config/goose/extensions.d",
        "{n} MCP extension fragments, one file each", "*.yaml"),
    row(2, "goose/custom_providers/", "config/goose/custom_providers",
        "together (DEFAULT), zen-openai, zen-anthropic, zen-free (trains on data)"),
    row(2, "goose/goosehints.example", "config/goose/goosehints.example",
        "identity, routing rules, vault path, PHI standing rules"),
    row(2, "goose/acp-contract.json", "config/goose/acp-contract.json",
        "the captured ACP method list check-connectors.sh asserts against"),
    row(2, "opencode/opencode.json", "config/opencode/opencode.json",
        "OpenCode: Zen models + Together provider, cheap small_model"),
    row(2, "opencode/AGENTS.md", "config/opencode/AGENTS.md",
        "global coding/workflow rules template"),
    row(2, "opencode/agents/", "config/opencode/agents",
        "{n} review/research subagents", "*.md"),
    row(2, "opencode/project-rules/", "config/opencode/project-rules",
        "per-project rule snippets (python, django, linear…) — paste-in"),
    row(2, "skills/", "config/skills",
        "{n} skills, Claude-compatible SKILL.md (→ ~/.agents/skills)"
        " — read by BOTH OpenCode and goose", "*/SKILL.md"),
    row(2, "connectors/", "config/connectors",
        "{n} connector manifests + the contract in that directory's README", "*.yaml"),
    row(2, "code-agents/", "config/code-agents",
        "the code-agent image, per-chat opencode config, repo-allowlist template"),
    row(2, "mcp/workspace-mcp.env.example", "config/mcp/workspace-mcp.env.example",
        "Google Workspace MCP env template"),
    row(2, "env/secrets.env.example", "config/env/secrets.env.example",
        "every secret VAR NAME (no values) — copy to /data/secrets.env"),
    row(1, "recipes/", "recipes",
        "{n} goose recipes; which of them are scheduled is docs/automations.md's table",
        "*.yaml"),
    row(1, "scripts/", "scripts"),
    row(2, "pai/", "scripts/pai", "the `pai` dispatcher, doctor, goosecfg"),
    row(2, "mac/", "scripts/mac", "bootstrap-mac.sh, keychain-secrets.sh"),
    row(2, "vps/", "scripts/vps",
        "deploy-vps.sh, LUKS setup/unlock, schedule registration, systemd units"),
    row(2, "common/", "scripts/common",
        "run-recipe.sh (failure watchdog), notify.sh (alerts to ntfy's email gateway)"),
    row(2, "sync-models.sh", "scripts/sync-models.sh",
        "refresh provider model lists from the live Zen/Together catalogs"),
    row(2, "verify/", "scripts/verify",
        "{n} check-*.sh, plus the harnesses and the fakes they drive", "check-*.sh"),
    row(1, "vault-template/", "vault-template",
        "skeleton for the SEPARATE PRIVATE vault repo — no real data here"),
)


# --------------------------------------------------------------------- output --


def emit(line: str) -> None:
    print(line)  # noqa: T201 -- this IS the reporting surface


# The three line shapes check-docs.sh counts, spelled exactly as lib.sh spells
# them for shell: two words and a two-space gutter, so one grep finds every
# verdict in the repo and continuation lines never move a total.
def ok(text: str) -> str:
    return f"PASS  {text}"


def bad(text: str) -> str:
    return f"FAIL  {text}"


def cont(text: str) -> str:
    return f"      {text}"


def read_exact(path: Path) -> str:
    """Decode a file with NO newline translation, so `==` really compares bytes.

    Path.read_text() opens with newline=None, i.e. universal newlines: CRLF is
    rewritten to LF before the caller sees a character, and A1 would then call a
    CRLF README identical to an LF render. This repo has shipped that exact bug
    once already -- see goose_template.read_exact, whose measurement is the
    reason this helper is copied rather than skipped.
    """
    return path.read_bytes().decode("utf-8")


# ----------------------------------------------------------------- the map ----


def _is_last(depths: Sequence[int], index: int) -> bool:
    """Report whether nothing after `index` is a sibling of it."""
    for later in depths[index + 1:]:
        if later < depths[index]:
            return True
        if later == depths[index]:
            return False
    return True


def _prefix(depths: Sequence[int], lasts: Sequence[bool], index: int) -> str:
    """Build one entry's box-drawing gutter: a cell per ancestor, then a tee."""
    depth = depths[index]
    if depth == 0:
        return ""
    parts: list[str] = []
    for level in range(1, depth):
        ancestor = next((j for j in range(index - 1, -1, -1) if depths[j] == level), None)
        parts.append("    " if ancestor is None or lasts[ancestor] else "│   ")
    parts.append("└── " if lasts[index] else "├── ")
    return "".join(parts)


def count_for(entry: MapEntry) -> int | None:
    if entry.count_glob is None:
        return None
    return len(list((REPO_ROOT / entry.path).glob(entry.count_glob)))


def note_for(entry: MapEntry) -> str:
    count = count_for(entry)
    return entry.note if count is None else entry.note.replace("{n}", str(count))


def map_lines() -> list[str]:
    depths = [e.depth for e in MAP_ENTRIES]
    lasts = [_is_last(depths, i) for i in range(len(depths))]
    stems = [_prefix(depths, lasts, i) + e.label for i, e in enumerate(MAP_ENTRIES)]
    width = max((len(s) for s, e in zip(stems, MAP_ENTRIES, strict=True) if e.note), default=0)
    return [
        stem if not e.note else f"{stem.ljust(width)}  # {note_for(e)}"
        for stem, e in zip(stems, MAP_ENTRIES, strict=True)
    ]


def render_repo_map() -> str:
    return block(["```text", *map_lines(), "```"])


# ---------------------------------------------------------------- the menu ----


@dataclass(frozen=True)
class MenuRow:
    uid: str
    cells: tuple[str, ...]


def short_check(entry: str) -> str:
    """`scripts/verify/check-security.sh --local` -> `check-security.sh --local`."""
    head, _, rest = entry.partition(" ")
    name = head.rsplit("/", 1)[-1]
    return f"{name} {rest}".rstrip()


def installer_cell(installer: object) -> str:
    """Say what installs this unit, in the manifest's own two-state vocabulary.

    `status: planned` asserts the function does NOT exist yet (units_lint's P3
    runs that assertion backwards), so the cell must not read as if it does.
    """
    if not isinstance(installer, dict):
        return "by hand"
    script = str(installer.get("script", "")).rsplit("/", 1)[-1]
    if installer.get("status") == "present":
        return f"`{script}`"
    return f"`{script}` (planned)"


def doc_target(runbook: str) -> str:
    """Link to the runbook DOCUMENT, dropping any `#fragment` the manifest carries.

    NOT a style choice, and not laziness. units_lint's slugify() collapses runs
    of hyphens (`re.sub(r"-+", "-", ...)`); GitHub's does not, so a heading like
    `## 3. OpenCode -> Zen`, whose arrow leaves two spaces, anchors as
    `#3-opencode--zen` on GitHub and as `#3-opencode-zen` in units_lint. THIRTEEN
    of this catalog's anchors are wrong on GitHub for that reason (measured
    across all 18 manifests; lychee agrees, and confirms `--` is what resolves).
    Nothing had noticed, because no tracked .md linked to them -- units_lint is
    the only reader, and it validates them against its own slugger.

    Rendering the fragment here would put all thirteen into a file lychee DOES
    read, turning somebody else's bug into this gate's red build. Rendering the
    document is both correct and sufficient: the runbook is a document, and the
    manifest keeps the precise section for `pai list`. Fixing slugify() and
    re-anchoring thirteen references across seven manifests is its own change,
    in its own PR, with its own negative test.
    """
    return runbook.partition("#")[0]


def menu_rows() -> list[MenuRow]:
    rows: list[MenuRow] = []
    for path in sorted(UNITS_DIR.glob("*.yaml")):
        data = yaml.safe_load(read_exact(path))
        if not isinstance(data, dict):
            continue
        uid = str(data.get("id", path.stem))
        runbook = data.get("runbook")
        # `is not None`, never a truth test: `runbook: ""` is a state a human can
        # type, and a truth test would render it as a bare id -- silently
        # discarding exactly the input A7 exists to catch.
        label = uid if runbook is None else f"[{uid}]({doc_target(runbook)})"
        verify = [v for v in (data.get("verify") or []) if isinstance(v, str)]
        rows.append(MenuRow(uid=uid, cells=(
            label,
            str(data.get("tier", "")),
            str(data.get("host", "")),
            str(data.get("summary", "")),
            installer_cell(data.get("installer")),
            ", ".join(f"`{short_check(v)}`" for v in verify) or "—",
        )))
    order = {tier: i for i, tier in enumerate(TIER_ORDER)}
    rows.sort(key=lambda r: (order.get(r.cells[1], len(TIER_ORDER)), r.uid))
    return rows


def render_units_menu() -> str:
    lines = [
        "| " + " | ".join(MENU_HEADER) + " |",
        "|" + "---|" * len(MENU_HEADER),
    ]
    lines += ["| " + " | ".join(r.cells) + " |" for r in menu_rows()]
    return block(lines)


# -------------------------------------------------------------- the regions ---


def block(lines: Sequence[str]) -> str:
    """Wrap a rendered body in the blank lines the region contract requires.

    A region's content starts and ends with a blank line so that the table or
    fence inside it is surrounded by blanks (markdownlint MD031/MD058) even
    though its neighbours are HTML comment lines rather than prose.
    """
    return "\n" + "\n".join(lines) + "\n\n"


@dataclass(frozen=True)
class Region:
    name: str
    doc: str
    render: Callable[[], str]


REGIONS: Final[tuple[Region, ...]] = (
    Region(name="units-menu", doc="README.md", render=render_units_menu),
    Region(name="repo-map", doc="README.md", render=render_repo_map),
)


def region_by_name(name: str) -> Region | None:
    return next((r for r in REGIONS if r.name == name), None)


def marker_complaints(region: Region, text: str) -> list[str]:
    """A5 for one region. Returns [] when the pair is usable by split_region."""
    out: list[str] = []
    for marker in (MARKER_BEGIN.format(name=region.name), MARKER_END.format(name=region.name)):
        found = text.count(marker)
        if found != MARKERS_PER_REGION:
            out.append(bad(f"{region.doc} has {found} '{marker}' markers, "
                           f"expected exactly {MARKERS_PER_REGION}"))
            continue
        at = text.index(marker)
        if (at != 0 and text[at - 1] != "\n") or not text[at + len(marker):].startswith("\n"):
            out.append(bad(f"{region.doc}: '{marker}' must be alone on its own line"))
    if out:
        return out
    begin = text.index(MARKER_BEGIN.format(name=region.name))
    end = text.index(MARKER_END.format(name=region.name))
    if begin > end:
        out.append(bad(f"{region.doc}: the '{region.name}' end marker precedes its begin marker"))
    return out


def split_region(region: Region, text: str) -> tuple[str, str, str]:
    """(before-and-begin-marker, content, end-marker-onwards). A5 must pass first."""
    begin = MARKER_BEGIN.format(name=region.name)
    end = MARKER_END.format(name=region.name)
    head_end = text.index(begin) + len(begin) + 1
    tail_start = text.index(end)
    return text[:head_end], text[head_end:tail_start], text[tail_start:]


# -------------------------------------------------------------- assertions ----


def check_markers() -> list[str]:
    """A5. Also the gate on --write: a malformed pair must never be spliced."""
    out: list[str] = []
    for region in REGIONS:
        path = REPO_ROOT / region.doc
        if not path.is_file():
            out.append(bad(f"{region.doc} does not exist, so its regions cannot be checked"))
            continue
        out += marker_complaints(region, read_exact(path))
    if out:
        return out
    docs = sorted({r.doc for r in REGIONS})
    return [ok(f"{len(REGIONS)} generated region(s) in {', '.join(docs)} are well formed")]


def first_difference(committed: str, rendered: str) -> list[str]:
    """Describe the first line that differs, printed both ways.

    NOT a byte count. The very first stale render this file produced was 5448
    bytes committed against 5448 bytes rendered -- adding check-docs.sh took
    scripts/verify from 10 check-*.sh to 11, and "10" and "11" are the same
    width. A size comparison would have reported "no difference" about a real
    one, and a reader given only two equal numbers learns nothing.
    """
    old = committed.splitlines()
    new = rendered.splitlines()
    for index, (a, b) in enumerate(zip(old, new, strict=False)):
        if a != b:
            return [cont(f"first difference at region line {index + 1}:"),
                    cont(f"  committed: {a}"), cont(f"  rendered:  {b}")]
    verb = "shorter" if len(old) < len(new) else "longer"
    return [cont(f"the committed region is {verb}: {len(old)} lines against {len(new)}")]


def check_regions() -> list[str]:
    """A1, one verdict per region."""
    out: list[str] = []
    for region in REGIONS:
        committed = split_region(region, read_exact(REPO_ROOT / region.doc))[1]
        rendered = region.render()
        if committed == rendered:
            out.append(ok(f"{region.doc} region '{region.name}' is current"))
        else:
            out.append(bad(f"{region.doc} region '{region.name}' is STALE"))
            out.append(cont("run scripts/verify/check-docs.sh --write, then commit the result"))
            out += first_difference(committed, rendered)
    return out


def check_annotated_paths() -> list[str]:
    """A2. The annotations are static data; A1 cannot see one go dangling."""
    out = [
        bad(f"the repo map annotates '{e.path}', which does not exist")
        for e in MAP_ENTRIES
        if e.path and not (REPO_ROOT / e.path).exists()
    ]
    if out:
        return out
    named = sum(1 for e in MAP_ENTRIES if e.path)
    return [ok(f"all {named} paths named on the repo map exist")]


def covered(child: str) -> bool:
    return any(e.path == child or e.path.startswith(child + "/") for e in MAP_ENTRIES)


def check_coverage() -> list[str]:
    """A3. The only assertion that can see a path nobody wrote down."""
    out: list[str] = []
    for parent in COVERED_DIRS:
        base = REPO_ROOT / parent if parent else REPO_ROOT
        for entry in sorted(base.iterdir()):
            name = entry.name
            if name.startswith(".") or name in MAP_IGNORE:
                continue
            child = f"{parent}/{name}" if parent else name
            if not covered(child):
                out.append(bad(f"{child} is not on the repo map"))
                out.append(cont("add a MAP_ENTRIES row for it, or a MAP_IGNORE reason"))
    if out:
        return out
    scope = ", ".join(p or "." for p in COVERED_DIRS)
    return [ok(f"every direct child of {scope} is on the repo map")]


def check_counts() -> list[str]:
    """A4. The anti-regression for a hand-typed count in an authoritative block."""
    by_path = {e.path: e for e in MAP_ENTRIES}
    out: list[str] = []
    for path in sorted(MUST_COUNT):
        entry = by_path.get(path)
        if entry is None:
            out.append(bad(f"the repo map has no row for '{path}', which must carry a count"))
        elif entry.count_glob is None or "{n}" not in entry.note:
            out.append(bad(f"the repo map's note for '{path}' hardcodes a count "
                           f"-- it must be a count_glob and a {{n}} placeholder"))
    if out:
        return out
    return [ok(f"all {len(MUST_COUNT)} counted directories take their count from the tree")]


def check_cells() -> list[str]:
    """A6 and A7, over the menu's cells rather than its rendered string."""
    out: list[str] = []
    for r in menu_rows():
        out += [
            bad(f"units-menu cell {i} for '{r.uid}' contains a bare '|', "
                f"which would shift every column of that row: {cell!r}")
            for i, cell in enumerate(r.cells)
            if "|" in cell
        ]
        if r.cells[0].startswith("[") and not MENU_LINK_RE.match(r.cells[0]):
            out.append(bad(f"units-menu row for '{r.uid}' renders an incomplete link: "
                           f"{r.cells[0]!r}"))
    if out:
        return out
    rows = menu_rows()
    return [
        ok(f"none of the {len(rows) * len(MENU_HEADER)} rendered menu cells contains a bare '|'"),
        ok(f"all {len(rows)} menu rows link to a runbook or name none at all"),
    ]


def check_permalinks() -> list[str]:
    """A8. A NAMING CHECK, NOT A PROOF -- see the module docstring.

    Two halves, and the second is the one that earns its keep: the registered
    files must still declare their registered permalink, AND no other file under
    docs/ may declare one at all. Without the reverse half, a fourth published
    URL appears with nobody having decided to publish it.
    """
    out: list[str] = []
    for rel, want in sorted(PERMALINKS.items()):
        path = REPO_ROOT / rel
        got = PERMALINK_RE.findall(read_exact(path)) if path.is_file() else []
        if got != [want]:
            out.append(bad(f"{rel} must declare exactly one 'permalink: {want}' "
                           f"(it is registered outside this repo); found {got}"))
    for path in sorted((REPO_ROOT / "docs").rglob("*.md")):
        rel = path.relative_to(REPO_ROOT).as_posix()
        if rel in PERMALINKS:
            continue
        found = PERMALINK_RE.findall(read_exact(path))
        out += [
            bad(f"{rel} declares 'permalink: {value}', which is a published URL "
                f"nobody registered -- add it to PERMALINKS or drop it")
            for value in found
        ]
    if out:
        return out
    return [ok(f"the {len(PERMALINKS)} externally registered permalinks are unchanged "
               f"and no other doc declares one")]


# EXTRA_CHECKS is where a region's own assertions live. A new region appends its
# checks here; nothing else in this file has to know about them.
EXTRA_CHECKS: Final[tuple[Callable[[], list[str]], ...]] = (
    check_annotated_paths,
    check_coverage,
    check_counts,
    check_cells,
    check_permalinks,
)


# -------------------------------------------------------------------- modes ---


def do_check() -> int:
    lines = check_markers()
    failed = any(line.startswith("FAIL") for line in lines)
    if not failed:
        lines += check_regions()
    else:
        lines.append(cont("skipping the byte comparison: the markers do not delimit a region"))
    for extra in EXTRA_CHECKS:
        lines += extra()
    for line in lines:
        emit(line)
    return 1 if any(line.startswith("FAIL") for line in lines) else 0


def do_write() -> int:
    """Splice every region, then run the full check over what was written.

    THE MARKER CHECK RUNS FIRST AND REFUSES. With two begin markers in a file,
    splicing between "the first begin" and "the end" deletes everything in
    between -- silently, and in the one file whose whole job is to be
    authoritative. Regenerating is also not the same as being correct, so this
    ends by running do_check(): A1 is trivially true afterwards, which is exactly
    why A2, A3, A4, A6 and A7 exist.
    """
    complaints = check_markers()
    if any(line.startswith("FAIL") for line in complaints):
        for line in complaints:
            emit(line)
        emit(cont("nothing was written"))
        return 1
    for doc in sorted({r.doc for r in REGIONS}):
        path = REPO_ROOT / doc
        text = read_exact(path)
        for region in REGIONS:
            if region.doc != doc:
                continue
            head, _, tail = split_region(region, text)
            text = head + region.render() + tail
        # write_bytes, not write_text: write_text's newline=None translates "\n"
        # to os.linesep, so on Windows this would write a file whose bytes are
        # not what it just rendered -- and A1 refuses to normalise on the way in.
        path.write_bytes(text.encode("utf-8"))
    return do_check()


def do_print(name: str) -> int:
    region = region_by_name(name)
    if region is None:
        emit(bad(f"no such region: {name!r} (have: {', '.join(r.name for r in REGIONS)})"))
        return 2
    sys.stdout.write(region.render())
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="docs_lint.py",
        description="Render and check the generated regions of this repo's docs.",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="verify every region (default)")
    mode.add_argument("--write", action="store_true", help="re-render every region, then verify")
    mode.add_argument("--print", dest="print_region", metavar="NAME",
                      help="write one region's render to stdout and exit")
    args = parser.parse_args(argv)
    if args.print_region:
        return do_print(args.print_region)
    return do_write() if args.write else do_check()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
