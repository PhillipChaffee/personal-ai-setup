# Making this repo public, safely

This repo is designed to be public **by construction**: it holds only code, templates,
and docs with placeholders. Every real value — keys, tokens, hostnames, topics — is
injected at runtime from untracked files (`/data/secrets.env`, the macOS Keychain,
`terraform.tfvars`). This document is the contract that keeps it that way, and the
checklist you run before flipping visibility.

## What may be committed

- Docs, runbooks, this checklist.
- Shell scripts, systemd units, Terraform code (`*.tf`), CI workflows.
- Recipe YAMLs — instructions only; delivery references `$NTFY_TOPIC`, never a value.
- Config **templates**: `config/goose/config.yaml`, custom-provider JSONs (they carry
  `api_key_env` names like `OPENCODE_ZEN_API_KEY`, never key values),
  `config/opencode/opencode.json`, `config/env/secrets.env.example` (variable names
  only), `config/goose/goosehints.example`.
- `infra/terraform/terraform.tfvars.example` (placeholders only).
- `vault-template/` — the empty skeleton for the separate private vault repo.
- Placeholders of the form `<YOUR-ZEN-API-KEY>`, `you@example.com`,
  `<your-tailnet>.ts.net`, `<your-brain>`.

## What must never be committed

- **Secret values of any kind**: `OPENCODE_ZEN_API_KEY`, `TOGETHER_API_KEY`,
  `GOOSE_SERVER__SECRET_KEY`, `TAVILY_API_KEY`, Google OAuth client ID/secret, Tailscale
  auth keys, Telegram bot tokens.
- **Secret-bearing files**: `secrets.env`, `secrets.yaml`, `gcp-oauth*.json`, any
  `*token*.json`, OpenCode's `auth.json`, `*.tfstate*`, `*.tfvars`, `.terraform/`,
  SSH/TLS private keys.
- **Identity and location**: your real email address, phone number, tailnet name or
  `*.ts.net` hostnames, Tailscale IPs, the **ntfy topic name** (it is effectively a
  password), Telegram chat IDs.
- **Life data**: anything from the life vault (it is a **separate private repo**, never
  this one — not even its remote URL in committed config), `sessions.db` or session
  exports, Goose memory files, logs containing chat content.

If in doubt: does the line change if another person adopts this repo? If no (it's yours,
not the template's), it doesn't belong here.

## How the guardrails work

Three layers, so a single mistake never reaches a public remote:

1. **`.gitignore`** — all secret-bearing filename patterns above are ignored, so `git add
   -A` can't stage them in the first place.
2. **Pre-commit gitleaks hook** (`.pre-commit-config.yaml`) — scans every commit for
   secret-shaped content (keys, tokens, high-entropy strings) before it enters history.
   One-time setup per clone:

   ```bash
   pre-commit install
   pre-commit run --all-files    # baseline check of the whole tree
   ```

3. **CI scan** (`.github/workflows/secret-scan.yml`) — gitleaks runs on every push and
   PR, catching anything committed from a machine without the hook installed.

Layers 2–3 catch *content*; layer 1 catches *files*. Hostnames and topic names are not
secret-shaped, which is why the go-public checklist below adds a grep audit for them.

## The go-public checklist

Run every step from the repo root. All must pass before flipping visibility. Remember:
history counts — a secret committed and later deleted is still published the moment the
repo goes public.

**1. Full-history secret scan.**

```bash
gitleaks git --redact -v .
# gitleaks <= 8.18 syntax:
#   gitleaks detect --source . --redact -v
```

Must report zero leaks. If it finds a real secret anywhere in history: **rotate that
secret now** (see the rotation table in [security.md](security.md)) — treat it as burned
regardless of whether you also rewrite history (`git filter-repo`) afterwards.

**2. Grep audit for identity leaks** (things gitleaks can't recognize). Each command
should print nothing, or only obvious placeholders:

```bash
# real email addresses (placeholders, systemd unit names, and git SSH URLs excluded)
git grep -nIE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}' \
  | grep -vE 'example\.com|you@|noreply|@users\.|@[a-z-]+\.(service|timer)|git@github'

# tailnet hostnames and Tailscale (CGNAT) IPs
git grep -nIE '[A-Za-z0-9-]+\.ts\.net' | grep -vE '<your-tailnet>|example-tailnet'
git grep -nIE '\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b'

# ntfy topics written as literals instead of $NTFY_TOPIC
git grep -nIE 'ntfy\.sh/[A-Za-z0-9_-]+' | grep -vE '\$NTFY_TOPIC|<your'

# one pass over full history for the same shapes (-i: placeholders vary in case)
git log --all -p | grep -naiE '\.ts\.net|ntfy\.sh/[a-z0-9]|tskey-' | grep -vi '<your' | head
```

**3. Confirm no sensitive file is tracked** (the `.example` files are supposed to
survive this filter):

```bash
git ls-files | grep -E '\.tfstate|\.tfvars$|secrets\.env$|secrets\.yaml$|auth\.json$|gcp-oauth|token.*\.json|sessions\.db' \
  && echo 'STOP: sensitive file tracked' || echo 'OK: nothing sensitive tracked'
```

And that the ignore rules will keep it that way:

```bash
git check-ignore -v infra/terraform/terraform.tfvars \
                    infra/terraform/terraform.tfstate \
                    config/env/secrets.env
```

All three paths must resolve to a `.gitignore` rule.

**4. Confirm the vault is truly separate.** The life vault must be its own **private**
repo — not a directory, submodule, or remote of this one:

```bash
git remote -v                          # only this repo's remote
git submodule status                   # must print nothing
git ls-files | grep -i life-vault      # must print nothing
gh repo view <owner>/life-vault --json visibility   # must say PRIVATE
```

Also eyeball `vault-template/` — skeleton files and placeholder headings only, no real
entries.

**5. Green CI.** The latest run of `secret-scan.yml` on the default branch must be
passing:

```bash
gh run list --workflow secret-scan.yml --limit 1
```

**6. Flip visibility.**

```bash
gh repo edit <owner>/personal-ai-setup --visibility public \
  --accept-visibility-change-consequences
```

**7. Post-flip.** In GitHub → Settings → Code security, enable **secret scanning** and
**push protection** (free on public repos) as a fourth guardrail layer. Then re-run step
1 once more against the now-public repo, because paranoia is cheap and rotation is not.

## Ongoing discipline

- New scripts and docs use placeholders from day one; write `$NTFY_TOPIC`, not the topic.
- Re-run steps 1–3 after any large import of files (e.g. pulling configs off a machine).
- Never `git add` from `/data` or your home config directories; the repo's templates are
  the only config that belongs here.
