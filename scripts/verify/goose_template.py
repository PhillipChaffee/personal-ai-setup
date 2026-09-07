#!/usr/bin/env python3
"""goose_template.py — assemble config/goose/config.yaml, and prove the assembly.

config/goose/config.yaml is now a GENERATED, COMMITTED artifact. Its sources are
config/goose/config.base.yaml plus config/goose/extensions.d/*.yaml, one file
per extension, and its bytes are exactly compose(base, fragments).

WHY THE GENERATED FILE STAYS COMMITTED. Five tracked scripts read that path
(bootstrap-mac.sh's copy_no_clobber, deploy-vps.sh's install_template and its
diff remedy, pin-models.sh's model grep, check-security.sh's diff remedy),
doctor.py loads it twice, and test-pai.sh builds its fixture from it. Deleting
it would turn a four-file split into an installer rewrite. pin-models.sh is the
sharp one: its grep carries `2>/dev/null`, so a vanished config.yaml would make
it assert NOTHING and still exit 0. Sources of truth move; the path does not,
and every consumer is a no-op change.

WHY AN EXPLICIT ORDER. FRAGMENT_ORDER is a hand-written tuple, not
sorted(glob): sorted() yields playwright/tavily/todoist/workspace-mcp, which
composes a different — still valid, still byte-different — file. Adding a
connector is therefore a deliberate two-line act (drop the fragment in, name it
here), and the roster check below refuses any fragment this tuple does not name.

WHY NOT DEDENT THE FRAGMENTS. Each fragment is `extensions:` followed by its
slice of the original file VERBATIM, at the original two-space indent. Restoring
the root key is what makes the slice a legal document; dedenting it would
rewrite the leading whitespace of every comment inside and forfeit the
byte-identity this whole gate rests on. Verified: yamllint --strict is clean on
the fragments as written.

THE SIX ASSERTIONS, and what each one catches that the others do not:

  1. compose(...) == config/goose/config.yaml, byte for byte. Pins comment
     count, indentation, location AND fragment order in a single comparison.
     This is the "every comment survives exactly once" proof.
  2. the comment-token MULTISET over the sources equals the one over the
     generated file. Redundant with (1) today, by construction — and it is
     what survives the first time somebody legitimately edits a fragment and
     regenerates, which is the moment (1) stops being interesting.
  3. per-file comment-token counts. Multiset equality alone permits sliding a
     comment block across a fragment boundary; only a per-file count notices.
  4. each fragment declares exactly one key under `extensions:`, and the file
     stem equals that key. yamllint's key-duplicates cannot see across files.
  5. no extension key is declared twice — by two fragments, or by the base and
     a fragment. Same hole as (4), other direction.
  6. a fragment whose entry has no non-empty snake_case `available_tools` must
     carry `enabled: false`. playwright and tavily ship with their allowlists
     commented out; this is the install-path counterpart of the ACP refusal, so
     the rule cannot be honoured on one path and bypassed on the other.

    scripts/verify/check-goose-template.sh            # --check, what CI runs
    scripts/verify/check-goose-template.sh --write    # regenerate config.yaml
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter
from pathlib import Path
from typing import Final

import yaml

# The extension fragments, in the order they are concatenated. NOT sorted(glob)
# — see the module docstring.
FRAGMENT_ORDER: Final[tuple[str, ...]] = ("workspace-mcp", "todoist", "playwright", "tavily")

# Assertion 3's location pin. These are measured, not guessed: run --check and
# the failure line prints the actual counts, so a deliberate move of a comment
# block is a one-number edit with the new number handed to you. Their sum is
# not written down anywhere — assertion 2 derives it from the generated file.
EXPECTED_COMMENT_TOKENS: Final[dict[str, int]] = {
    "config.base.yaml": 62,
    "workspace-mcp.yaml": 76,
    "todoist.yaml": 38,
    "playwright.yaml": 16,
    "tavily.yaml": 7,
}

# The root key every fragment restores so its slice is a legal YAML document.
FRAGMENT_ROOT: Final = "extensions:"

# Derived from __file__, never from the cwd: data-lint.yml's negative tests run
# a COPY of the tree out of $RUNNER_TEMP and must validate that copy, leaving
# the checkout untouched. Same rule check-connectors.sh applies to its own
# CONNECTOR_DIR.
REPO_ROOT: Final = Path(__file__).resolve().parents[2]
GOOSE_DIR: Final = REPO_ROOT / "config" / "goose"
BASE_PATH: Final = GOOSE_DIR / "config.base.yaml"
FRAGMENT_DIR: Final = GOOSE_DIR / "extensions.d"
GENERATED_PATH: Final = GOOSE_DIR / "config.yaml"

_QUOTES: Final = "\"'"


def read_exact(path: Path) -> str:
    """Decode a file with NO newline translation, so `==` really compares bytes.

    Path.read_text() opens in text mode with newline=None, i.e. universal
    newlines: CRLF and lone CR are rewritten to LF before the caller sees a
    character. Assertion 1 would then call a CRLF config.yaml identical to the
    LF sources. Measured before this helper existed: converting the artifact to
    CRLF took it from 14884 to 15202 bytes and the "byte for byte" check still
    exited 0 — the one assertion the whole PR rests on, inert. Decoding the
    bytes ourselves keeps every line ending inside the comparison. (Python 3.13
    grew a `newline=` argument for read_text; mypy.ini pins 3.12.)
    """
    return path.read_bytes().decode("utf-8")


def nbytes(text: str) -> int:
    """UTF-8 length, because len() counts CHARACTERS and this file is not ASCII.

    config.yaml carries 28 multi-byte characters (26 em dashes, a section sign,
    an ellipsis): 14829 characters over 14884 bytes. A gate whose entire claim
    is byte-identity must not print a character count next to the word "bytes"
    — the 55-byte gap is exactly the size of an edit it would be reporting on.
    """
    return len(text.encode("utf-8"))


def emit(line: str) -> None:
    print(line)  # noqa: T201 -- this IS the reporting surface


# The three line shapes check-goose-template.sh counts, spelled exactly as
# lib.sh spells them for shell: two words and a two-space gutter, so one grep
# finds every verdict in the repo and the continuation lines never move a total.
def ok(text: str) -> str:
    return f"PASS  {text}"


def bad(text: str) -> str:
    return f"FAIL  {text}"


def cont(text: str) -> str:
    return f"      {text}"


def comment_tokens(text: str) -> list[str]:
    """Return the RAW LINE of every line carrying a YAML comment, in order.

    Keyed on the whole raw line, leading whitespace included, for two reasons.
    Indentation is part of what "verbatim" means here, so a re-indented comment
    must read as a different token. And one line yields at most one token,
    which is what keeps `# available_tools: [...]   # REQUIRED ...` (present in
    both playwright.yaml and tavily.yaml) from being counted twice — a naive
    scan for `#` reports 201 tokens where this reports 199.

    A `#` only opens a comment in YAML at the start of a line or after
    whitespace, and never inside a quoted scalar, so the scanner tracks quotes
    rather than splitting on the character.
    """
    tokens: list[str] = []
    for line in text.splitlines():
        quote: str | None = None
        for i, char in enumerate(line):
            if quote is not None:
                if char == quote:
                    quote = None
            elif char in _QUOTES:
                quote = char
            elif char == "#" and (i == 0 or line[i - 1] in " \t"):
                tokens.append(line)
                break
    return tokens


def fragment_path(name: str) -> Path:
    return FRAGMENT_DIR / f"{name}.yaml"


def fragment_body(text: str) -> str:
    """Strip a fragment's restored `extensions:` root, leaving the slice."""
    head, _, body = text.partition("\n")
    return body if head == FRAGMENT_ROOT else text


