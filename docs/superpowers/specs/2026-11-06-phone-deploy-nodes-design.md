# Phones as Dokploy deploy targets over the headscale tailnet

Design, 2026-11-06. Approach chosen by Nick in conversation.

## Intent

Turn a pile of spare Android phones (Pixels first, then OnePlus) into Docker hosts that
Dokploy can deploy to. Each phone runs Podroid (an Alpine VM with dockerd) and joins the
existing headscale tailnet with the official Tailscale Android client. Dokploy, on the DO box,
reaches each phone's VM over the tailnet by ssh and treats it as a remote server.

Prove it end to end on the Pixel 7 that is on adb now. Capture every step as a script so the
other phones are a loop, not a repeat.

## Goals

- One command provisions a phone from "USB-attached, developer mode on" to "registered as a
  Dokploy server and validated".
- A second command fetches the latest Tailscale and Podroid APKs from the vendors' official
  channels, verifies them, and reports whether an installed phone is behind.
- No Google account on any phone. APKs are side-loaded over adb.
- A deployment from Dokploy to the Pixel 7 runs and is reachable.

## Non-goals

- Relay redesign. Nick and the phones are in China, so a phone's home DERP is the Aliyun
  `cn` relay, which the DO box cannot reach (the October blocker). The first thing the spike
  proves is a *direct* path instead: udp/41641 is now open on the DO firewall, so a phone can
  punch straight to the box's public endpoint and no relay is needed. If direct fails, the
  relay topology goes to the headscale-cn repo or another session, not this one.
- Joining the DO box's Swarm. Phones are Dokploy "remote servers", not workers of the main
  cluster. (Dokploy makes each remote server its own single-node swarm; that is in scope.)
- Phase two, not here: a phone-only swarm. One phone is the manager and Dokploy's remote
  server; the others join it as workers over the local Wi-Fi. Dokploy deploys to the manager
  and swarm spreads tasks. Needs prebuilt images or a registry, and node labels for the slow
  (QEMU) vs fast (AVF) phones if any phone lacks AVF; both provisioned so far have it.
- Performance tuning. (Written before the spike: Podroid's docs list AVF as Pixel 8+, but the
  Pixel 7 and Pixel 6 Pro both run the guest under AVF/pKVM via crosvm; see the runbook.)
- Driving the Podroid or Tailscale GUIs from a script. First-run wizards are done by hand
  (scrcpy is available). Everything after the wizards is scripted.

## Anti-goals

- Opening the Dokploy panel to the internet. The panel stays behind its Traefik IP allowlist;
  the CLI reaches it over the tailnet at `100.64.0.7:3000`.
- Installing an APK whose checksum does not match the vendor-published digest.
- Storing the Dokploy ssh private key, headscale preauth keys, or API tokens in this repo.

## Constraints and facts verified today

- Headscale `hs.nclar.ke` is behind Dokploy's Traefik on the DO box. The DO firewall now
  allows 443 from anywhere. Port 80 and udp/3478 are not needed: certs come from a DNS-01
  challenge and the embedded DERP is off.
- Tailscale SSH is on for the DO box node, and the policy allows nonroot users only, so
  `ssh root@100.64.0.7` is refused. Operator ssh to the box stays on the public IP via the
  `dokploy` ssh alias.
- Dokploy already has a server record "Pixel 6" at `100.64.0.6:9922`, user `root`, ssh key
  `pixel_6`. That key is reused for every phone. In October Dokploy never got an ssh
  connection to that phone (the relay blocker), so `dokploy server validate` has never run
  against a Podroid guest. Dokploy's remote-server setup runs `docker swarm init` on the
  target and deploys its own Traefik there; whether that works in the Alpine guest behind
  SLIRP is the largest unknown in this design.
- The Tailscale Android app has no auth-key field. With a custom control server it opens a
  headscale page that shows `headscale nodes register --user <user> --key <key>`; that is how
  the Pixel 6 Pro and Pixel 7a were registered. Preauth keys are not used for phones.
- Podroid port forwards can be managed from inside the guest with `podroid-forward`, so the
  provisioning script owns them over ssh. Host ports below 1024 cannot be bound on the phone.
- Podroid (per its docs; the AVF guest instead gets DHCP from Android tethering): guest IP
  `10.0.2.15` behind QEMU SLIRP NAT; port forwards bind `0.0.0.0` on the
  phone, so Dokploy can reach the guest's dropbear at `<phone tailnet IP>:9922`. Android 12+
  kills backgrounded QEMU unless the phantom-process limit is raised over adb. "Start VM on
  boot" exists in Settings. Intents `com.excp.podroid.action.START_VM` and `STOP_VM` exist.
