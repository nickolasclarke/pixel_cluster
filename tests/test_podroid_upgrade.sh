# shellcheck shell=bash disable=SC2016  # stub bodies are single-quoted on purpose: they expand inside the stub
# podroid-upgrade with adb, ssh, curl and sleep stubbed. The stubs share state files in $S: vm (running|
# stopped), ver (installed versionName), and flags that make one step misbehave. Every stub call is
# logged to $S/calls in order.
pu_run() { # [flag files to create...] -> sets PU_OUT (script output), PU_RC (exit code), PU_CALLS (call log)
  local S; S=$(mktemp -d); export S; mkdir "$S/bin" "$S/apks" "$S/backups"
  echo running > "$S/vm"; echo 1.2.9 > "$S/ver"
  printf 'hermes-1\ntraefik\n' > "$S/containers"
  touch "$S/apks/Podroid-v1.3.0-release.apk"
  for f in "$@"; do touch "$S/$f"; done
  [ -e "$S/already_current" ] && echo 1.3.0 > "$S/ver"
  [ -e "$S/no_apk" ] && rm "$S/apks/Podroid-v1.3.0-release.apk"
  cat > "$S/bin/adb" <<'STUB'
#!/bin/bash
echo "adb $*" >> "$S/calls"
case "$*" in
  *get-state*) echo device ;;
  *"getprop ro.serialno"*) echo 28161FDH200LY1 ;;
  *"forward tcp:0 tcp:9922"*) echo 40000 ;;
  *"forward --remove"*) ;;
  *"dumpsys package com.excp.podroid"*) echo "    versionCode=33 minSdk=26"; echo "    versionName=$(cat "$S/ver")" ;;
  *"content call"*) echo "Result: Bundle[{result=ok vm=$(cat "$S/vm") backend=avf selection=AUTO stage=Ready vc=33}]" ;;
  *STOP_VM*) [ -e "$S/stop_ignored" ] || echo stopped > "$S/vm" ;;
  *START_VM*) echo running > "$S/vm" ;;
  *" install -r "*) [ -e "$S/install_fails" ] && exit 1; echo 1.3.0 > "$S/ver" ;;
  *podroid-watchdog.pause*) ;;
  *) exit 1 ;;
esac
STUB
  cat > "$S/bin/ssh" <<'STUB'
#!/bin/bash
cmd="${*: -1}"
echo "ssh $cmd" >> "$S/calls"
[ "$(cat "$S/vm")" = running ] || exit 255
case "$cmd" in
  true) ;;
  "uname -r") [ "$(cat "$S/ver")" = 1.3.0 ] && echo 7.3.0 || echo 7.1.5 ;;
  *"docker ps"*)
    if [ "$(cat "$S/ver")" = 1.3.0 ] && [ -e "$S/container_lost" ]; then echo traefik; else cat "$S/containers"; fi ;;
  *"rc-service docker"*) ;;
  *"tar "*) printf 'volume data' | gzip ;;
  *) exit 1 ;;
esac
STUB
  cat > "$S/bin/curl" <<'STUB'
#!/bin/bash
echo "curl ${*: -1}" >> "$S/calls"
case "$*" in
  *server.all*) echo '[{"name":"pixel-7-podroid","serverId":"SID7"}]' ;;
  *server.validate*)
    n=$(cat "$S/validate_calls" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$S/validate_calls"
    if [ -e "$S/dokploy_late" ] && [ "$n" -le 2 ] || [ -e "$S/dokploy_never" ]; then printf 400; exit 0; fi
    out=""; prev=""; for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done
    echo '{"isMainDirectoryInstalled":true,"traefik":{"version":"3.6.25","enabled":true}}' > "$out"; printf 200 ;;
  *) exit 1 ;;
