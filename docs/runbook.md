# Runbook: one phone, from USB to Dokploy deploy target

What the Pixel 7 spike (2026-11-06, serial `28161FDH200LY1`) established. `bin/phone-provision`
scripts the repeatable parts; the rest is here so the next phone is a loop, not a rediscovery.

## Topology that actually works

```
Dokploy (DO box, 100.64.0.7)
   └── ssh root@<guest tailnet IP>:2222 (OpenSSH, key only)
         └── Alpine guest under Podroid (AVF on Pixel 7), running tailscaled + dockerd
               └── single-node swarm + dokploy-network + dokploy-traefik, as Dokploy's setup creates
```

- **tailscaled runs inside the guest**, not just the Android app. The guest is an Android *tethered*
  client (DHCP from Android, `172.19.72.0/24` on this phone), and Android keeps tethered clients
  outside VPN apps. So the guest cannot see the tailnet through the phone's Tailscale app, and
  nothing it does triggers the phone to find peers. The Android app stays installed so the phone
  itself can use an exit node; it is not on the deploy path.
- **The DO box reaches the guest only on a direct path.** The guest's home relay is `cn` (Aliyun),
  which the box cannot reach. A direct path forms only after the *guest* sends to the box (the
  box's own disco goes via `cn` and dies). Hence the per-minute cron keepalive in the guest. On the
  Wi-Fi used for the spike the guest's packets leave through the router's WireGuard exit in the US;
  on a China-direct network this must be re-tested before moving phones there.
- **Dropbear cannot be Dokploy's ssh target.** It closes the connection for exec commands longer
  than ~10 KB and Dokploy sends its ~20 KB setup script as one command (`Error: Unable to exec` in
  Dokploy's log, an empty "Initializing Setup Server" deployment log). OpenSSH on 2222 fixes it.
  Dropbear stays on guest 22 / phone 9922 for Podroid.
- **Dropbear flips to key-only by itself.** Once `/root/.ssh/authorized_keys` exists, Podroid's
  hostd runs dropbear with `-s` (no passwords). After that, the only way into the guest is a key:
  Dokploy's over 2222, or your own key added to `authorized_keys` before the password stops working.
- **IPv6 off in the guest.** Tethering hands out a global IPv6 address with no working route, and
  dockerd then fails pulls with `dial tcp [2600:...]`. `/etc/sysctl.d/90-no-ipv6.conf`.
- **China network facts:** `dl-cdn.alpinelinux.org` unreachable, use `mirrors.aliyun.com`.
  Docker Hub reachable over IPv4 via this router (401 challenge in ~1 s). `rclone.org` reachable.

## Phone preparation (adb, all scriptable)

1. Authorize USB debugging once (dialog on the phone).
2. Remove the screen lock so adb can drive the UI unattended (Nick's call for shelf phones).
   `locksettings clear --old <PIN or pattern digits 1-9>` must be run by a human; then
   `locksettings set-disabled true`. Pattern digits: rows top-to-bottom, `1 2 3 / 4 5 6 / 7 8 9`.
3. `svc power stayon true`, `settings put system screen_off_timeout 2147483647`,
   `screen_brightness_mode 0`, `screen_brightness 1`.
4. Phantom-process fix (Podroid docs, verbatim):
   `device_config set_sync_disabled_for_tests persistent`,
   `device_config put activity_manager max_phantom_processes 2147483647`,
   `settings put global settings_enable_monitor_phantom_procs false`.
5. Install both APKs (`adb install -r`). Package names in `pins/packages`.
6. Podroid permissions over adb (no GUI needed): `pm grant com.excp.podroid
   android.permission.POST_NOTIFICATIONS`, `dumpsys deviceidle whitelist +com.excp.podroid`, and
   for AVF: `pm grant ... MANAGE_VIRTUAL_MACHINE` and `USE_CUSTOM_VIRTUAL_MACHINE`. Granting
   restarts the app; relaunch it afterwards.

## Podroid wizard (GUI, via adb screencap + tap; ~2 minutes)

Launch `com.excp.podroid`. Tap coordinates are for 1080x2400.

| Step | Setting | Value used |
|---|---|---|
| 1 Storage | size | 32 GB (only selectable after step 2's Load balance is off; go Back) |
| 2 Configure | Load balance | **off** |
| 2 | RAM / cores / bandwidth | **4 GB** RAM on 8 GB and 12 GB phones (see Sizing policy), top core count (on AVF anything above 1 means all cores), Unlimited. Earlier phones were 2 GB / 4 cores. |
| 2 | SSH access | on |
| 3 Downloads sharing | | off |
| 4 USB passthrough | | off |
| 5 Permissions | | already granted by adb; tap Get Started |

Then the home screen. Pixel 7 reports **AVF (KVM) available** despite the docs saying Pixel 8+.
Start the VM with `am start -a com.excp.podroid.action.START_VM`; Ready in ~50 s. Set
"Start VM on boot" in Settings (not yet scripted; see open items).

## Guest configuration (over `adb forward tcp:9922 tcp:9922`, password `podroid`)

1. `/etc/apk/repositories`: dl-cdn → mirrors.aliyun.com. `apk add tailscale openssh-server`.
2. tailscale: `rc-update add tailscale default; rc-service tailscale start;`
   `tailscale up --login-server https://hs.nclar.ke --authkey <preauth> --hostname <phone>-podroid --accept-dns=false`.
   Preauth key: `headscale-cn/commands/hs preauthkeys create --user 1 --expiration 1h`.
3. Keepalive cron (busybox crond): `*/1 * * * * /usr/bin/tailscale ping -c 1 --timeout 5s 100.64.0.7`.
4. OpenSSH on 2222, key only: `/etc/ssh/sshd_config.d/dokploy.conf` with `Port 2222`,
   `PermitRootLogin prohibit-password`, `PasswordAuthentication no`; `ssh-keygen -A`;
   `rc-update add sshd default; rc-service sshd restart`.
5. Dokploy's public key (ssh key `pixel_6`, id `46etDVagTkjFQka2nEbhV`) into
   `/root/.ssh/authorized_keys` (700/600).
6. IPv6 off (sysctl above).
7. Port forwards (`/usr/local/bin/podroid-forward add <host> <guest> tcp`, not on PATH in a
   non-login shell) from `pins/forwards`. Not on the Dokploy path any more; kept so published
   ports are also reachable on the phone's LAN IP.

## Dokploy

- `dokploy server create --name <phone>-podroid --ipAddress <guest IP> --port 2222 --username root
  --sshKeyId 46etDVagTkjFQka2nEbhV --serverType deploy`. Names: hyphens (DNS labels).
- Validate: `GET /api/server.validate?serverId=…` with `x-api-key` (the CLI's `server validate`
  returns 400). Setup: `POST /api/server.setup {"serverId"}`; it is async, watch
  `GET /api/deployment.allByServer?serverId=…` for `running` → `done`. Setup on Alpine installs
  curl wget git git-lfs jq openssl sudo unzip tar + rclone, inits a single-node swarm, creates
  `dokploy-network`, `/etc/dokploy/*`, and runs `dokploy-traefik` (ports 80/443 inside the guest).
- The CLI's `server update` needs `--description`; the REST `server.update` needs every field
  including `serverType`.
- Personal project environment id for the smoke test: `dgynIEdNSk66oVgHVKBdG`.

## Result of the spike

Dokploy's nginx quickstart ("Hello World", published host port 30000) deployed to server
`pixel-7-podroid` from the panel and answered `200` at `http://100.64.0.9:30000/` over the tailnet
and at `http://<phone LAN IP>:30000/` through the Podroid forward.

## Open items

- "Start VM on boot" is a Podroid Settings toggle, not yet set over adb.
- Direct-path test on the China-direct Wi-Fi.
- The Android-app node (`pixel-7`, 100.64.0.8) and the guest node (`pixel-7-podroid`, 100.64.0.9)
  are two headscale nodes per phone; fine, but `phone-status` should show both.

## Second phone: Pixel 6 Pro (`1B231FDEE0033H`, Android 17), 2026-11-06

`bin/phone-provision` did everything except the wizard. Node `pixel-6-pro-podroid` (100.64.0.10),
Dokploy server `pixel-6-pro-podroid`, nginx smoke test at `http://100.64.0.10:30000/`. Learned:

- **Two attached phones collide on host port 9922.** The script now lets adb allocate a host port per
  phone (`adb forward tcp:0 tcp:9922`) and removes it on exit.
- **If the VM was started before the wizard finished** (the script's first pass sends START_VM), the
  app never opens its 9922 listener even though dropbear runs in the guest and the SSH toggle looks
  on. The STOP_VM broadcast did not stop it; the app's **Restart** button did, and 9922 appeared 10 s
  later. The wizard's "load balance off" has to be done before the VM starts, or the sizes stick at
  the auto values until a restart.
- **The headscale REST preauth path works** (`POST /api/v1/preauthkey`, `"user":"1"`, key at
  `.preAuthKey.key`) with the API key in `~/.config/pixel_cluster/headscale-api-key`; no ssh to the
  DO box is needed any more. `tailscale up --authkey file:/dev/stdin` does not work over a non-tty
  ssh session; the key goes into a mode-600 temp file instead.
- **dockerd keeps dialing IPv6 after the sysctl** until restarted: the first Traefik pull failed with
  `dial tcp [2600:...]:443`. The script restarts docker once when it first writes the sysctl.
- Dokploy's `server.setup` reported done after 5 min but had only reached the Traefik pull; running
  its script again by hand (idempotent) installed Traefik 3.6.25 and nixpacks. railpack's GitHub
  download failed (HTTP/2 reset); not needed for image deploys.
- Swarm advertise address is the public exit IP (`<router-wg-exit-ip>`): harmless for a one-node swarm,
  wrong for the phase-two phone swarm, which must use the guest's LAN address.
- The phone sat in landscape with auto-rotate on; `settings put system accelerometer_rotation 0`
  and `user_rotation 0` did not take effect immediately. Taps were done in landscape coordinates.


## Sizing policy (2026-11-06, RAM revised 2026-11-07)

The phones do nothing else, so: top core count (AVF uses all cores for anything above 1), **4 GB
guest RAM** on 8 GB and 12 GB phones, and the largest disk that still leaves Android about 10 GB (64 GB on a 128 GB phone). Set Battery >
Charging optimization to the 80 % limit; these sit on power permanently and all-core load throttles
thermally. RAM and CPU changes need a VM stop; pick them in the wizard on a fresh phone.

RAM is 4 GB, not the largest Podroid offers: guest memory never returns to Android (no balloon
driver), so after any heavy disk IO the whole guest size is a standing cost to Android. At 8 GB the
6 Pro was killed during a large `docker load`; 6 GB survived with 140 MB of swap left; 4 GB survived
on both phones (measurements under "Guest RAM step-down" below). Change it in Podroid > Settings >
VM resources with the VM stopped. First `adb shell touch /data/local/tmp/podroid-watchdog.pause` so the
watchdog does not restart the VM under you, and remove the file afterwards (the chips are 512 MB, 1, 2, 4, 6, 8 GB).

## Pixel 7 rebuilt from a factory reset (2026-11-06)

User files were pulled first (`adb pull` of Pictures, DCIM, Download, Movies, Snapseed, Documents,
Music, Android/media: 9.2 GB, 5648 files, counts verified) to `~/phone-backups/`. App data cannot be
exported without root. After the reset: skip every sign-in, enable USB debugging, then
`bin/phone-provision` (stops at the wizard), the wizard with the sizing policy (64 GB / 4 GB / 8 cores /
Unlimited / SSH on), **Restart** in the app (the VM always starts early), Settings > Start VM on boot,
`bin/phone-debloat`, `bin/phone-provision` again. Learned:

- A wiped guest never logs out, so headscale keeps its node "online". The provisioner now pings the
  old address from the laptop and retires the node when it does not answer; the Android-app node was
  retired by hand the same way (DELETE /api/v1/node/<id>). The Dokploy record's IP was updated by the
  script (100.64.0.9 -> 100.64.0.11).
- `bin/phone-debloat` disabled 64 packages with nothing refused. The launcher, Settings and Podroid
  kept working. Memory numbers before/after are in the session summary below the table.

## Keepalive and debloat (2026-11-06, later)

- Dokploy lost the Pixel 6 Pro for a while ("Timed out while waiting for handshake") although the
  laptop still reached it; a guest-side `tailscale ping` restored it at once. The per-minute cron was
  too slow for the UDP NAT timeouts on this path. Replaced by the OpenRC service `tailnet-keepalive`
  (ping the box every 20 s), installed by the provisioner and applied to both guests.
- `bin/phone-debloat` now runs from `bin/phone-provision` step 2, and the list includes Play services
  and the keyboard. Pixel 7 after: 4.7 GB available with the 4 GB VM running; Pixel 6 Pro: 6.6 GB.
  Launcher, Settings, Podroid and the Tailscale app still work; adb text injection needs no IME.

## Reboot behaviour (tested on the Pixel 7, 2026-11-06)

- Android back on USB in ~55 s; the VM auto-starts and the guest is on the tailnet ~10 s later.
- Neither `adb tcpip 5555` nor Android's Wireless debugging survives a reboot (tested: Android
  turns Wireless debugging off at boot; "Always allow on this network" only skips the dialog).
  Without root, USB once per reboot is the floor. Wireless debugging needs no pairing when the host's
  USB adb key is already authorized: `adb mdns services` shows the TLS port, `adb connect ip:port`.
- `dokploy-traefik` exits at boot ("network ... not found": the swarm overlay is not up yet) and
  Docker's restart loop gives up. `/etc/local.d/dokploy-traefik.start` now re-starts it 45 s after
  boot; the provisioner installs it.

## Control without USB (2026-11-06)

- Guests: `ssh -p 2222 root@<guest tailnet IP>` from anywhere on the tailnet (operator key is installed).
- Android: `adb tcpip 5555` once over USB (Nick runs it; it exposes a service), then
  `adb connect <phone LAN IP>:5555`. The scripts accept `host:port` wherever they take a serial and
  key names/pins on the real serial. Lost on reboot without root. Reaching ADB from outside the LAN
  needs the Tailscale Android app logged in on the phone (done, see below): `adb connect <phone
  tailnet IP>:5555`.
- Tailscale Android app login (done on both phones 2026-11-06, driven over adb with `uiautomator
  dump` + `input tap`): accept the VPN consent dialog (it only appears with the screen on; with the
  screen off the app shows "VPN permission needed", tap Try again), tap Get Started and close the
  Chrome tab it opens, then Settings > Accounts > kebab menu > "Use an alternate server"
  (`https://hs.nclar.ke`, Add account, close Chrome again) and kebab > "Use an auth key" with a
  headscale preauth key from the REST API. The phone registers as `<model>` (e.g. `pixel-7`,
  100.64.0.12); the 6 Pro got `pixel-6-pro-1` (100.64.0.13) because a stale offline `pixel-6-pro`
  node (id 6) held the name. The Android app's VPN does not touch the tethered guest: both guests
  still ping dokploy and run traefik with it up.
- Start on boot: Android Settings > Network & internet > VPN > Tailscale gear > "Always-on VPN"
  (on; "Block connections without VPN" left off so tethering and non-tailnet traffic keep working).
  Verifiable with `settings get secure always_on_vpn_app` = `com.tailscale.ipn`. This is the only
  supported route without device owner; `settings put` on that key is reported not to take effect.
  Not yet verified across a real reboot.
- Tailscale SSH: skipped; OpenSSH with keys over the tailnet already covers it and the policy
  allows non-root users only.

## Tether address loss and tailscaled respawn (2026-11-06)

Seen on the 6 Pro after the phone changed Wi-Fi: the guest dropped off the tailnet and off the
adb-forwarded 9922 for 15+ minutes until the VM was restarted. Root cause is in Podroid's
`/etc/init.d/podroid-network`: on the AVF backend it runs `udhcpc -q -n` once at boot and never
renews, while Android hands out a fresh tether subnet whenever tethering restarts (seen
172.19.72.x -> 172.17.92.x on the Pixel 7, 10.13.42.x on the 6 Pro). After a re-tether the guest
keeps a dead address; tailscaled's DERP reads time out, its wgengine watchdog fires and it exits 1.
(The guest logs are zero-filled after that exit because the VM was later force-stopped, so whether
supervise-daemon respawned it is unknown.) Two fixes, both in the provisioner's guest step:

- `guest/tailnet-keepalive` replaces the inline ping loop: same 20 s ping to the box, and after 3
  consecutive misses it re-runs udhcpc one-shot on eth0 and restarts tailscaled. Tested on the Pixel
  7 by flushing eth0: back on the tailnet in 86 s with no hands. Unit-tested with stubbed
  `tailscale`/`udhcpc`/`rc-service` in `tests/test_tailnet_keepalive.sh`.
- `/etc/conf.d/tailscale` gets `respawn_max=0` (unlimited) and `respawn_delay=5`. OpenRC's
  default `respawn_max=10` with no `respawn_period` counts over the service's whole lifetime, after
  which a crashed tailscaled stays down for good.

Also noted: with `adb tcpip 5555` adbd listens on every interface (`*:5555`), as do the Podroid
forwards (8080, 8443, 9922, 30000-30009), so they are reachable from whatever Wi-Fi the phone is on.
Accepted for now; the Android app's tailnet address is the intended path.

## Docker image store: overlay2, not containerd (2026-11-06)

Docker 29 on the guest defaults to the containerd image store (`overlayfs` snapshotter). On the
Podroid guest (kernel 7.1.5, containerd 2.3.5) it unpacks hard-linked files as empty: the
hermes-agent arm64 image came out with 4979 zero-byte `.py` files, every one with more than one
link. The layer blob itself was intact (checksum matched and a manual `tar -xzf` of it on the same
disk was correct). The provisioner now writes `{"features": {"containerd-snapshotter": false}}`
to `/etc/docker/daemon.json` (merged into any existing keys) and restarts Docker; `docker info`
then shows `Storage Driver: overlay2`.

Switching stores hides every image *and container* of the old store, including Dokploy's
`dokploy-traefik`. `server.validate` then still says `isMainDirectoryInstalled:true` but
`traefik.enabled:false`, so step 7 now re-runs Dokploy setup unless both are true.

Docker Hub from a phone on a China-adjacent network: small pulls (traefik, 178 MB) work, but large
blobs get `connection reset by peer` from the CloudFront CDN (52.85.151.x) partway through, five
retries in a row, so a 1 GB layer never lands. Dokploy's setup reports `done` even when its traefik
pull failed this way; check `traefik.enabled` in validate, not the deployment status. Workaround
used: pull on a machine with clean egress (`docker pull --platform linux/arm64 ...`) and stream it
in with `docker save | ssh -p 2222 root@<guest> docker load`. A registry mirror would be the
durable fix if phones are going to deploy large images from that network.

## Android killed the VM for memory (2026-11-07)

Loading the 4.3 GB hermes-agent image (`docker load`) on the 6 Pro guest (8 GB RAM on a 12 GB
phone) made the guest unresponsive for minutes at a time, then Android killed Podroid outright:
`ActivityManager: Killing com.excp.podroid (adj 200): MemoryLimiter:AnonSwap`, preceded by
lowmemorykiller clearing every cached app with "device is not responding" and Android swap at
3071/3071 MB. The guest's page cache had filled its whole 8 GB, which is host anonymous memory to
Android. The deviceidle whitelist, background app ops and active standby bucket do not protect
against this kill. Podroid did not restart the VM afterwards; `am start -a
com.excp.podroid.action.START_VM` brought it back in under 20 s with docker, traefik and the tailnet
path intact. Implication: the max-RAM sizing policy leaves Android too little headroom under heavy
guest IO, and a killed VM stays down until something restarts it.

### Guest RAM step-down on the 6 Pro (2026-11-07)

Same test at each size: VM restarted at the new size, then `docker load` of the same 4.3 GB
hermes-agent tar from the guest disk, Android memory sampled every 10 s over adb. With the VM
stopped the phone has 9.0 GB available and 2.8 GB of its 3 GB swap free.

| Guest RAM | Load | Podroid | Lowest Android MemAvailable | Lowest Android SwapFree |
|---|---|---|---|---|
| 8 GB | did not finish | killed (`MemoryLimiter:AnonSwap`) | n/a | 0 (3071/3071 used) |
| 6 GB | 2 min 21 s | survived | 3447 MB | 140 MB |
| 4 GB | 2 min 56 s | survived | 4806 MB | 733 MB |

- Android's MemoryLimiter logs `onLimitExceeded ... type=memory.high memHigh=3221225472
  swapHigh=3221225472 pkg=com.excp.podroid` early in every run at 4, 6 and 8 GB: Podroid has a
  3 GB memory.high limit. Not verified: that the limiter pushes everything above 3 GB into swap and
  kills once swap runs out. It fits the numbers, since swap use grows with guest size.
- The guest has no virtio-balloon driver. `echo 3 > /proc/sys/vm/drop_caches` freed 3.8 GB inside
  the guest and changed nothing on the Android side. Guest memory, once touched, stays with Podroid
  until the VM stops, so the guest size is a standing cost to Android, not a peak.
- Image contents were correct at both sizes on overlay2 (one empty non-`__init__` `.py` file,
  `google/auth/crypt/_helpers.py`, which is also empty in the published image).

Pixel 7 (8 GB phone, Android 16 BP2A.250605.031.A2), same test at its existing 4 GB: load 2 min 4 s,
Podroid survived, lowest Android MemAvailable 685 MB, lowest SwapFree 1879 MB, 982 MB available
afterwards, image contents correct. No MemoryLimiter line and no am_kill during the run. The
6 Pro runs Android 17 (CP3A.261005.002.A1); whether the 3 GB MemoryLimiter is an Android 17 feature
is not verified. Copying the 1 GB of image chunks to the Pixel 7 guest over the tailnet dropped
the ssh stream 5 times and once hung it outright; use `-o ServerAliveInterval=10
-o ServerAliveCountMax=3` and per-chunk checksums with retry for large copies.

## Screen off and Doze (tested 2026-11-06)

With Podroid on the deviceidle whitelist plus `RUN_ANY_IN_BACKGROUND`/`RUN_IN_BACKGROUND` allowed,
standby bucket `active`, and app hibernation off, a forced deep Doze (`dumpsys deviceidle force-idle`)
on the Pixel 7 left the guest reachable over the tailnet, Dokploy validate green, and ssh working for
the whole 4-minute test. Default is now screen off after 60 s (`svc power stayon false`). When driving
the UI over adb, wake it first with `input keyevent KEYCODE_WAKEUP`. The provisioner applies all of it.

## Tailnet stability investigation (2026-11-07, Pixel 7 and 6 Pro)

Symptom: large transfers to the guests over the tailnet dropped, and inbound paths (laptop ->
guest) sometimes stayed dead. Findings, in the order they matter:

1. **The keepalive restarted tailscaled under load (fixed, bd81fc9).** The 20 s ping to the
   Dokploy box goes overseas and misses three times in a row whenever the link is busy, and the
   keepalive then re-ran udhcpc and restarted tailscaled. That killed every tailnet stream. The
   Pixel 7 guest restarted tailscaled at every bulk copy and stream test. On the 6 Pro the re-lease
   also moved the guest from 10.13.42.104 to .68 although its lease was still valid. Now the re-lease
   and restart also require the default gateway on eth0 to stop answering. During the failed
   transfers the gateway answered 456/456 pings, worst 47 ms.
2. **Inbound paths depend on the China relay (derp-900).** The guests sit behind two NATs: the
   Android tether (`avf_tap_*`) and the clarke router, whose WAN is 192.168.1.64 on the SUN
   network. A client can only reach them directly if the relay coordinates hole punching, or if the
   guest has recently sent to that client. A client that cannot reach 47.108.180.69:443 gets
   neither a relay path nor a direct path. Seen with the laptop on SUN-5G plus the full-tunnel
   `WG-Boyd-Ave`. The laptop logged `connect to region 900 (cn): context deadline exceeded`, and
   test connections through the tunnel timed out, while the guests reach the relay in 37 ms from
   clarke. Recovered by a `tailscale ping <client>` from the guest. Not verified: that tailscaled's
   relay socket goes into the WG tunnel (no root to check its routing).
3. **Phone Wi-Fi latency with the screen off.** Pixel 7 LAN pings averaged 805 ms (max 1.6 s) with
   the screen off, and 36 ms (max 110 ms) with `svc power stayon true`. Its Wi-Fi had 26% of TX
   frames retried at RSSI -62. User builds have no shell switch for Wi-Fi power save (`cmd wifi`
   has none). The screen stays off by default.
4. **Podroid's port forwards cut long uploads.** 300 MB sent to `192.168.15.140:30009`
   (`podroid-forward`, relayed by the Podroid app in userspace) delivered 101,200 bytes and closed.
   The download direction was not measured.
5. **The laptop's own network moved under the tests.** Wi-Fi dropped at 12:51:26 (the hung scp)
   and switched to SUN-5G at 14:27. The laptop's tailscaled also logs `restarted resolved` several
   times a minute (2104 lines in 25 min), a likely cause of its Docker Hub DNS timeouts.

Throughput (300 MB of zeros over ssh, with the old keepalive): laptop -> Android tailnet 20 MB/s;
laptop -> guest tailnet 1.4-6.4 MB/s, often dropped.
After the keepalive fix, with the laptop back on clarke: 0 tailscaled restarts, but 6/6 transfers
still dropped (58-170 s, 1.8-5.2 MB/s), screen on or off. The laptop's log shows the guest's path
going derp/direct every 20-30 s during each transfer. Investigation handed off in
`docs/handoffs/2026-11-07-tailnet-relay-and-bulk-transfers.md`.

### Second pass (2026-11-07 afternoon, from the handoff)

Method: one instrumented 300 MB transfer to the Pixel 7 guest with per-2 s counters on every hop
(laptop, Android, guest, relay), then plain-TCP throughput tests that each cross a single hop.
Findings:

1. **The guest, its tailscaled, and the virtio tap are not the bottleneck.** Plain TCP between
   Android and the guest over `avf_tap_fixed` moves 300 MB in 1-3 s (75 MB/s) in both directions.
   During the tailnet transfer the guest's CPU stayed 88% idle, `/proc/net/dev` showed 0 drops,
   UDP InErrors stayed 0, and tailscaled's `tailscaled_inbound_dropped_packets_total` metrics did not
   exist (no inbound drops). The lower packet count on `tailscale0` than on `eth0` is tailscaled's
   TCP GRO coalescing, not loss.
2. **Bulk TCP across the clarke Wi-Fi stalls with no tunnel involved.** Plain TCP, no WireGuard:
   laptop -> guest through the Android NAT stalled after 1.3 MB; guest -> laptop ran 4-7 MB/s and
   stalled at 45 MB; laptop -> Android (no guest, no NAT) stalled after 256 KB; Android -> laptop
   stalled at 16 MB. The tailnet transfer shows the same shape: 26 MB burst in 2 s, then the TCP
   flow dies (laptop retransmits every RTO, guest receives nothing), ssh gives up 30 s later. During
   the stall, ICMP pings guest -> laptop (1/s) had 0 loss and < 100 ms, while laptop <-> Android
   pings lost 9 of 70 and the guest's sshd measured 2 s RTTs. So small, slow flows survive and
   sustained flows die. Not yet isolated: the Pixel 7 radio, the laptop radio, or the AP/router.
   The earlier 20 MB/s adb result to the Android node is unexplained by this and needs a repeat.
3. **The relay sees the same Wi-Fi failure.** derper's only client errors over 7 days are
   `read: connection timed out` / `no route to host` for every clarke client (both guests, both
   Android nodes, and the laptop, 5-13 each), i.e. the relay's keepalives stop being ACKed. The
   derper does not restart and has no firewall limits (tcp_retries2 15, conntrack 5 d). The guest
   learns of the dead socket only when it next writes (`connection reset by peer`, 17 on the 6 Pro),
   so it can sit on a zombie relay connection for a long time, during which the relay answers the
   laptop with `derp-900 does not know about peer`.
4. **Under load the guest's netcheck reports `UDP is blocked`** (3 times in the 14:55-15:10 window)
   because its STUN probes get no answer, and it rehomes to the lowest HTTPS-latency region
   (Dubai 514 ms, Denver, Chicago, Los Angeles) before returning to cn. Each move opens TCP
   connections that also get reset.
5. **Laptop behind the full-tunnel WG (SUN-5G + WG-Boyd-Ave, 16:20):** tailscaled's own relay
   connection is fine. Its fwmark 0x80000 bypass routes 47.108.180.69 out `wlp170s0`
   (`ip route get ... mark 0x80000`), the socket is ESTAB at 36 ms RTT, netcheck sees cn at
   23 ms with UDP working, and `curl --interface wlp170s0 https://47.108.180.69/derp/probe` is 200
   in 82 ms. Default-routed traffic goes out the WG to 135.180.36.137 and is border-blocked. Yet all
   four phone nodes are unreachable (`tailscale ping` no reply; dokploy answers in 288 ms) and the
   laptop logs `derp-900 does not know about peer [VLtW2]/[sASWC]` every few seconds: the guests are
   not on the relay (finding 3 and 4), not the laptop's side. The 14:50 `connect to region 900:
   context deadline exceeded` errors from earlier today are therefore not reproduced; the laptop
   runs v2rayA (`v2raya_core`, transparent proxy, DNS hijack to 127.2.0.17), and on clarke its relay
   TCP showed two sockets with identical byte counts (one at 0.06 ms RTT), which is a local
   intercept. Whether v2rayA pulled the relay dial into the WG at 14:50 needs `sudo nft list
   ruleset`.
6. **Side finding:** the `restarted resolved` log storm on the laptop is tailscaled fighting
   v2rayA's resolv.conf hijack (`trample: resolv.conf changed ... "# v2rayA DNS hijack"`), and after
   the Wi-Fi move resolv.conf is tailscale-owned with only 100.100.100.100.

Not changed: headscale, relay, routers, firewall, phones (the screen-on test never ran: adb
dropped when the laptop left clarke). Probe scripts are in the session scratchpad, to be moved
into `bin/` once the test matrix settles (done 2026-11-07 evening: `bin/guest-xfer-probe`, `bin/natpath`).

### Third pass (2026-11-07 evening): the clarke router was underpowered

Nick found the clarke GL router (LAN MAC OUI 94:83:c4, GL.iNet) was underpowered and fixed it.
Everything below was measured after the laptop rejoined clarke at 18:24.

1. **The Pixel 7 lost Wi-Fi at 16:10:35 and had none until 18:10** (`dumpsys wifi` state records,
   `NETWORK_DISCONNECTION_EVENT reasonCode -1 locallyGenerated false`, i.e. the AP went away). It
   dropped again 18:12:19 and rejoined at 18:29. The laptop's own flap was 16:07. The 16:09 Wi-Fi-only
   stalls (second pass, finding 2) happened while the AP was dying, so they say nothing about the
   radios. Across the day the "clarke" SSID appeared under four locally-administered BSSIDs
   (0a:21:37:2d:c1:e9, 9e:9a:24:e6:d3:e2, ae:9a:4f:fc:f4:35, 0e:79:fd:f3:9c:e4); two are up now, both
   on channel 44.
2. **Wi-Fi-only plain TCP now completes 300 MB both ways, screen on and screen off**, laptop to
   Pixel 7 Android (`natpath.py`, 18:48-18:50): 9.3 and 10.2 MB/s with the screen held on, 11.5 and
   10.4 MB/s dozing. Second-pass finding 2 is withdrawn: there is no Wi-Fi bulk-flow stall when the
   AP is healthy. Screen-off power saving does not stall bulk TCP.
3. **The 300 MB ssh transfer to the Pixel 7 guest now completes 4 of 4** (`xfer-probe2.sh`, screen
   off, 18:50-18:55): 49, 45, 44, 36 s at 6.2-8.5 MB/s, ssh exit 0, direct path via the Android NAT
   (192.168.15.141:20310) for the whole run, relay never used. Some retransmits (about 100 per run on
   the laptop's ssh socket) but no stall. Before the power fix it was 0 of 7.
4. **The guest's relay socket is healthy** (ESTAB to 47.108.180.69, last receive 1.6 s ago) and the
   guest's tailscaled log shows the usual rehoming churn only at 18:29 when its Wi-Fi came back.
5. **v2rayA (from the nft ruleset Nick captured at about 18:30):** no proxy or tproxy rules exist and
   `v2raya_core` is not running, only the `v2raya` manager. The ruleset is clean: Docker, lxc and
   tailscaled's own tables. This does not settle the 14:50 relay dial failure, which happened under a
   different state (SUN-5G, WG up, proxy state unknown). To settle it, capture the ruleset while the
   proxy core and WG are both up.

Working conclusion: the underpowered router is the simplest explanation for both problems in the
handoff. An AP that browns out under sustained traffic drops bulk flows mid-transfer, and each drop
also kills the guests' relay TCP sessions, which is the zombie-socket pattern the derper logs. Still
to confirm: that no failures recur over a longer series and on the 6 Pro, and that the derper stops
logging client timeouts for clarke clients from now on.
6. **The 6 Pro guest also completes 3 of 3** (19:11-19:15, Nick's go-ahead, Hermes answering on
   :9119 before and after): 80, 68, 68 s at about 4 MB/s, ssh exit 0, direct path via the 6 Pro's
   Android NAT (192.168.15.168:22356) throughout. Guest load rose to 2.7 during the runs; RAM unchanged.
   Nick confirms the 18:xx Wi-Fi events were him fixing the router's power supply, so every failure in
   this investigation predates the fix and every pass follows it.

### Aliyun relay reachability from outside China (2026-11-07 evening, read-only)

- The 2026-06-30 design spec already tested the handoff's "open the relay to all sources" option:
  with the security group open to 0.0.0.0/0 on 22/80/443, about 30 non-China vantage points still
  timed out on every port. It concluded the block is at the platform/border, not the security group.
- Today's derper log (7 days) shows only three client sources: the two China exits (61.159.245.68,
  116.54.18.215) and, once, the DO box 165.22.145.26: `client [LHMYf]` at 00:24:53 CST, ending in
  `read: connection timed out`. So the DO box did complete a TLS session with the relay at least once,
  which means inbound from outside China is throttled or intermittent rather than hard-blocked.
  derper only logs errors, so how long that session lived and how often DO gets in is unknown; the
  DO box's tailscaled log would say.
- From the Aliyun box, egress to the DO box (22 and 443), hs.nclar.ke and 1.1.1.1 all time out;
  baidu answers in 150 ms. The box firewall is Docker-only, derper listens on *:443, *:80, UDP 3478.
- The DO box could not be reached from the laptop on clarke: public port 22 times out from China,
  Tailscale SSH refuses root by policy (any other OS user is allowed, user unknown).

## Podroid watchdog (2026-11-07)

Podroid never restarts its VM after Android kills the app (its only automatic start is
`autostart_on_boot`; checked in the v1.2.9 APK). `phone/podroid-watchdog` runs on the phone as adb's
shell user, `setsid nohup`-detached by `bin/phone-provision` step 3:

- Every 30 s it reads the guest's ssh banner through `127.0.0.1:9922` (`sleep 2 | nc`: nc needs its
  input held open for the banner to arrive). After 3 misses it fires `START_VM` and waits 120 s.
- The shell user runs at `oom_score_adj -1000`, so lmkd leaves it alone. It survives adb disconnects.
  A phone reboot ends it; Podroid's boot autostart brings the VM back, and the next provisioner run
  over adb starts the watchdog again.
- Log `/data/local/tmp/podroid-watchdog.log`, pid `/data/local/tmp/podroid-watchdog.pid`. Pause with
  `/data/local/tmp/podroid-watchdog.pause`.
- Tested on the Pixel 7: `am force-stop com.excp.podroid` at 19:23:36, `START_VM` at 19:24:56, guest
  ssh back at 111 s with traefik up and the tailnet ping to Dokploy working.

Found while re-running the provisioner over the tailnet: step 1 looked up installed versions through
the phone's USB serial, found nothing, and reinstalled Tailscale over the tailnet. That restarted
Tailscale and dropped adb mid-install. Fixed: lookups use the adb target. Always-on VPN brought
Tailscale straight back after the forced restart.
