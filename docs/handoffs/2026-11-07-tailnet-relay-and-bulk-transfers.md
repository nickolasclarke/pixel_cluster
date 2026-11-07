# Handoff: tailnet relay reachability and bulk transfers to the phone guests

Paste this to a fresh agent. Written 2026-11-07 from the pixel_cluster session.

## Goal

Make the Podroid phone guests reliably reachable over Nick's headscale tailnet:

1. **Any tailnet client, from any network, can reach a guest.** That includes clients outside
   China and clients behind Nick's US WireGuard tunnel.
2. **Bulk transfers to a guest complete.** Target: a 300 MB ssh stream finishes every time.

Find root causes before changing anything. Nick prefers the simplest fix that works. He wants to
discuss architecture changes (new relay hosts, opening firewall ports, DERP map changes) before
they're made. Address him as Nick.

## Systems

- **headscale** (control plane): `hs.nclar.ke`, a DigitalOcean box at 165.22.145.26, deployed by
  Dokploy. Config is in `~/repos/headscale-cn/headscale/` (`config.yaml`, `derp.yaml`).
  - The API key is at `~/.config/pixel_cluster/headscale-api-key`.
- **China relay** (DERP region 900, "cn"): Aliyun 47.108.180.69:443, standalone derper (built from
  v1.98.5), self-signed certificate pinned in `derp.yaml`. Design and history are in
  `~/repos/headscale-cn/docs/` (the 2026-06-30 DERP design spec and `status-2026-10-21-resume.md`).
  The spec says the box is unreachable from outside China, probably because of a security-group
  source rule. Nick says getting reliable egress out of China from that box has been a problem.
- **Phones** (repo `~/repos/pixel_cluster`, start with `docs/runbook.md`):

  | Phone | Guest (Podroid Alpine VM) | Android Tailscale node | adb |
  |---|---|---|---|
  | Pixel 7 | `pixel-7-podroid` 100.64.0.11 | 100.64.0.12 | `adb connect 100.64.0.12:5555` |
  | Pixel 6 Pro | `pixel-6-pro-podroid` 100.64.0.10 | 100.64.0.13 | `adb connect 100.64.0.13:5555` |

  - Guest tailscale is 1.98.10. Android app and laptop are 1.104.5.
  - Guest ssh: `ssh -p 2222 root@<guest tailnet IP>` with
    `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`.
  - When the tailnet path to a guest is dead, use the back door:
    `adb -s <android>:5555 forward tcp:0 tcp:9922`, then `ssh -p <port> root@127.0.0.1`.
- **Network:** both phones and the laptop (100.64.0.2) are on the Wi-Fi "clarke", 192.168.15.0/24.
  - The clarke router's WAN is 192.168.1.64 on the upstream "SUN" network.
  - China destinations exit at 61.159.245.68. Some guest traffic also maps to 135.180.36.137,
    which looks like a US exit.
  - Each guest sits behind a second NAT: Android's `avf_tap_*` interface, guest eth0 on a
    172.17.92.x or 10.13.42.x subnet.
- **The 6 Pro runs Hermes** (port 9119), which is in active use. Coordinate before disrupting it.
  The Pixel 7 is free for experiments.

## Evidence so far

All of it is in `pixel_cluster/docs/runbook.md`, section "Tailnet stability investigation".

1. **Clients that can't reach the China relay can't reach the guests at all.**
   - From 14:27 to 14:54 CST the laptop was on SUN-5G with the full-tunnel NetworkManager
     WireGuard `WG-Boyd-Ave` up.
   - Its tailscaled logged `derp.Recv(derp-900): connect to region 900 (cn): context deadline
     exceeded`, and `curl https://47.108.180.69/derp/probe` timed out. The guests on clarke got
     HTTP 200 from the same probe in 37 ms.
   - Laptop-initiated connections to the guests failed until a guest ran `tailscale ping 100.64.0.2`.
   - The guests are behind two NATs, so with no shared relay there is neither a relay path nor
     relay-coordinated hole punching.
   - Back on clarke, the laptop reconnected to derp-900 at 14:54:43 and had a direct path to the
     Pixel 7 guest by 14:55:41.
   - **Unverified:** whether tailscaled's relay socket went into the WG tunnel (its fwmark bypass
     should prevent that) or the SUN network path itself blocks TCP 443 to Aliyun. Checking needs
     root on the laptop.
2. **Bulk transfers to a guest still drop, even on clarke.**
   - Test: `dd if=/dev/zero bs=1M count=300 | ssh -o ServerAliveInterval=10
     -o ServerAliveCountMax=3 -p 2222 root@100.64.0.11 'cat >/dev/null'`.
   - Results: 6 of 6 runs dropped after 58–170 s at 1.8–5.2 MB/s, with the screen on and with it
     off. The same test to the Android Tailscale node (`adb exec-in`) runs a steady 20 MB/s.
   - During each transfer the laptop's tailscaled logs the guest's path going `via=derp` then
     `via=direct` every 20–30 s, plus `derp-900 does not know about peer [VLtW2]`.
   - The guest's own derp-900 connection gets `connection reset by peer` (13 times on the 6 Pro,
     10 on the Pixel 7, over about 16 h). The guests have changed home DERP 123 and 66 times,
     sometimes to US regions at 200–480 ms.
   - Working hypothesis, not tested: under load, disco pongs are delayed or lost in the
     guest -> `avf_tap` -> Android NAT -> Wi-Fi path, so the direct path expires. The relay
     fallback is then broken, and the stall exceeds ssh's 30 s.
3. **Ruled out or fixed already:**
   - The guest keepalive restarting tailscaled is fixed in commit bd81fc9. Since then there have
     been 0 restarts across 6 transfers.
   - Phone memory pressure: the guests are at 4 GB and Podroid stays alive.
   - The GFW for LAN traffic: the direct path is LAN-local and the China relay is in-country.
   - Screen-off Wi-Fi power saving is real (805 ms vs 36 ms pings) but not what drops the
     transfers.
4. **Side findings:**
   - Podroid's userspace port forwards (`podroid-forward`, e.g. phone :30009 -> guest :30009) cut
     a 300 MB upload after 101,200 bytes.
   - The laptop's tailscaled restarts systemd-resolved several times a minute.

## Options Nick is open to for (1)

- Open the Aliyun relay to all sources (Nick's preference). Tailnet membership still gates use.
  Egress from that box out of China has been unreliable.
- Stand up a new relay on Aliyun or similar to test.
- Expose a relay or the guests through Nick's second router, which has outside access. It may not
  be publicly addressable; check.
- Nick is in Japan next week, which allows a test from outside China: the same probe, ping and
  300 MB transfer from a client abroad.

## Constraints

- Use `superpowers:systematic-debugging`. Record every finding in the runbook section above.
- Do not change headscale, the relay, routers or firewall rules without Nick's go-ahead.
- Never put credentials in commits. The repos are public.
- Commit messages end with the attribution lines Nick's setup asks for.
