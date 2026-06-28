# AGENTS.md — SmartHome project

Orientation for any agent/session working in this repo. Full rationale lives in
`home-server-smart-home-plan.md` (the source of truth for every decision). This file is the
quick "what/where/how" so a fresh session can continue without re-deriving context.

## What this is

Two intertwined projects:
1. **`masn` revamp** — a Dell OptiPlex 5050 SFF home server (i7-7700, 32 GB) re-platformed to a
   clean Ubuntu Server + Docker stack (Home Assistant, Frigate, MQTT, Postgres, Snapcast).
2. **Smart-home build** for a 3-floor / 3200 sqft house (50 Westacott Crescent, Ajax ON).

Bias throughout: **local-first / no-cloud, security-first, test-before-commit, reproducible infra.**

## Repo layout

- `home-server-smart-home-plan.md` — master plan; all decisions + BoM (~$4,960) + runbook.
- `masn-stack/` — reproducible Docker stack + Phase 0 scripts (see below).
- `AGENTS.md` (this file), `.gitignore`.

## Status (as of 2026-06-25)

- NAS arrives **2026-06-26**. Phase 0 (bring masn online) runs then.
- **Greenfield**: user confirmed NO irreplaceable data on masn → backup-before-wipe gate WAIVED,
  EXCEPT copy the media library to the NAS first (see runbook).
- Storage: **1× 12 TB now, mirror added in a few months** (Google stays the off-site copy meanwhile).

## Key architecture decisions (quick ref — full rationale in the plan)

- **Host**: reuse the 5050 (`masn`), 32 GB; clean-install Ubuntu Server; switch BIOS SATA
  **RAID On → AHCI** (currently RAID On). OS disk = WD Blue 1 TB SATA (`sda`).
- **Storage / NAS**: UGREEN **DXP4800 Pro**, run **ZFS**; 1× **12 TB Seagate IronWolf Pro** now →
  add 2nd later for a mirror (`zpool attach`, in place). Frigate cache stays LOCAL on masn's SSD;
  bulk (recordings/media/backups/family photos) on the NAS.
- **Network**: ALL-**UniFi** — UCG-Max gateway + USW-Pro-Max-16-PoE + 3× U7 Pro APs (wired PoE,
  one/floor). ASUS BT10 **sold** (its weak VLAN software was the reason to switch). VLANs:
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

## Phase 0 runbook (tomorrow)

1. **NAS wizard (user, web UI)**: ZFS single-disk pool; shares `media` / `frigate` / `backups` /
   `family-shared` / per-member private / encrypted `sensitive-docs` (§6.8). NFS-export
   media/frigate/backups to masn's IP; SMB for family. No guest access. Note NAS IP + export paths.
2. **Copy media (agent, SSH to CURRENT masn)**: `masn-stack/copy-media.sh` → media to NAS,
   ~1 h over 1GbE, verify (count + checksum sample) BEFORE the wipe.
3. **Clean install (user, console)**: BIOS SATA RAID On → **AHCI**; install Ubuntu Server onto
   `sda` (UEFI; Secure Boot off if the P620 will be added). Verify `lspci|grep -i sata` = [AHCI mode].
4. **Stand up stack (agent, SSH to fresh masn)**: fill `masn-stack/.env`, run
   `masn-stack/setup-masn.sh` (Docker, `/opt/stack`, mosquitto user, NAS fstab, `compose up` core).
   HA onboarding at `http://<masn-ip>:8123`; paste `homeassistant/configuration-snippet.yaml`.

## masn-stack usage

- `docker-compose.yml`: **HA + Mosquitto + Postgres active**; Frigate / Zigbee2MQTT / Snapcast are
  COMMENTED — enable each as its hardware arrives (cameras / SLZB-06 / speakers). Mosquitto+Postgres
  bind to `127.0.0.1` only (host-mode HA reaches them; LAN can't). NFS mounts use `nofail`.
- `.env.example` → copy to `.env`, fill, `chmod 600` (gitignored). Never commit real secrets.
- `copy-media.sh`, `setup-masn.sh`: review before running; need sudo. Idempotent-ish.

## Conventions (also see `~/.claude/CLAUDE.md`)

- **Secrets**: never commit. `.env` gitignored; `.env.example` committed with placeholders. Same
  for mosquitto `passwd` and the Z2M network key.
- **No emojis** in code/docs. Immutability. Many small files. **Conventional commits** (`feat:`,
  `fix:`, `chore:`, `docs:`…). Test before commit.
- Confirm before destructive or outward-facing actions.

## Pending / next

- **2026-06-26**: execute Phase 0.
- Add 2nd 12 TB → mirror (a few months); resume regular NAS backups once real data exists.
- Buy (see plan BoM): SLZB-06 + USB-C brick, ZBT-2, UniFi (UCG-Max + 16-PoE + 3× U7 Pro),
  cameras (single-lens Reolink/Amcrest + ≤1 Duo for coverage), ~4 Zigbee plug routers,
  Sinopé Zigbee thermostat, Aqara T2 + ThirdReality tilt sensor.
