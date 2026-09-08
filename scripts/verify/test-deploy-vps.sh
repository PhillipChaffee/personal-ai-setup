#!/usr/bin/env bash
# test-deploy-vps.sh — scripts/vps/deploy-vps.sh, EXECUTED, with no VPS, no
# /data, no podman, no systemd and no network. The deploy runs for real against
# scripts/verify/fake-host.sh in a throwaway directory tree, and every
# assertion below is about what it INVOKED and what it WROTE.
#
# WHAT A GREEN RUN HERE MEANS, exactly, and nothing beyond it:
#
#   "deploy-vps.sh issues the privileged invocations it issued before the carve,
#    IN THE SAME ORDER, with two enumerated edits -- one `daemon-reload` moved
#    below the tls-cert-renew installs and one added inside
#    unit_telegram_gateway -- writes the same file tree byte for byte, and
#    issues a strictly smaller sequence when a unit is deselected."
#
# WHAT IT CANNOT MEAN. There is no CI on earth that can run this script against
# a real brain, so the following stay a human's job on a real VPS and are
# listed here rather than left to be assumed:
#   * that podman, apt-get, systemd and loginctl behave as fake-host.sh models
#     them on Ubuntu;
#   * that `podman build` succeeds, or that code-agent:local runs;
#   * that `systemctl enable --now` on a stale unit file is a no-op -- V2b/V2b'
#     assert only that the daemon-reload was ISSUED between the install and the
#     enable, which is the fix, not the symptom;
#   * that rootless subuid ranges or `loginctl enable-linger agent` work;
#   * that goose serve reads schedule.json only at startup (constraint 4's
#     premise -- a goose 1.46.0 fact verified by hand, and a comment in
#     deploy-vps.sh, not an assertion here);
#   * check-code-agents.sh's checks 3/5/6 and --probe, which talk to a live TLS
#     gateway. deploy-vps.sh's own summary already prints them as a manual step.
#
# LINUX ONLY, and it dies 2 saying so. `ln -sfnT` (GNU -T), `stat -c %a` and
# register-schedules.sh's `declare -A` rule out stock macOS, and a partial pass
# would be worse than no pass: half these assertions are ABOUT the GNU-only
# behaviour. This is a deliberate departure from test-base-install.sh's
# laptop-friendliness. Develop it in CI or in a container.
#
# ASSERTION IDS carry through from the design so a failure names the claim:
#   V0      the pinned baseline is real         V5/V5b/V5c  selection + dry run
#   V1/V1b  the pre-carve differential          V7          idempotence
#   V2a-f   ordering constraints                V8          the /status gate
#   V3/V3b  the -T constraint, both directions  V9          ERR attribution
#   V4a/V4b the EXIT trap                       V11         check-code-agents
#   V6      the migration runs once
#
# NOTHING HERE MAY CONTAIN A LITERAL SECRET-SHAPED CONSTANT. The fixture
# secrets.env is generated with `openssl rand -hex 32` at run time, and no
# assertion message interpolates a value -- counts, booleans and exit codes
# only.
# shellcheck disable=SC2015
# ^ FILE-LEVEL and load bearing, the same as test-base-install.sh:94-101: every
# assertion is the deliberate `[ cond ] && ok "..." || bad "..."` idiom, and
# ok() ends in an arithmetic ASSIGNMENT (always exit 0) so the `|| bad` arm can
# never run after a passing `ok`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage: test-deploy-vps.sh [--only differential|constraints|select|rerun|status] [--help]

Runs scripts/vps/deploy-vps.sh against scripts/verify/fake-host.sh inside a
throwaway directory. Linux only. Exits non-zero if any assertion fails.

  --only differential  V0/V1/V1b: the pinned baseline, then the
                       pre-carve/post-carve invocation-SEQUENCE and file-tree
                       differential, with a two-edit allowlist
  --only constraints   V2a-f, V3, V3b, V4a/V4b, V6: the four documented
                       constraints on this deploy, plus the reload orderings
  --only select        V5/V5b/V5c/V11: --with/--without/--only/--dry-run
  --only rerun         V7: a second deploy into the same sandbox
  --only status        V8/V9: the /status gate and ERR-trap attribution
  (no flag)            all of it
EOF
}

ONLY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --only)
      [ "$#" -ge 2 ] || { echo "test-deploy-vps.sh: --only needs a value" >&2; usage >&2; exit 2; }
      ONLY="$2"; shift 2 ;;
    *) echo "test-deploy-vps.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$ONLY" in
  ""|differential|constraints|select|rerun|status) ;;
  *) echo "test-deploy-vps.sh: unknown --only leg: $ONLY" >&2; usage >&2; exit 2 ;;
esac

leg() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0
ok()      { echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
bad()     { echo "FAIL  $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skipped() { echo "SKIP  $1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }
# `head` FIRST and `|| true`: evidence() is only ever the last command of a
# failure arm, and under `set -euo pipefail` a missing file (or sed taking
# SIGPIPE from a head that stopped at 40) would end the whole run right there,
# turning one named failure into a truncated log with no summary.
evidence() { { head -40 "$1" 2>/dev/null || true; } | sed 's/^/      | /'; }
die() { echo "test-deploy-vps.sh: $*" >&2; exit 2; }

# ---- 1. preflight -----------------------------------------------------------
case "$(uname -s)" in
  Linux) ;;
  *) die "Linux only. This harness asserts GNU-specific behaviour (ln -T, stat -c, find -printf) and a partial pass would be worse than none. Run it in CI or a container." ;;
esac

# NOT ROOT, and refused rather than reported. deploy-vps.sh's own preflight
# (deploy-vps.sh:315) exits 1 on `id -u` == 0, so under root EVERY run of it
# dies on its first line and every assertion below fails for that one reason.
# Measured before this guard existed, in ubuntu:24.04 as root: 1 pass, 13
# failures saying things like "the brain would be left offline", and then the
# harness died inside V4b without printing a summary at all. Not one of those
# failures was about the code under test, and the count is environment-dependent
# — which is the point: a root run reports the wrong cause 13 different ways.
# The obvious way to hit it is a bare `docker run ubuntu:24.04`.
[ "$(id -u)" -ne 0 ] || die "refusing to run as root: deploy-vps.sh's preflight refuses root, so every assertion here would fail for that one reason and name the wrong cause. Run as an unprivileged user (in a container: 'useradd -m tester' then run as tester)."

# THE BRAIN INTERLOCK. register-schedules.sh reads the LITERAL /data/secrets.env
# and the literal /data/life-vault paths (it has no seam of its own, and giving
# it one is #39's job, not this one's). On a real brain that would make this
# harness read the owner's secrets and branch on their vault. Refuse.
[ ! -r /data/secrets.env ] || die "/data/secrets.env is readable — this looks like the brain itself. This harness must not run there."

REQUIRED_TOOLS="bash env openssl git diff comm sort grep sed awk find head tail wc tr cut cmp ls stat id date basename readlink mktemp seq install ln mv cp rm rmdir mkdir chmod cat sha256sum uname"
MISSING=""
for tool in $REQUIRED_TOOLS; do
  command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
