#!/usr/bin/env bash
# test-pai.sh — the harness for bin/pai. Establishes the pattern every later
# scripts/pai/*.py owes, because .coveragerc's `source = scripts` plus
# check-coverage.sh's 85% per-file floor apply the INSTANT such a file is
# committed, and test-code-agent-manager.sh is the only other runner.
#
# THE FIXTURES ARE GENERATED, NOT COMMITTED. A checked-in copy of the goose
# config would go stale the moment config/goose/config.yaml changed, and would
# then be asserting yesterday's template. These are derived from the repo's own
# template at run time, then mutated — so the "clean" case is clean BY
# CONSTRUCTION and cannot drift away from what the repo actually ships.
#
# Run under coverage the same way the manager harness is:
#   PAI_PY="coverage run --parallel-mode --data-file=$PWD/.coverage" ./scripts/verify/test-pai.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pai-test.XXXXXX")"

# Sections 8 and 9 spawn `goose serve` stand-ins, so `trap ... EXIT` alone is no
# longer enough: Ctrl-C would leave a listener behind in the very file that
# asserts nothing is left behind. Every server this harness starts is recorded
# as a 0600 marker under $TMPDIR/pai-goosecfg (goosecfg writes it AT SPAWN), and
# both sections redirect TMPDIR into a subdirectory of $WORK -- so the markers
# are the roster, and cleanup is idempotent by construction. Killing the group
# precedent: test-code-agent-manager.sh:90-99; the multi-signal trap is new here.
#
# The glob is `*/tmp/` rather than `goosecfg/tmp/` because section 9 owns a
# second work directory: `pai doctor --fix` spawns its own server, and a roster
# that only knew about section 8's would leak exactly the process this file
# added.
cleanup() {
  local marker pid
  for marker in "$WORK"/*/tmp/pai-goosecfg/*.json; do
    [ -e "$marker" ] || continue
    pid="$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$marker")"
    if [ -n "$pid" ]; then
      # The group, not the pid: goose serve opens a second listener, and
      # start_new_session makes the child its own group leader. `|| true`
      # because a process that already died is the outcome, not an error --
      # and under `set -e` a failing kill in a trap would abort the trap.
      kill -9 "-$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT
# 130 is the conventional "killed by SIGINT" status. Separate from the EXIT trap
# so a Ctrl-C actually stops the run rather than resuming at the next section;
# cleanup is idempotent, so running twice on the way out is free.
trap 'cleanup; exit 130' INT TERM HUP

# shellcheck source=scripts/verify/lib.sh
. "$HERE/lib.sh"

# The interpreter seam, mirroring MANAGER_PY in test-code-agent-manager.sh:98.
# It wraps ONLY the thing under measurement.
read -r -a PAI_PY <<<"${PAI_PY:-python3}"
DOCTOR="$REPO_ROOT/scripts/pai/doctor.py"

# Fixture setup runs on a PLAIN interpreter, never under $PAI_PY. Two reasons,
# and the first one is a trap this repo has now hit twice: `coverage run -`
# refuses stdin ("No file to run: -"), so a heredoc through the coverage
# wrapper dies. The second is that fixture scaffolding is not the code under
# test and has no business in the report.
if python3 -c 'import yaml' >/dev/null 2>&1; then
  read -r -a FIX_PY <<<"python3"
else
  read -r -a FIX_PY <<<"uv run --quiet --with pyyaml python"
fi

# Flags are forwarded, because #34 gave `doctor` some: a wrapper that passed
# only "$1" would make every --fix assertion below silently test plain `doctor`.
# cli.sh has the same change for the same reason.
pai() { # pai <command> <home> [flags...]
  local command="$1" home="$2"
  shift 2
  PAI_HOME="$home" "${PAI_PY[@]}" "$DOCTOR" "$command" "$@"
}

# ---- fixture generation ------------------------------------------------------
# `clean` is what goose WOULD have written: the template's own values, with the
# comments stripped and goose's bookkeeping keys added, plus fourteen extensions
# of its own. That last part is the point — a clean machine is NOT one whose
# config equals the template, and a doctor that demanded equality would be
# permanently red on every real install.
make_clean() {
  local home="$1"
  mkdir -p "$home/.config/goose/custom_providers" "$home/.agents/skills"
  "${FIX_PY[@]}" - "$REPO_ROOT" "$home" <<'PY'
import json, pathlib, sys
import yaml
repo, home = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
tpl = yaml.safe_load((repo / "config/goose/config.yaml").read_text())
live = {"active_provider": tpl.get("active_provider"), "providers": tpl.get("providers"),
        "extensions": {}}
for name, block in tpl["extensions"].items():
    entry = dict(block)
    # goose adds these to everything it touches; doctor must ignore them.
    entry.update({"bundled": True, "description": "added by goose", "display_name": name})
    live["extensions"][name] = entry
# goose's own extensions, which must be reported as NOTE and never as drift.
for extra in ("analyze", "chatrecall", "computercontroller", "extensionmanager",
              "orchestrator", "scheduler", "skills", "summarize", "summon", "todo",
              "tom", "tutorial", "autovisualiser", "code_execution"):
    live["extensions"][extra] = {"name": extra, "type": "builtin", "enabled": True,
                                 "bundled": True}
(home / ".config/goose/config.yaml").write_text(yaml.safe_dump(live, sort_keys=False))
for src in (repo / "config/goose/custom_providers").glob("*.json"):
    obj = json.loads(src.read_text())
    # Wiring identical, catalogue deliberately NOT — that is sync-models.sh's
    # job and doctor must call it a NOTE rather than a failure.
    obj["models"] = obj.get("models", [])[:1]
    (home / ".config/goose/custom_providers" / src.name).write_text(json.dumps(obj))
for skill in (repo / "config/skills").glob("*"):
    if skill.is_dir():
        (home / ".agents/skills" / skill.name).mkdir(parents=True, exist_ok=True)
(home / ".config/goose/.goosehints").write_text("I am Phillip. Timezone America/New_York.\n")
PY
}

# ---- 1. a correctly-installed machine is CLEAN -------------------------------
CLEAN="$WORK/clean"
make_clean "$CLEAN"
if OUT="$(pai doctor "$CLEAN" 2>&1)"; then
  pass "doctor exits 0 on a correctly-installed machine"
else
  fail "doctor failed on a clean fixture:"$'\n'"$OUT"
fi
case "$OUT" in
  *"not ours, never touched (14)"*) pass "goose's own 14 extensions are a NOTE, never drift" ;;
  *) fail "the goose-added extensions were not reported as NOTE" ;;
esac
case "$OUT" in
  *"catalogue differs"*) pass "a differing model catalogue is a NOTE, not a failure" ;;
  *) fail "the model catalogue was not treated as sync-models.sh's business" ;;
esac

# ---- 2. each drift is detected, one at a time --------------------------------
# One mutation per fixture, so a failure names exactly one cause.
drift_case() { # drift_case <label> <needle> <mutator...>
  local label="$1" needle="$2"; shift 2
  local home="$WORK/drift-$RANDOM"
  make_clean "$home"
  "$@" "$home"
  local out rc=0
  out="$(pai doctor "$home" 2>&1)" || rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q -- "$needle"; then
    pass "detects: $label"
  else
    fail "missed: $label (exit $rc)"$'\n'"$out"
  fi
}

mut_apps_on() { "${FIX_PY[@]}" - "$1" <<'PY'
import pathlib, sys, yaml
p = pathlib.Path(sys.argv[1]) / ".config/goose/config.yaml"
d = yaml.safe_load(p.read_text()); d["extensions"]["apps"]["enabled"] = True
p.write_text(yaml.safe_dump(d))
PY
}
mut_unpin() { "${FIX_PY[@]}" - "$1" <<'PY'
import pathlib, sys, yaml
p = pathlib.Path(sys.argv[1]) / ".config/goose/config.yaml"
d = yaml.safe_load(p.read_text())
d["extensions"]["workspace-mcp"]["args"] = ["workspace-mcp", "--tools", "gmail"]
p.write_text(yaml.safe_dump(d))
PY
}
mut_drop_skill() { rm -rf "$1/.agents/skills/connect-service"; }
mut_hints() { printf 'I am <your name>.\n' > "$1/.config/goose/.goosehints"; }
mut_wiring() { "${FIX_PY[@]}" - "$1" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / ".config/goose/custom_providers/together.json"
d = json.loads(p.read_text()); d["base_url"] = "https://evil.example/v1"
p.write_text(json.dumps(d))
PY
}
mut_drop_ext() { "${FIX_PY[@]}" - "$1" <<'PY'
import pathlib, sys, yaml
p = pathlib.Path(sys.argv[1]) / ".config/goose/config.yaml"
d = yaml.safe_load(p.read_text()); d["extensions"].pop("memory")
p.write_text(yaml.safe_dump(d))
PY
}

drift_case "apps re-enabled (a security control)" "apps.enabled" mut_apps_on
drift_case "workspace-mcp unpinned and un-allowlisted" "workspace-mcp.args" mut_unpin
drift_case "a shipped skill is not installed" "shipped skills are not installed" mut_drop_skill
drift_case "goosehints still has placeholders" "placeholder" mut_hints
drift_case "provider WIRING changed" "wiring differs" mut_wiring
drift_case "a declared extension is missing entirely" "absent from the live config" mut_drop_ext

# A NOTE-producing case, not a FAIL: the template ships you@example.com and a
# correctly personalised machine MUST NOT be reported as drifted. Without this
# rule doctor is permanently red on every real install, which is the single
# fastest way to make it ignored.
note_case() { # note_case <label> <needle> <mutator...>
  local label="$1" needle="$2"; shift 2
  local home="$WORK/note-$RANDOM"
  make_clean "$home"
  "$@" "$home"
  local out rc=0
  out="$(pai doctor "$home" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q -- "$needle"; then
    pass "tolerates: $label"
  else
    fail "wrongly failed on: $label (exit $rc)"$'\n'"$out"
  fi
}

mut_personalise() { "${FIX_PY[@]}" - "$1" <<'PY'
import pathlib, sys, yaml
p = pathlib.Path(sys.argv[1]) / ".config/goose/config.yaml"
d = yaml.safe_load(p.read_text())
envs = d["extensions"]["workspace-mcp"].setdefault("envs", {})
envs["USER_GOOGLE_EMAIL"] = "real.person@gmail.com"
p.write_text(yaml.safe_dump(d))
PY
}
mut_no_hints() { rm -f "$1/.config/goose/.goosehints"; }

note_case "a personalised placeholder value" "personalised" mut_personalise
note_case "goosehints simply not installed yet" "not installed" mut_no_hints

# Provider-side failure shapes, which have distinct messages on purpose: a
# missing file, an unparseable one, and one that parses to the wrong TYPE are
# three different problems for the reader — and the third is a real shape, not a
# hypothetical: `[]` is valid JSON that json.loads accepts happily, so the
# unreadable-or-not-JSON arm never fires for it.
mut_provider_gone() { rm -f "$1/.config/goose/custom_providers/together.json"; }
mut_provider_junk() { printf 'not json at all' > "$1/.config/goose/custom_providers/together.json"; }
mut_provider_list() { printf '[1, 2, 3]' > "$1/.config/goose/custom_providers/together.json"; }

drift_case "a provider is not installed" "is not installed" mut_provider_gone
drift_case "a provider file is unparseable" "unreadable or not JSON" mut_provider_junk
drift_case "a provider file is JSON but not an object" "is not a JSON object" mut_provider_list

# The PASS arm of check_providers, which no fixture has ever reached: make_clean
# deliberately truncates every catalogue to models[:1], so `n_want != n_got` has
# always held and the NOTE arm always won. A verbatim copy makes the two sides
# byte-identical. The other three providers keep their truncated catalogues, so
# this stays a NOTE-producing (rc 0) case overall.
mut_provider_synced() {
  cp "$REPO_ROOT/config/goose/custom_providers/together.json" \
     "$1/.config/goose/custom_providers/together.json"
}
note_case "a provider whose catalogue is in sync" "provider together matches" mut_provider_synced

# ---- 3. a mangled config degrades, it does not crash -------------------------
MANGLED="$WORK/mangled"; make_clean "$MANGLED"
printf 'this is not yaml: [unclosed\n' > "$MANGLED/.config/goose/config.yaml"
if pai doctor "$MANGLED" >/dev/null 2>&1; then
  fail "an unreadable config should still report findings, not pass"
else
  pass "an unreadable goose config degrades to findings, not a traceback"
fi

# ---- 4. status and list are read-only and always succeed ---------------------
if pai status "$CLEAN" >/dev/null 2>&1; then pass "status exits 0"; else fail "status failed"; fi
if pai list "$CLEAN" >/dev/null 2>&1; then pass "list exits 0"; else fail "list failed"; fi
UNKNOWN_RC=0
pai nonsense "$CLEAN" >/dev/null 2>&1 || UNKNOWN_RC=$?
if [ "$UNKNOWN_RC" -eq 2 ]; then
  pass "an unknown command exits 2 (usage), per this repo's convention"
else
  fail "an unknown command exited $UNKNOWN_RC, wanted 2"
fi

# ---- 5. THE read-only proof --------------------------------------------------
# Not a grep for '>' — a hash of every byte under the fixture before and after.
#
# DELIBERATELY RESTRICTED TO THE NON-MUTATING VERBS, and it must stay that way.
# #34 added `doctor --fix`, which writes on purpose; this proof is what keeps
# the rest of the tool honest about not doing so, and adding --fix here would
# turn the one assertion that guards the read-only contract into a no-op.
# Section 9 has the matching proof for `--dry-run`.
BEFORE="$(find "$CLEAN" -type f -exec shasum {} \; | sort | shasum)"
pai doctor "$CLEAN" >/dev/null 2>&1 || true
pai status "$CLEAN" >/dev/null 2>&1 || true
pai list "$CLEAN" >/dev/null 2>&1 || true
AFTER="$(find "$CLEAN" -type f -exec shasum {} \; | sort | shasum)"
if [ "$BEFORE" = "$AFTER" ]; then
  pass "doctor/status/list wrote nothing: the fixture hashes identically"
else
  fail "pai modified the machine it was inspecting"
fi

# ---- 6. the arms the CLI cannot reach ----------------------------------------
# Four of doctor's branches are unreachable through `pai doctor`/`pai list` BY
# CONSTRUCTION, not by omission:
#
#   is_placeholder    every value the shipped template declares is a bool or a
#                     list, so the `isinstance(value, str)` guard has never once
#                     fallen through in a real run.
#   run()             its OSError arm needs a binary that does not exist.
#   check_opencode_shadowing
#                     gated on `home == Path.home()`, which is false for every
#                     fixture — that gate exists precisely so a fixture never
#                     reports THIS Mac's PATH as if it were the fixture's.
#   load_units        its degraded arms are a checkout with no config/units/ at
#                     all, and a manifest that is unparseable or not a mapping.
#                     None can exist in THIS tree: check-units.sh gates the
#                     latter two on every push.
#
# Driving them means calling the functions, so this is an in-process unit probe.

# The unit-manifest fixture, DERIVED FROM config/units/ AT RUN TIME for the same
# reason make_clean derives from config/goose/config.yaml: a committed manifest
# would be asserting yesterday's schema the moment config/units/README.md moved.
# Four shapes, because they are four different code paths and nothing else in
# the repo can produce them together:
#   base-goose a byte copy of a real manifest — the only way the "verbatim"
#              assertions below can know what verbatim IS without hardcoding it.
#   zz-empty   the same manifest with its three lists emptied and its installer
#              and verify removed: the `or "-"` fallbacks and BOTH footer counts.
#   zz-broken  unparseable — the arm check-units.sh cannot prevent, because an
#              editor can create it between two runs of the gate.
#   zz-blank   zero bytes, which is `touch config/units/x.yaml` mid-draft. It
#              parses CLEANLY, to None, so zz-broken's arm never sees it; before
#              the isinstance guard it was an AttributeError traceback out of a
#              read-only menu. A separate shape because a separate code path.
UNITS_FIXTURE="$WORK/units-fixture"
mkdir -p "$UNITS_FIXTURE/config/units"
"${FIX_PY[@]}" - "$REPO_ROOT" "$UNITS_FIXTURE" <<'PY'
import pathlib, shutil, sys
import yaml
repo, fixture = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
units = fixture / "config/units"
src = repo / "config/units/base-goose.yaml"
shutil.copyfile(src, units / "base-goose.yaml")
d = yaml.safe_load(src.read_text())
d.update({"id": "zz-empty", "cost": [], "requires": [], "manual_steps": [],
          "installer": None, "verify": []})
(units / "zz-empty.yaml").write_text(yaml.safe_dump(d, sort_keys=False))
(units / "zz-broken.yaml").write_text("this is not yaml: [unclosed\n")
(units / "zz-blank.yaml").write_text("")
PY

# The probe is a FILE, not a heredoc on stdin: `coverage run -` refuses stdin
# ("No file to run: -"), the same trap documented at the top of this file. And
# it runs under $PAI_PY, not $FIX_PY — a plain python3 would assert correctly
# and contribute exactly zero coverage.
cat > "$WORK/probe.py" <<'PY'
import contextlib
import importlib.util
import io
import os
import sys
from pathlib import Path

import yaml

doctor_path, clean_home, work, repo_root, units_fixture = sys.argv[1:6]
spec = importlib.util.spec_from_file_location("doctor_probe", doctor_path)
assert spec and spec.loader
mod = importlib.util.module_from_spec(spec)
# Register BEFORE exec_module, matching test-code-agent-manager.sh:244. Without
# it @dataclass fails resolving its own annotations: it looks the class's module
# up via sys.modules[cls.__module__], finds None, and dies in _is_type.
sys.modules["doctor_probe"] = mod
spec.loader.exec_module(mod)

# 1. is_placeholder with actual STRINGS -- both literal and <bracketed>.
assert mod.is_placeholder("you@example.com") is True
assert mod.is_placeholder("<your name>") is True
assert mod.is_placeholder("uvx") is False
assert mod.is_placeholder(7) is False

# 2. a placeholder-valued field is a NOTE, never a FAIL. Asserting the LEVEL is
#    the point: if the placeholder arm is skipped this is a FAIL with different
#    text, so the equality fails rather than quietly matching.
got = [(f.level, f.text) for f in mod.compare_extension("x", {"cmd": "<your cmd>"}, {"cmd": "uvx"})]
assert got == [("NOTE", "x.cmd is personalised (template ships a placeholder)")], got

# 3. a repo that ships no skills at all (glob on a missing dir yields nothing,
#    it does not raise). Without this arm check_skills returns the "all N
#    shipped skills are installed" PASS, so the level flips.
r = mod.check_skills(Path(work) / "emptyrepo", Path(clean_home))
assert [f.level for f in r] == ["NOTE"], r
assert "ships no skills" in r[0].text, r

# 4. the REAL run(), BEFORE step 5 rebinds it. FileNotFoundError is an OSError.
assert mod.run(["/nonexistent/binary/pai-probe"]) == ""

# 5. both arms of the shadowing check, with run() stubbed at module scope
#    (check_opencode_shadowing resolves `run` at call time).
calls = []


def fake_run(cmd):
    calls.append(cmd)
    return fake_run.out


mod.run = fake_run

fake_run.out = "/opt/homebrew/bin/opencode\n"
assert mod.check_opencode_shadowing() == []
assert ["/usr/bin/which", "-a", "opencode"] in calls, len(calls)

fake_run.out = "/opt/homebrew/bin/opencode\n/Users/someone/.opencode/bin/opencode\n"
shadow = mod.check_opencode_shadowing()
assert [f.level for f in shadow] == ["FAIL"], shadow
assert "resolves 2 ways" in shadow[0].text, shadow

# 6. collect() runs the shadowing check ONLY when the inspected home is this
#    machine's. Point HOME at the fixture so the two sides are the same string.
os.environ["HOME"] = clean_home
findings = mod.collect(Path(repo_root), Path(clean_home))
assert any("resolves 2 ways" in f.text for f in findings), [f.text for f in findings]

# 7. the unit catalogue. A checkout with no config/units/ at all reads as empty
#    rather than raising: Path.glob on a missing directory yields nothing.
assert mod.load_units(Path(work) / "norepo") == ([], []), "a missing config/units/ must be empty"

units, unreadable = mod.load_units(Path(units_fixture))
# BOTH degraded shapes, and they reach `unreadable` by different routes:
# zz-broken raises YAMLError, zz-blank parses cleanly to None and is rejected by
# the isinstance guard. A one-stem assertion here would pass with that guard
# deleted and a traceback in its place.
assert unreadable == ["zz-blank", "zz-broken"], unreadable
by_id = {u.id: u for u in units}
assert sorted(by_id) == ["base-goose", "zz-empty"], sorted(by_id)

# Expectations are READ OUT OF THE FIXTURE, which was itself copied from the
# real manifest — so nothing here can encode a value the repo has since changed.
manifest = yaml.safe_load((Path(units_fixture) / "config/units/base-goose.yaml").read_text())
full = by_id["base-goose"]
assert full.summary == manifest["summary"], full
assert full.requires == tuple(manifest["requires"]), full
assert full.cost == " + ".join(c["amount"] for c in manifest["cost"]), full
assert (full.has_installer, full.has_verify) == (True, True), full
# The manual column is a COUNT, and it is asserted against a NON-EMPTY list on
# purpose: len() returns 0 for an absent key and for an int alike, so a fixture
# whose true count is zero cannot tell a working implementation from a broken
# one. This one is >0 or the assertion below is meaningless.
assert len(manifest["manual_steps"]) > 0, manifest["manual_steps"]
assert full.manual_steps == len(manifest["manual_steps"]), full

empty = by_id["zz-empty"]
assert (empty.cost, empty.requires, empty.manual_steps) == ("-", (), 0), empty
assert (empty.has_installer, empty.has_verify) == (False, False), empty

buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = mod.catalogue(Path(units_fixture))
out = buf.getvalue()
# `pai list` is read-only, so the unreadable manifests are REPORTED, not fatal.
assert rc == 0, rc
assert manifest["summary"] in out, out
assert "unreadable (2): zz-blank, zz-broken" in out, out
assert "2 units — 1 with no installer, 1 with no verify script." in out, out
PY
if OUT="$("${PAI_PY[@]}" "$WORK/probe.py" "$DOCTOR" "$CLEAN" "$WORK" "$REPO_ROOT" \
    "$UNITS_FIXTURE" 2>&1)"; then
  pass "unit probe: is_placeholder, run()'s OSError arm, both shadowing arms, load_units"
else
  fail "unit probe failed:"$'\n'"$OUT"
fi

# ---- 7. `pai list` renders the MANIFESTS, not a scan of the tree -------------
# Deliberately not a check for the column labels: the header is printed
# unconditionally, so matching it passes even against an empty catalogue. These
# assert VALUES that only reach the output by way of config/units/.
LIST_OUT="$(pai list "$CLEAN")"
MANIFESTS=("$REPO_ROOT"/config/units/*.yaml)

SUMMARY_VALUE="$("${FIX_PY[@]}" - "$REPO_ROOT" <<'PY'
import pathlib, sys
import yaml
p = pathlib.Path(sys.argv[1]) / "config/units/base-goose.yaml"
print(yaml.safe_load(p.read_text())["summary"])
PY
)"
if printf '%s\n' "$LIST_OUT" | grep -qF -- "$SUMMARY_VALUE"; then
  pass "list prints base-goose's summary verbatim, straight out of the manifest"
else
  fail "the manifest summary is not in the menu:"$'\n'"$SUMMARY_VALUE"$'\n'"$LIST_OUT"
fi

# Epic #30's own requirement: every unit id appears in the generated table. The
# roster is the directory, so this holds at three manifests and at eighteen.
# One verdict for the whole loop — lib.sh's fail() records and RETURNS, so a
# fail inside the loop followed by a pass after it would report both.
MISSING=""
for manifest in "${MANIFESTS[@]}"; do
  stem="$(basename "$manifest" .yaml)"
  # Anchored: an id must START a row, not merely occur somewhere in a summary.
  # Unit ids are kebab-case, so there is nothing here for the regex to eat.
  printf '%s\n' "$LIST_OUT" | grep -q "^$stem " || MISSING="$MISSING $stem"
done
if [ -z "$MISSING" ]; then
  pass "every one of the ${#MANIFESTS[@]} manifests appears in the menu"
else
  fail "unit ids missing from the menu:$MISSING"
fi

# The footer count is the directory's, not a number in the source.
if printf '%s\n' "$LIST_OUT" | grep -q "^${#MANIFESTS[@]} units "; then
  pass "the footer counts the manifests on disk (${#MANIFESTS[@]})"
else
  fail "the footer does not count ${#MANIFESTS[@]} units:"$'\n'"$LIST_OUT"
fi

# The one CLI-level assertion in this file. AC#4 is written at the `pai list`
# level, and nothing in this repo has ever executed bin/pai — every other test
# here calls doctor.py directly. It costs zero coverage: cli.sh runs doctor.py
# under py_runner's plain python3, outside $PAI_PY.
if "$REPO_ROOT/bin/pai" list >/dev/null 2>&1; then
  pass "bin/pai list exits 0 through the real CLI shim"
else
  fail "bin/pai list did not exit 0"
fi

# ---- 8. goosecfg against a fake goose ----------------------------------------
# scripts/pai/goosecfg.py is measured the instant it is tracked (.coveragerc
# `source = scripts`), and every arm worth having only exists against a live
# ACP server: an allowlist goose silently dropped, a remove that reports success
# and does nothing, a server that never becomes ready, one that dies mid-apply.
# So the harness owns a stand-in, scripts/verify/fake-goose-acp.py, and
# GOOSECFG SPAWNS IT ITSELF -- a pre-started server would leave the whole
# choose_port/spawn/readiness/teardown class at zero.
#
# Three probes rather than one, because a single 400-line assertion block that
# dies on line 12 tells you nothing about the other 388. Same file-not-stdin and
# register-before-exec_module rules as section 6.
GOOSECFG="$REPO_ROOT/scripts/pai/goosecfg.py"
FAKE_ACP="$REPO_ROOT/scripts/verify/fake-goose-acp.py"
GC_WORK="$WORK/goosecfg"
mkdir -p "$GC_WORK/tmp"

# openssl mints the throwaway certificate the `tls` mode needs. It is present on
# every machine this repo targets; when it is not, that ONE arm is skipped and
# the probe says so rather than failing for a reason nobody can act on.
TLS_OK=0
command -v openssl >/dev/null 2>&1 && TLS_OK=1

# TMPDIR is redirected into $WORK for these three: goosecfg's crash markers live
# under $TMPDIR/pai-goosecfg/ and start() reaps every one it finds, so a probe
# sharing /tmp with a developer's own `pai doctor --fix` would reap theirs.
#
# The tuning seams are the reason this section takes seconds rather than a
# minute: readiness is measured at 0.19s against real goose, so 0.8s is still
# 4x margin, and the never-ready arm costs 3 x 0.8s instead of 3 x 20s.
gc_probe() { # gc_probe <label> <probe-file> [args...]
  local label="$1" probe="$2"; shift 2
  local out rc=0
  out="$(TMPDIR="$GC_WORK/tmp" PAI_GOOSE_READY_S=0.8 PAI_GOOSE_STOP_S=0.5 \
        PAI_GOOSE_ALLOW_CONCURRENT=1 \
        "${PAI_PY[@]}" "$probe" "$GOOSECFG" "$FAKE_ACP" "$GC_WORK" "$TLS_OK" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "goosecfg: $label"
  else
    fail "goosecfg: $label (exit $rc)"$'\n'"$out"
  fi
}

# --- 8a. the pure surface: translation, parsing, ports, markers ---------------
cat > "$GC_WORK/probe-unit.py" <<'PY'
"""goosecfg's dependency-free half, plus the two vocabularies that must not drift."""
import importlib.util
import json
import os
import signal
import socket
import ssl
import subprocess
import sys
import types
import urllib.error
from pathlib import Path

GOOSECFG, FAKE, WORK = sys.argv[1:4]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    # Register BEFORE exec_module, the same trap as section 6: @dataclass
    # resolves its own annotations through sys.modules[cls.__module__].
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


g = load("goosecfg_probe", GOOSECFG)
doctor = load("doctor_for_goosecfg", str(Path(GOOSECFG).with_name("doctor.py")))


def raises(kind, reason, fn, *args, **kwargs):
    """Assert fn() raises `kind` with `reason`, and hand the exception back."""
    try:
        fn(*args, **kwargs)
    except kind as exc:
        assert exc.reason == reason, (exc.reason, reason)
        return exc
    raise AssertionError(f"expected {kind.__name__}/{reason}")


# 1. THE TWO VOCABULARIES. goosecfg cannot import doctor (it must stay free of
#    PyYAML) so both are written out; this is the gate that keeps them equal.
assert g.DISK_FIELDS == doctor.DECLARED_FIELDS, (g.DISK_FIELDS, doctor.DECLARED_FIELDS)
for value in ("you@example.com", "<your name>", "uvx", 7, None):
    assert g.looks_like_placeholder(value) is doctor.is_placeholder(value), value

# 2. to_wire: disk -> ACP. Every optional key present, then every one absent.
stdio = {"type": "stdio", "enabled": True, "cmd": "uvx", "args": ["workspace-mcp@1.25.0"],
         "env_keys": ["GOOGLE_OAUTH_CLIENT_ID"], "available_tools": ["get_events"],
         "envs": {"USER_GOOGLE_EMAIL": "you@example.com"}, "timeout": 300}
wire = g.to_wire("workspace-mcp", stdio, {"USER_GOOGLE_EMAIL": "person@example.org"})
assert wire["type"] == "mcp", wire
assert wire["server"] == {
    "name": "workspace-mcp", "type": "stdio", "command": "uvx",
    "args": ["workspace-mcp@1.25.0"],
    "env": [{"name": "USER_GOOGLE_EMAIL", "value": "person@example.org"}],
}, wire["server"]
assert wire["envKeys"] == ["GOOGLE_OAUTH_CLIENT_ID"] and wire["timeout"] == 300, wire
assert wire["available_tools"] == ["get_events"], wire
bare = g.to_wire("playwright", {"type": "stdio", "cmd": "npx"}, {})
assert bare["server"]["args"] == [] and bare["server"]["env"] == [], bare
assert "envKeys" not in bare and "available_tools" not in bare and "timeout" not in bare, bare

# The remote shape, which is spelled differently on both sides: `uri` -> `url`,
# and headers go from a MAPPING to a LIST of {name, value}. Sending the mapping
# is the failure config/connectors/README.md calls the safe one.
http = g.to_wire("todoist", {"type": "streamable_http", "uri": "https://ai.todoist.net/mcp",
                             "headers": {"Authorization": "Bearer ${TODOIST_API_KEY}"},
                             "env_keys": ["TODOIST_API_KEY"], "timeout": 300}, {})
assert http["server"]["type"] == "http", http
assert http["server"]["url"] == "https://ai.todoist.net/mcp", http
assert http["server"]["headers"] == [
    {"name": "Authorization", "value": "Bearer ${TODOIST_API_KEY}"}], http
assert "env" not in http["server"], "the http variant has no env field at all"
assert g.to_wire("x", {"type": "streamable_http", "uri": "u"}, {})["server"]["headers"] == []

# 3. LiveEntry: ACP -> disk. `enabled` is a SIBLING on the wire and has to be
#    merged back, `type` is inferred from the shape because it is not echoed.
entry = g.LiveEntry("workspace-mcp", True, {
    "server": {"command": "uvx", "args": ["workspace-mcp@1.25.0"]},
    "envKeys": ["GOOGLE_OAUTH_CLIENT_ID"], "available_tools": ["get_events"], "timeout": 300})
assert entry.to_disk() == {
    "enabled": True, "type": "stdio", "cmd": "uvx", "args": ["workspace-mcp@1.25.0"],
    "env_keys": ["GOOGLE_OAUTH_CLIENT_ID"], "available_tools": ["get_events"],
    "timeout": 300}, entry.to_disk()
remote = g.LiveEntry("todoist", False, {"server": {"url": "https://ai.todoist.net/mcp"}})
assert remote.to_disk() == {"enabled": False, "type": "streamable_http",
                            "uri": "https://ai.todoist.net/mcp", "env_keys": []}, remote.to_disk()
# A platform/builtin entry -- goose's own `apps` -- has neither shape and gets
# no `type`, which is right: nothing in the repo declares one for it.
platform = g.LiveEntry("apps", False, {})
assert platform.to_disk() == {"enabled": False, "env_keys": []}, platform.to_disk()
assert platform.allowlist() == (None, None)
assert g.LiveEntry("x", False, {"availableTools": ["t"]}).allowlist() == (["t"], "availableTools")
assert g.LiveEntry("x", False, {"available_tools": "oops"}).allowlist() == ([], "available_tools")

# 4. frame parsing: a POST body, an SSE line, and every way of being neither.
assert g._parse_body("") is None
assert g._parse_body("   ") is None
assert g._parse_body('{"a": 1}') == {"a": 1}
assert g._parse_body("{not json") is None
assert g._parse_body('data: {"a": 1}\n\n') == {"a": 1}
assert g._parse_body('event: update\ndata: nope\ndata: {"b": 2}') == {"b": 2}
assert g._parse_body("data: [1, 2]") is None
assert g._parse_body("event: update only") is None

# 5. the TLS downgrade, decided in two pieces so both are assertable without a
#    certificate. The end-to-end arm is in probe 8b's `tls` mode.
ctx = g._unverified_context()
assert ctx.check_hostname is False and ctx.verify_mode is ssl.CERT_NONE
assert g._is_tls_failure(urllib.error.URLError(ssl.SSLError("bad cert"))) is True
assert g._is_tls_failure(urllib.error.URLError(OSError("refused"))) is False

# 6. process identification. A recycled pid must not be killed on the strength
#    of its number alone, so the argv is what decides.
assert g._argv_is_goose("/opt/homebrew/bin/goose serve --host 127.0.0.1 --port 3288", "goose")
assert not g._argv_is_goose("/opt/homebrew/bin/goose session", "goose")
assert not g._argv_is_goose("/bin/sleep 30", "goose")
assert g.foreign_goose_pids([
    "  4242 /opt/homebrew/bin/goose serve --port 3284",
    "not-a-pid  whatever",
    f"{os.getpid()} /opt/homebrew/bin/goose serve",
    "  4243 /bin/zsh -l",
]) == [4242]
assert g.foreign_goose_pids([]) == []
assert isinstance(g._ps_lines(), list)
assert g._pid_argv(os.getpid()) != ""
assert g._pid_argv(2 ** 30) == ""
g._killpg(2 ** 30, signal.SIGTERM)          # a dead pid is not an error, it is the goal

# ps itself failing (no /bin/ps, a sandbox) must degrade, not traceback.
broken = types.SimpleNamespace(
    run=lambda *a, **k: (_ for _ in ()).throw(OSError("no ps")),
    SubprocessError=subprocess.SubprocessError, DEVNULL=subprocess.DEVNULL)
real_subprocess, g.subprocess = g.subprocess, broken
try:
    assert g._pid_argv(1) == ""
    assert g._ps_lines() == []
finally:
    g.subprocess = real_subprocess

# 7. the float seams, including a value someone typo'd.
os.environ.pop("PAI_TEST_FLOAT", None)
assert g._float_env("PAI_TEST_FLOAT", 1.5) == 1.5
os.environ["PAI_TEST_FLOAT"] = "not-a-number"
assert g._float_env("PAI_TEST_FLOAT", 1.5) == 1.5
os.environ["PAI_TEST_FLOAT"] = "2.5"
assert g._float_env("PAI_TEST_FLOAT", 1.5) == 2.5
del os.environ["PAI_TEST_FLOAT"]

# 8. choose_port reserves P AND P+1, because goose opens a second listener at
#    P+1 and stealing a neighbour's port is the failure that looks like a flake.
port = g.EphemeralGoose.choose_port()
assert port > 1024 and port not in g.RESERVED_PORTS and (port + 1) not in g.RESERVED_PORTS
assert g._port_is_open(port) is False
saved_reserved, g.RESERVED_PORTS = g.RESERVED_PORTS, frozenset(range(1, 65536))
try:
    raises(g.ServerError, g.Reason.NO_PORT, g.EphemeralGoose.choose_port)
finally:
    g.RESERVED_PORTS = saved_reserved
# The other refusal: P is free but P+1 is squatted. Deterministic only if the
# candidate is chosen for us, which is why _ephemeral_port is its own function.
squatter = socket.socket()
squatter.bind(("127.0.0.1", 0))
squatter.listen(1)
saved_ep, g._ephemeral_port = g._ephemeral_port, lambda: squatter.getsockname()[1] - 1
try:
    raises(g.ServerError, g.Reason.NO_PORT, g.EphemeralGoose.choose_port)
finally:
    g._ephemeral_port = saved_ep
    squatter.close()
# And the top of the range, which the OS hands out like any other ephemeral
# port: bind(65536) raises OverflowError, NOT OSError, so before this guard it
# escaped the retry above and surfaced as a traceback out of `pai doctor --fix`.
# Observed once in a real harness run, which is the only reason it is here.
saved_ep, g._ephemeral_port = g._ephemeral_port, lambda: 65535
try:
    raises(g.ServerError, g.Reason.NO_PORT, g.EphemeralGoose.choose_port)
finally:
    g._ephemeral_port = saved_ep

# 9. the exception vocabulary the callers will switch on.
rpc = g.RpcError(-32601, "Method not found")
assert (rpc.code, rpc.reason) == (-32601, g.Reason.RPC_ERROR) and "-32601" in str(rpc)
allow = g.AllowlistError(g.Reason.ALLOWLIST_MISSPELLED, "x", spelling="availableTools")
assert isinstance(allow, g.ReadBackError) and allow.spelling == "availableTools"
assert str(g.GooseCfgError(g.Reason.AUTH)) == g.Reason.AUTH        # the no-detail arm

# 10. crash markers. A marker for a dead pid, one that will not parse, one whose
#     process is alive but is NOT ours, and one that is -- four different fates.
marker_dir = g._marker_dir()
assert marker_dir.is_dir()
(marker_dir / "garbage.json").write_text("this is not json")
(marker_dir / "nopid.json").write_text(json.dumps({"port": 1}))
(marker_dir / "dead.json").write_text(json.dumps({"pid": 2 ** 30, "binary": "goose"}))
child_env = dict(os.environ, PAI_FAKE_MODE="never-ready")
victim = subprocess.Popen([FAKE, "serve", "--host", "127.0.0.1", "--port", str(port)],
                          env=child_env, start_new_session=True,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
bystander = subprocess.Popen(["/bin/sleep", "30"], start_new_session=True)
g._write_marker(victim.pid, port, FAKE)
g._write_marker(bystander.pid, port, FAKE)
try:
    g._reap_markers(FAKE)
    assert victim.wait(timeout=10) is not None, "a stale goose survived the reaper"
    assert bystander.poll() is None, "the reaper killed a process that was not ours"
    assert list(marker_dir.glob("*.json")) == [], list(marker_dir.glob("*.json"))
finally:
    bystander.kill()
    bystander.wait(timeout=10)

Path(WORK, "unit.ok").write_text("ok")
PY
gc_probe "translation, frame parsing, port reservation, crash markers" \
  "$GC_WORK/probe-unit.py"

# --- 8b. the client and the read-back contract, against the fake -------------
cat > "$GC_WORK/probe-acp.py" <<'PY'
"""Every AcpClient arm and every apply/remove refusal, driven by the fake's modes."""
import importlib.util
import json
import os
import sys
from pathlib import Path

GOOSECFG, FAKE, WORK, TLS_OK = sys.argv[1:5]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


g = load("goosecfg_probe", GOOSECFG)

WS = {"type": "stdio", "enabled": True, "cmd": "uvx",
      "args": ["workspace-mcp@1.25.0", "--tool-tier", "core"],
      "env_keys": ["GOOGLE_OAUTH_CLIENT_ID"],
      "available_tools": ["get_events", "manage_event", "send_gmail_message"],
      "timeout": 300}
# playwright's real shape: no allowlist, ships disabled. It must still be
# APPLICABLE -- only enabling it is refused.
PW = {"type": "stdio", "enabled": False, "cmd": "npx",
      "args": ["-y", "@playwright/mcp@0.0.79"], "env_keys": [], "timeout": 300}

_serial = [0]


def serve(mode, state=None, **extra):
    env = {"PAI_FAKE_MODE": mode}
    if state is not None:
        env["PAI_FAKE_CONFIG"] = state
    env.update(extra)
    return g.EphemeralGoose(binary=FAKE, env=env)


def state_file(name, seed=None):
    path = Path(WORK) / f"state-{name}.json"
    path.write_text(json.dumps(seed or {"extensions": {}, "secrets": {}}))
    return str(path)


def raises(kind, reason, fn, *args, **kwargs):
    try:
        fn(*args, **kwargs)
    except kind as exc:
        assert exc.reason == reason, (exc.reason, reason)
        return exc
    raise AssertionError(f"expected {kind.__name__}/{reason}")


def apply_fails(mode, kind, reason, disk=WS, envs=None, enable=False):
    """Spawn a misbehaving goose, apply, and assert WHICH refusal came back."""
    _serial[0] += 1
    with serve(mode, state_file(f"{mode}-{_serial[0]}")) as server, \
            g.AcpClient(server.url, server.secret, 5.0) as client:
        return raises(kind, reason, g.apply_extension, client, "workspace-mcp", disk,
                      envs=envs or {}, enable=enable)


# --- the happy path, end to end, including the enable -----------------------
ok_state = state_file("ok")
with serve("ok", ok_state) as server, g.AcpClient(server.url, server.secret, 5.0) as client:
    assert client.get("workspace-mcp") is None
    entry = g.apply_extension(client, "workspace-mcp", WS,
                              envs={"USER_GOOGLE_EMAIL": "person@example.org"}, enable=True)
    assert entry.enabled is True and entry.config_key == "workspace-mcp", entry
    assert entry.to_disk()["available_tools"] == WS["available_tools"], entry.to_disk()
    # The migration: the NAME reaches env_keys and the store says the key is
    # set. The VALUE is never asked for, never compared, never printed.
    assert "USER_GOOGLE_EMAIL" in entry.extension["envKeys"], entry.extension
    assert client.secret_is_set("USER_GOOGLE_EMAIL") is True
    assert client.secret_is_set("NEVER_STORED") is False

    # Applying again is an UPSERT, not a merge, and stays idempotent.
    again = g.apply_extension(client, "workspace-mcp", WS, envs={}, enable=True)
    assert again.enabled is True

    # A placeholder value is DROPPED rather than migrated: `you@example.com` is
    # the template's own, and promoting it would put a fiction in the store.
    plain = dict(WS)
    g.apply_extension(client, "workspace-mcp", plain,
                      envs={"USER_GOOGLE_EMAIL": "you@example.com"}, enable=False)

    # playwright: applied, left disabled, no allowlist to prove.
    pw = g.apply_extension(client, "playwright", PW, envs={}, enable=False)
    assert pw.enabled is False and pw.allowlist() == (None, None), pw
    # ...and asking to ENABLE it is the second, separate refusal -- raised
    # before any write, so nothing on the server changed.
    exc = raises(g.AllowlistError, g.Reason.NO_ALLOWLIST,
                 g.apply_extension, client, "playwright", PW, envs={}, enable=True)
    assert exc.spelling is None
    assert client.get("playwright").enabled is False

    # camelCase in the TEMPLATE never reaches the wire at all.
    exc = raises(g.AllowlistError, g.Reason.ALLOWLIST_MISSPELLED, g.apply_extension,
                 client, "camel", {"type": "stdio", "cmd": "npx", "availableTools": ["t"]},
                 envs={}, enable=False)
    assert exc.spelling == "availableTools"

    # remove: proven by the read-back, because the call says success regardless.
    g.remove_extension(client, "workspace-mcp")
    assert client.get("workspace-mcp") is None
    g.remove_extension(client, "never-existed-at-all")

# --- connect() uses GOOSE_ACP_URL and does NOT spawn -------------------------
with serve("ok", state_file("adopt")) as server:
    os.environ["GOOSE_ACP_URL"] = server.url
    os.environ["GOOSE_SERVER__SECRET_KEY"] = server.secret
    try:
        with g.connect() as client:
            assert client.get("anything") is None
    finally:
        del os.environ["GOOSE_ACP_URL"]
        del os.environ["GOOSE_SERVER__SECRET_KEY"]

# ...and with no GOOSE_ACP_URL it spawns one of its own and tears it down.
assert "GOOSE_ACP_URL" not in os.environ
with g.connect(binary=FAKE, env={"PAI_FAKE_MODE": "ok",
                                 "PAI_FAKE_CONFIG": state_file("spawned")}) as client:
    assert client.list_extensions() == []

# --- transport and auth ------------------------------------------------------
with serve("ok") as server:
    # A wrong key is a 401 from the server, not a guess by the client.
    raises(g.AuthError, g.Reason.AUTH, g.AcpClient(server.url, "wrong-key", 5.0).__enter__)
    # Nothing is listening two ports up from a port nobody bound.
    raises(g.TransportError, g.Reason.TRANSPORT,
           g.AcpClient(f"http://127.0.0.1:{g.EphemeralGoose.choose_port()}/acp", "", 1.0).__enter__)

with serve("auth-401") as server:
    raises(g.AuthError, g.Reason.AUTH, g.AcpClient(server.url, server.secret, 5.0).__enter__)
with serve("http-500") as server:
    raises(g.TransportError, g.Reason.TRANSPORT,
           g.AcpClient(server.url, server.secret, 5.0).__enter__)
with serve("bad-init") as server:
    raises(g.TransportError, g.Reason.BAD_RESPONSE,
           g.AcpClient(server.url, server.secret, 5.0).__enter__)

# A renamed method is -32601, which is the shape the contract gate exists for.
with serve("rpc-error") as server, g.AcpClient(server.url, server.secret, 5.0) as client:
    exc = raises(g.RpcError, g.Reason.RPC_ERROR, client.list_extensions)
    assert exc.code == -32601, exc.code
    # secret_is_set swallows it: "the store did not answer" is "not set".
    assert client.secret_is_set("ANY") is False

with serve("bad-list") as server, g.AcpClient(server.url, server.secret, 5.0) as client:
    raises(g.TransportError, g.Reason.BAD_RESPONSE, client.list_extensions)

# Garbage inside a well-formed array is dropped, not fatal: one bad entry must
# not cost the read-back of every other extension.
with serve("junk-list", state_file("junk")) as server, \
        g.AcpClient(server.url, server.secret, 5.0) as client:
    entries = client.list_extensions()
    assert [e.config_key for e in entries] == ["junk"], entries
    assert entries[0].extension == {}, entries[0]

# --- the reply may arrive on the OTHER channel -------------------------------
with serve("sse-reply", state_file("sse")) as server, \
        g.AcpClient(server.url, server.secret, 5.0) as client:
    assert client.get("nothing") is None            # answered over SSE, after a notification
with serve("no-reply") as server, g.AcpClient(server.url, server.secret, 0.7) as client:
    exc = raises(g.TransportError, g.Reason.TRANSPORT, client.list_extensions)
    assert "timeout" in exc.detail, exc.detail
with serve("sse-reply,sse-close") as server, \
        g.AcpClient(server.url, server.secret, 5.0) as client:
    exc = raises(g.TransportError, g.Reason.TRANSPORT, client.list_extensions)
    assert "sse closed" in exc.detail, exc.detail
# The SSE channel refused outright: the pump dies quietly and says so through
# the sentinel, at the call that needed it, rather than raising on a thread.
with serve("sse-401,sse-reply") as server, \
        g.AcpClient(server.url, server.secret, 5.0) as client:
    exc = raises(g.TransportError, g.Reason.TRANSPORT, client.list_extensions)
    assert "sse closed" in exc.detail, exc.detail
# No connection id means no SSE channel at all; POST bodies still answer.
with serve("no-conn-id", state_file("noconn")) as server, \
        g.AcpClient(server.url, server.secret, 5.0) as client:
    assert client.list_extensions() == []

# --- every read-back refusal, one mode each ----------------------------------
# THE ONE THE WHOLE FEATURE EXISTS FOR: accepted, stored with no allowlist key,
# which means every tool is allowed.
assert apply_fails("drop-allowlist", g.AllowlistError,
                   g.Reason.ALLOWLIST_DROPPED).spelling is None
assert apply_fails("camel-allowlist", g.AllowlistError,
                   g.Reason.ALLOWLIST_MISSPELLED).spelling == "availableTools"
apply_fails("empty-allowlist", g.AllowlistError, g.Reason.ALLOWLIST_EMPTY)
exc = apply_fails("truncate-allowlist", g.AllowlistError, g.Reason.ALLOWLIST_DIFFERS)
assert "send_gmail_message" in exc.detail, exc.detail
exc = apply_fails("mangle-args", g.ReadBackError, g.Reason.FIELD_DIFFERS)
assert exc.detail.endswith(".args"), exc.detail
# env_keys is the one field compared as a SUPERSET (a migration widens it), so
# it needs its own arm: a key the template declares and goose did not keep.
exc = apply_fails("drop-envkeys", g.ReadBackError, g.Reason.FIELD_DIFFERS)
assert exc.detail.endswith(".env_keys"), exc.detail
apply_fails("add-noop", g.ReadBackError, g.Reason.NOT_LISTED)
apply_fails("ignore-enable", g.ReadBackError, g.Reason.NOT_ENABLED, enable=True)
apply_fails("no-secret", g.ReadBackError, g.Reason.ENV_NOT_PROMOTED,
            envs={"USER_GOOGLE_EMAIL": "person@example.org"})
# The server dying between the write and the read-back: the window fails CLOSED
# and the restore cannot run, which is the documented behaviour.
apply_fails("die-mid-apply", g.TransportError, g.Reason.TRANSPORT)

# --- the restore: a failure after the write puts `enabled` back --------------
# Seed a live, ENABLED entry so the pre-image is not None. `add` writes it back
# disabled; the read-back then fails; step 8 must restore what was there.
seeded = state_file("restore", {
    "extensions": {"workspace-mcp": {"enabled": True, "extension": {
        "type": "mcp", "server": {"name": "workspace-mcp", "type": "stdio",
                                  "command": "uvx", "args": WS["args"], "env": []},
        "available_tools": WS["available_tools"], "envKeys": WS["env_keys"],
        "timeout": 300}}},
    "secrets": {}})
with serve("truncate-allowlist", seeded) as server, \
        g.AcpClient(server.url, server.secret, 5.0) as client:
    assert client.get("workspace-mcp").enabled is True
    raises(g.AllowlistError, g.Reason.ALLOWLIST_DIFFERS, g.apply_extension,
           client, "workspace-mcp", WS, envs={}, enable=True)
    assert client.get("workspace-mcp").enabled is True, "the pre-image's enabled was not restored"

# remove that reports success and changes nothing -- the measured behaviour, and
# the only reason remove_extension reads back at all.
with serve("remove-noop", seeded) as server, \
        g.AcpClient(server.url, server.secret, 5.0) as client:
    raises(g.ReadBackError, g.Reason.STILL_LISTED, g.remove_extension, client, "workspace-mcp")

# --- https with a self-signed certificate: the brain's shape -----------------
if TLS_OK == "1":
    with serve("tls", state_file("tls")) as server:
        url = f"https://127.0.0.1:{server.port}/acp"
        with g.AcpClient(url, server.secret, 10.0) as client:
            assert client.list_extensions() == []
            assert client.downgraded is True, "a self-signed goose must be reached, once, loudly"

Path(WORK, "acp.ok").write_text("ok")
PY
gc_probe "the client, the read-back contract, and every refusal" "$GC_WORK/probe-acp.py"

# --- 8c. the ephemeral server's lifecycle ------------------------------------
cat > "$GC_WORK/probe-life.py" <<'PY'
"""Spawn, readiness, teardown proof, the crash marker, and the signal path."""
import importlib.util
import os
import re
import signal
import stat
import sys
from pathlib import Path

GOOSECFG, FAKE, WORK = sys.argv[1:4]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


g = load("goosecfg_probe", GOOSECFG)


def raises(kind, reason, fn, *args, **kwargs):
    try:
        fn(*args, **kwargs)
    except kind as exc:
        assert exc.reason == reason, (exc.reason, reason)
        return exc
    raise AssertionError(f"expected {kind.__name__}/{reason}")


def server(mode="ok"):
    return g.EphemeralGoose(binary=FAKE, env={"PAI_FAKE_MODE": mode})


# 1. start/stop, both idempotent, with the teardown PROVEN by a TCP connect.
one = server()
one.start()
url, port = one.url, one.port
one.start()                                   # already running: a no-op, not a second spawn
assert (one.url, one.port) == (url, port)
assert g._port_is_open(port) is True
assert one._marker is not None and one._marker.is_file()
assert stat.S_IMODE(one._marker.stat().st_mode) == 0o600, "the marker names a port; keep it 0600"
one.stop()
one.stop()
assert g._port_is_open(port) is False, "stop() left a listener behind"
assert one._marker is None and one._stderr_tail() == ""

# 2. two at once. This is what makes start()'s reaper dangerous -- it must not
#    kill a server this same process is still holding -- and it is the only way
#    to reach _restore_signals' "someone else is still live" arm.
first, second = server(), server()
first.start()
second.start()
assert first.proc.poll() is None, "starting a second server reaped the first"
assert g._port_is_open(first.port) and g._port_is_open(second.port)
first.stop()
assert g._port_is_open(second.port), "stopping one stopped the other"
second_port = second.port
second.stop()
assert not g._port_is_open(second_port)

# 3. every way it can fail to come up.
raises(g.ServerError, g.Reason.NOT_READY, server("never-ready").start)
exits = Path(WORK) / "exits-immediately"
exits.write_text("#!/bin/sh\nexit 3\n")
exits.chmod(0o755)
raises(g.ServerError, g.Reason.NOT_READY, g.EphemeralGoose(binary=str(exits)).start)
missing = raises(g.ServerError, g.Reason.NO_BINARY,
                 g.EphemeralGoose(binary=str(Path(WORK) / "no-such-goose")).start)
assert "PAI_GOOSE_BIN" in missing.detail, missing.detail

# 3b. THE CHILD'S STDERR IS REPORTED VERBATIM, and the child was handed a freshly
#     minted GOOSE_SERVER__SECRET_KEY. A goose that panics with an environment
#     dump is not hypothetical, and this detail is printed by
#     check-connectors.sh and by `pai doctor --fix` — so the line must survive
#     and the value must not.
dumps = Path(WORK) / "dumps-its-env"
dumps.write_text("#!/bin/sh\necho 'panicked at config.rs:1' >&2\nenv | grep GOOSE_SERVER >&2\nexit 1\n")
dumps.chmod(0o755)
leak = raises(g.ServerError, g.Reason.NOT_READY, g.EphemeralGoose(binary=str(dumps)).start)
assert "panicked at config.rs" in leak.detail, leak.detail   # still actionable
assert "GOOSE_SERVER__SECRET_KEY=<redacted>" in leak.detail, leak.detail
assert re.search(r"[0-9a-f]{64}", str(leak)) is None, "the minted key reached an exception"
# ...and the redactor itself, on the two shapes it has to handle without a
# server: a bare value with no assignment around it, and an empty secret, where
# a naive str.replace("") would splice the marker between every character.
assert g._redact("key=deadbeef and deadbeef", "deadbeef") == "key=<redacted> and <redacted>"
assert g._redact("nothing to hide", "") == "nothing to hide"

# 3c. the stderr tail is best-effort: a ServerError must not be replaced by an
#     I/O error raised while assembling its own detail.
tailless = server()
tailless.start()
tailless._stderr.close()
assert tailless._stderr_tail() == ""
tailless.stop()

# 4. a server that ignores SIGTERM must still be gone: the escalation to
#    SIGKILL is the only thing standing between this and a leaked listener.
stubborn = server("ignore-sigterm")
stubborn.start()
stubborn_port = stubborn.port
stubborn.stop()
assert not g._port_is_open(stubborn_port), "SIGTERM was ignored and nothing escalated"

# 5. the teardown proof itself has to be able to FAIL, or it is decoration.
leaky = server()
leaky.start()
leaky_port = leaky.port
saved_probe, g._port_is_open = g._port_is_open, lambda _port: True
try:
    raises(g.ServerError, g.Reason.LEFT_RUNNING, leaky.stop)
finally:
    g._port_is_open = saved_probe
assert not g._port_is_open(leaky_port), "the server itself should still have died"

# 6. the preflight: never race a second writer onto one config.yaml.
del os.environ["PAI_GOOSE_ALLOW_CONCURRENT"]
saved_ps, g._ps_lines = g._ps_lines, lambda: ["  4242 /opt/homebrew/bin/goose serve --port 3284"]
try:
    exc = raises(g.ServerError, g.Reason.FOREIGN_GOOSE, server().start)
    assert "4242" in exc.detail, exc.detail
    g._ps_lines = lambda: ["  4242 /bin/zsh -l"]
    clear = server()
    clear.start()
    clear.stop()
finally:
    g._ps_lines = saved_ps
    os.environ["PAI_GOOSE_ALLOW_CONCURRENT"] = "1"

# 7. Ctrl-C. _on_signal is CALLED, never delivered: with .coveragerc's
#    `sigterm = True`, a handler that restores SIG_DFL and re-raises overwrites
#    coverage's own handler and the process writes no data file at all.
interrupted = server()
interrupted.start()
interrupted_port = interrupted.port
try:
    g._on_signal(signal.SIGINT, None)
    raise AssertionError("_on_signal must re-raise after cleaning up")
except KeyboardInterrupt:
    pass
assert not g._port_is_open(interrupted_port), "the signal path left a listener running"
assert g._LIVE == [], g._LIVE
# and with nothing live it is still a pass-through, not a crash.
try:
    g._on_signal(signal.SIGINT, None)
    raise AssertionError("_on_signal must re-raise")
except KeyboardInterrupt:
    pass

# 8. the atexit path, which is the one that runs when nobody was watching.
last = server()
last.start()
last_port = last.port
g._stop_all()
assert not g._port_is_open(last_port)
g._stop_all()                                  # nothing live: the empty arm

Path(WORK, "life.ok").write_text("ok")
PY
gc_probe "spawn, readiness, teardown proof, crash marker, signal path" \
  "$GC_WORK/probe-life.py"

# ---- 9. `pai doctor --fix`: the one mutating verb ----------------------------
# doctor.py was READ-ONLY BY DESIGN until #34 and said so in its header; --fix
# is a real change to a stated contract, so it gets a section of its own and the
# read-only proof above stays restricted to the verbs that still honour it.
#
# THE FIXTURE IS TWO FILES, and the split is an artefact of the test double, not
# of the design. On a real machine the ACP view and ~/.config/goose/config.yaml
# are the same config: goose writes the file from the state ACP reads. The fake
# persists ACP state as JSON in the WIRE shape (`{extension: {...}, enabled:
# bool}`), which is not the disk shape doctor's read-only half parses, so:
#
#   $state          the fake's write-through file -- the ACP truth, and the only
#                   thing --fix's plan is computed from or proven against
#   $home/.config/goose/config.yaml
#                   read by --fix for ONE thing: the inline `envs` values, which
#                   are unreadable over ACP in both directions (measured)
#
# The consequence, stated rather than papered over: a plain `pai doctor` after a
# `--fix` cannot observe the repair offline, because the disk file the fake
# writes is not in config.yaml's shape. The re-assert is proven instead by a
# second `--dry-run` finding nothing left to do -- read through the same ACP
# read-back that IS the state, which is the stronger of the two claims.
FIX_WORK="$WORK/fix"
mkdir -p "$FIX_WORK/tmp"

# Derived from the repo's own template at run time, exactly like make_clean and
# for the same reason: a committed seed would be asserting yesterday's template.
# goosecfg.to_wire does the disk->ACP translation so this fixture cannot drift
# from the one --fix will send.
seed_state() { # seed_state <state.json> <mutator-name>
  "${FIX_PY[@]}" - "$REPO_ROOT" "$1" "$2" <<'PY'
import importlib.util, json, pathlib, sys
import yaml
repo, out, mutation = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
spec = importlib.util.spec_from_file_location("gc_seed", repo / "scripts/pai/goosecfg.py")
g = importlib.util.module_from_spec(spec)
sys.modules["gc_seed"] = g
spec.loader.exec_module(g)
tpl = yaml.safe_load((repo / "config/goose/config.yaml").read_text())["extensions"]
state = {"extensions": {}, "secrets": {}}
for name, block in tpl.items():
    if block.get("type") in ("builtin", "platform"):
        # goose's own: the wire entry carries neither a command nor a url, which
        # is exactly why --fix compares only `enabled` on these.
        wire = {"type": block["type"], "name": name, "timeout": block.get("timeout")}
    else:
        wire = g.to_wire(name, block, {})
    state["extensions"][name] = {"enabled": bool(block.get("enabled")), "extension": wire}
# goose's own extensions, which must be reported as NOTE and never touched.
for extra in ("computercontroller", "scheduler", "tutorial"):
    state["extensions"][extra] = {"enabled": True,
                                  "extension": {"type": "builtin", "name": extra}}
ws = state["extensions"]["workspace-mcp"]
if mutation in ("drift", "restart"):
    # The three drifts criterion 4 names, and they are the measured ones: the
    # live Mac has workspace-mcp UNPINNED with no --permissions, an
    # available_tools of length 0, and apps.enabled true.
    ws["extension"]["server"]["args"] = ["workspace-mcp", "--tools", "gmail"]
    ws["extension"]["available_tools"] = []
    state["extensions"]["apps"]["enabled"] = True
if mutation == "restart":
    # ...plus one goose put back that the first --fix had already promoted: a
    # dropped env_key. env_keys is the one field compared as a SUPERSET, so this
    # is the arm where that comparison has to say NO.
    ws["extension"]["envKeys"] = ws["extension"]["envKeys"][:1]
if mutation == "disabled":
    ws["enabled"] = False
    ws["extension"]["available_tools"] = []
out.write_text(json.dumps(state, indent=2))
PY
}

# The disk half. `envs` is the only key --fix reads from it, so that is the only
# key it carries; anything else here would imply doctor's read-only half can see
# the fake, which it cannot.
seed_home() { # seed_home <home> <envs-value-or-empty>
  mkdir -p "$1/.config/goose"
  if [ -z "${2:-}" ]; then
    printf 'extensions: {}\n' > "$1/.config/goose/config.yaml"
  else
    printf 'extensions:\n  workspace-mcp:\n    envs:\n      USER_GOOGLE_EMAIL: %s\n' \
      "$2" > "$1/.config/goose/config.yaml"
  fi
}

# A value that is obviously not a secret, so the "the value never reaches the
# output" assertion below can name it. Never a real address.
FAKE_EMAIL="not-a-real-address@example.invalid"

# --fix spawns its own `goose serve` stand-in through goosecfg, so it needs the
# same TMPDIR redirection and tuning seams section 8 uses -- and the markers it
# leaves under $FIX_WORK/tmp are what the EXIT trap reaps.
run_fix() { # run_fix <home> <state> <mode> [flags...]
  local home="$1" state="$2" mode="$3"
  shift 3
  FIX_RC=0
  FIX_OUT="$(TMPDIR="$FIX_WORK/tmp" PAI_GOOSE_READY_S=3 PAI_GOOSE_STOP_S=0.5 \
      PAI_GOOSE_ALLOW_CONCURRENT=1 PAI_GOOSE_BIN="$FAKE_ACP" \
      PAI_FAKE_CONFIG="$state" PAI_FAKE_MODE="$mode" \
      pai doctor "$home" "$@" 2>&1)" || FIX_RC=$?
}

fix_rc() { # fix_rc <label> <wanted>
  if [ "$FIX_RC" = "$2" ]; then
    pass "$1"
  else
    fail "$1 (exit $FIX_RC, wanted $2)"$'\n'"$FIX_OUT"
  fi
}
fix_says() { # fix_says <label> <extended-regex>
  if printf '%s\n' "$FIX_OUT" | grep -qE -- "$2"; then
    pass "$1"
  else
    fail "$1 — no line matched /$2/"$'\n'"$FIX_OUT"
  fi
}
fix_silent() { # fix_silent <label> <extended-regex>
  if printf '%s\n' "$FIX_OUT" | grep -qE -- "$2"; then
    fail "$1 — /$2/ appeared in the output"$'\n'"$FIX_OUT"
  else
    pass "$1"
  fi
}

FIX_HOME="$FIX_WORK/home"
FIX_STATE="$FIX_WORK/state.json"
seed_home "$FIX_HOME" ""
seed_state "$FIX_STATE" drift

# 9a. --dry-run says what it would do and WRITES NOTHING. Same byte-hash proof
#     as section 5, applied to the mutating half: a dry run whose plan differs
#     from --fix's, or that touches the config, is worse than no dry run.
DRY_BEFORE="$(shasum < "$FIX_STATE")"
run_fix "$FIX_HOME" "$FIX_STATE" ok --dry-run
DRY_AFTER="$(shasum < "$FIX_STATE")"
fix_rc "--dry-run exits 1 while fixable drift remains" 1
fix_says "--dry-run plans the workspace-mcp pin" 'WOULD +workspace-mcp\.args'
fix_says "--dry-run plans the allowlist" 'WOULD +workspace-mcp\.available_tools'
fix_says "--dry-run plans re-disabling apps" 'WOULD +apps\.enabled'
fix_says "--dry-run says so, in the summary" 'NOTHING WAS WRITTEN'
fix_silent "--dry-run fixes nothing" '^FIXED'
if [ "$DRY_BEFORE" = "$DRY_AFTER" ]; then
  pass "--dry-run left the live config byte-identical"
else
  fail "--dry-run wrote to the config it was only supposed to describe"
fi

# 9b. the acceptance criterion itself: the pin, the --permissions flag, the
#     allowlist, and apps re-disabled — in one run, each proven by read-back.
run_fix "$FIX_HOME" "$FIX_STATE" ok --fix
fix_rc "--fix exits 0 when everything fixable was fixed" 0
fix_says "--fix restores the workspace-mcp pin and --permissions" 'FIXED +workspace-mcp\.args'
fix_says "--fix restores the allowlist" 'FIXED +workspace-mcp\.available_tools'
fix_says "--fix re-disables apps" 'FIXED +apps\.enabled'
fix_says "goose's own extensions are a NOTE, never touched" 'not ours, never touched \(3\)'
if "${FIX_PY[@]}" - "$FIX_STATE" "$REPO_ROOT" <<'PY'
import json, pathlib, sys
import yaml
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
tpl = yaml.safe_load((pathlib.Path(sys.argv[2]) / "config/goose/config.yaml").read_text())
want = tpl["extensions"]["workspace-mcp"]
ws = state["extensions"]["workspace-mcp"]
# The DISK side of the same claim: not "doctor printed FIXED" but "the server
# stored the template's own bytes", read straight out of the fake's file.
assert ws["extension"]["server"]["args"] == want["args"], ws["extension"]["server"]["args"]
assert ws["extension"]["available_tools"] == want["available_tools"]
assert ws["enabled"] is True, ws
assert state["extensions"]["apps"]["enabled"] is False, state["extensions"]["apps"]
PY
then
  pass "the fixed values are what the repo's template declares, read off the server"
else
  fail "--fix reported success and the stored config disagrees"
fi

# 9c. idempotence. A second --fix finds nothing, and a --dry-run agrees: there
#     is no journal, so this is the read-back saying the re-assert stuck.
run_fix "$FIX_HOME" "$FIX_STATE" ok --fix
fix_rc "a second --fix exits 0" 0
fix_silent "a second --fix changes nothing" '^FIXED'
fix_says "...and says so" '== fix: 0 fixed, 0 unfixed'
run_fix "$FIX_HOME" "$FIX_STATE" ok --dry-run
fix_rc "--dry-run on a repaired config exits 0" 0
fix_silent "--dry-run on a repaired config plans nothing" '^WOULD'

# 9d. criterion 4: a goose restart puts the keys back, and re-running detects
#     and re-asserts them by the same code path. Also drives env_keys' superset
#     comparison in the direction that must FAIL — a declared key goose lost.
seed_state "$FIX_STATE" restart
run_fix "$FIX_HOME" "$FIX_STATE" ok --fix
fix_rc "after a simulated goose restart, --fix exits 0" 0
fix_says "...and re-asserts the pin" 'FIXED +workspace-mcp\.args'
fix_says "...and the allowlist" 'FIXED +workspace-mcp\.available_tools'
fix_says "...and apps" 'FIXED +apps\.enabled'
fix_says "...and the env_keys goose dropped" 'FIXED +workspace-mcp\.env_keys'

# 9e. THE FAIL-OPEN ONE. goose accepts the allowlist, answers success, and
#     stores no allowlist key at all — which means every tool is allowed. --fix
#     must report FAIL, must NOT enable, and must exit 1.
DROP_STATE="$FIX_WORK/drop.json"
seed_state "$DROP_STATE" disabled
run_fix "$FIX_HOME" "$DROP_STATE" drop-allowlist --fix
fix_rc "a dropped allowlist is an unfixed FAIL, exit 1" 1
fix_says "...reported as FAIL, not FIXED" '^FAIL +workspace-mcp\.available_tools'
fix_says "...naming the reason machine-readably" 'allowlist-dropped'
if "${FIX_PY[@]}" -c 'import json,sys;s=json.load(open(sys.argv[1]));sys.exit(0 if s["extensions"]["workspace-mcp"]["enabled"] is False else 1)' "$DROP_STATE"; then
  pass "a failed read-back left the extension DISABLED — the safe end"
else
  fail "--fix enabled an extension whose allowlist goose had silently dropped"
fi
# ...and the drift is still there afterwards, which is the other half of "did
# not fix it". This is also the arm where the live allowlist key is ABSENT
# rather than a list, so the set-comparison in field_matches falls through.
run_fix "$FIX_HOME" "$DROP_STATE" ok --dry-run
fix_rc "the unfixed drift is still reported afterwards" 1
fix_says "...still naming the allowlist" 'WOULD +workspace-mcp\.available_tools'

# 9f. `envs`. MEASURED: it is unreachable over ACP in both directions and ANY
#     ACP write leaves disk `envs: {}`. The author's live machine has
#     USER_GOOGLE_EMAIL populated, so the default has to be to leave the whole
#     extension alone and say why.
ENV_HOME="$FIX_WORK/envhome"
ENV_STATE="$FIX_WORK/env.json"
seed_home "$ENV_HOME" "$FAKE_EMAIL"
seed_state "$ENV_STATE" drift
run_fix "$ENV_HOME" "$ENV_STATE" ok --fix
fix_rc "an inline envs value does not make --fix fail" 0
fix_says "...the extension holding it is refused by name" 'workspace-mcp NOT TOUCHED'
fix_says "...naming the KEY and the remedy" 'USER_GOOGLE_EMAIL'
fix_says "...and pointing at the flag" '--migrate-envs'
fix_silent "...and never printing the value" "$FAKE_EMAIL"
fix_silent "...and not repairing it behind the refusal" 'FIXED +workspace-mcp'
fix_says "...while still fixing what it may" 'FIXED +apps\.enabled'

# ...and with the flag, the one announced migration, proven by config/read
# {isSecret: true} returning non-null. The VALUE is never asked for.
run_fix "$ENV_HOME" "$ENV_STATE" ok --fix --migrate-envs
fix_rc "--migrate-envs exits 0" 0
fix_says "the migration is announced before it happens" 'migrating USER_GOOGLE_EMAIL'
fix_says "...it is called one way, in those words" 'ONE WAY'
fix_says "...and the extension is then repaired" 'FIXED +workspace-mcp\.args'
fix_silent "...still without printing the value" "$FAKE_EMAIL"
if "${FIX_PY[@]}" - "$ENV_STATE" <<'PY'
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
ws = state["extensions"]["workspace-mcp"]["extension"]
# The NAME reached env_keys and the store holds the key. Nothing here looks at,
# compares, or prints what the value is — that is the repo's rule, and it is
# also all goose would give us (config/read masks it).
assert "USER_GOOGLE_EMAIL" in ws["envKeys"], ws["envKeys"]
assert "USER_GOOGLE_EMAIL" in state["secrets"], sorted(state["secrets"])
PY
then
  pass "the promoted key reached env_keys and goose's secret store, by name only"
else
  fail "the announced envs migration did not land"
fi

# ...and the promotion SURVIVES the next repair, which is the half that is easy
# to get wrong and impossible to notice. `config/extensions/add` is a FULL
# REPLACE, so a payload carrying only the template's `env_keys` would delete the
# name the migration had just appended: the value would still be in goose's
# secret store and the extension would silently stop being handed it, while the
# planner's superset comparison went on calling the narrowed list a match.
# Drift is re-introduced by editing ONE key rather than re-seeding, because
# seed_state would rewrite `envKeys` and destroy the very thing under test.
"${FIX_PY[@]}" - "$ENV_STATE" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
state = json.loads(path.read_text())
state["extensions"]["workspace-mcp"]["extension"]["server"]["args"] = [
    "workspace-mcp", "--tools", "gmail",
]
path.write_text(json.dumps(state, indent=2))
PY
# goose has emptied inline `envs` by now -- that is what the migration did to it
# -- so this run is a plain --fix with nothing left to refuse.
seed_home "$ENV_HOME" ""
run_fix "$ENV_HOME" "$ENV_STATE" ok --fix
fix_rc "a repair AFTER the migration exits 0" 0
fix_says "...and re-asserts the pin" 'FIXED +workspace-mcp\.args'
if "${FIX_PY[@]}" -c 'import json,sys;s=json.load(open(sys.argv[1]));sys.exit(0 if "USER_GOOGLE_EMAIL" in s["extensions"]["workspace-mcp"]["extension"]["envKeys"] else 1)' "$ENV_STATE"; then
  pass "the migrated env_key survived that repair, still wired to the extension"
else
  fail "a later --fix dropped the migrated env_key: stored, and no longer delivered"
fi

# A live `envs` still holding the template's own placeholder is dropped, never
# promoted: putting a fiction in the secret store is worse than doing nothing.
PLACEHOLDER_HOME="$FIX_WORK/placeholderhome"
seed_home "$PLACEHOLDER_HOME" "you@example.com"
seed_state "$FIX_STATE" drift
run_fix "$PLACEHOLDER_HOME" "$FIX_STATE" ok --fix
fix_rc "a placeholder envs value does not block the repair" 0
fix_says "...it is dropped, and said so" 'USER_GOOGLE_EMAIL still holds the template.s placeholder'
fix_says "...and the extension is repaired anyway" 'FIXED +workspace-mcp\.args'

# 9g. set-enabled answers {} whatever it did, so the enabled-only path reads
#     back too. `ignore-enable` is the mode that proves it.
seed_state "$FIX_STATE" drift
run_fix "$FIX_HOME" "$FIX_STATE" ignore-enable --fix
fix_rc "a set-enabled that silently did nothing is an unfixed FAIL" 1
fix_says "...reported against apps" '^FAIL +apps\.enabled'
fix_says "...saying the read-back is what disagreed" 'read-back disagrees'

# 9h. the split-brain guard. PAI_HOME retargets everything doctor READS and
#     nothing it WRITES, so without this `PAI_HOME=/tmp/fixture pai doctor
#     --fix` diagnoses a fixture and repairs the real machine.
SPLIT_RC=0
SPLIT_OUT="$(PAI_HOME="$FIX_HOME" TMPDIR="$FIX_WORK/tmp" \
  env -u GOOSE_ACP_URL -u PAI_GOOSE_BIN \
  "${PAI_PY[@]}" "$DOCTOR" doctor --fix 2>&1)" || SPLIT_RC=$?
if [ "$SPLIT_RC" -eq 2 ] && printf '%s' "$SPLIT_OUT" | grep -q "refusing --fix"; then
  pass "--fix refuses a PAI_HOME that is not \$HOME with no goose named"
else
  fail "--fix would have repaired this machine while diagnosing a fixture (exit $SPLIT_RC)"$'\n'"$SPLIT_OUT"
fi
# ...and the same run is allowed once $HOME and PAI_HOME agree, which is the
# other arm of the guard. HOME is pointed at the FIXTURE rather than --fix at
# this machine, for the obvious reason -- and the assignment is a prefix on a
# function call, which bash outside POSIX mode scopes to that call alone
# (verified). If that ever stopped being true, every later line in this file
# would be running against a fake $HOME.
seed_state "$FIX_STATE" drift
HOME="$FIX_HOME" run_fix "$FIX_HOME" "$FIX_STATE" ok --dry-run
fix_rc "--fix is allowed when PAI_HOME is \$HOME" 1
fix_says "...and plans the same repairs" 'WOULD +workspace-mcp\.args'

# 9i. no goose, and none spawnable: exit 2, not a traceback and not a silent 0.
run_fix "$FIX_HOME" "$FIX_STATE" ok --fix
NOGOOSE_RC=0
NOGOOSE_OUT="$(TMPDIR="$FIX_WORK/tmp" PAI_GOOSE_READY_S=1 PAI_GOOSE_ALLOW_CONCURRENT=1 \
  PAI_GOOSE_BIN="$FIX_WORK/no-such-goose" PAI_HOME="$FIX_HOME" \
  "${PAI_PY[@]}" "$DOCTOR" doctor --fix 2>&1)" || NOGOOSE_RC=$?
if [ "$NOGOOSE_RC" -eq 2 ] && printf '%s' "$NOGOOSE_OUT" | grep -q "no usable goose ACP session"; then
  pass "no goose reachable and none spawnable exits 2, naming both seams"
else
  fail "an unreachable goose exited $NOGOOSE_RC"$'\n'"$NOGOOSE_OUT"
fi

# 9j. the option vocabulary. An unknown flag must be a usage error, not a word
#     that silently degrades `pai doctor --fx` into a harmless-looking report.
BAD_RC=0
pai doctor "$FIX_HOME" --fx >/dev/null 2>&1 || BAD_RC=$?
if [ "$BAD_RC" -eq 2 ]; then
  pass "an unknown doctor flag exits 2 (usage)"
else
  fail "an unknown doctor flag exited $BAD_RC, wanted 2"
fi
LONE_RC=0
pai doctor "$FIX_HOME" --migrate-envs >/dev/null 2>&1 || LONE_RC=$?
if [ "$LONE_RC" -eq 2 ]; then
  pass "--migrate-envs without --fix exits 2 rather than reading as a plain doctor"
else
  fail "--migrate-envs alone exited $LONE_RC, wanted 2"
fi

# 9k. THE FLAG ACTUALLY REACHES doctor.py THROUGH bin/pai. cli.sh used to
#     `exec ... "$1"`, which dropped every flag — so without this assertion the
#     entire section above could pass while `pai doctor --fix` did nothing at
#     all. It costs zero coverage (cli.sh runs its own python3) and is the only
#     thing that proves the "$@" change.
SHIM_RC=0
"$REPO_ROOT/bin/pai" doctor --fx >/dev/null 2>&1 || SHIM_RC=$?
if [ "$SHIM_RC" -eq 2 ]; then
  pass "bin/pai forwards doctor's flags verbatim (an unknown one is its exit 2)"
else
  fail "bin/pai dropped the flag: --fx exited $SHIM_RC, wanted doctor.py's 2"
fi
SHIM_DRY_RC=0
SHIM_DRY_OUT="$(PAI_HOME="$FIX_HOME" TMPDIR="$FIX_WORK/tmp" PAI_GOOSE_READY_S=3 \
  PAI_GOOSE_ALLOW_CONCURRENT=1 PAI_GOOSE_BIN="$FAKE_ACP" PAI_FAKE_CONFIG="$FIX_STATE" \
  "$REPO_ROOT/bin/pai" doctor --dry-run 2>&1)" || SHIM_DRY_RC=$?
if printf '%s' "$SHIM_DRY_OUT" | grep -q "NOTHING WAS WRITTEN"; then
  pass "bin/pai doctor --dry-run reaches the real dry run (exit $SHIM_DRY_RC)"
else
  fail "bin/pai doctor --dry-run did not run one"$'\n'"$SHIM_DRY_OUT"
fi

# 9l. the planner arms no live server can produce, driven in process. Same
#     file-not-stdin and register-before-exec_module rules as sections 6 and 8.
#     These are template shapes the repo does not ship and must never ship
#     silently: a camelCase allowlist, an `enabled: true` with no allowlist, a
#     placeholder in a DECLARED field, a builtin that is simply absent.
cat > "$FIX_WORK/probe-plan.py" <<'PY'
"""doctor's --fix planner on template shapes the repo deliberately does not ship."""
import importlib.util
import sys

DOCTOR, = sys.argv[1:2]
spec = importlib.util.spec_from_file_location("doctor_plan_probe", DOCTOR)
assert spec and spec.loader
mod = importlib.util.module_from_spec(spec)
sys.modules["doctor_plan_probe"] = mod
spec.loader.exec_module(mod)

MCP = {"type": "stdio", "enabled": True, "cmd": "uvx", "args": ["x@1"],
       "available_tools": ["get_events"]}


def texts(findings):
    return " || ".join(f.text for f in findings)


# 1. field_matches: the two fields whose comparison must be NO STRICTER than
#    goosecfg's prover, or --fix re-applies the same extension forever.
assert mod.field_matches("env_keys", ["A"], ["A", "PROMOTED"]) is True
assert mod.field_matches("env_keys", ["A", "B"], ["A"]) is False
assert mod.field_matches("available_tools", ["a", "b"], ["b", "a"]) is True
assert mod.field_matches("available_tools", ["a"], None) is False
assert mod.field_matches("args", ["a", "b"], ["b", "a"]) is False
assert mod.field_matches("timeout", 300, 300) is True

# 2. a placeholder in a DECLARED field is skipped by the differ entirely: --fix
#    never invents a value, and the read-only half already NOTEs it.
assert mod.diff_fields({"cmd": "<your cmd>"}, {"cmd": "uvx"}) == []
assert mod.diff_fields({"cmd": "uvx"}, {"cmd": "npx"}) == [("cmd", "npx", "uvx")]

# 3. camelCase in the template: refused BEFORE any write, because goose accepts
#    it and stores no allowlist at all.
camel = dict(MCP, availableTools=["t"])
repairs, notes = mod.plan_mcp("camel", camel, None, {}, migrate_envs=False)
assert repairs == [], repairs
assert "camelCase" in texts(notes), texts(notes)

# 4. enabled: true with no allowlist -> APPLIED, left DISABLED. Two refusals,
#    not one; collapsing them makes playwright and tavily permanently unfixable.
naked = {"type": "stdio", "enabled": True, "cmd": "npx"}
repairs, notes = mod.plan_mcp("naked", naked, None, {}, migrate_envs=False)
assert len(repairs) == 1 and repairs[0].enable is False, repairs
assert "left DISABLED" in texts(notes), texts(notes)
assert "add it, disabled" in repairs[0].lines[0], repairs[0].lines

# 5. a builtin that is absent: ACP's add speaks `type: mcp` only.
repairs, notes = mod.plan_platform("apps", {"type": "platform", "enabled": False}, None)
assert repairs == [] and "cannot create one" in texts(notes), (repairs, texts(notes))

# 6. plan_fix's own two empty arms: a template with no builtin/platform block,
#    and a live config holding nothing goose added of its own.
repairs, notes = mod.plan_fix({"extensions": {"x": MCP}}, {"x": MCP}, {}, migrate_envs=False)
assert repairs == [], repairs
assert [n.text for n in notes] == [mod.OUT_OF_SCOPE.text], texts(notes)

# 7. apply_repair's detail-less exception arm: reason alone, no ": ".
import goosecfg  # noqa: E402 -- sys.path[0] is scripts/pai only for the real CLI


class Refuses:
    def set_enabled(self, key, *, enabled):
        raise goosecfg.ServerError(goosecfg.Reason.NOT_READY)


bare = mod.Repair("apps", ("apps.enabled",), {}, {}, True, enabled_only=True)
assert mod.apply_repair(Refuses(), bare) == goosecfg.Reason.NOT_READY
PY
PLAN_RC=0
PLAN_OUT="$(PYTHONPATH="$REPO_ROOT/scripts/pai" "${PAI_PY[@]}" "$FIX_WORK/probe-plan.py" \
  "$DOCTOR" 2>&1)" || PLAN_RC=$?
if [ "$PLAN_RC" -eq 0 ]; then
  pass "--fix planner: both refusals, the placeholder skip, and the convergence rules"
else
  fail "--fix planner probe failed:"$'\n'"$PLAN_OUT"
fi

# ---- 10. the derived rosters -------------------------------------------------
# `pai verify` used to carry two hardcoded strings, and they had drifted:
# brain.yaml claims check-brain.sh AND check-security.sh and only the first was
# ever run. Both halves are asserted here — doctor.py's `units --field`
# projection in process (that is the measured half), and the SHELL that consumes
# it through a miniature repo, because the roster's whole point is which
# processes actually get launched.

# --- 10a. `pai units --field`, in process so it counts toward coverage --------
cat > "$WORK/probe-units.py" <<'PY'
import contextlib
import importlib.util
import io
import sys
from pathlib import Path

doctor_path, work = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("doctor_units", doctor_path)
assert spec and spec.loader
mod = importlib.util.module_from_spec(spec)
sys.modules["doctor_units"] = mod
spec.loader.exec_module(mod)


def run(repo, argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = mod.projection(Path(repo), argv)
    return rc, out.getvalue().splitlines(), err.getvalue()


# The catalogue is written here rather than copied from config/units/, because
# every assertion below is about a SHAPE the real catalogue does not currently
# contain: two units naming the same check, an entry carrying arguments, a
# `checklist` host. Copying the real one would make these assertions true by
# whatever the repo happens to ship this month.
repo = Path(work) / "unitsproj"
(repo / "config/units").mkdir(parents=True)
for stem, body in {
    "aa-mac": "id: aa-mac\nhost: mac\nverify:\n  - scripts/verify/check-alpha.sh\n",
    "bb-vps": "id: bb-vps\nhost: vps\nverify:\n"
              "  - scripts/verify/check-beta.sh --local\n",
    # Names check-alpha.sh a SECOND time: the de-duplication arm. Without it the
    # roster would run one script twice and count its verdict twice.
    "cc-both": "id: cc-both\nhost: both\nverify:\n  - scripts/verify/check-alpha.sh\n"
               "  - scripts/verify/check-gamma.sh\n",
    "dd-list": "id: dd-list\nhost: checklist\nverify: []\n",
}.items():
    (repo / "config/units" / f"{stem}.yaml").write_text(body)

ALPHA = "scripts/verify/check-alpha.sh"
BETA = "scripts/verify/check-beta.sh --local"
GAMMA = "scripts/verify/check-gamma.sh"

# 1. the union, in manifest order, de-duplicated, arguments carried VERBATIM.
assert run(repo, ["--field", "verify"]) == (0, [ALPHA, BETA, GAMMA], ""), run(
    repo, ["--field", "verify"])
# 2. the other field.
assert run(repo, ["--field", "id"]) == (
    0, ["aa-mac", "bb-vps", "cc-both", "dd-list"], ""), run(repo, ["--field", "id"])

# 3. host filtering, all four values. `both` counts for every host, which is why
#    check-gamma.sh survives --host mac and --host vps alike, and why --host both
#    keeps only the units every machine has.
assert run(repo, ["--field", "verify", "--host", "mac"])[1] == [ALPHA, GAMMA]
assert run(repo, ["--field", "verify", "--host", "vps"])[1] == [BETA, ALPHA, GAMMA]
assert run(repo, ["--field", "verify", "--host", "both"])[1] == [ALPHA, GAMMA]
assert run(repo, ["--field", "verify", "--host", "checklist"])[1] == [ALPHA, GAMMA]
assert run(repo, ["--field", "id", "--host", "checklist"])[1] == ["cc-both", "dd-list"]

# 4. every usage refusal is exit 2 and says what the vocabulary is. A roster
#    that silently reads as empty is the failure this whole issue is about.
for argv, needle in (
    ([], "--field must be one of"),
    (["--field"], "--field needs a value"),
    (["--field", "verrify"], "'verrify'"),
    (["--field", "verify", "--host"], "--host needs a value"),
    (["--field", "verify", "--host", "brain"], "--host must be one of"),
    (["--field", "verify", "--nope"], "unknown option '--nope'"),
):
    rc, lines, err = run(repo, argv)
    assert (rc, lines) == (2, []), (argv, rc, lines)
    assert needle in err, (argv, err)

# 5. a checkout with no config/units/ at all: empty, not a crash and not a raise.
assert run(Path(work) / "no-such-repo", ["--field", "verify"]) == (0, [], "")

# 6. AN UNREADABLE MANIFEST IS EXIT 1, with the readable values still printed.
#    `pai list` reports the same stems and returns 0 — a menu that says "this
#    one is broken" is reporting. A ROSTER cannot: the caller silently loses a
#    check and nothing tells them. cli.sh turns this non-zero into its own exit
#    2 rather than sweeping a short roster.
(repo / "config/units/zz-broken.yaml").write_text("nope: [unclosed\n")
(repo / "config/units/zz-blank.yaml").write_text("")
rc, lines, err = run(repo, ["--field", "verify"])
assert rc == 1, (rc, err)
assert lines == [ALPHA, BETA, GAMMA], lines
assert "zz-blank, zz-broken" in err, err
PY
if OUT="$("${PAI_PY[@]}" "$WORK/probe-units.py" "$DOCTOR" "$WORK" 2>&1)"; then
  pass "pai units --field: union, order, de-duplication, host filter, every refusal"
else
  fail "units projection probe failed:"$'\n'"$OUT"
fi

# The dispatch arm itself, against the REAL catalogue. The probe above calls
# projection() directly, so without this the `units` case in main() is the one
# statement in doctor.py nothing executes — and an arm that is never dispatched
# is an arm that can be deleted with every assertion still green.
UNITS_OUT="$(pai units "$CLEAN" --field id)"
if printf '%s\n' "$UNITS_OUT" | grep -qx "base-goose"; then
  pass "pai units reaches the dispatch and reads the shipped catalogue"
else
  fail "pai units --field id did not list base-goose:"$'\n'"$UNITS_OUT"
fi

# --- 10b. `pai verify` runs what the manifests name, in a miniature repo ------
# cli.sh and doctor.py both resolve the repo root from their own path, so a
# tree with the same four files in the same four places IS a repo as far as they
# are concerned — no new env seam, and the checks it "runs" are stubs whose exit
# codes are chosen rather than inherited from this machine's goose install.
FR="$WORK/rosterrepo"
mkdir -p "$FR/bin" "$FR/scripts/pai" "$FR/scripts/verify" "$FR/config/units"
cp "$REPO_ROOT/bin/pai" "$FR/bin/pai"
cp "$REPO_ROOT/scripts/pai/cli.sh" "$FR/scripts/pai/cli.sh"
cp "$REPO_ROOT/scripts/pai/doctor.py" "$FR/scripts/pai/doctor.py"
cp "$REPO_ROOT/scripts/verify/lib.sh" "$FR/scripts/verify/lib.sh"
chmod +x "$FR/bin/pai" "$FR/scripts/pai/cli.sh" "$FR/scripts/pai/doctor.py"

mk_check() { # mk_check <id> <exit-code> — a stub that records the argv it saw
  cat > "$FR/scripts/verify/check-$1.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FR/argv-$1.log"
exit $2
EOF
  chmod +x "$FR/scripts/verify/check-$1.sh"
  return 0
}
mk_unit() { # mk_unit <id> <host> [verify entry...]
  local id="$1" host="$2" entry
  shift 2
  printf 'id: %s\nhost: %s\nverify:\n' "$id" "$host" > "$FR/config/units/$id.yaml"
  for entry in "$@"; do
    printf -- '  - %s\n' "$entry" >> "$FR/config/units/$id.yaml"
  done
  return 0
}
verify_run() { # verify_run <PAI_MODE> [pai verify args...] -> VR_OUT, VR_RC
  local mode="$1"
  shift
  VR_RC=0
  VR_OUT="$(PAI_MODE="$mode" "$FR/bin/pai" verify "$@" 2>&1)" || VR_RC=$?
  return 0
}
saw() { # saw <label> <needle>  — one verdict line, matched literally
  if printf '%s\n' "$VR_OUT" | grep -qF -- "$2"; then
    pass "$1"
  else
    fail "$1 — no line matched: $2"$'\n'"$VR_OUT"
  fi
  return 0
}
missing() { # missing <label> <needle>
  if printf '%s\n' "$VR_OUT" | grep -qF -- "$2"; then
    fail "$1 — should not appear: $2"$'\n'"$VR_OUT"
  else
    pass "$1"
  fi
  return 0
}

mk_check alpha 0
mk_check beta 2
mk_check gamma 0
mk_check brain 0
mk_check delta 0   # on disk, claimed by nobody
# A SECOND exit-2 check, in the same unit as check-beta.sh and never named by
# --require. It exists so the escalation has a control: with only one exit-2
# check in the roster, "--require beta escalated ONLY beta" has nothing to be
# measured against, and an arm that escalates every skip unconditionally reads
# identical. See the --require block below.
mk_check epsilon 2
mk_unit aa-mac mac scripts/verify/check-alpha.sh
mk_unit bb-vps vps scripts/verify/check-beta.sh scripts/verify/check-epsilon.sh
mk_unit cc-both both "scripts/verify/check-gamma.sh --flavour salty"
mk_unit dd-brain vps scripts/verify/check-brain.sh
mk_unit ee-none mac

verify_run remote
# THE POINT OF THE WHOLE ISSUE: check-alpha.sh is claimed by a `host: mac` unit
# and check-beta.sh by a `host: vps` one, and BOTH are in the roster on BOTH
# hosts. A host filter over `host:` was the obvious design and it loses
# check-goose.sh and check-providers.sh on the brain — base-goose is `host: mac`
# and is their only owner, and the brain is where goose actually runs.
saw "off-brain: a host:mac unit's check runs" "PASS  check-alpha"
saw "off-brain: a host:vps unit's check is in the roster too" "SKIP  check-beta"
saw "an entry's arguments are in its verdict line" "PASS  check-gamma --flavour salty"
saw "check-brain.sh is the one off-brain exclusion, and it says so" \
  "SKIP  check-brain (runs on the brain; this is remote)"
saw "a check no unit claims is reported, not run" "claimed by no unit"
saw "...naming it" "check-delta.sh"
if [ "$VR_RC" -eq 0 ]; then
  pass "a sweep of passes and skips exits 0"
else
  fail "sweep exited $VR_RC:"$'\n'"$VR_OUT"
fi
if [ "$(cat "$FR/argv-gamma.log")" = "--flavour salty" ]; then
  pass "...and they reach the PROCESS verbatim, with nothing else on its argv"
else
  fail "check-gamma saw argv: $(cat "$FR/argv-gamma.log")"
fi
if [ ! -e "$FR/argv-brain.log" ] && [ ! -e "$FR/argv-delta.log" ]; then
  pass "neither the excluded check nor the unclaimed one was executed"
else
  fail "an excluded check ran anyway"
fi

verify_run local
saw "on the brain: the excluded check runs" "PASS  check-brain"
saw "on the brain: a host:mac unit's check is still in the roster" "PASS  check-alpha"

# --require: NEW CODE, not a port. The comment it replaced cited
# check-connectors.sh:1951 as the precedent it inherited; :1949-1962 is that
# script's AcpClient AuthError handler and its option vocabulary has no
# escalation flag at all. So it owes its own negative test.
verify_run remote --require beta
saw "--require turns a precondition skip into a failure" "FAIL  check-beta (exit 2"
# THE CONTROL, and it has to be another EXIT-2 check. This assertion used to
# read `missing "FAIL  check-alpha"`, which can never fail: check-alpha.sh is
# `mk_check alpha 0` and always renders as PASS, so escalating every skip
# unconditionally left it green (verified by making that exact mutation).
# check-epsilon.sh exits 2, is in the roster, and is NOT required — so the
# over-broad escalation this is written to catch turns this line into
# "FAIL  check-epsilon" and the assertion goes red.
saw "...and an un-required exit 2 in the same unit is still a skip" \
  "SKIP  check-epsilon (exit 2 — precondition missing)"
if [ "$VR_RC" -eq 1 ]; then
  pass "...and the sweep exits 1"
else
  fail "--require sweep exited $VR_RC:"$'\n'"$VR_OUT"
fi

verify_run remote --require check-brain.sh
saw "--require on the off-brain exclusion is a failure, not a silent skip" \
  "FAIL  check-brain — required, but it only runs ON the brain"

verify_run remote --require nonesuch
if [ "$VR_RC" -eq 2 ] && printf '%s\n' "$VR_OUT" | grep -qF "no unit's \`verify:\` claims it"; then
  pass "--require naming a check outside the roster is a usage error, not a green no-op"
else
  fail "--require nonesuch exited $VR_RC:"$'\n'"$VR_OUT"
fi

# THE ROSTER IS THE MANIFEST'S. Empty one unit's `verify:` and its check is gone
# from the sweep — this is the assertion the hardcoded string could not make.
# Asserted at the PROCESS level, not by grepping the output: check-alpha.sh is
# still on disk, so it correctly moves into the "claimed by no unit" list and a
# text match for its name would go green either way.
rm -f "$FR/argv-alpha.log"
mk_unit aa-mac mac
verify_run remote
if [ ! -e "$FR/argv-alpha.log" ]; then
  pass "emptying a unit's verify: stops its check being executed at all"
else
  fail "check-alpha still ran after its manifest stopped claiming it"$'\n'"$VR_OUT"
fi
saw "...and it is reported as claimed by no unit" "check-alpha.sh"
mk_unit aa-mac mac scripts/verify/check-alpha.sh

# An unreadable manifest is a SHORT ROSTER, which must never read as a clean one.
printf 'nope: [unclosed\n' > "$FR/config/units/zz-broken.yaml"
verify_run remote
if [ "$VR_RC" -eq 2 ] && printf '%s\n' "$VR_OUT" | grep -qF "zz-broken"; then
  pass "an unreadable manifest refuses the sweep (exit 2) instead of shortening it"
else
  fail "unreadable manifest gave exit $VR_RC:"$'\n'"$VR_OUT"
fi
rm -f "$FR/config/units/zz-broken.yaml"

# AN EMPTY ROSTER IS THE SILENT GREEN SWEEP, and it is the one shape that has to
# be CONSTRUCTED here rather than described. doctor.py's projection exits 0 with
# EMPTY STDOUT for a checkout with no config/units/ — probe 5 in section 10a
# asserts exactly that, `(0, [], "")` — and cmd_verify only refused a NON-ZERO
# exit. So empty stdout fell through both `while ... <<<"$roster"` loops, every
# check on disk landed in the "claimed by no unit" note, and `finish --skips`
# printed "0 passed, 0 failed, 0 skipped" and exited 0. Reproduced before the
# guard existed: `PAI_MODE=remote pai verify` on this very fixture, EXIT=0.
#
# check-brain.sh:159 refuses the same shape for its schedule roster. This one
# matters more: it is not one check's precondition, it is the whole sweep.
mv "$FR/config/units" "$FR/config/units.away"
verify_run remote
if [ "$VR_RC" -eq 2 ] && printf '%s\n' "$VR_OUT" | grep -qF "roster derived from config/units/*.yaml is EMPTY"; then
  pass "a checkout with no config/units/ refuses the sweep (exit 2)"
else
  fail "a missing config/units/ gave exit $VR_RC:"$'\n'"$VR_OUT"
fi
# Not just the exit code: the footer that CALLED it a success must not print.
# Delete the guard and this line is back, verbatim, over a roster of nothing.
missing "...and never reaches the footer that called that a pass" \
  "== summary: 0 passed, 0 failed, 0 skipped =="
mv "$FR/config/units.away" "$FR/config/units"

# The other way to empty it, and the one that needs no filesystem surgery at
# all: every manifest still present, every `verify:` list empty. One careless
# edit in a real repo, and it read as a clean sweep.
mk_unit aa-mac mac
mk_unit bb-vps vps
mk_unit cc-both both
mk_unit dd-brain vps
mk_unit ee-none mac
verify_run remote
if [ "$VR_RC" -eq 2 ] && printf '%s\n' "$VR_OUT" | grep -qF "is EMPTY"; then
  pass "every manifest's verify: emptied is the same refusal, not a green no-op"
else
  fail "an all-empty catalogue gave exit $VR_RC:"$'\n'"$VR_OUT"
fi
# Put the catalogue back, and PROVE the refusal was about the roster and not
# about the fixture being broken: one entry restored is a running sweep again.
mk_unit aa-mac mac scripts/verify/check-alpha.sh
mk_unit bb-vps vps scripts/verify/check-beta.sh scripts/verify/check-epsilon.sh
mk_unit cc-both both "scripts/verify/check-gamma.sh --flavour salty"
mk_unit dd-brain vps scripts/verify/check-brain.sh
mk_unit ee-none mac
verify_run remote
if [ "$VR_RC" -eq 0 ] && printf '%s\n' "$VR_OUT" | grep -qF "PASS  check-alpha"; then
  pass "...and one restored entry is enough to make it a sweep again"
else
  fail "the restored catalogue gave exit $VR_RC:"$'\n'"$VR_OUT"
fi

# The real catalogue, through the real CLI: brain.yaml's second verify script is
# in the roster now. The blocker it carried said it was in no runner at all.
if REAL_ROSTER="$("$REPO_ROOT/bin/pai" units --field verify)"; then
  if printf '%s\n' "$REAL_ROSTER" | grep -qF "scripts/verify/check-security.sh --local"; then
    pass "the shipped catalogue puts check-security.sh --local in the roster"
  else
    fail "check-security.sh is still in no runner:"$'\n'"$REAL_ROSTER"
  fi
else
  fail "bin/pai units --field verify did not exit 0"
fi

# ---- the `docs` arm: the generated-region gate, through the real CLI ---------
# NAMED, NOT NUMBERED. The section numbers above are claimed in landing order
# and three open PRs each planned "a new section 10"; a name cannot collide.
#
# TWO ASSERTIONS AND NO MORE, on purpose. scripts/verify/docs_lint.py lives on
# the coverage-exempt side of .coveragerc (`omit = scripts/verify/*`) and has
# its own harness, scripts/verify/test-docs-lint.sh, which feeds a broken input
# to every one of its assertions. What is NOT covered there is the thing this
# file owns: that cli.sh's `docs)` arm reaches it at all, and that an unknown
# flag comes back as check-docs.sh's own usage error rather than as a word this
# dispatcher silently drops. Both run through bin/pai and both cost ZERO
# coverage -- cli.sh execs a plain python3 under py_runner, outside $PAI_PY,
# exactly as the `bin/pai list` assertion in section 7 notes.
#
# NEITHER OF THESE MAY BE `pai docs --write`. That is a writing verb, and a test
# that ran it would rewrite the checkout it is running in.
if "$REPO_ROOT/bin/pai" docs >/dev/null 2>&1; then
  pass "bin/pai docs exits 0: the generated regions in README.md are current"
else
  fail "bin/pai docs did not exit 0 — README.md's generated regions are stale," \
       "or the docs) arm does not reach scripts/verify/check-docs.sh"
fi

DOCS_RC=0
DOCS_OUT="$("$REPO_ROOT/bin/pai" docs --no-such-flag 2>&1)" || DOCS_RC=$?
if [ "$DOCS_RC" -eq 2 ] && printf '%s\n' "$DOCS_OUT" | grep -qF "check-docs.sh: unknown argument"; then
  pass "bin/pai docs forwards flags verbatim: an unknown one is check-docs.sh's exit 2"
else
  fail "bin/pai docs --no-such-flag gave exit $DOCS_RC:"$'\n'"$DOCS_OUT"
fi

# Nothing sections 8 and 9 spawned may survive them. The trap at the top of this
# file is the backstop; this is the assertion.
LEFTOVER="$(find "$GC_WORK/tmp/pai-goosecfg" "$FIX_WORK/tmp/pai-goosecfg" \
  -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$LEFTOVER" = "0" ]; then
  pass "goosecfg and --fix: no crash markers and no listeners survived the probes"
else
  fail "$LEFTOVER crash marker(s) survived — a server may still be running"
fi

# ---- 10. `pai secrets` and keychain-secrets.sh --------------------------------
# The roster and the ~/.zshrc block, which is the one place this repo writes to a
# file the USER owns. Two halves:
#
#   10a  the projection, driven through doctor.py under $PAI_PY (coverage).
#   10b  scripts/mac/keychain-secrets.sh run for real, under a FAKE $HOME and a
#        PATH whose `security` and `uname` are stand-ins. Nothing here touches
#        the real Keychain or the real ~/.zshrc, and the harness never learns a
#        value: the fake logs a length (fake-security.sh, following the rule
#        fake-brew.sh:18-22 wrote for it).
#
# THE NAME GOLDENS BELOW ARE HAND-TYPED. Deriving them from the manifests would
# compare the projection with itself: deleting a `store: mac_keychain` row would
# change both sides and the assertion would stay green, which is the exact
# failure mode this file exists to avoid. The PROMPT assertions do read the
# manifest -- there is no way to hand-type a sentence that must not rot -- so
# each is guarded by a minimum length, because `grep -qF ""` matches anything.

# The two names a base install needs, and nothing else. This IS the ticket's
# first acceptance criterion.
WANT_MAC_BASE="OPENCODE_ZEN_API_KEY TOGETHER_API_KEY"
# Every name the catalog can put in the Keychain. Same ten the deleted
# keychain-secrets.sh:12 VARS string listed, now reachable one add-on at a time.
WANT_MAC_ALL="GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET GOOSE_SERVER__SECRET_KEY \
NTFY_AGENT_TOPIC NTFY_EMAIL NTFY_TOPIC OPENCODE_ZEN_API_KEY TAVILY_API_KEY TELEGRAM_BOT_TOKEN \
TOGETHER_API_KEY"
# The four deploy-vps.sh:344 hard-requires.
WANT_VPS_BASE="GOOSE_SERVER__SECRET_KEY NTFY_TOPIC OPENCODE_ZEN_API_KEY TOGETHER_API_KEY"

secret_names() { # secret_names <flags...> -- the key column, space-separated
  pai secrets "$CLEAN" "$@" | cut -f1 | tr '\n' ' ' | sed 's/ $//'
}

names_are() { # names_are <label> <wanted> <flags...>
  local label="$1" wanted="$2"; shift 2
  local got
  got="$(secret_names "$@")"
  if [ "$got" = "$wanted" ]; then
    pass "$label"
  else
    fail "$label"$'\n'"  wanted: $wanted"$'\n'"  got:    $got"
  fi
}

names_are "secrets --host mac is exactly the two names a base install needs" \
  "$WANT_MAC_BASE" --host mac
names_are "secrets --host mac --all is the whole catalog's ten" \
  "$WANT_MAC_ALL" --host mac --all
names_are "secrets --host vps is deploy-vps.sh's four" \
  "$WANT_VPS_BASE" --host vps
names_are "an add-on selection is that unit's names only, not the base ones" \
  "GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET" --host mac --units google-workspace
# THE ONE GOLDEN HERE WHOSE EXPECTED VALUE IS ALSO THE FAILURE VALUE, so it does
# not go through names_are: secret_names discards the exit code and everything on
# stderr, and "base-skills keeps nothing in the Keychain" and "the command
# produced no stdout, for any reason at all" are the same empty string. A `pai
# secrets` that started exiting 2 on a rowless unit would abort the harness here
# with no message under `set -e`, and one that merely grumbled to stderr and
# exited 0 would read as a pass. Assert all three channels instead.
EMPTY_RC=0
EMPTY_OUT="$(pai secrets "$CLEAN" --host mac --units base-skills \
  2>"$WORK/base-skills.err")" || EMPTY_RC=$?
if [ "$EMPTY_RC" != "0" ]; then
  fail "a rowless unit exited $EMPTY_RC, not 0:"$'\n'"$(cat "$WORK/base-skills.err")"
elif [ -n "$EMPTY_OUT" ]; then
  fail "base-skills projected Keychain rows it has none of:"$'\n'"$EMPTY_OUT"
elif [ -s "$WORK/base-skills.err" ]; then
  fail "an empty roster arrived with a complaint on stderr:"$'\n'"$(cat "$WORK/base-skills.err")"
else
  pass "a unit with no secrets in that store projects to nothing: exit 0, no stdout, silent"
fi

# `--host` names the STORE, not the unit's host: `brain` is host: vps and still
# owns the Mac's copy of the shared secret. Without this arm the projection
# could filter on unit.host and every add-on row above would still pass.
names_are "a vps-hosted unit still contributes its Mac Keychain row" \
  "GOOSE_SERVER__SECRET_KEY" --host mac --units brain

# The de-duplication rule, in both argument orders. USER_GOOGLE_EMAIL is
# optional: true in automations and optional: false in google-workspace, so a
# "first row wins" implementation reports it differently depending on the order
# and this is the arm that says no.
for ORDER in "automations,google-workspace" "google-workspace,automations"; do
  NEED="$(pai secrets "$CLEAN" --host vps --units "$ORDER" \
    | awk -F'\t' '$1 == "USER_GOOGLE_EMAIL" { print $2 }')"
  if [ "$NEED" = "required" ]; then
    pass "USER_GOOGLE_EMAIL is required in $ORDER (a unit that needs it wins)"
  else
    fail "USER_GOOGLE_EMAIL read as '$NEED' in $ORDER, wanted required"
  fi
done

# Four usage errors, each exit 2. A roster command that answered 0 with an empty
# list for a typo'd unit would read as "this add-on needs nothing".
secrets_rc() { # secrets_rc <label> <wanted-rc> <grep-string> <flags...>
  local label="$1" want="$2" needle="$3"; shift 3
  local out rc=0
  out="$(pai secrets "$CLEAN" "$@" 2>&1)" || rc=$?
  if [ "$rc" != "$want" ]; then
    fail "$label (exit $rc, wanted $want)"$'\n'"$out"
  elif [ -n "$needle" ] && ! printf '%s\n' "$out" | grep -qF -- "$needle"; then
    fail "$label — the message did not name it: $out"
  else
    pass "$label"
  fi
}

secrets_rc "secrets with no --host is a usage error" 2 "needs --host" --units base-goose
secrets_rc "secrets --host nonsense is a usage error" 2 "nonsense" --host nonsense
secrets_rc "an unknown unit id is a usage error naming it" 2 "zz-not-a-unit" \
  --host mac --units zz-not-a-unit
secrets_rc "--all and --units together are refused" 2 "contradict" \
  --host mac --all --units base-goose
secrets_rc "an unknown flag is a usage error" 2 "bad option" --host mac --wat

# The two arms the CLI cannot reach: a checkout with no config/units/ at all,
# and the mint command's shape as the projection emits it.
cat > "$WORK/probe-secrets.py" <<'PY'
import contextlib
import importlib.util
import io
import sys
from pathlib import Path

doctor_path, work, repo_root = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("doctor_secrets", doctor_path)
assert spec and spec.loader
mod = importlib.util.module_from_spec(spec)
sys.modules["doctor_secrets"] = mod
spec.loader.exec_module(mod)

# A checkout with no manifests at all: an empty roster, exit 0, no traceback.
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = mod.secrets(Path(work) / "norepo", ["--host", "mac"])
assert (rc, buf.getvalue()) == (0, ""), (rc, buf.getvalue())

# The generate column is the command keychain-secrets.sh parses N out of. Read
# from the real tree, and asserted against a HAND-TYPED string: the script does
# `bytes="${gen##* }"` and runs `openssl rand -hex "$bytes"`, so a manifest that
# said `openssl rand 12` (no -hex) would mint raw bytes into a shell variable.
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = mod.secrets(Path(repo_root), ["--host", "mac", "--units", "ntfy-alerts"])
rows = dict(line.split("\t", 1) for line in buf.getvalue().splitlines())
assert rc == 0, rc
assert rows["NTFY_TOPIC"].split("\t")[1] == "openssl rand -hex 12", rows["NTFY_TOPIC"]
assert rows["NTFY_EMAIL"].split("\t")[1] == "-", rows["NTFY_EMAIL"]
PY
if OUT="$("${PAI_PY[@]}" "$WORK/probe-secrets.py" "$DOCTOR" "$WORK" "$REPO_ROOT" 2>&1)"; then
  pass "secrets probe: an empty catalog, and the generate column's exact shape"
else
  fail "secrets probe failed:"$'\n'"$OUT"
fi

# ---- 10b. keychain-secrets.sh against a fake Keychain and a fake HOME ---------
KC="$REPO_ROOT/scripts/mac/keychain-secrets.sh"
KC_WORK="$WORK/keychain"
KC_BIN="$KC_WORK/bin"
KC_HOME="$KC_WORK/home"
mkdir -p "$KC_BIN" "$KC_HOME" "$KC_WORK/state"

# HAND-TYPED, like the name goldens above: reading the marker out of the script
# under test would compare it with itself, and a rename would stay green.
KC_MARKER_BEGIN='# >>> personal-ai keychain exports (keychain-secrets.sh) >>>'

# EXPLICITLY /bin/bash where there is one. macOS ships bash 3.2.57 and that is
# what a reader's `./scripts/mac/keychain-secrets.sh` gets; `command -v bash` on
# a developer Mac is Homebrew's 5.x, so running only that would let a 4.x-ism
# (declare -A, mapfile, ${x^^}) ship untested.
KC_BASH="bash"
# An `if`, not `[ -x /bin/bash ] && KC_BASH=...`: as the AND-list's last (and
# only) statement that would exit 1 wherever /bin/bash is missing, and under
# `set -e` at file scope that kills the harness on the spot.
if [ -x /bin/bash ]; then
  KC_BASH="/bin/bash"
fi

# uname is a three-line stub and is GENERATED, not committed: it exists only so
# the macOS guard passes on ubuntu-latest, and it models nothing. fake-security
# is the opposite -- it has a redaction contract to keep -- so it is a tracked
# file this symlinks to.
cat > "$KC_BIN/uname" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-s" ]; then echo Darwin; exit 0; fi
exec /usr/bin/uname "$@"
EOF
chmod +x "$KC_BIN/uname"
ln -sf "$REPO_ROOT/scripts/verify/fake-security.sh" "$KC_BIN/security"

# A `rm` THAT QUARANTINES INSTEAD OF DELETING, and the reason the leak sweep
# below is worth running. keychain-secrets.sh's EXIT trap removes its own scratch
# files -- the two roster files, the block file, the staged ~/.zshrc -- before
# this script gets to look at anything, so a value that leaked into one of them
# would be erased by the time the sweep ran and the sweep would report "clean"
# over a directory the evidence had been removed from. With this in front of
# PATH, the trap's `rm -f` moves those files aside and the sweep sees exactly
# what the script wrote. Generated, not tracked: like `uname` it models nothing
# and has no contract to keep, and it only ever runs inside kc_env.
KC_QUARANTINE="$KC_WORK/quarantine"
mkdir -p "$KC_QUARANTINE"
cat > "$KC_BIN/rm" <<'EOF'
#!/bin/sh
# Not a general rm. Flags are ignored, operands are moved, the exit code is
# always 0: the point is to let a leak outlive a cleanup trap for one test.
set -eu
: "${FAKE_RM_QUARANTINE:?fake rm: FAKE_RM_QUARANTINE is required}"
mkdir -p "$FAKE_RM_QUARANTINE"
for arg in "$@"; do
  case "$arg" in -*) continue ;; esac
  [ -e "$arg" ] || continue
  mv "$arg" "$(mktemp "$FAKE_RM_QUARANTINE/rm.XXXXXX")" 2>/dev/null || true
done
exit 0
EOF
chmod +x "$KC_BIN/rm"

# The pty driver. keychain-secrets.sh refuses to prompt without a terminal --
# a secret arriving on a pipe came from a file or a history -- so the harness
# gives it a real one instead of deleting the refusal to make testing easy.
cat > "$KC_WORK/pty-run.py" <<'PY'
"""Run a command on a controlling terminal, feeding it canned answers.

ECHO IS TURNED OFF ON THE SLAVE BEFORE THE FORK, and that is the whole reason
this is not `pty.spawn`. `read -s` disables echo around its own read and then
restores what it found, so answers written to the master before the child gets
there are echoed back by the line discipline -- putting the bytes under test
into the captured output, in a file whose job is to prove they never appear.
"""
import fcntl
import os
import select
import sys
import termios
import time

TIMEOUT_S = 60.0


def main(argv):
    with open(argv[1], "rb") as handle:
        answers = handle.read()
    cmd = argv[2:]
    master, slave = os.openpty()
    attrs = termios.tcgetattr(slave)
    attrs[3] &= ~termios.ECHO
    termios.tcsetattr(slave, termios.TCSANOW, attrs)
    pid = os.fork()
    if pid == 0:
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        for fd in (0, 1, 2):
            os.dup2(slave, fd)
        if slave > 2:
            os.close(slave)
        os.close(master)
        os.execvp(cmd[0], cmd)
        raise SystemExit(127)
    os.close(slave)
    os.write(master, answers)
    out = bytearray()
    deadline = time.monotonic() + TIMEOUT_S
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.5)
        if not ready:
            continue
        try:
            chunk = os.read(master, 4096)
        except OSError:
            break                      # Linux raises EIO on the child's exit.
        if not chunk:
            break                      # macOS returns EOF instead.
        out.extend(chunk)
    else:
        os.kill(pid, 9)
        out.extend(b"\npty-run: TIMED OUT waiting for the child\n")
    os.close(master)
    _, status = os.waitpid(pid, 0)
    sys.stdout.buffer.write(bytes(out))
    sys.stdout.flush()
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
PY

KC_LOG="$KC_WORK/security.log"
: >"$KC_LOG"

kc_env() { # kc_env <cmd...> -- run cmd with the fake home, PATH and keystore
  env HOME="$KC_HOME" PATH="$KC_BIN:$PATH" \
    FAKE_SECURITY_LOG="$KC_LOG" FAKE_SECURITY_STATE="$KC_WORK/state" \
    FAKE_RM_QUARANTINE="$KC_QUARANTINE" "$@"
}

kc_run() { # kc_run <flags...> -- headless, no prompts. Sets KC_RC and KC_OUT.
  KC_RC=0
  KC_OUT="$(kc_env "$KC_BASH" "$KC" --rewrite-only "$@" 2>&1)" || KC_RC=$?
  return 0
}

kc_prompted() { # kc_prompted <answers-file> <flags...> -- with a pty
  local answers="$1"; shift
  KC_RC=0
  KC_OUT="$(kc_env python3 "$KC_WORK/pty-run.py" "$answers" "$KC_BASH" "$KC" "$@" 2>&1)" \
    || KC_RC=$?
  return 0
}

# The manifest's own prompt for one (key, store), read the way test-pai.sh:471
# reads a summary. Guarded below by a length floor, because grep -qF "" is true
# of every possible output.
kc_prompt_of() { # kc_prompt_of <manifest> <key> <store>
  "${FIX_PY[@]}" - "$REPO_ROOT/config/units/$1" "$2" "$3" <<'PY'
import pathlib, sys
import yaml
rows = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())["secrets"]
for row in rows:
    if row["key"] == sys.argv[2] and row["store"] == sys.argv[3]:
        print(row["prompt"])
        break
PY
}

kc_mode() { # kc_mode <path> -- the two-arm portable stat, GNU then BSD
  stat -c %a "$1" 2>/dev/null || stat -f %A "$1" 2>/dev/null
}

# ---- the prompting pass ----
# Two answers: a value for the first key, Enter for the second. The value is
# minted HERE, at run time, and it is the sentinel every leak assertion below
# looks for. Nothing in this repo ever writes a secret-shaped constant down.
KC_SENTINEL="$(openssl rand -hex 32)"
printf '%s\n\n' "$KC_SENTINEL" >"$KC_WORK/answers-base"
kc_prompted "$KC_WORK/answers-base"
if [ "$KC_RC" -eq 0 ]; then
  pass "keychain-secrets.sh completes a default run on a fake Mac"
else
  fail "keychain-secrets.sh exited $KC_RC:"$'\n'"$KC_OUT"
fi

# It prompts for the base roster and NOTHING else. The old script asked for all
# ten names on every run, including a Telegram token for a brain-side gateway.
PROMPTED="$(printf '%s\n' "$KC_OUT" | sed -n 's/^  \([A-Z][A-Z0-9_]*\)  .*/\1/p' \
  | tr '\n' ' ' | sed 's/ $//')"
if [ "$PROMPTED" = "$WANT_MAC_BASE" ]; then
  pass "it prompts for exactly the base roster, in the roster's order"
else
  fail "prompted for '$PROMPTED', wanted '$WANT_MAC_BASE'"
fi
case "$KC_OUT" in
  *TELEGRAM_BOT_TOKEN*|*GOOGLE_OAUTH*|*NTFY_*)
    fail "a base run prompted for an add-on's secret:"$'\n'"$KC_OUT" ;;
  *) pass "no add-on name appears in a base run" ;;
