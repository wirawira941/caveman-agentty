#!/usr/bin/env sh
# caveman-agentty control script.
#
#   caveman-agentty start     start proxy + bridge, wire agentty, install boot hook
#   caveman-agentty stop      stop both
#   caveman-agentty restart   restart both
#   caveman-agentty status    are they up?
#   caveman-agentty test      self-test of the whole chain
#   caveman-agentty logs      tail bridge + proxy logs
#
# Config lives in ~/.caveman-agentty/config (created on first run).
set -u

HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
CFG_DIR="$HOME_DIR/.caveman-agentty"
CFG="$CFG_DIR/config"
SELF_DIR="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "$CFG_DIR"

# --- defaults (overridable in ~/.caveman-agentty/config) ---------------
PROXY_BIN="$HOME_DIR/.caveman/bin/caveman-proxy"
PROXY_PORT=8787
BRIDGE_PORT=8790
ATRIA_BASE="https://api.atria-asi.ai"
VIA_GATEWAY=1
WORKFLOW=agentty
AGENTTY_SETTINGS="$HOME_DIR/.agentty/settings.json"
BOOT_HOOK="$HOME_DIR/.termux/boot/start-caveman-agentty.sh"

[ -f "$CFG" ] && . "$CFG"

PROXY_URL="http://127.0.0.1:$PROXY_PORT"
BRIDGE_URL="http://127.0.0.1:$BRIDGE_PORT"

log()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- process helpers -----------------------------------------------------
bridge_pids() { ps -ef 2>/dev/null | grep 'atria-bridge.py' | grep -v grep | awk '{print $2}'; }
proxy_pids()  { pgrep -x caveman-proxy 2>/dev/null; }

stop_pids() { for p in $1; do kill -9 "$p" 2>/dev/null || true; done; }