done
[ -z "$MISSING" ] || die "missing required tool(s):$MISSING"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/out"

# ---- 2. the minimal PATH the deploy runs on ---------------------------------
# Enumerated, and short. Anything the deploy reaches for that is neither
# shimmed by fake-host.sh nor on this list exits 127 mid-run rather than
# silently resolving to the developer's toolchain -- which is how an unmodelled
# dependency is supposed to surface.
PATHMIN="$WORK/pathmin"
mkdir -p "$PATHMIN"
PATHMIN_TOOLS="bash sh env seq head tail grep cmp ls stat id basename readlink find sed cat wc tr sort dirname uname mktemp"
for tool in $PATHMIN_TOOLS; do
  real="$(command -v "$tool")" || die "pathmin: no $tool"
  ln -sf "$real" "$PATHMIN/$tool"
done

SHIM_NAMES="sudo systemctl apt-get usermod loginctl tailscale curl mountpoint git goose sleep date ln mv cp rm rmdir install chmod mkdir"
DENY_NAMES="podman apt-get usermod loginctl"

# ---- 2b. the fixture secrets ------------------------------------------------
# GENERATED, never typed: a literal here would be a secret-shaped constant in a
# public repo and gitleaks would be right to reject it.
#
# Generated ONCE and copied into every sandbox, not once per sandbox. V1b
# compares the two sides of the differential byte for byte, and a per-sandbox
# secrets.env differs by construction -- which is a difference in the FIXTURE,
# not in the installer, and exactly the kind of noise that gets a real
# differential switched off. (Measured: this is how it failed first.)
SECRETS_FIXTURE="$WORK/secrets.env"
{
  echo "OPENCODE_ZEN_API_KEY=$(openssl rand -hex 32)"
  echo "TOGETHER_API_KEY=$(openssl rand -hex 32)"
  echo "GOOSE_SERVER__SECRET_KEY=$(openssl rand -hex 32)"
  echo "NTFY_TOPIC=pai-test-$(openssl rand -hex 8)"
  echo "TELEGRAM_BOT_TOKEN=$(openssl rand -hex 32)"
  echo "OPENCODE_SERVER_PASSWORD=$(openssl rand -hex 32)"
  echo "GITHUB_CODE_AGENT_PAT=$(openssl rand -hex 32)"
  echo "GOOGLE_OAUTH_CLIENT_ID=$(openssl rand -hex 16)"
  echo "GOOGLE_OAUTH_CLIENT_SECRET=$(openssl rand -hex 32)"
} >"$SECRETS_FIXTURE"
chmod 600 "$SECRETS_FIXTURE"

# ---- 3. sandbox construction ------------------------------------------------
# Two directories per sandbox, and the split matters: $WORK/sb-<tag> is the
# FAKE HOST (home, /data, /etc) and nothing else, so an inventory of it is an
# inventory of what the deploy wrote. The fake's own log, state and shim
# directory live in $WORK/aux-<tag>, outside it.
mksandbox() {
  # mksandbox <tag> <fresh|existing> [--deny]
  local tag="$1" kind="$2" deny="${3:-}"
  local sb="$WORK/sb-$tag" aux="$WORK/aux-$tag"
  mkdir -p "$sb/home/agent" "$sb/data" "$sb/etc/systemd/system" "$sb/bin" \
           "$sb/repo" "$aux/state" "$aux/shims" "$aux/deny"
  : >"$sb/etc/subuid"

  # The repo the deploy pulls and copies templates out of. Symlinks to the real
  # thing: config/, scripts/ and recipes/ are INPUTS to both sides of the
  # differential and must be the same inputs. `.git` is a real directory so
  # deploy-vps.sh's `[[ -d "$REPO_DIR/.git" ]]` (a bash builtin test, not
  # routed) takes the pull branch.
  ln -sfn "$REPO_ROOT/config" "$sb/repo/config"
  ln -sfn "$REPO_ROOT/scripts" "$sb/repo/scripts"
  ln -sfn "$REPO_ROOT/recipes" "$sb/repo/recipes"
  mkdir -p "$sb/repo/.git"

  cp "$SECRETS_FIXTURE" "$sb/data/secrets.env"
  chmod 600 "$sb/data/secrets.env"

  # Unquoted on purpose: $SHIM_NAMES is a WORD LIST, and quoting it would hand
  # fake-host.sh a single 19-word filename.
  # shellcheck disable=SC2086
  "$HERE/fake-host.sh" --materialise "$aux/shims" $SHIM_NAMES
  # GOOSE_BIN points at a real shim, so the `-x $GOOSE_BIN` arm of the
  # preflight is the one that runs rather than the `command -v` fallback.
  cp "$aux/shims/goose" "$sb/bin/goose"
  # shellcheck disable=SC2086  # word list, see above
  [ "$deny" != "--deny" ] || "$HERE/fake-host.sh" --deny-wall "$aux/deny" $DENY_NAMES

  # $STAMP feeds every `.superseded.<stamp>` name. Pinned so two runs that
  # straddle a second boundary do not differ for a reason that has nothing to
  # do with the code under test.
  echo "20260101000000" >"$aux/state/fixed-date"

  if [ "$kind" = "existing" ]; then
    # A brain from BEFORE the path-root migration: goose's three directories
    # are real, on the root disk, with content, and /data/goose-data exists.
    # This is the AC5 scenario ("an existing brain"), and it is the only shape
    # that exercises migrate_into_root's mv arms at all.
    mkdir -p "$sb/home/agent/.config/goose/custom_providers" \
             "$sb/home/agent/.local/share/goose" \
             "$sb/home/agent/.local/state/goose/logs" \
             "$sb/data/goose-data"
    echo "GOOSE_PROVIDER: opencode-zen" >"$sb/home/agent/.config/goose/config.yaml"
    echo "existing hint" >"$sb/home/agent/.config/goose/.goosehints"
    echo "sessions" >"$sb/home/agent/.local/share/goose/sessions.db"
    echo "llm request" >"$sb/home/agent/.local/state/goose/logs/llm_request.0.jsonl"
    echo "{}" >"$sb/data/goose-data/schedule.json"
    local u
    for u in goose-serve.service goose-telegram-gateway.service \
             tls-cert-renew.service tls-cert-renew.timer; do
      cp "$REPO_ROOT/scripts/vps/systemd/$u" "$sb/etc/systemd/system/$u"
    done
    printf 'goose-serve.service\ngoose-telegram-gateway.service\ntls-cert-renew.timer\n' \
      >"$aux/state/systemd-enabled"
    printf 'goose-serve.service\ngoose-telegram-gateway.service\ntls-cert-renew.timer\n' \
      >"$aux/state/systemd-active"
  fi
}

arm()   { : >"$WORK/aux-$1/state/$2"; }
disarm() { rm -f "$WORK/aux-$1/state/$2"; }

