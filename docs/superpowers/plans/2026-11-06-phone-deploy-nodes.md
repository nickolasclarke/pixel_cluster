# Phones as Dokploy Deploy Nodes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Pixel 7 (`28161FDH200LY1`) a validated Dokploy remote server over the headscale tailnet, with the steps captured as scripts that work for the next phone.

**Architecture:** Bash scripts in `bin/` share `bin/lib.sh`. Pure functions (version parsing, checksum checks, adb output parsing) live in `lib.sh` and are unit-tested with a tiny `tests/run.sh` harness; the scripts themselves are thin wrappers that call adb, ssh, `headscale-cn/commands/hs`, and the `dokploy` CLI. A hands-on spike on the phone (Task 2) comes before the provisioning script, because the design's biggest unknown (Dokploy's setup inside the Podroid guest) is only answerable by doing it.

**Tech Stack:** bash, adb, curl, `gh`, `dokploy` CLI (authenticated to `http://100.64.0.7:3000`), `~/repos/headscale-cn/commands/hs`, ssh, shellcheck.

**Spec:** `docs/superpowers/specs/2026-11-06-phone-deploy-nodes-design.md`

## Global Constraints

- No Google account on any phone; APKs are side-loaded over adb.
- An APK is only installed if its sha256 matches the vendor-published digest.
- Secrets (Dokploy ssh private key, API token, headscale keys) never enter the repo. `apks/` is git-ignored.
- Scripts: `set -euo pipefail`, `--help`, terse stdout, full log path printed at exit, shellcheck clean. Style matches `headscale-cn/commands/`.
- Dokploy server record for a phone: port `9922`, user `root`, ssh key id `46etDVagTkjFQka2nEbhV` (`pixel_6`), type `deploy`.
- Port forwards per phone (`pins/forwards`): `8080 80 tcp`, `8443 443 tcp`, `30000..30009 -> same tcp`. `9922->22` is implicit.
- Pixel 7 VM sizing: 2 cores, 2 GB RAM, 32 GB disk.
- Spike stop condition: if `dokploy server validate` or the nginx deploy cannot be made to pass inside the guest, stop and report to Nick; do not start Task 3.

## Review Focus

1. A phone already registered in headscale or Dokploy must not get a duplicate record on re-run. Test in Task 3 (`find_server_id` returns the existing id).
2. A truncated or tampered APK download must be deleted and the script must exit non-zero. Test in Task 1 (`verify_sha256` on a flipped byte).
3. Vendor pages change shape. The version parsers must fail loudly on no match rather than return an empty string. Test in Task 1.
4. `adb` with several phones attached must never act on the wrong one: every adb call takes `-s <serial>`. Test in Task 3 (`adb_installed_version` parses a fixture for one serial).
5. A registration key pasted with surrounding text or the whole command must still work. Test in Task 3 (`extract_register_key`).

---

### Task 1: Repo scaffold and `bin/apk-fetch`

**Files:**
- Create: `.gitignore`, `bin/lib.sh`, `bin/apk-fetch`, `tests/run.sh`, `tests/test_lib.sh`, `tests/fixtures/tailscale-index.html`, `tests/fixtures/podroid-release.json`, `pins/tailscale.version`, `pins/podroid.version`

**Interfaces:**
- Produces in `bin/lib.sh`:
  - `tailscale_latest_version <index-html-file>` → prints e.g. `1.104.5`; exit 1 and message on stderr if no `tailscale-android-universal-<v>.apk` link found.
  - `podroid_latest <release-json-file>` → prints `<tag> <asset-name> <sha256>` from the asset whose name matches `Podroid-*-release.apk`; exit 1 if missing.
  - `verify_sha256 <file> <expected-hex>` → exit 0 on match; on mismatch deletes `<file>`, prints `checksum mismatch: <file>` to stderr, exit 1.
  - `die <msg>` → stderr + exit 1. `log <msg>` → appends to `$LOG_FILE`, echoes only if `VERBOSE=1`.
- `tests/run.sh` runs every `tests/test_*.sh`, prints one line per test, exits non-zero on any failure. Assertions: `assert_eq <expected> <actual> <name>`, `assert_fails <name> <cmd...>`.

- [ ] **Step 1: Write failing tests in `tests/test_lib.sh`**

```bash
assert_eq "1.104.5" "$(tailscale_latest_version tests/fixtures/tailscale-index.html)" "tailscale version parse"
assert_fails "tailscale no match" tailscale_latest_version /dev/null
assert_eq "v1.2.9 Podroid-v1.2.9-release.apk 3945c8c887f1df239501de6320fe5c8315bf9805029f530373d3244fee0d2a5f" "$(podroid_latest tests/fixtures/podroid-release.json)" "podroid parse"
# verify_sha256: good file passes; flipped byte fails AND file is removed
```

