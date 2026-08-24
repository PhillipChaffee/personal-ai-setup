# Connecting the brain to a service

[`providers.md`](providers.md) built a doorway for one room: email and calendar. This
document widens it to **any** external service — files, tasks, health records, a budgeting
app, whatever joins your life next — and makes the doorway *executable* rather than prose.

The design decision, made once, here: there is **one generic workflow**, and its output
artifact is a per-service [connector manifest](../config/connectors/README.md). Known
services skip straight to authentication; unknown ones run the full research path and
**leave a manifest behind**. Distinct support accrues from use instead of being hand-written
in advance. That is why this repo does not ship a directory of thirty integrations.

Facts below verified against **goose 1.46.0** (the pinned version) on **2026-08-23**, by
running a real `goose serve` and reading the results back — not by reading docs. Where
something is inferred rather than observed, it says so.

## What "connecting" means in goose's own vocabulary

A connection is a goose **extension**, which is an MCP server. Three variants exist
(`builtin`, `platform`, `mcp`); connectors are always `mcp`, over `stdio` or streamable
HTTP.

There are four ways to add one — the UI, `goose configure`, a `goose://extension?…`
deeplink, or editing `config.yaml`. This repo uses a fifth that the others are built on:
the **ACP custom methods**, because that is the only path a phone can drive.

| Method | Does |
|---|---|
| `_goose/unstable/extensions/available` | goose's own bundled extension directory |
| `_goose/unstable/config/extensions/list` | what's configured, with `configKey` and `enabled` |
| `_goose/unstable/config/extensions/add` | persist a new extension to `config.yaml` |
| `_goose/unstable/config/extensions/set-enabled` | toggle one |
| `_goose/unstable/session/extensions/add` | attach to the **running** session |
| `_goose/unstable/config/upsert` | write a config value or a secret (`is_secret`) |

All eleven methods this repo relies on exist at **v1.46.0** — verified by fetching
`crates/goose/acp-meta.json` at the tag, which lists 113 methods and is the only
machine-readable contract goose publishes. **No version bump is required**; the
`brew pin block-goose-cli` in `scripts/mac/bootstrap-mac.sh` stays.

Two caveats that follow from `_goose/unstable/`:

- **There is no capability negotiation for these.** `initialize` advertises only
  `recipeParameterScopes` and `localInference`; a client cannot ask whether
  `config/extensions/add` exists. It must know, from the pinned version.
- **The prefix means what it says.** The names have already broken twice in released
  history: `config/extensions/toggle` → `set-enabled` between v1.37 and v1.38, and an
  entire `_goose/config/*` family was deleted. All of it therefore lives behind one
  adapter keyed to the pinned version, and CI asserts every method string against
  `acp-meta.json` at that ref.

### No restart

Adding an extension does **not** require restarting `goose serve`. `config/extensions/add`
persists it and `session/extensions/add` attaches it to the session you are already talking
in. This matters more than it sounds: a restart would kill the very conversation driving the
connection.

*(Not yet verified: whether `config/extensions/add` alone hot-reloads an in-flight session,
or whether the `session/…` call is always required. The workflow issues both, so the
happy path is correct either way.)*

## Which direction does traffic go?

The brain has **zero public inbound ports** ([`security.md`](security.md)), which raises an
obvious question: how does it reach Gmail at all?

Because the firewall only drops **ingress**. `infra/terraform/main.tf` creates a Hetzner
firewall with no `rule` blocks — and with no outbound rules defined, egress is unrestricted,
which is exactly what the server needs for apt, Tailscale, and provider/MCP HTTPS. Every
connector is **pull-based**: the brain opens the connection outward, and stateful return
traffic on an established flow was never "inbound" in the rule sense.

Three listening situations, worth keeping apart because they fail differently:

| Interface | Status | What uses it |
|---|---|---|
| **Public** (Hetzner NIC) | all inbound dropped | nothing — this is what makes webhooks impossible |
| **Tailnet** (WireGuard) | reachable from your devices | `goose serve --host "$TS_IP" --port 3284` — how your phone reaches the brain at all |
| **Loopback** (`127.0.0.1`) | never crosses a network interface | the OAuth callback listener; Proton Bridge's IMAP on `127.0.0.1:1143` |

Per connector: `workspace-mcp` dials out to `googleapis.com`; Todoist's remote MCP is an
outbound HTTPS call to `ai.todoist.net`; IMAP/CalDAV is outbound TLS to the host; and Proton
Bridge dials out to Proton, then serves loopback only, so the MCP server's connection to it
never touches a network interface.

**The corollary that matters:** the OAuth failure below is *not* a firewall problem, and
opening a port would not fix it. goose hardcodes the redirect as
`http://127.0.0.1:{port}/oauth_callback`, so "localhost" resolves to whichever machine the
*browser* is on — on a phone, the phone. Even with the brain's port world-reachable, goose
would never emit a redirect URI pointing at it, and Google would not accept a `*.ts.net` one
regardless. Two independent walls, and only one of them is yours to move.

## Least privilege is a field, and it fails open

The whole point of connecting a service is giving the agent *some* access, not all of it.
goose expresses this with `available_tools`, a per-extension tool allowlist, and — where a
server supports it — the server's own scope flags.

Both must be set, because they gate different things:

- **`available_tools`** filters what the agent may call, and shrinks the tool list sent with
  every request.