run_deploy() {
  # run_deploy <tag> <log> <script> [args...]; echoes rc. Prefix assignments
  # only, so this harness's own environment stays clean and a later leg cannot
  # inherit what an earlier one set.
  local tag="$1" log="$2" script="$3"; shift 3
  local sb="$WORK/sb-$tag" aux="$WORK/aux-$tag" rc=0
  : >"$log"
  : >"$aux/deny.log"
  # `</dev/null` is an assertion in the shape of a redirection: deploy-vps.sh
  # is a non-interactive program, and the day it grows a `read -r -p` an
  # inherited terminal would hang CI instead of failing it.
  HOME="$sb/home/agent" \
  PATH="$aux/deny:$aux/shims:$PATHMIN" \
  PAI_FAKE_ROOT="$sb" \
  PAI_REPO_DIR="$sb/repo" \
  PAI_DATA_ROOT="$sb/data" \
  PAI_SYSTEMD_DIR="$sb/etc/systemd/system" \
  PAI_GOOSE_BIN="$sb/bin/goose" \
  PAI_SUBUID_FILE="$sb/etc/subuid" \
  PAI_HOST_LOG="$log" \
  PAI_HOST_STATE="$aux/state" \
  PAI_HOST_SHIMS="$aux/shims" \
  PAI_DENY_LOG="$aux/deny.log" \
  REPO_URL="" \
    "$script" "$@" >"$log.out" 2>"$log.err" </dev/null || rc=$?
  echo "$rc"
}

# ---- 4. log helpers ---------------------------------------------------------
# `|| true` on every one: grep exits 1 on no-match, which under `set -e` in a
# command substitution inside an assignment would abort the whole harness.
count_in()  { grep -cE -- "$2" "$1" 2>/dev/null || true; }
first_idx() { grep -nE -- "$2" "$1" 2>/dev/null | head -n1 | cut -d: -f1 || true; }
last_idx()  { grep -nE -- "$2" "$1" 2>/dev/null | tail -n1 | cut -d: -f1 || true; }
# first_idx_after <log> <pattern> <n> — the first match strictly after line n.
first_idx_after() {
  grep -nE -- "$2" "$1" 2>/dev/null | cut -d: -f1 | awk -v n="$3" '$1 > n {print; exit}' || true
}
n() { [ -n "${1:-}" ] && echo "$1" || echo 0; }

# inventory <root> — type, mode, relative path and (for symlinks) the target,
# with the sandbox root collapsed. `diff -r` is NOT used: the two sides of the
# differential live at different absolute paths, so every symlink target
# differs textually while the trees are identical, and `diff -r` dereferences
# and hides exactly the thing this repo's -T constraint is about.
inventory() {
  # inventory <sandbox-root> <part>. The sandbox root is normalised out of
  # SYMLINK TARGETS, which are absolute and therefore name the sandbox: the
  # first version of this normalised the part root instead, so every target
  # under a sibling part came through un-normalised and the two sides differed
  # on four lines that were in fact identical.
  local sb="$1" part="$2"
  find "$sb/$part" -mindepth 1 \
    \( -type d -printf 'd %m %P\n' \) -o \
    \( -type f -printf 'f %m %P\n' \) -o \
    \( -type l -printf 'l --- %P -> %l\n' \) \
    | sed "s|$sb|@ROOT@|g" | sort
}
# checksums <root> — content, for regular files only, so "the same tree" means
# the same bytes and not just the same names.
checksums() {
  # checksums <sandbox-root> <part>
  local root="$1/$2" f
  find "$root" -type f -printf '%P\n' | sort | while IFS= read -r f; do
    printf '%s  %s\n' "$f" "$(sha256sum <"$root/$f" | cut -d' ' -f1)"
  done
}

# ---- 5. the deny wall must be able to fire ----------------------------------
# An EMPTY deny log is what V5 asserts, and an empty deny log is ALSO what a
# broken wall, an unset PAI_DENY_LOG or a PATH that never took effect produce.
# So the wall is fired on purpose, before anything depends on it.
if leg select; then
  mkdir -p "$WORK/selftest"
  "$HERE/fake-host.sh" --deny-wall "$WORK/selftest/deny" podman
  : >"$WORK/selftest/deny.log"
  DENY_RC=0
  PATH="$WORK/selftest/deny:$PATHMIN" PAI_DENY_LOG="$WORK/selftest/deny.log" \
    podman --version >/dev/null 2>&1 || DENY_RC=$?
  [ "$DENY_RC" -eq 127 ] && [ -s "$WORK/selftest/deny.log" ] &&
    ok "deny-wall self-test: a denied binary exits 127 and lands in the log" ||
    bad "deny-wall self-test: the wall did not fire (rc=$DENY_RC) — V5's empty-log assertion proves nothing"
fi

