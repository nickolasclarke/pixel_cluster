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

# --- phone-provision helpers ---

parse_version_code() { # <dumpsys-package-text> → versionCode, or empty if the package is not installed
  printf '%s\n' "$1" | grep -oE 'versionCode=[0-9]+' | head -1 | cut -d= -f2
}

adb_installed_version() { # <serial> <package> → versionCode or empty
  parse_version_code "$(adb -s "$1" shell dumpsys package "$2" 2>/dev/null)"
}

phone_node_name() { # <model> <serial> <phones-file> → "<model>-podroid", suffixed with last 4 of the serial on collision
  local model=$1 serial=$2 phones=$3 base name
  base=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-')-podroid
  if [ -f "$phones" ]; then
    name=$(awk -v s="$serial" '$1==s {print $2}' "$phones")
    [ -n "$name" ] && { echo "$name"; return; }
    if awk '{print $2}' "$phones" | grep -qx "$base"; then
      echo "$base-${serial: -4}"; return
    fi
  fi
  echo "$base"
}

node_ip_by_hostname() { # <tailscale-status-json> <hostname> → first tailnet IPv4, or exit 1
  python3 -I - "$1" "$2" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); want = sys.argv[2]
for p in list(s.get("Peer", {}).values()) + [s.get("Self", {})]:
    if p.get("DNSName", "").split(".")[0] == want or p.get("HostName") == want:
        print(p["TailscaleIPs"][0]); sys.exit(0)
sys.exit(f"no tailnet node named {want}")
PY
}

find_server_id() { # <dokploy-servers-json> <name> → serverId or empty
  python3 -I - "$1" "$2" <<'PY'
import json, sys
for s in json.load(open(sys.argv[1])):
    if s.get("name") == sys.argv[2]:
        print(s["serverId"]); break
PY
}

# --- Dokploy REST (the CLI's own token; several CLI subcommands return 400) ---
DOKPLOY_URL="${DOKPLOY_URL:-http://100.64.0.7:3000}"
dokploy_token() {
  python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' \
    "$(dirname "$(dirname "$(readlink -f "$(command -v dokploy)")")")/lib/node_modules/@dokploy/cli/config.json" 2>/dev/null \
    || python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$HOME/.local/share/fnm/node-versions/v22.23.1/installation/lib/node_modules/@dokploy/cli/config.json"
}
dk_get() { # <path?query>
  curl -sf -m 90 -H "x-api-key: $(dokploy_token)" "$DOKPLOY_URL/api/$1"
}
dk_post() { # <path> <json-body>
  curl -sf -m 600 -X POST -H "x-api-key: $(dokploy_token)" -H 'Content-Type: application/json' -d "$2" "$DOKPLOY_URL/api/$1"
}

# --- phone-status helpers ---

parse_version_name() { # <dumpsys-package-text> → versionName or empty
  printf '%s\n' "$1" | grep -oE 'versionName=[^ ]+' | head -1 | cut -d= -f2
}

version_matches_pin() { # <installed-versionName> <pinned-version, optional leading v> → yes|no
  [ "${1%%-*}" = "${2#v}" ] && echo yes || echo no
}

node_state() { # <tailscale-status-json> <hostname> → online|offline|none
  python3 -I - "$1" "$2" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); want = sys.argv[2]
for p in list(s.get("Peer", {}).values()) + [s.get("Self", {})]:
    if p.get("DNSName", "").split(".")[0] == want or p.get("HostName") == want:
        print("online" if p.get("Online") else "offline"); sys.exit(0)
print("none")
PY
}
