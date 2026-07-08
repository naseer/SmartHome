# AGENTS.md — SmartHome project

Orientation for any agent/session working in this repo. Full rationale lives in
`home-server-smart-home-plan.md` (the source of truth for every decision). This file is the
quick "what/where/how" so a fresh session can continue without re-deriving context.

## What this is

Two intertwined projects:
1. **`masn` revamp** — a Dell OptiPlex 5050 SFF home server (i7-7700, 32 GB) re-platformed to a
   clean Ubuntu Server + Docker stack (Home Assistant, Frigate, MQTT, Postgres).
2. **Smart-home build** for a 3-floor / 3200 sqft house (50 Westacott Crescent, Ajax ON).

Bias throughout: **local-first / no-cloud, security-first, test-before-commit, reproducible infra.**

## Repo layout

- `home-server-smart-home-plan.md` — master plan; all decisions + BoM (~$4,960) + runbook.
- `masn-stack/` — reproducible Docker stack + Phase 0 scripts (see below).
- `AGENTS.md` (this file), `.gitignore`.

## Status (as of 2026-06-29)

- **BLOCKED:** NAS arrived, but the 1st IronWolf Pro 12 TB was **DOA (clicking)** on first power-up
  (2026-06-29). Returned/RMA'd. Phase 0 is paused until a working disk arrives. Do NOT wipe masn
  (it holds the only copy of the 382 GB media library; no valid NAS backup target yet). Burn-in the
  replacement before trusting it.
- Original plan: NAS up → copy media → AHCI + clean install → bring stack online (resumes once disk replaced).
- **Greenfield**: user confirmed NO irreplaceable data on masn → backup-before-wipe gate WAIVED,
  EXCEPT copy the media library to the NAS first (see runbook).
- Storage: **1× 14 TB now, mirror added in a few months** (Google stays the off-site copy meanwhile).

## Key architecture decisions (quick ref — full rationale in the plan)

- **Host**: reuse the 5050 (`masn`), 32 GB; clean-install Ubuntu Server; switch BIOS SATA
  **RAID On → AHCI** (currently RAID On; AHCI also needed to see the NVMe). OS disk = **NEW 1 TB
  NVMe** (~$80). The old WD Blue 1 TB SATA SSD (`sda`) is **WORN OUT** (Media_Wearout=001; cold
  reads 2.7–4 MB/s) — retire it after the media copy. i7-7700 / 32 GB / HD 630 all fine.
- **Storage / NAS**: UGREEN **DXP4800 Pro** on **UGOS with btrfs** (checksums + snapshots +
  in-place single→RAID1; ext4 rejected. btrfs is the UGOS stand-in for ZFS; TrueNAS+ZFS is the
  alt). 1× **14 TB Toshiba N300 (HDWG21E)** now (the 1st IronWolf Pro 12 TB was DOA — clicking —
  and returned) → add 2nd 14 TB later for a mirror (btrfs add-drive→RAID1, in place). Frigate
  cache stays LOCAL on masn's SSD;
  bulk (recordings/media/backups/family photos) on the NAS.
- **Network**: ALL-**UniFi** — **UCG-Fiber** gateway in the **basement rack** (router + firewall/IDS
  + controller; NO Wi-Fi; 10G SFP+ WAN, 5G IDS = full 3G) + USW-Pro-Max-16-PoE (basement, 10G DAC to
  gateway) + **3× U7 Pro** APs, ONE PER LEVEL (basement ceiling + floors 1/2 WALL — no ceiling access
  on the finished floors). Floor-2 AP has no Cat6 path → backhauled over **MoCA/coax** (+ its own PoE
  injector). RELOCATE the cable modem down to the basement demarc so modem+gateway+switch+NAS+masn
  share ONE rack UPS. UDR7 was considered (modem is currently on floor 2) but REJECTED — radio wasted
  in the rack + 2.3G IDS cap. Ordered so far: 1× UCG-Fiber + 1× U7 Pro Wall; 2 more APs later. ASUS
  BT10 **sold** (its weak VLAN software was the reason to switch). VLANs:
  Trusted / Cameras / IoT (Cameras+IoT firewalled off the NAS).