# ============================================================================
# V0/V1/V1b — THE DIFFERENTIAL
# ============================================================================
if leg differential; then
  # PINNED, and it pins the SEAM COMMIT, not some earlier revision: the seam is
  # what makes the pre side runnable at all (before it, deploy-vps.sh wrote to
  # the literal /data and /etc/systemd/system and no harness could touch it).
  # The seam commit is deliberately zero-behaviour-change, so it is a valid
  # baseline for "the carve moved nothing".
  #
  # THE TAG refs/tags/vps-pre-carve IS LOAD-BEARING. DO NOT DELETE IT.
  #
  # The sha below is NOT an ancestor of main and is not guaranteed to become
  # one. This repo's history is MIXED: #101-#104 landed as `Merge pull request
  # #NN` commits, while #105-#108 — including the directly analogous Mac carve —
  # were SQUASHED. A squash makes the seam commit unreachable from every branch,
  # `cat-file -e` starts failing, and the differential stops asserting. That is
  # not a skip: a differential that silently stops asserting is the failure this
  # whole file exists to prevent, so the only arm that may skip is a genuinely
  # SHALLOW clone (which a `git fetch --unshallow` fixes), and everything else is
  # a FAILURE with a runbook.
  #
  # The tag is what makes that impossible, whatever the merge strategy:
  #   git push origin 06b04ca39669e8efbfa29fb6f6fefdab37987493:refs/tags/vps-pre-carve
  # A tag is a ref, so the object stays reachable through any squash, rebase or
  # branch deletion, and actions/checkout with `fetch-depth: 0` fetches tags
  # (getRefSpecForAllHistory includes `+refs/tags/*:refs/tags/*`), so CI sees it
  # too. Deleting the tag re-arms exactly the failure it was pushed to prevent.
  #
  # PINNED BY SHA RATHER THAN BY TAG NAME, deliberately. A sha is
  # content-addressed: `vps-pre-carve` could be moved onto a post-carve revision
  # by anyone with push access and the comparison would quietly become the tree
  # against itself. (V0 below also checks the blob's shape, so that has two
  # guards, not one.) The tag's job is REACHABILITY; the sha's job is IDENTITY.
  #
  # AND NO OLDER SHA CAN REPLACE IT. The obvious hardening — pin something that
  # is already an ancestor of main, the way test-base-install.sh:1369 pins the
  # merge commit 5f016b3 — is not available here: the seam is introduced by
  # this branch's own first commit, and every earlier revision of
  # deploy-vps.sh writes to the literal /data and /etc/systemd/system, so it
  # cannot be run against a fake host at all. Failing the tag, GitHub keeps
  # refs/pull/110/head forever, so the blob is still recoverable — see the
  # failure text below, which says how.
  #
  # RE-PIN THIS IF THE BRANCH IS EVER REBASED. A rebase rewrites every commit on
  # the branch, so the seam gets a new sha and V0 goes red on "UNREACHABLE in a
  # full clone" — correctly. Re-pin to the rebased seam commit and re-push the
  # tag at it; do not reach for `--depth 1` to make the red go away.
  PRE_CARVE_SHA="06b04ca39669e8efbfa29fb6f6fefdab37987493"

  HAVE_GIT=0; SHALLOW=0; HAVE_BLOB=0
  if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    HAVE_GIT=1
    [ "$(git -C "$REPO_ROOT" rev-parse --is-shallow-repository 2>/dev/null)" != "true" ] || SHALLOW=1
    git -C "$REPO_ROOT" cat-file -e "$PRE_CARVE_SHA:scripts/vps/deploy-vps.sh" 2>/dev/null && HAVE_BLOB=1 || true
  fi

  # V0 — THE BASELINE ITSELF. Two ways of losing this differential are silent
  # and neither is hypothetical:
  #   * the pinned commit goes unreachable (see above), or
  #   * a future author re-pins to a POST-carve sha to make the red go away,
  #     which compares the working tree against itself and passes for free.
  # So the extracted blob is checked for the seam it must have and for the unit
  # functions it must NOT have, and V1/V1b do not run unless V0 passes.
  BASELINE=""
  if [ "$HAVE_BLOB" -eq 1 ]; then
    mkdir -p "$WORK/pre-carve"
    git -C "$REPO_ROOT" show "$PRE_CARVE_SHA:scripts/vps/deploy-vps.sh" >"$WORK/pre-carve/deploy-vps.sh"
    chmod 755 "$WORK/pre-carve/deploy-vps.sh"
    V0_SEAM="$(count_in "$WORK/pre-carve/deploy-vps.sh" '^PAI_FAKE_ROOT=')"
    V0_UNITS="$(count_in "$WORK/pre-carve/deploy-vps.sh" '^unit_[a-z_]+\(\) \{')"
    if [ "$V0_SEAM" -ge 1 ] && [ "$V0_UNITS" -eq 0 ]; then
      BASELINE="$WORK/pre-carve/deploy-vps.sh"
      ok "V0: the pinned baseline ${PRE_CARVE_SHA:0:9} is reachable, carries the seam and defines no unit function"
    else
      bad "V0: ${PRE_CARVE_SHA:0:9} is reachable but is not a pre-carve seam revision (PAI_FAKE_ROOT=$V0_SEAM want >=1, unit_*() definitions=$V0_UNITS want 0) — V1/V1b did not run. Re-pinning the baseline to a post-carve sha compares the tree with itself."
    fi
  elif [ "$HAVE_GIT" -eq 1 ] && [ "$SHALLOW" -eq 1 ]; then
    # The ONLY skip. Distinguishable by construction, and self-repairing:
    # `git fetch --unshallow` (or actions/checkout's fetch-depth: 0) restores it.
    skipped "V0/V1/V1b: this is a SHALLOW clone and the pre-carve blob was never fetched — run 'git fetch --unshallow' (CI uses fetch-depth: 0)"
  elif [ "$HAVE_GIT" -eq 1 ]; then
    bad "V0: ${PRE_CARVE_SHA:0:9}:scripts/vps/deploy-vps.sh is UNREACHABLE in a full clone, so V1/V1b asserted nothing. The tag refs/tags/vps-pre-carve exists to make this impossible, so it has most likely been DELETED (or this branch was rebased and the sha above was not re-pinned). Fix it, do not skip it: 'git fetch origin refs/tags/vps-pre-carve' first; failing that recover the object with 'git fetch origin refs/pull/110/head' (GitHub keeps that ref forever) and re-push the tag with 'git push origin ${PRE_CARVE_SHA}:refs/tags/vps-pre-carve'; failing THAT, retire V1/V1b deliberately and say in this file what replaces them. Do NOT re-pin to a post-carve revision — V0 checks for that and it compares the tree with itself."
  else
    bad "V0: $REPO_ROOT is not a git work tree, so the pre-carve baseline cannot be read and V1/V1b asserted nothing. Run this harness from a clone, not from a 'git archive' export."
  fi

  if [ -n "$BASELINE" ]; then
    mksandbox pre existing
    mksandbox post existing
    arm pre curl-ok
    arm post curl-ok
    V1_PRE_RC="$(run_deploy pre "$WORK/out/pre.log" "$BASELINE")"
    V1_POST_RC="$(run_deploy post "$WORK/out/post.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh")"

    # V1 — THE PRIVILEGED SEQUENCE, IN ORDER.
    #
    # The first version of this sorted both logs and compared MULTISETS, and it
    # was inert in the one direction that matters. Ordering is this script's
    # entire risk model — stop-before-move, register-before-restart,
    # install-reload-enable — and a pure reordering is invisible to a multiset.
    # Measured: moving the whole `unit_google_workspace` / `completed
    # google-workspace` call site from above the systemd block to below
    # `completed code-agents` left the sorted comparison GREEN. V2a-f pin six
    # specific pairs; the other ~2300 pairs were pinned by nothing.
    #
    # So the comparison is SEQUENCE-EXACT, and the allowlist is an EDIT SCRIPT
    # applied to the pre-carve log rather than a set of permitted lines. Two
    # edits, and both are defended in deploy-vps.sh:
    #
    #   E1  MOVE  the unconditional `daemon-reload` moved from ABOVE the two
    #             tls-cert-renew installs to BELOW them (deploy-vps.sh:618-633).
    #   E2  ADD   unit_telegram_gateway got a reload of its own, immediately
    #             after its install, because that install is GATED and an
    #             unconditional reload would have to run before it
    #             (deploy-vps.sh:641-648).
    #
    # The counts are asserted too ("1 1 1"): an anchor that stopped matching
    # would otherwise degrade this into an identity transform and report the
    # move as a plain difference, blaming the wrong line.
    #
    # WHAT IS NOT ORDERED HERE, stated rather than assumed: nothing in this log
    # is emitted by a loop whose order the source leaves open. The two loops
    # that reach the log iterate literal word lists (`for t in morning-brief
    # inbox-triage weekly-review health-followups` and register-schedules.sh's
    # ORDER=() — its `declare -A` maps are lookups, never iterated). The one
    # glob, config/goose/custom_providers/*.json, is sorted by bash, and BOTH
    # SIDES EXPAND THE SAME GLOB from the same repo in the same environment, so
    # a collation difference moves the two logs together and cancels. Nothing
    # here runs in parallel. Measured: both logs are byte-identical across
    # repeated runs, so a total order does not flap.
    RELOAD='sudo systemctl daemon-reload'
    awk -v reload="$RELOAD" -v countfile="$WORK/out/edits" '
      { line[NR] = $0 }
      END {
        for (i = 1; i <= NR; i++) {
          # E1, delete half: the reload immediately above the tls installs.
          if (line[i] == reload && line[i+1] ~ /^sudo install .*\/tls-cert-renew\.service$/) {
            e1del++
            continue
          }
          print line[i]
          # E1, insert half: below the LAST of the two tls installs.
          if (line[i] ~ /^sudo install .*\/tls-cert-renew\.timer$/) { print reload; e1ins++ }
          # E2: the reload added inside unit_telegram_gateway.
          if (line[i] ~ /^sudo install .*\/goose-telegram-gateway\.service$/) { print reload; e2++ }
        }
        printf "%d %d %d\n", e1del + 0, e1ins + 0, e2 + 0 > countfile
      }
    ' "$WORK/out/pre.log" >"$WORK/out/expected"
    V1_EDITS="$(tr -d '\n' <"$WORK/out/edits")"

    if [ "$V1_PRE_RC" = "0" ] && [ "$V1_POST_RC" = "0" ] && [ "$V1_EDITS" = "1 1 1" ] &&
       diff -u "$WORK/out/expected" "$WORK/out/post.log" >"$WORK/out/seq.diff" 2>&1; then
      ok "V1: the carve issues the pre-carve sequence IN ORDER, with two enumerated edits ($(wc -l <"$WORK/out/pre.log" | tr -d ' ') pre-carve invocations)"
    else
      # Diagnosis, not assertion: the multiset comparison the sequence one
      # replaced still answers the first question a failure raises — did a call
      # appear or vanish, or did the deploy merely REORDER?
      sort "$WORK/out/pre.log"  >"$WORK/out/pre.sorted"
      sort "$WORK/out/post.log" >"$WORK/out/post.sorted"
      comm -23 "$WORK/out/pre.sorted" "$WORK/out/post.sorted" >"$WORK/out/removed"
      comm -13 "$WORK/out/pre.sorted" "$WORK/out/post.sorted" >"$WORK/out/added"
      V1_REM="$(wc -l <"$WORK/out/removed" | tr -d ' ')"
      V1_ADD="$(wc -l <"$WORK/out/added" | tr -d ' ')"
      # 0 removed / 1 added is the multiset the OLD sorted V1 called a pass:
      # the one allowlisted reload and nothing else. Saying so names the class.
      V1_SHAPE="calls appeared or vanished"
      [ "$V1_REM" -ne 0 ] || [ "$V1_ADD" -ne 1 ] || V1_SHAPE="a PURE REORDER — same calls, different order"
      bad "V1: the privileged sequence moved (pre rc=$V1_PRE_RC, post rc=$V1_POST_RC, edits='$V1_EDITS' want '1 1 1'; against the pre-carve multiset $V1_REM removed / $V1_ADD added, i.e. $V1_SHAPE)"
      evidence "$WORK/out/seq.diff"
    fi

    # V1b — the FILE TREE, which the invocation log cannot see: install/cp/ln
    # are real, so this is the assertion that the same bytes landed in the same
    # places. The floor exists because two empty trees also compare equal, and
    # a pre run that died on its first line would satisfy the comparison while
    # proving nothing.
    : >"$WORK/out/inv-pre"; : >"$WORK/out/inv-post"
    : >"$WORK/out/sum-pre"; : >"$WORK/out/sum-post"
    for part in home data etc; do
      inventory "$WORK/sb-pre" "$part"  >>"$WORK/out/inv-pre"
      inventory "$WORK/sb-post" "$part" >>"$WORK/out/inv-post"
      checksums "$WORK/sb-pre" "$part"  >>"$WORK/out/sum-pre"
      checksums "$WORK/sb-post" "$part" >>"$WORK/out/sum-post"
    done
    V1B_FILES="$(grep -c '^f ' "$WORK/out/inv-pre" || true)"
    if [ "${V1B_FILES:-0}" -ge 20 ] &&
       diff -u "$WORK/out/inv-pre" "$WORK/out/inv-post" >"$WORK/out/inv.diff" 2>&1 &&
       diff -u "$WORK/out/sum-pre" "$WORK/out/sum-post" >"$WORK/out/sum.diff" 2>&1; then
      ok "V1b: the carve writes the same $V1B_FILES-file tree, byte for byte, with the same modes and symlink targets"
    else
      bad "V1b: the installed tree differs from pre-carve ${PRE_CARVE_SHA:0:9} (files=${V1B_FILES:-0}, want >=20)"
      evidence "$WORK/out/inv.diff"
      evidence "$WORK/out/sum.diff"
    fi
  fi
