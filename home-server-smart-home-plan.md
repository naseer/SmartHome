# Home Server + Smart Home Build Plan

Status: Planning
Last updated: 2026-06-06
Primary host: `masn` (Dell OptiPlex 5050, i7-7700, Ubuntu 24.04)

---

## 1. Goals

- Reliable, local-first home server hosting Home Assistant and Jellyfin.
- New-home smart home build: Matter-over-Thread devices, PoE cameras, multi-room audio.
- Keep inference (local LLM) on the Jetson AGX Orin, separate from Home Assistant.
- No cloud dependencies for cameras or core automation. Security-first segmentation.

---

## 2. Current State of `masn` (verified 2026-06-06)

| Item | Finding |
|------|---------|
| OS | Ubuntu 24.04 (Noble), currently a desktop install (GNOME + snaps) |
| CPU | Intel Core i7-7700, 8 threads, 3.6 GHz |
| RAM | 7.6 GiB total (the current bottleneck) |
| Boot disk | `/dev/sda` WD Blue 1TB SATA SSD (`WDS100T2B0A`) |
| iGPU | Intel HD Graphics 630, `/dev/dri/renderD128` present (Quick Sync available) |
| Home Assistant | Already running in Docker (`ghcr.io/home-assistant/home-assistant:stable`) |
| Jellyfin | Native `.deb` install (server 10.11.6 + `jellyfin-ffmpeg7`) |
| Chassis | SFF (Small Form Factor) -- confirmed |
| Drives present | Only `sda` (WD Blue 1TB SSD) + `sr0` (DVD). M.2 NVMe slot EMPTY/free |
| SATA controller | Intel RST in RAID mode (not AHCI) -- see Phase 0 caveat |

### Disk health verdict: HEALTHY, keep it

SMART overall-health: PASSED. All physical wear/error attributes clean:

- Reallocated_Sector_Ct (5): 0
- Grown_Bad_Blocks (170): 0 (the 772 in #169 are factory-marked, normal)
- Reported_Uncorrect (187): 0; Program/Erase_Fail (171/172): 0; End-to-End_Error (184): 0
- UDMA_CRC_Error_Count (199): 0 (SATA link clean)
- Available_Reservd_Space (232, Pre-fail): 100 (threshold 4)
- Host writes (241): ~17.9 TB of 400 TBW rating (~4.5% used)
- Average P/E cycles (173): 6 (max 20); TLC rated ~1000-3000 -> essentially new
- Power-on hours (9): 36,186 (~4.1 years)

Note: `Media_Wearout_Indicator` (230) shows normalized value 001, which looks alarming
but is a known WD Blue reporting quirk. It is contradicted by every physical wear metric
above and is reported as Old_age (not a failure condition). Disk is fine.

Optional confirmation step (active surface scan, non-destructive, ~10 min):

```bash
sudo smartctl -t long /dev/sda
sudo smartctl -l selftest /dev/sda   # check result afterward
```

---

## 3. Prerequisites (gate the `masn` revamp)

The headless conversion and container stack rebuild are DEFERRED until these two
hardware upgrades are done.

### 3.0 Host Hardware Decision -- RESOLVED: reuse the 5050

Decision: reuse the OptiPlex 5050 (i7-7700, 32 GB). The mini-PC option is rejected. Workload is
lighter than it looks: detection runs on the HD 630 iGPU (OpenVINO), heavy AI on the Orin,
recording is a stream copy (near-zero CPU), and with Jellyfin moved to the NAS, masn's only real
work is Frigate decode + orchestration -- it sits ~94% idle. The 5050 is NOT the bottleneck.

Why the mini PC was rejected (revisited after Jellyfin moved to the NAS):
- Its headline advantages -- AV1 / more parallel transcodes -- are now MOOT: transcode lives on
  the NAS's N100 (which has AV1). masn no longer transcodes.
- Remaining upside is only ~$30/yr idle power + DDR5/longer support -- a ~16-yr payback on a
  ~$450 box that isn't constrained. Poor value.
- RAM is bought (32 GB, kept) and the host is intentionally REPLACEABLE: NAS backups + a
  reproducible compose stack mean any host failure is a ~1-hour restore onto a then-current box.
  So we don't need this CPU to last forever -- we need fast recovery, which the design provides.

Longevity: the i7-7700 die almost never wears out (idle, cool ~36C). What ages is consumables
(PSU caps, fans, CMOS battery, thermal paste, SSD) -- cheap one-off swaps, see Runbook (17).
Replace the host on ITS timeline (when it dies/feels slow) with a then-cheaper mini PC, not now.

| Option | Verdict |
|--------|---------|
| Reuse 5050 + 32 GB | CHOSEN -- adequate with margin, cheapest, host is replaceable via backups |
| Modern x86 mini-PC | Rejected -- transcode moved to NAS, so its advantages evaporated; ~$450 for ~$30/yr |
| M4 Mac mini | No -- macOS blocks USB radio passthrough to containers; poor headless 24/7 server |



### 3.1 RAM upgrade (highest priority) -- DONE

Status: COMPLETE. Upgraded to 32 GB (SFF max); `free -h` reports 31Gi usable (iGPU reserves
the rest), clean boot, dmesg clear of MCE/memory errors, idle thermals ~36C. This gate is
cleared.

8 GB could not comfortably run HA + Frigate + Mosquitto + Snapcast + Postgres + Jellyfin.
This single upgrade did more for reliability than any other change.

Original config (verified via dmidecode, pre-upgrade):

- 2 x 4 GB DDR4-2400 (DIMM1 + DIMM2) = 8 GB.
- dmidecode reports 4 slots (DIMM3/4 empty), but SFF physically has 2 -- the extra two
  are likely phantom SMBIOS records (or the box is actually an MT). Confirm by opening the
  case; not required to buy correctly.

What was done: installed a matched 32 GB (2 x 16 GB) DDR4 UDIMM kit -- the SFF maximum,
chosen over 16 GB for headroom across all containers plus Frigate decode buffers.

### 3.2 Disk (reuse existing SSD in-box + NAS for bulk)

Decision: masn keeps its existing 1TB SATA SSD for OS + Frigate active cache (NVMe not
needed, see below); all bulk data (continuous
recordings, Jellyfin media, family Photos/Drive, masn backups) lives on a 4-bay NAS (start 2x12 TB mirror). This is driven by
the move to CONTINUOUS recording -- which a single SFF drive can't protect (one bay, no
mirror), and which makes the always-on footage valuable enough to want redundancy. The NAS
also does double duty (media, backups, local-first Drive/Photos) -- see 6.7.

Storage tiers:

| Tier | Where | Holds |
|------|-------|-------|
| Fast / OS | Existing 1TB SATA SSD (NVMe optional) | OS, Docker, HA config, **Frigate active cache (must stay local)** |
| Bulk (RAID1) | UGREEN NAS over the network (NFS/SMB) | Continuous recordings, Jellyfin server + library, masn backups, local-first sync/photos |
| Off-site (optional) | NAS sync (Nextcloud/Immich) or encrypted bucket | Kept event clips -- local-first alternative to Google Drive |

Do you need the NVMe? No. The existing healthy 1TB SATA SSD is fine for OS + Docker + HA +
Frigate cache -- these are light writes; the heavy continuous recording stream goes to the
NAS, not the local disk. SATA vs NVMe is imperceptible for this workload. Buy an NVMe ONLY as
migration insurance: clean-install on it while leaving the SSD untouched as instant rollback.

Frigate-over-network rule: keep Frigate's `cache` dir on the local SSD; point only finished
`recordings` at the NAS share. The active cache must never write over the network (stalls);
finished-segment writes to the NAS are low and steady (trivial over gigabit). No local 3.5"
HDD needed in masn -- bulk goes to the NAS.

Phase 0 disk caveats:

- Switch BIOS SATA Operation from "RAID On" to AHCI BEFORE the clean reinstall.
  Do NOT toggle this under the live system -- the current initramfs expects RAID mode and
  would fail to boot. Switch first, then clean-install.
- Reusing the existing SSD: back up HA + Jellyfin configs first, then AHCI switch + clean
  reinstall onto it. If you add an optional NVMe instead, the SSD stays as a zero-risk rollback.
- No internal HDD is added (bulk = NAS), so SFF bay/power constraints no longer apply.

Until 3.1 and 3.2 are complete, leave `masn` as-is (HA + Jellyfin keep running).

### 3.3 GPU options (owned Quadro P620 -- optional relief valve)

A Quadro P620 (Pascal GP107, low-profile, bus-powered ~40W, no PSU connector) is on hand.
With Jellyfin moved to the NAS, masn's iGPU now only does Frigate decode + OpenVINO detection
-- the transcode-vs-detection contention that justified the P620 is gone, so it is almost
certainly NOT needed. Keep it on the shelf as a contingency only.

Capabilities (for reference): H.264 + HEVC 8/10-bit encode/decode (NVENC/NVDEC); NO AV1
(Pascal too old). TensorRT-capable (compute 6.1) so it could run Frigate detection on its 512
CUDA cores (~15-30ms/inference; fine for a handful of cameras). Too weak for vision-LLM work.

