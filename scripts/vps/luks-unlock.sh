#!/usr/bin/env bash
# luks-unlock.sh — post-reboot recovery for the brain: unlock the LUKS data
# volume (passphrase prompt), mount /data, start goose-serve. Counterpart of
# the one-time scripts/vps/luks-setup.sh; safe to re-run (idempotent).
#
#   sudo /home/agent/personal-ai-setup/scripts/vps/luks-unlock.sh
set -euo pipefail

MAPPER_NAME="braindata"
MOUNT_POINT="/data"
SERVICE="goose-serve.service"

usage() {
  cat <<'EOF'
Usage: sudo luks-unlock.sh

Run after every reboot of the brain: prompts for the LUKS passphrase (it is
only in your password manager), mounts /data, and starts goose-serve.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
esac

if [[ $(id -u) -ne 0 ]]; then
  echo "ERROR: must run as root (sudo)." >&2
  exit 1
fi

# 1) Unlock, unless already unlocked.
if [[ -e "/dev/mapper/$MAPPER_NAME" ]]; then
  echo "==> /dev/mapper/$MAPPER_NAME already open — skipping unlock."
else
  # The device to open comes from the crypttab entry luks-setup.sh wrote
  # (usually "UUID=<uuid>", which we resolve via /dev/disk/by-uuid/).
  SRC="$(awk -v name="$MAPPER_NAME" '$1 !~ /^#/ && $1 == name {print $2; exit}' /etc/crypttab 2>/dev/null || true)"
  if [[ -z "$SRC" ]]; then
    echo "ERROR: no $MAPPER_NAME entry in /etc/crypttab — has scripts/vps/luks-setup.sh been run?" >&2
    exit 1
  fi
  if [[ "$SRC" == UUID=* ]]; then
    SRC="/dev/disk/by-uuid/${SRC#UUID=}"
  fi
  if [[ ! -b "$SRC" ]]; then
    echo "ERROR: crypttab device $SRC not found — is the Hetzner volume attached?" >&2
    exit 1
  fi
  echo "==> Unlocking $SRC as $MAPPER_NAME (enter the LUKS passphrase from your password manager)"
  cryptsetup open "$SRC" "$MAPPER_NAME"
fi

# 2) Mount, unless already mounted (fstab has the /data entry, noauto).
if mountpoint -q "$MOUNT_POINT"; then
  echo "==> $MOUNT_POINT already mounted — skipping mount."
else
  echo "==> Mounting $MOUNT_POINT"
  mount "$MOUNT_POINT"
fi

# 3) Start the stack. goose-serve has RequiresMountsFor=/data, so until this
#    moment it was (correctly) refusing to run.
echo "==> Starting $SERVICE"
systemctl start "$SERVICE"
sleep 3

echo "==> $SERVICE is $(systemctl is-active "$SERVICE" || true); recent log:"
journalctl -u "$SERVICE" -n 8 --no-pager || true

cat <<'EOF'

Brain unlocked and started. Now verify from the repo:
  /home/agent/personal-ai-setup/scripts/verify/check-brain.sh
EOF
