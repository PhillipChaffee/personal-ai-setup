# Phone setup — the iPhone as a thin client

The iPhone never runs an agent. It's a few small apps, each a thin surface
onto infrastructure you already run — in priority order: **Telegram** (the
working agentic path — chat with the brain from anywhere, §1a), **Tailscale**
(network), **Pal Chat** (quick BYOK chat, works day one), and a **Siri
Shortcut** (voice one-shots). Automation results need nothing here at all —
they arrive by email (§2). The **Goose iOS app** is covered honestly in §1b:
as of goose 1.46 / app 1.1.6 it cannot talk to a headless brain.

§2–§5 need no server and can be done in Phase 1. §1 needs the brain
([50-vps-brain.md](50-vps-brain.md)) — come back to it from there.

> **Do not use Chatbox on iOS.** Its custom OpenAI-compatible endpoints with
> API-key auth are broken on iPhone (WKWebView CORS preflight strips the auth
> header; works on desktop, fails on iOS; bug open with no fix —
> [chatboxai/chatbox#3516](https://github.com/chatboxai/chatbox/issues/3516)).
> Pal Chat is the verified pick for BYOK chat on iOS.

## 1a. Telegram gateway — the working agentic path

The brain runs goose's Telegram gateway, giving your phone full agentic
access — same sessions, all extensions, from anywhere, no tailnet needed on
the phone, always-on because it lives on the VPS:

1. In Telegram, message **@BotFather** → `/newbot` → pick a name and a
   `…bot` username. Copy the bot token (a secret — Keychain / secrets.env,
   never in a repo).
2. On the brain, with the secrets env loaded:
   `goose gateway start telegram --bot-token "$TELEGRAM_BOT_TOKEN"`
   (run under systemd or tmux so it survives; then
   `goose gateway pair telegram` prints a pairing code).
3. Send the pairing code to your bot from your own Telegram account — that
   binds the gateway to you. **The gateway answers your account only**;
   treat the bot token like a password.

## 1b. Goose iOS app — status: not usable with a headless brain

The **"Goose AI"** App Store app
(<https://apps.apple.com/us/app/goose-ai/id6752889295>) is
**maintainer-published** (an individual goose core maintainer's developer
account, referenced by the project's blog and `block/goose-mobile` — not a
Block Inc. release, and not promoted on the goose site). As of
goose 1.46 / app 1.1.6 (2026-08-21):

- Its **server URL + secret mode connects** (the `/status` probe passes,
  including over a real LE certificate) **but every chat action 404s** — the
  app expects the REST API of `goosed`, the backend bundled inside the
  Desktop *app*, which the headless CLI's `goose serve` does not expose
  (serve answers only `/status` and `/acp`, even with `--platform desktop`).
- The **QR/tunnel pairing flow was removed upstream**, and no in-app entry
  point for `goose gateway pair mobile` codes exists in this app version.

Net: install it only if you want to re-test after goose upgrades
(watch the mobile roadmap — native remote ACP + push — in
[`docs/roadmap.md`](../roadmap.md)). Until then, §1a is the phone's agentic
surface. If you do try it and enter your server secret into the app, note the
trust boundary (individually-published binary) and rotate
`GOOSE_SERVER__SECRET_KEY` afterwards if that bothers you (docs/security.md).

## 2. How the stack reaches you — email, no app

Nothing to set up here — there is no phone push app in the
system. Automation results arrive as ordinary email — each recipe on the
brain sends its result to your own address via Gmail as its final step
([`docs/automations.md`](../automations.md)) — and failure alerts reach the
same inbox via ntfy's email gateway, configured back in
[10-accounts.md §6](10-accounts.md).

## 3. Tailscale — put the phone on the tailnet

Install the **Tailscale** iOS app, sign in with the same identity you used in
[10-accounts.md §3](10-accounts.md), and allow the VPN configuration.

Nothing in §1–2 strictly requires this today (Telegram and email need no
tailnet) — but the tailnet is the only route to everything tailnet-bound on
the brain: emergency SSH from the phone, any future self-hosted web surface,
and the goose mobile roadmap's remote-ACP path, which would connect directly
over exactly this tailnet. Set it up now so it's there when you need it.

## 4. Pal Chat — the backup that works day one

**Pal Chat** (App Store, "Pal Chat - AI Chat Client"; Pro ≈ $7 one-time,
prices as of 2026-08-20) is a native BYOK client with custom
OpenAI-compatible endpoints, local-only chat storage, and no data collection.
It's the backup surface precisely *because* its history is device-local: if
the brain, the tunnel, and the Mac are all down, this still works — but
nothing you say here lands in the shared history.

Add both providers (Settings → model/provider configuration → custom
OpenAI-compatible endpoint):

| Provider | Base URL | Key | Models to add |
|---|---|---|---|
| Together | `https://api.together.xyz/v1` | `TOGETHER_API_KEY` | `openai/gpt-oss-120b` (cheap default), `Qwen/Qwen3.5-397B-A17B` |
| OpenCode Zen | `https://opencode.ai/zen/v1` | `OPENCODE_ZEN_API_KEY` | `kimi-k2.6`, `minimax-m2.7`, `glm-5.1`, `deepseek-v4-flash` |

**Zen caveat:** only Zen's *chat-completions* models work here (the four
above). Claude and Qwen ride Zen's Anthropic `/messages` endpoint and GPT-5.x
rides `/responses` — an OpenAI-compatible client like Pal Chat can't speak
either, so don't add those IDs ([`docs/model-routing.md`](../model-routing.md)).

The routing rules follow you onto the phone: Together for anything personal
or sensitive; Zen paid models for general chat; never paste vault-tier
content at a model the [routing table](../model-routing.md) wouldn't allow.

## 5. Siri Shortcut — voice one-shots

A Shortcut that POSTs your spoken question straight to Together and speaks
the answer. Framing matters: this is a **voice trigger for one-shot Q&A** —
no memory, no tools, no brain — not a main client. Build it once in the
Shortcuts app:

1. **New shortcut**, name it `Ask my AI` (the name is the Siri phrase).
2. Action **Ask for Input** — type *Text*, prompt `What do you want to ask?`
   (invoked via Siri, this becomes a spoken question + dictation).
3. Action **Text**, containing the request body, with the magic variable
   from step 2 inserted where `[Provided Input]` appears:

   ```json
   {"model": "openai/gpt-oss-120b",
    "messages": [{"role": "user", "content": "[Provided Input]"}],
    "max_tokens": 400}
   ```

4. Action **Get Contents of URL**:
   - URL: `https://api.together.xyz/v1/chat/completions`
   - Method: `POST`
   - Headers: `Authorization` = `Bearer <YOUR-TOGETHER-API-KEY>`,
     `Content-Type` = `application/json`
   - Request Body: **File** → the Text from step 3.
5. Parse the reply: **Get Dictionary from Input** → **Get Dictionary Value**
   `choices` → **Get Item from List** (First Item) → **Get Dictionary Value**
   `message` → **Get Dictionary Value** `content`.
6. Action **Show Result** with that value — when triggered by voice, Siri
   reads it aloud.

Then: *"Hey Siri, Ask my AI"* → speak → hear the answer.

Notes: the API key lives inside the shortcut, readable by anyone who can
unlock your phone — acceptable for a low-balance PAYG key you can rotate
([`docs/security.md`](../security.md), key rotation). A dictated question
containing literal quote characters can break the JSON body; for one-shot
voice questions this effectively never happens. Long agent-style requests
will hit Shortcuts' HTTP patience — keep it to questions, and take real work
to Telegram or the Mac.

## Done — the phone at a glance

| Surface | Needs | Gives |
|---|---|---|
| Telegram gateway (§1a) | Brain + bot token | Full agent, shared brain, 24/7 — the primary phone surface |
| Goose iOS app (§1b) | An upstream fix | Nothing today (incompatible with a headless brain as of app 1.1.6) |
| Email inbox (§2) | Nothing new | Every automation's results and failure alerts |
| Tailscale (§3) | Tailnet | Direct path to the brain, future-proofing |
| Pal Chat (§4) | A provider key | Chat that survives everything being down |
| Siri Shortcut (§5) | A provider key | Voice one-shots |

Pairing problems: [`docs/troubleshooting.md`](../troubleshooting.md#goose-ios-pairing-fails).
