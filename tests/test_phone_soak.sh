# shellcheck shell=bash disable=SC2016  # stub bodies are single-quoted on purpose: they expand inside the stub
# phone-soak: parsers for its probe outputs, and the summary of a soak file (tests/fixtures/soak.tsv).
# shellcheck disable=SC1091
source bin/lib.sh
assert_eq "163 derp" "$(ts_ping_result 'pong from pixel-7-podroid (100.64.0.11) via DERP(cn) in 163ms
direct connection not established')" "ts_ping_result: relayed pong"
assert_eq "261 direct" "$(ts_ping_result 'pong from pixel-7 (100.64.0.12) via 192.168.15.141:45410 in 261ms')" "ts_ping_result: direct pong"
assert_eq "- timeout" "$(ts_ping_result 'ping "100.64.0.11" timed out')" "ts_ping_result: no pong"
assert_eq "1234 direct" "$(ts_ping_result 'pong from dokploy (100.64.0.7) via 165.22.145.26:41641 in 1.234s')" "ts_ping_result: latency over a second is printed in seconds"
assert_eq "2000 derp" "$(ts_ping_result 'pong from dokploy (100.64.0.7) via DERP(sfo) in 2s')" "ts_ping_result: whole seconds"
assert_eq "1 direct" "$(ts_ping_result 'pong from pixel-7 (100.64.0.12) via 192.168.15.141:41641 in 850µs')" "ts_ping_result: sub-millisecond rounds to the nearest ms"
assert_eq "805" "$(ping_avg_ms '3 packets transmitted, 3 received, 0% packet loss, time 2003ms
rtt min/avg/max/mdev = 10.123/805.456/1600.789/700.001 ms')" "ping_avg_ms: rounds the average"
assert_eq "-" "$(ping_avg_ms '3 packets transmitted, 0 received, 100% packet loss, time 2003ms')" "ping_avg_ms: all lost"

s=$(bin/phone-soak summary tests/fixtures/soak.tsv)
p7=$(echo "$s" | sed -n '/^pixel-7-podroid/,/^pixel-6/p')
assert_eq "yes" "$(echo "$p7" | grep -q 'rounds 5 (laptop offline 1)' && echo yes)" "soak summary: counts rounds and laptop-offline rounds"
assert_eq "yes" "$(echo "$p7" | grep -q 'max gap 15m' && echo yes)" "soak summary: largest gap between rounds"
assert_eq "yes" "$(echo "$p7" | grep -q 'guest ssh 3/4' && echo yes)" "soak summary: guest ssh ok over laptop-online rounds"
assert_eq "yes" "$(echo "$p7" | grep -q 'android pong 3/4' && echo yes)" "soak summary: android tailnet pongs"
assert_eq "yes" "$(echo "$p7" | grep -q 'dokploy ready 3/4' && echo yes)" "soak summary: dokploy ready"
assert_eq "yes" "$(echo "$p7" | grep -q 'guest->box direct 2/4, relayed 1, timeout 1' && echo yes)" "soak summary: guest to Dokploy box path"
assert_eq "yes" "$(echo "$p7" | grep -q 'lan ms screen off: median 805 max 1600 (n 3); screen on: median 36 max 36 (n 1)' && echo yes)" "soak summary: LAN latency split by screen state"
assert_eq "yes" "$(echo "$p7" | grep -q 'restarts: vm 1, tailscaled 1, watchdog-triggered 1; watchdog dead 1' && echo yes)" "soak summary: VM, tailscaled and watchdog restarts"
assert_eq "yes" "$(echo "$p7" | grep -q '23:05:00 ssh dokploy box' && echo yes)" "soak summary: lists failing rounds with what failed"
p6=$(echo "$s" | sed -n '/^pixel-6-pro-podroid/,$p')
assert_eq "yes" "$(echo "$p6" | grep -q 'restarts: vm 0, tailscaled 0, watchdog-triggered 0; watchdog dead 0' && echo yes)" "soak summary: phones are summarised separately"

# dokploy_validate_state: ready / notready from the body, error-<http code> when the call fails
# (000 = the laptop never got an answer from the Dokploy API; 5xx = Dokploy could not reach the guest)
dv_run() { # <http code> <body> -> dokploy_validate_state output, with curl stubbed
  local d; d=$(mktemp -d)
  printf '#!/bin/bash\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && { printf %%s %q > "$2"; shift; }; shift; done\nprintf %%s %q\n' "$2" "$1" > "$d/curl"
  chmod +x "$d/curl"; DOKPLOY_TOKEN=x PATH="$d:$PATH" dokploy_validate_state SID; rm -rf "$d"
}
assert_eq "ready" "$(dv_run 200 '{"isMainDirectoryInstalled":true,"traefik":{"version":"3.7.16","enabled":true}}')" "dokploy_validate_state: ready"
assert_eq "notready" "$(dv_run 200 '{"isMainDirectoryInstalled":false}')" "dokploy_validate_state: answered but not ready"
assert_eq "error-500" "$(dv_run 500 '{"message":"ssh timeout"}')" "dokploy_validate_state: API error carries the HTTP code"
assert_eq "error-000" "$(dv_run 000 '')" "dokploy_validate_state: no answer from the API"
