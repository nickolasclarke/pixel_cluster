# phone-provision step 1 over network adb: the phone answers only on its host:port target, not on its
# USB serial, so the installed-version check must use the target or it reinstalls Tailscale over the
# tailnet and cuts its own connection. adb is stubbed; step 2's first adb call fails to end the run.
pa_run() { # -> prints the stub adb call log
  local d; d=$(mktemp -d); mkdir "$d/bin" "$d/apks"
  for app in tailscale podroid; do touch "$d/apks/${app}-$(cat "pins/$app.version" | sed 's/^v//').apk"; done
  cat > "$d/bin/adb" <<STUB
#!/bin/bash
echo "\$*" >> "$d/calls"
[ "\$1" = "-s" ] && [ "\$2" != "10.9.8.7:5555" ] && exit 1   # only the network target answers
case "\$*" in
  *get-state*) echo device ;;
  *"getprop ro.serialno"*) echo REALSERIAL ;;
  *"getprop ro.product.model"*) echo "Pixel 7" ;;
  *"dumpsys package"*) echo "    versionCode=123 minSdk=26 targetSdk=36" ;;
  *install*) exit 0 ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$d/bin/adb"
  APK_DIR="$d/apks" LOG_FILE="$d/log" PATH="$d/bin:$PATH" timeout 10 bin/phone-provision 10.9.8.7:5555 >/dev/null 2>&1
  cat "$d/calls"; rm -rf "$d"
}
calls=$(pa_run)
assert_eq "0" "$(echo "$calls" | grep -c ' install ')" "provision over network adb does not reinstall APKs that are already installed"
assert_eq "yes" "$(echo "$calls" | grep -q '10.9.8.7:5555 shell dumpsys package com.tailscale.ipn' && echo yes)" "provision checks installed versions through the adb target it was given"
