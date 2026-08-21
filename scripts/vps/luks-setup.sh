#!/usr/bin/env bash
# luks-setup.sh — ONE-TIME, DESTRUCTIVE: LUKS2-format the Hetzner data volume
# and mount it at /data. Everything stateful on the brain (secrets.env, goose
# sessions.db, the life-vault clone) lives on this volume so it is encrypted
# at rest. Run ON the brain, once, right after `terraform apply`:
#
#   sudo scripts/vps/luks-setup.sh --device "$(terraform output -raw data_volume_linux_device)"
#
# Deliberately manual afterwards: crypttab/fstab entries are `noauto`, no key
# is ever stored on the machine, so every reboot needs scripts/vps/luks-unlock.sh.
set -euo pipefail

MAPPER_NAME="braindata"
MOUNT_POINT="/data"
DATA_OWNER="agent"

usage() {
  cat <<'EOF'
Usage: sudo luks-setup.sh --device <path>

One-time LUKS2 setup of the brain's data volume. DESTROYS everything on the
device. <path> comes from Terraform:

  cd infra/terraform && terraform output -raw data_volume_linux_device
  # e.g. /dev/disk/by-id/scsi-0HC_Volume_12345678

Before running: generate a strong passphrase INTO YOUR PASSWORD MANAGER.
It will exist nowhere else — lose it and a rebooted brain's data is noise.

After a reboot the volume stays locked (by design); unlock with:
  sudo scripts/vps/luks-unlock.sh
EOF
}

DEVICE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ $(id -u) -ne 0 ]]; then
  echo "ERROR: must run as root (sudo)." >&2
  exit 1
fi

if [[ -z "$DEVICE" ]]; then
  echo "ERROR: --device <path> is required (this script refuses to guess a" >&2
  echo "device to destroy). Candidates attached to this server:" >&2
  ls -1 /dev/disk/by-id/scsi-0HC_Volume_* 2>/dev/null >&2 || echo "  (no Hetzner volumes found under /dev/disk/by-id/)" >&2
  echo >&2
  usage >&2
  exit 1
fi

if [[ ! -b "$DEVICE" ]]; then
  echo "ERROR: $DEVICE is not a block device." >&2
  exit 1
fi

command -v cryptsetup >/dev/null || { echo "ERROR: cryptsetup not installed (cloud-init should have installed it)." >&2; exit 1; }

# Refuse to touch anything that is mounted (that would include the root disk).
if lsblk -no MOUNTPOINT "$DEVICE" | grep -q .; then
  echo "ERROR: $DEVICE (or a partition on it) is mounted — refusing to format:" >&2
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$DEVICE" >&2
  exit 1
fi

if [[ -e "/dev/mapper/$MAPPER_NAME" ]]; then
  echo "ERROR: /dev/mapper/$MAPPER_NAME already exists — the volume looks set up" >&2
  echo "and open. This script is one-time; for post-reboot unlocking use" >&2
  echo "scripts/vps/luks-unlock.sh." >&2
  exit 1
fi

echo "About to LUKS2-format the following device. THIS DESTROYS ALL DATA ON IT:"
echo
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$DEVICE"
echo
if cryptsetup isLuks "$DEVICE" 2>/dev/null; then
  echo "WARNING: $DEVICE already contains a LUKS header. If the brain is already"
  echo "set up you almost certainly want scripts/vps/luks-unlock.sh instead —"
  echo "continuing here will destroy the existing encrypted data."
  echo
fi
echo "Have the new passphrase saved in your password manager FIRST."
read -r -p "Type FORMAT (all caps) to proceed, anything else aborts: " CONFIRM
if [[ "$CONFIRM" != "FORMAT" ]]; then
  echo "Aborted — nothing was changed."
  exit 1
fi

echo
echo "==> LUKS2-formatting $DEVICE (cryptsetup will prompt for the passphrase)"
cryptsetup luksFormat --type luks2 --batch-mode "$DEVICE"

echo "==> Opening as /dev/mapper/$MAPPER_NAME (re-enter the passphrase)"
cryptsetup open "$DEVICE" "$MAPPER_NAME"

echo "==> Creating ext4 filesystem"
mkfs.ext4 -q -L "$MAPPER_NAME" "/dev/mapper/$MAPPER_NAME"

echo "==> Mounting at $MOUNT_POINT"
mkdir -p "$MOUNT_POINT"
mount "/dev/mapper/$MAPPER_NAME" "$MOUNT_POINT"
chown "$DATA_OWNER:$DATA_OWNER" "$MOUNT_POINT"

# crypttab: reference the LUKS container by UUID (stable across device
# renames); `noauto` = boot never tries to unlock it (no stored key, and a
# headless box must not hang on a passphrase prompt).
LUKS_UUID="$(cryptsetup luksUUID "$DEVICE")"
CRYPTTAB_LINE="$MAPPER_NAME UUID=$LUKS_UUID none luks,noauto"
if grep -qE "^\s*$MAPPER_NAME\s" /etc/crypttab 2>/dev/null; then
  echo "==> /etc/crypttab already has a $MAPPER_NAME entry — leaving it alone:"
  grep -E "^\s*$MAPPER_NAME\s" /etc/crypttab
else
  echo "==> Adding /etc/crypttab entry"
  echo "$CRYPTTAB_LINE" >> /etc/crypttab
fi

FSTAB_LINE="/dev/mapper/$MAPPER_NAME $MOUNT_POINT ext4 defaults,noauto,nofail 0 2"
if grep -qE "^\s*/dev/mapper/$MAPPER_NAME\s" /etc/fstab 2>/dev/null; then
  echo "==> /etc/fstab already has a $MAPPER_NAME entry — leaving it alone:"
  grep -E "^\s*/dev/mapper/$MAPPER_NAME\s" /etc/fstab
else
  echo "==> Adding /etc/fstab entry"
  echo "$FSTAB_LINE" >> /etc/fstab
fi

cat <<EOF

DONE. Encrypted volume mounted at $MOUNT_POINT (owner: $DATA_OWNER).

REMEMBER — the reboot rule:
  After ANY reboot, $MOUNT_POINT is absent and the stack stays down until you run
      sudo /home/agent/personal-ai-setup/scripts/vps/luks-unlock.sh
  which prompts for the passphrase (password manager), mounts $MOUNT_POINT,
  and starts goose-serve. That manual step is the accepted cost of storing
  no key server-side (docs/security.md).

Next steps (docs/setup/50-vps-brain.md):
  1. Create $MOUNT_POINT/secrets.env from config/env/secrets.env.example (chmod 600).
  2. Transfer the Google OAuth tokens (docs/setup/30-google-oauth.md).
  3. Run scripts/vps/deploy-vps.sh as the $DATA_OWNER user.
EOF
