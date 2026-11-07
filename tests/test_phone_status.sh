# shellcheck shell=bash
# phone-status with adb, tailscale and curl stubbed: one attached Pixel 7 (pins/phones names it
# pixel-7-podroid), tailnet state from tests/fixtures/ts-status.json, servers from dokploy-servers.json.
ps_run() { # <tailscale status json> -> phone-status stdout, then "rc=<exit code>"
  local d out rc; d=$(mktemp -d); mkdir "$d/bin"
  cat > "$d/bin/adb" <<STUB
#!/bin/bash
case "\$*" in
  devices) printf 'List of devices attached\n28161FDH200LY1\tdevice\n' ;;
  *"getprop ro.serialno"*) echo 28161FDH200LY1 ;;
  *"getprop ro.product.model"*) echo "Pixel 7" ;;
  *"dumpsys package com.tailscale.ipn"*) echo "    versionName=$(sed 's/^v//' pins/tailscale.version)" ;;
  *"dumpsys package com.excp.podroid"*) echo "    versionName=$(sed 's/^v//' pins/podroid.version)" ;;
  *charge_optimization_mode*) echo 1 ;;
  *) exit 1 ;;
esac
STUB
  printf '#!/bin/bash\ncat %q\n' "$1" > "$d/bin/tailscale"
  printf '#!/bin/bash\ncat %q\n' "$PWD/tests/fixtures/dokploy-servers.json" > "$d/bin/curl"
  chmod +x "$d/bin/"*
  out=$(DOKPLOY_TOKEN=x LOG_FILE="$d/log" PATH="$d/bin:$PATH" timeout 20 bin/phone-status 2>&1); rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"; rm -rf "$d"
}
r=$(ps_run tests/fixtures/ts-status.json)
assert_eq "yes" "$(echo "$r" | grep -q 'node:online android-node:online' && echo yes)" "phone-status shows the guest node and the phone's Android node"
assert_eq "rc=0" "$(echo "$r" | tail -1)" "phone-status passes when both nodes are online"
off=$(mktemp); python3 -I - tests/fixtures/ts-status.json "$off" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
for p in s["Peer"].values():
    if p["DNSName"].startswith("pixel-7."): p["Online"] = False
json.dump(s, open(sys.argv[2], "w"))
PY
r=$(ps_run "$off"); rm -f "$off"
assert_eq "yes" "$(echo "$r" | grep -q 'android-node:offline' && echo yes)" "phone-status reports an offline Android node"
assert_eq "rc=1" "$(echo "$r" | tail -1)" "phone-status fails when the Android node is offline (no adb over the tailnet)"
