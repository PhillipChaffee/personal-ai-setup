#!/usr/bin/env bash
# cli.sh — the `pai` dispatcher. READ-ONLY EXCEPT FOR THE COMMANDS LISTED BELOW.
#
# doctor/status/list are doctor.py; remove is uninstall.py; verify is a runner
# over the existing scripts/verify/check-*.sh; docs is check-docs.sh. The split
# is deliberate: verify and docs are shell because the things they run are
# shell, and a Python wrapper would only re-implement exit-code plumbing that
# lib.sh already has.
#
# WRITING COMMANDS — THE WHOLE LIST. Everything not named here writes nothing,
# and a command that gains a writing verb belongs in this list in the same diff
# that gives it one. (This used to be the sentence "with exactly one
# exception", written in three places; the enumeration is what stops the count
# and the code from disagreeing.)
#
#   doctor --fix   re-asserts, over goose's ACP config API, the keys the repo's
#                  own templates declare — the API rather than the file because
#                  goose serde-round-trips config.yaml, so a file-copying "fix"
#                  would be undone the next time goose starts. `doctor
#                  --dry-run` prints the same plan and writes nothing; that is
#                  the reading to reach for first.
#   docs --write   re-renders the generated regions of README.md in place from
#                  config/units/*.yaml and the tree. Bare `docs` only checks
#                  them, which is what docs-lint.yml runs.
#
# Flags are forwarded VERBATIM to doctor.py ("$@", not "$1") — it owns the
# option vocabulary, and an unknown flag must be its usage error rather than a
# word this dispatcher silently drops.
set -euo pipefail

# shellcheck source=scripts/verify/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../verify" && pwd)/lib.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage: pai <command> [options]

  doctor   what drifted between this machine and the repo's templates
  status   what is installed here
  list     what the repo ships
  units    one field of every manifest, one value per line (for scripts)
  secrets  the credential roster for one host, projected from the manifests
  verify   run the checks the manifests claim, one table, one exit code
  docs     the generated regions of README.md, checked against the tree
  remove   why a unit cannot be uninstalled, and what is kept regardless.
           It REFUSES and deletes nothing, for every unit, with no flag that
           bypasses it. `pai remove --help` says why the removing half is
           not written.

  verify --require <check>     a check that exits 2 (precondition missing) is a
                               SKIP in a sweep. Name it here and its skip
                               becomes a FAILURE — "I know this machine has
                               connectors; prove it." Repeatable. `check-mcp`,
                               `check-mcp.sh` and the full path all name the
                               same check.
  units --field id|verify      the projection. `verify` is what `pai verify`
                               itself reads, so the roster has one home.
  units --host mac|vps|both|checklist
                               keep only the units that host installs (`both`
                               counts for every host).

  secrets --host mac|vps [--units a,b,c | --all]
                               one TAB-separated row per key: name, required or
                               optional, the `openssl rand` command or -, and
                               the prompt. Names and prompts only; no value is
                               ever read. Default selection is every base and
                               default_on unit; --host names the STORE, so a
                               vps-hosted unit can still contribute a Mac
                               Keychain row. scripts/mac/keychain-secrets.sh is
                               the consumer.

Every command writes nothing. These two are the whole list of exceptions:

  doctor --dry-run             say exactly what --fix would do. writes nothing.
  doctor --fix                 re-assert the repo's own keys over goose's ACP
                               config API. THIS WRITES. Refuses to touch an
                               extension whose live config still holds inline
                               `envs` values, because any ACP write erases them.
  doctor --fix --migrate-envs  additionally promote those values into goose's
                               secret store. One way; the value is never printed.
  docs --write                 re-render README.md's generated regions from the
                               manifests and the tree. THIS WRITES. Bare `docs`
                               compares them and changes nothing.

Exit: 0 ok, 1 findings, 2 usage/precondition.

  PAI_HOME       inspect a different home (used by the tests); defaults to $HOME.
                 --fix REFUSES when it is not $HOME unless GOOSE_ACP_URL or
                 PAI_GOOSE_BIN also names which goose is meant.
  GOOSE_ACP_URL  a running `goose serve` to use; nothing is spawned. Required on
                 the brain, where goose-serve.service already owns the config.
  PAI_GOOSE_BIN  the goose binary --fix may spawn on loopback for the duration.
EOF
}

