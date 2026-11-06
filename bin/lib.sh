#!/usr/bin/env bash
# lib.sh — shared functions for the pixel_cluster scripts. Source it; do not run it.
# Pure parsers take files so they can be unit-tested on fixtures (tests/test_lib.sh).

LOG_FILE="${LOG_FILE:-/tmp/pixel_cluster-$(date +%Y%m%d-%H%M%S).log}"

die() { echo "error: $*" >&2; exit 1; }

log() { # message — always to the log file; to stdout only with VERBOSE=1
  printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >> "$LOG_FILE"
  [ "${VERBOSE:-0}" = 1 ] && echo "$*"
  return 0
}

tailscale_latest_version() { # <index-html-file> → "1.104.5"
  local v
  v=$(grep -oE 'tailscale-android-universal-[0-9.]+\.apk' "$1" | head -1 | sed -E 's/.*-([0-9.]+)\.apk/\1/')
  [ -n "$v" ] || { echo "no tailscale-android-universal-<v>.apk link in $1" >&2; return 1; }
  echo "$v"
}

podroid_latest() { # <release-json-file> → "<tag> <asset-name> <sha256>"
  python3 -I - "$1" <<'PY'
import json, sys
try:
    r = json.load(open(sys.argv[1]))
except Exception as e:
    sys.exit(f"cannot parse {sys.argv[1]}: {e}")
for a in r.get("assets", []):
    n = a.get("name", "")
    if n.startswith("Podroid-") and n.endswith("-release.apk"):
        d = a.get("digest", "")
        if not d.startswith("sha256:"):
            sys.exit(f"asset {n} has no sha256 digest")
        print(r["tag_name"], n, d[len("sha256:"):])
        sys.exit(0)
sys.exit("no Podroid-*-release.apk asset in release")
PY
}

verify_sha256() { # <file> <expected-hex> — on mismatch deletes the file and returns 1
  local actual
  actual=$(sha256sum "$1" | cut -c1-64)
  if [ "$actual" != "$2" ]; then
    rm -f "$1"
    echo "checksum mismatch: $1" >&2
    return 1
  fi
}
