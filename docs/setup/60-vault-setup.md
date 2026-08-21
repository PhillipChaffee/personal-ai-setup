# Phase 4 — The life vault (sensitive tier)

The vault is where your actual life data lives: medical records, insurance
and billing paperwork, appointment notes, the budget. It is a **separate,
private git repository** — this public repo only ships its empty skeleton
(`vault-template/`). Nothing real ever touches `personal-ai-setup`; the two
repos must never blur.

Everything the agent does with the vault runs under the Tier 3 rules in
[`docs/privacy.md`](../privacy.md): Together (ZDR default, HIPAA/BAA posture)
or Zen paid open models only — enforced by pinned models in the recipes, and
by you in interactive sessions.

## 1. Create the private repo

1. On your git host, create a **private** repository named e.g. `life-vault`.
   Double-check the visibility toggle — this is the one repo where "public by
   accident" is a disaster, not an inconvenience.
2. Seed it from the template in this repo:

   ```bash
   git clone git@github.com:<you>/life-vault.git ~/life-vault
   cp -R /path/to/personal-ai-setup/vault-template/. ~/life-vault/
   cd ~/life-vault
   git add -A && git commit -m "Seed from vault-template" && git push
   ```

The direction of flow is one-way, forever: template → vault. Never copy
anything back from the vault into `personal-ai-setup` — not even "just one
example file". The public repo's gitleaks guardrails do not and cannot check
the vault's content; separation is the guardrail.

One more boundary: the vault holds life *data*, never credentials. API keys
and tokens stay in the Keychain / `/data/secrets.env`
([`docs/security.md`](../security.md)) even though the vault is private.

## 2. What goes where

The template's layout is the contract the recipes rely on — keep the paths
stable (`health-followups` appends to `health/appointments.md` by path):

| Path | What goes in it |
|---|---|
| `health/records/` | Medical records: visit summaries, lab results, imaging reports, discharge notes — the PDFs plus their markdown conversions (§3) |
| `health/insurance/` | Policies, coverage summaries, EOBs, prior-auth letters |
| `health/billing/` | Medical bills, receipts, payment disputes and their paper trails |
| `health/appointments.md` | Running log of appointments and follow-ups — **the file the weekly `health-followups` automation appends to** |
| `finance/ledger.csv` | Simple transaction ledger (date, amount, category, note) — the starting-point budgeting flow until a budgeting app with an API is picked ([`docs/roadmap.md`](../roadmap.md)) |
| `finance/budget.md` | Budget targets and notes — what `budget-checkin` compares the ledger against |
| `admin/reference.md` | Everything-else reference: policy numbers, provider contact details, important dates. Reference data, not secrets |

Name documents date-first so listings sort chronologically and the agent can
reason about recency: `2026-03-12-dental-visit.md`.

## 3. Ingesting documents (PDF → markdown)

Models read markdown far better than they read PDFs, and text files make the
vault greppable. So every document goes in twice: **the original PDF plus a
markdown conversion alongside it**, same basename.

Either converter works — both run locally on the Mac (nothing sensitive
leaves the machine during ingestion):

```bash
# pdftotext (poppler) — fast, fine for text-first documents
brew install poppler
pdftotext -layout 2026-03-12-dental-visit.pdf 2026-03-12-dental-visit.md

# markitdown — better structure preservation (tables, headings)
uvx markitdown 2026-03-12-dental-visit.pdf > 2026-03-12-dental-visit.md
```

After converting, skim the markdown once — scanned/image-only PDFs can come
out empty (they need OCR first), and garbled tables are worth a manual fix
now rather than a model hallucination later. Then commit both files.

Batch tip for the initial ingestion:

```bash
cd ~/life-vault
find . -name '*.pdf' | while read -r f; do
  [ -f "${f%.pdf}.md" ] || uvx markitdown "$f" > "${f%.pdf}.md"
done
```

## 4. Clone the vault to the brain

The brain needs the vault at `/data/life-vault` (on the LUKS volume — see
§6) with **push** access, because `health-followups` writes to it and pushes
its own commits. Cleanest credential for a headless machine: a per-machine
**deploy key** scoped to just this repo.

```bash
agent@brain$ ssh-keygen -t ed25519 -f ~/.ssh/life-vault-deploy -N "" -C "brain-life-vault"
agent@brain$ cat ~/.ssh/life-vault-deploy.pub
```

