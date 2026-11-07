# shellcheck shell=bash disable=SC2016  # stub bodies are single-quoted on purpose: they expand inside the stub
# podroid-watchdog (runs on the phone as adb's shell user): probes the VM's ssh banner on the phone's
# 127.0.0.1:9922 and fires Podroid's START_VM after WATCHDOG_FAILS consecutive misses, unless the
# pause file exists. nc, am and sleep are stubbed on PATH; am logs its calls.
wd_run() { # nc-stub-body [pause] -> prints the am call log, then the watchdog log
  local d; d=$(mktemp -d); mkdir "$d/bin"
  printf '#!/bin/sh\n%s\n' "$1" > "$d/bin/nc"
  printf '#!/bin/sh\necho "am $*" >> "%s/calls"\n' "$d" > "$d/bin/am"
  printf '#!/bin/sh\nexec /bin/sleep 0.01\n' > "$d/bin/sleep"
  chmod +x "$d/bin/"*; : > "$d/calls"
  [ -n "${2:-}" ] && touch "$d/pause"
  STATE="$d/state" WATCHDOG_FAILS=3 WATCHDOG_PAUSE="$d/pause" WATCHDOG_LOG="$d/log" WATCHDOG_PIDFILE="$d/pid" \
    PATH="$d/bin:$PATH" timeout 1 sh phone/podroid-watchdog >/dev/null 2>&1
  cat "$d/calls"; cat "$d/log" 2>/dev/null; rm -rf "$d"
}
out=$(wd_run 'exit 1')
assert_eq "am start -a com.excp.podroid.action.START_VM" "$(echo "$out" | grep '^am' | head -1)" "watchdog starts the VM when the ssh banner stays missing"
assert_eq "yes" "$(echo "$out" | grep -q 'VM not answering' && echo yes)" "watchdog logs each restart"
assert_eq "" "$(wd_run 'echo SSH-2.0-dropbear')" "watchdog does nothing while the VM answers"
assert_eq "" "$(wd_run 'exit 1' pause)" "watchdog does nothing while the pause file exists"
assert_eq "" "$(wd_run 'n=$(cat "$STATE" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$STATE"; [ "$n" -gt 2 ] && echo SSH-2.0')" "watchdog tolerates two consecutive misses"