- **OAuth scopes / server permission flags** gate what the *credential itself* can do. A
  tight allowlist over a credential scoped to your whole Drive still means a stolen token
  reads your whole Drive.

`available_tools` is snake_case on the wire while its siblings are camelCase, has no
`deny_unknown_fields`, and treats "absent" and "empty" as *allow everything*. Writing it the
natural way produces a silently-inert allowlist. The mechanics, the empirical proof, and the
two mandatory mitigations are in
[`config/connectors/README.md`](../config/connectors/README.md#the-one-field-that-must-not-be-typed-from-memory).
Read that before authoring a manifest.

Concretely for Workspace: `--permissions gmail:send calendar:full tasks:manage` is what
narrows the OAuth consent screen, and `available_tools` is what narrows the agent. The
repo's older `--tool-tier core --tools gmail calendar tasks` did neither well — it left
`tasks` non-functional and requested more than it used.

## Can it be done from the phone?

Honestly: **it depends entirely on how the service authenticates**, and for OAuth the answer
today is no.

Every manifest therefore carries a `first_run_auth` field, and the workflow **refuses to
start a connection it cannot finish** rather than stranding you 40 minutes in.

| `first_run_auth` | Meaning | Phone |
|---|---|---|
| `none` | No credential (e.g. a local file path) | **Yes** |
| `phone_secret` | An API token or app password you can type | **Yes** |
| `brain_browser` | Interactive consent/login on the brain itself | No — needs a laptop |
| `laptop_oob` | Out-of-band setup, then copy state to the brain | No |

### Why OAuth cannot be completed from a phone

Not a limitation of this repo — a property of goose as of 1.46.0 and `main` alike. Three
independent mechanisms, each individually fatal:

1. **The callback is loopback-bound on the brain.** The redirect URI is hardcoded
   `http://127.0.0.1:{port}/oauth_callback`; `GOOSE_OAUTH_CALLBACK_PORT` changes only the
   port. Your phone's browser resolves `127.0.0.1` to *the phone*.
2. **The authorization URL never leaves the brain.** It is emitted with `warn!` +
   `eprintln!` + `webbrowser::open` — a no-op on a headless server — and appears in no ACP
   message. The phone never learns the URL to open.
3. **URL-mode elicitation, the one mechanism that could carry it, is explicitly refused** at
   goose's ACP bridge, and the phone client advertises no elicitation capability, so even
   form elicitation is auto-cancelled.

There is no device-code grant anywhere in the MCP path. Upstream issue #11086 tracks this.

Three escape routes were evaluated and all fail for a Tailscale-only brain:
Google's TV/limited-input device flow does not cover Gmail/Calendar/Tasks scopes; a
Tailscale-HTTPS redirect URI cannot be registered because `*.ts.net` can never be a verified
Authorized Domain; and a domain you own works but presumes you own one.

**So the phone-native happy path is `phone_secret`, not OAuth** — bearer-token services and
app-password services. Todoist is the worked example: its first-party remote MCP accepts a
personal API token as an `Authorization` header, which is headless, phone-completable, and
keeps goose's OAuth machinery out of the picture entirely. Where a service *only* does
OAuth, the manifest says `brain_browser` and points at a runbook.

## Privacy is a gate, not a footnote

No connector's data may route anywhere until it has a row in
[`privacy.md`](privacy.md) — the rule `providers.md` established, unchanged and now
enforced by the validator.

Two additions that only matter once arbitrary services are in play:

- **Classify by the most sensitive content the connector can surface, not by its label.** A
  files connector is Tier 3 the moment your Drive holds a tax return or a lab PDF, even
  though "files" sounds Tier 2.
- **Tier 3 routing is a property of the session, not a filter applied afterwards.** Raw
  request and response bodies are written to `<state>/logs/llm_request.*.jsonl` regardless
  of tier, and tool results land in `sessions.db`. Deciding the tier *after* the call has
  already leaked it. This is why `GOOSE_PATH_ROOT=/data/goose` is not optional — it puts
  config, data **and state** on the encrypted volume.

## What is deliberately not supported

Saying this plainly is more useful than a half-working integration:

- **Push / webhooks.** Zero public inbound ports is a security invariant
  ([`security.md`](security.md)). Anything push-only is out.
- **Sending files from the phone.** The mobile client can only send text content blocks;
  there is no attachment path at any layer. This is why `periodic_export` (health records,
  bank statements) is **Mac-only** today, not phone-runnable — the export has to reach
  `/data` some other way.
- **Proton Calendar and Proton Contacts.** No CalDAV, no supported API. Proton *Mail* works
  via Bridge; the rest of the suite does not. Half of "all Proton services" is a documented
  dead end rather than an open task.
- **Contacts/CardDAV generally.** No server currently clears the maintenance bar.

## Relationship to `providers.md`

`providers.md` keeps what is specific to the communication surface: the `mail-<provider>` /
`cal-<provider>` naming, per-provider account rosters, and the rule that delivery stays one
self-addressed email from the Google primary. This document owns the general case, and the
vetting bar is shared — defined there, applied here to every archetype.

One correction propagates back: the `<PROVIDER>_*` secret-naming convention **cannot be
honoured for stdio connectors**, because goose does no `${VAR}` substitution on stdio env
values and cannot set a working directory over ACP. See
[the collision note](../config/connectors/README.md#the-stdio-naming-collision).