Only realistic remaining trigger: detection on the HD 630 alone can't keep up with the final
camera count. Then install the P620 and move Frigate detection to it (TensorRT), leaving the
iGPU for decode -- preferred over buying a Hailo-8L. Cost: NVIDIA proprietary driver +
nvidia-container-toolkit passthrough (more moving parts than Quick Sync's /dev/dri), +~40W
(24/7 ~= $40-60/yr in Ontario). Fits the SFF's one low-profile
x16 slot; verify thermals in the small chassis. This also makes the Hailo-8L unnecessary.

---

## 4. Architecture Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| OS strategy | Clean-install Ubuntu Server 24.04 (headless) + AHCI, recommended; convert-in-place is the lighter alternative | Once backups land on the NAS, a clean install gives a pristine, reproducible base (the container stack is rebuilt either way). In-place keeps the working config but carries accumulated cruft. See Runbook (17) |
| CachyOS (or other perf distro) for masn? | No -- considered, rejected | Its wins (BORE scheduler, x86-64-v3 packages, tuned kernel) target interactive/compute perf; masn is ~94% idle and bottlenecked on iGPU fixed-function + I/O, not CPU. Arch rolling-release breakage + hands-on upkeep is the opposite of what a 24/7 critical box needs, and Ubuntu is the HA/Frigate community's paved path. CachyOS instead fits the opportunistic RTX 5070 box (perf matters, not a dependency, wants bleeding-edge Blackwell drivers) |
| Virtualization (Proxmox)? | No -- bare-metal Ubuntu + Docker | Single iGPU + USB radios are shared cleanly on bare metal; hypervisor adds RAM overhead and iGPU/USB-passthrough pain. Proxmox would only fit HAOS-in-a-VM, which we've deliberately avoided |
| Server host: reuse 5050 vs buy new? | RESOLVED -- reuse the 5050 (32 GB) | Transcode moved to NAS so the mini-PC's edge evaporated; ~94% idle; host is replaceable via NAS backups. See 3.0 |
| M4 Mac mini as host? | No | macOS blocks USB passthrough (ZBT-2 Thread/Zigbee radio) to containers; containerized Jellyfin can't use VideoToolbox; macOS poor as headless 24/7 server; Asahi Linux has no M4 support. Great for LLM/AI or desktop, wrong fit for this device-gateway role |
| Remote GUI | `multi-user.target` default + NoMachine (on-demand) | Headless RAM/security win, full GUI when connected |
| Home Assistant | Docker, `restart: unless-stopped` | Already running; container isolation suits HA |
| Jellyfin | Move to the UGREEN NAS (UGOS/Docker or TrueNAS app) | Data-local with the media library; N100 Quick Sync (incl. AV1 decode); frees masn's iGPU for Frigate and removes contention |
| Distro change to Debian? | No | Debian ships older ffmpeg/Mesa -> worse Quick Sync |
| Smart home protocol | HYBRID: Matter-over-Thread for mains devices, Zigbee for battery sensors | Zigbee has better battery life + bigger mature sensor catalog; Thread for mains + multi-admin |
| Z-Wave | Not now (deliberate) | Sub-GHz (908 MHz) avoids 2.4 GHz congestion -- its one real edge -- but channel planning already solves that. Adding it = 3rd radio + ecosystem, pricier/fewer devices, not a Matter transport. Two protocols (Thread+Zigbee) cover all device classes. Revisit only if: untamable 2.4 GHz congestion, a Z-Wave-only device, or long-range/outbuilding needs |
| Radios | TWO dedicated radios: SLZB-06 (Zigbee, network/central) + ZBT-2 (Thread BR, USB on masn) | Avoids single-radio contention; each network on its own 802.15.4 channel; Zigbee gets central placement, Thread rides the 9 mains switches |
| Thread Border Router | HA Connect ZBT-2 on `masn` (Thread only) | No Google/Apple hub owned; HA-first. Second dongle handles Zigbee |
| Cameras | PoE + Frigate (local NVR) | Bandwidth needs wired/Wi-Fi, not Thread; no cloud/subscription |
| Camera AI | Frigate + OpenVINO on HD 630 iGPU (baseline) | Coral EOL; iGPU detection costs $0 and keeps it off CPU; Orin stays on LLM duty |
| GPU relief valve (owned Quadro P620) | Optional; install only if iGPU contention appears | Splits decode/detect/transcode across two chips. Lean: P620 does detection (TensorRT); iGPU keeps decode + Quick Sync transcode. Free; +~40W. See 3.3 |
| Remote access + push | Nabu Casa (HA Cloud), $6.50/mo per instance -- SUBSCRIPTION ACTIVE (2026-06-25); link in HA after first boot | Ring-like mobile UX; secure, no port-forwarding; covers all users |
| Network core | UniFi: UCG-Max gateway (router + controller + firewall/IDS) + 3x U7 Pro APs (wired PoE backhaul). SELL the ASUS BT10 to offset | BT10's weak VLAN/firewall software undermines the camera/IoT segmentation this build depends on. UniFi gives first-class, verifiable VLANs in one dashboard; wired ceiling APs beat mesh backhaul in a wired house |
| Switching/VLANs | UniFi USW-Pro-Max-16-PoE; controller runs ON the UCG-Max (no self-hosted container) | 16 PoE ports size for 3 APs + 4 cams + doorbell; 2.5G + 10G SFP+ for the NAS; one ecosystem/dashboard with the gateway + APs |
| Audio | Keep NuTone IM-3303 as-is; feed a WiiM streamer into its mono AUX | No wiring/speaker changes (lo-fi accepted); whole-house mono; casting + HA via WiiM. Snapcast dropped |
| Dashboard | Pi 4 + old monitor, Chromium kiosk | Free; reuse existing hardware |
| Asterisk | Dropped | Legacy; PoE doorbell + HA Assist cover door/intercom comms |

---

## 5. Network Design

```
Internet
   |
[ UniFi UCG-Max ]  (router + firewall/IDS + UniFi controller)
   |
[ UniFi USW-Pro-Max-16-PoE ]   (VLANs + PoE; 2.5G + 10G SFP+)
   |     |        |        |         |            |
 masn  NAS   Pi4 kiosk  4x PoE cam  doorbell   3x U7 Pro AP
                                               (wired PoE, one per floor)
```

All UniFi -> one dashboard for routing, switching, Wi-Fi, and VLANs. Wi-Fi served by 3 ceiling
U7 Pro APs on wired PoE backhaul (3200 sqft / 3 floors), NOT mesh. ASUS BT10 retired (sold).

VLAN plan (UniFi "Networks"; tagged per-port on the switch + per-SSID on the APs; inter-VLAN
firewall rules on the UCG-Max):

| VLAN | Members | Internet | Can reach NAS? |
|------|---------|----------|----------------|
| Trusted | Workstations, phones, masn | Yes | Yes (then NAS user/ACL applies, see 6.8) |
| Cameras | All PoE cameras + doorbell | Blocked (only HA/Frigate reaches them) | No (firewalled) |
| IoT | Matter/Wi-Fi devices, smart switches | Restricted | No (firewalled) |

Why UniFi over the ASUS: the BT10's VLAN/firewall software is too weak to trust for the
camera/IoT isolation this build's security model relies on. UniFi enforces VLANs + inter-VLAN
firewall rules as first-class, auditable config -- and that segmentation is Layer 1 of the NAS
access-control design (see 6.8).

---

## 6. Bill of Materials

All prices are approximate USD estimates for 2026 and will vary.

### 6.1 `masn` upgrades (Phase 0 prerequisite)

| Item | Qty | Est. each | Est. total | Notes |
|------|-----|-----------|------------|-------|
| DDR4 32 GB UDIMM kit (2x16 GB) | 1 | -- | DONE | Installed; SFF max. Gate cleared |
| Detection accelerator | 0-1 | $70 | $0 | START at $0: OpenVINO on HD 630 iGPU. Coral EOL -- skip. If contention: first use the owned P620 (free, see 3.3); Hailo-8L M.2 (~$70) only if neither suffices |
| M.2 2280 NVMe SSD 1TB (OPTIONAL) | 0-1 | $70 | $0 | Skip -- reuse existing 1TB SATA SSD. Buy only as migration-rollback insurance |
| | | | **~$0** | RAM done; detection on iGPU/P620; existing SSD reused. Up to ~$140 only if Hailo + rollback NVMe ever added |

(Existing healthy 1TB SATA SSD is the OS/app/cache tier -- NVMe not needed. Detection runs on
the HD 630 iGPU via OpenVINO -- no Coral/accelerator to buy up front. Bulk storage --
continuous recordings, media, backups -- lives on the NAS, see 6.7. No internal HDD in masn.)

### 6.2 Network

| Item | Qty | Est. each | Est. total | Notes |
|------|-----|-----------|------------|-------|
| UniFi Cloud Gateway Max (UCG-Max) | 1 | $199 | $199 | Router + firewall/IDS + runs the UniFi controller. Replaces ASUS routing. No built-in Wi-Fi (rack location -> APs do Wi-Fi) |
| UniFi USW-Pro-Max-16-PoE | 1 | $379 | $379 | 12x1G PoE+ + 4x2.5G PoE++ + 2x10G SFP+, 180W. Powers APs + cameras; 2.5G/10G for NAS. 1U rackmount |
| UniFi U7 Pro AP (Wi-Fi 7, PoE) | 3 | $189 | $567 | One per floor (3200 sqft/3 floors), ceiling-mount, wired PoE backhaul |
| Cat6 cable (1000 ft box) | 1 | $120 | $120 | Home runs incl. AP drops to each floor |
| Keystones / patch panel / RJ45 / boots | 1 lot | $80 | $80 | AV-closet termination |
| Cable tester / crimper / punch-down | 1 lot | $40 | $40 | If not already owned |
| 10GBASE-T SFP+ module (OPTIONAL) | 0-1 | $60 | $0 | Only if NAS at 10G via SFP+; else NAS on a 2.5G port (plenty). Runs hot |
| UniFi controller | - | on UCG-Max | $0 | No self-hosted container (was Docker on masn) |
| | | | **~$1,385** | Less ASUS BT10 resale (~$400 credit) -> net ~$985 |

### 6.3 Cameras

| Item | Qty | Est. each | Est. total | Notes |
|------|-----|-----------|------------|-------|
| PoE exterior camera (RTSP/ONVIF) | 4 | $90 | $360 | PoE (NOT battery/Wi-Fi); must have main+sub dual-stream + H.265. Amcrest/Dahua-OEM = most reliable RTSP; Reolink OK via go2rtc restream (see notes). Avoid cloud-locked |
| PoE video doorbell | 1 | $100 | $100 | RTSP, Frigate-friendly, two-way talk |
| | | | **~$460** | |

Camera notes (Frigate):
- Reolink works but its RTSP is finicky and some models cap simultaneous connections -> always
  pull through go2rtc (restreams one connection to detect/record/live). Amcrest/Dahua-OEM are
  the more bulletproof RTSP choice if you want zero fuss.
- Require dual-stream (detect on substream, record on mainstream -- the storage design depends
  on it) and H.265 (to hit ~4 Mbps/cam sizing). PoE only; battery/Wi-Fi cams are unfit for
  continuous recording.
- Reolink Duo 2V (dual-lens, ~180 stitched): good COVERAGE cam (driveway/yard), but weaker for
  detection (objects small/distorted on the ultra-wide frame; needs split config). Use single-
  lens (e.g. RLC-810A/820A/520A) as primary detection cams; at most one Duo for wide coverage.

### 6.4 Smart home (Matter/Thread)

| Item | Qty | Est. each | Est. total | Notes |
|------|-----|-----------|------------|-------|
| HA Connect ZBT-2 dongle (Thread Border Router) | 1 | $35 | $35 | Thread BR; runs Thread-only for capacity |
| Zigbee coordinator: SLZB-06 (network-attached) | 1 | $40 | $40 | Mount CENTRALLY on floor 1 (NOT the basement rack); Z2M over TCP. START: Ethernet jack + USB power (no PoE needed at first); PoE later if the drop is on a PoE port. Separate 802.15.4 channel. USB Sonoff ZBDongle-E / 2nd ZBT-2 (~$30) is the fallback |
| USB-C power adapter for SLZB-06 | 1 | $10 | $10 | Powers the coordinator until/unless PoE is used |
| USB extension cables (1-2 m) | 2 | $8 | $16 | MANDATORY: get both dongles out of the metal rack + away from USB 3.0/each other (2.4 GHz noise) |
| TP-Link Matter-over-Thread switches | 9 | owned | $0 | Already owned; mains-powered -> also Thread routers |
| Sinope low-voltage thermostat (Zigbee SKU -- rebalanced to seed Zigbee) | 1 | $130 | $130 | Furnace+AC (conventional 24V); needs C-wire. CHOSEN Zigbee SKU -> adds a (central) Zigbee router; Z2M-supported. Matter-Thread SKU also exists if you'd rather keep it on Thread |
| Add-a-wire adapter (Fast-Stat / Venstar) | 1 | $25 | $25 | Only if no C-wire and can't pull one -- see thermostat note |
| Matter smart deadbolt (front door, full replacement) | 1 | $200 | $200 | Replacing all locks anyway (used house -- security). Front is a DOUBLE door: smart deadbolt on ACTIVE leaf + coordinating handleset for looks. Yale Assure 2 (Thread module) or Aqara U200/U100. Confirm tubular (drop-in) vs mortise (needs conversion) from door-edge photo |
| Contact sensors (Zigbee) | 6 | $18 | $108 | Doors/windows; security + HVAC-open alerts |
| Motion sensors (Zigbee) | 4 | $22 | $88 | Lighting, presence, camera-arm logic |
| Leak sensors (Zigbee) | 6 | $18 | $108 | Kitchen, laundry, baths, water heater, furnace |
| Sump / high-water alarm (Zigbee) | 1 | $35 | $35 | Ajax flood risk -- catches pump failure |
| Temp/humidity sensors (Zigbee) | 3 | $15 | $45 | Basement, family room, baths (fan automation) |
| Smart plugs Matter-Thread (incl. 1-2 outdoor) | 4 | $26 | $104 | Mains -> Thread; lamps, patio/gazebo, spa |
| Zigbee smart plug (mesh router) | 4 | $15 | $60 | One per floor + one on the garage path. SEEDS the Zigbee router mesh (sensors + garage are Zigbee; mains devices otherwise skew Thread). Mains -> Zigbee router |
| Garage opener relay: Aqara Dual Relay Module T2 (DCM-K01) | 1 | $40 | $40 | Hub-free via Z2M (`LLKZMK12LM`); dry-contact mode wired across the wall-button terminals. Mains-powered (L+N) -> also a Zigbee router. Dual-channel: covers 2 doors. Ignore the "Aqara hub required" label -- Z2M-supported incl. OTA |
| Garage state: ThirdReality Garage Tilt Sensor (3RDTS01056Z) | 1 | $25 | $25 | Hub-free via Z2M; tilt -> open/closed `contact`. Mount on top door panel; disable buzzer; set sensitivity dip switch. 1 per door |
| Scene buttons (optional) | 2 | $20 | $40 | Matter buttons for scenes |
| | | | **~$1,183** | ~32 devices (incl. 4 Zigbee router plugs for mesh health); trim optional items if desired |

### Garage door note (hub-free Zigbee)

Two devices, both on the ZBT-2 + Z2M (no Aqara/ThirdReality hub, no cloud):
- Aqara Dual Relay T2 = the "button". WIRING (per Aqara manual):
  1. Confirm the opener's two wall-button terminals: short them with a paperclip -> door moves.
  2. Power the T2: LIN <- live (120V), N <- neutral. The T2 is mains-powered (no battery), but
     needs NO separate PSU -- use the opener's existing 120V. MOUNT AT THE OPENER HEAD (mains +
     button terminals are both there; the wall button is low-voltage only -- can't power it there).
     Easiest: a plug pigtail + outlet splitter into the ceiling opener outlet (no hardwiring).
     Or a junction-box tap of the outlet circuit (electrician if unsure).
  3. REMOVE THE RED JUMPER (between LIN and LOUT) -> this is what enables DRY (voltage-free) contact.
  4. Dry-contact output (channel 1) = terminals LOUT and L1. Wire the opener's two button terminals
     across LOUT <-> L1 (opener COM -> LOUT; opener trigger -> L1). No voltage injected.
  Dual-channel -> one T2 can drive two doors. Videos: yt ToJHXnb9BR8 (garage), WADio-jD1Ug (wiring)
  -- ignore their Aqara-app pairing; we pair to Z2M instead (wiring is identical).
- ThirdReality tilt sensor = the "state": mount on the top door panel (vertical=closed,
  horizontal=open); reports `contact`. One per door. Disable the buzzer; set the sensitivity dip.
- Make the relay MOMENTARY: a Zigbee relay latches, but a garage button pulses. Use an HA
  automation (relay ON -> wait ~0.8 s -> relay OFF), or the relay's pulse mode if Z2M exposes it.
- Tie relay + sensor into an HA TEMPLATE COVER -> a real garage entity (open/close/stop + true
  state). Keep auto-CLOSE conservative (UL325 safety): don't close unattended without a camera view.

### Thermostat note (Sinope + C-wire)

HVAC is furnace + AC (conventional 24V single-stage -- the easiest case: R/W/Y/G/C, no
heat-pump aux/reversing-valve wiring). Use Sinope's LOW-VOLTAGE model (not the line-voltage
baseboard model). DECIDED: the ZIGBEE SKU (rebalances a mains router onto the starved Zigbee
mesh; Z2M-supported). The Matter-over-Thread SKU is the alternative if you'd rather keep it on
Thread -- either works; the choice here is purely about which mesh gets the extra router.