esac

# Every prompt carries its manifest's sentence VERBATIM. This is what makes the
# empty parenthetical impossible: with the hint table deleted there is nowhere
# else for the text to come from.
for KEY in OPENCODE_ZEN_API_KEY TOGETHER_API_KEY; do
  TEXT="$(kc_prompt_of base-goose.yaml "$KEY" mac_keychain)"
  if [ "${#TEXT}" -lt 20 ]; then
    fail "$KEY's manifest prompt is ${#TEXT} chars — too short for a grep to mean anything"
  elif printf '%s\n' "$KC_OUT" | grep -qF -- "$TEXT"; then
    pass "$KEY's prompt line carries the manifest's sentence verbatim"
  else
    fail "$KEY's prompt line does not contain its manifest prompt:"$'\n'"$TEXT"$'\n'"$KC_OUT"
  fi
done

# The value went to the keystore as a LENGTH and nowhere else.
if grep -qF "add s=personal-ai a=OPENCODE_ZEN_API_KEY len=64" "$KC_LOG"; then
  # shellcheck disable=SC2016  # backticks in prose, not a command substitution
  pass 'the typed value reached `security add -w` as a length of 64, never as a value'
else
  fail "the fake keychain never saw the add:"$'\n'"$(cat "$KC_LOG")"
