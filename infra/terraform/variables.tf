variable "hcloud_token" {
  description = "Hetzner Cloud API token (Read & Write) for the project that hosts the brain. Create it in the Hetzner Cloud console under Security > API tokens."
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "Your SSH public key (the full 'ssh-ed25519 AAAA... you@example.com' line). Uploaded to Hetzner and installed for the 'agent' user via cloud-init. Keys only — password auth is disabled."
  type        = string
}

variable "tailscale_authkey" {
  description = "Tailscale auth key used by cloud-init to join the server to your tailnet. Create it in the Tailscale admin console (Settings > Keys) as a REUSABLE, PRE-AUTHORIZED, TAGGED key (e.g. tag:server) so the node comes up without manual approval and the key survives a re-provision. Auth keys expire (90 days max) — regenerate before re-applying."
  type        = string
  sensitive   = true
}

variable "server_type" {
  description = "Hetzner server type. Default cx22 (2 vCPU / 4 GB / 40 GB) is enough for goose serve + MCP servers. NOTE: the cx (shared Intel) line is not offered in every location — US locations typically carry cpx/ccx types instead; pick e.g. cpx21 if you choose ash/hil and cx22 is rejected."
  type        = string
  default     = "cx22"
}

variable "location" {
  description = "Hetzner location. Options: fsn1 (Falkenstein, DE), nbg1 (Nuremberg, DE), hel1 (Helsinki, FI), ash (Ashburn, VA, US), hil (Hillsboro, OR, US), sin (Singapore). Default ash keeps latency low from the US East Coast; see the server_type note about type availability per location."
  type        = string
  default     = "ash"
}

variable "timezone" {
  description = "IANA timezone for the server. The goose scheduler crons (morning brief at 07:00, etc.) fire in the server's local time, so set this to YOUR timezone, not UTC."
  type        = string
  default     = "America/New_York"
}

variable "data_volume_size" {
  description = "Size in GB of the /data volume (LUKS-encrypted; holds sessions.db, secrets.env, OAuth tokens, life-vault clone). 10 GB is plenty to start; Hetzner volumes can be grown later without recreation (shrinking is not possible)."
  type        = number
  default     = 10
}