C-wire: required by Sinope, and likely absent in this older house.
1. First check for a hidden/unused conductor: pull the thermostat plate and inspect the
   furnace control board for a spare (often blue) wire coiled unused at both ends. If
   present, just land it on C at both ends -- free.
2. If walls are open at the thermostat location, pull fresh 18/5 thermostat cable (gives C
   + a spare). Preferred permanent fix.
3. If no spare and can't pull: add a Fast-Stat / Venstar add-a-wire adapter (~$25) -- keeps
   Sinope (local-first) and synthesizes C from the existing 4 wires.

Brand fallback: ecobee includes a Power Extender Kit (PEK) that creates C from 4 wires,
but is Wi-Fi + cloud-leaning -- only switch to it if you'd rather have a vendor-integrated
fix than a $25 adapter. Avoid Nest (cloud-dependent, weak local Matter).

### 6.5 Audio (keep NuTone IM-3303; feed AUX with a smart streamer)

DECIDED: NO new wiring, NO speaker changes, lo-fi accepted. Keep the existing NuTone IM-3303
radio-intercom as the whole-house distribution brain (its room volume knobs = per-room on/off)
and make its mono AUX input "smart" with one network streamer. This drops the whole
Snapcast/amp/home-run plan -- one box replaces all of it.

| Item | Qty | Est. each | Est. total | Notes |
|------|-----|-----------|------------|-------|
| WiiM Mini network streamer | 1 | $90 | $90 | Line-out (3.5mm) -> NuTone AUX (3.5mm->RCA; AUX is mono). AirPlay 2 / Chromecast / Spotify Connect + HA integration. WiiM Pro (~$150) if you want RCA out + better DAC |
| NuTone AUX-to-RCA/3.5mm adapter | 1 | $25 | $25 | REQUIRED: the IM-3303 has no visible AUX jack -- "AUX/CD" is a SOURCE on the master, but the physical input is a proprietary connector on the master that this adapter breaks out to RCA/3.5mm. e.g. "Steve's NuTone Shop / M&S AUX adapter" (compatible IM-3303) |
| NuTone master + speakers + wiring | - | reuse | $0 | Whole-house mono, single source. Requires the master still works |
| | | | **~$115** | Single mono zone; per-room control via existing knobs |

Notes:
- Single whole-house source (mono, lo-fi) -- accepted. No independent per-room streams.
- Snapcast / multi-zone amp / speaker home-runs DROPPED (not needed for a single AUX-fed zone).
- Connection: confirm the master's source selector has an AUX/CD position; the AUX connector is on
  the master (may need to pull it off the wall -- KILL POWER first). WiiM line-out -> adapter ->
  master AUX; select AUX on the master. Verify the master unit still works.

### 6.6 Dashboard

| Item | Qty | Est. each | Est. total | Notes |
|------|-----|-----------|------------|-------|
| Raspberry Pi 4 | - | owned | $0 | Chromium kiosk |
| Old monitor | - | owned | $0 | Reuse |
| microSD/SSD + mount + cabling | 1 lot | $30 | $30 | |
| | | | **~$30** | |

### 6.8 Voice satellites (Orin-backed Assist)

| Item | Qty | Est. each | Est. total | Notes |
|------|-----|-----------|------------|-------|
| Voice satellite (ESP32-S3 / HA Voice PE) | 2 | $40 | $80 | Wake word + mic/speaker per room; or repurpose old phone/Pi ($0) |
| | | | **~$80** | Start with 1-2 rooms, expand later |

### 6.7 Bulk storage (NAS -- continuous recording + media + backups)

Decision: 4-bay NAS, start with a 2x12 TB mirror, because (a) continuous recording makes the
always-on footage worth protecting and the SFF can't mirror (one bay), and (b) the NAS earns
its cost across multiple roles, not just recording:

