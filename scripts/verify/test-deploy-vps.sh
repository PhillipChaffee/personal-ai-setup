#!/usr/bin/env bash
# test-deploy-vps.sh — scripts/vps/deploy-vps.sh, EXECUTED, with no VPS, no
# /data, no systemd and no network. The deploy runs for real against
# scripts/verify/fake-host.sh in a throwaway directory tree, and every
# assertion below is about what it INVOKED and what it WROTE.
#
# WHAT A GREEN RUN HERE MEANS, exactly, and nothing beyond it:
#
#   "deploy-vps.sh stops goose-serve before the first move into the path root,
#    installs the herdr unit then reloads then restarts it, always links with
#    -T, runs the migration once per host per deploy whatever is selected,
#    selects NOTHING on a bare run, honours --with/--without/--only and the
#    --coding-agents gating (agents require herdr; the catalog is enforced),
#    installs the herdr plane in the recorded order (user, pinned digest-
#    checked binary, config, pick-aware env, unit), exits 0 on a re-run
#    without re-downloading or re-creating the user or superseding anything,
#    blocks on a dead /status, attributes a failing unit by name, and refuses
#    a unit id or a coding-agent id that is not in the catalog."
#
# WHAT IT CANNOT MEAN. There is no CI on earth that can run this script against
# a real brain, so the following stay a human's job on a real VPS and are
# listed here rather than left to be assumed:
#   * that apt-get, systemd, sudo -u, useradd, npm and curl behave as
#     fake-host.sh models them on Ubuntu;
#   * that the herdr binary and the agent CLIs run, that `herdr integration
#     install` writes its hooks, or that the namespace sandbox holds — the
#     fixture binaries are sh stubs; the LIVE evidence about the real host is
#     check-herdr.sh plus first boot (the unit's namespace combination is
#     syntax-checked by `systemd-analyze verify` in CI and proven on boot);
#   * that file OWNERSHIP is real — install -o/-g are recorded and dropped in
#     the fake (a chown is impossible unprivileged), so "owner herdr" claims
#     are check-herdr.sh's, not this harness's;
#   * check-herdr.sh's live arms (service, namespace properties, socket,
#     isolation, disk) — the harness runs only its SKIP arm (V11).
#
# WHERE THE DIFFERENTIAL WENT. V0/V1/V1b — a sequence-and-file-tree
# differential against the pre-carve seam commit — retired with the automations
# removal (#143, 2026-09-23). What carries the guarantee forward is the
# constraint set below (V2a/V2c/V2e/V2f/V3/V6) plus the selection, idempotence
# and /status legs, which assert the properties that survived rather than a
# sequence no longer reachable.
#
# LINUX ONLY, and it dies 2 saying so. `ln -sfnT` (GNU -T) and `stat -c %a`
# rule out stock macOS, and a partial pass
# would be worse than no pass: half these assertions are ABOUT the GNU-only
# behaviour. This is a deliberate departure from test-base-install.sh's
# laptop-friendliness. Develop it in CI or in a container.
#
# ASSERTION IDS carry through from the design so a failure names the claim:
#   V2a      stop before the first move        V5/V5b/V5c   selection + dry run
#   V2c/V2e/V2f  herdr reload/restart/env rules V12         --coding-agents gating
#   V3/V3b   the -T constraint, both directions V7          idempotence
#   V4a      the EXIT trap                      V8/V9       the /status gate, ERR
#   V6       the migration runs once            V11         check-herdr skip
#   V13      the plane's install shape
#
# NOTHING HERE MAY CONTAIN A LITERAL SECRET-SHAPED CONSTANT. The fixture
# secrets.env is generated with `openssl rand -hex 32` at run time, and no
# assertion message interpolates a value -- counts, booleans and exit codes
# only. The fixture pins file is written at sandbox-build time with the sha256
# OF THE FIXTURE ASSETS THEMSELVES, so the digest pin is exercised against
# bytes this harness can prove.
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
Usage: test-deploy-vps.sh [--only constraints|select|gating|rerun|status] [--help]

Runs scripts/vps/deploy-vps.sh against scripts/verify/fake-host.sh inside a
throwaway directory. Linux only. Exits non-zero if any assertion fails.

  --only constraints   V2a, V2c/V2e/V2f, V3, V3b, V4a, V6: the documented
                       constraints on this deploy, plus the reload orderings
  --only select        V5/V5b/V5c/V11: the bare-run default, --only, dry run
  --only gating        V12: --coding-agents requires herdr; the catalog
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
  ""|constraints|select|gating|rerun|status) ;;
  *) echo "test-deploy-vps.sh: unknown --only leg: $ONLY" >&2; exit 2 ;;
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
# exits 1 on `id -u` == 0, so under root EVERY run of it dies on its first line
# and every assertion below fails for that one reason. Measured before this
# guard existed, in ubuntu:24.04 as root: 1 pass, 13 failures saying things
# like "the brain would be left offline", and then the harness died inside V4b
# without printing a summary at all. Not one of those failures was about the
# code under test, and the count is environment-dependent — which is the point:
# a root run reports the wrong cause 13 different ways. The obvious way to hit
# it is a bare `docker run ubuntu:24.04`.
[ "$(id -u)" -ne 0 ] || die "refusing to run as root: deploy-vps.sh's preflight refuses root, so every assertion here would fail for that one reason and name the wrong cause. Run as an unprivileged user (in a container: 'useradd -m tester' then run as tester)."