def compose(base_text: str, bodies: list[str]) -> str:
    """Join the base and each fragment body, in FRAGMENT_ORDER.

    Every piece already ends in a newline, so joining the pieces on one more
    newline reproduces the single blank line that separated each extension
    block in the original file. That blank line is a separator, not content:
    config.base.yaml ends at `enabled: false` and each fragment body starts at
    its own leading comment.
    """
    return base_text + "\n" + "\n".join(bodies)


def compose_from_sources(base_text: str, fragments: dict[str, str]) -> str:
    return compose(base_text, [fragment_body(fragments[n]) for n in FRAGMENT_ORDER])


def extension_entries(text: str) -> dict[str, object]:
    """Return the mapping under a document's `extensions:` key, or {} if absent.

    safe_load, like everywhere else in this repo. yamllint's key-duplicates rule
    is what stops the silent last-one-wins behaviour this would otherwise hide.
    """
    doc = yaml.safe_load(text)
    if not isinstance(doc, dict):
        return {}
    entries = doc.get("extensions")
    if not isinstance(entries, dict):
        return {}
    return {str(key): value for key, value in entries.items()}


def has_allowlist(entry: object) -> bool:
    """Report whether the entry carries a non-empty snake_case `available_tools`.

    Snake_case only, deliberately: goose accepts a camelCase `availableTools`
    on the ACP wire and then stores NO allowlist at all, so a camelCase key
    here would read as a narrowed extension while shipping the whole surface.
    """
    if not isinstance(entry, dict):
        return False
    allow = entry.get("available_tools")
    return isinstance(allow, list) and bool(allow)


