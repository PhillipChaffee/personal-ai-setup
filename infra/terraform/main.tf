# Hetzner Cloud infrastructure for the "brain" VPS.
#
# What this creates: one small Ubuntu 24.04 server, an SSH key, a cloud
# firewall with zero inbound rules, and a separate data volume that later
# gets LUKS-encrypted and mounted at /data (see scripts/vps/luks-setup.sh).
#
# Secrets are deliberately NOT stored on disk. `hcloud_token` and
# `tailscale_authkey` are declared in variables.tf with no default and are
# absent from terraform.tfvars, so Terraform PROMPTS for them on every
# plan/apply. That is the design, not an oversight: a key that is never
# written to a file cannot be committed — and this repo has already leaked a
# Tailscale auth key once, through a saved plan file.
#
# terraform.tfvars holds non-secret inputs only. See terraform.tfvars.example.

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

# The version pins the Mac surface and this cloud-init both read, so the two
# cannot drift. See config/pins.yaml for why each side consumes it differently.
locals {
  pins = yamldecode(file("${path.module}/../../config/pins.yaml"))
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
    goose_version        = local.pins.goose.version
  })

  # The brain is a pet, not cattle. `user_data` forces REPLACEMENT on
  # hcloud_server, and the rendered cloud-init embeds the Tailscale auth key —
  # so simply typing a NEW key at the prompt (because the old one expired, or
  # because you rotated it after a leak) changes user_data and would destroy
  # and rebuild the server. Auth keys expire every 90 days, which means the
  # single most routine operation here is also the one that silently eats the
  # machine. /data survives (separate volume, delete_protection = true), but
  # the root disk does not: goose, the systemd units, /etc, and every
  # hand-applied fix since provisioning.
  #
  # THE TRADE, stated plainly: this guard also hides LEGITIMATE cloud-init
  # changes. Edit templates/cloud-init.yaml.tftpl and `terraform plan` will
  # report "No changes" while the running server keeps the old config. That is
  # a real cost, accepted because cloud-init only ever runs on first boot
  # anyway — so a plan that offers to "apply" a template edit was always
  # offering a rebuild, never an update.
  #
  # ESCAPE HATCH — the only supported way to re-run cloud-init, and an
  # explicit, deliberate rebuild of the root disk:
  #
  #   terraform apply -replace=hcloud_server.brain
  #
  # Before running it, confirm /data is detached-safe and you can re-run
  # scripts/vps/deploy-vps.sh, because you will be reinstalling the brain.
  lifecycle {
    ignore_changes = [user_data]
  }
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
