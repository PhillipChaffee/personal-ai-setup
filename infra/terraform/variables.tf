# No default, and deliberately not in terraform.tfvars: Terraform prompts for
# this on every plan/apply so the token is never written to disk.
variable "hcloud_token" {
  description = "Hetzner Cloud API token (Read & Write) for the project that hosts the brain. Create it in the Hetzner Cloud console under Security > API tokens. Entered at the interactive prompt — do NOT put it in terraform.tfvars."
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "Your SSH public key (the full 'ssh-ed25519 AAAA... you@example.com' line). Uploaded to Hetzner and installed for the 'agent' user via cloud-init. Keys only — password auth is disabled."
  type        = string
}

# Also prompted for, never stored. Note that this key is interpolated into
# user_data, which is replace-forcing on hcloud_server — see the lifecycle
# block in main.tf, which is what stops a routine key rotation from rebuilding
# the machine.
variable "tailscale_authkey" {
  description = "Tailscale auth key used by cloud-init to join the server to your tailnet. Create it in the Tailscale admin console (Settings > Keys) as a REUSABLE, PRE-AUTHORIZED, TAGGED key (e.g. tag:server) so the node comes up without manual approval and the key survives a re-provision. Auth keys expire (90 days max) — regenerate before re-applying. Entered at the interactive prompt — do NOT put it in terraform.tfvars."
  type        = string
  sensitive   = true
}

# Defaults hel1/cpx32 (#165, settled 2026-09-26): Helsinki is the least-Eyes-
# exposure region (Finland is in no 5/9/14-Eyes alliance — Germany is in the
# 14th), EU pricing runs ~2:1 under the US line for this tier, and cpx32 (4
# vCPU AMD / 8 GB RAM / 160 GB NVMe) is the herdr floor — the wizard warns and
# deploy-vps.sh refuses a smaller server when herdr is selected. Both defaults
# are also what the wizard's picker (stage 4) offers on Enter.
variable "server_type" {
  description = "Hetzner server type. Default cpx32 (4 vCPU AMD / 8 GB / 160 GB) fits goose serve, MCP servers and herdr panes. The cheaper cx line (cx23/cx33/cx43) is shared-vCPU and EU-only (NBG1/HEL1); the US locations (ash/hil) carry their own lineup (cpx11/21/31/41) at roughly twice the price; sin carries a reduced CPX set. Availability drifts per location and Hetzner guarantees nothing — re-check hetzner.com and let 'terraform plan' be the validator: it fails loudly when a type is not orderable in the picked location."
  type        = string
  default     = "cpx32"
}

variable "location" {
  description = "Hetzner location. Options: fsn1 (Falkenstein, DE), nbg1 (Nuremberg, DE), hel1 (Helsinki, FI), ash (Ashburn, VA, US), hil (Hillsboro, OR, US), sin (Singapore). Default hel1 keeps the server out of every Eyes alliance at the EU price; expect ~90–120 ms RTT from the US East Coast. Availability drifts per location — see the server_type note."
  type        = string
  default     = "hel1"
}

variable "timezone" {
  description = "IANA timezone for the server. The goose scheduler crons (morning brief at 07:00, etc.) fire in the server's local time, so set this to YOUR timezone, not UTC."
  type        = string
  default     = "America/New_York"
}

variable "data_volume_size" {
  description = "Size in GB of the /data volume (LUKS-encrypted; holds sessions.db, secrets.env, and the code-agent volumes). 10 GB is plenty to start; Hetzner volumes can be grown later without recreation (shrinking is not possible)."
  type        = number
  default     = 10
}
