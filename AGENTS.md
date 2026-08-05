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

## Status (as of 2026-08-05)

**LIVE — the stack is in daily use.** Phase 0 is DONE; masn runs the full local-first stack and the
smart home is operational. What's running:

- **Core**: HA + Mosquitto + Postgres (recorder → Postgres) on Ubuntu 24.04 / NVMe / AHCI. HA at
  `http://192.168.50.50:8123`, Nabu Casa linked. NAS mounts (`/mnt/nas/{frigate,backups,media}`) live.
  **Mosquitto publishes on TWO explicit bindings (2026-08-04)**: `127.0.0.1:1883` (host-mode HA) and
  `${MASN_LAN_IP}:1883` for the cross-box Frigate to come — NOT `0.0.0.0`, which would also expose it
  on the tailnet. Its password was rotated at the same time (the old one had leaked in a traceback).
  GOTCHA when changing MQTT creds: Frigate and Z2M read `${MQTT_PASSWORD}` from `/opt/stack/.env`, but
  **HA keeps its copy in a UI config entry in root-owned `.storage` and rewrites that file on
  shutdown** — edit it with HA STOPPED or the change is silently lost.
- **Cameras**: **Frigate on OpenVINO (HD 630 iGPU)** with **6 cameras + the TrackMix tele lens**,
  go2rtc restream, 24/7 continuous recording to the NAS. PERSON detection.
  Detector model is **`yolo_nas_s` @ 320 (swapped off ssdlite 2026-08-04)** running on **two** detector
  processes — YOLO-NAS costs ~31 ms vs ssdlite's 8 ms, so one process could not keep up. Regenerate the
  model with `masn-stack/tools/export-yolonas.sh`; check load with `tools/frigate-detector-stats.sh`.
  **Detect fps is 3, not 5** — cut as an emergency because detection and VAAPI decode share the one
  HD 630, and YOLO-NAS pinned it at max clock so video playback crawled. Person `min_area: 0.005`
  filters YOLO-NAS's false hits on fixed objects across the street (they are 0.09-0.40% of frame;
  real people are 1.3-21%, and scores overlap so only SIZE separates them).
  See `masn-stack/frigate/config/config.yml`.
- **Zigbee**: **Z2M + SLZB-06** coordinator live; devices paired incl. the **garage relay** (Aqara T2 —
  opens/closes via `script.garage_door_pulse`) and the **garage
  door contact sensor** (ThirdReality). The two are combined into **`cover.garage_door`** (template cover:
  state from the contact, movement from a relay pulse) — use that entity, not the raw script. An
  **auto-close after 30 min open** automation rides on it (2-min "Keep open" warning, then close +
  verify, 3 attempts). Both garage devices are `retain: true` in Z2M so state survives an HA restart.
- **Dashboards**: a SINGLE default **Overview** (Home / Cameras / Review), deployed from
  `masn-stack/homeassistant/dashboards/overview.json` via `tools/apply-dashboard.sh`. (The old duplicate
  `dashboard-westacott` was deleted 2026-08-02 — one source of truth now.)
- **Notifications**: person alerts live. **Vehicle alerts AND vehicle *detection* are DISABLED** pending a
  detector upgrade — the weak ssdlite model false-fired on parked-car box flicker.

**NEXT BIG THING — Frigate moves to the Jetson AGX Orin.** DECIDED 2026-08-04, plan in
**`docs/orin-frigate-migration.md`**. The HD 630 hit the relief-valve trigger the plan itself defined
(">~25ms = saturating"; measured 28-31 ms), and detection + video decode now fight over the one iGPU.
**Flash JetPack 6.2.2, NOT 7.2** — Frigate publishes no jp7 image. Phase 1a/1d (broker LAN bind +
password rotation) are DONE; the rest waits on the Orin being flashed and given a static IP. Note it
reverses the plan's "security detection stays on the always-on box" principle — the Orin becomes
must-never-be-down, so masn keeps the ability to take Frigate back.