Add that public key on the git host as a deploy key for `life-vault` **with
write access** (GitHub: repo → Settings → Deploy keys → check "Allow write
access"). Then:

```bash
agent@brain$ printf 'Host github.com-life-vault\n  HostName github.com\n  IdentityFile ~/.ssh/life-vault-deploy\n' >> ~/.ssh/config
agent@brain$ git clone git@github.com-life-vault:<you>/life-vault.git /data/life-vault
```

`health-followups` is the **only** recipe that syncs the vault: its
instructions begin with `git -C /data/life-vault pull --ff-only`, and after
updating `health/appointments.md` it commits and pushes that change, so the
remote keeps mirroring the brain's weekly appends. If the push fails you'll
see it in that run's session history (and, on fallback-timer or manual
`run-recipe.sh` runs, in the watchdog's failure alert) — not by discovering
a stale backup months later. `vault-qa` and `budget-checkin` stay fully
offline: no git, no network — they read whatever is on disk.

## 5. Optional: a Mac clone for editing

Ingestion and hand-editing are nicer on the Mac. Clone with your normal git
identity:

```bash
git clone git@github.com:<you>/life-vault.git ~/life-vault
```

Ordinary git discipline applies since two machines now write: pull before
editing, push after, and if the brain's weekly append collides with your
edit, resolve it like any merge. On the brain, only `health-followups` pulls
automatically (`git -C /data/life-vault pull --ff-only` at the start of each
weekly run). Before an interactive `vault-qa` session or a `budget-checkin`
run, pick up pushed edits manually: `git -C /data/life-vault pull`.

## 6. Backup and at-rest posture

- **The private git remote *is* the backup.** Full history, off-machine,
  restorable anywhere with one clone. No separate backup system to maintain —
  the only discipline is that everything gets committed and pushed:
  `health-followups` pushes its own weekly append (§4); anything you change
  by hand, on the Mac or the brain, needs a manual commit and push (§5).
- **On the brain, the vault sits on `/data`** — LUKS-encrypted at rest, so
  Hetzner snapshots/disk disposal never expose it
  ([`docs/security.md`](../security.md#disk-the-luks-design)).
- **On the Mac**, FileVault covers the clone at rest (assumed baseline in
  [`docs/security.md`](../security.md)).
- **Honest note on the remote:** the git host stores the vault in plaintext
  on its side — a private repo at a reputable host is an access-controlled
  copy, not an end-to-end-encrypted one. That's an accepted trade for a
  zero-maintenance backup, same shape as the provider stances in
  [`docs/privacy.md`](../privacy.md). If it ever stops being acceptable,
  move the remote to a self-hosted git service on the brain itself or an
  encrypted-remote scheme — the vault's plain-files design makes that a
  one-hour migration.

## 7. Standing privacy rules (read before first use)

The vault is Tier 3 — the full policy is
[`docs/privacy.md`](../privacy.md), compiled into the
[routing table](../model-routing.md). Operationally:

1. **Models allowed to read vault content:** Together (`together` provider —
   the home tier) and, as fallback only, Zen **paid open** models via
   `zen-openai`. Never `claude-sonnet-5`/`claude-haiku-4-5` or anything else
   on `zen-anthropic` (30-day retention), never any free model (they train on
   you).
2. **The recipes already comply** — `vault-qa` (on-demand Q&A, DeepSeek V4
   Flash for 1M-token context over big records), `health-followups`
   (Qwen3.5-397B), and `budget-checkin` (gpt-oss-120b) all pin `together` in
   their settings. Don't repoint them.
3. **Interactive sessions are on you.** The brain's daily-driver default is
   `zen-anthropic`/`claude-sonnet-5` — before opening anything under
   `/data/life-vault` in a session, switch the session to `together` (or
   start via the `vault-qa` recipe, which does it for you). The standing
   rules in `~/.config/goose/.goosehints` (from
   `config/goose/goosehints.example`) tell the agent to refuse/flag vault
   reads on a disallowed model, but hints are a seatbelt, not a wall.
4. **Pushes about vault work carry counts and neutral titles only** — never
   a condition, medication, provider name, or dollar amount. Enforced at the
   `notify.sh` choke point; don't route around it.

## 8. Verify — the Phase 4 checklist

1. **vault-qa from the phone, on the right provider** — from the Goose iOS
   app (or Desktop against the brain), run the `vault-qa` recipe with a
   question about an ingested document. Confirm the answer is grounded in the
   file *and* that the session shows provider `together` /
   `deepseek-ai/DeepSeek-V4-Flash-0731`.
2. **health-followups end to end** — on the brain:
   `goose schedule run-now --schedule-id health-followups`. Confirm:
   `health/appointments.md` gained entries, the commit was pushed to the
   remote (`git -C /data/life-vault log origin/main -1` shows it — this
   push-verification applies to `health-followups` runs, the only recipe
   that pushes), and the ntfy push is exactly
   `Health review ready: N items` — **no PHI**.
3. **Separation is intact** — in the `personal-ai-setup` working tree:
   `git status` shows no vault files, and the gitleaks pre-commit hook /
   `scripts/verify/check-security.sh` still pass green.

That's the full stack. Last stop: [`docs/public-repo.md`](../public-repo.md)
to flip this repo public, and [`docs/roadmap.md`](../roadmap.md) for what's
next (vault RAG with Together embeddings, Basic Memory, a real budgeting
API).