fi
if grep -q "^add s=personal-ai a=TOGETHER_API_KEY" "$KC_LOG"; then
  fail "an Enter-skipped key was stored anyway:"$'\n'"$(cat "$KC_LOG")"
else
  pass "pressing Enter stores nothing"
fi
# The sweep is only worth its sentence if the quarantine caught something. Three
# scratch files exist during a run (SELECTED_ROSTER, FULL_ROSTER, BLOCK_FILE);
# the staged ~/.zshrc is consumed by the rename instead of removed. Without this
# guard, a stub that silently stopped working would turn the sweep below into a
# grep over an empty directory.
KC_QUARANTINED="$(find "$KC_QUARANTINE" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ "$KC_QUARANTINED" -ge 3 ] && grep -rqF -- "$KC_MARKER_BEGIN" "$KC_QUARANTINE"; then
  pass "the script's own scratch files ($KC_QUARANTINED) outlived its cleanup trap"
else
  fail "the quarantine holds $KC_QUARANTINED file(s) and no export block — the sweep below is over nothing"
fi
# Now the sweep, over the terminal destination AND the scratch files the script
# builds on the way there.
LEAKED="$(grep -rl -- "$KC_SENTINEL" "$KC_HOME" "$KC_LOG" "$KC_WORK/state" \
  "$KC_QUARANTINE" 2>/dev/null || true)"