- Verification sources: Tailscale publishes `<apk>.sha256` next to each file at
  `pkgs.tailscale.com/stable/`; GitHub's release API returns a `digest` (sha256) per Podroid
  asset. Neither vendor publishes a detached signature. Signer-certificate pinning was
  considered and dropped (Nick's call): Android itself refuses to update an installed app
  with one signed by a different key, so checksums on the laptop plus that on-device check
  are the supply-chain controls.
- The Pixel 7 is `28161FDH200LY1`, Android 16, unrooted, with no Podroid or Tailscale installed.

## Approaches considered

1. **Tailscale Android app + Podroid ssh on 9922 + Dokploy remote server.** Chosen. It is what
   the October attempt built, Dokploy records already exist for it, and it has the fewest
   unknowns. Cost: two apps per phone, and the Tailscale app holds Android's single VPN slot.
2. **Tailscale inside the Alpine guest.** The VM becomes the node. Unverified whether the guest
   kernel has `tun`; userspace mode would need a SOCKS proxy for outbound. More discovery for
   no gain. Rejected.
3. **Docker Swarm worker.** Needs several TCP and UDP ports in both directions through SLIRP
   NAT. Rejected as fragile.

## Design

### Repo layout

```
pixel_cluster/
  bin/apk-fetch        # vendor update check, download, verify checksum
  bin/phone-provision  # one phone, start to Dokploy-validated
  bin/phone-status     # what is installed/registered on each attached phone
  apks/                # git-ignored; downloaded, verified APKs
  pins/                # committed: last-known versions and the port-forward list
  docs/                # runbook with the manual GUI steps and screenshots
```

Scripts are bash with `set -euo pipefail`, `--help`, and terse output; full logs go to a file
the script names at the end. This matches the headscale-cn `commands/` style.

### apk-fetch

For each app (`tailscale`, `podroid`):

1. Ask the vendor for the latest version: Tailscale by scraping the stable index, Podroid via
   `gh api repos/ExTV/Podroid/releases/latest`.
2. Compare with `pins/<app>.version`. Exit 0 with "up to date" if equal, unless `--force`.
3. Download into `apks/` and verify sha256 against the vendor-published digest. A mismatch
   deletes the file and exits non-zero.
4. On success, update `pins/<app>.version` and print the new version.

### Spike first: validate Dokploy against one Podroid guest by hand

Before any scripting, on the Pixel 7: install both apps, register, confirm from the DO box
that `tailscale ping <phone>` reports a direct path rather than a relay, open 9922, install the
Dokploy key, then run `dokploy server setup` and `dokploy server validate` and one deploy by
hand. Record what setup does on Alpine and whether swarm init and Dokploy's Traefik come up in
the guest. If this fails in a way that cannot be fixed inside the guest, stop and bring it back
to Nick; the scripts below assume it passes.

### phone-provision <serial>

Idempotent: every step checks before acting, so re-running after a manual wizard step
continues from there.

1. `adb -s <serial> install -r` each verified APK if the installed `versionCode` is older.
2. Apply the phantom-process fix: `device_config put activity_manager
   max_phantom_processes 2147483647` and `settings put global settings_enable_monitor_phantom_procs
   false`. Exact commands are confirmed against Podroid's troubleshooting page during
   implementation, not invented.
3. Print the manual steps and wait: Podroid wizard (disk, RAM, cores, SSH on, "start on boot"
   on, background permission), then Tailscale app login with custom server
   `https://hs.nclar.ke`. The phone shows a `headscale nodes register ... --key <key>` page;
   the operator pastes that key into the script, which runs the register command through
   `headscale-cn/commands/hs` as user `nick`.
4. Poll `hs nodes list` until the phone is online; record its tailnet IP.
4a. Over ssh, add the port forwards the phone needs with `podroid-forward`: `9922->22` is
   implicit, plus `8080->80` and `8443->443` for Dokploy's Traefik in the guest, and a fixed
   range `30000-30009` for published app ports. The list lives in `pins/forwards` so every
   phone gets the same set.
5. Over `adb forward tcp:9922 tcp:9922`, ssh into the guest as `root`/`podroid`, install the
   Dokploy public key into `/root/.ssh/authorized_keys`, and disable password login in
   dropbear. Confirm `docker info` works in the guest.
6. `dokploy server create` with name `<model>-<serial-suffix>`, ip `<tailnet IP>`, port
   `9922`, user `root`, the `pixel_6` key id, type `deploy`. Then `dokploy server validate`.
   If validate wants Dokploy's setup script, run `dokploy server setup` and record what it
   does to Alpine; the guest already has dockerd, so setup may be skipped if it assumes apt.
7. Deploy a smoke-test app (nginx hello page) to the new server through the CLI with a
   published host port from the reserved range, and curl `<tailnet IP>:<port>` from the laptop.
   Domain routing through the guest's Traefik is a later concern.

### phone-status

Lists attached phones, installed versions of both APKs vs `pins/`, headscale node state, and
Dokploy server status. This is the "are we behind?" view for the fleet.

### Verification of done

- `bin/phone-provision 28161FDH200LY1` completes, `dokploy server validate` passes, and the
  smoke-test app answers over the tailnet.
- `bin/apk-fetch` reports both apps up to date and refuses a tampered APK (test by flipping a
  byte in a copy).
- A runbook in `docs/` records the manual wizard steps with what each setting was set to.

## Left to the builder

- Whether dropbear in the guest reads `/root/.ssh/authorized_keys` and how its OpenRC args
  are set, for disabling password auth.
- What `dokploy server setup` actually runs, and whether to skip it.
- Podroid's VM sizing for the Pixel 7 (my call: 2 cores, 2 GB RAM, 32 GB disk, revisit after
  the smoke test).
