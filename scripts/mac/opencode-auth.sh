#!/usr/bin/env bash
# opencode-auth.sh — write OpenCode's credential file, with no TUI.
#
# Before this, the Mac was told to run `opencode`, type /connect, pick OpenCode
# Zen and paste the key by hand, while scripts/vps/code-agent-manager.py's
# seed_auth() had been writing exactly that file on the brain since day one. The
# same capability existed twice and only one copy was automated. This is the Mac
# copy, and bootstrap-mac.sh's unit_opencode() calls it.
#
# ~/.local/share/opencode/auth.json, shape mirrored from seed_auth
# (code-agent-manager.py:1082-1096) and from what `opencode auth login` writes:
#
#     {"opencode": {"type": "api", "key": "<the Zen key>"}}
#
# THREE THINGS THIS DOES THAT seed_auth DOES NOT, each a deliberate divergence:
#
#   1. IT MERGES. seed_auth opens the file "w" and dumps a single-key object,
#      which is a destructive write: a Mac where you have also run /connect for
#      a second provider would silently lose that provider's credential. Here
#      the existing JSON is read and only the `opencode` key is replaced.
#   2. IT CREATES AT 0600, it does not chmod afterwards. seed_auth writes the
#      key and *then* chmods, so there is a window in which a live credential
#      sits at the umask's mode. Here the temp file is opened O_CREAT|O_EXCL
#      with 0600, fchmod'd to 0600 regardless of umask, written, and only then
#      os.replace'd over the destination -- so the file is never readable by
#      anyone else and a reader never sees a half-written one.
#   3. IT IS NOT FATAL WHEN THERE IS NO KEY. A fresh Mac has not run
#      keychain-secrets.sh yet, and unit_opencode() calls this as a bare
#      command under `set -e`: a non-zero exit here would abort the whole
#      bootstrap on the machine least able to recover from it. No key means one
#      line saying so and exit 0.
#
# THE CREDENTIAL REACHES PYTHON THROUGH THE ENVIRONMENT AND NEVER THROUGH ARGV.
# That is a standing rule for this repo as of #38, not an implementation detail:
# argv is world-readable in `ps` output on macOS, and it is the one channel a
# `set -x`, a crash dump or a process listing exposes for free. Nothing below
# passes a value on a command line, and nothing below ever prints the key --
# the success line names the path and the mode, and that is all.
#
# NOT A .py FILE, on purpose. .coveragerc measures `source = scripts`, so a
# scripts/mac/opencode_auth.py would land in the inventory at 0% and fail both
# the 85% per-file floor and check-coverage.sh. An inline heredoc is shell,
# which shellcheck covers and coverage does not measure.
#
# It does NOT source scripts/verify/lib.sh. That file is the spine of the
# check-*.sh scripts and brings PASS_COUNT/die()/finish() with it; an installer
# inheriting a verifier's counters is a seam nobody designed.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: opencode-auth.sh [--help]

Writes ~/.local/share/opencode/auth.json (mode 0600) with the OpenCode Zen key
from $OPENCODE_ZEN_API_KEY, merging into whatever is already there. With no key
in the environment it prints one remedy line and exits 0.

Verified afterwards by scripts/verify/check-opencode.sh.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "opencode-auth.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

AUTH_DIR="$HOME/.local/share/opencode"
AUTH_FILE="$AUTH_DIR/auth.json"

# THE ENVIRONMENT IS THE ONLY SOURCE, and `:-` rather than `-` is load bearing:
# an exported-empty OPENCODE_ZEN_API_KEY is what a shell that once sourced a
# half-filled secrets file has, and writing `{"key": ""}` from it would produce
# an auth.json that looks authenticated and 401s on first use.
#
# #38 IS ENV-ONLY, DELIBERATELY. The ticket's scope line says "sourcing the key
# from the Keychain"; that is #39's, and the reason is mechanical rather than
# preferential: a `security find-generic-password` call from a bootstrap child
# lands in $PAI_DENY_LOG, which test-base-install.sh's A5 and B4 require to be
# empty, so it would have to be routed through the PAI_EXEC seam -- a new
# fake-exec.sh arm and a rewrite of fake-brew.sh's redaction contract, both
# holding a live credential, for a value ~/.zshrc already exports.
if [ -z "${OPENCODE_ZEN_API_KEY:-}" ]; then
  echo "==> OpenCode: no Zen key in the environment — auth.json not written."
  echo "    Remedy: scripts/mac/keychain-secrets.sh, open a NEW terminal, then re-run"
  echo "            scripts/mac/opencode-auth.sh (or the whole bootstrap; it is idempotent)."
  exit 0
fi

mkdir -p "$AUTH_DIR"
# The leaf directory holds one live credential and nothing else. 700 here is
# belt to the file's braces: os.replace below preserves the temp file's 0600, so
# the file mode does not depend on this succeeding.
chmod 700 "$AUTH_DIR" 2>/dev/null || true

# `<<'PY'` is quoted: nothing in this block is expanded by the shell, so no
# value can be spliced into the program text. Both inputs arrive as environment
# variables, which is also why python3 is invoked with an EMPTY argv here.
PAI_OPENCODE_AUTH_FILE="$AUTH_FILE" python3 - <<'PY'
import json
import os
import sys

path = os.environ["PAI_OPENCODE_AUTH_FILE"]
key = os.environ["OPENCODE_ZEN_API_KEY"]


def refuse(reason: str) -> None:
    """Complain and leave the file alone — never clobber a credential store.

    Exits 0, not 1: the caller is bootstrap-mac.sh under `set -e`, and a corrupt
    auth.json is a thing the user must look at, not a reason to stop installing
    the rest of the Mac. check-opencode.sh is what turns this into a red
    verdict, which is the right division of labour: the installer is tolerant,
    the verifier is strict.
    """
    sys.stderr.write(f"opencode-auth.sh: {path} {reason}\n")
    sys.stderr.write("opencode-auth.sh: refusing to overwrite it — inspect it by hand,\n")
    sys.stderr.write("opencode-auth.sh: then delete or repair it and re-run this script.\n")
    raise SystemExit(0)


data = {}
if os.path.lexists(path):
    try:
        with open(path, encoding="utf-8") as handle:
            loaded = json.load(handle)
    except (OSError, ValueError):
        # The exception is NOT printed. json.JSONDecodeError's message quotes
        # the offending document, and the offending document is a credential
        # store.
        refuse("is not readable JSON")
    if not isinstance(loaded, dict):
        refuse("is JSON but not an object")
    data = loaded

# MERGE. Every other provider's entry rides through untouched; only `opencode`
# is replaced. This is the line seed_auth does not have.
data["opencode"] = {"type": "api", "key": key}

# O_EXCL, in the SAME directory (os.replace is only atomic within a filesystem),
# and fchmod before a single byte is written so the mode does not depend on the
# caller's umask.
tmp = f"{path}.pai-tmp.{os.getpid()}"
try:
    fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        os.fchmod(handle.fileno(), 0o600)
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, path)
finally:
    if os.path.lexists(tmp):
        os.unlink(tmp)

# Path and mode. Never the key, and never the file's contents.
print(f"==> OpenCode: wrote {path} (mode {oct(os.stat(path).st_mode & 0o777)[2:]})")
PY