if [ -z "$LEAKED" ]; then
  pass "the typed value is in no file the script wrote: fake HOME, log, keystore, scratch"
else
  fail "the value leaked into: $LEAKED"
fi
if printf '%s\n' "$KC_OUT" | grep -qF -- "$KC_SENTINEL"; then
  fail "the value was echoed to the terminal"
else
  pass "the value never appears in the script's own output"
fi

# ---- the ~/.zshrc block ----
ZSHRC="$KC_HOME/.zshrc"
# shellcheck disable=SC2016  # the UNEXPANDED $( ) is exactly what must be there
if grep -qF 'export TOGETHER_API_KEY="$(security find-generic-password -w -s personal-ai -a TOGETHER_API_KEY 2>/dev/null || true)"' "$ZSHRC"; then
  pass "the block writes the \$( ) LITERALLY — the value is fetched at shell init, not baked in"
else
  fail "the export line is not the literal command substitution:"$'\n'"$(cat "$ZSHRC")"
fi
BLOCK_KEYS="$(sed -n 's/^export \([A-Z][A-Z0-9_]*\)=.*/\1/p' "$ZSHRC" | tr '\n' ' ' | sed 's/ $//')"
if [ "$BLOCK_KEYS" = "$WANT_MAC_ALL" ]; then
  pass "the block exports the WHOLE catalog, so a later add-on is already wired"