# THE BRAIN INTERLOCK. deploy-vps.sh reads the LITERAL /data/secrets.env in its
# preflight (it has no seam for the file itself — the seam roots are what move).
# On a real brain that would make this harness read the owner's secrets. Refuse.
[ ! -r /data/secrets.env ] || die "/data/secrets.env is readable — this looks like the brain itself. This harness must not run there."

REQUIRED_TOOLS="bash env openssl git diff comm sort grep sed awk find head tail wc tr cut cmp ls stat id date basename readlink mktemp seq install ln mv cp rm rmdir mkdir chmod cat sha256sum uname tar gzip"
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
PATHMIN_TOOLS="bash sh env seq head tail grep cmp ls stat id basename readlink find sed cat wc tr sort dirname uname mktemp awk sha256sum tar test gzip"
for tool in $PATHMIN_TOOLS; do
  real="$(command -v "$tool")" || die "pathmin: no $tool"
  # `command -v` answers with a BARE name for shell builtins (test is one);
  # a relative symlink target would point at $PATHMIN itself and break. Only
  # absolute paths are linkable; anything else resolves from /usr/bin.
  case "$real" in
    /*) ;;
    *) real="/usr/bin/$tool" ;;
  esac
  [ -x "$real" ] || die "pathmin: $tool resolved to '$real', which is not executable"
  ln -sf "$real" "$PATHMIN/$tool"
done

SHIM_NAMES="sudo systemctl apt-get usermod loginctl tailscale curl mountpoint git goose sleep date ln mv cp rm rmdir install chmod mkdir id useradd npm"
DENY_NAMES="podman apt-get usermod loginctl npm useradd"

# ---- 2b. the fixture secrets ------------------------------------------------
# GENERATED, never typed: a literal here would be a secret-shaped constant in a
# public repo and gitleaks would be right to reject it. The vendor rows
# (ANTHROPIC_API_KEY / OPENAI_API_KEY) are deliberately absent: the herdr legs
# pick opencode, whose row is TOGETHER_API_KEY, so the vendor-first rule's both
# branches cannot both fire on one fixture.
SECRETS_FIXTURE="$WORK/secrets.env"
{
  echo "OPENCODE_ZEN_API_KEY=$(openssl rand -hex 32)"
  echo "TOGETHER_API_KEY=$(openssl rand -hex 32)"
  echo "GOOSE_SERVER__SECRET_KEY=$(openssl rand -hex 32)"
  echo "GITHUB_CODE_AGENT_PAT=$(openssl rand -hex 32)"
} >"$SECRETS_FIXTURE"
chmod 600 "$SECRETS_FIXTURE"

# ---- 3. sandbox construction ------------------------------------------------
# Two directories per sandbox, and the split matters: $WORK/sb-<tag> is the
# FAKE HOST (home, /data, /etc) and nothing else, so an inventory of it is an
# inventory of what the deploy wrote. The fake's own log, state and shim
# directory live in $WORK/aux-<tag>, outside it.
#
# THE PINS SEAM. deploy-vps.sh reads its versions out of $REPO_DIR/config/
# pins.yaml via the PAI_PINS_FILE seam, and the fixture pins carry the sha256
# OF THE FIXTURE ASSETS — computed here, from the bytes fake-host.sh's curl
# will serve. That is what makes the digest pin EXERCISED rather than skipped:
# a tampered asset (download-lies) has different bytes, the check fires, and
# the deploy must fail loudly.
mksandbox() {
  # mksandbox <tag> <fresh|existing> [--deny]
  local tag="$1" kind="$2" deny="${3:-}"
  local sb="$WORK/sb-$tag" aux="$WORK/aux-$tag"
  mkdir -p "$sb/home/agent" "$sb/data" "$sb/etc/systemd/system" "$sb/bin" \
           "$sb/repo" "$sb/repo-pins" "$aux/state" "$aux/shims" "$aux/deny"
  : >"$sb/etc/subuid"

  # The repo the deploy pulls and copies templates out of. Symlinks to the real
  # thing: config/ and scripts/ are INPUTS to both sides of every assertion and
  # must be the same inputs. `.git` is a real directory so
  # deploy-vps.sh's `[[ -d "$REPO_DIR/.git" ]]` (a bash builtin test, not
  # routed) takes the pull branch.
  ln -sfn "$REPO_ROOT/config" "$sb/repo/config"
  ln -sfn "$REPO_ROOT/scripts" "$sb/repo/scripts"
  mkdir -p "$sb/repo/.git"

  cp "$SECRETS_FIXTURE" "$sb/data/secrets.env"
  chmod 600 "$sb/data/secrets.env"

  # Unquoted on purpose: $SHIM_NAMES is a WORD LIST, and quoting it would hand
  # fake-host.sh a single filename.
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

  # ---- the download fixtures (herdr + the opencode asset) ----
  # The herdr asset is a stub binary: --version answers the pin, server and
  # integration exit 0 — enough to drive the version guard and the
  # integration hook without a real binary. The opencode asset is a REAL
  # tar.gz holding one executable stub named `opencode`, because the deploy
  # extracts it with real tar after the digest check.
  # extracts it with real tar after the digest check.
  # shellcheck disable=SC2016  # "$1" is for the SHIM to expand at its runtime
  printf '#!/bin/sh\ncase "$1" in --version) echo "herdr 0.9.1";; server) exit 0;; integration) exit 0;; *) exit 0;; esac\n' \
    >"$aux/state/asset-herdr"
  chmod 755 "$aux/state/asset-herdr"
  ocpkg="$aux/state/opencode-pkg"
  mkdir -p "$ocpkg"
  # shellcheck disable=SC2016  # "$1" is for the shim's runtime, not here
  printf '#!/bin/sh\ncase "$1" in --version) echo "opencode 1.18.32";; *) exit 0;; esac\n' \
    >"$ocpkg/opencode"
  chmod 755 "$ocpkg/opencode"
  tar -czf "$aux/state/asset-opencode" -C "$ocpkg" opencode
  rm -rf "$ocpkg"
  # The claude and grok installers: stubs modelling the documented installers —
  # argv 1 is the pinned version; they create the binary the version guard
  # probes, under the HOME the deploy runs them with.
  cat >"$aux/state/asset-claude-install" <<'EOF'
#!/bin/sh
ver="${1:?the fake installer needs the pinned version as argv 1}"
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\ncase "$1" in --version) echo "%s";; *) exit 0;; esac\n' "$ver" >"$HOME/.local/bin/claude"
chmod 755 "$HOME/.local/bin/claude"
EOF
  cat >"$aux/state/asset-grok-install" <<'EOF'
#!/bin/sh
ver="${1:?the fake installer needs the pinned version as argv 1}"
mkdir -p "$HOME/.grok/bin"
printf '#!/bin/sh\ncase "$1" in --version) echo "%s";; *) exit 0;; esac\n' "$ver" >"$HOME/.grok/bin/grok"
chmod 755 "$HOME/.grok/bin/grok"
EOF
  chmod 755 "$aux/state/asset-claude-install" "$aux/state/asset-grok-install"
  printf 'NOT-THE-PINNED-ASSET\n' >"$aux/state/asset-bad"

  # The fixture pins: versions matching the fixture stubs, digests computed
  # from the fixture bytes.
  herdr_digest="$(sha256sum "$aux/state/asset-herdr" | cut -d' ' -f1)"
  oc_digest="$(sha256sum "$aux/state/asset-opencode" | cut -d' ' -f1)"
  {
    echo "goose:"
    echo '  version: "1.51.0"'
    echo "herdr:"
    echo '  version: "0.9.1"'
    echo '  asset: "herdr-linux-x86_64"'
    echo "  sha256: \"$herdr_digest\""
    echo "coding_agents:"
    echo "  opencode:"
    echo '    version: "1.18.32"'
    echo '    asset: "opencode-linux-x64.tar.gz"'
    echo "    sha256: \"$oc_digest\""
    echo "  pi:"
    echo '    version: "0.87.1"'
    echo '    package: "@earendil-works/pi-coding-agent"'
    echo "  claude_code:"
    echo '    version: "2.1.282"'
    echo "  codex:"
    echo '    version: "0.156.1"'
    echo '    package: "@openai/codex"'
    echo "  grok_build:"
    echo '    version: "1.0.41"'
  } >"$sb/repo-pins/pins.yaml"

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
    cp "$REPO_ROOT/scripts/vps/systemd/goose-serve.service" \
       "$sb/etc/systemd/system/goose-serve.service"
    printf 'goose-serve.service\n' >"$aux/state/systemd-enabled"
    printf 'goose-serve.service\n' >"$aux/state/systemd-active"
  fi
}

arm()   { : >"$WORK/aux-$1/state/$2"; }
disarm() { rm -f "$WORK/aux-$1/state/$2"; }

HERDR_FLAGS=(--with herdr --coding-agents opencode)

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
  PAI_PINS_FILE="$sb/repo-pins/pins.yaml" \
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
# with the sandbox root collapsed. `diff -r` is NOT used: the two sides of a
# comparison live at different absolute paths, so every symlink target
# differs textually while the trees are identical, and `diff -r` dereferences
# and hides exactly the thing this repo's -T constraint is about.
inventory() {
  # inventory <sandbox-root> <part>. The sandbox root is normalised out of
  # SYMLINK TARGETS, which are absolute and therefore name the sandbox.
  local sb="$1" part="$2"
  find "$sb/$part" -mindepth 1 \
    \( -type d -printf 'd %m %P\n' \) -o \
    \( -type f -printf 'f %m %P\n' \) -o \
    \( -type l -printf 'l --- %P -> %l\n' \) \
    | sed "s|$sb|@ROOT@|g" | sort
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
# V2/V3/V4/V6 — THE DOCUMENTED CONSTRAINTS, AND THE RELOAD ORDERINGS
# ============================================================================
if leg constraints; then
  mksandbox full existing
  arm full curl-ok
  FULL_LOG="$WORK/out/full.log"
  FULL_RC="$(run_deploy full "$FULL_LOG" "$REPO_ROOT/scripts/vps/deploy-vps.sh" "${HERDR_FLAGS[@]}")"
  [ "$FULL_RC" = "0" ] && ok "constraints: a herdr deploy onto an existing brain exits 0" || {
    bad "constraints: a herdr deploy exited $FULL_RC"
    evidence "$FULL_LOG.err"
  }

  # V2a — CONSTRAINT: nothing may move underneath a running goose.
  V2A_STOP="$(n "$(first_idx "$FULL_LOG" '^sudo systemctl stop goose-serve\.service$')")"
  V2A_MV="$(n "$(first_idx "$FULL_LOG" '^mv @ROOT@/data/goose-data ')")"
  [ "$V2A_STOP" -gt 0 ] && [ "$V2A_MV" -gt 0 ] && [ "$V2A_STOP" -lt "$V2A_MV" ] &&
    ok "V2a: goose-serve is stopped before the first move into the path root" ||
    bad "V2a: stop=$V2A_STOP, first move=$V2A_MV — the migration ran under a live goose"

  # V2c — herdr.service keeps its own reload: install, THEN reload, THEN
  # restart. The reload is the ONE in-unit reload in the file (the negative
  # controls in install-test.yml count it), and the restart must never precede
  # either.
  V2C_INS="$(n "$(first_idx "$FULL_LOG" '^sudo install -m 644 .*/herdr\.service ')")"
  V2C_RLD="$(n "$(first_idx_after "$FULL_LOG" '^sudo systemctl daemon-reload$' "$V2C_INS")")"
  V2C_RST="$(n "$(first_idx "$FULL_LOG" '^sudo systemctl restart herdr\.service$')")"
  [ "$V2C_INS" -gt 0 ] && [ "$V2C_RLD" -gt 0 ] && [ "$V2C_RST" -gt 0 ] &&
  [ "$V2C_INS" -lt "$V2C_RLD" ] && [ "$V2C_RLD" -lt "$V2C_RST" ] &&
    ok "V2c: herdr.service is installed, THEN reloaded, THEN restarted" ||
    bad "V2c: install=$V2C_INS reload=$V2C_RLD restart=$V2C_RST"

  # V2e — CONSTRAINT: RESTART, never `enable --now`, for the herdr unit.
  # `--now` is a no-op on a running unit and would ship a new unit file while
  # the old server kept running — the exact failure the manager once shipped.
  V2F_RST="$(count_in "$FULL_LOG" '^sudo systemctl restart herdr\.service$')"
  V2F_NOW="$(count_in "$FULL_LOG" '^sudo systemctl enable --now herdr\.service$')"
  [ "$V2F_RST" -ge 1 ] && [ "$V2F_NOW" -eq 0 ] &&
    ok "V2e: herdr is restarted ($V2F_RST) and never 'enable --now'd ($V2F_NOW)" ||
    bad "V2e: restart=$V2F_RST enable--now=$V2F_NOW — a running herdr would keep serving stale config"

  # V2f — the credentials and the config exist before the service restarts
  # onto them: the env file is EnvironmentFile, and a restart against an
  # unwritten one fails the unit.
  V2F_ENV="$(n "$(first_idx "$FULL_LOG" '^sudo install -o herdr -g herdr -m 600 .*/data/herdr/secrets\.env$')")"
  V2F_RST="$(n "$(first_idx "$FULL_LOG" '^sudo systemctl restart herdr\.service$')")"
  [ "$V2F_ENV" -gt 0 ] && [ "$V2F_RST" -gt 0 ] && [ "$V2F_ENV" -lt "$V2F_RST" ] &&
    ok "V2f: the pick-aware env file is written before herdr is restarted" ||
    bad "V2f: env-install=$V2F_ENV restart=$V2F_RST — the unit would start on an absent EnvironmentFile"

  # V3 — CONSTRAINT: `ln -sfnT` everywhere. Without -T, `ln -sfn LINK DIR`
  # against a surviving real directory creates DIR/<basename> INSIDE it and
  # reports success, leaving the root-disk copy in place. (The herdr
  # discovery symlink runs under sudo, so its log line starts with `sudo` —
  # the same constraint, a different prefix; this count is the bare ones.)
  V3_ALL="$(count_in "$FULL_LOG" '^ln ')"
  V3_T="$(count_in "$FULL_LOG" '^ln -sfnT ')"
  [ "$V3_ALL" -ge 4 ] && [ "$V3_ALL" -eq "$V3_T" ] &&
    ok "V3: all $V3_ALL ln invocations carry -sfnT" ||
    bad "V3: $V3_ALL ln invocations, only $V3_T with -T — a symlink can silently nest inside a surviving directory"

  # V6 — AC4: the path-root migration runs ONCE per host per deploy, whatever
  # is selected. Four links into the path root (config, state, data, plus the
  # legacy /data/goose-data compatibility link) and exactly one stop — also
  # under --only herdr, where the brain core still runs.
  V6_LINKS="$(count_in "$FULL_LOG" '^ln -sfnT @ROOT@/data/goose/')"
  V6_STOPS="$(count_in "$FULL_LOG" '^sudo systemctl stop goose-serve\.service$')"
  mksandbox onlyunit existing
  arm onlyunit curl-ok
  V6_RC="$(run_deploy onlyunit "$WORK/out/onlyunit.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh" --only herdr)"
  V6_LINKS2="$(count_in "$WORK/out/onlyunit.log" '^ln -sfnT @ROOT@/data/goose/')"
  V6_STOPS2="$(count_in "$WORK/out/onlyunit.log" '^sudo systemctl stop goose-serve\.service$')"
  [ "$V6_LINKS" -eq 4 ] && [ "$V6_STOPS" -eq 1 ] &&
  [ "$V6_LINKS2" -eq 4 ] && [ "$V6_STOPS2" -eq 1 ] && [ "$V6_RC" = "0" ] &&
    ok "V6: the migration is 4 links and 1 stop, identical under --only herdr" ||
    bad "V6: full=($V6_LINKS links,$V6_STOPS stops) --only herdr=($V6_LINKS2 links,$V6_STOPS2 stops, rc=$V6_RC)"

  # V3b — the `|| fail` arm, which is UNREACHABLE through the script's own
  # control flow: a successful mv always removes the source. Reached here with
  # a lying mv. This proves the guard is LIVE. It does not prove the situation
  # arises.
  mksandbox lie1 existing
  arm lie1 curl-ok
  arm lie1 lie-mv
  LIE1_RC="$(run_deploy lie1 "$WORK/out/lie1.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh" "${HERDR_FLAGS[@]}")"
  [ "$LIE1_RC" != "0" ] && grep -q 'config/goose is still a real directory' "$WORK/out/lie1.log.err" &&
    ok "V3b: a mv that copies without unlinking makes migrate_into_root fail loudly, naming the directory" || {
    bad "V3b: rc=$LIE1_RC — the run nested a symlink inside a surviving directory and did not say so"
    evidence "$WORK/out/lie1.log.err"
  }

  # V4a — CONSTRAINT: the EXIT trap brings goose back on ANY failure path.
  # Armed at the herdr download (a lying asset), which is the real-world case
  # the trap exists for: a mid-deploy failure leaves the brain OFFLINE.
  mksandbox trapa fresh
  arm trapa curl-ok
  arm trapa download-lies
  TRAPA_RC="$(run_deploy trapa "$WORK/out/trapa.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh" "${HERDR_FLAGS[@]}")"
  TRAPA_LAST="$(grep -E 'systemctl ' "$WORK/out/trapa.log" | tail -n1 || true)"
  [ "$TRAPA_RC" != "0" ] && [ "$TRAPA_LAST" = "sudo systemctl start goose-serve.service" ] &&
    ok "V4a: a failed herdr download still leaves goose-serve started by the EXIT trap" || {
    bad "V4a: rc=$TRAPA_RC, last systemctl line was '$TRAPA_LAST' — the brain would be left offline"
    evidence "$WORK/out/trapa.log"
  }
