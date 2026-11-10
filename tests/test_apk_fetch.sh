# shellcheck shell=bash
# test_apk_fetch.sh — bin/apk-fetch end to end with a stubbed curl/gh on PATH, in a scratch copy of the repo.
afx_setup() { # <mode: truncated|baddigest> → prints scratch dir
  local d; d=$(mktemp -d); mkdir -p "$d/bin" "$d/pins" "$d/apks" "$d/stub"
  cp bin/apk-fetch bin/lib.sh "$d/bin/"; echo 0.0.0 > "$d/pins/tailscale.version"
  cp tests/fixtures/tailscale-index.html "$d/index.html"
  cat > "$d/stub/curl" <<STUB
#!/usr/bin/env bash
# stub curl: last arg is the URL; -o <file> is the output
out=""; url=""; while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift;; esac; url="\$1"; shift; done
case "\$url" in
  */stable/) cat "$d/index.html" > "\${out:-/dev/stdout}";;
  *.sha256) echo "a517f94006b90a9dbd7383221cbd05ff4acf5ea680335b9b0318e3fbf086d4c9  x.apk";;
  *.apk) if [ "$1" = truncated ]; then printf 'PK' > "\$out"; exit 18; else head -c 4096 /dev/urandom > "\$out"; exit 0; fi;;
esac
STUB
  chmod +x "$d/stub/curl"; echo "$d"
}
for mode in truncated baddigest; do
  d=$(afx_setup "$mode")
  PATH="$d/stub:$PATH" "$d/bin/apk-fetch" --app tailscale >"$d/out" 2>&1; rc=$?
  assert_eq "1" "$rc" "apk-fetch $mode download exits 1"
  assert_eq "0" "$(find "$d/apks" -name '*.apk' | wc -l)" "apk-fetch $mode leaves no apk behind"
  assert_eq "0.0.0" "$(cat "$d/pins/tailscale.version")" "apk-fetch $mode does not advance the pin"
  assert_eq "" "$(grep -o 'sha256 ok' "$d/out")" "apk-fetch $mode does not claim success"
  rm -rf "$d"
done

# download_parts (lib.sh): GitHub's release CDN throttles each connection (~25-45 KB/s seen from here),
# so the APK is fetched as parallel byte ranges. Real curl on a file:// URL; a logging wrapper counts
# the ranged calls, and a range that fails makes the whole download fail.
dp_dir=$(mktemp -d); mkdir "$dp_dir/bin"
head -c 1000003 /dev/urandom > "$dp_dir/src.apk"
REAL_CURL=$(command -v curl)
cat > "$dp_dir/bin/curl" <<STUB
#!/bin/bash
echo "\$*" >> "$dp_dir/calls"
for a in "\$@"; do [ "\$a" = "-r" ] && [ -e "$dp_dir/fail_ranges" ] && exit 22; done
exec "$REAL_CURL" "\$@"
STUB
chmod +x "$dp_dir/bin/curl"; : > "$dp_dir/calls"
(source bin/lib.sh; PATH="$dp_dir/bin:$PATH" download_parts "file://$dp_dir/src.apk" "$dp_dir/out.apk" 4) >/dev/null 2>&1
assert_eq "$(sha256sum < "$dp_dir/src.apk")" "$(sha256sum < "$dp_dir/out.apk" 2>/dev/null)" \
  "download_parts reassembles the file byte for byte"
assert_eq "4" "$(grep -c -- ' -r ' "$dp_dir/calls")" "download_parts fetches the file as the requested number of ranges"
assert_eq "0" "$(find "$dp_dir" -name 'out.apk.part*' | wc -l)" "download_parts removes its part files"
touch "$dp_dir/fail_ranges"; rm -f "$dp_dir/out.apk"
(source bin/lib.sh; PATH="$dp_dir/bin:$PATH" download_parts "file://$dp_dir/src.apk" "$dp_dir/out.apk" 4) >/dev/null 2>&1; rc=$?
assert_eq "1:no" "$rc:$([ -e "$dp_dir/out.apk" ] && echo yes || echo no)" "download_parts fails and leaves no file when a range fails"
assert_eq "0" "$(find "$dp_dir" -name 'out.apk.part*' | wc -l)" "download_parts removes its part files after a failure"
rm -rf "$dp_dir"