- **Radios** (two, each dedicated): **SLZB-06** = Zigbee coordinator, network-attached, mounted
  CENTRAL on floor 1, Z2M over TCP (Ethernet + USB power; PoE later). **ZBT-2** = Thread Border
  Router, USB on masn in the basement (OK because the 9 mains Thread switches are dense routers).
- **Zigbee software**: **Zigbee2MQTT** (not ZHA) — bridges to Mosquitto; resilient + best Aqara/Tuya support.
- **Protocol split (hybrid)**: **Thread** = the 9 owned TP-Link mains lighting switches.
  **Zigbee** = all battery sensors + garage + thermostat (Zigbee SKU) + ~4 mains "router" plugs
  (one/floor) to seed the Zigbee mesh.
- **Cameras**: Frigate + **OpenVINO** on the HD 630 iGPU (Coral EOL; P620 is the relief valve).
  Pull every camera through **go2rtc** (Reolink RTSP is finicky). Dual-stream: detect on substream,
  record on mainstream; H.265; 15-day continuous retention.
- **Garage door**: **Aqara Dual Relay T2** (DCM-K01, dry-contact, the "button") + **ThirdReality
  tilt sensor** (3RDTS01056Z, the "state") — both Zigbee via Z2M, hub-free. No native Thread option exists.
- **Jellyfin** runs ON the NAS (not masn). **Family Google Photos/Drive** → Immich + Nextcloud on
  the NAS; **Google stays primary** (= the off-site copy; 3-2-1 satisfied).
- **Remote access**: **Nabu Casa** for HA; **Tailscale per-host** (NAS, masn) for Jellyfin/admin —
  never a whole-subnet route (preserves VLAN segmentation). No port-forwarding.

## masn access

- SSH: `ssh masn` (key-based; same access used for the RAM/SMART checks).
- **sudo on masn requires a password** → the user runs privileged commands or approves them.
- Media library to preserve pre-wipe: `/local/mnt/workspace/naseer/jellyfin` (382 GB, on `sda`).

## Phase 0 runbook

**BUILD STATUS 2026-07-06**: masn REIMAGED — clean **Ubuntu Server 24.04.4 LTS on the NEW 1TB
NVMe** (`nvme0n1`, LVM/ext4); SATA in **AHCI**; worn SATA SSD pulled. **Core stack is UP**
(Docker 29.6 CE from docker.com; HA + Mosquitto + Postgres running via `setup-masn.sh`). HA live
at `http://192.168.50.50:8123` (onboarding). Internal secrets (PG/MQTT/Frigate) generated on-box
into `/opt/stack/.env` (600). NAS mounts use **PER-SHARE least-privilege creds** (§6.8): create two
UGOS users — **`frigate`** (rw `frigate` share only) + **`masn`** (rw `backup` + `media`).
**NAS MOUNTS LIVE + VERIFIED (2026-07-06)**: `/mnt/nas/{frigate,backups,media}` all mounted rw via
per-share creds (`creds-frigate`/`creds-masn`, 600 root); isolation confirmed — `frigate` creds are
REJECTED by the `backup` + `media` shares. media shows ~382 GB used (library intact). Note: backups
mountpoint is `/mnt/nas/backups` but the SHARE is `//NAS/backup` (singular). Nabu Casa LINKED (user).
**Recorder→Postgres DONE + VERIFIED (2026-07-06)**: `recorder.db_url: !secret recorder_db_url` in
configuration.yaml; the URL (`postgresql://hauser:***@127.0.0.1:5432/homeassistant`) lives in
`config/secrets.yaml` (600); 13 HA tables created in the `homeassistant` DB, `states` growing.
Orphaned `home-assistant_v2.db*` (SQLite) can be deleted. REMAINING: enable Frigate/Z2M as hardware
arrives. NOTE: user set **passwordless sudo temporarily** for setup — REVERT it when done.

