# shellcheck shell=bash
# adb_network_enable: a USB provisioning run leaves the phone listening for adb on :5555, because a
# phone reboot drops `adb tcpip` and USB is otherwise the only way back in. adb is stubbed.
# shellcheck disable=SC1091
source bin/lib.sh
ne_run() { # <target> <current service.adb.tcp.port> -> "<function output>|<stub adb call log>"
  local d out; d=$(mktemp -d); mkdir "$d/bin"; : > "$d/calls"
  cat > "$d/bin/adb" <<STUB
#!/bin/bash
echo "\$*" >> "$d/calls"
case "\$*" in
  *"getprop service.adb.tcp.port"*) echo "$2" ;;
esac
exit 0
STUB
  chmod +x "$d/bin/adb"
  out=$(PATH="$d/bin:$PATH" adb_network_enable "$1" 5555 2>&1)
  echo "$out|$(tr "\n" ";" < "$d/calls")"; rm -rf "$d"
}
r=$(ne_run 28161FDH200LY1 "")
assert_eq "yes" "$(echo "$r" | grep -q -- '-s 28161FDH200LY1 tcpip 5555' && echo yes)" "network adb: USB target with adb off gets tcpip 5555"
assert_eq "yes" "$(echo "$r" | grep -q -- 'tcpip 5555;-s 28161FDH200LY1 wait-for-disconnect;-s 28161FDH200LY1 wait-for-device' && echo yes)" "network adb: waits for the old USB transport to drop, then for the new one (wait-for-device alone returns on the stale one)"
assert_eq "network adb on :5555" "${r%%|*}" "network adb: reports the port it enabled"
r=$(ne_run 28161FDH200LY1 "5555")
assert_eq "0" "$(echo "$r" | grep -c tcpip)" "network adb: already listening on 5555 leaves adbd alone"
assert_eq "network adb already on :5555" "${r%%|*}" "network adb: reports when it was already on"
r=$(ne_run 100.64.0.13:5555 "5555")
assert_eq "0" "$(echo "$r" | grep -c tcpip)" "network adb: a host:port target is already network adb"