fi

# ============================================================================
# V2/V3/V4/V6 — THE FOUR DOCUMENTED CONSTRAINTS, AND THE RELOAD ORDERINGS
# ============================================================================
if leg constraints; then
  mksandbox full existing
  arm full curl-ok
  FULL_LOG="$WORK/out/full.log"
  FULL_RC="$(run_deploy full "$FULL_LOG" "$REPO_ROOT/scripts/vps/deploy-vps.sh")"
  [ "$FULL_RC" = "0" ] && ok "constraints: a full deploy onto an existing brain exits 0" || {
    bad "constraints: a full deploy exited $FULL_RC"
    evidence "$FULL_LOG.err"
  }

  # V2a — CONSTRAINT: nothing may move underneath a running goose.
  V2A_STOP="$(n "$(first_idx "$FULL_LOG" '^sudo systemctl stop goose-serve\.service$')")"
  V2A_MV="$(n "$(first_idx "$FULL_LOG" '^mv @ROOT@/data/goose-data ')")"
  [ "$V2A_STOP" -gt 0 ] && [ "$V2A_MV" -gt 0 ] && [ "$V2A_STOP" -lt "$V2A_MV" ] &&
    ok "V2a: goose-serve is stopped before the first move into the path root" ||
    bad "V2a: stop=$V2A_STOP, first move=$V2A_MV — the migration ran under a live goose"

  # V2b — the gateway install/reload/enable ordering. THE FIX. Before the
  # carve the only reload covering this install was the one inside the
  # code-agents block, i.e. AFTER the enable, so this assertion fails on the
  # pre-carve script.
  V2B_INS="$(n "$(first_idx "$FULL_LOG" '^sudo install -m 644 .*/goose-telegram-gateway\.service ')")"
  V2B_RLD="$(n "$(first_idx_after "$FULL_LOG" '^sudo systemctl daemon-reload$' "$V2B_INS")")"
  V2B_EN="$(n "$(first_idx "$FULL_LOG" '^sudo systemctl enable --now goose-telegram-gateway\.service$')")"
  [ "$V2B_INS" -gt 0 ] && [ "$V2B_RLD" -gt 0 ] && [ "$V2B_EN" -gt 0 ] &&
  [ "$V2B_INS" -lt "$V2B_RLD" ] && [ "$V2B_RLD" -lt "$V2B_EN" ] &&
    ok "V2b: goose-telegram-gateway.service is installed, THEN reloaded, THEN enabled" ||
    bad "V2b: install=$V2B_INS reload=$V2B_RLD enable=$V2B_EN — the gateway is enabled against a cached unit definition"

  # V2b' — the same for tls-cert-renew, which is the half the first audit
  # missed. Move the reload back above the two installs and this goes red.
  V2C_INS="$(n "$(last_idx "$FULL_LOG" '^sudo install -m 644 .*/tls-cert-renew\.(service|timer) ')")"
  V2C_RLD="$(n "$(first_idx_after "$FULL_LOG" '^sudo systemctl daemon-reload$' "$V2C_INS")")"
  V2C_EN="$(n "$(first_idx "$FULL_LOG" '^sudo systemctl enable --now tls-cert-renew\.timer$')")"
  [ "$V2C_INS" -gt 0 ] && [ "$V2C_RLD" -gt 0 ] && [ "$V2C_EN" -gt 0 ] &&
  [ "$V2C_INS" -lt "$V2C_RLD" ] && [ "$V2C_RLD" -lt "$V2C_EN" ] &&
    ok "V2b': tls-cert-renew is installed, THEN reloaded, THEN enabled" ||
    bad "V2b': install=$V2C_INS reload=$V2C_RLD enable=$V2C_EN — the timer is armed against a cached unit definition"

  # V2c — code-agent-manager keeps its own reload.
  V2D_INS="$(n "$(first_idx "$FULL_LOG" '^sudo install -m 644 .*/code-agent-manager\.service ')")"
  V2D_RLD="$(n "$(first_idx_after "$FULL_LOG" '^sudo systemctl daemon-reload$' "$V2D_INS")")"
  V2D_RST="$(n "$(first_idx "$FULL_LOG" '^sudo systemctl restart code-agent-manager\.service$')")"
  [ "$V2D_INS" -gt 0 ] && [ "$V2D_RLD" -gt 0 ] && [ "$V2D_RST" -gt 0 ] &&
  [ "$V2D_INS" -lt "$V2D_RLD" ] && [ "$V2D_RLD" -lt "$V2D_RST" ] &&
    ok "V2c: code-agent-manager.service is installed, THEN reloaded, THEN restarted" ||
    bad "V2c: install=$V2D_INS reload=$V2D_RLD restart=$V2D_RST"

  # V2d — CONSTRAINT: schedules are registered BEFORE the goose-serve restart,
  # because the scheduler reads schedule.json once at startup.
  V2E_ADD="$(n "$(last_idx "$FULL_LOG" '^goose schedule add ')")"
  V2E_RST="$(n "$(last_idx "$FULL_LOG" '^sudo systemctl restart goose-serve\.service$')")"
  [ "$V2E_ADD" -gt 0 ] && [ "$V2E_RST" -gt 0 ] && [ "$V2E_ADD" -lt "$V2E_RST" ] &&
    ok "V2d: every schedule is registered before goose-serve is restarted" ||
    bad "V2d: last add=$V2E_ADD, restart=$V2E_RST — schedules registered after the restart stay dormant"

  # V2e — CONSTRAINT: RESTART, never `enable --now`, for the manager. `--now`
  # is a no-op on a running unit and shipped a new manager to disk while the
  # old process kept serving.
  V2F_RST="$(count_in "$FULL_LOG" '^sudo systemctl restart code-agent-manager\.service$')"
  V2F_NOW="$(count_in "$FULL_LOG" '^sudo systemctl enable --now code-agent-manager\.service$')"
  [ "$V2F_RST" -ge 1 ] && [ "$V2F_NOW" -eq 0 ] &&
    ok "V2e: the manager is restarted ($V2F_RST) and never 'enable --now'd ($V2F_NOW)" ||
    bad "V2e: restart=$V2F_RST enable--now=$V2F_NOW — a running manager would keep serving the old code"

  # V2f — the image exists before the manager is restarted onto it.
  V2G_BLD="$(n "$(first_idx "$FULL_LOG" '^podman build ')")"
  V2G_RST="$(n "$(first_idx "$FULL_LOG" '^sudo systemctl restart code-agent-manager\.service$')")"
  [ "$V2G_BLD" -gt 0 ] && [ "$V2G_RST" -gt 0 ] && [ "$V2G_BLD" -lt "$V2G_RST" ] &&
    ok "V2f: the image is built before the manager is restarted" ||
    bad "V2f: build=$V2G_BLD restart=$V2G_RST"

  # V3 — CONSTRAINT: `ln -sfnT` everywhere. Without -T, `ln -sfn LINK DIR`
  # against a surviving real directory creates DIR/<basename> INSIDE it and
  # reports success, leaving the root-disk copy in place.
  V3_ALL="$(count_in "$FULL_LOG" '^ln ')"
  V3_T="$(count_in "$FULL_LOG" '^ln -sfnT ')"
  [ "$V3_ALL" -ge 4 ] && [ "$V3_ALL" -eq "$V3_T" ] &&
    ok "V3: all $V3_ALL ln invocations carry -sfnT" ||
    bad "V3: $V3_ALL ln invocations, only $V3_T with -T — a symlink can silently nest inside a surviving directory"

  # V6 — AC4: the path-root migration runs ONCE per host per deploy, whatever
  # is selected. Four links into the path root (config, state, data, plus the
  # legacy /data/goose-data compatibility link) and exactly one stop.
  V6_LINKS="$(count_in "$FULL_LOG" '^ln -sfnT @ROOT@/data/goose/')"
  V6_STOPS="$(count_in "$FULL_LOG" '^sudo systemctl stop goose-serve\.service$')"
  mksandbox onlyauto existing
  arm onlyauto curl-ok
  V6_RC="$(run_deploy onlyauto "$WORK/out/onlyauto.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh" --only automations)"
  V6_LINKS2="$(count_in "$WORK/out/onlyauto.log" '^ln -sfnT @ROOT@/data/goose/')"
  V6_STOPS2="$(count_in "$WORK/out/onlyauto.log" '^sudo systemctl stop goose-serve\.service$')"
  [ "$V6_LINKS" -eq 4 ] && [ "$V6_STOPS" -eq 1 ] &&
  [ "$V6_LINKS2" -eq 4 ] && [ "$V6_STOPS2" -eq 1 ] && [ "$V6_RC" = "0" ] &&
    ok "V6: the migration is 4 links and 1 stop, identical under --only automations" ||
    bad "V6: full=($V6_LINKS links,$V6_STOPS stops) --only automations=($V6_LINKS2 links,$V6_STOPS2 stops, rc=$V6_RC)"

  # V3b — the two `|| fail` arms, which are UNREACHABLE through the script's
  # own control flow: a successful mv/rm always removes the source. Reached
  # here with a lying mv and a lying rm. This proves the guard is LIVE. It does
  # not prove the situation arises.
  mksandbox lie1 existing
  arm lie1 curl-ok
  arm lie1 lie-mv
  LIE1_RC="$(run_deploy lie1 "$WORK/out/lie1.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh")"
  [ "$LIE1_RC" != "0" ] && grep -q 'config/goose is still a real directory' "$WORK/out/lie1.log.err" &&
    ok "V3b-1: a mv that copies without unlinking makes migrate_into_root fail loudly, naming the directory" || {
    bad "V3b-1: rc=$LIE1_RC — the run nested a symlink inside a surviving directory and did not say so"
    evidence "$WORK/out/lie1.log.err"
  }

  mksandbox lie2 fresh
  arm lie2 curl-ok
  mkdir -p "$WORK/sb-lie2/home/agent/.google_workspace_mcp"
  echo "token" >"$WORK/sb-lie2/home/agent/.google_workspace_mcp/creds.json"
  arm lie2 lie-rm
  LIE2_RC="$(run_deploy lie2 "$WORK/out/lie2.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh")"
  [ "$LIE2_RC" != "0" ] && grep -q 'google_workspace_mcp is still a real directory' "$WORK/out/lie2.log.err" &&
    ok "V3b-2: an rm that does not remove makes the OAuth-token link fail loudly, naming the directory" || {
    bad "V3b-2: rc=$LIE2_RC — the OAuth tokens would have stayed on the unencrypted root disk with every check reporting success"
    evidence "$WORK/out/lie2.log.err"
  }

  # V4a — CONSTRAINT: the EXIT trap brings goose back on ANY failure path.
  # Gateway NOT enabled here, so the trap must start goose-serve and nothing
  # else. Armed at `podman build`, which is the real-world case the trap's
  # comment names.
  mksandbox trapa fresh
  arm trapa curl-ok
  arm trapa podman-build-fails
  TRAPA_RC="$(run_deploy trapa "$WORK/out/trapa.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh")"
  TRAPA_LAST="$(grep -E 'systemctl ' "$WORK/out/trapa.log" | tail -n1 || true)"
  [ "$TRAPA_RC" != "0" ] && [ "$TRAPA_LAST" = "sudo systemctl start goose-serve.service" ] &&
    ok "V4a: a failed podman build still leaves goose-serve started by the EXIT trap" || {
    bad "V4a: rc=$TRAPA_RC, last systemctl line was '$TRAPA_LAST' — the brain would be left offline"
    evidence "$WORK/out/trapa.log"
  }

  # V4b — the same trap with the gateway ENABLED, in its own sandbox. This is
  # the arm that dies silently if GATEWAY_WAS_ENABLED is ever made `local`:
  # under `set -u` the trap would abort AFTER starting goose-serve and BEFORE
  # starting the gateway, and V4a would still pass.
  mksandbox trapb fresh
  arm trapb curl-ok
  TRAPB_RC1="$(run_deploy trapb "$WORK/out/trapb1.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh")"
  arm trapb podman-build-fails
  TRAPB_RC2="$(run_deploy trapb "$WORK/out/trapb2.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh")"
  TRAPB_TAIL="$(grep -E 'systemctl ' "$WORK/out/trapb2.log" | tail -n2 | tr '\n' '|')"
  [ "$TRAPB_RC1" = "0" ] && [ "$TRAPB_RC2" != "0" ] &&
  [ "$TRAPB_TAIL" = "sudo systemctl start goose-serve.service|sudo systemctl start goose-telegram-gateway.service|" ] &&
    ok "V4b: with the gateway enabled, the trap restores goose-serve AND the gateway, in that order" || {
    bad "V4b: run1 rc=$TRAPB_RC1 run2 rc=$TRAPB_RC2, trap tail was '$TRAPB_TAIL'"
    evidence "$WORK/out/trapb2.log"
  }