**Open camera/detector threads → `masn-stack/OPEN-THREADS.md`** (git-tracked, portable): the disabled
vehicle detection + the directness-gate fix kept for later, auto-dismiss of expired-clip notifications,
and Ring-style timeline scrubbing. Read that file to resume any of them.

**Known bug, unfixed and independent of hardware**: Frigate's Review page returns **HTTP 503 on
1-hour VOD playback** for some hours. `front_door` intermittently writes 2-second segments instead of
10-second (2026-08-04 hour 12: 1592 segments vs a normal ~360), overflowing nginx-vod's durations
array. 10-minute windows work. Episodic — hours 12 and 15 that day, other hours fine. Moving to the
Orin will NOT fix it.

Historical (reference): the 1st NAS disk (IronWolf Pro 12 TB) was DOA 2026-06-29 and RMA'd; the build
proceeded on a 14 TB Toshiba N300 (mirror to be added later). masn was greenfield — no irreplaceable data
except the 382 GB media library, which was copied to the NAS before the wipe. Storage is 1× 14 TB now
(Google stays the off-site copy until the mirror is added).

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
- **Network CURRENT REALITY (2026-07)**: core is in the **2nd-floor OFFICE** (internet enters there) --
  UCG-Fiber + U7 Pro Wall + masn + NAS all in the office now, works fine, no PoE switch yet. Basement
  rack is FUTURE/optional. Floor-2 AP wired off the office gateway; coverage gap = floor 1 + basement.
  **LEADING backhaul (investigating): repurpose the legacy Cat5** -- if the office has a Cat5 drop to the
  structured panel, put a PoE switch at the panel and patch the other drops = fully wired floor-1/basement
  APs + cameras, no MoCA/mesh (office<->panel = 1G over Cat5e). Verify (4-pair UTP not alarm wire, all 4
  pairs, solid copper, test 1G+PoE+). Fallbacks: wireless MESH (floor 1 ok, basement weak), then MoCA.
  The design below is the TARGET:
- **Network (TARGET)**: ALL-**UniFi** — **UCG-Fiber** gateway (planned basement rack) (router + firewall/IDS
  + controller; NO Wi-Fi; 10G SFP+ WAN, 5G IDS = full 3G) + USW-Pro-Max-16-PoE (basement, 10G DAC to
  gateway) + **3× U7 Pro** APs, ONE PER LEVEL (basement ceiling + floors 1/2 WALL — no ceiling access
  on the finished floors). Floor-2 AP has no Cat6 path → backhauled over **MoCA/coax** (+ its own PoE
  injector). RELOCATE the cable modem down to the basement demarc so modem+gateway+switch+NAS+masn
  share ONE rack UPS. UDR7 was considered (modem is currently on floor 2) but REJECTED — radio wasted
  in the rack + 2.3G IDS cap. Ordered so far: 1× UCG-Fiber + 1× U7 Pro Wall; 2 more APs later. ASUS
  BT10 **sold** (its weak VLAN software was the reason to switch). VLANs:
  Trusted / Cameras / IoT (Cameras+IoT firewalled off the NAS).
- **Radio (ONE, Zigbee-only)**: **SLZB-06** = the sole Zigbee coordinator, network-attached (Ethernet,
  Z2M over TCP), mounted CENTRAL on floor 1 — chosen OVER the ZBT-2 precisely for that placement (a
  USB ZBT-2 would sit in the basement on masn = poor mesh spot). **ZBT-2 RETURNED** (2026-07-08); add
  one later only as a dedicated Thread BR if a Thread-only Matter device ever appears.