else
  fail "the block exports '$BLOCK_KEYS'"$'\n'"wanted '$WANT_MAC_ALL'"
fi

# A hand-written file, with sentinels above and below, is what the rest of these
# assertions protect.
# shellcheck disable=SC2016  # a user's own line, which must survive VERBATIM
printf '# my own zshrc\nexport PATH="$HOME/bin:$PATH"\n' >"$ZSHRC"
printf 'alias ll="ls -la"\n' >>"$ZSHRC"
chmod 644 "$ZSHRC"
kc_run
if [ "$KC_RC" -eq 0 ]; then
  pass "--rewrite-only needs no terminal and no prompts"
else
  fail "--rewrite-only exited $KC_RC:"$'\n'"$KC_OUT"
fi
printf 'export AFTER_THE_BLOCK=1\n' >>"$ZSHRC"
cp "$ZSHRC" "$KC_WORK/baseline"

kc_run --units ntfy-alerts
if cmp -s "$KC_WORK/baseline" "$ZSHRC"; then
  pass "regenerating with a different selection is byte-identical (the block is the catalog)"
else
  fail "a different --units rewrote the file:"$'\n'"$(diff "$KC_WORK/baseline" "$ZSHRC" || true)"
fi
kc_run
if cmp -s "$KC_WORK/baseline" "$ZSHRC"; then
  pass "regeneration is idempotent: run it twice, the file is byte-identical"