fi

# ============================================================================
# V5 — SELECTION
# ============================================================================
if leg select; then
  # V5 (AC1) — the whole point of the ticket.
  mksandbox nocode fresh --deny
  arm nocode curl-ok
  V5_RC="$(run_deploy nocode "$WORK/out/nocode.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh" --without code-agents)"
  V5_DENY="$(wc -l <"$WORK/aux-nocode/deny.log" | tr -d ' ')"
  V5_RESTART="$(count_in "$WORK/out/nocode.log" '^sudo systemctl restart goose-serve\.service$')"
  V5_CURL="$(count_in "$WORK/out/nocode.log" '^curl ')"
  if [ "$V5_RC" = "0" ] && [ "$V5_DENY" -eq 0 ] &&
     [ ! -e "$WORK/sb-nocode/data/code-agents" ] &&
     [ ! -e "$WORK/sb-nocode/etc/systemd/system/code-agent-manager.service" ] &&
     [ ! -s "$WORK/sb-nocode/etc/subuid" ] &&
     [ "$V5_RESTART" -eq 1 ] && [ "$V5_CURL" -ge 1 ]; then
    ok "V5: --without code-agents installs no podman, adds no subuid range, builds no image and creates no /data/code-agents — and still restarts goose-serve and probes /status"
  else
    bad "V5: rc=$V5_RC deny-lines=$V5_DENY restarts=$V5_RESTART curls=$V5_CURL, code-agents dir/unit/subuid present?"
    evidence "$WORK/aux-nocode/deny.log"
    evidence "$WORK/out/nocode.log.err"
  fi

  # V5b — the other three gates, one sandbox each. No acceptance criterion
  # covers these, but the Scope wraps them, and a gate nobody tests is a gate
  # somebody deletes.
  mksandbox notg fresh
  arm notg curl-ok
  V5B1_RC="$(run_deploy notg "$WORK/out/notg.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh" --without telegram-gateway)"
  [ "$V5B1_RC" = "0" ] &&
  [ ! -e "$WORK/sb-notg/etc/systemd/system/goose-telegram-gateway.service" ] &&
  [ "$(count_in "$WORK/out/notg.log" 'enable --now goose-telegram-gateway')" -eq 0 ] &&
    ok "V5b: --without telegram-gateway installs and enables no gateway unit" ||
    bad "V5b: --without telegram-gateway rc=$V5B1_RC and the unit file or the enable survived"

  mksandbox nogw fresh
  arm nogw curl-ok
  V5B2_RC="$(run_deploy nogw "$WORK/out/nogw.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh" --without google-workspace)"
  [ "$V5B2_RC" = "0" ] &&
  [ ! -e "$WORK/sb-nogw/home/agent/.google_workspace_mcp" ] &&
  [ ! -e "$WORK/sb-nogw/data/workspace-mcp" ] &&
    ok "V5b: --without google-workspace creates neither the token link nor its target" ||
    bad "V5b: --without google-workspace rc=$V5B2_RC and the token directory was still created"

  mksandbox noauto fresh
  arm noauto curl-ok
  V5B3_RC="$(run_deploy noauto "$WORK/out/noauto.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh" --without automations)"
  [ "$V5B3_RC" = "0" ] &&
  [ "$(count_in "$WORK/out/noauto.log" '^goose schedule add ')" -eq 0 ] &&
  [ "$(count_in "$WORK/out/noauto.log" '^sudo install -m 644 .*/goose-recipe@morning-brief\.timer$')" -eq 1 ] &&
    ok "V5b: --without automations registers no schedule, and STILL installs the fallback timers (they are the escape hatch for a broken deploy)" ||
    bad "V5b: --without automations rc=$V5B3_RC — either a schedule was registered or the fallback timers went missing"

  # V5c — --dry-run writes NOTHING. Not "the gates return early": the brain
  # core is ungateable, so a dry-run that only silenced the four unit bodies
  # would still stop goose, migrate three directories and install seven units.
  mksandbox dry existing
  arm dry curl-ok
  inventory "$WORK/sb-dry" home >"$WORK/out/dry-before"
  inventory "$WORK/sb-dry" data >>"$WORK/out/dry-before"
  inventory "$WORK/sb-dry" etc  >>"$WORK/out/dry-before"
  V5C_RC="$(run_deploy dry "$WORK/out/dry.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh" --dry-run --without code-agents)"
  inventory "$WORK/sb-dry" home >"$WORK/out/dry-after"
  inventory "$WORK/sb-dry" data >>"$WORK/out/dry-after"
  inventory "$WORK/sb-dry" etc  >>"$WORK/out/dry-after"
  V5C_CALLS="$(wc -l <"$WORK/out/dry.log" | tr -d ' ')"
  V5C_NAMED=0
  for id in google-workspace telegram-gateway code-agents automations; do
    grep -q -- "$id" "$WORK/out/dry.log.out" && V5C_NAMED=$((V5C_NAMED + 1)) || true
  done
  if [ "$V5C_RC" = "0" ] && [ "$V5C_CALLS" -eq 0 ] && [ "$V5C_NAMED" -eq 4 ] &&
     diff -u "$WORK/out/dry-before" "$WORK/out/dry-after" >"$WORK/out/dry.diff" 2>&1; then
    ok "V5c: --dry-run invokes nothing, writes nothing, names all 4 units and exits 0"
  else
    bad "V5c: rc=$V5C_RC, $V5C_CALLS host calls, $V5C_NAMED/4 units named, tree changed?"
    evidence "$WORK/out/dry.diff"
  fi

  # V11 — check-code-agents.sh must SKIP (exit 2), not FAIL, on a brain that
  # deliberately has no code-agents plane. Without this, AC1 ships a
  # permanently-red check: cli.sh:197-213 maps exit 2 to SKIP and everything
  # else to FAIL. (Re-anchored past #108, which rewrote cli.sh and gave that
  # arm a `--require` escalation; the mapping this depends on is unchanged.)
  V11_RC=0
  PAI_MODE=local \
  PAI_DATA_ROOT="$WORK/sb-nocode/data" \
  PAI_SYSTEMD_DIR="$WORK/sb-nocode/etc/systemd/system" \
    "$REPO_ROOT/scripts/verify/check-code-agents.sh" >"$WORK/out/v11.log" 2>&1 || V11_RC=$?
  [ "$V11_RC" -eq 2 ] &&
    ok "V11: check-code-agents.sh exits 2 (SKIP) when the plane was deselected" || {
    bad "V11: check-code-agents.sh exited $V11_RC, want 2 — 'pai verify' would report a FAIL for a unit nobody installed"
    evidence "$WORK/out/v11.log"
  }