fi

# ============================================================================
# V5 — SELECTION (the bare run provisions nothing)
# ============================================================================
if leg select; then
  # V5 (the gate) — the whole point of the ticket: herdr is OFF by default, so
  # a bare run must provision no plane at all, and still run the brain core.
  mksandbox nocode fresh --deny
  arm nocode curl-ok
  V5_RC="$(run_deploy nocode "$WORK/out/nocode.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh")"
  V5_DENY="$(wc -l <"$WORK/aux-nocode/deny.log" | tr -d ' ')"
  V5_RESTART="$(count_in "$WORK/out/nocode.log" '^sudo systemctl restart goose-serve\.service$')"
  V5_CURL="$(count_in "$WORK/out/nocode.log" '^curl ')"
  if [ "$V5_RC" = "0" ] && [ "$V5_DENY" -eq 0 ] &&
     [ ! -e "$WORK/sb-nocode/data/herdr" ] &&
     [ ! -e "$WORK/sb-nocode/etc/systemd/system/herdr.service" ] &&
     [ ! -s "$WORK/sb-nocode/etc/subuid" ] &&
     [ "$V5_RESTART" -eq 1 ] && [ "$V5_CURL" -ge 1 ]; then
    ok "V5: a bare run installs no plane (no useradd, no npm, no unit, no /data/herdr) — and still restarts goose-serve and probes /status"
  else
    bad "V5: rc=$V5_RC deny-lines=$V5_DENY restarts=$V5_RESTART curls=$V5_CURL, herdr dir/unit present?"
    evidence "$WORK/aux-nocode/deny.log"
    evidence "$WORK/out/nocode.log.err"
  fi

  # V5b — the removed unit ids are no longer selectable at all, and --only
  # works. The three pre-removal ids (google-workspace, telegram-gateway,
  # automations) and the container plane's code-agents are gone from UNIT_IDS,
  # so naming one must exit 2 with "unknown unit" — the same refusal a typo
  # earns, because a flag naming a unit that no longer exists should not
  # silently deploy anyway.
  mksandbox gone fresh
  arm gone curl-ok
  V5B_RC="$(run_deploy gone "$WORK/out/gone.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh" --without telegram-gateway)"
  [ "$V5B_RC" = "2" ] &&
  grep -q "unknown unit 'telegram-gateway'" "$WORK/out/gone.log.err" &&
    ok "V5b: a removed unit id is refused with exit 2 and named, not silently ignored" ||
    bad "V5b: --without telegram-gateway exited $V5B_RC (want 2, unknown unit)"

  # A FRESH TAG, not `onlyunit`: the constraints leg already built that one,
  # and mksandbox's mkdir -p would leave the earlier run's users state behind —
  # `id -u herdr` would answer from it and the useradd count below would read
  # zero for a reason that has nothing to do with the deploy.
  mksandbox onlyherdr fresh
  arm onlyherdr curl-ok
  V5B2_RC="$(run_deploy onlyherdr "$WORK/out/onlyherdr.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh" --only herdr)"
  V5B2_USER="$(count_in "$WORK/out/onlyherdr.log" '^sudo useradd ')"
  [ "$V5B2_RC" = "0" ] &&
  [ -e "$WORK/sb-onlyunit/etc/systemd/system/herdr.service" ] &&
  [ "$V5B2_USER" -eq 1 ] &&
    ok "V5b: --only herdr installs the plane (unit file + one useradd) and still runs the brain core" ||
    bad "V5b: --only herdr rc=$V5B2_RC useradd=$V5B2_USER"

  # V5c — --dry-run writes NOTHING. Not "the gates return early": the brain
  # core is ungateable, so a dry-run that only silenced the unit body would
  # still stop goose, migrate three directories and install the systemd unit.
  # Both shapes are asserted: the bare run (herdr skipped) and the wizard
  # shape (--with herdr + --coding-agents, herdr named as run).
  mksandbox dry existing
  arm dry curl-ok
  inventory "$WORK/sb-dry" home >"$WORK/out/dry-before"
  inventory "$WORK/sb-dry" data >>"$WORK/out/dry-before"
  inventory "$WORK/sb-dry" etc  >>"$WORK/out/dry-before"
  V5C_RC="$(run_deploy dry "$WORK/out/dry.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh" --dry-run)"
  V5C_CALLS="$(wc -l <"$WORK/out/dry.log" | tr -d ' ')"
  grep -q 'skip: herdr' "$WORK/out/dry.log.out" && V5C_NAMED=1 || V5C_NAMED=0
  V5C_WIZ_RC="$(run_deploy dry "$WORK/out/dry2.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh" --dry-run "${HERDR_FLAGS[@]}")"
  V5C_CALLS2="$(wc -l <"$WORK/out/dry2.log" | tr -d ' ')"
  grep -q 'run:  herdr' "$WORK/out/dry2.log.out" && V5C_WIZ=1 || V5C_WIZ=0
  grep -q 'coding agents: opencode' "$WORK/out/dry2.log.out" && V5C_AGENTS=1 || V5C_AGENTS=0
  inventory "$WORK/sb-dry" home >"$WORK/out/dry-after"
  inventory "$WORK/sb-dry" data >>"$WORK/out/dry-after"
  inventory "$WORK/sb-dry" etc  >>"$WORK/out/dry-after"
  if [ "$V5C_RC" = "0" ] && [ "$V5C_CALLS" -eq 0 ] && [ "$V5C_NAMED" -eq 1 ] &&
     [ "$V5C_WIZ_RC" = "0" ] && [ "$V5C_WIZ" -eq 1 ] && [ "$V5C_CALLS2" -eq 0 ] &&
     [ "$V5C_AGENTS" -eq 1 ] &&
     diff -u "$WORK/out/dry-before" "$WORK/out/dry-after" >"$WORK/out/dry.diff" 2>&1; then
    ok "V5c: --dry-run invokes nothing, writes nothing, names herdr (skip and run) and prints the agent list"
  else
    bad "V5c: rc=$V5C_RC, $V5C_CALLS host calls, named=$V5C_NAMED run=$V5C_WIZ agents=$V5C_AGENTS, tree changed?"
    evidence "$WORK/out/dry.diff"
  fi

  # V11 — check-herdr.sh must SKIP (exit 2), not FAIL, on a brain that
  # deliberately has no herdr plane. Without this, a deselected plane ships a
  # permanently-red check: cli.sh's cmd_verify maps exit 2 to SKIP and
  # everything else to FAIL.
  V11_RC=0
  PAI_MODE=local \
  PAI_DATA_ROOT="$WORK/sb-nocode/data" \
  PAI_SYSTEMD_DIR="$WORK/sb-nocode/etc/systemd/system" \
    "$REPO_ROOT/scripts/verify/check-herdr.sh" >"$WORK/out/v11.log" 2>&1 || V11_RC=$?
  [ "$V11_RC" -eq 2 ] &&
    ok "V11: check-herdr.sh exits 2 (SKIP) when the plane was deselected" || {
    bad "V11: check-herdr.sh exited $V11_RC, want 2 — 'pai verify' would report a FAIL for a unit nobody installed"
    evidence "$WORK/out/v11.log"
  }
