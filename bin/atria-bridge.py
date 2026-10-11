#!/usr/bin/env python3
"""agentty <-> Caveman measurement bridge.

agentty speaks OpenAI-compatible /v1/chat/completions to Atria
(api.atria-asi.ai). Caveman's local gateway only knows a fixed set of upstream
providers (openai, anthropic, gemini, ...) and cannot be pointed at Atria, so
this bridge is the seam agentty talks to:

    agentty (:8790) this bridge  ->  caveman-proxy (:8787)  ->  Atria

When BRIDGE_VIA_GATEWAY=1 every request is sent through the Caveman gateway
as the "openai" provider, so it is measured and attributed to workflow
"agentty". The gateway can only reach api.openai.com, so its 4xx/5xx for an
Atria model is expected; the measurement (tokens, latency, bytes) is what
matters. Set BRIDGE_VIA_GATEWAY=0 to talk to Atria directly.

agentty sends its own Authorization header (BYOK), which the bridge forwards
unchanged -- the real key never leaves agentty's encrypted store. Only
chat/completions, completions, embeddings and models are forwarded; anything
else 404s. Streaming (SSE) is passed through untouched.

Env:
  ATRIA_API_KEY       fallback key if the caller sends no Authorization
  ATRIA_BASE          default https://api.atria-asi.ai
  BRIDGE_LISTEN       default 127.0.0.1:8790
  BRIDGE_VIA_GATEWAY  1 = measure via caveman-proxy, 0 = straight to Atria
  CAVE_GATEWAY_URL    gateway base, default http://127.0.0.1:8787
  CAVE_WORKFLOW       workflow slug for attribution, default agentty
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ATRIA_BASE = os.environ.get("ATRIA_BASE", "https://api.atria-asi.ai").rstrip("/")
GATEWAY = os.environ.get("CAVE_GATEWAY_URL", "http://127.0.0.1:8787").rstrip("/")
WORKFLOW = os.environ.get("CAVE_WORKFLOW", "agentty")
VIA_GATEWAY = os.environ.get("BRIDGE_VIA_GATEWAY", "1") == "1"
LISTEN = os.environ.get("BRIDGE_LISTEN", "127.0.0.1:8790")
API_KEY = os.environ.get("ATRIA_API_KEY", "")
TIMEOUT = int(os.environ.get("BRIDGE_TIMEOUT", "600"))
RETRIES = int(os.environ.get("BRIDGE_RETRIES", "4"))

# Paths forwarded upstream. agentty sends the /v1 prefix, so match it both
# with and without it. Anything else 404s so misrouting is loud.
FORWARDED = ("/v1/chat/completions", "/v1/completions", "/v1/embeddings",
             "/v1/models", "/chat/completions", "/completions",
             "/embeddings", "/models")

SKIP_REQ_HEADERS = {"host", "content-length", "authorization", "connection",
                    "accept-encoding", "transfer-encoding"}
SKIP_RES_HEADERS = {"transfer-encoding", "connection", "content-length"}


class Handler(BaseHTTPRequestHandler):
    server_version = "caveman-atria-bridge/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        # Never log headers, bodies, or the key. Path + status only.
        code = args[1] if len(args) > 1 else ""
        sys.stderr.write("[bridge] %s %s\n" % (self.path, code))
        sys.stderr.flush()

    def _target(self):
        path = self.path.split("?", 1)[0]
        for p in FORWARDED:
            if path == p or path.startswith(p + "/"):
                if VIA_GATEWAY:
                    # /v1/chat/completions -> /w/<workflow>/openai/v1/chat/completions
                    return GATEWAY + "/w/" + WORKFLOW + "/openai" + path
                return ATRIA_BASE + path
        return None

    def _proxy(self):
        if not API_KEY and not self.headers.get("Authorization"):
            self._json(503, "bridge has no key and caller sent no Authorization")
            return

        url = self._target()
        if url is None:
            self._json(404, "not forwarded by bridge: %s" % self.path)
            return

        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""

        req = urllib.request.Request(url, data=body, method=self.command)
        # BYOK: forward agentty's own Authorization header when present, so the
        # real Atria key stays in agentty's encrypted store and is never read
        # by the bridge. Falls back to $ATRIA_API_KEY when the caller sent none.
        incoming_auth = self.headers.get("Authorization")
        for k, v in self.headers.items():
            if k.lower() not in SKIP_REQ_HEADERS:
                req.add_header(k, v)
        req.add_header("Authorization", incoming_auth or ("Bearer [REDACTED]" + API_KEY))
        if body and not req.has_header("Content-Type"):
            req.add_header("Content-Type", "application/json")

        streaming = b'"stream":true' in body or b'"stream": true' in body

        # Termux networking drops connections intermittently; retry transient
        # failures before giving up so agentty does not see flakes.
        last = None
        resp = None
        for attempt in range(max(1, RETRIES)):
            try:
                resp = urllib.request.urlopen(req, timeout=TIMEOUT)
                break
            except urllib.error.HTTPError as e:
                # A real upstream HTTP error is a genuine response; pass it on.
                payload = e.read()
                self.send_response(e.code)
                self._copy_headers(e.headers)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            except Exception as e:
                last = e
                if attempt < RETRIES - 1:
                    time.sleep(0.4 * (attempt + 1))
        if resp is None:
            self._json(502, "upstream unreachable: %s" % last)
            return

        self.send_response(resp.status)
        if streaming:
            self._copy_headers(resp.headers)
        else:
            # urllib decodes chunked/gzip, so recompute a real Content-Length;
            # without it HTTP/1.1 keep-alive clients hang waiting for the body.
            payload = resp.read()
            self._copy_headers(resp.headers)
            self.send_header("Content-Length", str(len(payload)))
        self.end_headers()

        if streaming:
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
            self.wfile.write(b"")
            self.wfile.flush()
        else:
            self.wfile.write(payload)

    def _copy_headers(self, src):
        for k, v in src.items():
            if k.lower() not in SKIP_RES_HEADERS:
                self.send_header(k, v)

    def _json(self, code, msg):
        payload = json.dumps({"error": {"message": msg, "type": "bridge_error"}}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = _proxy
    do_POST = _proxy
    do_PUT = _proxy


def main():
    if not API_KEY:
        sys.stderr.write("[bridge] no ATRIA_API_KEY; BYOK callers must send "
                         "Authorization themselves\n")
    via = "gateway %s" % GATEWAY if VIA_GATEWAY else "direct"
    sys.stderr.write("[bridge] listening %s -> %s (%s)\n" % (LISTEN, ATRIA_BASE, via))
    sys.stderr.flush()
    host, port = LISTEN.rsplit(":", 1)
    ThreadingHTTPServer((host, int(port)), Handler).serve_forever()


if __name__ == "__main__":
    main()