1. **NAS wizard (user, web UI)**: btrfs single-disk pool (UGOS); shares `media` / `frigate` / `backups` /
   `family-shared` / per-member private / encrypted `sensitive-docs` (§6.8). All over SMB (UGOS
   default); masn mounts via cifs. No guest access. Note NAS IP + share names + the SMB user.
2. **Copy media (agent, SSH to CURRENT masn)**: `masn-stack/copy-media.sh` → media to NAS,
   ~1 h over 1GbE, verify (count + checksum sample) BEFORE the wipe.
3. **Clean install (user, console)**: BIOS SATA RAID On → **AHCI**; install Ubuntu Server onto
   `sda` (UEFI; Secure Boot off if the P620 will be added). Verify `lspci|grep -i sata` = [AHCI mode].
4. **Stand up stack (agent, SSH to fresh masn)**: fill `masn-stack/.env`, run
   `masn-stack/setup-masn.sh` (Docker, `/opt/stack`, mosquitto user, NAS fstab, `compose up` core).
   HA onboarding at `http://<masn-ip>:8123`; paste `homeassistant/configuration-snippet.yaml`.
5. **Link Nabu Casa (user, HA UI)**: Settings → Home Assistant Cloud → sign in. Subscription is
   already active (set up 2026-06-25); this connects the running instance. Unlocks remote UI +
   mobile push + cloud TTS/STT. Built-in `cloud:` integration — nothing to add to compose.

## masn-stack usage