else
  fail "the second run changed the file:"$'\n'"$(diff "$KC_WORK/baseline" "$ZSHRC" || true)"
fi
if [ "$(kc_mode "$ZSHRC")" = "644" ]; then
  pass "the file's mode survives regeneration (644 in, 644 out)"
else
  fail "mode became $(kc_mode "$ZSHRC"), wanted 644"
fi

# A hand edit INSIDE the markers is the block's content, so it is overwritten.
awk '/^# >>> personal-ai/{print; print "export HAND_EDIT_INSIDE=1"; next} {print}' \
  "$KC_WORK/baseline" >"$ZSHRC"
kc_run
if grep -q HAND_EDIT_INSIDE "$ZSHRC"; then
  fail "an edit inside the markers survived — the block is not regenerated"
elif cmp -s "$KC_WORK/baseline" "$ZSHRC"; then
  pass "an edit INSIDE the markers is overwritten, and only the block is touched"
else
  fail "the file differs from the baseline after overwriting an inside edit:"$'\n'"$(diff "$KC_WORK/baseline" "$ZSHRC" || true)"
fi

# A hand edit OUTSIDE them is the user's file, so it is not.
printf 'export HAND_EDIT_OUTSIDE=1\n' >>"$ZSHRC"
cp "$ZSHRC" "$KC_WORK/with-outside-edit"
kc_run --units google-workspace
if cmp -s "$KC_WORK/with-outside-edit" "$ZSHRC"; then
  pass "an edit OUTSIDE the markers survives byte-for-byte"