esac
STUB
  printf '#!/bin/sh\nexit 0\n' > "$S/bin/sleep"
  chmod +x "$S/bin/"*; : > "$S/calls"
  PU_OUT=$(PODROID_PIN=v1.3.0 APK_DIR="$S/apks" LOG_FILE="$S/log" DOKPLOY_TOKEN=t PATH="$S/bin:$PATH" \
    STOP_TIMEOUT=3 BOOT_TIMEOUT=3 CONTAINER_TIMEOUT=3 DOKPLOY_TIMEOUT=15 timeout 20 bin/podroid-upgrade 10.9.8.7:5555 ${PU_BACKUP:+--backup-volumes "$S/backups"} 2>&1)
  PU_RC=$?
  PU_CALLS=$(cat "$S/calls")
  PU_BACKUPS=$(cd "$S/backups" && for f in *; do [ -e "$f" ] && echo "$f $(stat -c %a "$f") $(gzip -dc "$f")"; done)
  rm -rf "$S"
}
order_of() { # <pattern> -> line number of the first call matching it in PU_CALLS, or 0
  local n; n=$(echo "$PU_CALLS" | grep -n -m1 -- "$1" | cut -d: -f1); echo "${n:-0}"
}

pu_run
assert_eq "0" "$PU_RC" "upgrade succeeds when every step works"
assert_eq "yes" "$([ "$(order_of 'touch /data/local/tmp/podroid-watchdog.pause')" -gt 0 ] \
  && [ "$(order_of 'touch /data/local/tmp/podroid-watchdog.pause')" -lt "$(order_of 'rc-service docker stop')" ] \
  && [ "$(order_of 'rc-service docker stop')" -lt "$(order_of 'STOP_VM')" ] \
  && [ "$(order_of 'STOP_VM')" -lt "$(order_of ' install -r ')" ] \
  && [ "$(order_of ' install -r ')" -lt "$(order_of 'START_VM')" ] && echo yes)" \
  "upgrade pauses the watchdog, stops docker, stops the VM, installs, then starts the VM, in that order"
assert_eq "yes" "$(echo "$PU_CALLS" | grep -q 'STOP_VM -n com.excp.podroid/.service.VmControlReceiver' && echo yes)" \
  "upgrade stops the VM with the broadcast addressed to Podroid's receiver"
assert_eq "yes" "$(echo "$PU_CALLS" | grep -q 'install -r .*/apks/Podroid-v1.3.0-release.apk' && echo yes)" \
  "upgrade installs the pinned APK in place"
assert_eq "yes" "$(echo "$PU_CALLS" | tail -5 | grep -q 'rm -f /data/local/tmp/podroid-watchdog.pause' && echo yes)" \
  "upgrade unpauses the watchdog at the end"
assert_eq "yes" "$(echo "$PU_OUT" | grep -q '1.2.9 -> 1.3.0' && echo "$PU_OUT" | grep -q '7.1.5 -> 7.3.0' && echo yes)" \
  "upgrade reports the Podroid and guest kernel versions before and after"
assert_eq "yes" "$(echo "$PU_OUT" | grep -q 'containers back: 2/2' && echo "$PU_OUT" | grep -q 'dokploy: ready' && echo yes)" \
  "upgrade reports the containers that came back and Dokploy's view of the server"

PU_BACKUP=1 pu_run
assert_eq "0" "$PU_RC" "upgrade with --backup-volumes succeeds"
assert_eq "yes" "$(echo "$PU_BACKUPS" | grep -qE '^pixel-7-podroid-[0-9]{8}-[0-9]{6}-volumes\.tar\.gz 600 volume data$' && echo yes)" \
  "--backup-volumes saves the guest's docker volumes, owner-only, named after the node"
assert_eq "yes" "$([ "$(order_of 'rc-service docker stop')" -lt "$(order_of 'tar ')" ] \
  && [ "$(order_of 'tar ')" -lt "$(order_of 'STOP_VM')" ] && echo yes)" \
  "--backup-volumes copies the volumes while docker is stopped and before the VM stops"
pu_run
assert_eq "" "$PU_BACKUPS" "a run without --backup-volumes saves nothing"