fi

# ============================================================================
# V7 — IDEMPOTENCE
# ============================================================================
if leg rerun; then
  mksandbox rerun fresh
  arm rerun curl-ok
  V7_RC1="$(run_deploy rerun "$WORK/out/rerun1.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh")"
  # A user's edit to the seeded allowlist. install_template must never
  # overwrite it, on this run or any later one.
  SENTINEL="pai-rerun-sentinel-$(openssl rand -hex 8)"
  V7_READY=0
  if [ -f "$WORK/sb-rerun/data/code-agents/repos.json" ]; then
    printf '\n// %s\n' "$SENTINEL" >>"$WORK/sb-rerun/data/code-agents/repos.json"
    V7_READY=1
  fi
  V7_RC2="$(run_deploy rerun "$WORK/out/rerun2.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh")"
  V7_APT="$(count_in "$WORK/out/rerun2.log" '^apt-get install ')"
  V7_SUPERSEDED="$(find "$WORK/sb-rerun" -name '*.superseded.*' | wc -l | tr -d ' ')"
  V7_SENTINEL=0
  grep -qF "$SENTINEL" "$WORK/sb-rerun/data/code-agents/repos.json" 2>/dev/null && V7_SENTINEL=1 || true
  if [ "$V7_RC1" = "0" ] && [ "$V7_RC2" = "0" ] && [ "$V7_APT" -eq 0 ] &&
     [ "$V7_SUPERSEDED" -eq 0 ] && [ "$V7_READY" -eq 1 ] && [ "$V7_SENTINEL" -eq 1 ]; then
    ok "V7: the re-run exits 0, installs no packages, supersedes nothing and keeps the local edit"
  else
    bad "V7: rc1=$V7_RC1 rc2=$V7_RC2 apt-installs=$V7_APT superseded=$V7_SUPERSEDED sentinel(ready=$V7_READY,kept=$V7_SENTINEL)"
    evidence "$WORK/out/rerun2.log.err"
  fi
