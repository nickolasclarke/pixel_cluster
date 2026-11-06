# Runbook: Pixel 7 spike (2026-11-06)

What it took to get one phone from "USB-attached" to "Dokploy deploys to it". `bin/phone-provision`
scripts these steps; this is the record of what was done by hand and what was learned.

Phone: Pixel 7, serial `28161FDH200LY1`, Android 16, unrooted. Result: tailnet node
`pixel-7-podroid` (100.64.0.9), Dokploy server `pixel-7-podroid` (id `3RzoxeV75giJGcgX3ueCM`,
ssh `root@100.64.0.9:2222`), nginx smoke test answering on `http://100.64.0.9:30000/`.

## 1. Phone preparation (all over adb)

```sh
S=28161FDH200LY1
adb -s $S install -r apks/tailscale-android-universal-1.104.5.apk
adb -s $S install -r apks/Podroid-v1.2.9-release.apk        # packages: com.tailscale.ipn, com.excp.podroid
# phantom-process killer fix (Podroid docs, verbatim)
adb -s $S shell device_config set_sync_disabled_for_tests persistent
adb -s $S shell device_config put activity_manager max_phantom_processes 2147483647
adb -s $S shell settings put global settings_enable_monitor_phantom_procs false
# Podroid permissions, granted without touching the GUI
adb -s $S shell pm grant com.excp.podroid android.permission.POST_NOTIFICATIONS
adb -s $S shell dumpsys deviceidle whitelist +com.excp.podroid
adb -s $S shell pm grant com.excp.podroid android.permission.MANAGE_VIRTUAL_MACHINE      # AVF backend
adb -s $S shell pm grant com.excp.podroid android.permission.USE_CUSTOM_VIRTUAL_MACHINE  # AVF backend
# headless phone: no lock screen, stay awake on power, dim panel
adb -s $S shell locksettings clear --old <pattern-as-digits>   # Nick runs this; needs the current PIN/pattern
adb -s $S shell locksettings set-disabled true
adb -s $S shell svc power stayon true
adb -s $S shell settings put system screen_off_timeout 2147483647
adb -s $S shell settings put system screen_brightness_mode 0
adb -s $S shell settings put system screen_brightness 1
```