def is_disabled(entry: object) -> bool:
    return isinstance(entry, dict) and entry.get("enabled") is False


# --------------------------------------------------------------- assertions --
# Each returns the failure lines for one assertion — empty means it passed.
# Continuation lines carry the remedy, in this repo's verify-script shape.


def check_bytes(composed: str, generated: str) -> list[str]:
    if composed == generated:
        return []
    # The two sizes alone are not enough to act on: a line-ending change, or any
    # edit that swaps as much as it adds, prints two identical numbers under a
    # "these differ" headline. The line number of the first divergence is what
    # the reader actually needs, so compute it rather than making them diff.
    # split("\n"), not splitlines(): splitlines() also breaks on \r, which would
    # make a CR-only artifact line up perfectly against the LF sources and report
    # the difference as "past the end". Splitting on \n alone leaves a stray \r
    # attached to the line that carries it, where it shows up as a difference.
    want, have = composed.split("\n"), generated.split("\n")
    first = next(
        (i for i, (a, b) in enumerate(zip(want, have, strict=False), start=1) if a != b),
        min(len(want), len(have)) + 1,
    )
    return [
        bad("config/goose/config.yaml is not compose(config.base.yaml, extensions.d/*)"),
        cont("It is generated. Edit the sources, then regenerate:"),
        cont("  scripts/verify/check-goose-template.sh --write"),
        cont(f"composed {nbytes(composed)} bytes, on disk {nbytes(generated)}"),
        cont(f"first difference at line {first}"),
    ]


def check_comment_multiset(sources: list[str], generated: str) -> list[str]:
    want = Counter(comment_tokens(generated))
    got: Counter[str] = Counter()
    for text in sources:
        got.update(comment_tokens(text))
    if got == want:
        return []
    lost = want - got
    gained = got - want
    lines = [
        bad("comment tokens differ between the sources and config/goose/config.yaml"),
        cont(f"{sum(want.values())} in the generated file, {sum(got.values())} in the sources"),
    ]
    lines += [cont(f"only in config.yaml: {token!r}") for token in sorted(lost)]
    lines += [cont(f"only in the sources: {token!r}") for token in sorted(gained)]
    return lines


def check_comment_locations(texts: dict[str, str]) -> list[str]:
    counts = {name: len(comment_tokens(text)) for name, text in texts.items()}
    if counts == EXPECTED_COMMENT_TOKENS:
        return []
    lines = [
        bad("per-file comment-token counts moved — a comment block changed file"),
        cont("If that was deliberate, update EXPECTED_COMMENT_TOKENS in"),
        cont("scripts/verify/goose_template.py to the measured counts below."),
    ]
    for name in sorted(set(counts) | set(EXPECTED_COMMENT_TOKENS)):
        want = EXPECTED_COMMENT_TOKENS.get(name)
        got = counts.get(name)
        if want != got:
            lines.append(cont(f"{name}: expected {want}, measured {got}"))
    return lines


def check_fragment_keys(fragments: dict[str, dict[str, object]]) -> list[str]:
    lines: list[str] = []
    for name in FRAGMENT_ORDER:
        keys = sorted(fragments[name])
        if keys == [name]:
            continue
        lines.append(
            bad(f"extensions.d/{name}.yaml must declare exactly one extension named {name!r}"),
        )
        lines.append(cont(f"it declares: {keys or '(nothing)'}"))
    return lines


def check_unique_keys(
    base: dict[str, object],
    fragments: dict[str, dict[str, object]],
) -> list[str]:
    owners: dict[str, list[str]] = {}
    for key in base:
        owners.setdefault(key, []).append("config.base.yaml")
    for name in FRAGMENT_ORDER:
        for key in fragments[name]:
            owners.setdefault(key, []).append(f"extensions.d/{name}.yaml")
    lines: list[str] = []
    for key, files in sorted(owners.items()):
        if len(files) > 1:
            lines.append(bad(f"extension {key!r} is declared by {len(files)} files"))
            lines.append(cont(f"{', '.join(files)}"))
    return lines