- Continuous Frigate recordings (finished segments; Frigate cache stays on masn's SSD).
  Sizing: 4 cameras, 15-day retention. At ~4-6 Mbps/camera H.265 main stream this is ~2.6-3.9 TB
  (rule of thumb: 1 Mbps continuous ~= 10.8 GB/day). ~4 TB typical. Use H.265 + a sane
  per-camera bitrate to keep it in this range. Footage (~4 TB) + family Photos/Drive (1-3 TB)
  drives the 12 TB mirror choice below (8 TB would be too tight once media is added).
- Jellyfin server + media library -- runs ON the NAS (data-local; i3-1315U Iris Xe Quick Sync
  incl. AV1 decode). Moved off masn so the HD 630 only does Frigate decode + detection. See note below.
- masn backup target -- HA config, Docker volumes, Postgres dumps (3-2-1 off-box copy).
- Family Google Photos + Drive backup (whole family, multi-user). Google STAYS PRIMARY, so the
  NAS is a redundant local copy and Google remains the off-site copy -> already 3-2-1 compliant,
  no extra cloud-backup cost. Sizing: 1-3 TB family data today.
  - Apps: Immich (Photos) + Nextcloud (Drive files), Docker on the NAS, per-family-member accounts.
  - Drive files: rclone scheduled one-way sync (Google Drive -> NAS).
  - Photos: phones auto-backup to Immich for NEW photos (live local copy) + one-time historical
    import via Google Takeout -> immich-go (Google Photos API can't reliably pull originals).
  - REMINDER: a mirror is NOT a backup. Here Google is the off-site copy; if Google is ever
    dropped, ADD an off-site backup (encrypted Backblaze B2 ~$6/TB/mo, or a 2nd NAS off-site).
- Time Machine / PC backups; general SMB/NFS shares.

Decision: NO Synology -- avoiding its 2025+ drive lock-in. Pick a no-lock box. Since the NAS
is LAN-only (reached via HA/Tailscale, never port-forwarded), the vendor's cloud-security
surface is largely neutralized, so the choice is driven by no-lock + value + OS quality.

Recommended: UGREEN NASync DXP4800 Pro (4-bay, Intel Core i3-1315U 13th-gen x86, 10GbE +
2.5GbE), starting with 2 x 12 TB NAS-rated drives (WD Red Plus / Seagate IronWolf -- CMR,
24/7-rated) as a mirror = 12 TB usable, 2 bays left free for growth. 12 TB (not 8) because the
NAS now also holds 1-3 TB of family Photos/Drive on top of ~4 TB footage. x86 = escape hatch: run
UGOS now, or wipe to TrueNAS SCALE later. The Pro was chosen over the Plus (Pentium 8505) and
the base (N100) because Prime Day pricing made the delta insignificant -- the i3 (6C/8T, 2
P-cores, up to 96 GB RAM) is free 10-year runway. Same chassis/bays/NVMe/10GbE across Plus/Pro;
only CPU + RAM ceiling differ. If the Pro's premium ever exceeds ~$130, the Plus is the value pick.

Expansion path (4-bay, no forklift): start 2x12 mirror -> when data grows, ADD a 2nd 2x12 pair
-> 24 TB usable (stripe of mirrors), no swap, no wasted drives. Alternatively rebuild to a
4-drive RAIDZ1 (36 TB, 1-drive redundancy) or RAIDZ2 (24 TB, 2-drive). NOTE: a mirror cannot
be converted in place to RAIDZ -- the "add a 2nd mirror pair" path avoids any rebuild.

| Item | Qty | Est. each | Est. total | Notes |
|------|-----|-----------|------------|-------|
| UGREEN NASync DXP4800 Pro (4-bay, i3-1315U) | 1 | $650 | $650 | No drive lock-in; x86 (UGOS or TrueNAS); i3 Iris Xe Quick Sync hosts Jellyfin; 10GbE; 2 bays free. Prime Day price; Plus ~$130 less |
| NAS HDD 12 TB Toshiba N300 (HDWG21C, CMR) | 2 | $240 | $480 | CHOSEN after the IronWolf Pro DOA (2026-06-29). CMR, 7200 RPM, 300 TB/yr (3yr warranty). PHASING: buy 1 NOW (single-disk, no redundancy -- Google stays the off-site copy); add the 2nd in a few months once stable -> mirror via `zpool attach` (in place). BURN-IN each (SMART long + surface scan) before trusting. For the mirror, use a DIFFERENT batch, or mix brands (N300 + WD Red Plus) to decorrelate batch/brand risk. Mirror = 12 TB usable |
| | | | **~$1,130** | UPS moved to the shared rack -- see 6.9 |

Running Jellyfin on the NAS:
- UGOS: Jellyfin via app center or Docker; pass `/dev/dri` for Quick Sync HW transcode.
- TrueNAS SCALE: Jellyfin app with iGPU passthrough.
- The i3-1315U (Iris Xe Quick Sync) handles typical home use easily (multiple concurrent 1080p
  transcodes + lots of direct-play) and comfortably exceeds the N100/Pentium for 4K HDR
  tone-mapping. Transcoding is gated by Quick Sync, not cores, so this is plenty of headroom.

Remote access -- who handles what:
- HA (dashboards, app, push, sharing, cameras/events via the Frigate integration): NABU CASA.
  HA does NOT need Tailscale -- Nabu Casa already proxies the HA application.
- Jellyfin: TAILSCALE on the NAS (the only remote path; decided). Point the Jellyfin app at the
  NAS Tailscale IP / MagicDNS name.
- masn host admin (SSH/Docker/NoMachine) + the STANDALONE Frigate UI (`:8971`, not exposed by
  Nabu Casa since Frigate runs as a plain container, not an HAOS add-on): TAILSCALE on masn --
  OPTIONAL. Add only if you want remote host/Frigate-UI access; otherwise do those on the LAN.

Install Tailscale per-host (NAS required; masn optional), NOT a whole-LAN subnet route. Per-host
= least privilege + direct P2P tunnels + respects the VLAN segmentation; a subnet router would
expose every device on the LAN (incl. camera/IoT VLANs) and become a pivot point. NAS stays
LAN-only -- no port-forward, no reverse proxy, no Cloudflare Tunnel (the last is a TOS violation
for video). Not supporting cast-to-remote-TV / no-VPN clients (out of scope, by choice). Ensure
Jellyfin HW transcoding is on so remote streams adapt to home upload bandwidth.
- If a subnet route is ever truly needed (a non-Tailscale device): scope it with Tailscale
  ACLs, advertise ONLY the Trusted subnet (never camera/IoT VLANs), prefer a narrow /32 host
  route over the full /24.

Sizing notes (continuous recording):

- Per camera per day ~= bitrate(Mbps) x 10.8 GB. DECIDED config = 4 cams, 15-day retention:
  - Main stream ~4 Mbps (4MP H.265): ~173 GB/day -> ~2.6 TB over 15 days.
  - Main stream ~6 Mbps: ~259 GB/day -> ~3.9 TB over 15 days.
  - ~4 TB typical for footage; family Photos/Drive (1-3 TB) + media ride on top -> 12 TB mirror.
- Use DUAL-STREAM: continuous low-res substream + full-res main only on events. Tiered
  retention: `record.retain` (continuous, e.g. 15d) separate from alerts/detections
  (e.g. 30d). Frigate auto-prunes oldest first; the share never fills.
- 12 TB usable (2x12 mirror) is the recommended start (footage + family data + media); add a
  2nd 2x12 pair later for 24 TB. Mirror usable = one drive's capacity.

Alternatives to UGREEN:
- Asustor (Intel models, ADM): most mature appliance OS after Synology; no drive lock-in.
- TrueNAS SCALE (DIY on the UGREEN or a mini-PC + enclosure): ZFS integrity (scrubs,
  snapshots, bit-rot protection), zero vendor; more hands-on upkeep.
- Avoid Synology 2025+ (drive lock) and internet-facing QNAP (ransomware history).

### 6.8 NAS access control + encryption

Goal: not every device/user sees every file. Enforced in TWO independent layers (defense in depth).

Layer 1 -- Network (who can REACH the NAS): VLAN/firewall rules (see 5) block the Cameras and
IoT VLANs from the NAS entirely -- they get no route to the file shares regardless of credentials.
Only the Trusted VLAN can even attempt a connection. (This is the segmentation the BT10's weak
VLAN support undermines -- a reason for the UniFi gateway.)

Layer 2 -- NAS users/permissions (who sees WHICH files): shares are accessed by AUTHENTICATED
USERS, not "devices". A device with no valid account gets access-denied even on the LAN. Rules:
- NO guest/anonymous access on any share (require login everywhere).
- One account per family member; group them (e.g. `family`).
- Per-folder permissions (read-only / read-write / no-access) per user or group.

Folder / permission layout:

| Folder / Share | Access |
|----------------|--------|
| `family-shared` | group `family` (read-write) |
| `naseer-private`, `<member>-private` | that user only; others denied |
| `frigate-recordings` | Frigate service account + admin ONLY (not family, not IoT) |
| `media` (Jellyfin library) | Jellyfin service reads it; family watches via the Jellyfin APP, no raw file access |
| Immich / Nextcloud data | managed by the app's OWN user system -- each member sees only their own + shared |

Encryption (for the few truly-sensitive files, e.g. financial/legal):
- SCOPE PER FOLDER/DATASET, never the whole pool. After a reboot, ONLY the encrypted folder
  locks; the OS, apps, shares, recordings, and all unencrypted data come back up normally. Only
  a service whose data lives inside the locked folder waits until you unlock it.
- WHY narrow scope: the NAS is on a UPS and unattended. A power cut that outlives the battery
  reboots it. Whole-pool encryption would halt EVERYTHING (Frigate, Jellyfin, family shares)
  until someone types a passphrase. Keep always-on data unencrypted so the NAS is self-sufficient
  after a blip; put only private docs in an encrypted folder.
- Key vs passphrase: STORED KEY auto-unlocks on boot (protects against bare-drive theft, NOT
  whole-NAS theft; zero manual steps). PASSPHRASE protects even against whole-NAS theft but needs
  a manual unlock each reboot. Use passphrase for sensitive docs; stored key if you only care
  about pulled-disk theft.
- Both UGOS (encrypted folder) and TrueNAS SCALE (ZFS native per-dataset encryption) support this.

### 6.9 Rack & power (consolidated cabinet)

One spot (Utility room AV/network closet) houses masn, the UGREEN NAS, the UniFi USW-Pro-Max-16-PoE
switch + UCG-Max gateway, the patch panel, and the modem -- all on one UPS. The 3 U7 Pro APs are
NOT in the rack (ceiling-mounted, one per floor, fed by in-wall Cat6 from the switch).
Open-frame/vented, NOT a sealed cabinet (everything here runs 24/7 and makes heat).

| Item | Qty | Est. each | Est. total | Notes |
|------|-----|-----------|------------|-------|
| 18U 4-post open-frame rack (~600mm deep) | 1 | $170 | $170 | StarTech/NavePoint/Kendall Howard class. 18U (not 15U) for shelf clearances; 4-post for shelf weight; vented-door cabinet only if actively cooled. Go 20U if running the NAS upright |
| 4-post vented shelf, ~400mm+ deep | 3 | $25 | $75 | For masn (SFF), NAS, and modem + UCG-Max (side by side). Depth >= 300mm so the SFF (~292mm deep) doesn't overhang. Lay SFF FLAT (~2-3U), vents clear, velcro-strap it down |
| 1U rackmount PDU | 1 | $40 | $40 | Feeds from the UPS |
| 1U patch panel + 1U cable manager | 1 | $50 | $50 | Terminates the Cat6 home runs |
| UPS 1500VA PURE SINE WAVE + USB | 1 | $240 | $240 | CyberPower CP1500PFCLCD (or APC BR1500MS). PURE sine wave required (active-PFC PSUs misbehave on simulated sine). Powers EVERYTHING incl. PoE switch -> cameras + internet stay up; USB to masn + NAS for graceful shutdown. Battery swap ~3-5 yr |
| Rack screws / misc | 1 lot | $15 | $15 | |
| | | | **~$590** | |

U-by-U layout (18U, U1 = bottom):

```
U18  Patch panel (1U)                      <- house Cat6 lands here
U17  Brush / horizontal cable manager (1U)
U16  UniFi USW-Pro-Max-16-PoE (1U)         <- short jumpers to patch panel
U15  airflow gap
U14  Shelf A (vented, deep): masn SFF FLAT
U13   masn / clearance
U12   clearance / airflow
U11  Shelf B (vented, deep): UGREEN NAS    (upright -> +2U, go 20U)
U10   NAS
U9    clearance / airflow
U8   airflow gap
U7   Shelf C (vented): modem + UCG-Max gateway (side by side)
U6    modem/gateway clearance
U5   airflow gap
U4   PDU (1U)                              <- fed from UPS
U3   UPS 1500VA (2U rackmount)
U2    UPS (heavy -> bottom)
U1    spare / floor clearance
```

Shelves needed: 3 x 4-post vented shelves (>=400mm deep) for masn, NAS, modem+UCG-Max.
Everything else (patch panel, brush, switch, PDU, UPS) mounts directly on the rails.
Space-saver: masn (flat, ~290mm) + NAS (~105mm) fit side-by-side on one wide shelf (saves
~3U -> fits 15U) at the cost of tighter airflow between them.

Power/UPS notes:
- Consolidated continuous draw ~250-290W (masn ~60, NAS ~40, switch ~25, PoE load: 4 cams ~35 +
  3 U7 Pro APs ~66, UCG-Max + modem ~35). 1500VA/~900-1000W still rides outages with meaningful
  runtime + graceful shutdown; APs + cameras + internet all stay up on battery.
- PURE (true) sine wave is required, not optional: masn's and the NAS's active-PFC PSUs can
  stutter/shut off on a simulated-sine UPS at the moment of transfer to battery. Pick
  CyberPower CP1500PFCLCD or APC Back-UPS Pro BR1500MS.
- PoE switch IS on the UPS (decision): cameras + internet survive a power cut -- security
  priority. This is why 1500VA, not 900VA.
- UPS at the bottom (battery weight). Battery life halves ~every 8-10C above 25C -> keep the
  rack ventilated; replace UPS battery ~every 3-5 yrs.
- Wi-Fi: NO radio in the rack (metal kills signal). The UCG-Max is Wi-Fi-less by design; Wi-Fi
  comes from the 3 ceiling U7 Pro APs (one per floor), each on its own in-wall Cat6 PoE run.

### BoM grand total

Approx. **$4,665** spread across phases (RAM done; NVMe dropped -- reusing existing SSD; Coral
dropped -- detection on the HD 630 iGPU; UGREEN 4-bay NAS (Pro) with Jellyfin + family
Photos/Drive backup on it; ALL-UniFi network -- UCG-Max + 16-PoE switch + 3x U7 Pro APs, BT10
sold; consolidated rack + 1500VA pure-sine UPS). Largest line items: smart home devices (~$1,183, incl. lock +
thermostat + dual radios + hub-free Zigbee garage), network (~$985 net after BT10 resale, all-UniFi), NAS (~$1,130, DXP4800 Pro
4-bay starting 2x12 TB), rack + power (~$590), cameras (~$460), and audio (~$115 -- NuTone reused
+ WiiM + AUX adapter; Snapcast/amp/speaker-runs dropped). Reuse of Pi 4,
monitors, the existing 1TB SSD, the iGPU for detection, and the Orin avoids ~$720+; selling the
BT10 offsets ~$400 of the UniFi switch-over. Bulk storage + Jellyfin on the UGREEN NAS (mirror, 2
bays free to grow); continuous recording via dual-stream; everything on one UPS (PoE/cameras/APs included).

Recurring cost: Nabu Casa (HA Cloud) **$6.50/mo** -- per instance, covers all cameras and
all household users. Optional (Tailscale is the $0 alternative).

---

## 7. Cable-Pull List (during drywall)

Pull more than you think you need. Cat6 to:

- Each exterior camera location (4) -> PoE switch
- Doorbell location (1) -> PoE switch
- Each ceiling AP location (3, one per floor) -> Cat6 PoE drop for a U7 Pro (wired backhaul)
- CENTRAL main-floor location -> Cat6 drop for the SLZB-06 Zigbee coordinator (PoE if the port
  supports it; else data jack + a USB power brick nearby). Pick the most central spot, high up.
- FLOOR 1 ABOVE THE RACK -> ensure a powered Thread router here (a TP-Link switch on that wall,
  or a Thread smart plug in a nearby outlet) to anchor the basement Thread BR into the mesh. Not
  a cable item -- just don't leave the floor above the rack without a mains Thread device.
- Dashboard location(s) (Pi 4 kiosk) (1+)
- AV/network closet: home runs land here, plus uplink to router
- 1-2 spare drops per room (cheap insurance)
- Thermostat location: if reachable while walls are open, pull fresh 18/5 thermostat cable
  to guarantee a C-wire (+ spare). Otherwise plan on a Fast-Stat/Venstar add-a-wire adapter.
- Unfinished basement (easy access): land all home-runs in/near Utility; 1-2 spare Cat6 to the
  future Rec Room area, capped + labeled, for a later media zone.

Speaker wiring: DROPPED. Audio reuses the existing NuTone IM-3303 + its speakers/wiring as-is,
fed by a WiiM streamer at the AUX (see 6.5). No new speaker home-runs. (If you ever want true
multi-zone hi-fi later, that's a separate project -- pull speaker pairs then.)

---

## 8. `masn` Container Stack (post-revamp)

```
masn (Ubuntu 24.04, headless + NoMachine on-demand)
|
+-- Docker:
    +-- home-assistant    (restart: unless-stopped)
    +-- frigate           (OpenVINO on /dev/dri iGPU; active cache local, continuous recordings -> NAS via NFS/SMB)
    +-- mosquitto         (MQTT broker; shared by Z2M + HA)
    +-- zigbee2mqtt       (connects to the SLZB-06 over TCP; bridges Zigbee -> MQTT -> HA)
    +-- postgres          (HA recorder DB)
    (snapserver DROPPED -- audio is the NuTone IM-3303 fed by a standalone WiiM at the AUX, see 6.5)
|
+-- ZBT-2 (USB on masn) -> Thread Border Router (OTBR/HA)
+-- SLZB-06 (network, central floor 1) -> Zigbee coordinator (Z2M over TCP)

(Network management UI runs on the UniFi UCG-Max, not masn -- no controller container.)

(Jellyfin runs on the UGREEN NAS, not masn -- see 6.7. masn no longer transcodes.)
+-- /dev/dri (iGPU: Frigate decode + OpenVINO detection) passed to containers
```

Dropped from the original add-on list: Asterisk, Z-Wave JS.

---

## 9. House Layout Reference (50 Westacott Crescent, Ajax -- iGUIDE 2026-03-06)

~3,020 sq ft above grade, ~4,405 total (incl. finished basement). 2-storey + basement.

- Main floor (1,404 sq ft int): Family 252 (gas F/P, open to Breakfast 132 + Kitchen 163),
  Living 185, Dining 175, Office 138 (potential 6th bed), 2pc powder, Foyer, 2-car garage 392.
- 2nd floor (1,616 sq ft int): Primary 297 + 5pc ensuite + WIC; second suite Bedroom 203 +
  4pc ensuite + WIC; Bedrooms 175/153/139; 4pc main bath; LAUNDRY 46 (upstairs).
- Basement (1,385 sq ft int, UNFINISHED): open Rec Room area 1,230; Storage; Utility 40
  (furnace, water heater, panel, likely sump); egress windows. (iGUIDE color = included
  area, not "finished".)

Layout-driven decisions:

- Upstairs laundry -> priority leak sensor (2nd-floor water = ceiling damage below);
  auto-shutoff-valve-ready preferred.
- Utility room = sensor cluster (leak x2, sump high-water, temp/humidity) AND the natural
  network/AV closet + thermostat wiring origin. Land Cat6/speaker home-runs here.
- Possible DUAL-ZONE HVAC (size + 2-storey): may need TWO thermostats, each with its own
  C-wire solution. Verify at the furnace before ordering.
- Unfinished basement = easiest cabling in the house (open joists/studs). PRE-WIRE now:
  speaker home-runs + spare Cat6 to the future Rec Room area, capped + labeled, even if
  finishing is years away. Mount network/AV gear in the open in/near Utility.
- Rec Room as a media/Snapcast zone + 2nd Jellyfin location = FUTURE (activate if finished).
  Keep 1-2 egress-window contacts for basic security now.

---

## 10. Smart Home Protocol Notes

- Matter = application standard; Thread = one transport (others: Wi-Fi, Ethernet).
  "Matter over Thread" needs a Thread Border Router (the ZBT-2 -- a single 802.15.4 radio).
- ONE Thread dongle covers ALL your Matter + Thread devices (Matter-over-Thread = Thread;
  Matter-over-Wi-Fi needs no dongle). The SECOND dongle exists ONLY for the Zigbee tier below.
- ZBT-2 "supports both" = it can run Zigbee OR Thread, NOT both at once. HA tested simultaneous
  multiprotocol (MultiPAN) on the prior ZBT-1, found it unreliable, and explicitly will NOT
  implement it on the ZBT-2 -- they recommend a dedicated device per protocol. So: 1 dongle if
  all-Matter; TWO dongles for the hybrid (plan) -- e.g. 2x ZBT-2, or ZBT-2 + a Zigbee coordinator.
- Mains-powered Matter-over-Thread devices act as Thread routers; the 10 smart switches
  will densify mesh coverage automatically -> one Border Router likely sufficient.
- Matter devices are multi-admin: can appear in BOTH Home Assistant and the Google Home
  app simultaneously.
- Cameras do NOT run on Thread (bandwidth). Matter 1.4 added a camera spec but adoption
  is near-zero in 2026 -> cameras stay PoE/Wi-Fi.

Zigbee vs Thread (battery + coexistence):
- Same radio (802.15.4, 2.4 GHz). Battery difference = protocol overhead: Thread is IPv6
  (6LoWPAN) + Matter adds another layer -> more bytes/wake -> more drain. Zigbee is leaner +
  15 yrs of optimization, so battery sensors last longer on Zigbee today (gap shrinking).
- HYBRID strategy (see "Protocol assignment" below for the final split): THREAD = the 9 owned
  mains lighting switches (+ lock if Thread); ZIGBEE = all battery sensors + garage + thermostat
  + dedicated router plugs (longer battery life, cheaper, far bigger mature catalog -- Zigbee is
  the richer 2026 ecosystem, so the device-heavy side lives there).
- Run BOTH via TWO dedicated radios (SLZB-06 for Zigbee + ZBT-2 for Thread BR), not one
  multiprotocol chip -> avoids single-radio time-share contention; lets each use its own channel.
- 2.4 GHz channel planning is the real reliability factor: bias Wi-Fi to 5/6 GHz on the U7 Pro
  APs (and pin 2.4 GHz to ch 1/6/11), then separate Zigbee (e.g. ch 15) and Thread (e.g. ch 25),
  both away from Wi-Fi 2.4 GHz channels. Get this right = solid meshes; ignore it = "device
  dropped" flakiness.

Dual-dongle install on masn (both radios connect to masn via USB):
- USB EXTENSION CABLES are mandatory, not optional. USB 3.0 ports, SSDs, and the PC itself
  spew 2.4 GHz noise that desensitizes 802.15.4 receivers. Put each dongle on a 1-2 m
  extension, routed OUT of the metal rack into open air.
- Space the two dongles ~0.5 m+ apart from each other (two 802.15.4 radios side-by-side
  interfere). Prefer USB 2.0 ports; keep extensions clear of the USB 3.0 side.
- Pass each dongle's STABLE path (`/dev/serial/by-id/...`, never `ttyACM0` which renumbers)
  to the right service: Thread -> OTBR/HA, Zigbee -> the Zigbee2MQTT container (DECIDED, see below).
- Coordinator placement is somewhat forgiving since mains Thread/Zigbee devices extend the
  mesh -- but out-of-the-rack, open-air placement still helps initial coverage.

Coordinator placement (basement rack) + scaling -- IMPORTANT:
- The rack is in the BASEMENT. A single radio there will NOT blanket 3 floors + garage:
  concrete foundation + floor decks are heavy RF attenuators. Range is environment-dependent;
  do NOT plan around the coordinator's direct reach.
- Mesh range comes from ROUTERS, not the coordinator. Every mains-powered Zigbee/Thread device
  (TP-Link switches, plugs, the Aqara T2 relay) repeats the mesh. Seed at least one mains router
  per floor (incl. one near the basement ceiling/stairs) so there's an unbroken chain upward.
- Zigbee: ONE coordinator per network (it holds the keys) -- you CANNOT add a 2nd for coverage;
  extend with routers (or a dedicated SLZB-06 flashed as a router) instead. Multiple coordinators
  = multiple SEPARATE networks (don't mesh; only for segmentation/detached outbuilding).
  DECIDED: use a NETWORK-ATTACHED coordinator (SLZB-06) mounted CENTRALLY on floor 1, with Z2M
  connecting over TCP (serial-over-IP) -- decouples the radio from the basement rack while the
  rack stays put. Keeps the USB ZBT-2/Sonoff as a fallback if the rack ever moves central.
  - Connection/power: Z2M only needs the SLZB-06 on the same LAN. POWER + NET options:
    PoE (one cable, cleanest), OR any Ethernet jack + a USB-C power brick, OR USB-to-host.
    START PLAN: no PoE at first -> use a central Ethernet jack + USB power (fine; PoE later if
    that drop lands on a PoE port). Wi-Fi Zigbee bridge (Sonoff ZBBridge-P) only if no cable
    can reach -- wired is more reliable (a Wi-Fi blip = laggy Zigbee).
- Thread: NO single coordinator -- self-healing mesh, and it SUPPORTS MULTIPLE BORDER ROUTERS on
  one network (redundancy + multiple LAN entry points; BRs must share the same Thread credentials
  + LAN). Range still comes from Thread routers (mains TP-Link devices), not from adding BRs.
  - ZBT-2 BR can STAY in the basement -- but only because the Thread mesh is router-RICH (9 mains
    switches). REQUIREMENT: a Thread router must be within reach of the basement BR. INSURANCE:
    put a Thread device near it -- a basement switch (if finished), or one TP-Link switch / Thread
    plug on FLOOR 1 directly above the rack / near the basement stairs. That single device anchors
    the BR into the mesh. Also raise the ZBT-2 on its USB extension toward the basement ceiling.
  - If Thread still lags, DON'T relocate -- add a 2nd central BR (Thread allows multiple BRs).

Protocol assignment (which mesh carries what) -- DECIDED:
- Two meshes, each carrying what it's best at; each needs its OWN routers (a Thread device does
  NOTHING for Zigbee coverage and vice versa).
- THREAD = mains lighting backbone: the 9 owned TP-Link switches (sunk asset; excellent Thread
  routers) + optionally the lock. Already richly seeded.
- ZIGBEE = breadth: all battery sensors + the garage (no Thread garage gear exists) + the
  thermostat (rebalanced to Zigbee) + dedicated router plugs. Zigbee has the deeper/cheaper 2026
  catalog, so the sensor-heavy side lives here.
- Router seeding (the fix for the basement coordinator): battery sensors do NOT route, and the
  mains devices otherwise skew Thread -- so the Zigbee mesh would be router-poor. Add ~4 mains
  ZIGBEE smart plugs (one per floor + one on the garage path) as dedicated routers; the garage
  Aqara T2 and the Zigbee thermostat add two more. Then one floor-1 SLZB-06 covers the house.
- Don't go Zigbee-ONLY: the owned Thread switches + Matter interop + multi-BR redundancy are
  worth keeping. Hybrid is the right call.

Zigbee software -- DECIDED: Zigbee2MQTT (Z2M), not ZHA:
- ZHA runs IN-PROCESS inside HA (zigpy, direct entities, no broker). Z2M is a STANDALONE,
  hub-agnostic app that bridges the Zigbee radio to MQTT (Mosquitto, already in the stack); HA
  subscribes. Both drive the SAME dongle -- pick one; they can't share the radio.
- Why Z2M here: (1) broader/faster device support via zigbee-herdsman-converters (ships on its
  own cadence, not gated on HA releases) -- best for the Aqara + Tuya TS0601 garage mix; (2)
  resilience -- restarting/upgrading HA does NOT drop the Zigbee mesh (separate process; state
  resyncs over MQTT). Cost: one extra container + the MQTT dep (already have it).
- Coordinator support: Z2M `ember` driver covers the ZBT-2 (EFR32MG24) and Sonoff ZBDongle-E
  (EFR32MG21); `zstack` covers ZBDongle-P (CC2652). Whichever is the Zigbee coordinator works.
- Decide up front: switching ZHA -> Z2M later means re-pairing every device. Start on Z2M.

Aqara on Zigbee (NO Aqara hub needed):
- Aqara Zigbee devices pair DIRECTLY to the ZBT-2 Zigbee coordinator (the coordinator IS the
  hub) -- fully local, no Aqara hub or cloud. HA handles automations (via Z2M -> MQTT).
- Aqara's quirk: end-devices (esp. cheap sensors) often DROP OFF when re-parented through
  third-party Zigbee routers (cheap Tuya/no-name bulbs/plugs are the usual culprits). Mitigate
  by using Aqara or IKEA Tradfri as the mains-powered ROUTERS in the mesh.
- Verify per product before buying: it must be ZIGBEE (some new Aqara are Thread/Matter -> those
  go to the Thread border router instead; a few are Wi-Fi) and NOT hub-locked (most standard
  sensors/switches are not; a few cameras / advanced devices are).
- Caveat: some Aqara Zigbee FW updates require an Aqara hub (Z2M/ZHA OTA support is partial).
  Functionally everything works hub-free; only optional firmware updates may need a borrowed hub.

---

## 11. Cameras: Remote Access, Mobile Notifications & Sharing

Goal: reproduce the Ring phone experience (push with snapshot, tap to live view, two-way
talk, event clips) locally, with household sharing.

Three cooperating pieces:

1. Detection -- Frigate (local AI, OpenVINO on the HD 630 iGPU): person/car/package events, fewer false
   alerts than PIR. Continuous recordings on NAS (RAID1), active cache on masn's local SSD.
2. Notify + view -- HA Companion app (iOS/Android): rich push with the Frigate snapshot,
   animated clip preview, and action buttons; tap opens the go2rtc/WebRTC live view.
3. Remote access -- Nabu Casa (HA Cloud): secure remote access + push relay, no port
   forwarding.

### Notifications

- Use the community "Frigate Notifications" blueprint (SgtBatten): Ring-like push with
  thumbnail, clip preview, tap-to-clip/live, and Dismiss/Silence/Snooze actions. One form
  per camera instead of hand-built automations.
- Doorbell press -> its own notification ("Someone's at the door") + snapshot, plus an
  optional TTS announcement through the NuTone speakers (HA -> WiiM -> AUX).

### Remote access: Nabu Casa (chosen)

- $6.50/mo, per-INSTANCE (not per-user) -- covers unlimited cameras and all household
  members. Also funds HA development.
- Provides secure remote access + the push relay; no port forwarding (never expose HA
  directly to the internet).
- Free alternative if ever desired: Tailscale (mesh VPN) -- seamless once installed,
  slightly more setup.

Note: HA Companion push works via the HA project's free relay even without Nabu Casa; the
subscription is what makes tap-through to remote LIVE VIEW seamless from anywhere.

### Watching recordings away from home

You reach everything through Home Assistant; Nabu Casa just makes HA reachable from outside.
You never connect to the NAS directly over the internet.

- Path: phone (HA Companion app) -> Nabu Casa encrypted tunnel -> HA at home -> Frigate ->
  reads recordings from the NAS on the LAN. Footage never lives in Nabu Casa's cloud (unlike
  Ring/Amazon); the NAS holds it, HA is the only front door.
- Live feeds + recent events: embedded Frigate view in HA. Remote live uses WebRTC and may
  occasionally fall back to slightly higher latency than on home Wi-Fi.
- Full continuous archive: open the Frigate UI through the same tunnel and scrub days of NAS
  footage -- playback over the tunnel has none of the live-WebRTC quirks.
- Putting recordings on the NAS (vs a local disk) changes nothing about remote access -- HA
  is always the access point regardless of where the bytes sit.
- $0 alternative: Tailscale (mesh VPN) puts the phone "on" the home LAN -> full live +
  archive exactly as if home; trade-off is self-managed and less seamless household sharing.

### Household sharing (Ring "Shared Users" equivalent)

Per family member:

1. Settings -> People -> Users -> Add user, Administrator OFF.
2. They install the HA Companion app and log in via the Nabu Casa URL (no extra fee).
3. Create a "Cameras" dashboard, set visible to those users (non-admins can't see config).
4. Add their device to notification targets (each login gets its own
   `notify.mobile_app_<phone>` service).

Caveat: HA permissions are admin / non-admin, not fine-grained per-entity RBAC. Dashboard
visibility + non-admin role is plenty for trusted family, but the API still exposes entity
states to any authenticated user -- not suitable for an untrusted short-term guest. For
that, use a temporary account you delete afterward, or just share a clip.

### Two-way talk

- WebRTC two-way audio on the PoE doorbell, surfaced in the HA dashboard / camera card.

---

## 12. Local AI Roles (Orin always-on + RTX 5070 opportunistic)

Local AI runs across two nodes by AVAILABILITY: the Orin is the always-on inference node;
an RTX 5070 Linux box is an opportunistic accelerator (usable most of the time, but has
downtime when used for other workloads). Everything stays LAN-only, no cloud AI by default.

The governing rule: nothing the home depends on may sit on the 5070. Critical paths run on
always-on hardware; the 5070 only ACCELERATES heavy/optional work and must degrade gracefully
to the Orin (then cloud) whenever it is offline.

Availability tiers:

| Tier | Hardware | Runs | If it's down |
|------|----------|------|--------------|
| Always-on critical | masn iGPU + Orin | Frigate detection trip-wire, voice wake/STT/intent, core automations | (must never be down) |
| Always-on heavy | Orin | Conversational LLM, live VLM event understanding, TTS | n/a |
| Opportunistic burst | RTX 5070 box (sometimes) | Bigger/faster LLM + VLM, batch vision (embeddings, face/LPR, training), AV1 re-encode | Auto-fall back to Orin, then cloud |

Role hierarchy:

| Box | Role |
|-----|------|
| masn | Orchestration + light inference (HA, Frigate real-time detection on HD 630 iGPU) |
| Orin | Always-on heavy AI (voice STT, conversational LLM, live VLM event understanding) |
| RTX 5070 box | Opportunistic: preferred LLM/VLM endpoint when up; batch vision + AV1 jobs |
| UGREEN NAS (RAID1) | Bulk storage (continuous recordings, media, masn backups) + Jellyfin (N100 Quick Sync) |
| HD 630 iGPU (OpenVINO) | Frigate real-time object detection + decode |

### Role 1: Local voice assistant (HA Assist pipeline)

HA's Assist voice pipeline is built from swappable stages connected over the Wyoming
protocol (voice service over LAN). Heavy stages run on the Orin:

| Stage | Where | Software |
|-------|-------|----------|
| Wake word ("Hey Jarvis") | Satellite device | openWakeWord |
| Speech-to-text (STT) | Orin (GPU) | faster-whisper |
| Intent / conversation | Orin (GPU) | Ollama LLM |
| Text-to-speech (TTS) | Orin or satellite | Piper |

### Role 2: Conversation agent (LLM-backed)

HA hands free-form requests to the Orin's Ollama LLM:
- Natural commands ("I'm cold" -> reason to adjust thermostat).
- Questions about home state ("did anyone come to the door while I was out?").
- Fallback understanding when a command matches no built-in intent.

### Role 3 (optional, later): advanced vision -- two-stage, LLM event understanding

Heavier models beyond what the iGPU detector handles:
- License-plate recognition, face recognition, richer scene understanding.
- Generative event descriptions: send a Frigate snapshot to a vision LLM ->
  "a person in a brown uniform is at the front door holding a box" as the notification text.

Two-stage by design (never one or the other):
- Stage 1 (always-on, local): HD 630 iGPU (OpenVINO) does real-time per-frame detection. This
  is the 24/7 trip-wire and must stay local -- it can never go to a cloud LLM (cost/latency/
  internet-dependence make per-frame cloud inference a non-starter).
- Stage 2 (event-triggered): Frigate GenAI (0.16+) sends ONLY the snapshot of a detected
  event to a vision LLM for description / search. Occasional and latency-tolerant.

Stage 2 endpoint -- preference chain with automatic fallback:
`RTX 5070 (when up) -> Orin -> cloud`. All three speak the SAME OpenAI-compatible API, so
this is a routing/health-check choice, not a re-architecture.
- PREFERRED: RTX 5070 box when online -- biggest/fastest local VLM (e.g. qwen2-vl, llama-3.2-
  vision, larger variants). Richer descriptions, faster. Free, private, on-LAN.
- ALWAYS-ON DEFAULT: Orin via Ollama's OpenAI-compatible API (`http://orin:11434/v1`). Takes
  over automatically whenever the 5070 is busy with other workloads / offline.
- LAST-RESORT: cloud OpenAI-compatible endpoint (OpenAI / Gemini) -- base-URL + API-key swap.
  Pennies per event; only the few event snapshots leave the LAN, not the feed. Use only if
  both local nodes are down or insufficient.

Implement the chain with a tiny router (HA automation, or a LiteLLM/local proxy in front of
Frigate GenAI) that health-checks the 5070 endpoint and falls through. Event understanding is
latency-tolerant, so a failed-call retry to the next tier is invisible in practice.

### Role 4 (opportunistic): RTX 5070 burst + batch jobs

When the 5070 box is online it serves the interactive LLM/VLM roles above (preferred tier).
It is also the home for heavy, NON-time-sensitive batch work that simply waits for it:
- Semantic footage search: build CLIP-style embeddings of events so you can search history
  ("package on the porch", "white van"). Frigate Semantic Search; index on the 5070 when up.
- Face recognition / license-plate recognition over events.
- Train/fine-tune a detector on your own cameras; validate heavier models offline.
- Batch re-encode the Jellyfin library to AV1 (5070 has AV1 NVENC) to save NAS space.

Pattern: a simple queue drains these when the machine is online -- nothing here has an uptime
or latency requirement, so downtime just means the queue waits. Keep all of it on-LAN.

Note: RTX 5070 is Blackwell (sm_120) -- needs CUDA 12.8+/recent drivers; supported across
Ollama / vLLM / llama.cpp / TensorRT. 12 GB VRAM fits 7-8B LLMs (12-14B quantized) + VLMs.

### Connectivity

- Orin runs Ollama + faster-whisper (+ optional Piper), each exposed as a network service.
- The RTX 5070 box (when up) runs Ollama/vLLM exposing the same OpenAI-compatible API; it is
  the preferred LLM/VLM endpoint with health-check fallback to the Orin.
- HA on masn points its Assist pipeline at the Orin's IP (Wyoming for STT/TTS, Ollama
  integration for the conversation agent). Voice STT/intent stays on the always-on Orin, NOT
  the 5070 (latency-critical + always-needed). Pure LAN; no internet required.

### Voice satellites (per-room mic/speaker)

Wake word + mic + speaker in rooms where you want voice. Options:
- ESP32-S3 voice box (e.g. ESPHome "voice assistant" / Home Assistant Voice PE) ~$13-60.
- Repurposed old Android phone or Pi running an HA Assist satellite.

---

## 13. Controlling Everything from Android

Single app for the whole system: the Home Assistant Companion app (Android). It is the
remote control, the dashboard, the notification channel, and a voice entry point.

### What the app gives you

- Dashboards: the same Lovelace views as the wall/kiosk display, on your phone -- cameras,
  lights, thermostat, locks, scenes, Jellyfin controls, audio zones.
- Live camera view: tap a camera -> go2rtc/WebRTC live stream (low latency).
- Rich notifications: Frigate person/doorbell push with snapshot + actions (see Section 10).
- Remote access: works away from home via Nabu Casa (already chosen).
- Phone-as-sensor: the app exposes phone GPS (presence/geofencing), battery, connectivity,
  etc. back to HA -> "arriving home" / "everyone left" automations.
- Quick controls: Android home-screen widgets + Quick Settings tiles for one-tap
  scenes/devices without opening the app.

### Voice from the phone (three ways)

1. In-app Assist: tap the Assist (microphone) icon in the Companion app -> talk -> the
   request runs through the same Orin-backed pipeline (STT + LLM) as the room satellites.
   Works remotely via Nabu Casa.
2. Android Assist hand-off: set HA Assist as the device assistant / bind to a button or
   home-screen shortcut so a gesture opens HA voice directly.
3. Google Assistant bridge (optional): because devices are also exposed to the Google Home
   app, "Hey Google, turn off the lights" still works through Google for basic device
   control -- but that path is cloud and Google-dependent. The local Orin pipeline (1 and 2)
   is the private, no-cloud route and the one to prefer for this build.

### Two voice worlds (be deliberate)

- Local/private: Companion-app Assist + room satellites -> Orin (STT + LLM). No cloud.
  Full power: conversational, can answer questions about home state, advanced automations.
- Google Home app: convenient, familiar, but cloud-based and limited to basic device
  control. Fine as a casual fallback; not the primary control plane here.

Recommendation: make the HA Companion app + Orin-backed Assist the primary control plane;
keep Google Home as an optional convenience layer for simple voice.

### Google Home exposure (optional convenience layer)

No additional hardware required. "Google Home" the app (already used) runs Google
Assistant on the phone/Android; a Nest speaker is just one more surface, not a requirement
-- and the Orin voice satellites already fill the in-room voice role locally.

Two distinct paths to get devices into Google Home:

| Path | Covers | Setup | Cloud? |
|------|--------|-------|--------|
| A. Matter multi-admin | Matter/Thread devices (the smart switches, etc.) | Commission in HA, then share the generated pairing code into Google Home (or vice versa). A few taps per device | Device link is local; Google voice is cloud |
| B. HA Google Assistant integration | Non-Matter HA entities (scenes, scripts, automations) | One toggle in Nabu Casa to expose chosen entities | Yes, via Nabu Casa |

Notes:
- Matter devices reach Google directly via multi-admin -- no bridge, no extra integration,
  no extra subscription. Both HA and Google control them locally.
- Path B rides on the existing Nabu Casa sub (without it, Path B needs a fiddly free Google
  Cloud project -- another reason Nabu Casa earns its keep).
- Tradeoff: Google voice is cloud-dependent (fails if internet is down, Google sees the
  commands) and basic (flip devices / run scenes only). It cannot do the conversational,
  stateful queries the local Orin pipeline handles. Keep it as a convenience fallback, not
  the primary control plane.

---

## 14. Implementation Phases

- [x] Phase 0a (prereq): RAM to 32 GB -- DONE (verified healthy).
- [ ] Phase 0b (prereq): stand up the NAS FIRST (it is the backup target). Assemble the 18U
      rack (3 vented shelves, PDU, patch panel, 1500VA UPS at bottom); rack masn, UGREEN NAS,
      UniFi UCG-Max + USW-Pro-Max-16-PoE switch, modem; everything on the UPS. Configure NAS
      2x12 TB mirror (4-bay, 2 bays free); export NFS/SMB shares (backups, recordings, media).
- [ ] Phase 0c (prereq): BACK UP masn to the NAS (HA, Jellyfin, Docker volumes, Postgres dump,
      /etc, media). Verify the backups are readable on the NAS before touching masn.
- [ ] Phase 0d (prereq): masn revamp. CHOSEN PATH: GREENFIELD -- user confirms NO irreplaceable
      data on masn, so the backup-before-wipe gate is WAIVED for this initial build. Clean-install
      directly onto the EXISTING SSD (WD Blue 1TB SATA, `sda`); no pre-wipe backup needed -- EXCEPT
      copy the MEDIA LIBRARY (`/local/mnt/workspace/naseer/jellyfin`, 382 GB, on the OS disk so it
      gets wiped) to the NAS `media` share first (~1 h over 1GbE; rsync in tmux + verify before
      wiping). BIOS: masn is CURRENTLY in "RAID On" mode (confirmed via lspci [RAID mode]; works
      only because single-disk + ahci driver) -> change SATA Operation to AHCI during the install
      (real change, not just a confirm). Verify after: `lspci|grep -i sata` shows [AHCI mode],
      `smartctl -a /dev/sda` returns SMART. (Backup discipline resumes once real data exists.)
      clean-install Ubuntu Server + switch
      BIOS SATA to AHCI together, OR convert in place. Restore from NAS; rebuild container
      stack (HA, Frigate, Mosquitto, Postgres; no Snapcast, no Jellyfin, no Omada -- UniFi controller
      is on the UCG-Max); migrate Jellyfin
      onto the NAS (`/dev/dri` Quick Sync); point Frigate recordings at the NAS, cache local.
      Set HA `restart: unless-stopped`. See the Phase 0 Runbook (section 17).
- [ ] Phase 2 (during construction): pull Cat6 (incl. 3 ceiling AP drops, one per floor) -- NO
      speaker home-runs (NuTone reused); install UCG-Max + USW-Pro-Max-16-PoE + 3x U7 Pro APs;
      adopt all in the UniFi controller; set up VLANs (Trusted/Cameras/IoT) + inter-VLAN firewall rules.
- [ ] Phase 3: install PoE cameras + doorbell; stand up Frigate with OpenVINO/iGPU detection
      (if contention: add the owned P620 per 3.3; Hailo-8L only if neither suffices); wire into HA;
      enable Nabu Casa; configure Frigate Notifications blueprint + household user sharing.
- [ ] Phase 4: ZBT-2 Thread Border Router; commission Matter/Thread switches + devices.
- [ ] Phase 5: audio -- WiiM Mini into the NuTone IM-3303 AUX (verify AUX module + master work).
- [ ] Phase 6: Pi 4 kiosk dashboard on old monitor; motion-based screen power.
- [ ] Phase 7: Orin voice/AI -- Ollama + faster-whisper (+ Piper); wire HA Assist via
      Wyoming; add voice satellite(s); set up Companion app control + phone-as-sensor.

---

## 15. Open Items / To Confirm

- [x] Audio system identified: NuTone IM-3303 (3-wire intercom, up to 9 rooms, mono AUX).
      DECISION: keep as-is, feed AUX with a WiiM (see 6.5). TO CONFIRM ON-SITE: AUX module
      present (else add NuTone AUX assembly) + master unit still functional.
- [x] OptiPlex 5050 chassis form factor: confirmed SFF -> existing SSD for OS in-box, bulk on NAS (the
      SFF's single bay can't mirror continuous footage).
- [x] Media library / disk growth: resolved -- NAS RAID1 holds media + recordings + backups,
      expandable by swapping to larger drives (section 3.2 / 6.7).
- [x] Matter/Thread device list: drafted from floor plan (section 6.4, ~27 devices). Finalize
      exact counts at install.
- [ ] HVAC zoning: confirm single vs dual zone at the furnace. If dual -> TWO Sinope
      thermostats, each needing its own C-wire solution. Affects BoM.
- [ ] Thermostat C-wire (per zone): check for hidden spare conductor at plate + furnace board
      first; else pull 18/5 if reachable, else buy add-a-wire adapter. Confirm Sinope
      Matter-Thread SKU.
- [ ] Confirm sump pump present in Utility room (Ajax) -> high-water alarm placement.
- [x] Front door lock: replacing entirely (used house -- security). Smart deadbolt on the
      active leaf of the double door + coordinating handleset.
- [ ] Photograph the ACTIVE LEAF DOOR EDGE -> confirm tubular (two round faceplates, drop-in)
      vs mortise (one tall rectangular faceplate, needs conversion / mortise smart lock).
- [ ] Security: rekey/replace ALL exterior locks (front, garage-entry, back/side). Decide
      how many to make smart (recommend front + garage-entry; rekey the rest).
- [x] Storage approach: UGREEN NAS (DXP4800 Pro, 4-bay, start 2x12 TB mirror, no drive lock) for
      continuous recordings + media + family Photos/Drive + backups + Jellyfin; existing SSD in masn for OS + Frigate
      cache. Continuous recording via dual-stream + tiered retention. Grow by adding a 2nd 2x12
      pair (-> 24 TB) when needed. Keep Frigate cache local; export NFS/SMB. UGOS now / TrueNAS later.
- [ ] Run extended SMART self-test on `/dev/sda` for active surface-scan confirmation.
- [ ] RTX 5070 box: stand up Ollama/vLLM (OpenAI-compatible) when available; build the
      health-check fallback router (5070 -> Orin -> cloud) in front of Frigate GenAI / HA;
      set up the batch queue for embeddings / face-LPR / AV1 re-encode. Confirm CUDA 12.8+.

---

## 16. Hardware Reused (no purchase)

- ASUS ZenWiFi BT10 pair -- NOT reused; SELL to offset the all-UniFi switch-over (~$400 credit). See 6.2
- Raspberry Pi 4 (dashboard kiosk)
- Old monitor(s) (dashboard display)
- WD Blue 1TB SATA SSD (OS + Frigate cache / app data)
- Intel HD 630 iGPU (Frigate decode + OpenVINO detection; transcode moved to NAS)
- Quadro P620 (optional GPU relief valve -- detection or transcode offload; see 3.3)
- NuTone IM-3303 system (master + speakers + wiring) -- reused as-is, fed by a WiiM at the AUX (6.5)
- Jetson AGX Orin (always-on local LLM/VLM inference, kept separate from HA)
- RTX 5070 Linux box (opportunistic, sometimes-available; preferred LLM/VLM endpoint + batch
  vision/AV1 jobs, with auto-fallback to the Orin -- see 12)

---

## 17. Phase 0 Runbook (first hands-on sequence)

Golden rule: NAS up and backups verified BEFORE masn is touched. Nothing here is destructive
until Step 4, and Step 4 is gated on a verified restore-able backup.

NOTE -- INITIAL GREENFIELD BUILD: user confirmed NO irreplaceable data on masn, so the full
backup Steps 2-3 are SKIPPED -- EXCEPT one thing: COPY THE MEDIA LIBRARY to the NAS `media`
share BEFORE the wipe (re-creatable from other backups, but easier to move it now). Source:
`/local/mnt/workspace/naseer/jellyfin` (382 GB, ~4047 files) -- it lives on the OS disk
(`/dev/sda2`) that gets wiped, so it MUST be copied first. ~1 h over masn's 1GbE; run it in tmux,
verify (file count + checksum sample), then do the clean install (Step 4). The golden rule + full
Steps 2-3 apply to ALL FUTURE revamps once real HA config + family data exist.

### Step 0 -- Pre-flight (no downtime)

- Confirm current state still healthy: `free -h` (32 GB), `docker ps` (homeassistant up),
  `df -h` (SSD has room). Note masn's IP and current container list.
- Inventory what must survive: HA config, Jellyfin config + media library, Docker volumes,
  Postgres DB, `/etc` (network, fstab, cron), any app data.
- Decide OS approach now (affects Step 4): RECOMMENDED clean-install Ubuntu Server + AHCI
  together (pristine, modern, de-risked by the backup; no NVMe means no install complication),
  OR convert-in-place (keep RAID mode, no wipe -- faster, keeps cruft). Rest of runbook
  assumes the clean install; in-place skips 4a/4b and just removes the desktop.

### Step 1 -- Stand up the NAS (the backup target)

1. Rack the gear (can be a bench setup first if the rack isn't built): NAS + UPS powered.
2. Disks. TARGET = 2x12 TB MIRROR. CHOSEN PLAN: start with 1x12 TB now, add the 2nd disk to
   form the mirror in a few months once the setup is stable. Same 12 TB usable meanwhile; NO
   redundancy until then.
   !! BUILD STATUS 2026-06-29: NAS arrived, but the 1st IronWolf Pro 12 TB was DOA (clicking =
      mechanical failure) on first power-up. Returned/RMA'd. BUILD BLOCKED until a working disk
      is in hand. Caught at burn-in on an empty array (the system worked as intended). Do NOT wipe
      masn -- it still holds the only copy of the 382 GB media library; no valid NAS target yet.
      Burn-in the replacement (SMART long + surface scan) before trusting it.
   - Use ZFS/TrueNAS so the mirror is added IN PLACE later: create a single-disk pool now, then
     `zpool attach` the 2nd 12 TB later (auto-resilvers, no re-copy). On UGOS, confirm a single
     "Basic" volume can convert to RAID1 by adding a disk WITHOUT a backup/restore -- if not,
     prefer ZFS, or you'll re-copy 12 TB later.
   - SMART short test + health check the disk before trusting it (full surface scan can run after).
   - Schedule MONTHLY ZFS scrubs: single-disk can't self-heal, but scrubs still DETECT bit-rot.
   - SINGLE-DISK SAFETY RULES (until the mirror exists):
     * Nothing IRREPLACEABLE may live on the NAS alone. Keep GOOGLE PRIMARY; do NOT run the
       "drop Google" migration yet. Recordings/media/masn-backups are re-creatable -> OK to risk.
     * masn wipe (Phase 0d): the NAS is your only backup copy, so KEEP masn's ORIGINAL SSD intact
       as the 2nd copy through the migration. Clean-install onto the new disk/NVMe, run the new
       stack ~1-2 weeks to verify, and only THEN wipe/reuse the original SSD.
   4-bay: leave 2 bays empty now; grow later by adding a 2nd 2x12 mirror pair (-> 24 TB usable).
3. Create shares + users per the access-control design (see 6.8): `backups`, `recordings`
   (Frigate svc + admin only), `media` (Jellyfin svc), `family-shared` (group `family`),
   per-member private folders, and a PASSPHRASE-encrypted `sensitive-docs` folder. No guest
   access anywhere. Export recordings/backups via NFS to masn's IP only; family shares via SMB
   to the Trusted VLAN. Keep encryption per-folder (not whole-pool) so reboots don't block the
   stack; ensure Tailscale lives on the unencrypted system area so you can unlock from your phone.
4. Wire the UPS USB to the NAS; enable graceful shutdown on battery.
5. Mount-test from masn: `sudo mount -t nfs <nas>:/backups /mnt/nas-backups` and write a test
   file. Confirm read-back.

### Step 2 -- Back up masn -> NAS

1. Stop write-heavy containers for a consistent copy: `docker compose stop` (or stop HA +
   Frigate); dump Postgres first: `pg_dump`/`pg_dumpall` -> file on the NAS share.
2. Copy to the NAS: HA config dir, Jellyfin `/var/lib/jellyfin` + `/etc/jellyfin`, all Docker
   named volumes, `/etc`, and the MEDIA LIBRARY (it's moving to the NAS anyway). Use `rsync
   -aHAX --info=progress2` to the mounted share.
3. Also take HA's own backup (Settings -> System -> Backups) and copy that archive to the NAS.
4. Note exact image tags/versions (`docker ps --format '{{.Image}}'`) so the rebuild matches.

### Step 3 -- VERIFY the backup (gate before anything destructive)

- Re-read key files off the NAS (checksums or open them). Confirm the Postgres dump is
  non-zero and the HA backup archive lists expected contents. Confirm the media copied fully
  (compare `du -sh` source vs dest).
- Only proceed past here once you can answer "yes, I could rebuild from this."

### Step 4 -- masn revamp (DESTRUCTIVE from 4b)

4a0. While the case is open (one-time longevity maintenance, since the host is a ~2017 box
     we intend to run for years): replace the CMOS battery (CR2032), re-apply CPU thermal
     paste, and check/clean the fans. Cheap insurance; the CPU itself rarely fails, these
     consumables do.
4a. (clean install only) BIOS: set SATA Operation RAID On -> AHCI. (The wipe removes the
    initramfs-RAID dependency, so this is safe now; only risky on a non-wiped in-place system.)
4b. Clean-install Ubuntu Server 24.04 (headless) on the existing 1TB SSD. Static IP/DHCP
    reservation matching the old one. Install: openssh-server, docker + compose plugin,
    NoMachine (on-demand GUI), NFS client.
4c. Re-mount the NAS shares via `/etc/fstab` (recordings + media + backups).
4d. Rebuild the container stack from compose: home-assistant (`restart: unless-stopped`),
    frigate (OpenVINO `/dev/dri`, cache local, recordings -> NAS), mosquitto, zigbee2mqtt,
    postgres (restore the dump). NO Snapcast (audio = NuTone + WiiM), NO Jellyfin on masn,
    NO Omada/UniFi controller (UniFi runs on the UCG-Max).
4e. Plug in BOTH radios on USB extension cables (out of the rack, spaced apart, USB 2.0). Pass
    each by its `/dev/serial/by-id/` path: ZBT-2 (Thread) -> OTBR/HA, Zigbee dongle -> the
    zigbee2mqtt container. Confirm both enumerate; set Zigbee + Thread to separate 2.4 GHz channels.

### Step 5 -- Jellyfin onto the NAS

- Install Jellyfin on the NAS (UGOS app/Docker or TrueNAS app); pass `/dev/dri` for Quick
  Sync. Point its library at the NAS `media` share. Restore Jellyfin config from backup.

### Step 6 -- Validate, then decommission the old state

- HA: entities/automations load; radios online; restart-survives-reboot test (`reboot`, confirm
  HA + Frigate auto-start). Frigate: recordings landing on the NAS, detection on iGPU working.
  Jellyfin: plays + hardware-transcodes from the NAS. UPS: pull mains briefly -> everything
  rides; NAS/masn shut down gracefully on low battery (test once).
- Keep the NAS backup of the OLD masn state until the new setup has run clean for ~1-2 weeks.

Rollback: if Step 4+ goes wrong and you took the optional NVMe, the old SSD is untouched --
swap back. Without the NVMe, rollback = reinstall + restore from the Step 2 backup (why Step 3
verification is non-negotiable).

---

## 18. Appendix: masn Docker stack (copy-paste ready)

Layout on masn (all LOCAL on the SSD except where noted):

```
/opt/stack/
  docker-compose.yml
  .env
  homeassistant/config/
  frigate/config/config.yml
  mosquitto/config/mosquitto.conf
  mosquitto/{data,log}/
  zigbee2mqtt/data/    (configuration.yaml + Zigbee network DB)
  postgres/            (named volume)
```

### 18.1 `/opt/stack/docker-compose.yml`

```yaml
services:
  homeassistant:
    container_name: homeassistant
    image: ghcr.io/home-assistant/home-assistant:stable
    restart: unless-stopped
    network_mode: host            # needed for device discovery (mDNS/SSDP)
    privileged: true              # simplest path for radios + Bluetooth; tighten later
    devices:                      # use /dev/serial/by-id/* stable paths, not ttyACM*
      - /dev/serial/by-id/usb-...ZBT2-thread...:/dev/ttyThread   # Thread (OTBR/HA)
      # Zigbee dongle is NOT passed here -- it belongs to the zigbee2mqtt container (below)
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./homeassistant/config:/config
      - /run/dbus:/run/dbus:ro
    depends_on: [mosquitto, postgres]

  frigate:
    container_name: frigate
    image: ghcr.io/blakeblackshear/frigate:stable
    restart: unless-stopped
    stop_grace_period: 30s
    shm_size: "512mb"
    devices:
      - /dev/dri/renderD128        # HD 630: OpenVINO detect + VAAPI decode
    group_add:
      - "993"                      # render GID from `getent group render`
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./frigate/config:/config
      - /mnt/nas/frigate:/media/frigate    # NAS: recordings/snapshots/exports
      - type: tmpfs                # cache LOCAL in RAM, never on NAS
        target: /tmp/cache
        tmpfs: { size: "1g" }
    ports:
      - "8971:8971"                # authenticated UI
      - "8554:8554"                # RTSP restream
      - "8555:8555/tcp"
      - "8555:8555/udp"            # WebRTC
    environment:
      FRIGATE_RTSP_PASSWORD: "${FRIGATE_RTSP_PASSWORD}"
      LIBVA_DRIVER_NAME: "iHD"
    depends_on: [mosquitto]

  mosquitto:
    container_name: mosquitto
    image: eclipse-mosquitto:2
    restart: unless-stopped
    ports:
      - "1883:1883"
    volumes:
      - ./mosquitto/config:/mosquitto/config
      - ./mosquitto/data:/mosquitto/data
      - ./mosquitto/log:/mosquitto/log

  zigbee2mqtt:                     # owns the Zigbee dongle; bridges Zigbee <-> MQTT <-> HA
    container_name: zigbee2mqtt
    image: ghcr.io/koenkk/zigbee2mqtt:latest
    restart: unless-stopped
    devices:                       # stable by-id path, never ttyACM*
      - /dev/serial/by-id/usb-...zigbee...:/dev/ttyZigbee
    volumes:
      - ./zigbee2mqtt/data:/app/data
      - /run/udev:/run/udev:ro
    ports:
      - "8080:8080"                # Z2M web UI (frontend)
    environment:
      TZ: "America/Toronto"
    depends_on: [mosquitto]
    # data/configuration.yaml: set serial.port: /dev/ttyZigbee, serial.adapter: ember
    # (ZBT-2/ZBDongle-E) or zstack (ZBDongle-P); mqtt.server: mqtt://mosquitto:1883;
    # homeassistant: true (enables HA MQTT discovery).

  postgres:
    container_name: postgres
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_DB: homeassistant
      POSTGRES_USER: "${PG_USER}"
      POSTGRES_PASSWORD: "${PG_PASSWORD}"
    volumes:
      - postgres:/var/lib/postgresql/data

  # No snapserver: audio = NuTone IM-3303 fed by a standalone WiiM at the AUX (see 6.5) -- no
  # masn-side audio container.
  # No network-controller container: UniFi controller runs on the UCG-Max gateway.

volumes:
  postgres:
```

### 18.2 `/opt/stack/.env` (chmod 600; never commit real secrets)

```bash
FRIGATE_RTSP_PASSWORD=change-me
PG_USER=hass
PG_PASSWORD=change-me-too
```

### 18.3 `mosquitto/config/mosquitto.conf`

```
listener 1883
allow_anonymous false
password_file /mosquitto/config/passwd
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
```

Create the user once: `docker exec -it mosquitto mosquitto_passwd -c /mosquitto/config/passwd hass`

### 18.4 HA recorder -> Postgres (in `homeassistant/config/configuration.yaml`)

```yaml
recorder:
  db_url: postgresql://hass:change-me-too@127.0.0.1:5432/homeassistant
  purge_keep_days: 30
```

(Frigate `config.yml` is in section "Frigate docker-compose with OpenVINO + NAS" above.)

Notes:
- Find the ZBT-2 path: `ls -l /dev/serial/by-id/` and map THAT stable path (not ttyACM0,
  which can renumber). Same idea for any USB device.
- `privileged: true` on HA is the easy start; once stable, replace with explicit `devices:` +
  the few capabilities Bluetooth/Thread need.
- Bring it up: `cd /opt/stack && docker compose up -d`; logs: `docker compose logs -f <svc>`.
- After a reboot, confirm all containers auto-start (`restart: unless-stopped`) and the NAS
  mount came up first (`_netdev` in fstab) so Frigate sees `/media/frigate`.
