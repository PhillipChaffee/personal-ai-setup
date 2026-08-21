# Phone setup — the iPhone as a thin client

The iPhone never runs an agent. It's four small apps and a shortcut, each a
thin surface onto infrastructure you already run — in priority order: the
**Goose iOS app** (primary, pairs to the brain), **ntfy** (push), **Tailscale**
(network), **Pal Chat** (backup chat, works day one), and a **Siri Shortcut**
(voice one-shots).

§2–§5 need no server and can be done in Phase 1. §1 needs the brain
([50-vps-brain.md](50-vps-brain.md)) — come back to it from there.

> **Do not use Chatbox on iOS.** Its custom OpenAI-compatible endpoints with
> API-key auth are broken on iPhone (WKWebView CORS preflight strips the auth
> header; works on desktop, fails on iOS; bug open with no fix —
> [chatboxai/chatbox#3516](https://github.com/chatboxai/chatbox/issues/3516)).
> Pal Chat is the verified pick for BYOK chat on iOS.

## 1. Goose iOS app — the primary surface (experimental)

Install **"Goose AI"** from the App Store
(<https://apps.apple.com/us/app/goose-ai/id6752889295>, iOS 17+). It's the
official thin remote client: it connects back to a running goose agent
through an **outbound-only websocket tunnel** (relayed via Cloudflare — no
inbound port opens anywhere; the privacy trade-off and its alternatives are
discussed in [`docs/privacy.md`](../privacy.md#the-goose-ios-tunnel-and-cloudflare)).

**What it can do:** chat with your agent from anywhere, see and resume the
same sessions as every other surface, and check on long-running tasks —
everything executes on the paired host, so paired to the brain it has the
full extension set and the shared history.

**What it can't do / honest caveats:** it is an explicitly
**experimental/preview** feature. Nothing works if the paired host isn't
running; the documented pairing flow is Desktop-initiated (headless pairing
is our own attempt, below); fine-grained tool-approval UX on the phone is
unverified; and the feature surface changes across goose releases. The thing
that fixes all of this — native remote ACP + push on the goose mobile
roadmap — is tracked in [`docs/roadmap.md`](../roadmap.md).

### Pairing, in fallback order

Work down this chain until one sticks. A–B give the real app experience;
C–D are degraded but dependable.

**A. Headless pairing from the brain (try first — experimental, may not
exist in your pinned version).** The pairing tunnel is documented as started
from Goose Desktop; whether the CLI on a headless box can start one depends
on the release. On the brain:

```bash
goose --help | grep -iE 'tunnel|mobile|pair'
```

If your pinned version has a tunnel/pairing subcommand, run it inside `tmux`
(it must stay running), and pair the app with the QR code or URL it prints.
If the grep comes up empty, this path doesn't exist in your version — move
to B, and re-check after goose upgrades.

**B. Desktop-initiated tunnel (works, but only while the Mac is awake).**
With Goose Desktop connected to the brain as a remote server
([50-vps-brain.md](50-vps-brain.md)), start the mobile tunnel from Desktop
(Settings → the mobile/remote-access pane) and scan the QR with the app. The
Mac acts as a relay in front of the brain: sessions and history still live on
the brain, but the phone loses access whenever the Mac sleeps. Acceptable as
a daytime arrangement; not a 24/7 one.

**C. Telegram gateway on the brain (24/7, different app, same brain).**
Goose's experimental gateway gives you the brain inside Telegram — no tunnel,
no Mac ([gateway docs](https://github.com/aaif-goose/goose/blob/main/documentation/docs/experimental/remote-access/telegram-gateway.md)):

1. In Telegram, message **@BotFather** → `/newbot` → pick a name and a unique
   username → copy the bot token. Treat the token *and the bot username* as
   secrets — anyone who finds the bot can try to talk to it.
2. On the brain (in `tmux`, so it survives the SSH session):

   ```bash
   goose gateway start telegram --bot-token "<YOUR-BOT-TOKEN>"
   goose gateway pair telegram        # prints a pairing code
   ```

3. Send the pairing code to your bot from **your own Telegram account** —
   codes expire within minutes, so do this immediately. Pairing binds the
   gateway to your account; never post the code or the bot username anywhere,
   and don't pair any other account. If you adopt this as your daily channel,
   store the token as an extra `TELEGRAM_BOT_TOKEN=` line in
   `/data/secrets.env` and promote the gateway to a small systemd unit.

Trade-offs: Telegram becomes a relay party in the phone path (same shape of
trade as the Cloudflare tunnel — see
[`docs/privacy.md`](../privacy.md#the-goose-ios-tunnel-and-cloudflare)), and
chat happens in Telegram's UI rather than the app's.

**D. Pal Chat (§4).** Always works, needs nothing but a provider key — but
it's plain BYOK chat: no tools, no brain, device-local history.

## 2. ntfy — how the stack reaches you

Install the **ntfy** app
(<https://apps.apple.com/us/app/ntfy/id1625396347>) and subscribe to your
secret topic — you created it (and tested a push) in
[10-accounts.md §6](10-accounts.md). Every automation on the brain delivers
through this channel via `scripts/common/notify.sh`.

Two rules worth re-reading in [`docs/privacy.md`](../privacy.md): the topic
name is a password (never share or commit it), and pushes from sensitive
jobs carry counts/titles only — never PHI.

## 3. Tailscale — put the phone on the tailnet

Install the **Tailscale** iOS app, sign in with the same identity you used in
[10-accounts.md §3](10-accounts.md), and allow the VPN configuration.

Nothing in §1–2 strictly requires this today (the tunnel and ntfy are
outbound/public paths) — but the tailnet is the only route to everything
tailnet-bound on the brain: emergency SSH from the phone, any future
self-hosted web surface, and the goose mobile roadmap's remote-ACP path,
which will replace the Cloudflare tunnel with a direct connection over
exactly this tailnet. Set it up now so it's there when you need it.

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
to the Goose app or the Mac.

## Done — the phone at a glance

| Surface | Needs | Gives |
|---|---|---|
| Goose iOS app (§1) | Brain + a working pairing path | Full agent, shared history — primary |
| Telegram gateway (§1C) | Brain | Full agent in Telegram — 24/7 fallback |
| ntfy (§2) | Topic | Every automation's delivery channel |
| Tailscale (§3) | Tailnet | Direct path to the brain, future-proofing |
| Pal Chat (§4) | A provider key | Chat that survives everything being down |
| Siri Shortcut (§5) | A provider key | Voice one-shots |

Pairing problems: [`docs/troubleshooting.md`](../troubleshooting.md#goose-ios-pairing-fails).
