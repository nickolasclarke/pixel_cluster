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
