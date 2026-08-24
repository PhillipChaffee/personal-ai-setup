# Connector manifests: the contract

A **connector manifest** is one YAML file describing how to connect the brain to one
external service — which MCP server (if any), which credentials, which *exact* tools the
agent may call, which privacy tier the data falls in, and whether the whole thing can be
finished from a phone.

Manifests are the accruing half of the design in [`docs/connecting.md`](../../docs/connecting.md).
The generic connect workflow ([`config/skills/connect-service/SKILL.md`](../skills/connect-service/SKILL.md))
reads a manifest when one exists and **writes a new one when it doesn't** — so every service
you connect leaves behind the artifact that makes the next connection to it a no-op.

Nothing here is a template you fill in blind: every field below exists because getting it
wrong has a specific, observed consequence.

---

## The one field that must not be typed from memory

```yaml
acp_extension:
  available_tools: [search_gmail_messages, get_gmail_message_content]   # snake_case
```

`available_tools` is **snake_case on the ACP wire**, alone among its camelCase siblings
(`envKeys`, `clientId`, `clientSecretKey`). This is not a style preference — it is load
bearing, and it fails **open**:

- `GooseExtension` carries `#[serde(tag = "type", rename_all = "snake_case")]`, which
  renames *variants*, not fields. Only `env_keys` has an explicit
  `#[serde(rename = "envKeys")]`.
- There is no `deny_unknown_fields`, so a camelCase `availableTools` is **silently
  discarded** — no error, no warning.
- `available_tools: None` becomes `vec![]`, and an empty allowlist means
  **every tool is allowed**.

Verified empirically against goose 1.46.0 (2026-08-23) by adding two extensions over ACP,
one with each spelling, and reading `config.yaml` back:

```yaml
probe_camel:            # sent "availableTools"
  timeout: 300
  cwd: null
  bundled: null
  # ← no available_tools key at all. Silently dropped.

probe_snake:            # sent "available_tools"
  available_tools:
  - only_this_one_tool  # ← persisted
```

So a Gmail connector meant to be read-only, written with the natural camelCase spelling,
would ship with `send_gmail_message` live. **Least privilege here is one word away from
being a no-op.**

Two mitigations are mandatory, both enforced by
[`scripts/verify/check-connectors.sh`](../../scripts/verify/check-connectors.sh):