Fixtures: save the real `curl https://pkgs.tailscale.com/stable/` HTML and `gh api repos/ExTV/Podroid/releases/latest` JSON (digest field is `sha256:<hex>`).

- [ ] **Step 2: Run `tests/run.sh`, expect FAIL (functions undefined)**
- [ ] **Step 3: Implement the four functions in `bin/lib.sh`** (grep/sed for the HTML; `python3 -I -c` for the JSON is fine since `jq` is not installed)
- [ ] **Step 4: Run `tests/run.sh`, expect PASS; `shellcheck bin/lib.sh tests/*.sh` clean**
- [ ] **Step 5: Write `bin/apk-fetch [--force] [--app tailscale|podroid]`**

Per app: fetch latest; compare `pins/<app>.version`; print `<app> up to date (<v>)` and skip unless `--force`; else download to `apks/<asset>` with `curl -fL`, get the expected digest (Tailscale: `<url>.sha256` first field; Podroid: from the JSON), `verify_sha256`, then write `pins/<app>.version`. Exit non-zero if any app fails.

- [ ] **Step 6: Manual verification**

Run: `bin/apk-fetch` → downloads both, both `pins/*.version` written. Run again → both "up to date". Copy an APK, flip one byte with `printf '\x00' | dd of=copy bs=1 seek=100 conv=notrunc`, run `verify_sha256 copy <good-hex>` → exit 1, copy removed.

- [ ] **Step 7: Commit** `git add .gitignore bin tests pins && git commit -m "apk-fetch: vendor version check and checksum-verified download"`

---

### Task 2: Spike on the Pixel 7 (hands-on, documented, no scripting)

**Files:**
- Create: `docs/runbook.md` (what was done, exact commands, what each wizard setting was set to, what failed and how it was fixed)
- Create: `pins/forwards`, `pins/packages` (Android package names of both apps, read from `adb shell pm list packages` after install; not guessed)

**Interfaces:**
- Produces facts Task 3 depends on: package names; whether `dokploy server setup` is needed on Alpine; dropbear's authorized_keys path and how to disable password auth; the Dokploy environmentId used for the smoke test.

