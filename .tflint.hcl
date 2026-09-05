# tflint. `preset = "all"` rather than "recommended": the infra here is 134
# lines and clean under the strict preset, so there is no reason to run the
# lenient one.
#
# There is no tflint ruleset for Hetzner, so `terraform validate` is doing the
# provider-specific half of the work -- it is the only thing that can catch a
# typo'd hcloud_server attribute. Both run in infra-lint.yml.
config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "all"
}