1. Manifests are validated against goose's own `acp-schema.json` **at the pinned version**,
   rejecting unknown keys client-side (goose won't).
2. Every `extensions/add` is followed by `extensions/list` and an assertion that
   `available_tools` came back **non-empty and equal to what was sent**. A mismatch is a
   hard failure, never a warning.

If upstream ever normalizes the casing, the schema check breaks loudly at the pinned ref —
which is the point.

---

## File layout

One file per service, named `<id>.yaml`, where `<id>` matches the `id:` field.

```
config/connectors/
├── README.md                 # this file
├── google-workspace.yaml
├── todoist.yaml
├── imap-caldav.yaml
├── proton-mail.yaml
└── health-records.yaml
```

## Schema

```yaml
# ---- identity -------------------------------------------------------------
id: google-workspace              # kebab-case, matches the filename
display_name: Google Workspace    # what a human sees in the phone UI
summary: Gmail, Calendar and Tasks through your own GCP OAuth app.

manifest_version: 1
verified_on: 2026-08-23           # when the facts below were last checked
goose_version_verified: 1.46.0    # the goose the wire shapes were verified against

# ---- what it is -----------------------------------------------------------
archetype: self_hosted_mcp_stdio  # see "Archetypes" below
capabilities: [mail, calendar, tasks]

# ---- can this be finished from a phone? -----------------------------------
first_run_auth: brain_browser     # none | phone_secret | brain_browser | laptop_oob
phone_completable: partial        # yes | no | partial
auth_notes: >-
  One-time OAuth consent needs a browser on the same host as the loopback
  callback listener. See docs/setup/30-google-oauth.md §7b.

# ---- privacy --------------------------------------------------------------
privacy:
  tier: 2                         # 1 | 2 | 3, per docs/privacy.md
  notes: >-
    Mail and calendar are Tier 2 but routinely surface Tier 3 content (a bill,
    a lab result), so anything sweeping this connector pins to a zero-retention
    paid model.
  row_added: true                 # a docs/privacy.md row exists — REQUIRED before first use

# ---- the vetting bar (docs/providers.md), as data -------------------------
vetting:
  maintenance:        {verdict: pass, evidence: "v1.25.0, released 2026-08-14"}
  self_hosted_auth:   {verdict: pass, evidence: "stdio; your own GCP OAuth client"}
  relocatable_state:  {verdict: pass, evidence: "tokens in ~/.google_workspace_mcp, symlinked to /data"}
  restrictable_tools: {verdict: pass, evidence: "--permissions + available_tools allowlist"}
  privacy_row:        {verdict: pass, evidence: "docs/privacy.md provider table"}

# ---- credentials, BY NAME ONLY --------------------------------------------
# Never a value. These become GooseExtension.envKeys, resolved per-extension
# from goose's secret store — see "Where secrets live" below.
secrets:
  - key: GOOGLE_OAUTH_CLIENT_ID
    prompt: "OAuth client ID from your GCP project"
    secret: false                 # false => not masked in the UI (IDs aren't secret)
  - key: GOOGLE_OAUTH_CLIENT_SECRET
    prompt: "OAuth client secret"
    secret: true

# ---- the payload sent to _goose/unstable/config/extensions/add ------------
acp_extension:
  type: mcp
  server:
    type: stdio                   # stdio | http   (NOT sse — see below)
    name: workspace-mcp
    command: uvx
    args: [workspace-mcp@1.25.0, --permissions, "gmail:send", "calendar:full", "tasks:manage", --tool-tier, core]
    env: []                       # keep EMPTY — see "Where secrets live"
  envKeys: [GOOGLE_OAUTH_CLIENT_ID, GOOGLE_OAUTH_CLIENT_SECRET]
  description: Google Workspace via your own OAuth app
  timeout: 300
  available_tools:                # snake_case. Non-empty. Never omitted.
    - search_gmail_messages
    - get_gmail_message_content

# ---- proof it works -------------------------------------------------------
smoke_test:
  kind: tools_list                # tools_list | goose_run
  expect_tools_exactly: 2         # MUST equal len(available_tools) — see below
  command: >-
    scripts/verify/check-connectors.sh --smoke google-workspace

runbook: docs/setup/30-google-oauth.md
```

The count is `2` because the example allowlist above holds two tools. That is not a
formatting detail: `expect_tools_exactly` asserts **how many allowlisted tools the agent
can actually call**, so writing the *server's* total there asserts precisely the
un-narrowed state the smoke test exists to catch. The validator cross-checks the number
against `available_tools` for that reason. (The real `google-workspace.yaml` says `10`
and lists ten tools.)

### What `--smoke` proves, and what it doesn't

`--smoke` reads the manifest and talks to the MCP server **directly**. It never starts
goose, so it can say nothing about how goose spelled `available_tools`. Keep the two jobs
separate:

- **The camelCase canary** is (1) the validator, which rejects a camelCase key
  client-side against goose's own `acp-schema.json`, and (2) the `extensions/add` →
  `extensions/list` roundtrip the connect workflow performs, which fails if goose echoes
  back an empty or unequal allowlist. Those are the only two checks that can observe the
  bug at all.
- **`--smoke`'s distinct job** is proving every allowlisted tool **name exists** on the
  server — goose accepts a name matching nothing in total silence, so a typo or an
  upstream rename reads as a working allowlist forever while quietly granting less (or,
  if it were the only entry, nothing) — and quantifying the surface **outside** the
  allowlist: the blast radius that would go live *if* the allowlist were ever inert.

A corollary worth stating: when an allowlist happens to equal the server's entire
published surface, `expect_tools_exactly` carries no narrowing signal — the same number
comes back whether the allowlist bit or was dropped. That is a legitimate configuration
(`google-workspace` is one), but record it in `blockers` and lean on the roundtrip.

---

## Archetypes

The workflow's first branch. Picking the archetype determines everything downstream.

| Archetype | What it means | Phone-completable? |
|---|---|---|
| `first_party_remote_mcp` | The provider hosts an MCP server themselves. Only you and the provider — passes vetting bar 2. | **Yes**, *if* it takes a bearer token. No, if it requires goose's OAuth flow. |
| `self_hosted_mcp_stdio` | A community MCP server you run on the brain. | Credential yes; browser consent no. |
| `standard_protocol_bridge` | IMAP/SMTP/CalDAV, possibly behind a vendor bridge (Proton). | Credential yes; bridge setup no. |
| `local_cli_wrapper` | A good CLI exists but no MCP server: wrap N fixed invocations as N named tools. | Depends on the CLI's own auth. |
| `browser_automation` | No API, no export — drive the web UI. Last resort. | No. |
| `periodic_export` | No live API at all: export files on a schedule into the life vault. | **No** — see the file-drop gap below. |

Two deliberate absences:

- **`sse` is not a transport.** goose's ACP layer rejects it outright — `"SSE is unsupported,
  migrate to streamable_http"` — and a live `initialize` against 1.46.0 reports
  `mcpCapabilities: { http: true, sse: false }`. Use `http`.
- **`webhook_inbound` does not exist.** The brain has zero public inbound ports by design
  ([`docs/security.md`](../../docs/security.md)), so nothing push-based can reach it. If a
  service is push-only, say so in `blockers` and stop.

### The two layers that spell things differently

This trips people up, so it is written down once here:

| | ACP wire (what a manifest emits) | `config.yaml` on disk (what goose writes) |
|---|---|---|
| Remote transport | `type: http`, field `url` | `type: streamable_http`, field `uri` |
| Secret names | `envKeys` | `env_keys` |
| Tool allowlist | `available_tools` | `available_tools` |
| **Headers** | **a LIST of `{name, value}`** | a **mapping** of `Name: value` |
| `env` on a remote server | **does not exist** — the `http` variant's fields are exactly `{type, name, url, headers, _meta}` | — |

A manifest always describes the **ACP wire** shape. goose translates. You do not.

**The header shape is the one that kills, not the one that leaks.** On the wire, `headers`
is `Vec<HttpHeader>` and `HttpHeader` is a struct with `name` and `value` — it has no map
representation at all:

```yaml
# ACP wire — a manifest's acp_extension.server
headers:
  - name: Authorization
    value: "Bearer ${TODOIST_API_KEY}"     # RIGHT

headers:
  Authorization: "Bearer ${TODOIST_API_KEY}"   # WRONG on the wire — see below
```

Note that the wrong form above is *exactly what `config.yaml` on disk looks like*, which is
why copy-paste between the two layers is the usual cause. `headers` is also **required** on
the `http` variant: a remote server with no headers writes `headers: []`, not nothing.

This failure is the **mirror image of the `available_tools` trap**, and the contrast is worth
holding onto — they are the two shapes people get wrong, and they behave in opposite ways:

| | `availableTools` (camelCase) | `headers` as a mapping |
|---|---|---|
| What serde does | ignores the unknown field (no `deny_unknown_fields`) | cannot deserialize `HttpHeader` from a map |
| Result | **succeeds** — extension added | **fails** — `extensions/add` returns an error |
| Blast radius | every tool allowed, silently, forever | nothing added; nothing to clean up |
| How you find out | a `--smoke` blast-radius count, or never | immediately, in the error you just got |
| Fails | **OPEN** | **CLOSED** |

So the mapping-shaped header is the *safe* mistake: it is fatal rather than silent, and a
fatal error is a mistake that fixes itself. Do not paper over it with a retry — read the
error and change the shape.

---

## Where secrets live

Per-connector, via `envKeys` resolved from goose's secret store — **not** the global
`/data/secrets.env`.

The reason is blast radius. goose has no `env_clear` anywhere: every stdio MCP server is
spawned inheriting `goose serve`'s full environment. With a global `EnvironmentFile`
holding N services' credentials, **connector #1 can read all N**. `envKeys` merges only
that extension's declared keys into that extension's process.

Two consequences you must respect:

1. **`server.env` stays empty.** Inline `env` values *do* cross the ACP frame in plaintext,
   and goose promotes them into secret storage. Declaring `envKeys` and leaving `env: []`
   keeps the value out of the frame entirely.
2. **This depends on the config dir living on the encrypted volume.** `is_secret` writes
   `<config_dir>/secrets.yaml` (mode 0600). `goose-serve.service` therefore sets
   `GOOSE_PATH_ROOT=/data/goose`, which relocates config, data **and state** onto the LUKS
   volume. Without it those secrets land on the unencrypted root disk.

**Never read a secret back to confirm it.** `config/read` with `is_secret: true` returns the
first `min(len/2, 8)` characters in clear plus the exact length — which violates the
project's own secrets rule. Verify by handshake instead: enable the extension, list its
tools, call one cheap read-only tool. There is deliberately no "show token" affordance in
the phone UI.

### The stdio naming collision

The repo's `<PROVIDER>_*` secret convention (`docs/providers.md`) **cannot be honoured for
stdio connectors**. `${VAR}` substitution is applied only to a remote extension's `uri`,
`headers` and `socket` — never to stdio `env` values — and `cwd` is hardcoded `None` over
ACP, so a wrapper script can't rename them either without an absolute path in `command`.

A server demanding `MCP_EMAIL_SERVER_PASSWORD` gets exactly that key. Two providers of the
same protocol therefore **collide on one key**, and the honest answer today is one
extension instance per account with a wrapper binary. Record the collision in `blockers`
rather than pretending the convention holds.

---

## Adding a connector

1. Run the workflow (`/connect-service` from the phone, or
   `recipes/connect-service.yaml`). If no manifest exists it researches one and writes it here.
2. Whatever it produces, **the vetting bar is not self-certifying** — a human confirms
   `maintenance` and `self_hosted_auth` before the manifest is committed.
3. Add the `docs/privacy.md` row. `privacy.row_added: true` is a lie until you do; the
   validator checks the row exists.
4. `scripts/verify/check-connectors.sh --smoke <id>`.

## Fields the validator rejects

- `available_tools` absent, empty, or spelled `availableTools`
- `scopes` set without `clientId` (a hard config error in goose)
- `clientId` / `clientSecretKey` / `scopes` on anything but a `http` server — goose
  restricts OAuth fields to streamable-HTTP extensions
- `server.type: sse`
- `privacy.tier: 3` without a `docs/privacy.md` row
- any secret whose `key` appears with a value anywhere in the file