pu_run already_current
assert_eq "0" "$PU_RC" "upgrade on a phone already at the pin succeeds"
assert_eq "0" "$(echo "$PU_CALLS" | grep -cE 'STOP_VM|install -r|docker stop|watchdog.pause')" \
  "upgrade on a phone already at the pin touches nothing"

pu_run no_apk
assert_eq "yes" "$([ "$PU_RC" -ne 0 ] && echo "$PU_OUT" | grep -q 'bin/apk-fetch' && echo yes)" \
  "upgrade without the pinned APK fails and points at bin/apk-fetch"
assert_eq "0" "$(echo "$PU_CALLS" | grep -cE 'STOP_VM|docker stop|watchdog.pause')" \
  "upgrade without the pinned APK stops nothing"

pu_run stop_ignored
assert_eq "yes" "$([ "$PU_RC" -ne 0 ] && echo "$PU_OUT" | grep -qi 'did not stop' && echo yes)" \
  "upgrade fails when the VM does not stop"
assert_eq "0" "$(echo "$PU_CALLS" | grep -c 'install -r')" "upgrade installs nothing while the VM is still running"
assert_eq "yes" "$(echo "$PU_CALLS" | grep -q 'rc-service docker start' && echo yes)" \
  "upgrade starts docker again when the VM did not stop"
assert_eq "yes" "$(echo "$PU_CALLS" | tail -3 | grep -q 'rm -f /data/local/tmp/podroid-watchdog.pause' && echo yes)" \
  "upgrade unpauses the watchdog when the VM did not stop"

pu_run install_fails
assert_eq "yes" "$([ "$PU_RC" -ne 0 ] && echo "$PU_OUT" | grep -qi 'install failed' && echo yes)" \
  "upgrade fails when the install fails"
assert_eq "yes" "$([ "$(order_of ' install -r ')" -lt "$(order_of 'START_VM')" ] && echo yes)" \
  "upgrade starts the old VM again after a failed install"
assert_eq "yes" "$(echo "$PU_CALLS" | tail -3 | grep -q 'rm -f /data/local/tmp/podroid-watchdog.pause' && echo yes)" \
  "upgrade unpauses the watchdog after a failed install"

pu_run container_lost
assert_eq "yes" "$([ "$PU_RC" -ne 0 ] && echo "$PU_OUT" | grep -q 'not back: hermes-1' && echo yes)" \
  "upgrade fails and names a container that was running before and is not after"

# The guest answers ssh over adb before its tailscaled has rejoined, so Dokploy's first validate can
# fail (seen on the Pixel 7: error-400, ready a minute later).
pu_run dokploy_late
assert_eq "yes" "$([ "$PU_RC" -eq 0 ] && echo "$PU_OUT" | grep -q 'dokploy: ready' && echo yes)" \
  "upgrade waits for Dokploy to reach the guest again"
pu_run dokploy_never
assert_eq "yes" "$([ "$PU_RC" -ne 0 ] && echo "$PU_OUT" | grep -q 'dokploy: error-400' && echo yes)" \
  "upgrade fails and reports Dokploy's answer when it never reaches the guest"

# containers_missing (lib.sh): compares container names before and after a VM restart. A swarm task's
# container comes back with a new task id (<service>.<slot>.<25-char id>), so it is compared without it.
cm_dir=$(mktemp -d)
printf 'hermes-1\nnginx.1.abcdefghijklmnopqrstuvwxy\ntraefik\n' > "$cm_dir/before"
printf 'traefik\nnginx.1.zyxwvutsrqponmlkjihgfedcb\n' > "$cm_dir/after"
assert_eq "hermes-1" "$(source bin/lib.sh; containers_missing "$cm_dir/before" "$cm_dir/after")" \
  "containers_missing names a container that did not come back, and matches a swarm task by service and slot"
printf 'b\na\n' > "$cm_dir/before"; printf 'a\nb\nc\n' > "$cm_dir/after"
assert_eq "" "$(source bin/lib.sh; containers_missing "$cm_dir/before" "$cm_dir/after")" \
  "containers_missing is empty when every container came back, whatever the order"
rm -rf "$cm_dir"
