# caveman-agentty

Caveman (local LLM spend observability) wired into **agentty** on **Termux**
(Android, aarch64). Every turn agentty sends is measured — tokens, latency,
bytes, cost estimate — with no change to what the model receives.

```
agentty  ->  bridge :8790  ->  caveman-proxy :8787  ->  Atria
             (atria-bridge.py)     (measures + records)
```

## Quick start

```sh
git clone git@github.com:wirawira941/caveman-agentty.git
cd caveman-agentty

# prerequisites
pkg install proot python curl
npm i -g @caveman-ai/cli && caveman setup --install

# start it, wire agentty, install the boot hook
sh bin/caveman-agentty.sh start

# prove the whole chain works
sh bin/caveman-agentty.sh test
```

That's it. agentty's provider is repointed at the bridge, the backup of its
original settings lands at `~/.agentty/settings.json.bak`, and the stack
restarts itself at every Termux boot.

## Commands

| command | effect |
| --- | --- |
| `start` | start proxy + bridge, wire agentty, install boot hook |
| `stop` | stop both |
| `restart` | stop + start |
| `status` | are they up? (exits non-zero if degraded) |
| `test` | self-test of every link in the chain |
| `logs [n]` | tail both logs |

Config lives at `~/.caveman-agentty/config` — override ports, the Atria base
URL, or the workflow slug there.

## Why the bridge exists

Caveman's gateway has a **fixed** set of upstream providers — openai,
anthropic, gemini, bedrock, vertex, azure, kimi — and `api.openai.com` is
hardcoded for the OpenAI route. Atria (`api.atria-asi.ai`) is not one of them.

Both config knobs that look like they should add a provider were tested and
do not work:

- `providers.<name>.base_url` — parses, but does not change routing
- `compat_upstreams` — parses, but `/w/agentty/<name>/...` still 404s

So the bridge sends Atria traffic through the gateway's `openai` route to get
the measurement. The gateway forwards to `api.openai.com` and gets a 4xx back
for an Atria-only model — that is expected and irrelevant. The token, latency,
and byte accounting is the point; the response itself is discarded by the
bridge and replaced with Atria's real one.

Actually the bridge forwards the request to the gateway and returns the
gateway's response to agentty. The gateway records the measurement on the way
through. Set `BRIDGE_VIA_GATEWAY=0` to have the bridge talk to Atria directly
(no measurement, useful for isolating a fault).

agentty sends its own `Authorization` header (BYOK), which the bridge forwards
unchanged — the real Atria key never leaves agentty's encrypted credential
store and is never logged.

## Why proot is required

`caveman-proxy` is Go built **without** the cgo resolver, so it uses Go's
pure-Go DNS, which reads `/etc/resolv.conf`. Termux has none — `/etc` is a
read-only bind of `/system/etc` — and every lookup fails with:

```
lookup api.openai.com on [::1]:53: read udp [::1]:53: connection refused
```

`/etc` and `/system/etc` are both read-only, and Bionic ignores Termux's
`$PREFIX/etc/hosts` (verified). `proot -b <dir>:/etc` bind-mounting a real
`resolv.conf` is the only thing that fixes it. The control script does this
for you.

## What the self-test checks

`sh bin/caveman-agentty.sh test` needs no provider key and verifies each link:

1. `proot` is installed
2. `caveman-proxy` answers on `:8787`
3. the proxy has working DNS (it reaches a real upstream host)
4. the bridge is live on `:8790`
5. the bridge forwards upstream (a bogus key → a genuine 4xx from Atria)
6. the request was measured (`x-cave-request-id` present)
7. agentty's provider points at the bridge
8. requests are accumulating in `caveman.db`

Check 3 is the regression test for the Termux DNS problem; if it fails with a
502 the proot bind is no longer in effect.

## Files

| path | role |
| --- | --- |
| `bin/atria-bridge.py` | OpenAI-compat bridge; agentty's provider target |
| `bin/caveman-agentty.sh` | control script (start/stop/status/test) |
| `test/verify.sh` | self-test |

Runtime state lands in `~/.caveman-agentty/` (config, logs, the proot `/etc`).

## Rolling back

```sh
sh bin/caveman-agentty.sh stop
cp ~/.agentty/settings.json.bak ~/.agentty/settings.json
```

agentty talks to Atria directly again, exactly as before.

## Notes

- `caveman login` is not involved — local measurement needs no account. A
  Cloud account adds the dashboard, not local recording.
- Rows in `caveman.db` show `provider=openai` (the route used) with the model
  agentty actually sent (`Atria-Dawn-Preview`).
- Termux networking drops connections intermittently; the bridge retries
  transient failures so agentty does not see flakes.