- [ ] **Step 1: Install both verified APKs**: `adb -s 28161FDH200LY1 install -r apks/<apk>` for each. Record package names into `pins/packages`.
- [ ] **Step 2: Phantom-process fix** (verbatim from Podroid's limitations page):

```bash
adb -s $S shell device_config set_sync_disabled_for_tests persistent
adb -s $S shell device_config put activity_manager max_phantom_processes 2147483647
adb -s $S shell settings put global settings_enable_monitor_phantom_procs false
```

- [ ] **Step 3: Podroid wizard, by hand via scrcpy**: 32 GB, 2 cores, 2 GB, SSH on, Downloads sharing off, grant notifications and unrestricted background. Settings → "Start VM on boot" on. Wait for Ready.
- [ ] **Step 4: Tailscale app**: custom control server `https://hs.nclar.ke`, log in. On the headscale page it opens, copy the key from the `headscale nodes register --user USERNAME --key <key>` line and run it with `~/repos/headscale-cn/commands/hs nodes register --user nick --key <key>`. Confirm with `hs nodes list` that the phone is online; record its 100.64.0.x IP.
- [ ] **Step 5: Direct-path check from the DO box**: `ssh dokploy tailscale ping -c 5 <phone-ip>`. Expected: a `via <ip>:<port>` line (direct), not `via DERP(cn)`. If it stays on a relay after 5 pings, record it in the runbook and stop: this is the relay problem, Nick decides.
- [ ] **Step 6: Guest ssh over adb**: `adb -s $S forward tcp:9922 tcp:9922`; `ssh -p 9922 root@127.0.0.1` with password `podroid`. Fetch the Dokploy public key with `dokploy ssh-key one --sshKeyId 46etDVagTkjFQka2nEbhV` (publicKey field) and append it to the guest's `/root/.ssh/authorized_keys` (mode 700/600). Find dropbear's OpenRC conf and disable password auth (`-s`). Confirm `ssh -i <key> -p 9922 root@<phone-ip> docker info` works from the DO box.
- [ ] **Step 7: Forwards**: in the guest, `podroid-forward add` each line of `pins/forwards`. `podroid-forward list` shows them.
- [ ] **Step 8: Dokploy server**: `dokploy server create --name pixel7-0LY1 --ipAddress <phone-ip> --port 9922 --username root --sshKeyId 46etDVagTkjFQka2nEbhV --serverType deploy --json`. Then `dokploy server validate --serverId <id>`. If it demands setup, run `dokploy server setup --serverId <id>` and record exactly what it ran and whether it worked on Alpine. Note: `server get-default-command` and `environment by-project-id` returned 400 from the CLI during planning; find the right parameters or use the REST API at `http://100.64.0.7:3000/api/...` with the same token.
- [ ] **Step 9: Smoke test**: `dokploy application deploy-nginx-quickstart --environmentId <Personal project env> --serverId <id>`; add a host port with `dokploy port create --publishedPort 30000 --targetPort 80 --publishMode host --protocol tcp --applicationId <appId>` and redeploy. Expected: `curl -s http://<phone-ip>:30000/` from the laptop returns nginx HTML.
- [ ] **Step 10: Write `docs/runbook.md` and commit**: `git add docs/runbook.md pins && git commit -m "runbook: Pixel 7 spike, Dokploy validated against Podroid guest"`

---

### Task 3: `bin/phone-provision <serial>`

**Files:**
- Modify: `bin/lib.sh`
- Create: `bin/phone-provision`
- Test: `tests/test_lib.sh`, fixtures `tests/fixtures/pm-dump.txt`, `tests/fixtures/hs-nodes.json`, `tests/fixtures/dokploy-servers.json`

**Interfaces:**
- Consumes: `pins/packages`, `pins/forwards`, Task 2's runbook facts, `verify_sha256`.
- Produces in `bin/lib.sh`:
  - `adb_installed_version <serial> <package>` → prints `versionCode` from `adb -s <serial> shell dumpsys package <package>`, or empty if not installed. Parser is `parse_version_code <dumpsys-text>` (tested on fixture).
  - `extract_register_key <text>` → prints the `mkey:`/key token from any text containing `--key <key>`; exit 1 if none.
  - `node_ip_by_hostname <hs-nodes-json> <hostname>` → tailnet IPv4 or exit 1.
  - `find_server_id <servers-json> <name>` → serverId or empty.
  - `phone_server_name <serial> <model>` → e.g. `pixel7-0LY1` (model lowercased without spaces, last 4 of serial).

- [ ] **Step 1: Write failing tests** for the five functions against the fixtures (fixtures captured from the real Pixel 7 in Task 2). Include: `extract_register_key` on the full `headscale nodes register --user USERNAME --key <k>` line and on the bare key; `find_server_id` returns the existing Pixel 6 id and empty for an unknown name.
- [ ] **Step 2: Run tests, expect FAIL**
- [ ] **Step 3: Implement the functions**
- [ ] **Step 4: Run tests, expect PASS; shellcheck clean**
- [ ] **Step 5: Write `bin/phone-provision <serial>`** as the runbook, scripted and idempotent:
  1. install each APK whose installed versionCode is missing or lower (versionCode of the APK read from the device after install; before install, compare on `pins/<app>.version` vs a `pins/<app>.installed.<serial>` marker written on success);
  2. phantom fix, always (idempotent);
  3. if the phone is not in `hs nodes list`: print the manual wizard and Tailscale steps, prompt `paste the register line:`, `extract_register_key`, run `hs nodes register --user nick --key`;
  4. poll `hs nodes list -o json` up to 60 s for the node online; `node_ip_by_hostname`;
  5. `adb forward`, install Dokploy key and dropbear change if not already present, apply `pins/forwards` if `podroid-forward list` lacks them;
  6. `find_server_id` else `dokploy server create`; `dokploy server validate`;
  7. print `<name> <ip> <serverId> validated` and the log path.
- [ ] **Step 6: Verify on the Pixel 7**: run it; every step reports "already" and it ends with the validated line. Then `dokploy server remove` the record and re-run from step 6 only: a new record appears, exactly one.
- [ ] **Step 7: Commit** `git add bin tests pins && git commit -m "phone-provision: idempotent per-phone setup through Dokploy validation"`

---

### Task 4: `bin/phone-status` and README

**Files:**
- Create: `bin/phone-status`, `README.md`

**Interfaces:**
- Consumes: `adb_installed_version`, `pins/*.version`, `node_ip_by_hostname`, `find_server_id`, `dokploy server all`.

- [ ] **Step 1: Write `bin/phone-status`**: one line per attached phone: `serial model tailscale:<installed>/<pinned> podroid:<installed>/<pinned> node:<online|offline|none> dokploy:<serverStatus|none>`. Exit 1 if any phone is behind a pin.
- [ ] **Step 2: Verify**: with the Pixel 7 attached it prints one line, both versions equal, `node:online`, `dokploy:active`.
- [ ] **Step 3: README.md**: what the repo is, the three commands, where secrets live (nowhere here), pointer to the spec, runbook, and the phase-two swarm note.
- [ ] **Step 4: Commit** `git add bin/phone-status README.md && git commit -m "phone-status fleet view and README"`
