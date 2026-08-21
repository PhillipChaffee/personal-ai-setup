# Hetzner Cloud infrastructure for the "brain" VPS.
#
# What this creates: one small Ubuntu 24.04 server, an SSH key, a cloud
# firewall with zero inbound rules, and a separate data volume that later
# gets LUKS-encrypted and mounted at /data (see scripts/vps/luks-setup.sh).
#
# Secrets (API token, Tailscale auth key) come from terraform.tfvars, which
# is gitignored. See terraform.tfvars.example.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    hcloud = {
      source = "hetznercloud/hcloud"
      # Pins the provider to the 1.x line (>= 1.45.0, < 2.0.0). Check
      # https://registry.terraform.io/providers/hetznercloud/hcloud for the
      # latest 1.x release before first `terraform init`.
      version = "~> 1.45"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

resource "hcloud_ssh_key" "brain" {
  name       = "ai-brain"
  public_key = var.ssh_public_key
}

# Zero public inbound — a Hetzner Cloud Firewall with no inbound rules drops
# ALL incoming traffic on the public interface, including SSH. All access is
# over Tailscale (outbound-initiated WireGuard, so it works despite this).
# If Tailscale ever breaks, the Hetzner web console (VNC) is the break-glass.
# Outbound traffic is allowed by default when no outbound rules are defined,
# which the server needs for apt, Tailscale, and provider/MCP HTTPS egress.
resource "hcloud_firewall" "brain" {
  name = "ai-brain-deny-all-inbound"
  # Intentionally no `rule` blocks.
}

resource "hcloud_server" "brain" {
  name         = "ai-brain"
  server_type  = var.server_type
  image        = "ubuntu-24.04"
  location     = var.location
  firewall_ids = [hcloud_firewall.brain.id]
  ssh_keys     = [hcloud_ssh_key.brain.id]

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    tailscale_authkey    = var.tailscale_authkey
    timezone             = var.timezone
    agent_ssh_public_key = var.ssh_public_key
  })
}

# The stateful data volume (/data). Deliberately NOT formatted here: leaving
# `format` unset hands Terraform a raw block device, and scripts/vps/luks-setup.sh
# applies LUKS2 + ext4 to it manually, exactly once. If Terraform formatted it,
# there would be no way to layer LUKS underneath without wiping the data later.
resource "hcloud_volume" "brain_data" {
  name     = "ai-brain-data"
  size     = var.data_volume_size
  location = var.location

  # Guard against `terraform destroy` silently taking the encrypted data
  # (sessions.db, vault clone, secrets) with it. Flip to false deliberately
  # when you really mean to delete the volume.
  delete_protection = true
}

resource "hcloud_volume_attachment" "brain_data" {
  volume_id = hcloud_volume.brain_data.id
  server_id = hcloud_server.brain.id
  # No automount: the device is LUKS-encrypted, so mounting is done by
  # luks-setup.sh / luks-unlock.sh after unlocking, never automatically.
  automount = false
}
