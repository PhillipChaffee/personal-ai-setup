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
trap 'rm -rf "$WORK"' EXIT

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
# Three of doctor's branches are unreachable through `pai doctor` BY
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
#
# Driving them means calling the functions, so this is an in-process unit probe.
#
# It is a FILE, not a heredoc on stdin: `coverage run -` refuses stdin ("No file
# to run: -"), the same trap documented at the top of this file. And it runs
# under $PAI_PY, not $FIX_PY — a plain python3 would assert correctly and
# contribute exactly zero coverage.
cat > "$WORK/probe.py" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path

doctor_path, clean_home, work, repo_root = sys.argv[1:5]
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
PY
if OUT="$("${PAI_PY[@]}" "$WORK/probe.py" "$DOCTOR" "$CLEAN" "$WORK" "$REPO_ROOT" 2>&1)"; then
  pass "unit probe: is_placeholder, run()'s OSError arm, and both shadowing arms"
else
  fail "unit probe failed:"$'\n'"$OUT"
fi

finish
