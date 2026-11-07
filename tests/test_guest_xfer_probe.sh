# shellcheck shell=bash
# test_guest_xfer_probe.sh — argument handling of bin/guest-xfer-probe and bin/natpath.
assert_eq "0" "$(bin/guest-xfer-probe --help >/dev/null 2>&1; echo $?)" "guest-xfer-probe --help exits 0"
assert_eq "yes" "$(bin/guest-xfer-probe --help 2>&1 | grep -q '^Usage:' && echo yes)" "guest-xfer-probe --help prints usage"
assert_fails "guest-xfer-probe with no args fails" bin/guest-xfer-probe
assert_fails "guest-xfer-probe unknown guest fails" bin/guest-xfer-probe nope /tmp/x
assert_eq "0" "$(bin/natpath --help >/dev/null 2>&1; echo $?)" "natpath --help exits 0"
assert_fails "natpath bad mode fails" bin/natpath bogus 5000