def check_allowlist_or_disabled(fragments: dict[str, dict[str, object]]) -> list[str]:
    lines: list[str] = []
    for name in FRAGMENT_ORDER:
        for key, entry in sorted(fragments[name].items()):
            if has_allowlist(entry) or is_disabled(entry):
                continue
            lines.append(bad(f"{key} is enabled with no non-empty snake_case available_tools"))
            lines.append(cont("An extension with no allowlist may call EVERY tool its server"))
            lines.append(cont("registers. Derive the real list rather than guessing:"))
            # --smoke takes a CONNECTOR MANIFEST id, which is not the extension
            # key: workspace-mcp's manifest is config/connectors/google-workspace
            # .yaml, and playwright and tavily have no manifest at all. Printing
            # `--smoke playwright` would hand the reader a command that answers
            # "no manifest for id 'playwright'" — so say <id>, exactly as the
            # fragments' own comments do, and name the fallback.
            lines.append(cont("  scripts/verify/check-connectors.sh --smoke <id>"))
            lines.append(cont("using this extension's id in config/connectors/, or a raw"))
            lines.append(cont("tools/list against its server if it has no manifest."))
            lines.append(cont(f"Otherwise set `enabled: false` in extensions.d/{name}.yaml."))
    return lines


# ------------------------------------------------------------------- driver --


def check_roster() -> list[str]:
    """Refuse a fragment FRAGMENT_ORDER does not name, and vice versa.

    Without this, dropping a file into extensions.d/ would be silently ignored
    — it would lint clean, sit in the tree, and never reach a machine.
    """
    if not FRAGMENT_DIR.is_dir():
        return [bad(f"missing directory: {FRAGMENT_DIR}")]
    on_disk = {path.stem for path in FRAGMENT_DIR.glob("*.yaml")}
    named = set(FRAGMENT_ORDER)
    if on_disk == named:
        return []
    lines = [bad("extensions.d/ does not match FRAGMENT_ORDER")]
    if on_disk - named:
        lines.append(cont(f"on disk but unnamed: {sorted(on_disk - named)}"))
        lines.append(cont("add it to FRAGMENT_ORDER in scripts/verify/goose_template.py"))
    if named - on_disk:
        lines.append(cont(f"named but missing: {sorted(named - on_disk)}"))
    return lines


def run_checks() -> list[str]:
    """Every failure line from all six assertions; empty means all six passed."""
    roster = check_roster()
    if roster:
        # Nothing downstream can compose or parse a roster we do not trust.
        return roster

    base_text = read_exact(BASE_PATH)
    fragment_texts = {n: read_exact(fragment_path(n)) for n in FRAGMENT_ORDER}
    generated = read_exact(GENERATED_PATH)

    base_entries = extension_entries(base_text)
    fragment_entries = {n: extension_entries(t) for n, t in fragment_texts.items()}

    by_file = {BASE_PATH.name: base_text}
    by_file.update({fragment_path(n).name: t for n, t in fragment_texts.items()})

    lines: list[str] = []
    lines += check_bytes(compose_from_sources(base_text, fragment_texts), generated)
    lines += check_comment_multiset(list(by_file.values()), generated)
    lines += check_comment_locations(by_file)
    lines += check_fragment_keys(fragment_entries)
    lines += check_unique_keys(base_entries, fragment_entries)
    lines += check_allowlist_or_disabled(fragment_entries)
    return lines


def do_check() -> int:
    lines = run_checks()
    if lines:
        for line in lines:
            emit(line)
        return 1
    emit(ok("config/goose/config.yaml is compose(config.base.yaml, extensions.d/*), byte for byte"))
    emit(ok("every comment token survives, in exactly one source file"))
    emit(ok("each fragment declares one extension, named after the file, declared nowhere else"))
    emit(ok("every fragment without a non-empty available_tools ships disabled"))
    return 0


def do_write() -> int:
    roster = check_roster()
    if roster:
        for line in roster:
            emit(line)
        return 1
    base_text = read_exact(BASE_PATH)
    fragments = {n: read_exact(fragment_path(n)) for n in FRAGMENT_ORDER}
    composed = compose_from_sources(base_text, fragments)
    before = read_exact(GENERATED_PATH) if GENERATED_PATH.exists() else None
    # write_bytes, not write_text: write_text's newline=None translates "\n" to
    # os.linesep, so on Windows this would emit an artifact whose bytes are not
    # what it just composed. The read side refuses to normalise; the write side
    # must not introduce anything to normalise.
    GENERATED_PATH.write_bytes(composed.encode("utf-8"))
    verb = "unchanged" if before == composed else "rewritten"
    emit(ok(f"config/goose/config.yaml {verb} ({nbytes(composed)} bytes)"))
    # Regenerating is not the same as being correct: a --write that stopped here
    # would happily emit a file with two `todoist` blocks and call it a success.
    # Assertion 1 is now trivially true, which is exactly why the other five
    # exist — so --write reports the same verdicts CI will.
    return do_check()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="goose_template.py",
        description="Compose config/goose/config.yaml from config.base.yaml + extensions.d/.",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="verify the artifact (default)")
    mode.add_argument("--write", action="store_true", help="regenerate the artifact, then verify")
    args = parser.parse_args(argv)
    return do_write() if args.write else do_check()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
