#!/usr/bin/env bash
# renew-tls-cert.sh — issue/renew the brain's Let's Encrypt certificate for
# its tailnet name via `tailscale cert`, and restart goose-serve to load it.
#
# Run once during setup (docs/setup/50-vps-brain.md) and weekly thereafter by
# tls-cert-renew.timer. Requires MagicDNS + HTTPS Certificates enabled in the
# Tailscale admin console (https://login.tailscale.com/admin/dns).
#
# Why: goose serve's self-signed cert works for Goose Desktop (which pins the
# fingerprint) but iOS refuses it. A real LE cert on the ts.net name makes
# every client trust the brain natively — and LE certs expire in ~90 days,
# hence the timer. Certs live on the encrypted volume (/data/tls).
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "renew-tls-cert.sh: run as root (sudo)"; exit 1; }
mountpoint -q /data || { echo "renew-tls-cert.sh: /data not mounted (LUKS locked?)"; exit 1; }

DOMAIN="$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')"
[ -n "$DOMAIN" ] && [ "$DOMAIN" != "null" ] || { echo "renew-tls-cert.sh: no tailnet DNS name (MagicDNS off?)"; exit 1; }

mkdir -p /data/tls
tailscale cert --cert-file /data/tls/cert.pem --key-file /data/tls/key.pem "$DOMAIN"
chown agent:agent /data/tls/cert.pem /data/tls/key.pem
chmod 644 /data/tls/cert.pem
chmod 600 /data/tls/key.pem

systemctl restart goose-serve
echo "renew-tls-cert.sh: certificate for $DOMAIN installed; goose-serve restarted"
