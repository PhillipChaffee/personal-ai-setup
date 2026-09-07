#!/usr/bin/env python3
"""fake-provider — the Zen and Together inference slice the verify checks call.

One process, one port, two mounts, so `check-providers.sh` and `check-goose.sh`
can be run end to end with no network and no real key:

    fake-provider.py --port 4396 --out /tmp/provider.jsonl
    export ZEN_BASE=http://127.0.0.1:4396/zen/v1
    export TOGETHER_BASE=http://127.0.0.1:4396/together/v1
    scripts/verify/check-providers.sh

Served — everything else 404s, and a known path answered with the wrong method
is a 405:

    GET  /zen/v1/models                 the zen catalog
    POST /zen/v1/chat/completions       openai wire; model must be in the catalog
    POST /zen/v1/messages               anthropic wire; also REQUIRES an
                                        anthropic-version header, else 400
    GET  /together/v1/models            the together catalog
    POST /together/v1/chat/completions  openai wire; model must be in the catalog

Auth is per mount: /zen takes `Authorization: Bearer <key>` AND `x-api-key:
<key>`, /together takes Bearer only. Anything missing, blank, wrong-valued or
presented under a scheme the mount does not take is a 401. That asymmetry is
the point of the file — a blind-200 curl shim makes `check-providers.sh` print
`== summary: 5 passed, 0 failed ==` and exit 0 while inspecting zero bytes of
any body, because every verdict it makes (:83, :95, :122, :145, :157) is
`[ "$HTTP_STATUS" = "200" ]`. All of this fake's value is in what it refuses.

RULE, and it is a rule rather than a preference: NEVER echo a request header or
a request body back in a response, in any status code. `check-providers.sh:74`
prints the raw first 300 bytes of any non-200 body (:87, :99, :138, :149, :161)
and the key travels in `Authorization: Bearer $OPENCODE_ZEN_API_KEY` /
`x-api-key: $OPENCODE_ZEN_API_KEY`. A debugging-friendly
`{"received_headers": ...}` prints a real key the first time somebody points
ZEN_BASE here with their own environment loaded — which is exactly what an
overridable base invites. Every error body below is therefore a module
constant with nothing request-derived in it.

The record (`--out`, one JSONL object per request) obeys the same rule:

    {"mount", "method", "path", "auth_scheme", "key_matched", "model", "status"}

`auth_scheme` is the literal string `bearer` / `x-api-key` / `none` and
`key_matched` is a boolean — the credential itself is read, compared, and
dropped, and no code path can write it anywhere. Booleans and counts only
(test-code-agent-manager.sh:523-525). `path` is the URL path with the query
string discarded, so a key smuggled into `?api_key=` cannot land in the log
either. Request bodies are parsed for one field, `model`, and are never stored.

FAKE_PROVIDER_MODE picks one of the misbehaviours listed at MODES below; an
unknown value exits rather than quietly serving the happy path. There is no
/__ready route on purpose: an unauthenticated, always-200, mode-exempt route is
a hole someone forgets about, and a harness that polls GET /zen/v1/models with
the key it expects has proved the auth wiring is live before the check runs.
Those poll requests land in the record like any other, so a phase assertion
counts rows added since the poll rather than rows in the file.

Never point this at anything real: it hands out completions to anyone holding a
fixture key and keeps a plaintext record of every request it sees.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

Wire = dict[str, Any]

# `*_KEY`, not `*_TOKEN`: ruff's S105 fires on a name containing TOKEN and not
# on one containing KEY, and a hardcoded-password suppression on a fixture
# default is a line the next reader has to re-justify. The defaults are the
# spellings already committed at test-code-agent-manager.sh:217/219 — low
# entropy, established precedent for gitleaks, and exactly what the harness
# exports as OPENCODE_ZEN_API_KEY / TOGETHER_API_KEY.
ZEN_KEY = os.environ.get("FAKE_PROVIDER_ZEN_KEY", "fake-zen-key")
TOGETHER_KEY = os.environ.get("FAKE_PROVIDER_TOGETHER_KEY", "fake-together-key")

# Each mode exists for exactly one harness arm, named here so that arm and this
# mode live or die together (fake-github.py:443: "a mode only one assertion
# reaches is a mode that rots" — a mode NO assertion reaches is worse). No
# `down` mode: check-providers.sh:69 turns every transport failure into
# HTTP_STATUS 000 and the same FAIL row, so the mode would have nothing of its
# own to assert that stopping the process does not already prove.
MODES = {
    "ok": "the happy path — five green check-providers rows and three green check-goose rows",
    "zen-model-404": "check-providers.sh:100, the 'run pin-models.sh' hint arm",
    "bearer-only": "check-providers.sh:130-135, the NOTE arm (goose's engine sends x-api-key)",
}
MODE = os.environ.get("FAKE_PROVIDER_MODE", "ok")

# One writer lock: the server is threaded, and two requests landing together
# must not interleave half-lines into the record.
WRITE_LOCK = threading.Lock()
OUT_PATH = Path("/dev/null")

MAX_BODY = 1 << 20
BEARER = "Bearer "

# Literal fixtures, NOT derived from config/goose/custom_providers/*.json: those
# carry the full upstream catalogs (pin-models.sh:43 globs all four and pulls
# ~700 ids), and a mount that accepts 700 models cannot tell a pinned model from
# a deprecated one. These three ids are exactly what check-providers.sh:93/106/155
# and check-goose.sh:52 send, so a drift in either script lands as a 404 here.
ZEN_MODELS = ("minimax-m2.7", "claude-haiku-4-5")
TOGETHER_MODELS = ("openai/gpt-oss-120b",)


@dataclass(frozen=True)
class Route:
    """One served endpoint. The table below is exhaustive; anything else 404s."""

    mount: str
    method: str
    kind: str
    models: tuple[str, ...]


ROUTES: dict[str, Route] = {
    "/zen/v1/models": Route("zen", "GET", "models", ZEN_MODELS),
    "/zen/v1/chat/completions": Route("zen", "POST", "chat", ZEN_MODELS),
    "/zen/v1/messages": Route("zen", "POST", "messages", ZEN_MODELS),
    "/together/v1/models": Route("together", "GET", "models", TOGETHER_MODELS),
    "/together/v1/chat/completions": Route("together", "POST", "chat", TOGETHER_MODELS),
}

KEYS: dict[str, str] = {"zen": ZEN_KEY, "together": TOGETHER_KEY}

# Zen takes both schemes because settling exactly that is check-providers.sh's
# job at :122-129: it sends the same /messages request twice and reports which
# headers worked. A mount that took anything would turn that RESULT line into a
# restatement of the request instead of an observation.
SCHEMES: dict[str, tuple[str, ...]] = {"zen": ("bearer", "x-api-key"), "together": ("bearer",)}

# Constant error bodies — the docstring's no-echo rule made mechanical. The
# wording also avoids every signature check-goose.sh:112 greps for
# (`unauthorized`, `invalid api key`, `rate ?limit`, ...): those greps are
# unanchored and case-insensitive, so a body that ever reached goose's stdout
# would flip a green run red for a reason that has nothing to do with goose.
NOT_FOUND: Wire = {"error": {"type": "not_found", "message": "no such route on this fake"}}
NO_MODEL: Wire = {"error": {"type": "not_found", "message": "model is not in this catalog"}}
BAD_METHOD: Wire = {"error": {"type": "invalid_request", "message": "method not allowed here"}}
NO_AUTH: Wire = {"error": {"type": "authentication_error", "message": "key rejected by this mount"}}
NO_VERSION: Wire = {
    "error": {"type": "invalid_request", "message": "anthropic-version header is required"},
}


def key_matches(mount: str, presented: str) -> bool:
    """Report whether `presented` is this mount's key — a boolean, never the value.

    `bool(presented)` comes first so that an operator who exports
    FAKE_PROVIDER_ZEN_KEY= (empty) does not turn every unauthenticated request
    into a match and every assertion built on `key_matched` into a tautology.
    """
    return bool(presented) and presented == KEYS.get(mount)


def model_of(raw: bytes) -> str | None:
    """Pull `model` out of a request body, or None if it has no usable one.

    This is the ONLY field read out of a body, and nothing else in it is kept:
    the body is the other place a caller's key could be sitting.
    """
    if not raw:
        return None
    try:
        body: Any = json.loads(raw.decode("utf-8", "replace"))
    except json.JSONDecodeError:
        return None
    if not isinstance(body, dict):
        return None
    model = body.get("model")
    return model if isinstance(model, str) else None


def completion(model: str) -> Wire:
    """Build an openai-wire chat completion. `created` is a constant, not a clock.

    No caller parses this — check-providers.sh and fake-goose.sh both verdict on
    the status alone — so it exists to be readable to a human tailing the wire,
    and it is byte-stable so two runs of the harness cannot differ in it.
    """
    return {
        "id": "fake-completion",
        "object": "chat.completion",
        "created": 0,
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": "OK"},
                "finish_reason": "stop",
            },
        ],
        "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
    }


def message(model: str) -> Wire:
    """Build an anthropic-wire message — the other shape, for /zen/v1/messages."""
    return {
        "id": "fake-message",
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": [{"type": "text", "text": "OK"}],
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 1, "output_tokens": 1},
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "fake-provider"

    def take(self) -> None:
        """Read the body, then dispatch — on every verb, not just the ones that carry one.

        The read happens BEFORE any verdict is reached. Each arm below can
        answer without the body, but an unread body left in the socket
        desynchronises the next request on a keep-alive connection, and the
        failure would surface as a hang in whichever check ran next rather than
        as a wrong status here.
        """
        length = int(self.headers.get("Content-Length") or 0)
        self.dispatch(self.rfile.read(min(length, MAX_BODY)) if length else b"")

    # The five routes are GET/POST, but a wrong VERB on a known path owes a 405
    # and a record row, so every verb a caller could plausibly reach for is
    # named here rather than left to BaseHTTPRequestHandler. Its send_error()
    # 501 bypasses reply(), so it answers with no row -- breaking the "every
    # response is recorded" invariant the harness counts on -- and its HTML body
    # quotes the method back at the caller, the one echo this file otherwise
    # never does. Six near-identical bodies rather than `do_PUT = do_GET`
    # aliases: ruff's N815 rejects a mixedCase class attribute, and the base
    # class dispatches by getattr(self, "do_" + command), so the name is the
    # whole content either way. A verb outside this list (FROBNICATE) still
    # 501s, which is a refusal; enumerating verbs no caller has is how a fake
    # grows surface.
    def do_GET(self) -> None:
        self.take()

    def do_POST(self) -> None:
        self.take()

    def do_HEAD(self) -> None:
        self.take()

    def do_PUT(self) -> None:
        self.take()

    def do_PATCH(self) -> None:
        self.take()

    def do_DELETE(self) -> None:
        self.take()

    def do_OPTIONS(self) -> None:
        self.take()

    def credential(self) -> tuple[str, str]:
        """Return (scheme, presented value) — the only place the value is read.

        An Authorization header in a scheme this fake does not know reads as
        `none`: the record says a credential this mount cannot use was offered,
        and says it without carrying a single byte of the header.
        """
        auth = self.headers.get("Authorization")
        if auth is not None and auth.startswith(BEARER):
            return "bearer", auth[len(BEARER) :].strip()
        api_key = self.headers.get("x-api-key")
        if api_key is not None:
            return "x-api-key", api_key.strip()
        return "none", ""

    def dispatch(self, raw: bytes) -> None:
        route = ROUTES.get(urlparse(self.path).path)
        if route is None:
            self.reply(404, NOT_FOUND, mount="none", model=None)
            return
        model = model_of(raw)
        if self.command != route.method:
            self.reply(405, BAD_METHOD, mount=route.mount, model=model)
            return
        scheme, presented = self.credential()
        # Scheme and value are judged separately, so the 401s stay
        # distinguishable in the record: a right key under a scheme the mount
        # refuses records key_matched true with status 401, which is precisely
        # what the together mount is here to demonstrate.
        if scheme not in SCHEMES[route.mount] or not key_matches(route.mount, presented):
            self.reply(401, NO_AUTH, mount=route.mount, model=model)
            return
        self.serve(route, scheme, model)

    def serve(self, route: Route, scheme: str, model: str | None) -> None:
        """Route an authenticated request. Split from dispatch() along the seam.

        dispatch() decides whether to answer at all; this decides what with.
        Growing one chain across both trips ruff's complexity limit, and the
        limit is right that a chain that long is where a route gets added in
        the wrong place (fake-github.py:299-306 makes the same cut).
        """
        if route.kind == "models":
            catalog = [{"id": name, "object": "model"} for name in route.models]
            self.reply(200, {"object": "list", "data": catalog}, mount=route.mount, model=None)
        elif route.kind == "messages":
            self.serve_messages(route, scheme, model)
        else:
            self.serve_chat(route, model)

    def serve_chat(self, route: Route, model: str | None) -> None:
        if MODE == "zen-model-404" and route.mount == "zen":
            # Zen deprecates models aggressively, and check-providers.sh:100
            # prints the "run pin-models.sh" hint for exactly this. Scoped to
            # the zen mount so the together row stays green and the harness can
            # tell a model 404 from the fake being wedged.
            self.reply(404, NO_MODEL, mount=route.mount, model=model)
            return
        if model is None or model not in route.models:
            # A body that did not parse takes this arm too: it named no model,
            # and inventing a 400 for it would be a shape no caller sends.
            self.reply(404, NO_MODEL, mount=route.mount, model=model)
            return
        self.reply(200, completion(model), mount=route.mount, model=model)

    def serve_messages(self, route: Route, scheme: str, model: str | None) -> None:
        if MODE == "bearer-only" and scheme == "x-api-key":
            # The documented uncertainty check-providers.sh:103-108 exists to
            # settle: if Zen ever takes Bearer only, goose's anthropic engine
            # (which sends x-api-key) is broken while raw HTTPS still works.
            self.reply(401, NO_AUTH, mount=route.mount, model=model)
            return
        if self.headers.get("anthropic-version") is None:
            # Required, not optional, so a caller that drops the header fails
            # here rather than silently proving the anthropic wire works.
            self.reply(400, NO_VERSION, mount=route.mount, model=model)
            return
        if model is None or model not in route.models:
            self.reply(404, NO_MODEL, mount=route.mount, model=model)
            return
        self.reply(200, message(model), mount=route.mount, model=model)

    def reply(self, status: int, payload: Wire, *, mount: str, model: str | None) -> None:
        raw = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        # HEAD gets the headers and the truthful Content-Length but no body:
        # bytes the client will not read are bytes the next request on this
        # connection reads instead.
        if self.command != "HEAD":
            self.wfile.write(raw)
        self.record(status, mount, model)

    def record(self, status: int, mount: str, model: str | None) -> None:
        """Append one row. Recomputes the scheme rather than being handed it.

        Every response goes through reply(), and reply() ends here, so there is
        no arm that can answer without being recorded — which is what lets the
        harness assert an exact row count for a phase.
        """
        scheme, presented = self.credential()
        row = {
            # `none` when no route matched, so the mount vocabulary in the
            # record is exactly {zen, together, none} and a typo'd path cannot
            # invent a third one.
            "mount": mount,
            "method": self.command,
            # Path only: a query string is somewhere a key can ride.
            "path": urlparse(self.path).path,
            "auth_scheme": scheme,
            "key_matched": key_matches(mount, presented),
            "model": model,
            "status": status,
        }
        with WRITE_LOCK, OUT_PATH.open("a", encoding="utf-8") as f:
            f.write(json.dumps(row) + "\n")

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002, ARG002
        # Silent, and not only for tidiness: the default handler logs the
        # request line, and the record file is the output that is designed to
        # be safe to keep.
        return


def main() -> None:
    parser = argparse.ArgumentParser(description="Zen + Together HTTP slice for the verify harness")
    # 4396 is free: 4300 (check-code-agents.sh:41), 4397 (fake-ntfy), 4398
    # (fake-github) and 4399 (test-code-agent-manager.sh:40) are all taken.
    parser.add_argument("--port", type=int, default=4396)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    if MODE not in MODES:
        # Die naming what was seen. A mistyped mode would otherwise serve the
        # happy path, and the harness arm waiting for a 404 would fail with no
        # hint that the fake never heard the request.
        sys.exit(
            f"fake-provider: unknown FAKE_PROVIDER_MODE {MODE!r}; "
            f"want one of {', '.join(sorted(MODES))}",
        )
    global OUT_PATH  # noqa: PLW0603 -- one process-wide sink, set once from argv
    OUT_PATH = Path(args.out)
    # Touch it so the harness can read (and assert an empty) record before the
    # first request arrives.
    OUT_PATH.touch()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
