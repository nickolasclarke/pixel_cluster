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

download_parts() { # <url> <out> [parts, default 16] — fetch as parallel byte ranges: GitHub's release
  # CDN throttles each connection (~25-45 KB/s seen from here), not the total. Falls back to one
  # stream when the size is unknown. On any failure returns 1 and leaves neither <out> nor parts.
  local url=$1 out=$2 parts=${3:-16} size chunk i rc=0 pids=()
  size=$(curl -sfIL "$url" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:" {n=$2} END {print n}')
  if ! [[ "$size" =~ ^[0-9]+$ ]] || [ "$size" -lt "$parts" ]; then
    curl -fL --retry 3 --progress-bar "$url" -o "$out" || { rm -f "$out"; return 1; }
    return 0
  fi
  chunk=$(( (size + parts - 1) / parts ))
  for ((i = 0; i < parts; i++)); do
    curl -sfL --retry 5 -r "$((i * chunk))-$(((i + 1) * chunk - 1))" "$url" -o "$out.part$i" & pids+=($!)
  done
  for i in "${pids[@]}"; do wait "$i" || rc=1; done
  if [ "$rc" = 0 ]; then
    for ((i = 0; i < parts; i++)); do cat "$out.part$i"; done > "$out" || rc=1
    [ "$(stat -c %s "$out" 2>/dev/null)" = "$size" ] || rc=1
  fi
  for ((i = 0; i < parts; i++)); do rm -f "$out.part$i"; done
  [ "$rc" = 0 ] || { rm -f "$out"; return 1; }
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
  printf '%s\n' "$1" | sed -nE 's/.*versionCode=([0-9]+).*/\1/p' | head -1
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
    if p.get("DNSName", "").split(".")[0] == want:   # the label headscale keeps unique, not HostName
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
DOKPLOY_BOX_IP="100.64.0.7"   # the Dokploy box's tailnet address
# shellcheck disable=SC2034  # used by the scripts that source this file
GUEST_SSH_PORT=2222           # guest sshd that Dokploy deploys over
DOKPLOY_URL="${DOKPLOY_URL:-http://$DOKPLOY_BOX_IP:3000}"
dokploy_token() { # DOKPLOY_TOKEN env, else the token the dokploy CLI saved next to its own dist/
  if [ -n "${DOKPLOY_TOKEN:-}" ]; then echo "$DOKPLOY_TOKEN"; return; fi
  local cfg; cfg="$(dirname "$(readlink -f "$(command -v dokploy)")")/../config.json"
  [ -f "$cfg" ] || die "dokploy CLI not logged in ($cfg missing); run: dokploy auth --url $DOKPLOY_URL --token <token>"
  python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$cfg"
}
dk_get() { # <path?query>
  curl -sf -m 90 -H "x-api-key: $(dokploy_token)" "$DOKPLOY_URL/api/$1"
}
dk_post() { # <path> <json-body>
  curl -sf -m 600 -X POST -H "x-api-key: $(dokploy_token)" -H 'Content-Type: application/json' -d "$2" "$DOKPLOY_URL/api/$1"
}

# --- phone-status helpers ---

parse_version_name() { # <dumpsys-package-text> → versionName or empty
  printf '%s\n' "$1" | sed -nE 's/.*versionName=([^ ]+).*/\1/p' | head -1
}

version_matches_pin() { # <installed-versionName> <pinned-version, optional leading v> → yes|no
  [ "${1%%-*}" = "${2#v}" ] && echo yes || echo no
}

node_state() { # <tailscale-status-json> <hostname> → online|offline|none
  python3 -I - "$1" "$2" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); want = sys.argv[2]
for p in list(s.get("Peer", {}).values()) + [s.get("Self", {})]:
    if p.get("DNSName", "").split(".")[0] == want:
        print("online" if p.get("Online") else "offline"); sys.exit(0)
print("none")
PY
}

# --- headscale REST (API key file; used to retire a stale node before a rebuilt guest re-joins) ---
stale_node_id() { # <headscale-nodes-json> <givenName> → node id if that node exists and is offline; empty if none; exit 1 if online
  python3 -I - "$1" "$2" <<'PY'
import json, sys
for n in json.load(open(sys.argv[1]))["nodes"]:
    if n.get("givenName") == sys.argv[2]:
        if n.get("online"): sys.exit(f"node {sys.argv[2]} (id {n['id']}) is online: another guest has this name")
        print(n["id"]); break
PY
}

# --- phone-debloat helpers ---
packages_to_disable() { # <pm-list-packages-e output file> <disable-list file> → packages that are listed and currently enabled
  grep -vE '^\s*(#|$)' "$2" | sort -u > "${TMPDIR:-/tmp}/.want.$$"
  sed 's/^package://' "$1" | sort -u | comm -12 - "${TMPDIR:-/tmp}/.want.$$"
  rm -f "${TMPDIR:-/tmp}/.want.$$"
}

# --- adb over the network: scripts take a USB serial or host:port; names and pins key on the real serial
adb_real_serial() { # <adb -s target> → ro.serialno
  adb -s "$1" shell getprop ro.serialno 2>/dev/null | tr -d '\r'
}

adb_network_enable() { # <adb -s target> <port> — leave adbd listening on <port> too, so the phone stays
  # reachable after it leaves USB. `adb tcpip` restarts adbd (dropping forwards on this transport) and
  # does not survive a phone reboot, so a USB provisioning run re-enables it.
  local target=$1 port=$2
  case "$target" in *:*) return 0 ;; esac   # host:port target: already network adb
  if [ "$(adb -s "$target" shell getprop service.adb.tcp.port 2>/dev/null | tr -d '\r')" = "$port" ]; then
    echo "network adb already on :$port"; return 0
  fi
  adb -s "$target" tcpip "$port" >/dev/null || return 1
  # the old transport stays listed for a moment, so wait-for-device alone returns on it at once
  timeout 15 adb -s "$target" wait-for-disconnect || return 1
  timeout 30 adb -s "$target" wait-for-device || return 1
  echo "network adb on :$port"
}

