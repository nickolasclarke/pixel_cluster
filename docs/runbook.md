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
| 2 | RAM / cores / bandwidth | 2 GB / 4 / Unlimited (Podroid says 8 cores is slower than 4 on QEMU) |
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
- Swarm advertise address is the public exit IP (`135.180.36.137`): harmless for a one-node swarm,
  wrong for the phase-two phone swarm, which must use the guest's LAN address.
- The phone sat in landscape with auto-rotate on; `settings put system accelerometer_rotation 0`
  and `user_rotation 0` did not take effect immediately. Taps were done in landscape coordinates.

