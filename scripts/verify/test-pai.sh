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

# Section 8 spawns `goose serve` stand-ins, so `trap ... EXIT` alone is no longer
# enough: Ctrl-C would leave a listener behind in the very file that asserts
# nothing is left behind. Every server this harness starts is recorded as a
# 0600 marker under $TMPDIR/pai-goosecfg (goosecfg writes it AT SPAWN), and
# section 8 redirects TMPDIR into $WORK -- so the markers are the roster, and
# cleanup is idempotent by construction. Killing the group precedent:
# test-code-agent-manager.sh:90-99; the multi-signal trap is new here.
cleanup() {
  local marker pid
  for marker in "$WORK"/goosecfg/tmp/pai-goosecfg/*.json; do
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

pai() { # pai <command> <home>
  PAI_HOME="$2" "${PAI_PY[@]}" "$DOCTOR" "$1"
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

# Nothing this section spawned may survive it. The trap at the top of this file
# is the backstop; this is the assertion.
LEFTOVER="$(find "$GC_WORK/tmp/pai-goosecfg" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$LEFTOVER" = "0" ]; then
  pass "goosecfg: no crash markers and no listeners survived the probes"
else
  fail "goosecfg left $LEFTOVER crash marker(s) behind — a server may still be running"
fi

finish