fi

# ============================================================================
# V12 — THE --coding-agents GATE
# ============================================================================
if leg gating; then
  # V12a — agents require herdr. The wizard passes both flags together; a
  # missing half must be a refused argv (exit 2), not a half-plane.
  mksandbox gate1 fresh
  arm gate1 curl-ok
  V12A_RC="$(run_deploy gate1 "$WORK/out/gate1.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh" --coding-agents opencode)"
  [ "$V12A_RC" = "2" ] &&
  grep -q -- "--coding-agents requires herdr" "$WORK/out/gate1.log.err" &&
    ok "V12a: --coding-agents without a herdr selection is refused with exit 2" ||
    bad "V12a: rc=$V12A_RC (want 2 with a usage error)"

  # V12b — the catalog is enforced: Gemini CLI was cut by the agent-picker
  # decision and is refused like any other unknown id.
  mksandbox gate2 fresh
  arm gate2 curl-ok
  V12B_RC="$(run_deploy gate2 "$WORK/out/gate2.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh" --with herdr --coding-agents gemini)"
  [ "$V12B_RC" = "2" ] &&
  grep -q "unknown coding agent 'gemini'" "$WORK/out/gate2.log.err" &&
    ok "V12b: a coding agent outside the catalog is refused with exit 2" ||
    bad "V12b: rc=$V12B_RC (want 2, unknown coding agent)"

  # V12c — the flag BARE means server only: no agent CLIs, no agent config
  # dirs, no agent credentials, no npm, and an agents.list that records zero
  # agents. The env file exists (EnvironmentFile must resolve) but carries no
  # rows.
  mksandbox gate3 fresh
  arm gate3 curl-ok
  V12C_RC="$(run_deploy gate3 "$WORK/out/gate3.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh" --with herdr --coding-agents)"
  HF3="$WORK/sb-gate3/data/herdr"
  V12C_AGENTS_FILE="$HF3/config/agents.list"
  V12C_ROWS="$(grep -cE '^[A-Z][A-Z0-9_]+=' "$HF3/secrets.env" 2>/dev/null || true)"
  V12C_LIST="$(grep -cvE '^#|^[[:space:]]*$' "$V12C_AGENTS_FILE" 2>/dev/null || true)"
  V12C_OC_DIR="$([ -e "$HF3/config/opencode" ] && echo yes || echo no)"
  V12C_SERVICE="$(count_in "$WORK/out/gate3.log" '^sudo systemctl restart herdr\.service$')"
  if [ "$V12C_RC" = "0" ] && [ "$V12C_ROWS" -eq 0 ] && [ "$V12C_LIST" -eq 0 ] &&
     [ "$V12C_OC_DIR" = "no" ] && [ -f "$V12C_AGENTS_FILE" ] &&
     [ "$V12C_SERVICE" -eq 1 ]; then
    ok "V12c: bare --coding-agents installs server only — empty agents.list, empty env, no agent dir, service restarted"
  else
    bad "V12c: rc=$V12C_RC rows=$V12C_ROWS list=$V12C_LIST opencode-dir=$V12C_OC_DIR restarts=$V12C_SERVICE"
    evidence "$WORK/out/gate3.log.err"
  fi

  # V13 — the full plane shape, one agent picked. What lands, where, in what
  # order: user, pinned binary (digest-checked), six-key config, agents.list,
  # the opencode asset extracted to bin/, the exact env rows, the env-parity
  # shell init, and the systemd trio. Ownership is NOT asserted here (install
  # -o/-g are recorded and dropped in the fake; check-herdr.sh owns that).
  mksandbox shape fresh
  arm shape curl-ok
  V13_RC="$(run_deploy shape "$WORK/out/shape.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh" "${HERDR_FLAGS[@]}")"
  HF4="$WORK/sb-shape/data/herdr"
  V13_BINARY_OK="$([ -x "$HF4/bin/herdr" ] && echo yes || echo no)"
  V13_OC_OK="$([ -x "$HF4/bin/opencode" ] && echo yes || echo no)"
  V13_LIST="$(grep -vE '^#|^[[:space:]]*$' "$HF4/config/agents.list" 2>/dev/null | tr -d ' \n')"
  V13_ENV="$(grep -cE '^(TOGETHER_API_KEY|GITHUB_CODE_AGENT_PAT)=' "$HF4/secrets.env" 2>/dev/null || true)"
  V13_ENV_TOTAL="$(grep -cE '^[A-Z][A-Z0-9_]+=' "$HF4/secrets.env" 2>/dev/null || true)"
  V13_ENV_LEAK="$(grep -cE '^GOOSE_SERVER__SECRET_KEY=' "$HF4/secrets.env" 2>/dev/null || true)"
  V13_CFG_KEYS="$(grep -cE '^(onboarding = false|version_check = false|manifest_check = false|pane_history = false|resume_agents_on_restore = true)' "$HF4/config/herdr/config.toml" 2>/dev/null || true)"
  # The template carries the REAL brain path literally; the fixture config is
  # the template copied verbatim, so the worktrees line is asserted as shipped.
  V13_CFG_WT="$(grep -cF 'directory = "/data/herdr/worktrees"' "$HF4/config/herdr/config.toml" 2>/dev/null || true)"
  V13_BASHRC="$([ -f "$HF4/.bashrc" ] && [ -f "$HF4/.profile" ] && echo yes || echo no)"
  V13_INTEGRATION="$(count_in "$WORK/out/shape.log" '^sudo -u herdr env HOME=.*/bin/herdr integration install opencode$')"
  V13_USER="$(count_in "$WORK/out/shape.log" '^sudo useradd ')"
  V13_ENVINSTALL="$(count_in "$WORK/out/shape.log" '^sudo install -o herdr -g herdr -m 600 .*/data/herdr/secrets\.env$')"
  if [ "$V13_RC" = "0" ] &&
     [ "$V13_BINARY_OK" = "yes" ] && [ "$V13_OC_OK" = "yes" ] &&
     [ "$V13_ENV" -eq 2 ] && [ "$V13_ENV_LEAK" -eq 0 ] &&
     [ "$V13_BASHRC" = "yes" ] &&
     [ "$V13_LIST" = "opencode" ] && [ "$V13_CFG_KEYS" -eq 5 ] && [ "$V13_CFG_WT" -eq 1 ] &&
     [ "$V13_ENV_TOTAL" -eq 2 ] && [ "$V13_USER" -eq 1 ] && [ "$V13_ENVINSTALL" -eq 1 ]; then
    ok "V13: the herdr plane installs in the recorded shape — user, pinned binary, config, agents.list, opencode CLI, exact env rows, env-parity init, service"
  else
    bad "V13: rc=$V13_RC binary=$V13_BINARY_OK opencode=$V13_OC_OK env-rows=$V13_ENV leak=$V13_ENV_LEAK bashrc=$V13_BASHRC integration=$V13_INTEGRATION list=$V13_LIST cfg-keys=$V13_CFG_KEYS"
    evidence "$WORK/out/shape.log.err"
  fi