else
  fail "the user's own lines changed:"$'\n'"$(diff "$KC_WORK/with-outside-edit" "$ZSHRC" || true)"
fi

# The three malformations. Each must refuse, name what is wrong, and leave the
# file exactly as it found it -- this is the branch that stands between a bug
# here and a broken login shell.
kc_mangled() { # kc_mangled <label> <needle> <file-builder-command...>
  local label="$1" needle="$2"; shift 2
  "$@"
  local before after
  before="$(shasum "$ZSHRC" | cut -d' ' -f1)"
  kc_run
  after="$(shasum "$ZSHRC" | cut -d' ' -f1)"
  if [ "$KC_RC" != "2" ]; then
    fail "$label did not exit 2 (exit $KC_RC)"$'\n'"$KC_OUT"
  elif [ "$before" != "$after" ]; then
    fail "$label exited 2 but the file changed anyway"
  elif ! printf '%s\n' "$KC_OUT" | grep -qF -- "$needle"; then
    fail "$label refused without naming the malformation ('$needle'):"$'\n'"$KC_OUT"
  else
    pass "$label: exit 2, file byte-identical, message names it"
  fi
}

two_begins() {
  cp "$KC_WORK/baseline" "$ZSHRC"
  printf '%s\n' "$KC_MARKER_BEGIN" >>"$ZSHRC"
}
no_end() {
  grep -v '^# <<< personal-ai' "$KC_WORK/baseline" >"$ZSHRC"
}
end_first() {
  {
    printf '%s\n' '# <<< personal-ai keychain exports <<<'
    grep -v '^# <<< personal-ai' "$KC_WORK/baseline"
  } >"$ZSHRC"
}
kc_mangled "two BEGIN markers" "2 begin markers" two_begins
kc_mangled "a BEGIN with no END" "0 end markers" no_end
kc_mangled "an END above the BEGIN" "comes before the begin marker" end_first

