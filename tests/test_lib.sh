# shellcheck shell=bash
# test_lib.sh — sourced by tests/run.sh; tests for bin/lib.sh pure functions.
# shellcheck disable=SC1091
source bin/lib.sh

assert_eq "1.104.5" "$(tailscale_latest_version tests/fixtures/tailscale-index.html)" "tailscale version parse"
assert_fails "tailscale no match exits 1" tailscale_latest_version /dev/null

assert_eq "v1.2.9 Podroid-v1.2.9-release.apk 3945c8c887f1df239501de6320fe5c8315bf9805029f530373d3244fee0d2a5f" \
  "$(podroid_latest tests/fixtures/podroid-release.json)" "podroid latest parse"
assert_fails "podroid no asset exits 1" podroid_latest /dev/null

tmp=$(mktemp -d)
printf 'hello\n' > "$tmp/good"
good_sum=$(sha256sum "$tmp/good" | cut -c1-64)
verify_sha256 "$tmp/good" "$good_sum"; assert_eq "0" "$?" "verify_sha256 passes on match"
assert_eq "yes" "$([ -f "$tmp/good" ] && echo yes)" "verify_sha256 keeps good file"
cp "$tmp/good" "$tmp/bad"; printf 'x' | dd of="$tmp/bad" bs=1 seek=1 conv=notrunc 2>/dev/null
assert_fails "verify_sha256 fails on mismatch" verify_sha256 "$tmp/bad" "$good_sum"
assert_eq "gone" "$([ -f "$tmp/bad" ] || echo gone)" "verify_sha256 deletes mismatched file"
rm -rf "$tmp"

# --- Task 3: phone-provision helpers ---
assert_eq "33" "$(parse_version_code "$(grep -m1 versionCode=33 tests/fixtures/pm-dump.txt)")" "parse_version_code"
assert_eq "" "$(parse_version_code "")" "parse_version_code empty when not installed"

assert_eq "pixel-7-podroid" "$(phone_node_name "Pixel 7" 28161FDH200LY1 tests/fixtures/phones)" "node name: known serial keeps its name"
assert_eq "pixel-7-podroid-ABCD" "$(phone_node_name "Pixel 7" ZZZZZZZZZZZABCD tests/fixtures/phones)" "node name: second Pixel 7 gets serial suffix"
assert_eq "pixel-6-pro-podroid" "$(phone_node_name "Pixel 6 Pro" 1234567890ABCDEF tests/fixtures/phones)" "node name: new model, no collision"

assert_eq "100.64.0.9" "$(node_ip_by_hostname tests/fixtures/ts-status.json pixel-7-podroid)" "node ip by hostname"
assert_fails "node ip unknown hostname exits 1" node_ip_by_hostname tests/fixtures/ts-status.json no-such-node

assert_eq "3RzoxeV75giJGcgX3ueCM" "$(find_server_id tests/fixtures/dokploy-servers.json pixel-7-podroid)" "find_server_id existing"
assert_eq "" "$(find_server_id tests/fixtures/dokploy-servers.json nope)" "find_server_id unknown is empty"

# --- Task 4: phone-status helpers ---
assert_eq "1.2.9" "$(parse_version_name "$(cat tests/fixtures/pm-dump.txt)")" "parse_version_name"
assert_eq "yes" "$(version_matches_pin 1.2.9 v1.2.9)" "version matches pin with v prefix"
assert_eq "no" "$(version_matches_pin 1.2.8 v1.2.9)" "version behind pin"
assert_eq "online" "$(node_state tests/fixtures/ts-status.json pixel-7-podroid)" "node_state online"
assert_eq "none" "$(node_state tests/fixtures/ts-status.json no-such)" "node_state none"
assert_eq "yes" "$(version_matches_pin 1.104.5-t788384763-gd8673104f 1.104.5)" "version matches pin ignoring build suffix"

# --- final review: duplicate / stale nodes ---
python3 -I - <<'PY'
import json
s=json.load(open("tests/fixtures/ts-status.json"))
dead={"HostName":"pixel-7-podroid","DNSName":"pixel-7-podroid-1.tn.nclar.ke.","TailscaleIPs":["100.64.0.42"],"Online":False}
s["Peer"]["dead"]=dead
json.dump(s,open("tests/fixtures/ts-status-dup.json","w"))
PY
assert_eq "100.64.0.9" "$(node_ip_by_hostname tests/fixtures/ts-status-dup.json pixel-7-podroid)" "node ip: DNS label wins over a stale duplicate HostName"
assert_eq "100.64.0.42" "$(node_ip_by_hostname tests/fixtures/ts-status-dup.json pixel-7-podroid-1)" "node ip: suffixed label is addressable"
assert_eq "none" "$(node_state tests/fixtures/ts-status-dup.json pixel-7-podroid-2)" "node_state: HostName alone does not match"