- **Zigbee software**: **Zigbee2MQTT** (not ZHA) — bridges to Mosquitto; resilient + best Aqara/Tuya support.
- **Protocol = ZIGBEE-PRIMARY (revised 2026-07-08)**: CORRECTION — the 9 owned TP-Link switches are
  Matter-over-**Wi-Fi** (KS205), NOT Thread → returned (avoid 2.4 GHz Wi-Fi congestion vs the Wi-Fi
  cameras). **Zigbee carries everything**: 12× **Sinopé DM2500ZB** dimmers (house lighting +
  the Zigbee router BACKBONE; dimming needed on all 12 → rules out Eve/Thread which is on/off-only;
  Sinopé chosen over Inovelli for Canadian availability; native in Z2M, no Sinopé hub needed) + all
  battery sensors + garage. THERMOSTAT = **Aqara W200** (a HUB: thermostat + Zigbee hub + Matter
  controller + Thread BR), integrated via **MATTER** not Z2M; standalone (don't pair other Zigbee to
  it); its Thread BR = no ZBT-2 needed. **COMMISSIONED + LIVE in HA (2026-07-15)**: `climate.thermostat_
  hub_w200` (+ temp/humidity/**radar occupancy**/sensitivity/hold-time). Needs the **matter-server**
  container (added to masn-stack; ws://localhost:5580/ws, WS bound 127.0.0.1). Router plugs optional.
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
Orphaned `home-assistant_v2.db*` (SQLite) can be deleted. (Frigate/Z2M were subsequently enabled once the
cameras + SLZB-06 arrived — see the top "Status" section for current live state.) NOTE: user set
**passwordless sudo temporarily** for setup — REVERT it when done.

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

- `docker-compose.yml`: **HA + Mosquitto + Postgres + Frigate + Zigbee2MQTT + matter-server all ACTIVE**
  (Frigate/Z2M were enabled once the cameras + SLZB-06 came online). Audio = NuTone IM-3303 + a
  standalone WiiM at the AUX (no audio container on masn). Mosquitto+Postgres bind to `127.0.0.1`
  only (host-mode HA reaches them; LAN can't) — GOTCHA if Frigate ever moves to the Orin: the broker
  would then need LAN exposure, and Frigate's `:5000` API/auth is localhost-only too. NAS SMB (cifs)
  mounts use `nofail`.
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
- `nas-stack/tailscale-acl.hujson`: sample ACL scoping `group:family` to the NAS node only (Jellyfin
  8096 + SMB 445 for family storage; add the UGOS web port if wanted). Free tier covers ACLs + sharing.
- `nas-stack/.env`: holds `TS_AUTHKEY` (gitignored).
- **NAS Docker via CLI (2026-07-08)**: `naseer` was added to the `docker` group -> `docker` works over
  SSH (no sudo; socket is group `docker`, binary `/usr/bin/docker`, compose plugin present). NAS
  containers are now deployed/managed from this session over SSH -- no more UGOS-UI clicking. (May reset
  on a MAJOR UGOS firmware update -> re-run `sudo usermod -aG docker naseer`.) Confirmed on-box: media
  `/volume1/media` (0777), Quick Sync `/dev/dri/renderD128` (render GID 105), `docker` shared folder at
  `/volume1/docker`.
- **Jellyfin DEPLOYED + RUNNING (2026-07-08)**: `docker compose -f /volume1/docker/jellyfin-compose.yml
  up -d` (official image, host net, `/dev/dri`, `/volume1/media:ro`->`/media`, config+cache under
  `/volume1/docker/jellyfin/`). Listening :8096 (HTTP /health 200), library visible (Movies/Shows/
  Series/...), iGPU passed through. USER TODO: http://192.168.50.49:8096 wizard -> add libraries at
  `/media/*` -> Dashboard > Playback > enable Intel QuickSync (renderD128).
- **Tailscale on NAS DEPLOYED (2026-07-08)**: container `tailscale` (host net, NET_ADMIN, /dev/net/tun,
  state `/volume1/docker/tailscale`), authed via **auth key** in `/volume1/docker/tailscale.env` (600).
  Node = **`nas` / 100.119.77.58**. Verified from masn: `tailscale ping` 1ms + Jellyfin HTTP 200 at
  `nas:8096` and the 100.x IP. So **remote Jellyfin works now** -> `http://nas:8096` from any tailnet
  device. Compose ref: `nas-stack/tailscale-compose.yml` (jellyfin = `jellyfin-compose.yml`; both are
  the AS-DEPLOYED files -- `docker-compose.yml` is the older combined illustration). LESSON: a headless
  TS container MUST use TS_AUTHKEY (interactive login races the restart loop -> regenerates the URL).
  TODO: disable key expiry for `nas` in the admin console.
- **NAS reference — shares, users, and the rsync gotcha**: SMB shares are `media`, `personal_folder`
  (per-user home, Samba `%H` -> `/home/<user>`), `TimeMachine`, `masjidmapper`. NAS users:
  `naseer`(1000), `jellyfin`, `zaid`, `masjidmapper`. GOTCHA: **UGOS blocks rsync-over-SSH**
  (`ug_start_server` rejects all paths), so anything pulling from the NAS must use the **SMB mount**,
  tar-over-ssh, or UGOS's own rsync service. (Kept from the now-closed personal-backup-mount task —
  the mount is NOT wanted, but these facts still bite anyone scripting against the NAS.)
- **FAMILY on the NAS (two wants)**: (1) Jellyfin streaming, (2) storage for their personal accounts.
  Plan: create a UGOS USER ACCOUNT per member (+ private/home folder + shared folders) -- UGOS enforces
  per-user perms; install Tailscale on the NAS + NODE-SHARE it to each member (keeps them OFF the subnet
  route / rest of the LAN); ACL allows family -> NAS on 8096 (Jellyfin) + 445 (SMB). Access = Jellyfin
  app + Finder/Explorer SMB to the NAS tailscale IP. No UGREENlink cloud.

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
  to route internet through home). Key expiry DISABLED for masn (2026-07-07).
