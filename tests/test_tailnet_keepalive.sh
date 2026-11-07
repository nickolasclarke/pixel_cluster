# tailnet-keepalive: pings the box; after KEEPALIVE_FAILS consecutive misses, and only if the guest's
# tether gateway has stopped answering too, re-leases DHCP and restarts tailscaled. External
# commands are stubbed on PATH and log their calls.
ka_run() { # name tailscale-stub-body gateway-ping-stub-body -> prints the stub call log
  local d; d=$(mktemp -d); mkdir "$d/bin"
  printf '#!/bin/sh\n%s\n' "$2" > "$d/bin/tailscale"
  printf '#!/bin/sh\n%s\n' "${3:-exit 1}" > "$d/bin/ping"
  printf '#!/bin/sh\necho "default via 172.17.92.210 dev eth0 metric 203"\n' > "$d/bin/ip"
  for c in udhcpc rc-service; do printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$c" "$d" > "$d/bin/$c"; done
  chmod +x "$d/bin/"*; : > "$d/calls"
  STATE="$d/state" KEEPALIVE_INTERVAL=0.05 KEEPALIVE_FAILS=3 PATH="$d/bin:$PATH" timeout 1 guest/tailnet-keepalive 100.64.0.7 >/dev/null 2>&1
  cat "$d/calls"; rm -rf "$d"
}
out=$(ka_run "down" 'exit 1' 'exit 1')
assert_eq "udhcpc" "$(echo "$out" | grep -o '^udhcpc' | head -1)" "keepalive re-leases DHCP when the box and the tether gateway stay unreachable"
assert_eq "rc-service tailscale restart" "$(echo "$out" | grep '^rc-service' | head -1)" "keepalive restarts tailscaled when the box and the tether gateway stay unreachable"
assert_eq "yes" "$([ "$(echo "$out" | grep -c '^udhcpc')" -ge 2 ] && echo yes)" "keepalive keeps retrying recovery while still unreachable"
assert_eq "" "$(ka_run "busy" 'exit 1' 'exit 0')" "keepalive leaves tailscaled alone when only the box ping fails (busy link, gateway answers)"
assert_eq "" "$(ka_run "up" 'exit 0')" "keepalive does nothing while the box answers"
assert_eq "" "$(ka_run "blip" 'n=$(cat "$STATE" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$STATE"; [ "$n" -gt 2 ]')" "keepalive tolerates two consecutive misses"