# The one check that is EXCLUDED off-brain, and the whole exclusion list.
#
# NOT a host filter over `host:`. That was the obvious design and it is a net
# regression: base-goose is `host: mac` and is the only owner of check-goose.sh
# and check-providers.sh, so filtering the roster by the machine's host would
# have LOST both of those on the brain — where goose is the thing that runs —
# while gaining only check-security.sh. `host:` says where a unit INSTALLS, not
# where its proof is meaningful.
#
# check-brain.sh is the one script that genuinely cannot run off-brain: with no
# BRAIN_HOST it exits 2 about a placeholder, and with one it SSHes. Everything
# else either works from either side or reports its own missing precondition,
# which is what exit 2 is for. Keep this list at one name; if it grows, the
# reason belongs in the manifest, not here.
OFF_BRAIN_EXCLUDE="check-brain.sh"

# normalise_check <word> — `mcp`, `check-mcp`, `check-mcp.sh` and
# `scripts/verify/check-mcp.sh` all name the same check.
normalise_check() {
  local n="${1##*/}"
  case "$n" in check-*) ;; *) n="check-$n" ;; esac
  case "$n" in *.sh) ;; *) n="$n.sh" ;; esac
  printf '%s' "$n"
}

cmd_verify() {
  local mode roster rc=0 required="" entry name label unclaimed="" roster_names="" path
  local -a argv

  while [ $# -gt 0 ]; do
    case "$1" in
      --require)
        shift
        [ $# -gt 0 ] || die_usage "--require needs a check name"
        required="$required $(normalise_check "$1")"
        ;;
      *) die_usage "unknown verify option: $1" ;;
    esac
    shift
  done

  # THE ROSTER IS THE MANIFESTS'. It used to be two hardcoded strings here, and
  # they had drifted: brain.yaml claims check-brain.sh AND check-security.sh,
  # and only the first was ever run — brain.yaml recorded that as a blocker
  # rather than as a bug, which is how it survived. Deriving it also means the
  # next unit to gain a verify script gains it here with no second edit.
  local -a PY
  local py_cmd
  py_cmd="$(py_runner)"
  read -r -a PY <<<"$py_cmd"
  roster="$("${PY[@]}" "$REPO_ROOT/scripts/pai/doctor.py" units --field verify)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    die 2 "could not read the verify roster from config/units/*.yaml (exit $rc)" \
      "Every check this runs is claimed by some manifest's \`verify:\` list;" \
      "scripts/verify/check-units.sh is what validates them."
  fi

  # Name the roster BEFORE running any of it, so `--require no-such-check` is a
  # usage error rather than a green sweep whose escalation silently matched
  # nothing. That failure mode — a flag that reads fine and asserts nothing — is
  # the one this whole issue exists to stop shipping.
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    read -r -a argv <<<"$entry"
    roster_names="$roster_names ${argv[0]##*/}"
  done <<<"$roster"
  # AN EMPTY ROSTER IS A REFUSAL, NOT A CLEAN SWEEP — and this is the roster
  # that matters most, because it IS the sweep. doctor.py's projection exits 0
  # with EMPTY STDOUT when config/units/ is absent or no manifest carries a
  # `verify:` entry (test-pai.sh's probe asserts exactly that: rc 0, no lines,
  # no stderr). Without this guard the loops below walk nothing, every check on
  # disk lands in the "claimed by no unit" note, and `finish --skips` prints
  # "== summary: 0 passed, 0 failed, 0 skipped ==" and exits 0. Rename or
  # relocate config/units/ and `pai verify` becomes a permanent green no-op.
  #
  # die 2, matching check-brain.sh:159, which refuses the same shape for its
  # schedule roster: with nothing to run there is no sweep left to report, and
  # 2 is this repo's "the precondition is missing".
  if [ -z "$roster_names" ]; then
    die 2 "the verify roster derived from config/units/*.yaml is EMPTY" \
      "Nothing would run, and a sweep of nothing must not report success." \
      "Every check is claimed by some manifest's \`verify:\` list —" \
      "\`pai units --field verify\` prints the roster, and" \
      "scripts/verify/check-units.sh is what validates them."
  fi

  for name in $required; do
    case " $roster_names " in
      *" $name "*) ;;
      *) die_usage "--require $name: no unit's \`verify:\` claims it." \
           "This roster is:$roster_names" ;;
    esac
  done

  mode="$(pai_mode no)"
  echo "== pai verify (host: $mode) =="
  echo

  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    # An entry is a repo-relative path OPTIONALLY FOLLOWED BY ARGUMENTS —
    # brain.yaml's is `scripts/verify/check-security.sh --local`, because that
    # script's two modes are two different checks and the manifest is where a
    # unit says which one is its proof.
    read -r -a argv <<<"$entry"
    name="${argv[0]##*/}"
    label="${name%.sh}"
    [ "${#argv[@]}" -eq 1 ] || label="$label ${argv[*]:1}"

    case " $OFF_BRAIN_EXCLUDE " in
      *" $name "*)
        if [ "$mode" != "local" ]; then
          case " $required " in
            *" $name "*) fail "$label — required, but it only runs ON the brain" ;;
            *) skip "$label (runs on the brain; this is $mode)" ;;
          esac
          continue
        fi
        ;;
    esac

    argv[0]="$REPO_ROOT/${argv[0]}"
    if [ ! -x "${argv[0]}" ]; then
      fail "$label — claimed by a manifest but not executable at ${argv[0]}"
      continue
    fi
    rc=0
    "${argv[@]}" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0) pass "$label" ;;
      # 2 is "unusable environment" by this repo's convention (missing keys, no
      # goose). Inside a sweep that is a SKIP. --require escalates it, and that
      # escalation is NEW CODE with its own negative test in test-pai.sh — the
      # comment that used to stand here cited check-connectors.sh:1951 as the
      # precedent it was inheriting, and there is no such precedent: :1949-1962
      # is the AcpClient AuthError handler, and that script's option vocabulary
      # has no escalation flag at all.
      2)
        case " $required " in
          *" $name "*) fail "$label (exit 2 — required, so a missing precondition is a failure)" ;;
          *) skip "$label (exit 2 — precondition missing)" ;;
        esac
        ;;
      *) fail "$label (exit $rc)" ;;
    esac
  done <<<"$roster"

  # What is NOT in the roster, derived the same way — the check-*.sh on disk
  # that no manifest claims. check-units.sh's P5 reverse closure has a verdict
  # about that; here it is only reported, so a reader can tell "no unit claims
  # it" from "it ran and passed". check-coverage.sh is the permanent member:
  # with no coverage.json it exits 2, which inside a sweep would render as a
  # SKIP indistinguishable from a real missing precondition. It is produced by
  # .github/workflows/coverage.yml, not runnable here.
  for path in "$REPO_ROOT"/scripts/verify/check-*.sh; do
    [ -f "$path" ] || continue
    name="${path##*/}"
    case " $roster_names " in *" $name "*) continue ;; esac
    unclaimed="$unclaimed $name"
  done
  if [ -n "$unclaimed" ]; then
    echo
    note "claimed by no unit, so not in this roster:$unclaimed"
    note "(check-coverage.sh is produced by coverage.yml; check-units.sh and"
    note " check-goose-template.sh are repo gates data-lint.yml runs, and"
    note " check-docs.sh is the one docs-lint.yml runs — \`pai docs\`. A check"
    note " here that ISN'T one of those is a manifest missing a \`verify:\` entry.)"
  fi

  finish --skips
}