fi

# ============================================================================
# V8/V9 — THE /status GATE AND ERR ATTRIBUTION
# ============================================================================
if leg status; then
  # V8 (AC6a) — the deploy BLOCKS on /status. curl is unarmed, so every probe
  # fails and the real 45-attempt loop runs. `sleep` is shimmed to return
  # immediately, so this costs milliseconds instead of 90 seconds.
  mksandbox down fresh
  V8_RC="$(run_deploy down "$WORK/out/down.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh")"
  V8_CURL="$(count_in "$WORK/out/down.log" '^curl ')"
  V8_SLEEP="$(count_in "$WORK/out/down.log" '^sleep 2$')"
  V8_RESTART="$(count_in "$WORK/out/down.log" '^sudo systemctl restart goose-serve\.service$')"
  V8_START="$(count_in "$WORK/out/down.log" '^sudo systemctl start goose-serve\.service$')"
  if [ "$V8_RC" != "0" ] && [ "$V8_CURL" -eq 45 ] && [ "$V8_SLEEP" -eq 45 ] &&
     [ "$V8_RESTART" -eq 1 ] && [ "$V8_START" -eq 0 ] &&
     grep -q 'journalctl -u goose-serve' "$WORK/out/down.log.err"; then
    ok "V8: a dead /status is 45 probes, a non-zero exit naming journalctl, and NO trap restart (the trap was cleared before the intentional one)"
  else
    bad "V8: rc=$V8_RC curls=$V8_CURL sleeps=$V8_SLEEP restarts=$V8_RESTART trap-starts=$V8_START"
    evidence "$WORK/out/down.log.err"
  fi

  # V9 (AC6b, amended) — the deploy does NOT continue past a failed unit, and
  # should not: the brain core is a prerequisite for everything after it. What
  # it does instead is ATTRIBUTE. Without `set -E` neither line below prints,
  # because an ERR trap is not inherited by shell functions.
  mksandbox errattr fresh
  arm errattr curl-ok
  arm errattr goose-add-fails
  V9_RC="$(run_deploy errattr "$WORK/out/errattr.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh")"
  if [ "$V9_RC" != "0" ] &&
     grep -q "unit 'automations' failed" "$WORK/out/errattr.log.err" &&
     grep -qE '^ *completed:.*code-agents' "$WORK/out/errattr.log.err"; then
    ok "V9: a failing unit is named, with the units that completed before it"
  else
    bad "V9: rc=$V9_RC — the failure was not attributed to a unit"
    evidence "$WORK/out/errattr.log.err"
  fi
fi

# ---- summary ----------------------------------------------------------------
echo
if [ "$SKIP_COUNT" -eq 0 ]; then
  echo "== summary: $PASS_COUNT passed, $FAIL_COUNT failed =="
else
  echo "== summary: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped =="
fi
[ "$FAIL_COUNT" -eq 0 ] || exit 1
