# shellcheck shell=bash
# phone-soak: parsers for its probe outputs, and the summary of a soak file (tests/fixtures/soak.tsv).
# shellcheck disable=SC1091
source bin/lib.sh
assert_eq "163 derp" "$(ts_ping_result 'pong from pixel-7-podroid (100.64.0.11) via DERP(cn) in 163ms
direct connection not established')" "ts_ping_result: relayed pong"
assert_eq "261 direct" "$(ts_ping_result 'pong from pixel-7 (100.64.0.12) via 192.168.15.141:45410 in 261ms')" "ts_ping_result: direct pong"
assert_eq "- timeout" "$(ts_ping_result 'ping "100.64.0.11" timed out')" "ts_ping_result: no pong"
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
