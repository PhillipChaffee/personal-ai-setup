output "server_public_ip" {
  description = "Public IPv4 of the brain — BOOTSTRAP ONLY. The cloud firewall drops all public inbound, so nothing answers here; day-to-day access is via the server's Tailscale name/IP once cloud-init has joined the tailnet."
  value       = hcloud_server.brain.ipv4_address
}

output "server_status" {
  description = "Hetzner-reported server status (should be 'running' after apply)."
  value       = hcloud_server.brain.status
}

output "data_volume_linux_device" {
  description = "Linux device path of the attached data volume (e.g. /dev/disk/by-id/scsi-0HC_Volume_...). Pass this to scripts/vps/luks-setup.sh for the one-time LUKS format."
  value       = hcloud_volume.brain_data.linux_device
}