- `docker-compose.yml`: **HA + Mosquitto + Postgres active**; Frigate / Zigbee2MQTT are
  COMMENTED — enable each as its hardware arrives (cameras / SLZB-06). Audio = NuTone IM-3303 + a
  standalone WiiM at the AUX (no audio container on masn). Mosquitto+Postgres bind to `127.0.0.1`
  only (host-mode HA reaches them; LAN can't). NAS SMB (cifs) mounts use `nofail`.
- `.env.example` → copy to `.env`, fill, `chmod 600` (gitignored). Never commit real secrets.
- `copy-media.sh`, `setup-masn.sh`: review before running; need sudo. Idempotent-ish.

## HA automations-as-code (SSH + API, NOT MCP)

- Author automations/scripts/templates as YAML in `masn-stack/homeassistant/packages/` (version
  controlled). configuration.yaml has `homeassistant: packages: !include_dir_named packages/`.
  UI-created automations still live in `automations.yaml` and coexist.
- Deploy: `rsync -az masn-stack/homeassistant/packages/ masn:/opt/stack/homeassistant/config/packages/`
- Apply: `ssh masn 'bash ~/SmartHome/masn-stack/homeassistant/ha-reload.sh'` (check_config + reload_all;
  hot-reloads automations/scripts -- a NEW package file or integration needs `docker restart homeassistant`).
- Needs `HA_TOKEN` in `/opt/stack/.env` (long-lived token, HA > Profile > Security). Set silently via
  `ssh -t masn 'bash ~/SmartHome/masn-stack/set-ha-token.sh'`. Chose SSH+API over an HA MCP server
  (MCP = device control, not config authoring). Starter package: `packages/system.yaml` (HA-start notice).
- Voice assistant = DEFERRED to Phase 7 (Orin) per user (2026-07-07). Destination = fully-local Assist
  pipeline on the Jetson Orin (whisper + Piper + Ollama via Wyoming); cloud/Claude agent considered but
  not wanted now. Do NOT re-propose until the Orin is online.

## nas-stack (runs ON the UGOS NAS, not masn)

- `nas-stack/docker-compose.yml`: **Jellyfin** (media + `/dev/dri` Quick Sync, reads media LOCALLY
  read-only) + **Tailscale** (container: host net + NET_ADMIN + `/dev/net/tun`; MagicDNS `nas`).
  Deploy via UGOS Docker (Projects/compose if available, else recreate in the GUI).
- `nas-stack/tailscale-acl.hujson`: sample ACL restricting `group:family` to `tag:media:8096` only.
- `nas-stack/.env`: holds `TS_AUTHKEY` (gitignored). Jellyfin PUID/PGID must read the media share.

## Remote-access architecture (three lanes)

- **Cameras + smart home + HA** → **Nabu Casa** (linked). Frigate surfaces cameras INSIDE HA, so
  Nabu Casa proxies live view/events/clips remotely -- no Tailscale needed. Use camera SUB-stream
  for smooth remote live. Cameras stay firewalled (never internet-exposed).
- **Jellyfin media** → **Tailscale** (NAS node; standalone app Nabu Casa can't proxy). Family via
  Tailscale node SHARING (keeps them off your seat limit) + ACL to `nas:8096` + per-user Jellyfin
  accounts. Caveat: each remote device needs the Tailscale app; remote smart-TVs are the exception.
- **SSH/admin to masn/NAS** → **Tailscale**. masn UP (2026-07-07): tailnet IP `100.83.165.11`,
  **subnet router `192.168.50.0/24` approved + active** (whole LAN reachable via masn), Tailscale
  SSH on, IP-forwarding persistent, `ethtool` UDP-GRO tune APPLIED + persisted (tailscale-ethtool.service).
  NOT an exit node (subnet router suffices for reaching home devices; add `--advertise-exit-node` only
  to route internet through home). Key expiry DISABLED for masn (2026-07-07). NAS will get its OWN TS
  node later for direct remote Jellyfin (see nas-stack).

## Conventions (also see `~/.claude/CLAUDE.md`)

- **Secrets**: never commit. `.env` gitignored; `.env.example` committed with placeholders. Same
  for mosquitto `passwd` and the Z2M network key.
- **No emojis** in code/docs. Immutability. Many small files. **Conventional commits** (`feat:`,
  `fix:`, `chore:`, `docs:`…). Test before commit.
- Confirm before destructive or outward-facing actions.

## Pending / next

- **masn OS SSD WORN OUT → NVMe ORDERED (2026-07-03).** Media copy DONE + VERIFIED
  (`rsync --size-only`: 0 missing, 382G=382G, 3498 files) despite the failing SSD — retire the SSD
  after rebuild. Execute Phase 0 (AHCI → install on NVMe → setup-masn.sh) once the NVMe arrives.
- **At reimage**: add the personal-backup cifs mount on masn — share `personal_folder` (Samba `%H`
  -> `/home/naseer`), auth as **naseer** (separate `/etc/samba/creds-naseer`, chmod 600), mount at
  `/mnt/nas/personal` with `file_mode=0600,dir_mode=0700`. GOTCHA: **UGOS blocks rsync-over-SSH**
  (`ug_start_server` rejects all paths) — so personal backup must use the **SMB mount**, or
  tar-over-ssh, or enable UGOS's rsync service. NAS SMB shares: `media`, `personal_folder`
  (per-user home), `TimeMachine`, `masjidmapper`. NAS users: naseer(1000), jellyfin, zaid, masjidmapper.
- Add 2nd 14 TB → mirror (a few months); resume regular NAS backups once real data exists.
- Buy (see plan BoM): SLZB-06 + USB-C brick, ZBT-2, UniFi (UCG-Fiber + 10G DAC + 16-PoE + 3× U7 Pro; 1 UCG-Fiber + 1 U7 Pro Wall already ordered) + floor-2 MoCA kit,
  cameras (single-lens Reolink/Amcrest + ≤1 Duo for coverage), ~4 Zigbee plug routers,
  Sinopé Zigbee thermostat, Aqara T2 + ThirdReality tilt sensor.