# A file this script creates is its own, and 600 is right for one naming every
# credential the machine holds.
rm -f "$ZSHRC"
kc_run
if [ "$KC_RC" -eq 0 ] && [ "$(kc_mode "$ZSHRC")" = "600" ]; then
  pass "a ~/.zshrc that did not exist is created at mode 600"
else
  fail "created ~/.zshrc has mode $(kc_mode "$ZSHRC") (exit $KC_RC)"
fi

# ---- ~/.zshrc IS OFTEN A LINK -------------------------------------------------
# EVERY FIXTURE ABOVE BUILDS A PLAIN FILE, and that is why "the mode survives
# regeneration" and "an edit OUTSIDE the markers survives byte-for-byte" both
# stayed green while the write path stopped honouring the one shape most people
# with a dotfiles repo actually have. stow, chezmoi and yadm all leave ~/.zshrc a
# symlink into that repo; a `mv new ~/.zshrc` REPLACES the link with a regular
# file, so ~/dotfiles/zshrc keeps the old bytes, stays tracked, stays edited, and
# is read by no shell ever again. Nothing tells the user. A hardlink loses the
# same way, one inode at a time.
#
# NINE OF THE TEN ARMS BELOW GO RED against scripts/mac/keychain-secrets.sh as
# this PR first wrote it. That was run: one `git checkout` of that one file, one
# harness run, nine failures. The tenth (a link to a directory) is about the
# refusal's wording, not the link bug, and names its own discriminator where it
# stands. Each of the nine has its own reason:
#   symlink        the link is gone and the dotfiles copy is unchanged
#   through it     the block is in ~/.zshrc, not in the dotfiles repo
#   its mode       755 (a symlink's OWN lstat mode, which BSD `stat -f %A`
#                  reports) chmod'd onto a file naming every credential
#   rewrite branch the awk arm loses the link exactly like the append arm
#   hardlink       link count 2 -> 1, peer detached
#   dangling link  the link is replaced instead of its target being created
#   unwritable     silently "succeeds" by clobbering the link with a fresh
#                  writable regular file
#   read-only dir  the block never reaches the file it was aimed at
#   symlink loop   walks off into a plain file instead of refusing
KC_DOTFILES="$KC_WORK/dotfiles"
mkdir -p "$KC_DOTFILES"

kc_links() { # kc_links <path> -- hard link count, GNU then BSD
  stat -c %h "$1" 2>/dev/null || stat -f %l "$1" 2>/dev/null
}

# kc_mode_sourced <path> -- the mode of the file a new shell ACTUALLY READS, so
# -L. Asserting on the target path instead would be inert here: the pre-fix
# script never wrote the target at all, so the target kept the fixture's 600 and
# the assertion passed while ~/.zshrc itself sat at 755.
kc_mode_sourced() {
  stat -Lc %a "$1" 2>/dev/null || stat -Lf %A "$1" 2>/dev/null
}

# --- a symlink into a dotfiles repo, target mode 600 ---
KC_DOTFILE="$KC_DOTFILES/zshrc"
rm -f "$ZSHRC"
printf '# this file lives in a dotfiles repo\nalias g=git\n' >"$KC_DOTFILE"
chmod 600 "$KC_DOTFILE"
ln -s "$KC_DOTFILE" "$ZSHRC"
kc_run
if [ "$KC_RC" -ne 0 ]; then
  fail "a symlinked ~/.zshrc exited $KC_RC:"$'\n'"$KC_OUT"
elif [ ! -L "$ZSHRC" ]; then
  fail "the symlink was replaced by a $(kc_mode "$ZSHRC") regular file — the dotfiles repo is now detached"
elif [ "$(readlink "$ZSHRC")" != "$KC_DOTFILE" ]; then
  fail "the symlink now points at $(readlink "$ZSHRC"), not $KC_DOTFILE"
else
  pass "a symlinked ~/.zshrc is still a symlink after a rewrite"
fi
if grep -qF -- "$KC_MARKER_BEGIN" "$KC_DOTFILE" && grep -q 'alias g=git' "$KC_DOTFILE"; then
  pass "the block was written THROUGH the link, under the dotfiles repo's own lines"
else
  fail "the dotfiles target did not get the block:"$'\n'"$(cat "$KC_DOTFILE")"
fi
# The compounding half of the same bug: `stat -f %A` is lstat, so the mode read
# off a symlink is the LINK's own 0755 -- every symlink macOS makes is 0755 --
# and chmodding that onto the replacement published a world-readable file naming
# every credential on the machine. Read through the link (-L), because that is
# the file a login shell opens; the pre-fix script leaves 755 sitting there.
if [ "$(kc_mode_sourced "$ZSHRC")" = "600" ]; then
  pass "the file a shell actually sources is still 600, not the symlink's own 755"
else
  fail "the sourced file's mode is $(kc_mode_sourced "$ZSHRC"), wanted the target's 600"
fi
# The first run appended (no markers yet); this one takes the awk replace branch,
# which is the other half of the write path and regressed identically.
cp "$KC_DOTFILE" "$KC_WORK/linked-baseline"
kc_run --units ntfy-alerts
if [ "$KC_RC" -eq 0 ] && [ -L "$ZSHRC" ] && cmp -s "$KC_WORK/linked-baseline" "$KC_DOTFILE"; then
  pass "regenerating over a symlink is idempotent and still leaves a symlink"
else
  fail "the rewrite branch through a symlink changed something (exit $KC_RC, link: $( [ -L "$ZSHRC" ] && echo yes || echo no )):"$'\n'"$(diff "$KC_WORK/linked-baseline" "$KC_DOTFILE" || true)"
fi

# --- a hardlink, which resolve-the-symlink alone does not save ---
# There is no link to follow here: the two names ARE the same inode, so the only
# way to keep them together is to stop renaming over the path and truncate the
# inode in place instead.
KC_HARD="$KC_DOTFILES/hardlinked-zshrc"
rm -f "$ZSHRC" "$KC_HARD"
printf '# hardlinked into a dotfiles repo\n' >"$KC_HARD"
chmod 600 "$KC_HARD"
ln "$KC_HARD" "$ZSHRC"
kc_run
if [ "$KC_RC" -ne 0 ]; then
  fail "a hardlinked ~/.zshrc exited $KC_RC:"$'\n'"$KC_OUT"
elif [ "$(kc_links "$ZSHRC")" != "2" ]; then
  fail "the hardlink was broken: link count is now $(kc_links "$ZSHRC"), wanted 2"
elif ! cmp -s "$ZSHRC" "$KC_HARD"; then
  fail "the two names diverged:"$'\n'"$(diff "$ZSHRC" "$KC_HARD" || true)"
elif ! grep -qF -- "$KC_MARKER_BEGIN" "$KC_HARD"; then
  fail "the hardlink's peer never got the block:"$'\n'"$(cat "$KC_HARD")"
else
  pass "a hardlinked ~/.zshrc keeps both names, and both see the block"
fi
# NO MODE ARM HERE, deliberately. An in-place truncate cannot change the mode,
# and the pre-fix `mv` copied the plain file's own 600 onto the replacement, so
# "the hardlinked file is still 600" is true before AND after the fix. It would
# be an assertion with no broken input, which is the defect this file is about.
# The link count above is what actually closes this case.

# --- a symlink whose target does not exist yet ---
# `[ -f ~/.zshrc ]` FOLLOWS the link, so a dotfiles repo that is cloned but does
# not carry a zshrc yet read as "no file at all" and the create branch clobbered
# the link. The pre-#39 `>>"$ZSHRC"` created the target instead, and so does this.
KC_DANGLING="$KC_DOTFILES/not-in-the-repo-yet"
rm -f "$ZSHRC" "$KC_DANGLING"
ln -s "$KC_DANGLING" "$ZSHRC"
kc_run
if [ "$KC_RC" -eq 0 ] && [ -L "$ZSHRC" ] && [ -f "$KC_DANGLING" ] \
  && [ "$(kc_mode "$KC_DANGLING")" = "600" ]; then
  pass "a dangling symlink CREATES its target at 600 instead of replacing the link"
else
  fail "dangling link: exit $KC_RC, still a link: $( [ -L "$ZSHRC" ] && echo yes || echo no ), target: $(kc_mode "$KC_DANGLING" 2>/dev/null || echo missing)"
fi

# --- two flavours of "you cannot write there" ---
# Both need a permission bit to MEAN something, so both are skipped under a uid
# for which nothing is unwritable. One skip covers the pair.
KC_RO="$KC_DOTFILES/readonly-zshrc"
KC_RODIR="$KC_WORK/ro-dotfiles"
if [ "$(id -u)" = "0" ]; then
  skip "the two unwritable-dotfiles arms (running as root: every path is writable)"
else
  # An unwritable TARGET must REFUSE rather than fall back to replacing the
  # link: clobbering it would report success while the file the user edits and
  # commits never changes again.
  rm -f "$ZSHRC" "$KC_RO"
  printf '# a read-only dotfiles checkout\n' >"$KC_RO"
  chmod 444 "$KC_RO"
  ln -s "$KC_RO" "$ZSHRC"
  kc_run
  if [ "$KC_RC" != "2" ]; then
    fail "an unwritable dotfiles target was not refused (exit $KC_RC):"$'\n'"$KC_OUT"
  elif [ ! -L "$ZSHRC" ]; then
    fail "the refusal replaced the link with a regular file anyway"
  elif ! printf '%s\n' "$KC_OUT" | grep -qF "$KC_RO"; then
    fail "the refusal did not name the unwritable target:"$'\n'"$KC_OUT"
  elif ! grep -q 'read-only dotfiles checkout' "$KC_RO"; then
    fail "the unwritable target was rewritten anyway"
  else
    pass "a symlink into an unwritable dotfiles repo is refused, naming the target"
  fi
  chmod 644 "$KC_RO"

  # A writable file in a directory you may NOT add files to. There is nowhere to
  # put the staged sibling, so this is the second thing that forces the in-place
  # write; without that branch `mktemp "$dir/..."` fails and `set -e` kills the
  # run with a raw mktemp error and no explanation.
  rm -rf "$KC_RODIR"
  mkdir -p "$KC_RODIR"
  printf '# a dotfiles dir I may not add files to\n' >"$KC_RODIR/zshrc"
  chmod 600 "$KC_RODIR/zshrc"
  chmod 555 "$KC_RODIR"
  rm -f "$ZSHRC"
  ln -s "$KC_RODIR/zshrc" "$ZSHRC"
  kc_run
  if [ "$KC_RC" -ne 0 ]; then
    fail "a writable file in an unwritable directory exited $KC_RC:"$'\n'"$KC_OUT"
  elif ! grep -qF -- "$KC_MARKER_BEGIN" "$KC_RODIR/zshrc"; then
    fail "the block never reached the file in the unwritable directory"
  elif [ "$(kc_mode "$KC_RODIR/zshrc")" != "600" ]; then
    fail "its mode became $(kc_mode "$KC_RODIR/zshrc"), wanted 600"
  else
    pass "a writable file in an unwritable directory is rewritten in place, keeping its 600"
  fi
  chmod 755 "$KC_RODIR"
fi

# --- a symlink loop ---
# resolve_link walks the chain itself (macOS only grew `readlink -f` in
# Monterey), so a -> b -> a is an infinite loop unless the walk is capped. This
# arm is here because a harness that HANGS is worse than one that fails.
rm -f "$ZSHRC"
ln -s "$KC_DOTFILES/loop-b" "$KC_DOTFILES/loop-a"
ln -s "$KC_DOTFILES/loop-a" "$KC_DOTFILES/loop-b"
ln -s "$KC_DOTFILES/loop-a" "$ZSHRC"
kc_run
if [ "$KC_RC" = "2" ] && printf '%s\n' "$KC_OUT" | grep -qF "never reaches a file"; then
  pass "a symlink loop is refused instead of spun on"
else
  fail "a symlink loop was not refused (exit $KC_RC):"$'\n'"$KC_OUT"
fi

# --- a symlink to something that is not a file ---
# THE ONE ARM HERE THAT IS NOT ABOUT THE PRE-FIX SCRIPT. A ~/.zshrc pointing at
# a stale directory already refused and already wrote nothing, but it refused by
# falling through to the marker counts, where `grep -cF` on a directory errors,
# `|| true` swallows it, and the count is the empty string -- so the user was
# told " begin markers (want exactly 1)". Nothing in install_block writes to
# anything but a regular file, so the refusal says that. This arm asserts the
# MESSAGE, which is the only thing that changed; delete the `[ -f "$target" ]`
# guard and it goes red on the empty-count text while the exit code stays 2.
KC_NOTFILE="$KC_DOTFILES/not-a-file"
# Separate calls so the flags say what each one is for: $ZSHRC is a link the
# previous arm left behind (-f removes the link, never its target), $KC_NOTFILE
# is a directory this arm rebuilds.
rm -f "$ZSHRC"
rm -rf "$KC_NOTFILE"
mkdir -p "$KC_NOTFILE"
printf 'keepme\n' >"$KC_NOTFILE/inside"
ln -s "$KC_NOTFILE" "$ZSHRC"
kc_run
if [ "$KC_RC" != "2" ]; then
  fail "a link to a directory was not refused (exit $KC_RC):"$'\n'"$KC_OUT"
elif ! printf '%s\n' "$KC_OUT" | grep -qF "is not a regular file"; then
  fail "the refusal did not say what is wrong:"$'\n'"$KC_OUT"
elif [ ! -L "$ZSHRC" ] || [ "$(cat "$KC_NOTFILE/inside")" != "keepme" ]; then
  fail "the refusal disturbed the link or the directory behind it"
else
  pass "a link to a directory is refused by name, not by an empty marker count"
fi
rm -rf "$KC_NOTFILE"

# The other shape of "not a regular file", and no root needed for it: /dev/null
# is a character device every Mac has. Same guard as the arm above, second
# input: `-f` is false for both, and a reader who only saw the directory case
# would reasonably wonder whether the check was `-d`.
rm -f "$ZSHRC"
ln -s /dev/null "$ZSHRC"
kc_run
if [ "$KC_RC" = "2" ] && printf '%s\n' "$KC_OUT" | grep -qF "/dev/null is not a regular file"; then
  pass "a link to a device node is refused the same way, naming /dev/null"
else
  fail "a link to /dev/null was not refused by name (exit $KC_RC):"$'\n'"$KC_OUT"
fi

# Back to a plain file: everything below writes through $ZSHRC and must not be
# reading a link this section happened to leave behind.
rm -f "$ZSHRC"
cp "$KC_WORK/baseline" "$ZSHRC"
chmod 644 "$ZSHRC"

# ---- minting ----
# NTFY_TOPIC is minted ON THE MAC (10-accounts.md §6 step 1), so this is a real
# path, not a fixture-only branch. It is not the only one -- code-agents'
# NTFY_AGENT_TOPIC is minted at §6a the same way -- and ntfy-alerts is picked
# here only because it is the smaller roster. Roster order is alphabetical:
# NTFY_EMAIL first (Enter), then NTFY_TOPIC.
: >"$KC_LOG"
printf '\ngenerate\n' >"$KC_WORK/answers-mint"
kc_prompted "$KC_WORK/answers-mint" --units ntfy-alerts
if grep -qF "add s=personal-ai a=NTFY_TOPIC len=24" "$KC_LOG"; then
  pass "typing \"generate\" mints hex 12 (24 chars) and stores it without printing it"
else
  fail "the mint did not reach the keychain as 24 chars:"$'\n'"$(cat "$KC_LOG")"$'\n'"$KC_OUT"
fi
case "$KC_OUT" in
  *"minted and stored (24 hex chars)"*) pass "the mint reports a LENGTH, never a prefix" ;;
  *) fail "the mint said something else:"$'\n'"$KC_OUT" ;;
esac

# The same word at a key the manifest says is TRANSCRIBED must be refused:
# storing the literal "generate" as the goose serve shared secret would be a
# silent outage, and minting a fresh one would unpair the client.
: >"$KC_LOG"
printf 'generate\n' >"$KC_WORK/answers-refuse"
kc_prompted "$KC_WORK/answers-refuse" --units brain
if grep -q "^add " "$KC_LOG"; then
  fail "the mint word stored something at a transcribe-only key:"$'\n'"$(cat "$KC_LOG")"
else
  pass "\"generate\" at a transcribe-only key stores nothing"
fi
case "$KC_OUT" in
  *"is transcribed, not minted here"*) pass "and it says why" ;;
  *) fail "the refusal was silent:"$'\n'"$KC_OUT" ;;
esac

# ---- the refusals that have nothing to do with the file ----
KC_RC=0
KC_OUT="$(kc_env "$KC_BASH" "$KC" </dev/null 2>&1)" || KC_RC=$?
if [ "$KC_RC" = "2" ] && printf '%s\n' "$KC_OUT" | grep -qF "interactive terminal"; then
  pass "prompting without a terminal is refused (a piped secret came from a file)"
else
  fail "the no-tty refusal is gone (exit $KC_RC):"$'\n'"$KC_OUT"
fi
kc_run --units zz-not-a-unit
if [ "$KC_RC" = "2" ] && printf '%s\n' "$KC_OUT" | grep -qF "zz-not-a-unit"; then
  pass "an unknown unit id stops the script instead of prompting for nothing"
else
  fail "an unknown --units was accepted (exit $KC_RC):"$'\n'"$KC_OUT"
fi

# --skips because two arms legitimately skip together: neither unwritable-
# dotfiles case can be exercised as a uid that may write anything, and a skip
# that does not appear in the total is a pass by another name.
finish --skips