# wait until <url> answers anything that is not a connection failure
wait_up() {  # wait_up <url> <seconds>
  url="$1"; secs="$2"; i=0
  while [ $i -lt $((secs * 2)) ]; do
    code=$(timeout 5 curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
    [ -n "$code" ] && [ "$code" != "000" ] && return 0
    sleep 0.5; i=$((i+1))
  done
  return 1
}

# --- proxy ---------------------------------------------------------------
start_proxy() {
  [ -x "$PROXY_BIN" ] || die "caveman-proxy not found at $PROXY_BIN
run: npm i -g @caveman-ai/cli && caveman setup --install"

  # caveman-proxy is Go built without the cgo resolver, so it uses pure-Go DNS
  # which reads /etc/resolv.conf. Termux has none (/etc is a read-only bind of
  # /system/etc) and lookups fail with "lookup X on [::1]:53: connection refused".
  # /etc and /system/etc cannot be written, so proot bind-mounts a real one.
  ETC="$CFG_DIR/etc"
  mkdir -p "$ETC"
  if [ ! -f "$ETC/resolv.conf" ]; then
    cat > "$ETC/resolv.conf" <<'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
options single-request timeout:5 attempts:2 rotate
EOF
  fi
  [ -f "$ETC/hosts" ] || printf '127.0.0.1 localhost\n::1 ip6-localhost\n' > "$ETC/hosts"

  PROOT="$(command -v proot || true)"
  [ -n "$PROOT" ] || die "proot not installed: pkg install proot"

  stop_pids "$(proxy_pids)"
  sleep 1

  nohup "$PROOT" -b "$ETC:/etc" env \
    CAVEMAN_HOME="$HOME_DIR/.caveman" \
    "$PROXY_BIN" >> "$CFG_DIR/proxy.log" 2>&1 &

  wait_up "$PROXY_URL/health/ready" 12 \
    || die "caveman-proxy did not come up on $PROXY_PORT (see $CFG_DIR/proxy.log)"
  log "caveman-proxy  up  $PROXY_URL"
}

stop_proxy() { stop_pids "$(proxy_pids)"; log "caveman-proxy  down"; }

# --- bridge ---------------------------------------------------------------
start_bridge() {
  stop_pids "$(bridge_pids)"
  sleep 1

  nohup env BRIDGE_LISTEN="127.0.0.1:$BRIDGE_PORT" \
    ATRIA_BASE="$ATRIA_BASE" \
    BRIDGE_VIA_GATEWAY="$VIA_GATEWAY" \
    CAVE_GATEWAY_URL="$PROXY_URL" \
    CAVE_WORKFLOW="$WORKFLOW" \
    ${ATRIA_API_KEY:+ATRIA_API_KEY="$ATRIA_API_KEY"} \
    python3 "$SELF_DIR/bin/atria-bridge.py" >> "$CFG_DIR/bridge.log" 2>&1 &

  # the bridge returns its own 503 when it has no key; either proves it is live
  wait_up "$BRIDGE_URL/v1/models" 12 \
    || die "atria-bridge did not come up on $BRIDGE_PORT (see $CFG_DIR/bridge.log)"
  log "atria-bridge  up  $BRIDGE_URL"
}

stop_bridge() { stop_pids "$(bridge_pids)"; log "atria-bridge  down"; }

# --- agentty provider -------------------------------------------------------
wire_agentty() {
  [ -f "$AGENTTY_SETTINGS" ] || { log "agentty settings not found; skipping wiring"; return 0; }
  python3 - "$AGENTTY_SETTINGS" "$BRIDGE_URL" <<'PYEOF'
import json, os, sys
path, base = sys.argv[1], sys.argv[2]  # noqa: E501
target = base + "/v1"
raw = open(path).read()
s = json.loads(raw)
old = s.get("provider")
if old == target:
    print("agentty      already wired to " + target)
    sys.exit(0)

# snapshot the untouched original exactly once, before any write
bak = path + ".bak"
if not os.path.exists(bak):
    with open(bak, "w") as f:
        f.write(raw)

def fix(v):
    return target if v == old else v

s["provider"] = target
if isinstance(s.get("provider_models"), dict):
    s["provider_models"] = {fix(k): v for k, v in s["provider_models"].items()}
if isinstance(s.get("recent_models"), list):
    s["recent_models"] = [
        (target + "\t" + m.split("\t", 1)[-1]) if m.split("\t", 1)[0] == old else m
        for m in s["recent_models"]]

with open(path, "w") as f:
    json.dump(s, f, indent=2)
print("agentty      wired " + str(old) + " -> " + target + "  (backup: " + bak + ")")
PYEOF
}

# --- agentty env ---------------------------------------------------------------
# agentty rewrites settings.json on every startup and clobbers any provider
# edit, so the durable wiring is an env var read from .bashrc instead.
install_env_var() {
  BASHRC="$HOME_DIR/.bashrc"
  MARKER="# caveman-agentty bridge"
  LINE="export AGENTTY_API_HOST=\"http://127.0.0.1:$BRIDGE_PORT\""

  [ -f "$BASHRC" ] || touch "$BASHRC"
  if grep -qF "$MARKER" "$BASHRC" 2>/dev/null; then
    # keep the line current if the port changed
    python3 - "$BASHRC" "$LINE" "$MARKER" <<'PYEOF'
import sys
path, line, marker = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read().splitlines()
out = [line if marker in s and s.lstrip().startswith("export AGENTTY_API_HOST")
       else s for s in src]
open(path, "w").write("\n".join(out) + "\n")
PYEOF
    log "env var       AGENTTY_API_HOST already set"
    return 0
  fi

  printf '\n%s\nexport AGENTTY_API_HOST="http://127.0.0.1:%s"\n' \
    "$MARKER" "$BRIDGE_PORT" >> "$BASHRC"
  log "env var       AGENTTY_API_HOST set in $BASHRC"
  log "                open a new shell (or: source ~/.bashrc) for it to take effect"
}

# --- boot hook ---------------------------------------------------------------
install_boot() {
  d="$(dirname "$BOOT_HOOK")"
  mkdir -p "$d" 2>/dev/null || return 0
  cat > "$BOOT_HOOK" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
# started by Termux:Boot. Restores the Caveman measurement stack for agentty.
set -u
exec "$SELF_DIR/bin/caveman-agentty.sh" start >/dev/null 2>&1
EOF
  chmod +x "$BOOT_HOOK" 2>/dev/null || true
  log "boot hook     installed $BOOT_HOOK"
}

# --- commands ----------------------------------------------------------------
cmd_start() {
  # agentty ships a non-PIE binary that Android 11 refuses to execute; repair
  # it first so the stack has something to talk to.
  sh "$SELF_DIR/bin/fix-agentty-pie.sh" || log "warning: agentty PIE fix skipped"

  start_proxy
  start_bridge
  wire_agentty
  install_env_var
  install_boot
  log ""
  log "chain:  agentty -> bridge :$BRIDGE_PORT -> proxy :$PROXY_PORT -> Atria"
  log "check:  $SELF_DIR/bin/caveman-agentty.sh status"
}

cmd_stop()  { stop_bridge; stop_proxy; }
cmd_restart(){ cmd_stop; cmd_start; }

cmd_status() {
  pc=$(timeout 5 curl -s -o /dev/null -w '%{http_code}' "$PROXY_URL/health/ready" 2>/dev/null || true)
  bc=$(timeout 5 curl -s -o /dev/null -w '%{http_code}' "$BRIDGE_URL/v1/models" 2>/dev/null || true)
  [ "$pc" = "200" ] && ps="up"   || ps="down"
  [ "$bc" = "000" ] && bs="down" || bs="up"
  log "caveman-proxy  :$PROXY_PORT  $ps  (health=$pc)"
  log "atria-bridge  :$BRIDGE_PORT  $bs  (code=$bc)"
  if [ "$ps" = "up" ] && [ "$bs" = "up" ]; then
    log "status: OK"
    exit 0
  fi
  log "status: DEGRADED"
  exit 1
}

cmd_logs() {
  for f in "$CFG_DIR/bridge.log" "$CFG_DIR/proxy.log"; do
    if [ -f "$f" ]; then
      log "=== $f ==="
      tail -n "${1:-20}" "$f"
    fi
  done
}

cmd_test() {
  sh "$SELF_DIR/bin/fix-agentty-pie.sh" >/dev/null 2>&1 || true
  sh "$SELF_DIR/test/verify.sh"
}

case "${1:-help}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_restart ;;
  status)  cmd_status ;;
  logs)    shift; cmd_logs "${1:-20}" ;;
  test)    cmd_test ;;
  *)
    log "usage: caveman-agentty {start|stop|restart|status|logs|test}"
    log "config: $CFG"
    exit 2 ;;
esac