case "${1:-}" in
  -h|--help|"") usage; exit 0 ;;
  doctor|status|list|units|secrets)
    # An assignment, not `read -r -a PY <<<"$(py_runner)"`: verified under bash
    # 3.2.57, a here-string SWALLOWS the subshell's exit, so the version this
    # replaces printed py_runner's remedy and then exec'd doctor.py as if it
    # were the interpreter. See py_runner's comment in lib.sh.
    PY_CMD="$(py_runner)"
    read -r -a PY <<<"$PY_CMD"
    exec "${PY[@]}" "$REPO_ROOT/scripts/pai/doctor.py" "$@"
    ;;
  remove)
    # Same shape as the doctor arm, and for the same three reasons: the
    # assignment (not a here-string) so errexit sees py_runner's die, the exec
    # so uninstall.py's exit code IS this script's, and "$@" rather than "$1"
    # so the verb and the id both reach main() — which consumes the verb the
    # way doctor.py's does.
    PY_CMD="$(py_runner)"
    read -r -a PY <<<"$PY_CMD"
    exec "${PY[@]}" "$REPO_ROOT/scripts/pai/uninstall.py" "$@"
    ;;
  verify) shift; cmd_verify "$@" ;;
  # exec, not a call: check-docs.sh sources the same lib.sh this file did and
  # owns its own counters, usage text and 0/1/2 convention. Wrapping it would
  # mean deciding here what `--write` means, which is precisely the duplication
  # cmd_verify's roster comment is about.
  docs) shift; exec "$REPO_ROOT/scripts/verify/check-docs.sh" "$@" ;;
  *) die_usage "unknown command: $1" ;;
esac