fi

# ============================================================================
# V7 — IDEMPOTENCE
# ============================================================================
if leg rerun; then
  mksandbox rerun fresh
  arm rerun curl-ok
  V7_RC1="$(run_deploy rerun "$WORK/out/rerun1.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh" "${HERDR_FLAGS[@]}")"
  # A user's edit to the seeded config. install_template_as must never
  # overwrite it, on this run or any later one.
  SENTINEL="pai-rerun-sentinel-$(openssl rand -hex 8)"
  V7_READY=0
  if [ -f "$WORK/sb-rerun/data/herdr/config/herdr/config.toml" ]; then
    printf '# %s\n' "$SENTINEL" >>"$WORK/sb-rerun/data/herdr/config/herdr/config.toml"
    V7_READY=1
  fi
  V7_RC2="$(run_deploy rerun "$WORK/out/rerun2.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh" "${HERDR_FLAGS[@]}")"
  V7_DL="$(count_in "$WORK/out/rerun2.log" '^curl -fsSL -o ')"
  V7_USERADD="$(count_in "$WORK/out/rerun2.log" '^sudo useradd ')"
  V7_SUPERSEDED="$(find "$WORK/sb-rerun" -name '*.superseded.*' | wc -l | tr -d ' ')"
  V7_SENTINEL=0
  grep -qF "$SENTINEL" "$WORK/sb-rerun/data/herdr/config/herdr/config.toml" 2>/dev/null && V7_SENTINEL=1 || true
  if [ "$V7_RC1" = "0" ] && [ "$V7_RC2" = "0" ] && [ "$V7_DL" -eq 0 ] &&
     [ "$V7_USERADD" -eq 0 ] && [ "$V7_SUPERSEDED" -eq 0 ] &&
     [ "$V7_READY" -eq 1 ] && [ "$V7_SENTINEL" -eq 1 ]; then
    ok "V7: the re-run exits 0, re-downloads nothing, re-adds no user, supersedes nothing and keeps the local edit"
  else
    bad "V7: rc1=$V7_RC1 rc2=$V7_RC2 downloads=$V7_DL useradd=$V7_USERADD superseded=$V7_SUPERSEDED sentinel(ready=$V7_READY,kept=$V7_SENTINEL)"
    evidence "$WORK/out/rerun2.log.err"
  fi
fi

# ============================================================================
# V8/V9 — THE /status GATE AND ERR ATTRIBUTION
# ============================================================================
if leg status; then
  # V8 — the deploy BLOCKS on /status. curl is unarmed, so every probe
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

  # V9 — the deploy does NOT continue past a failed unit, and should not: the
  # brain core is a prerequisite for everything after it. What
  # it does instead is ATTRIBUTE. Without `set -E` neither line below prints,
  # because an ERR trap is not inherited by shell functions. The failing unit
  # is herdr, via the lying-download arm; with one selectable unit the
  # attribution line also proves nothing was skipped past.
  mksandbox errattr fresh
  arm errattr curl-ok
  arm errattr download-lies
  V9_RC="$(run_deploy errattr "$WORK/out/errattr.log" "$REPO_ROOT/scripts/vps/deploy-vps.sh" "${HERDR_FLAGS[@]}")"
  if [ "$V9_RC" != "0" ] &&
     grep -q "unit 'herdr' failed" "$WORK/out/errattr.log.err" &&
     grep -q "not reached: (none)" "$WORK/out/errattr.log.err"; then
    ok "V9: a failing unit is named, with nothing silently skipped past it"
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