- NAS is ALREADY reachable remotely via masn's subnet route (192.168.50.49 over the tailnet) -- no TS
  on the NAS needed for YOUR own access. The dedicated NAS TS node (nas-stack) is specifically for
  (a) FAMILY: never share your subnet route with family (exposes the whole LAN) -> node-SHARE just the
  NAS node, ACL-scoped to :8096; and (b) direct-to-NAS Jellyfin streaming (no masn hop, survives masn
  being down). If it were only ever you watching, the NAS node could be skipped.

## Conventions (also see `~/.claude/CLAUDE.md`)

- **Secrets**: never commit. `.env` gitignored; `.env.example` committed with placeholders. Same
  for mosquitto `passwd` and the Z2M network key.
- **No emojis** in code/docs. Immutability. Many small files. **Conventional commits** (`feat:`,
  `fix:`, `chore:`, `docs:`…). Test before commit.
- Confirm before destructive or outward-facing actions.

## Pending / next

- ~~masn OS SSD worn out → NVMe~~ **DONE** — NVMe arrived, masn reimaged 2026-07-06, Phase 0 executed.
  Media copy was verified beforehand (`rsync --size-only`: 0 missing, 382G=382G, 3498 files). Kept only
  as history; the live detail is in the Status section and the Phase 0 runbook.
- ~~Personal-backup cifs mount on masn (`/mnt/nas/personal`)~~ — **CLOSED 2026-08-05, not needed.**
  Was carried as an "at reimage" task; user confirmed the personal content does not need to come back
  to masn. Do not re-add it. (Reference facts it carried are preserved under `## nas-stack`.)
- **Flash the AGX Orin (JetPack 6.2.2)** and give it a static IP + SSH as `orin` — this unblocks the
  whole Frigate migration. First check afterwards: the jp6 image must report `TensorrtExecutionProvider`.
  See `docs/orin-frigate-migration.md` §3.
- Add 2nd 14 TB → mirror (a few months); resume regular NAS backups once real data exists.
- Buy (see plan BoM): SLZB-06 + USB-C brick (ZBT-2 returned; no Thread BR now), 12× Sinopé DM2500ZB (Zigbee dimmers), UniFi (UCG-Fiber + 10G DAC + 16-PoE + 3× U7 Pro; 1 UCG-Fiber + 1 U7 Pro Wall already ordered) + floor-2 MoCA kit,
  cameras (single-lens Reolink/Amcrest + ≤1 Duo for coverage), ~4 Zigbee plug routers,
  Aqara W200 thermostat (BOUGHT; Matter, not Z2M), Aqara T2 + ThirdReality tilt sensor.
