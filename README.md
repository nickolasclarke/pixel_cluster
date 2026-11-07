# pixel_cluster

Spare Android phones as Docker hosts that Dokploy deploys to. Each phone runs
[Podroid](https://extv.github.io/Podroid/) (an Alpine VM with dockerd); inside that VM,
tailscale joins the headscale tailnet and OpenSSH on 2222 is Dokploy's ssh target.

- Design: `docs/superpowers/specs/2026-11-06-phone-deploy-nodes-design.md`
- What it took on the first phone, and the networking facts behind the design: `docs/runbook.md`

## Commands

| Command | Does |
|---|---|
| `bin/apk-fetch [--force] [--app tailscale\|podroid]` | Checks Tailscale's and Podroid's official channels for a newer APK, downloads into `apks/`, verifies the vendor sha256, records the version in `pins/`. |
| `bin/phone-provision <adb-serial> [--reinstall]` | One phone, start to "registered as a Dokploy server and validated". Idempotent; stops with instructions at the one manual step (Podroid's first-run wizard). |
| `bin/phone-status` | One line per attached phone: APK versions vs pins, tailnet state of the guest and Android nodes, Dokploy status. Exit 1 if anything is behind or missing. |
| `bin/phone-soak` | `run`: every 5 min, one line per phone of reachability, latency, restarts and Dokploy validate (no transfers). `summary`: per-phone report of a soak file. |

`tests/run.sh` runs the unit tests; `shellcheck $(grep -l '^#!.*sh' bin/*) tests/*.sh` (the shell scripts; `bin/natpath` is Python) must be clean.

## Secrets

None live here. The Dokploy API token is the CLI's own config, headscale preauth keys are minted per
run (via `~/.config/pixel_cluster/headscale-api-key` if present, else the `hs` wrapper over ssh), and
the Dokploy ssh private key stays in Dokploy. `apks/` is git-ignored.

## Later: a phone-only swarm

One phone as swarm manager and Dokploy's remote server, the others joining it over the local Wi-Fi.
Needs prebuilt images or a registry, and node labels if any phone lacks AVF (both so far have it). Decided
after more than one phone is provisioned.
