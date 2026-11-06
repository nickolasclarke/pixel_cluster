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