# --- charging limit (Pixel "Charging optimization": secure charge_optimization_mode 1 = Limit to 80%)
charge_limit_label() { # <charge_optimization_mode value> → 80%|full
  [ "$1" = 1 ] && echo "80%" || echo full
}

docker_daemon_json_overlay2() { # <current daemon.json content or empty> -> content with the containerd image store off
  # containerd's overlayfs snapshotter on the Podroid guest unpacks hard-linked files as empty
  # (seen with hermes-agent: 4979 zero-byte .py files); the classic overlay2 driver does not.
  python3 -I -c '
import json, sys
d = json.loads(sys.argv[1]) if sys.argv[1].strip() else {}
d.setdefault("features", {})["containerd-snapshotter"] = False
print(json.dumps(d))' "$1"
}

dokploy_validate_state() { # <serverId> → ready|notready|error-<http code>; validate makes the Dokploy
  # box ssh into the guest. error-000: the laptop got no answer from the API; 5xx: Dokploy failed.
  local body code; body=$(mktemp)
  code=$(curl -s -m 90 -o "$body" -w '%{http_code}' -H "x-api-key: $(dokploy_token)" "$DOKPLOY_URL/api/server.validate?serverId=$1")
  if [ "$code" != 200 ]; then echo "error-${code:-000}"
  elif dokploy_server_ready "$(cat "$body")"; then echo ready; else echo notready; fi
  rm -f "$body"
}
dokploy_server_ready() { # <server.validate JSON> -> 0 when Dokploy's main directory and traefik are both up
  echo "$1" | grep -q '"isMainDirectoryInstalled":true' && echo "$1" | grep -q '"traefik":{"version":"[0-9.]*","enabled":true}'
}

# --- phone-soak probe parsers ---
ts_ping_result() { # <tailscale ping output> → "<ms> direct|derp", or "- timeout" when no pong came back
  # (tailscale ping exits 1 on a relayed pong too, so the text is the only reliable signal)
  # the latency is a Go duration: "850µs", "163ms", "1.234s", "2s"
  printf '%s\n' "$1" | awk '/^pong from/ { for (i = 1; i <= NF; i++) if ($i == "in") d = $(i + 1)
      if (d ~ /ms$/) ms = d + 0; else if (d ~ /(µs|us)$/) ms = (d + 0) / 1000; else ms = (d + 0) * 1000
      printf "%.0f %s\n", ms, ($0 ~ / via DERP\(/ ? "derp" : "direct"); found = 1; exit }
    END { if (!found) print "- timeout" }'
}
ping_avg_ms() { # <iputils ping output> → average rtt rounded to ms, or "-" when every packet was lost
  printf '%s\n' "$1" | awk -F/ '/^rtt / { printf "%.0f\n", $5; found = 1 } END { if (!found) print "-" }'
}

# --- podroid-upgrade helpers ---
containers_missing() { # <names-before-file> <names-after-file> → names in before that are not in after
  # A swarm task container comes back with a new task id (<service>.<slot>.<25-char id>): compare
  # those by service and slot.
  local key='s/\.([0-9]+)\.[a-z0-9]{25}$/.\1/'
  comm -23 <(sed -E "$key" "$1" | sort -u) <(sed -E "$key" "$2" | sort -u)
}