Granting a runtime permission restarts the app, so grant before driving the wizard.
`pm grant` of the two AVF permissions makes the "AVF available" banner disappear. Podroid's docs say
AVF is Pixel 8+, but the Pixel 7 offered it and the guest runs on it (guest gets DHCP from Android
tethering on 172.19.72.0/24, not SLIRP's 10.0.2.15).

## 2. Podroid wizard (driven by `adb shell input tap` from screenshots)

Settings chosen: Load balance **off** (otherwise storage is forced to 8 GB), storage 32 GB,
RAM 2 GB, CPU 4 (Podroid's own guidance: 8 is slower than 4 on QEMU), bandwidth Unlimited,
SSH **on**, Downloads sharing off, USB passthrough off. Permissions page: already granted above,
tap Get Started. Then start the VM with the documented intent:

```sh
adb -s $S shell am start -a com.excp.podroid.action.START_VM
adb -s $S forward tcp:9922 tcp:9922      # dropbear in the guest, root / podroid on first boot
```

"Start VM on boot" is in Settings and still has to be switched on by hand (not done yet on this phone).

## 3. Guest setup (over `ssh -p 9922 root@127.0.0.1` through the adb forward)

```sh
# China: the default Alpine mirror is unreachable
sed -i 's#https://dl-cdn.alpinelinux.org#https://mirrors.aliyun.com#g' /etc/apk/repositories
apk update && apk add tailscale openssh-server
# tailscale as the guest's own node (preauth key from `headscale-cn/commands/hs preauthkeys create --user 1 --expiration 1h`)
rc-update add tailscale default && rc-service tailscale start
tailscale up --login-server https://hs.nclar.ke --authkey <key> --hostname pixel-7-podroid --accept-dns=false
# keepalive: the DO box can only reach the phone once the phone has initiated (see §5)
( crontab -l; echo '*/1 * * * * /usr/bin/tailscale ping -c 1 --timeout 5s 100.64.0.7 >/dev/null 2>&1' ) | crontab -
rc-update add crond default && rc-service crond start
# OpenSSH on 2222 for Dokploy (dropbear drops exec commands > ~10 KB; Dokploy's setup script is 19 KB)
printf 'Port 2222\nPermitRootLogin prohibit-password\nPasswordAuthentication no\n' > /etc/ssh/sshd_config.d/dokploy.conf
ssh-keygen -A && rc-update add sshd default && rc-service sshd start
# keys: Dokploy's pixel_6 public key (dokploy ssh-key all) + the operator's, then dropbear key-only
mkdir -p /root/.ssh && chmod 700 /root/.ssh && cat >> /root/.ssh/authorized_keys ... && chmod 600 /root/.ssh/authorized_keys
sed -i 's/^DROPBEAR_OPTS=.*/DROPBEAR_OPTS="-s"/' /etc/conf.d/dropbear && rc-service dropbear restart
# Dokploy's setup script assumes bash (uses $EUID); root's shell is /bin/sh by default
sed -i 's#^root:x:0:0:root:/root:/bin/sh#root:x:0:0:root:/root:/bin/bash#' /etc/passwd
# Podroid forwards (pins/forwards) — only needed for LAN access to guest ports; Dokploy uses the tailnet
for l in $(cat pins/forwards); do /usr/local/bin/podroid-forward add $l; done
```

## 4. Dokploy (CLI authenticated to `http://100.64.0.7:3000`; several CLI subcommands return 400, the REST API with `x-api-key` works)

```sh
dokploy server create --name pixel-7-podroid --ipAddress 100.64.0.9 --port 2222 --username root \
  --sshKeyId 46etDVagTkjFQka2nEbhV --serverType deploy --json
curl -H "x-api-key: $TOK" "$B/server.validate?serverId=$SID"          # docker/swarm/network/dir flags
curl -X POST -H "x-api-key: $TOK" -d '{"serverId":"'$SID'"}' "$B/server.setup"   # async; poll deployment.allByServer
curl -X POST ... -d '{"environmentId":"dgynIEdNSk66oVgHVKBdG","serverId":"'$SID'"}' "$B/application.deployNginxQuickstart"
curl -X POST ... -d '{"applicationId":"'$APP'","publishedPort":30000,"targetPort":80,"protocol":"tcp","publishMode":"host"}' "$B/port.create"
curl -X POST ... -d '{"applicationId":"'$APP'"}' "$B/application.redeploy"
curl http://100.64.0.9:30000/      # <title>Hello World</title>
```

Setup on Alpine: installs curl/wget/git/jq/rclone, `docker swarm init`, creates `dokploy-network`
and `/etc/dokploy/*`. The `apk add` step took ~4 minutes on the Aliyun mirror. The Traefik
container was not created and nixpacks/railpack/buildpacks are absent (GitHub downloads are slow
from here); neither matters for image-based deploys with published ports.

## 5. Networking facts that drove the design

- The AVF guest is an Android tethered client, so it sits **outside** the Tailscale Android app's VPN.
  Guest traffic to 100.64.x goes nowhere; the Android app cannot serve the guest.
- From this Wi-Fi, foreign traffic leaves through the router's WireGuard exit in the US
  (135.180.36.137), so the phone's public endpoint is American and the DO box reaches it directly.
- The DO box's own discovery goes through the phone's home relay `cn` (Aliyun), which the box cannot
  reach. A direct path forms **only after the phone/guest sends first**; hence the cron keepalive.
- Firewall on the DO box: tcp/443 and udp/41641 open to all; the Dokploy panel stays behind its
  Traefik IP allowlist and is reached over the tailnet at 100.64.0.7:3000.
- Still to test: the "direct China" Wi-Fi (no WireGuard exit). That decides whether the relay
  problem needs solving.

## Open items

- Switch on "Start VM on boot" in Podroid Settings.
- The Tailscale Android app node `pixel-7` also exists (kept on purpose, for the phone's own access).
- Traefik on the guest: investigate only if domain routing on phones is wanted.
