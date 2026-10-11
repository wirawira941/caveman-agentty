#!/usr/bin/env sh
# Self-test for the caveman-agentty chain.
#
# Verifies each link independently, needs no provider key:
#   1. proot is installed          (caveman-proxy cannot do DNS without it)
#   2. caveman-proxy answers       (and the resolv.conf fix worked)
#   3. the bridge is live          (its own 503 proves it is serving)
#   4. the bridge forwards upstream (a bogus key -> a real 4xx from Atria)
#   5. agentty is wired to the bridge
#
# The link-4 check only passes if DNS works end to end, so this is also the
# regression test for the Termux /etc/resolv.conf problem.
set -u

HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
CFG_DIR="$HOME_DIR/.caveman-agentty"
SELF_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ -f "$CFG_DIR/config" ]; then
  . "$CFG_DIR/config"
fi
PROXY_PORT="${PROXY_PORT:-8787}"
BRIDGE_PORT="${BRIDGE_PORT:-8790}"
WORKFLOW="${WORKFLOW:-agentty}"
AGENTTY_SETTINGS="${AGENTTY_SETTINGS:-$HOME_DIR/.agentty/settings.json}"
PROXY_URL="http://127.0.0.1:$PROXY_PORT"
BRIDGE_URL="http://127.0.0.1:$BRIDGE_PORT"

PASS=0; FAIL=0
ok()   { printf '  \033[32mpass\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mfail\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '         %s\n' "$1"; }

get() { timeout 10 curl -s -o "$2" -w '%{http_code}' "$1" 2>/dev/null || echo 000; }

# 0. agentty itself launches (a non-PIE build dies with e_type: 2 on Android 11)
if timeout 10 /data/data/com.termux/files/usr/bin/agentty --version >/dev/null 2>&1; then
  ok "agentty launches ($(timeout 10 /data/data/com.termux/files/usr/bin/agentty --version 2>&1 | head -1))"
else
  bad "agentty does not launch (non-PIE binary)"
  info "fix: sh $SELF_DIR/bin/fix-agentty-pie.sh"
fi

post() { timeout 12 curl -s -o "$3" -D "$4" -w '%{http_code}' -X POST \
           -H "Content-Type: application/json" -H "Authorization: Bearer [REDACTED]" \
           -d "$2" "$1" 2>/dev/null || echo 000; }

T="$(mktemp -d 2>/dev/null)"
[ -n "$T" ] && [ -d "$T" ] || T="$HOME_DIR/.caveman-agentty/verify.d"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

log ""
log "== caveman-agentty self-test =="

# 1. proot
command -v proot >/dev/null 2>&1 && ok "proot installed" \
  || { bad "proot missing: pkg install proot"; }

# 2. proxy
code=$(get "$PROXY_URL/health/ready" "$T/proxy.json")
if [ "$code" = "200" ]; then
  ok "caveman-proxy up on :$PROXY_PORT (health 200)"
else
  bad "caveman-proxy not answering (code=$code)"
  info "run: $SELF_DIR/bin/caveman-agentty.sh start"
fi

# does the proxy have working DNS? ask it to reach an upstream host; any real
# HTTP status means it resolved + connected, a 502 means DNS failed again
dcode=$(get "$PROXY_URL/w/$WORKFLOW/openai/v1/models" "$T/dns.json")
if [ "$dcode" = "000" ]; then
  bad "proxy unreachable (no DNS?)"
  info "if 'lookup X on [::1]:53' appears in the log, proot resolv.conf bind failed"
elif [ "$dcode" = "502" ]; then
  bad "proxy has no DNS (502 upstream unreachable)"
  info "the proot /etc bind is not in effect; restart with the control script"
else
  ok "proxy DNS works (upstream returned $dcode)"
fi

# 3. bridge live
code=$(get "$BRIDGE_URL/v1/models" "$T/bridge.json")
if [ "$code" = "000" ]; then
  bad "atria-bridge not answering on :$BRIDGE_PORT"
else
  ok "atria-bridge live on :$BRIDGE_PORT (code $code)"
fi

# 4. bridge forwards upstream (Termux networking drops connections
#    intermittently, so this retries before declaring failure)
if [ "$code" != "000" ]; then
  code=000
  attempt=0
  while [ "$code" = "000" ] && [ $attempt -lt 3 ]; do
    attempt=$((attempt+1))
    code=$(post "$BRIDGE_URL/v1/chat/completions" \
      '{"model":"Atria-Dawn-Preview","messages":[{"role":"user","content":"ping"}],"max_tokens":5}' \
      "$T/chat.json" "$T/chat.hdr")
    [ "$code" = "000" ] && [ $attempt -lt 3 ] && sleep 1
  done
  if [ "$code" = "000" ]; then
    bad "bridge could not complete an upstream request"
    info "transient on this network; re-run the test"
  elif [ "$code" = "401" ] || [ "$code" = "403" ] || [ "$code" = "404" ]; then
    ok "bridge forwards upstream (bogus key -> HTTP $code, as expected)"
    grep -qi 'x-cave-request-id' "$T/chat.hdr" 2>/dev/null \
      && ok "request was measured by caveman (x-cave-request-id present)" \
      || info "no x-cave-request-id (BRIDGE_VIA_GATEWAY=0?)"
  elif [ "$code" = "200" ]; then
    bad "bogus key was accepted -- upstream is not real Atria"
  else
    bad "unexpected upstream response HTTP $code"
    info "body: $(head -c 200 "$T/chat.json" 2>/dev/null)"
  fi
fi

# 5. agentty wired
if [ -f "$AGENTTY_SETTINGS" ]; then
  cur=$(python3 -c "
import json, os, sys
settings = sys.argv[1]
env = os.environ.get('AGENTTY_API_HOST', '').rstrip('/')
if not env.endswith('/v1'):
    env += '/v1'
# The env var wins: agentty rewrites settings.json on startup and clobbers
# any provider edit, so the settings file alone is not authoritative.
print(env if os.environ.get('AGENTTY_API_HOST') else
      json.load(open(settings)).get('provider'))
" "$AGENTTY_SETTINGS" 2>/dev/null)
  want="http://127.0.0.1:$BRIDGE_PORT/v1"
  if [ "$cur" = "$want" ]; then
    ok "agentty provider -> bridge ($want)"
  else
    bad "agentty provider is '$cur', expected '$want'"
    info "run: $SELF_DIR/bin/caveman-agentty.sh start"
  fi
else
  bad "agentty settings not found at $AGENTTY_SETTINGS"
fi

# 6. recorded requests
DB="$HOME_DIR/.caveman/caveman.db"
if [ -f "$DB" ]; then
  n=$(python3 -c "
import sqlite3
try: print(sqlite3.connect('$DB').execute('select count(*) from requests').fetchone()[0])
except Exception: print(0)
" 2>/dev/null)
  [ "${n:-0}" -gt 0 ] \
    && ok "$n requests recorded in caveman.db" \
    || info "no requests recorded yet (nothing has been measured)"
fi

log ""
log "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ] && log "ALL CHECKS PASSED" || log "some checks failed"
[ "$FAIL" -eq 0 ]
