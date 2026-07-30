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

### 3.2 Disk (NEW NVMe for OS -- existing SSD is FAILING -- + NAS for bulk)

!! REVISED 2026-07-02: The existing WD Blue 1TB SATA SSD (WDS100T2B0A) is FAILING -- cold reads
measured at 2.7-4.0 MB/s (should be ~500; a cached file read 371 MB/s, which masked the fault in
normal Jellyfin use). Surfaced by the bulk media read. => DO NOT reuse it for OS/Frigate/HA.
DECISION FLIP: buy a NEW 1TB NVMe (the "optional" NVMe, now REQUIRED) for the free M.2 slot -> OS
+ Docker + HA + Postgres + Frigate active cache. RETIRE the SATA SSD (keep it connected only long
enough to copy the media off, then discard). Everything else on masn (i7-7700, 32GB, HD 630) is fine.

Decision: masn OS/cache on a NEW 1TB NVMe; all bulk data (continuous
recordings, Jellyfin media, family Photos/Drive, masn backups) lives on a 4-bay NAS (start 2x14 TB mirror). This is driven by
the move to CONTINUOUS recording -- which a single SFF drive can't protect (one bay, no
mirror), and which makes the always-on footage valuable enough to want redundancy. The NAS
also does double duty (media, backups, local-first Drive/Photos) -- see 6.7.

Storage tiers:

| Tier | Where | Holds |
|------|-------|-------|
| Fast / OS | NEW 1TB NVMe (M.2 slot); old SATA SSD FAILING, retire it | OS, Docker, HA config, Postgres, **Frigate active cache (must stay local)** |
| Bulk (RAID1) | UGREEN NAS over the network (NFS/SMB) | Continuous recordings, Jellyfin server + library, masn backups, local-first sync/photos |
| Off-site (optional) | NAS sync (Nextcloud/Immich) or encrypted bucket | Kept event clips -- local-first alternative to Google Drive |

Do you need the NVMe? YES (revised). The old SSD is failing, so a new NVMe is now the OS/cache
disk, not optional. Light writes (OS/Docker/HA/Postgres) + Frigate active cache live here; the
heavy continuous recording stream still goes to the NAS. Install onto the NVMe; the failing SATA
SSD is NOT a rollback (it's dying) -- it's only the temporary source for the media copy.

Frigate-over-network rule: keep Frigate's `cache` dir on the local SSD; point only finished
`recordings` at the NAS share. The active cache must never write over the network (stalls);
finished-segment writes to the NAS are low and steady (trivial over gigabit). No local 3.5"
HDD needed in masn -- bulk goes to the NAS.

Phase 0 disk caveats:

- Switch BIOS SATA Operation from "RAID On" to AHCI BEFORE the clean install. This is now
  DOUBLY important: in "RAID On"/VMD mode Intel HIDES NVMe drives from the installer, so AHCI is
  required just to SEE the new NVMe. Switch first, then install.
- Install onto the NEW NVMe (M.2 slot). Copy the media off the failing SATA SSD first (it's the
  only reason to keep that disk powered), then remove/discard it.
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

DECISION 2026-07: P620 DECLINED (user does not want NVIDIA-driver upkeep on the 24/7 box). So
the HD 630 must be sufficient on its own -- achieved by running object detection on only the 4
choke-point streams and motion/record-only on the backyard (see 6.11). If the HD 630 ever DOES
saturate, the relief valve is NOT the P620 but Frigate's remote-detector offload to the owned
AGX Orin (see 6.11) -- accepting that this couples detection to the Orin and needs it flashed first.

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
| Radios | PRIMARY: SLZB-06 (Zigbee, network/central) carries sensors + garage + 3 Sinopé dimmers. ZBT-2 (Thread BR) now OPTIONAL/future | Zigbee is the one primary mesh, centrally placed; its routers are 6 mains plugs + 3 Sinopé + the garage relay (the 9 owned KS225 lighting dimmers are Matter-over-Wi-Fi, NOT Zigbee routers). Thread has nothing load-bearing |
| Thread Border Router | NONE for the initial build (ZBT-2 returned) | Zigbee-only build; add a ZBT-2 later only if a Thread-only Matter device appears |
| Cameras | PoE + Frigate (local NVR) | Bandwidth needs wired/Wi-Fi, not Thread; no cloud/subscription |
| Camera AI | Frigate + OpenVINO on HD 630 iGPU (object detection on 4 choke-point streams, see 6.11) | Coral EOL; iGPU detection costs $0 and keeps it off CPU; P620 declined so HD 630 must suffice (scoping makes it safe); Orin/5070 do the GenAI VLM layer, NOT the trip-wire |
| NVR platform | Frigate (NOT a Ubiquiti/UniFi Protect NVR) | Protect locks to UniFi cameras (2-5x cost, no third-party ONVIF), weaker HA integration, less-tunable AI. Frigate = camera-agnostic + HA-native + local + free (already running). All-UniFi was right for NETWORKING, not cameras |
| GPU relief valve (owned Quadro P620) | Optional; install only if iGPU contention appears | Splits decode/detect/transcode across two chips. Lean: P620 does detection (TensorRT); iGPU keeps decode + Quick Sync transcode. Free; +~40W. See 3.3 |
| Remote access + push | Nabu Casa (HA Cloud), $6.50/mo per instance -- SUBSCRIPTION ACTIVE (2026-06-25); link in HA after first boot | Ring-like mobile UX; secure, no port-forwarding; covers all users |
| Network core | UniFi: UCG-Fiber gateway in the BASEMENT rack (router + controller + firewall/IDS; NO Wi-Fi) + 3x U7 Pro APs, ONE PER LEVEL (basement/floor 1/floor 2; floor-2 AP over MoCA). SELL the ASUS BT10 to offset | BT10's weak VLAN/firewall software undermines the camera/IoT segmentation this build depends on. UniFi gives first-class, verifiable VLANs in one dashboard. UCG-Fiber (not the briefly-considered UDR7): its radio would be wasted in the rack + its IDS caps at 2.3G; UCG-Fiber runs the full 3G fiber with IDS ON. Modem relocates to the basement demarc -> whole core in one rack. See 5 |
| Switching/VLANs | UniFi USW-Pro-Max-16-PoE (basement rack); controller runs ON the UCG-Fiber (no self-hosted container) | 16 PoE ports size for 2 wired APs (basement + floor 1) + 4 cams + doorbell; 2.5G + 10G SFP+ for the NAS; one 10G SFP+ DAC to the gateway; floor-2 AP powered at its MoCA injector; one ecosystem/dashboard with the gateway + APs |
| Audio | Keep NuTone IM-3303 as-is; feed a WiiM streamer into its mono AUX | No wiring/speaker changes (lo-fi accepted); whole-house mono; casting + HA via WiiM. Snapcast dropped |
| Dashboard | Pi 4 + old monitor, Chromium kiosk | Free; reuse existing hardware |
| Asterisk | Dropped | Legacy; PoE doorbell + HA Assist cover door/intercom comms |

---

## 5. Network Design

> **CURRENT REALITY (2026-07)**: core is in the **2nd-floor OFFICE** (internet enters there). Installed:
> **UCG-Fiber + U7 Pro Wall + masn + NAS**, all in the office (no PoE switch yet). Floor-2 AP is wired
> off the office gateway -> the old floor-2 MoCA backhaul is moot. Coverage gap = floor 1 + basement
> APs/cameras.
> **LEADING BACKHAUL PLAN (investigating): repurpose the legacy Cat5.** Structured Cat5 (~2001 house =
> likely Cat5e) home-runs to a central panel. If the OFFICE has a Cat5 drop to that panel: office
> gateway -> office Cat5 jack -> panel -> PoE SWITCH at the panel -> patch the OTHER Cat5 drops (floor 1,
> basement, rooms) = fully WIRED backhaul + PoE, no MoCA/mesh. Solves floor-1 AP + cameras + basement in
> one shot. Verify per 5 option 0 (real 4-pair UTP not alarm wire; all 4 pairs; solid copper; test 1 Gbps
> + PoE+). Caveat: office<->panel over Cat5e = 1 Gbps (mild cap for future 3G fiber; upgrade that ONE run
> to Cat6 later if needed). Fallbacks if Cat5 unusable: wireless MESH (floor 1 good, basement weak) then
> MoCA. Read the basement-rack sections below as the target design.


```
BASEMENT RACK (whole core on one UPS):
  Coax demarc -> Cable modem (RELOCATED to basement)   [later: 3 Gbps fiber ONT -> 10G SFP+ WAN]
     | Ethernet WAN
  [ UniFi UCG-Fiber ]  (router + firewall/IDS + controller; 10G SFP+ WAN, 5 Gbps IDS -- full 3G)
     | 10G SFP+ DAC
  [ UniFi USW-Pro-Max-16-PoE ]   (VLANs + PoE; 2.5G + 10G SFP+)
     |     |        |        |         |            |
   masn  NAS   Pi4 kiosk  4x PoE cam  doorbell   3x U7 Pro AP (one per level)
                                                 (basement + floor 1 wired PoE; floor 2 via MoCA)
```

All UniFi -> one dashboard for routing, switching, Wi-Fi, and VLANs. Wi-Fi served by 3 U7 Pro APs,
ONE PER LEVEL (basement + floor 1 + floor 2; 3200 sqft, NO floor 3). ASUS BT10 retired (sold).
NO CEILING ACCESS on floors 1 & 2 (finished ceilings) -> those APs are WALL-mounted at the existing
wall jacks (U7 Pro WALL, directional -- purpose-built for a wall; face the open area, mount HIGH).
The basement ceiling IS accessible (keep a round U7 Pro there). Attic/ceiling runs are OUT for
floors 1 & 2.

Per-level AP placement (matched to the existing wall jacks):
- Basement: U7 Pro on the CEILING (accessible here; open Rec Room -- omnidirectional).
- Floor 1 (main / Kitchen): U7 Pro WALL at the existing MID-HEIGHT jack.
- Floor 2 (upper): U7 Pro WALL at a wall jack, backhauled over COAX/MoCA (no Cat6 path up -- see the
  MoCA option below). This is floor 2's only radio (the UCG-Fiber gateway is in the basement rack and
  has no Wi-Fi). PLACE IT ON THE FRONT WALL (a front bedroom with a coax jack for the MoCA feed): from
  up high it doubles as the AP covering the 3 FRONT Wi-Fi cameras (garage/porch/doorbell) below/outside
  -- better line-of-sight than the floor-1 AP. Aim the directional Wall AP toward the front.

GATEWAY CHOICE = UCG-Fiber, in the BASEMENT rack. CHOSEN over UCG-Max ($199) for the 3 Gbps FIBER
plan: 10G SFP+ WAN takes the fiber ONT handoff; 5 Gbps IDS/IPS delivers the full 3G with security
ON (Max caps ~2.3-2.5G). No Wi-Fi -> the 3 U7 Pro APs do it.
UDR7 (Dream Router 7) was CONSIDERED -- appealing because the cable modem currently sits on FLOOR 2
(fed by coax up from the basement demarc), so a UDR7 there would put its built-in Wi-Fi 7 radio to
use. REJECTED: (a) its IDS/IPS caps at 2.3 Gbps -> would throttle the 3 Gbps fiber or force IDS off;
(b) a gateway on a living floor splits the core (its own floor-2 UPS, hairpinned inter-VLAN traffic)
vs the clean single-rack topology; (c) its lone PoE port is 802.3af -- too weak for a U7 Pro anyway.
INSTEAD: RELOCATE the cable modem DOWN to the basement coax demarc (where coax already enters), so
modem + UCG-Fiber + switch + NAS + masn all sit in ONE rack on ONE UPS.
WAN handoff: cable modem -> UCG-Fiber 10G RJ45 WAN today; fiber ONT -> UCG-Fiber 10G SFP+ WAN when it
lands (terminate the ONT in the basement). Bought once (vs UCG-Max-then-replace).
UDR-5G-Max (5G cellular failover) also rejected: add failover to the UCG-Fiber's 2nd WAN separately.

Backhaul when ceiling runs are hard (construction reality) -- hierarchy, best first:
0. REPURPOSE EXISTING CAT5 (old ADT / structured-wiring drops found in the house -- ASSESS FIRST):
   Cat5 does full GbE + carries PoE at home distances -> real PoE Ethernet backhaul at wall jacks,
   no new cable, no MoCA/injector, no mesh penalty. BEST option if usable. Verify: (a) it's real
   Cat5/5e UTP (8 conductors/4 twisted pairs) NOT 4-wire alarm/station wire; (b) drops HOME-RUN to
   a central panel (patch it to the switch, or extend to the basement rack); (c) map each far end
   (room/floor, wall jack?); (d) test each run -- continuity + links at 1GbE + delivers PoE+
   (U7 Pro = 802.3at ~22W; Cat5/5e handles PoE+ fine). Verify SOLID COPPER (not CCA) + ALL 4 PAIRS
   terminated (split "2-pair-for-phone" runs break gigabit AND PoE+).
   TEST BEFORE BUYING THE APs (no UniFi gear needed): (1) NF-468 = wiremap + tone-map; (2) gigabit
   = any switch/router you own at one end + a laptop at the room jack -> confirm 1000 Mbps (also
   catches split pairs); (3) PoE = OPTIONAL (a ~$20 PoE+ injector + inline tester) -- if (1)+(2)
   pass, PoE+ is essentially assured (same conductors, same failure modes). Buy U7 Pro Walls only
   for the CONFIRMED-good drops; fall back to MoCA/mesh for dead ones. Harvest
   the WIRING + enclosure; ignore the ADT brain (proprietary/locked; security = HA + Zigbee sensors).
   USE CAT5 AS-IS: 1GbE + PoE is plenty for a U7 Pro (Cat6 only buys 2.5G, which a home AP won't
   saturate). Don't pull Cat6 through the old path as a pull-string unless it's UNSTAPLED (conduit/
   free-run) -- residential low-voltage is usually stapled, so pulling snaps it and you lose the
   working Cat5. If a spot genuinely needs 2.5G+ (wired desktop, not APs), pull FRESH Cat6 through
   open walls during construction instead.
1. WIRE IT (new): ceiling AP via ATTIC (top floor, if attic accessible); or WALL-MOUNT an AP fed
   from the BASEMENT up a wall cavity (main floor -- easier than its sandwiched ceiling). Wall-high
   performs ~as well as ceiling IF mounted HIGH. WALL-MOUNT MODEL: U7 PRO WALL (full Wi-Fi 7 tri-band,
   ~1500 sqft, directional -- purpose-built for a wall; face it toward the floor's OPEN area, not a
   corner). Don't wall-mount a round U7 PRO (omni pattern fires ~half into the wall behind) -- keep
   the Pro for CEILINGS; use it wall-mounted only if you want omni coverage AROUND that spot (rooms
   on multiple sides). NOT the U7 In-Wall (dual-band, no 6 GHz, room-sized -- per-room/desk AP).
   HEIGHT: Cat5 jacks sit at outlet height (~1 ft) = poor AP spot -> run the drop UP the wall and
   mount the AP HIGH (near ceiling). Height matters more than model.
2. MoCA (Ethernet over existing COAX -- house HAS coax): a MoCA adapter PAIR -> true wired backhaul
   at a coax jack, NO new Cat6, NO mesh penalty. Preferred over mesh. CHOSEN for the FLOOR-2 AP
   (no easy Cat6 path up there). Products: goCoax MoCA 2.5 (WF-803M) pair (~$65 ea, 2.5G, headroom)
   or a MoCA 2.0 pair (Motorola MM1025 ~$45 ea, 1G -- plenty for one AP). One adapter by the switch
   (basement, Cat6 to a switch port), one at the floor-2 coax jack.
   - Coexists with the CURRENT CABLE internet (same coax): install a MoCA POINT-OF-ENTRY FILTER
     (~$10; here "PoE" = Point-Of-Entry, NOT Power-over-Ethernet) where coax enters (ground block/
     main splitter) + use MoCA-rated splitters (5-1675 MHz; old 5-1000 MHz blocks MoCA -- MoCA rides
     1125-1675 MHz, above DOCSIS). When FIBER lands, internet leaves the coax -> MoCA-only, filter optional.
   - AP power: MoCA gives Ethernet at the jack but NO PoE -> add an 802.3at PoE INJECTOR (~$20; a
     U7 Pro needs PoE+) + a wall outlet at the floor-2 AP. Chain: coax -> MoCA adapter -> PoE
     injector -> U7 Pro.
3. UniFi WIRELESS MESH -- last resort, ONE unreachable AP only: shared-radio backhaul ~halves
   throughput + adds latency, so keep it to 1 hop off a WIRED AP (never daisy-chain), 6 GHz
   backhaul. Wire >=2 of 3; never all-mesh. Stays fully managed (VLANs/dashboard) unlike consumer mesh.
Do NOT revert to consumer mesh (BT10/Eero/Orbi) for backhaul -- loses the VLAN segmentation.
Pull cable wherever walls are OPEN NOW (+ a spare drop per AP-candidate) while work is ongoing.
WAN timeline: CABLE now (coax/DOCSIS); 3 Gbps FIBER coming later -- city work order, up to ~1 yr out.
RELOCATE the modem to the basement demarc first (see gateway choice). UCG-Fiber handles both with NO
swap: cable modem -> UCG-Fiber 10G RJ45 WAN today (auto-negotiates); fiber ONT -> UCG-Fiber 10G SFP+
WAN when it lands. Bought once (vs UCG-Max-then-replace). When fiber lands, confirm the ONT hands off
at >2.5G (SFP+ or 10G/5G RJ45) and terminate it in the basement. Build proceeds NOW on cable; 3 Gbps
just turns on with fiber -- full 3G inspected (5G IDS headroom). Note: individual 1G devices won't see
3 Gbps -- benefit is household aggregate + the 2.5G/10G NAS across the basement switch.

VLAN plan (UniFi "Networks"; tagged per-port on the switch + per-SSID on the APs; inter-VLAN
firewall rules on the UCG-Fiber):

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
| M.2 2280 NVMe SSD 1TB (REQUIRED) | 1 | $80 | $80 | REVISED 2026-07-02: existing SATA SSD is FAILING (cold reads 2.7-4 MB/s) -> new NVMe is the OS/Docker/HA/Postgres/Frigate-cache disk. Goes in the free M.2 slot. NVMe uses that slot -> a Hailo M.2 (last-resort detector) would conflict, but detection is on the iGPU/P620 anyway |
| | | | **~$80** | RAM done; detection on iGPU/P620; NEW NVMe replaces the failing SSD. Retire the old SATA SSD after the media copy |

(Existing healthy 1TB SATA SSD is the OS/app/cache tier -- NVMe not needed. Detection runs on
the HD 630 iGPU via OpenVINO -- no Coral/accelerator to buy up front. Bulk storage --
continuous recordings, media, backups -- lives on the NAS, see 6.7. No internal HDD in masn.)

### 6.2 Network

| Item | Qty | Est. each | Est. total | Notes |
|------|-----|-----------|------------|-------|
| UniFi Cloud Gateway Fiber (UCG-Fiber) -- basement rack | 1 | $279 | $279 | Router + firewall/IDS + runs the UniFi controller. CHOSEN over UCG-Max ($199): 10G SFP+ WAN takes the fiber ONT handoff; 5 Gbps IDS/IPS delivers the full 3G with security ON (Max caps ~2.3-2.5G). No Wi-Fi -> APs do it. No local storage (Frigate->NAS, not UniFi Protect). UDR7 considered but rejected (radio wasted in the rack + 2.3G IDS cap) -- see 5 |
| 10G SFP+ DAC (gateway <-> switch) | 1 | $20 | $20 | Links UCG-Fiber 10G SFP+ LAN to a switch SFP+ port -> carries the 3G WAN into the LAN at 10G |
| UniFi USW-Pro-Max-16-PoE (basement) | 1 | $379 | $379 | 12x1G PoE+ + 4x2.5G PoE++ + 2x10G SFP+, 180W. Powers the 2 wired APs (basement + floor 1) + cameras; one SFP+ to the gateway (DAC), 10G SFP+ free for NAS. The floor-2 AP is powered at its MoCA injector. 1U rackmount |
| UniFi U7 Pro / U7 Pro Wall AP (Wi-Fi 7, PoE) | 3 | $199 | $597 | ONE PER LEVEL: basement CEILING U7 Pro (omni) + floor-1 U7 Pro WALL + floor-2 U7 Pro WALL (backhauled over MoCA). Floors 1 & 2 = WALL (NO ceiling access); basement ceiling is accessible. Floor 2's AP is its only radio (gateway is Wi-Fi-less, in the basement). NOT U7 In-Wall (no 6 GHz, room-sized) |
| MoCA backhaul kit (floor-2 AP -- no Cat6 path) | 1 | $175 | $175 | goCoax MoCA 2.5 PAIR (~$130; or MoCA 2.0 ~$90 -- 1G is plenty for one AP) + 802.3at PoE INJECTOR (~$20; MoCA carries no PoE) + MoCA POINT-OF-ENTRY filter (~$10) + MoCA-rated 5-1675 MHz splitter (~$15). Chain: coax -> MoCA -> injector -> U7 Pro Wall |
| Cat6 cable (1000 ft box) | 1 | $120 | $120 | Home runs incl. AP drops to each floor |
| Keystones / patch panel / RJ45 / boots | 1 lot | $80 | $80 | Terminate T568B BOTH ends (straight-through; auto-MDIX means no crossover). Untwist <=0.5in to avoid split pairs. PREFER punch-down KEYSTONES/patch panel for in-wall runs (more reliable than crimped plugs on solid wire); if crimping RJ45, use SOLID-rated or PASS-THROUGH plugs. Match the existing end's A/B if already terminated |
| Cable tester/toner (Noyafa NF-468) + inline PoE tester + crimper/punch-down | 1 lot | $70 | $70 | CHOSEN: NF-468 (~$30 CAD) = continuity/wiremap + TONE-TRACE to ID each ADT drop (one at a time: tone one end, probe the bundle). Inline PoE tester (~$25) reads PoE+ (802.3at). The real 1G+PoE qualify = power the actual AP off a switch PoE+ port (catches split pairs too -- they fail gigabit) |
| 10GBASE-T SFP+ module (OPTIONAL) | 0-1 | $60 | $0 | Only if NAS at 10G via SFP+; else NAS on a 2.5G port (plenty). Runs hot |
| UniFi controller | - | on UCG-Fiber | $0 | No self-hosted container (was Docker on masn) |
| | | | **~$1,720** | Less ASUS BT10 resale (~$400 credit) -> net ~$1,320 |

### 6.3 Cameras

| Item | Qty | Est. each | Est. total | Notes |
|------|-----|-----------|------------|-------|
| Reolink TrackMix PoE -- FRONT: garage gable, down the driveway | 1 | $190 | $190 | REVISED 2026-07-21 (was TrackMix WiFi). Dual-lens: WIDE (fixed) + TELE (pan/tilt, camera-native auto-track). Rated S TIER in independent PoE testing. Goes on the highest-traffic zone -- driveway, both garage doors, street approach -- where auto-tracking actually earns its keep. Wide lens holds the full scene continuously while the tele swings/zooms for face + plate. In Frigate = TWO cameras via go2rtc (see notes) |
| Reolink CX810 -- REAR-RIGHT + REAR-LEFT corners: THE TWO SIDE-YARD GATES | 2 | $129 | $258 | REVISED 2026-07-21: qty 1 -> 2. BOTH side yards have gates (to #52 AND to #48), so both are real routes to the backyard and each gets its own capture cam (see layout note). ColorX sensor (F1.0, 1/1.8") = TRUE COLOUR night video from ambient light alone, plus notably less motion smearing at night -- the right trade for a dark side yard where the job is NIGHT IDENTIFICATION at a choke point. A TIER. Spotlight + siren. Mount at the REAR-RIGHT (south) corner aimed FORWARD up the side yard -- traffic through the gate walks the full corridor INTO the lens (faces, not backs). Alt if tighter framing wanted: RLC-843A (A tier, 5x varifocal, best pure detail -- but weaker in the dark) |
| Reolink Duo 2 PoE -- MID BACK WALL: the backyard | 1 | $190 | $190 | 180 deg panoramic, A TIER, the recommended tool for WIDE coverage. MOVED 2026-07-21 off the rear-left corner to the middle of the back wall: with a CX810 now on each side yard, the Duo no longer has to double as the left-side cam and its 180 deg is spent entirely on the backyard. (A panoramic is the WORST tool for a narrow corridor -- oblique angle, low pixel density -- and the best for an open yard; the 4th camera let each unit do ONE job well.) Coverage cam: its job is "someone is in the yard", not ID -- anyone reaching it already passed a CX810 at a gate where the identifying shot was taken. NOTE: do NOT substitute the Duo 3 PoE (see models-to-avoid) |
| Wi-Fi video doorbell -- FRONT DOOR (RTSP) | 1 | $100 | $100 | Reolink Video Doorbell WiFi -- REPLACES the existing NuTone intercom DOOR STATION. RTSP + Frigate + two-way talk. Replaces the planned PoE doorbell (no Ethernet to the front). Power: existing doorbell transformer if 12-24V AC present, else a plug-in transformer off the soffit outlet OR the battery version |
| NuTone-intercom doorbell adapter plate | 1 | $20 | $20 | Covers the old NuTone door-station cutout + mounts the Reolink. Kyle Switch Plates / DoorBell Mount (custom for Reolink), or a blank oversize plate + Reolink backplate. MEASURE the box screw spacing first (4/4.5/5.25/6.25/6.58") |
| Wi-Fi PTZ auto-track cam (RTSP) -- wide area | 1 | $170 | $170 | Reolink TrackMix WiFi (dual-lens: wide + telephoto, camera-native auto-track). COMPLEMENTS the fixed cams (don't let it replace an entry cam -- PTZ may be panned away). In Frigate = TWO cameras via go2rtc: WIDE (h265Preview_01) = detect + full-scene record; TELE (h264Preview_02) = auto-tracked close-up record. Use CAMERA-NATIVE tracking, NOT Frigate onvif_autotrack (Reolink ONVIF flaky). HIGH Wi-Fi load (2 lenses) -> needs a strong AP; get TrackMix POE if the spot can be wired (MoCA->injector) |
| | | | **~$758** | 4 PoE cameras + doorbell (REVISED 2026-07-21: 5 Wi-Fi cams ~$720 -> 3 PoE ~$629 -> 4 PoE ~$758 once the second gate was confirmed). Prices are estimates -- only the CX810 ($129) is confirmed; verify TrackMix PoE + Duo 2 PoE at purchase |

Camera notes (Frigate):
- Reolink works but its RTSP is finicky and some models cap simultaneous connections -> always
  pull through go2rtc (restreams one connection to detect/record/live). Amcrest/Dahua-OEM are
  the more bulletproof RTSP choice if you want zero fuss.
- Require dual-stream (detect on substream, record on mainstream -- the storage design depends
  on it) and H.265 (to hit ~4 Mbps/cam sizing). Prefer PoE. EXCEPTION: a MAINS-powered Wi-Fi RTSP
  cam is fine for a hard-to-wire spot that HAS power (see porch) -- keep it to a couple; Wi-Fi
  streams are less reliable than wired. BATTERY Wi-Fi cams remain unfit (no continuous RTSP).
- Reolink Duo 2V (dual-lens, ~180 stitched): good COVERAGE cam (driveway/yard), but weaker for
  detection (objects small/distorted on the ultra-wide frame; needs split config). Use single-
  lens (e.g. RLC-810A/820A/520A) as primary detection cams; at most one Duo for wide coverage.
- Auto-tracking (PTZ): fixed cams for perimeter/entry (always see the whole scene); optionally ONE
  PTZ for a wide area (long driveway/yard). Camera-native tracking works with any RTSP; Frigate-
  driven `onvif_autotracking` needs proper ONVIF PTZ (Dahua/Amcrest more reliable than Reolink).
- FRONT OF HOUSE -- SUPERSEDED 2026-07-21: the previous plan was THREE Wi-Fi cams at the front
  (Duo Floodlight + RLC-810WA + doorbell) because no Ethernet ran to the front. That is REPLACED by
  running Cat6 and going PoE. The old Wi-Fi-load worry (Duo counting double, needing the floor-2 AP
  aimed at the exterior, dropped streams = Frigate gaps) disappears with wired cameras -- which was
  always the weakest part of that design. Doorbell stays Wi-Fi unless Cat6 reaches the door box.

- CAMERA LAYOUT (DECIDED 2026-07-21): THREE PoE cameras + the doorbell. Corner-mount, do NOT point
  cameras straight out at flat walls. With a low camera count use a DIAGONAL/PINWHEEL layout --
  cameras at opposite corners each cover TWO faces of the house, so 3 units cover the whole
  perimeter. Pointed straight out, the same 3 give 3 narrow slices with gaps between them.
  Think in two camera JOBS: OVERVIEW (high/wide, "what happened") vs CAPTURE (aimed at a choke
  point, "who was it"). Every approach funnels through a choke point -- driveway entrance, porch
  steps, side gate -- so put a capture angle on each and overview on the open areas.
  1. TrackMix -> garage gable, aimed down the driveway (front/driveway/garage + street approach).
  2. CX810 -> REAR-RIGHT corner (the SOUTH corner on the map: where the gate side meets the back),
     aimed FORWARD/NW up the side yard toward the gate + street. The gate to #52 is the main
     unobserved route to the backyard and the classic gap in a 3-camera build.
     WHY THIS CORNER (decided 2026-07-21, and it reverses an earlier call): aiming from the
     FRONT-right corner backwards gives ONE good face -- the moment they are at the gate -- then
     films their back down the side yard. From the REAR-right corner facing forward, anyone coming
     through the gate walks the ENTIRE LENGTH of the side yard straight into the lens, getting
     closer and larger the whole way: a long capture window with INCREASING detail, and the camera
     sits exactly where it guards the transition into the backyard.
     NOTE the house sits ~39 deg off compass north, so "southwest corner" is ambiguous -- the SOUTH
     corner is rear-right (correct); the WEST corner is front-right (wrong: it looks out over the
     front yard, duplicating the TrackMix, with the gate BEHIND the camera).
     SUN: facing NW puts the low EVENING summer sun into the lens, which is prime event time.
     Mount tight under the soffit so the eave shades it, and tilt down so sky is out of frame
     (the CX810's HDR covers the rest).
  3. CX810 #2 -> rear-LEFT (EAST) corner, aimed FORWARD/NW up the LEFT side yard toward the gate
     to #48. Exact mirror of #2. ADDED 2026-07-21 once the #48-side gate was confirmed.
  4. Duo 2 PoE -> MID BACK WALL, 180 deg over the backyard only.
  The doorbell owns the front door, which frees the front cameras from having to watch it.
  WHY THE 4th CAMERA EARNS ITS PLACE (it is corrective, not additive): with 3 cams the Duo was
  doing TWO jobs at once -- backyard AND left side yard from an oblique angle. A 180 deg panoramic
  is the right tool for an open yard and the WORST for a narrow corridor (low pixel density,
  distorted geometry, objects tiny in frame). So the weakest-covered approach in the whole design
  was a real gate. Adding CX810 #2 means every unit does ONE job well: both gates get a capture cam
  the intruder walks TOWARD, and the Duo's panorama is spent entirely on the yard.
  BLIND SPOT: none material. The earlier "front portion of the left side yard" gap is CLOSED.
  MOUNT HEIGHTS: TrackMix high on the gable is fine (its tele lens compensates), but mount the
  CX810 LOWER (~8-9 ft) -- a fixed camera mounted too high sees the tops of heads, and it has no
  zoom to make up for it. 9-10 ft under soffit/eave elsewhere: weather protection, tamper height,
  and it avoids IR bounce-back off a porch ceiling washing out night video. Don't aim into street
  lights or the setting sun (backlight silhouettes faces). Overlap fields so each camera sees the
  base of the next camera's wall -- no dead zone at the foot of any wall.

- MODELS TO AVOID (independent PoE tier-list testing):
  - Duo 3 PoE = D TIER. Tempting on spec (newer, 16MP, dual-lens) but its 32:9 aspect badly cuts
    VERTICAL field of view, the 16MP adds bandwidth/detection load without real clarity gain, and
    it causes app lag. The older Duo 2 is A tier for the same job. Higher resolution on a very wide
    camera is often a DOWNGRADE -- pixels spread across a strip you don't need.
  - RLC-810A = C tier ("middle-of-road, lacking specialization").
  - RLC-811A = B tier -- beaten by the RLC-843A on daytime image quality at similar money.
  Source: thesmarthomehookup.com Reolink PoE tier list.

- BACKYARD LIGHTING (DECIDED 2026-07-21): camera 4 stays a plain Duo 2 PoE. Do NOT buy a floodlight
  camera. Instead put the EXISTING back-door light on a Sinopé SW2500ZB Zigbee switch (see 6.4) and
  drive it from HA on a Frigate person-detect in the backyard zone, with a timer off.
  The Reolink Duo Floodlight PoE was the alternative -- same 180 deg role, same A tier, 1800 lm /
  4200K, 802.3at PoE+ and up to 24W (would have been the single largest PoE draw; must land on a
  PoE+ port, not a basic 802.3af one). Rejected because a separate switched light is better here:
  * NO INSECTS AT THE LENS. The standard failure of floodlight cams: the light attracts moths that
    fly through frame all night and spiders web the housing. Frigate's OBJECT detection blunts the
    false-alert half of this (a moth is not a `person`), but the image degradation is real.
  * The light can be positioned where it lights the yard BEST, not wherever the camera happens to
    sit -- and it avoids near-field glare/bloom washing out the camera's own image.
  * Reuses the Zigbee mesh already built, adds a router at the BACK of the house, and costs less.
  * 1800 lm in a tight suburban yard spills into #48/#52 -- easier to aim a fixture than a camera.
  TRIGGER ON DETECTION, not dusk-to-dawn: fewer bugs, stronger deterrent when it snaps on, and it
  keeps the yard dark (and the neighbours happy) the rest of the night.
  REVISIT the Duo Floodlight PoE only if the existing back fixture turns out to be unusable.

- PoE WIRING: one Cat6 home-run per camera back to the USW-Pro-Max-16-PoE (switch powers them, no
  local power needed). Runs are well under the 100 m limit for this house. Cameras land on the
  Cameras VLAN; Frigate pulls RTSP locally, footage never leaves the network. PLAN THE SOFFIT
  ENTRY POINTS NOW (where Cat6 penetrates to reach each mount) -- that is the part that is painful
  to retrofit once soffit/drywall is closed.

- FRIGATE + these cameras: the TrackMix is effectively TWO cameras (wide + tele as separate
  entries). The Duo 2's 180 deg panorama means objects occupy few pixels relative to the frame, so
  tune DETECTION ZONES rather than running full-frame detection on it. Everything behind go2rtc.
  3 cameras on the HD 630 with OpenVINO is comfortable.
- DOORBELL <-> NuTone: the NuTone intercom DOOR STATION is retired (user OK); the Reolink doorbell is
  the button + camera + two-way talk. Mount it on a NuTone-intercom adapter plate (see BoM; measure
  the box screw spacing first). Chime the WHOLE HOUSE via HA: doorbell-press event -> HA automation ->
  WiiM -> NuTone AUX plays a chime/announcement over the existing speakers. Keep the IM-3303 for
  music + room-to-room intercom (see 6.5). The two systems don't integrate electrically -- HA bridges them.

- AS-BUILT / HA ONBOARDING (2026-07-28): all 5 Reolink units mounted, on the LAN, and added to HA
  via the native Reolink integration (auto-discovered over SSDP; completed each Discovered flow with
  user `admin`). They ship with HTTP/HTTPS/RTSP/ONVIF OFF -- only Reolink's Baichuan port 9000 was
  open -- and the integration authenticated over Baichuan and enabled the rest itself; no per-camera
  toggling was needed. Identify cameras by MAC/IP, NEVER by DHCP hostname (see swap note below).

  | HA device | IP | MAC (ec:71:db:..) | Model | Role | Area |
  |-----------|------|-------------------|-------|------|------|
  | Driveway  | .86  | 1d:b7:f6 | TrackMix PoE       | garage gable -> driveway/street | Outside |
  | West Gate | .22  | 66:c9:f4 | CX810              | west side-yard gate choke point | Outside |
  | East Gate | .130 | b9:a5:98 | CX810              | east side-yard gate choke point | Outside |
  | Backyard  | .217 | 06:a2:d7 | Duo 2 PoE          | mid back wall, 180 deg backyard | Outside |
  | Doorbell  | .151 | 5f:04:3f | Video Doorbell PoE | front door + press event        | Entrance |
  | Doorbell Chime | -- | (accessory) | Reolink Chime | front-door chime              | Entrance |

  HOSTNAME SWAP (do not trust it): the DHCP hostnames of the two identical CX810s are crossed --
  .130 broadcasts hostname `west` but is physically the EAST gate; .22's hostname is generic `cx810`
  but it is the WEST gate. Cause: the twins are indistinguishable hardware, mislabelled at install.
  HA is CORRECT regardless -- it names devices from the camera's internal device-name (already right)
  and keys them by MAC, so "West Gate"/"East Gate" in HA match reality. Frigate/firewall configs must
  key on MAC or the IPs in this table, not the hostname. Fix is cosmetic only; left camera-side as-is.

  DHCP RESERVATIONS: done 2026-07-28 on the UCG-Fiber (by MAC, as with the SLZB-06). When the
  Cameras VLAN lands, re-point the reservations (one dashboard), do NOT set device-side static IPs.

  GOOGLE EXPOSURE (2026-07-28): one primary sub-stream per physical camera exposed to Google
  (camera.garage_fluent_lens_0 = TrackMix WIDE, west_fluent, east_fluent, backyard_fluent,
  outside_doorbell_fluent) -- the low-res `fluent` streams, which is what Nabu Casa wants for casting
  to a Nest Hub. Only ONE stream per camera is exposed so Google Home shows one device each, not the
  clear/snapshot duplicates. REMINDER: this HA instance records exposure in core.entity_registry
  options["cloud.google_assistant"]["should_expose"], NOT the homeassistant.exposed_entities store --
  verify there, or you get a false "nothing exposed" (see the exposure-trap note). The
  homeassistant/expose_entity WS API writes to the correct place (used here, live, no restart).

  DASHBOARD: westacott.json gained a "Cameras" section (5 picture-entity cards, camera_view auto ->
  snapshot that goes live on tap; TrackMix shown as its WIDE lens). Applied to both `-` (Overview)
  and dashboard-westacott. No restart needed -- Overview was already in storage mode.

### 6.4 Smart home (Matter/Thread)

| Item | Qty | Est. each | Est. total | Notes |
|------|-----|-----------|------------|-------|
| HA Connect ZBT-2 dongle (Thread Border Router) | 0-1 | $35 | $0 | NOW OPTIONAL/FUTURE: with lighting on Zigbee, nothing load-bearing runs on Thread. Keep as cheap future-proofing for a Thread-only Matter device (or the lock's Thread module), or DEFER until one appears. Not needed for the initial build |
| Zigbee coordinator: SLZB-06 (network-attached) | 1 | $40 | $40 | Mount CENTRALLY on floor 1 (NOT the basement rack); Z2M over TCP. START: Ethernet jack + USB power (no PoE needed at first); PoE later if the drop is on a PoE port. Separate 802.15.4 channel. USB Sonoff ZBDongle-E / 2nd ZBT-2 (~$30) is the fallback |
| USB-C power adapter for SLZB-06 | 1 | $10 | $10 | INTERIM ONLY -- MOVE THE COORDINATOR TO PoE once the USW-Pro-Max-16-PoE is in. 2026-07-21: a flaky USB-C connection powered the SLZB-06 down and took the ENTIRE Zigbee network out for ~7.5 h (Z2M crash-looped 198 times on "Error while opening socket"). That connector is a single point of failure for all ~31 Zigbee devices. PoE removes it AND puts coordinator power on the same UPS-backed rail as the rest of the core |
| USB extension cable (1-2 m) | 0-1 | $8 | $0 | Not needed for the SLZB-06 (Ethernet, central floor 1, not USB). Only if a ZBT-2 Thread BR is added later (get it out of the rack + off USB 3.0) |
| Sinopé DM2500ZB Zigbee dimmer (600 W) | 3 | $45 | $135 | The 3 dimmer spots NOT covered by the owned KS225s (12 spots total - 9 KS225 = 3). Zigbee, NATIVELY in Z2M (converter DM2500ZB -- on/off, dim, transition, timer, LED intensity, min-brightness, power-on) -> pairs to the SLZB-06, NO Sinopé hub/Neviweb. CANADIAN brand. Mains Zigbee ROUTERS -- deliberately keep these 3 as Zigbee (not more KS225) to seed the mesh for the battery sensors + garage relay. Neutral required (boxes have it). Verify dimmable LED loads + 3-way per Sinopé guide (DM2550ZB for tricky loads). Alt: Inovelli Blue 2-1 |
| TP-Link Kasa KS225 Matter-over-Wi-Fi DIMMERS (9, OWNED) | 9 | owned | $0 | KEPT -- past the return window (2026-07). Cover 9 of the 12 dimmer spots. Matter-over-WI-FI (2.4 GHz), NOT Thread -> NOT Zigbee/Thread routers. COMMISSIONING (proven 2026-07): pair in the KASA app first, then Kasa -> share/link to other platform -> paste the generated code into HA (Matter multi-admin). The direct HA-companion-app path FAILS: it hands off to Google Play Services, which falls back to `commission_on_network` against the switch's link-local IPv6 and dies in the PASE handshake (`Expected message type 33` -> `CHIP Error 0x00000003`). Only the one switch that went via BLE `commission_with_code` ever succeeded that way. Google Home is not an option either (needs a Nest hub; none owned). NO USB Bluetooth dongle needed on masn -- the phone supplies BLE at close range. Cost: TP-Link's cloud holds an admin fabric until removed in-app (see cloud-exit note below). Put on the IoT SSID/VLAN. 9 is fine on U7 Pro APs -- congestion worry was a scale concern, not a 9-device one |
| Aqara Thermostat Hub W200 (BOUGHT -- availability) | 1 | $150 | $150 | Furnace+AC (conventional 24V; ~85% HVAC incl. heat pump). NOT a Z2M Zigbee endpoint -- it's a HUB (thermostat + Zigbee hub + Matter controller + THREAD BR). Integrate into HA via MATTER (Aqara app -> pairing code -> HA Matter), NOT the SLZB-06. Use standalone; do NOT pair other Zigbee to its hub (keep all Zigbee on SLZB-06/Z2M). Its built-in Thread BR = definitively no ZBT-2 needed. HA-via-Matter gets core control; adaptive/schedule features app-only |
| Aqara C-Wire Adapter | 0-1 | $25 | $25 | Only if no C-wire at the furnace -- the matched accessory for the W200 (not a generic Fast-Stat) |
| Matter smart deadbolt (front door, full replacement) | 1 | $200 | $200 | Replacing all locks anyway (used house -- security). Front is a DOUBLE door: smart deadbolt on ACTIVE leaf + coordinating handleset for looks. Yale Assure 2 (Thread module) or Aqara U200/U100. Confirm tubular (drop-in) vs mortise (needs conversion) from door-edge photo |
| Contact sensors (Zigbee) | 6 | $18 | $108 | Doors/windows; security + HVAC-open alerts |
| Motion sensors (Zigbee) | 4 | $22 | $88 | Lighting, presence, camera-arm logic |
| Leak sensors (Zigbee) | 6 | $18 | $108 | Kitchen, laundry, baths, water heater, furnace |
| Sump / high-water alarm (Zigbee) | 1 | $35 | $35 | Ajax flood risk -- catches pump failure |
| Temp/humidity sensors (Zigbee) | 3 | $15 | $45 | Basement, family room, baths (fan automation) |
| Smart plugs Matter-Thread (incl. 1-2 outdoor) | 4 | $26 | $104 | Mains -> Thread; lamps, patio/gazebo, spa |
| Zigbee smart plug (mesh router) | 6 | $15 | $90 | NOW MANDATORY (was optional): with only 3 Sinopé dimmers left on Zigbee, these carry the router mesh. Spread ~2 per floor + one on the garage path so no battery sensor is >1 hop from a mains router. Mains -> Zigbee router |
| Sinopé SW2500ZB Zigbee SWITCH (non-dimming) -- BACK EXTERIOR LIGHT | 1 | $40 | $40 | DECIDED 2026-07-21. Puts the EXISTING back-door/patio light under HA so Frigate can trigger it -- this is why camera 4 stays a plain Duo 2 instead of a floodlight camera (see 6.3). SWITCH not dimmer: LED floodlights are usually non-dimmable and dimming is not wanted here. Sinopé = same family as the DM2500ZB dimmers, native in Z2M, no Neviweb/hub, Canadian. Neutral required (boxes have it). BONUS: mains Zigbee ROUTER at the BACK of the house -- extends the mesh toward the backyard/garage where coverage is thinnest. Verify the fixture's wattage against the switch rating. Keep it a WALL switch (not a relay behind the fixture) so manual control still works. Alt: Aqara WS-USC03/04 (neutral versions -- NOT the no-neutral WS-USC01) |
| Garage opener relay: Aqara Dual Relay Module T2 (DCM-K01) | 1 | $40 | $40 | Hub-free via Z2M (`LLKZMK12LM`); dry-contact mode wired across the wall-button terminals. Mains-powered (L+N) -> also a Zigbee router. Dual-channel: covers 2 doors. Ignore the "Aqara hub required" label -- Z2M-supported incl. OTA |
| Garage state: ThirdReality Garage Tilt Sensor (3RDTS01056Z) | 1 | $25 | $25 | Hub-free via Z2M; tilt -> open/closed `contact`. Mount on top door panel; disable buzzer; set sensitivity dip switch. 1 per door |
| Scene buttons (optional) | 2 | $20 | $40 | Matter buttons for scenes |
| | | | **~$1,357** | ~36 devices. LIGHTING = 9 owned KS225 Wi-Fi dimmers ($0, sunk) + 3 Sinopé Zigbee dimmers ($135) + 1 Sinopé SW2500ZB switch for the back exterior light ($40, added 2026-07-21). Zigbee mesh now carried by 6 mandatory router plugs ($90) + 3 Sinopé + garage relay, NOT a 12-dimmer backbone. ZBT-2 optional; thermostat = Aqara W200 (Matter). Down ~$375 from the 12-Sinopé plan (9 dimmers now sunk-cost Wi-Fi) |

### KS225 commissioning + TP-Link cloud exit

STATUS 2026-07-21: 7 of 9 paired and live in HA (Kitchen, Office, Library, Master Bedroom,
Outside Potlights, Family Room, Girls Bedroom). 2 left to do.
TIP: name the device BEFORE/while pairing -- "Girls Lights" produced a clean
`light.girls_bedroom_girls_lights` entity_id, where the earlier six all landed as
`light.smart_wi_fi_dimmer_switch_N` and depend on device names for a readable friendly name.

Working procedure per switch (validated 2026-07):

1. Factory reset the switch: hold ~10 s until the LED blinks rapid amber (a ~5 s hold is only a soft reset -- keeps the fabric and Wi-Fi).
2. Pair it in the **Kasa** app, standing next to it (the phone provides BLE).
3. Kasa -> device settings -> Matter / "link to other platforms" -> generate a pairing code.
4. Paste that code into HA -> Add Matter device. The code is time-limited (~15 min) and single-use.
5. Verify HA can actually toggle the switch before moving on.

Cloud exit (optional, do it LAST and test on ONE switch): removing the device **inside the Kasa app** sends a remove-fabric command that drops TP-Link's admin while leaving HA's fabric intact -- the switch then runs fully local, no cloud, no app. Uninstalling the Kasa app alone does NOT do this; the fabric lives on the device and the TP-Link account, not the app install, so the app must be used to evict it first. Risk to verify on one switch: some vendor apps decommission ALL fabrics on removal rather than just their own, which would evict HA too and force a re-pair.

### Zigbee mesh resilience / why the router count

A Zigbee device is a member of the NETWORK (keyed by IEEE address + network key),
not bound to the router it paired through. So removing/unplugging a router plug does NOT
unpair or reset the battery sensors that were routing through it -- the mesh self-heals:
each orphaned sensor rejoins another nearby router (or the coordinator) automatically,
keeping its address and its Z2M/HA entity. True for both a temporary unplug and a permanent
remove/factory-reset of the plug; either way only the plug leaves, its children re-parent.

Two caveats that drive the design:
1. Re-heal is NOT instant for sleepy end devices -- a battery sensor may take seconds to
   hours to notice its parent is gone. Physically waking it (open the contact, trip motion)
   forces an immediate rejoin.
2. It needs another router in RANGE to rejoin to. If the removed plug was a sensor's only
   path (>1 hop from anything else), that sensor goes offline until an alternate route exists.

VALIDATED IN THE FIELD 2026-07-21: the coordinator was down ~7.5 h (USB power fault). All 4 paired
ThirdReality plugs came back on their own with NO re-pairing and no lost entities -- devices stay
network members through a coordinator outage; only live control is interrupted.

DIAGNOSING A DEAD COORDINATOR (the symptom is a Z2M crash loop, which looks like a software bug):
`docker logs zigbee2mqtt` shows "Error while opening socket" + "Failed to start zigbee-herdsman",
container = `Restarting (1)`. Check the COORDINATOR before touching any config: ping it, test
`/dev/tcp/<ip>/6638`, and curl `http://<ip>/ha_sensors` (SLZB web endpoint). No ICMP + no ARP entry
+ nothing on any port = the device is POWERED OFF, not misconfigured. A DHCP/lease problem usually
still leaves a link-layer presence, so "no ARP at all" points at power, not addressing. Z2M is
`restart: unless-stopped`, so it self-heals the moment the coordinator answers again -- leave it
looping rather than intervening.

Hence: pair ROUTERS FIRST, then sensors; keep no battery sensor >1 hop from a mains router;
and buy overlap (8 ThirdReality plugs for 6 needed spots + 3 Sinopé + garage relay) so any
single plug removal always leaves an alternate path. Use Z2M -> Map to see who parents whom
and confirm re-homing after pulling a plug. Routers so far: mains ThirdReality plugs (Router,
Mains, model 3RSP02028BZ -- confirmed as routers on join), 3 Sinopé dimmers, garage T2 relay.

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

### Thermostat note (Aqara W200 -- BOUGHT + C-wire)

HVAC is furnace + AC (conventional 24V single-stage -- easiest case: R/W/Y/G/C). BOUGHT the
**Aqara Thermostat Hub W200** (availability). It is a HUB, not a Z2M endpoint:
- INTEGRATION = MATTER, not Zigbee2MQTT. Set up in the Aqara app (Wi-Fi + HVAC type -> Matter
  pairing code), then HA > Settings > Devices > Matter > Add. Runs LOCALLY over Matter after setup
  (Aqara account only for onboarding). HA gets core control (mode/setpoint/temp); adaptive/schedule
  features are app-only (typical Matter limitation).
- Use it STANDALONE. Do NOT pair other Zigbee devices to its built-in Zigbee hub -- keep everything
  on the SLZB-06/Z2M (one coordinator). Its built-in THREAD BR means the ZBT-2 is definitively not needed.
- It is NOT a Z2M Zigbee router, so it no longer "seeds" the Zigbee mesh -- fine, the 12 mains
  dimmers are the router backbone.

C-wire: required. Likely absent in this older house.
1. First check for a hidden/unused conductor: pull the thermostat plate + inspect the furnace board
   for a spare (often blue) wire coiled unused at both ends -- if present, land it on C. Free.
2. If walls are open there, pull fresh 18/5 thermostat cable (C + a spare). Preferred permanent fix.
3. Else: use the **Aqara C-Wire Adapter** (~$25, the matched accessory) -- synthesizes C at the furnace.
Zigbee interference: the W200's Zigbee radio is always on -> if Zigbee flakiness appears, set the
SLZB-06/Z2M channel away from the W200's.

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

Decision: 4-bay NAS, start with a 2x14 TB mirror, because (a) continuous recording makes the
always-on footage worth protecting and the SFF can't mirror (one bay), and (b) the NAS earns
its cost across multiple roles, not just recording:

- Continuous Frigate recordings (finished segments; Frigate cache stays on masn's SSD).
  Sizing: 4 cameras, 15-day retention. At ~4-6 Mbps/camera H.265 main stream this is ~2.6-3.9 TB
  (rule of thumb: 1 Mbps continuous ~= 10.8 GB/day). ~4 TB typical. Use H.265 + a sane
  per-camera bitrate to keep it in this range. Footage (~4 TB) + family Photos/Drive (1-3 TB)
  drives the 14 TB mirror choice below (8 TB would be too tight once media is added).
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
- Time Machine / PC backups; general SMB shares. ALL clients use SMB (UGOS default): masn via
  `cifs`, macOS natively (Finder `smb://<nas>`; Time Machine over SMB -- enable the UGOS
  Mac/Time-Machine option on that share), family devices via SMB. No NFS anywhere.

Decision: NO Synology -- avoiding its 2025+ drive lock-in. Pick a no-lock box. Since the NAS
is LAN-only (reached via HA/Tailscale, never port-forwarded), the vendor's cloud-security
surface is largely neutralized, so the choice is driven by no-lock + value + OS quality.

Recommended: UGREEN NASync DXP4800 Pro (4-bay, Intel Core i3-1315U 13th-gen x86, 10GbE +
2.5GbE), starting with 2 x 14 TB NAS-rated drives (Toshiba N300 / WD Red Plus -- CMR,
24/7-rated) as a mirror = 14 TB usable, 2 bays left free for growth. 14 TB (was 12; +2 TB for ~$10)
because the
NAS now also holds 1-3 TB of family Photos/Drive on top of ~4 TB footage. x86 = escape hatch: run
UGOS now, or wipe to TrueNAS SCALE later. The Pro was chosen over the Plus (Pentium 8505) and
the base (N100) because Prime Day pricing made the delta insignificant -- the i3 (6C/8T, 2
P-cores, up to 96 GB RAM) is free 10-year runway. Same chassis/bays/NVMe/10GbE across Plus/Pro;
only CPU + RAM ceiling differ. If the Pro's premium ever exceeds ~$130, the Plus is the value pick.

Expansion path (4-bay, no forklift): start 2x14 mirror -> when data grows, ADD a 2nd 2x14 pair
-> 28 TB usable (stripe of mirrors), no swap, no wasted drives. Alternatively rebuild to a
4-drive RAIDZ1 (42 TB, 1-drive redundancy) or RAIDZ2 (28 TB, 2-drive). NOTE: a mirror cannot
be converted in place to RAIDZ -- the "add a 2nd mirror pair" path avoids any rebuild.

| Item | Qty | Est. each | Est. total | Notes |
|------|-----|-----------|------------|-------|
| UGREEN NASync DXP4800 Pro (4-bay, i3-1315U) | 1 | $650 | $650 | No drive lock-in; x86 (UGOS or TrueNAS); i3 Iris Xe Quick Sync hosts Jellyfin; 10GbE; 2 bays free. Prime Day price; Plus ~$130 less |
| NAS HDD 14 TB Toshiba N300 (HDWG21E, CMR) | 2 | $250 | $500 | CHOSEN after the IronWolf Pro DOA (2026-06-29); 14 TB (was 12) since +2 TB was only ~$10. CMR, 7200 RPM, 300 TB/yr (3yr warranty). PHASING: buy 1 NOW (single-disk, no redundancy -- Google stays the off-site copy); add the 2nd in a few months once stable -> mirror in place (btrfs add-drive -> RAID1 on UGOS; or `zpool attach` on TrueNAS). The 2nd MUST also be 14 TB (mirror = smaller disk). BURN-IN each (SMART long + surface scan) before trusting. For the mirror, use a DIFFERENT batch, or mix brands (N300 + WD Red Plus) to decorrelate batch/brand risk. Mirror = 14 TB usable |
| | | | **~$1,150** | UPS moved to the shared rack -- see 6.9 |

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

REJECTED: UGREENlink (UGREEN cloud remote access, akin to Synology QuickConnect / QNAP
myQNAPcloud). It's a vendor cloud relay that makes the NAS -- our most sensitive box (family
photos, personal files, recordings) -- reachable via a third party; that class of feature drove
the QNAP/Synology ransomware waves. Keep it DISABLED; confirm the NAS is not WAN-exposed (no
port-forward, no UPnP, admin UI LAN-only). Family remote access = install Tailscale on each
person's device + join the tailnet (reaches Immich/Nextcloud/Jellyfin securely, no cloud broker).
- If a subnet route is ever truly needed (a non-Tailscale device): scope it with Tailscale
  ACLs, advertise ONLY the Trusted subnet (never camera/IoT VLANs), prefer a narrow /32 host
  route over the full /24.

Sizing notes (continuous recording):

- Per camera per day ~= bitrate(Mbps) x 10.8 GB. DECIDED config = 4 cams, 15-day retention:
  - Main stream ~4 Mbps (4MP H.265): ~173 GB/day -> ~2.6 TB over 15 days.
  - Main stream ~6 Mbps: ~259 GB/day -> ~3.9 TB over 15 days.
  - ~4 TB typical for footage; family Photos/Drive (1-3 TB) + media ride on top -> 14 TB mirror.
- Use DUAL-STREAM: continuous low-res substream + full-res main only on events. Tiered
  retention: `record.retain` (continuous, e.g. 15d) separate from alerts/detections
  (e.g. 30d). Frigate auto-prunes oldest first; the share never fills.
- 14 TB usable (2x14 mirror) is the recommended start (footage + family data + media); add a
  2nd 2x14 pair later for 28 TB. Mirror usable = one drive's capacity.

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

> **CURRENT REALITY (2026-07): core is in the SECOND-FLOOR OFFICE, not the basement.** Internet enters
> at the office, so the UCG-Fiber + U7 Pro Wall + masn + NAS are all there now (works fine). The
> basement-rack design below is the FUTURE/OPTIONAL target -- it only happens if a fast office<->basement
> link is found (repurpose existing coax for MoCA 2.5G, or pull Cat6). No link found yet (basement coax
> endpoint not located; satellite SW44 drops are dead). If no link materializes, the core STAYS in the
> office. The move is for noise/heat/space only -- not a functional need. MoCA's role flipped: it's now
> a potential office<->basement CORE link, NOT the floor-2-AP backhaul (that AP is wired off the office gateway).


One spot (Utility room AV/network closet) houses masn, the UGREEN NAS, the UniFi USW-Pro-Max-16-PoE
switch + UCG-Fiber gateway, the patch panel, the RELOCATED cable modem, and (later) the fiber ONT --
all on ONE UPS. The 3 U7 Pro APs are NOT in the rack (basement ceiling + floors 1/2 wall; floor 2 fed
via MoCA/coax, the others by in-wall Cat6 from the switch).
Open-frame/vented, NOT a sealed cabinet (everything here runs 24/7 and makes heat).

| Item | Qty | Est. each | Est. total | Notes |
|------|-----|-----------|------------|-------|
| 18U 4-post open-frame rack (~600mm deep) | 1 | $170 | $170 | StarTech/NavePoint/Kendall Howard class. 18U (not 15U) for shelf clearances; 4-post for shelf weight; vented-door cabinet only if actively cooled. Go 20U if running the NAS upright |
| 4-post vented shelf, ~400mm+ deep | 3 | $25 | $75 | For masn (SFF), NAS, and the modem + UCG-Fiber (+ later the fiber ONT). Depth >= 300mm so the SFF (~292mm deep) doesn't overhang. Lay SFF FLAT (~2-3U), vents clear, velcro-strap it down |
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
U7   Shelf C (vented): cable modem + UCG-Fiber gateway (+ fiber ONT later)
U6    modem/gateway/ONT clearance
U5   airflow gap
U4   PDU (1U)                              <- fed from UPS
U3   UPS 1500VA (2U rackmount)
U2    UPS (heavy -> bottom)
U1    spare / floor clearance
```

Shelves needed: 3 x 4-post vented shelves (>=400mm deep) for masn, NAS, and the modem+UCG-Fiber (+ONT later).
Everything else (patch panel, brush, switch, PDU, UPS) mounts directly on the rails.
Space-saver: masn (flat, ~290mm) + NAS (~105mm) fit side-by-side on one wide shelf (saves
~3U -> fits 15U) at the cost of tighter airflow between them.

Power/UPS notes:
- Consolidated continuous draw ~250-290W (masn ~60, NAS ~40, switch ~25, PoE load: 4 cams ~35 +
  2 U7 Pro APs ~44 -- the switch powers only the basement + floor-1 APs; the floor-2 AP draws PoE
  from its MoCA-side injector at floor 2, not the rack; UCG-Fiber + modem ~35). Everything is on
  the ONE rack UPS. 1500VA/~900-1000W still rides outages with meaningful runtime + graceful
  shutdown; router + APs + cameras + internet all stay up on battery.
- PURE (true) sine wave is required, not optional: masn's and the NAS's active-PFC PSUs can
  stutter/shut off on a simulated-sine UPS at the moment of transfer to battery. Pick
  CyberPower CP1500PFCLCD or APC Back-UPS Pro BR1500MS.
- PoE switch + gateway + modem are ALL on the rack UPS (decision): cameras + internet survive a
  power cut -- security priority. This is why 1500VA, not 900VA.
- UPS at the bottom (battery weight). Battery life halves ~every 8-10C above 25C -> keep the
  rack ventilated; replace UPS battery ~every 3-5 yrs.
- Wi-Fi: NO radio in the rack (metal kills signal). The UCG-Fiber is Wi-Fi-less by design; Wi-Fi
  comes from the 3 U7 Pro APs (basement ceiling + floors 1/2 wall) -- basement + floor 1 on in-wall
  Cat6 PoE runs, floor 2 over MoCA/coax + its own injector.

### 6.10 Electrical panel upgrade (100A -> 200A) + energy monitoring -- FUTURE

Electrician booked for AUGUST 2026 to upgrade 100A -> 200A. Drivers CONFIRMED: EV charger +
hot tub + basement finish -- 200A is clearly justified (no load-calc doubt). NOT rolled into
the BoM grand total below (separate home-improvement job). User will schedule the smart bits
"in the future"; this section is the CHECKLIST to hand the electrician so the cheap panel-open
window is not wasted.

SMART BREAKERS -- DECISION: SKIP THEM. Not on cost, on two structural mismatches:
- Lifecycle: a panel lasts 30-40 yrs; IoT firmware/cloud lasts 5-10. Smart breakers put a
  phone-app-lifecycle product inside generational infrastructure. When My Leviton is sunset you
  have expensive dumb breakers only an electrician can swap.
- Architecture: Leviton smart breakers run through the My Leviton CLOUD -- the single
  cloud-dependent component in an otherwise deliberately-local house (Frigate not Protect, Z2M
  not vendor hubs, local Matter). Also: Leviton smart breakers REQUIRE a Leviton load center,
  which is the one IRREVERSIBLE choice (wrong panel brand now = another panel swap later).
Per driver, put the smarts where they belong instead: EV -> at the EVSE (smart charger:
scheduling + amperage + load management, not a dumb on/off breaker); HOT TUB -> monitor, do NOT
put on a remotely-switchable breaker (an Ontario-winter remote "off" can freeze plumbing +
crack the heater; code already needs a GFCI disconnect in sight of the tub); BASEMENT -> smarts
at switch/outlet level (KS225 / Sinope), same as the rest of the house.
RECONSIDER smart breakers / a Span-class panel ONLY if solar or battery storage enters the
5-yr plan (real orchestration + backup-circuit prioritization -- CT monitoring cannot do that).
Nothing in the plan calls for solar today.

DO WHILE THE PANEL IS OPEN (incremental cost is tiny once the electrician is already in there):
- **Type 2 whole-panel SPD** (surge protective device), ~$200-400 installed, rated >=40 kA/phase.
  Mounts on the LOAD side of the main breaker; clamps surges before they fan out to all ~40
  branch circuits -- both external (grid/lightning-adjacent) AND internal (EV charger + hot-tub
  heater + AC compressor kick big transients back onto your own wiring every time they cut out).
  Protects the electronics-dense house (masn/NAS/PoE switch/cameras/~40 devices). NOT a UPS
  substitute: SPD = microsecond spikes; UPS = outages/sags. Layer both; keep Type 3 strips on the
  rack too. Square D/Eaton/Siemens sell a plug-in breaker-style Type 2 that snaps into 2 slots.
- **CT ENERGY MONITORING** -- the cost-effective "smart" (visibility, not switching). Install the
  CTs during the panel job (they clamp around conductors INSIDE the panel -> panel must be open +
  dead -> licensed-electrician work; doing it later = paying to pull the cover a 2nd time).
  DEVICE: Emporia Vue 3 (~$200 CAD, Amazon.ca, 16 branch + 2 mains). SEQUENCING TRICK: land the
  CTs + voltage-reference wiring in August and run it on Emporia's CLOUD at first (works OOTB,
  confirms every CT is on the right circuit), THEN flash ESPHome later at leisure for fully-local
  HA (decouples the panel-timed install from the fiddly Vue-3 pad-probe flash; a botched flash
  never leaves you with no monitoring). No-flash alt: Shelly Pro 3EM (DIN-rail, HA-native local
  OOTB, but only 3 channels = whole-home + 1 big load, not per-circuit). IotaWatt is the purest
  open/local option BUT CircuitIQ V6.4 ships US/AU only -- not Canada (freight-forwarder hassle).
  CT PLACEMENT: 2x 200A CTs on the incoming hot legs (mains); 50A CTs on each branch circuit of
  interest. 240V LOADS (EV + hot tub + dryer) -> clamp BOTH legs and sum (assign 2 CT inputs to
  one logical circuit); a single CT on one leg only sees half. Tell the electrician up front which
  circuits are 240V so they leave room for a CT on each leg -- these are the biggest loads and the
  ones you MOST want measured right. Voltage reference: Emporia takes it from a 3-wire pigtail
  (2 hots + neutral) on a spare 2-pole breaker. Into HA: ESPHome device auto-appears (~1s);
  point the HA Energy dashboard at mains (grid) + branches (devices); enter Ontario TOU/ULO rates
  for real $ per load (EV + hot tub are the two biggest -- this is where the bill goes).
- **RESERVE panel slots + gutter space**: SPD (2 slots), Emporia voltage-reference breaker
  (2-pole), and room for the monitor + CTs. Also worth roughing in: a DEDICATED circuit for the
  rack/masn (clean power for server + UPS), and SPARE circuits/conduit for EV, spa, garage,
  basement -- adding a circuit during a panel swap is far cheaper than a later call-out.

ONTARIO PROCESS (non-negotiable): Licensed Electrical Contractor only (verify licence w/ ESA);
mandatory ESA notification/permit -> Certificate of Inspection (matters for resale + insurer);
Elexicon Energy coordinates disconnect/reconnect; ~4-8h install, 2-4 wks end-to-end; new panel =
new breakers meeting current CEC (AFCI/GFCI -> pricier than the old ones -- budget for it).
PRE-QUOTE CHECK that can swing the price by thousands: 2001 Ajax subdivision builds sometimes ran
a 200A-capable underground lateral + meter base with only a 100A panel fitted -- if so this is a
cheap panel SWAP, not a full service upgrade. Have the electrician read the METER BASE RATING +
service-entrance conductor size before quoting. Underground service upgrade GTA 2026 ~$4,200-6,500;
overhead ~$3,200-4,800; cheap-swap case is well under that.

### 6.11 Frigate readiness (detection load, AI tiering, storage) -- reviewed 2026-07

Sanity-check of the masn Frigate design against the FINAL 4-camera set (TrackMix PoE, 2x CX810,
Duo 2 PoE) + doorbell. Verdict: GOOD ENOUGH on masn's HD 630 alone, no P620, IF detection is
scoped to choke points (below). The design (dual-stream, stream-copy record, go2rtc, iGPU
decode) is sound; the only real question was detection inference load, and scoping settles it.

STREAM COUNT -- it is NOT "4 cameras": dual-lens units are multiple streams to Frigate.
  TrackMix = wide + tele (2); CX810 x2 (2); Duo 2 panorama (1); doorbell (1) => ~6 potential
  detection inputs, not 4. Object detection scales with DETECT streams, not physical cameras.

DECISION -- object detection on 4 CHOKE-POINT streams; the rest record + motion-only:
  - DETECT: TrackMix WIDE (driveway), CX810 #52-gate, CX810 #48-gate, doorbell.
  - RECORD + MOTION ONLY (no object detection): Duo 2 backyard (anyone there already tripped a
    CX810 at a gate) and the TrackMix TELE (it is just the auto-tracked close-up of the wide).
  => 4 detection streams on the HD 630, which is comfortable. Frigate detection is MOTION-GATED
  (inference only fires on moving regions), and these are quiet scenes except the driveway.
  The one real stressor is the TrackMix on the street -> MOTION-MASK the street, and mask BOTH
  neighbours (#48/#52) on every camera: cuts inference load AND false notifications at once.

NO P620 (declined, see 3.3) -> the HD 630 must suffice; the 4-stream scoping is what makes that
safe rather than a gamble. MEASURE after go-live: Frigate `inference speed` (>~25ms = saturating),
per-camera detection fps dropping below configured, and detector skipped frames. RELIEF VALVE if
it saturates = remote-detector offload to the AGX Orin (DeGirum / ONNX-over-LAN; on AGX, pin to a
DLA so it does not touch the GPU cores doing LLM). Viable because the Orin is on-hand -- but needs
flashing first and couples security to the Orin, so tune/scope BEFORE reaching for it.

DECODE + RECORD load: fine. Frigate records the 4K H.265 mainstream by STREAM-COPY (no decode,
no re-encode); the iGPU only decodes the low-res DETECT substreams -> light. go2rtc fronts every
Reolink RTSP (one connection -> detect + record + live; tames Reolink's finicky RTSP).

STORAGE sizing (set retention deliberately -- shared NAS pool): ~6 mainstreams 4K H.265 continuous
~= 30 Mbps ~= 320 GB/day ~= 2.2 TB/week. On the 2x14 TB mirror that is ~6 wks IF cameras owned the
pool, but they share it with Jellyfin + backups. So: CONTINUOUS for a few days + longer retention
on DETECTION EVENTS only. Frigate `cache` dir stays on masn's local NVMe; only finished segments
go to the NAS (see 3.2 Frigate-over-network rule).

CAMERA-SPECIFIC TUNING: Duo 2 panorama -> objects are small on a 180 deg frame, so if it is ever
promoted to detection, raise the detect substream resolution and use ZONES, not full-frame.
TrackMix -> camera-NATIVE auto-track, NOT Frigate `onvif_autotrack` (Reolink ONVIF flaky).

AI TIERING for the SMART layer (cross-ref 12; assets reconciled 2026-07):
  - Object detection (trip-wire, MUST-NEVER-BE-DOWN): masn HD 630. NOT the 5070 (opportunistic)
    and NOT the Orin-first -- security detection has to be 24/7 on the always-on box.
  - Event VLM understanding (Frigate GenAI: "a delivery driver in brown holding a package" +
    semantic search): RTX 5070 box WHEN UP (preferred -- on-hand, Blackwell ~12 GB, fast) ->
    fallback AGX Orin (always-on) -> cloud. Health-check fallback, same OpenAI-compatible API.
  - Batch vision (semantic-search embeddings, face recognition, LPR): RTX 5070 box.
  ASSETS ON HAND (2026-07): AGX Orin -- OWNED, NOT YET FLASHED (needs JetPack/L4T). RTX 5070 Linux
  PC -- OWNED, opportunistic (not always-on; if ever run 24/7 it could host detection+VLM, but
  that is power/noise/overkill -- keep it opportunistic). Quadro P620 -- declined.
  WHY the 5070 is not the detector: it is opportunistic/not always-on; the trip-wire cannot depend
  on a box that is sometimes off. It IS the preferred GenAI/VLM + batch-vision endpoint when up.

SEQUENCING: masn Frigate does NOT depend on the Orin or the 5070. Stand up basic Frigate
(detection + record) on masn first; add the GenAI/VLM layer once the Orin (or 5070) is flashed.

### BoM grand total

Approx. **$5,869** spread across phases (RAM done; NEW 1TB NVMe (~$80) -- the old SATA SSD is
worn out (Media_Wearout=001), retire it; Coral
dropped -- detection on the HD 630 iGPU; UGREEN 4-bay NAS (Pro) with Jellyfin + family
Photos/Drive backup on it; ALL-UniFi network -- UCG-Fiber gateway (basement) + 16-PoE switch + 3x U7 Pro
APs (one per level; floor-2 over MoCA), BT10 sold; consolidated rack + 1500VA pure-sine UPS). Largest line items: smart home devices (~$1,692, incl. 12 Sinopé Zigbee dimmers + lock +
thermostat + dual radios + hub-free Zigbee garage), network (~$1,320 net after BT10 resale, all-UniFi w/ UCG-Fiber for full 3G + floor-2 MoCA kit), NAS (~$1,150, DXP4800 Pro
4-bay starting 2x14 TB), rack + power (~$590), cameras (~$720 -- 2 PoE + garage Duo + porch cam + Wi-Fi doorbell + NuTone plate + TrackMix WiFi PTZ), and audio (~$115 -- NuTone reused
+ WiiM + AUX adapter; Snapcast/amp/speaker-runs dropped). Reuse of Pi 4,
monitors, the existing 1TB SSD, the iGPU for detection, and the Orin avoids ~$720+; selling the
BT10 offsets ~$400 of the UniFi switch-over. Bulk storage + Jellyfin on the UGREEN NAS (mirror, 2
bays free to grow); continuous recording via dual-stream; everything on one UPS (PoE/cameras/APs included).

Recurring cost: Nabu Casa (HA Cloud) **$6.50/mo** -- per instance, covers all cameras and
all household users. Optional (Tailscale is the $0 alternative).

### 6.11.1 Frigate AS-BUILT -- basic bring-up (2026-07-28)

Frigate 0.17.2 ENABLED in /opt/stack/docker-compose.yml (was scaffolded/commented). Scope = a
working vertical slice: 2 cameras with PERSON detection, everything else deferred.

- CAMERAS (5 as of 2026-07-29): driveway (TrackMix .86 wide), front_door (doorbell .151),
  west_gate (.22), east_gate (.130), backyard (Duo 2 .217). All PERSON detection on the low-res
  h264 SUB stream (cheap iGPU decode: 896x512 / 640x480 / 640x360 / 640x360 / 1536x576); record the
  MAIN stream by stream-copy. go2rtc fronts each (one RTSP connection re-shared). Load check with 5
  cams: detector ~9 ms, skipped_fps=0 on all -> HD 630 NOT saturated, headroom remains.
  RECORDING: ALL 5 now 24/7 CONTINUOUS 15d (2026-07-29 -- the 3 event-based cams were promoted by
  removing their `record.continuous.days: 0` overrides, on user request to monitor storage). Baseline
  at switch: 55 GB / 8 TB. Est. ~300+ GB/day for 5 cams -> ~4.7 TB for 15d (fits 8 TB; Frigate
  auto-prunes oldest to keep ~10% free). Watching a few days before finalizing retention; revert any
  cam to event-based by re-adding `record: {continuous: {days: 0}}`.
  CODEC/SCRUB NOTE: every Reolink 4K/high-res MAIN is HEVC (h265) -- only front_door (doorbell) is
  h264. Reolink 4K firmware is h265-ONLY at full res (verified via GetEnc: mainStream vType=[h265],
  no h264 option; h264 only on the tiny sub). Chrome/Firefox can't seek h265 without an OS HEVC
  decoder (Win: MS Store "HEVC Video Extensions"; Mac: built-in, Safari always works; Linux: none ->
  would need a server-side transcode). So h265 recordings scrub fine on Mac/Safari but not bare
  Chrome-on-Linux. Not fixable camera-side at 4K.
- DETECTOR: OpenVINO on the HD 630 iGPU (`device: GPU`), bundled ssdlite_mobilenet_v2 model.
  ~10 ms/inference measured. `objects.track: [person]` only.
- MQTT: `host: mosquitto` (Frigate is BRIDGED -> service name, NOT 127.0.0.1 which is host-only).
  Creds via `{FRIGATE_MQTT_USER/PASSWORD}` env from .env. Confirmed publishing frigate/# topics.
- STORAGE: recording to the NAS SMB share (done 2026-07-29). `//192.168.50.49/frigate` mounted at
  /mnt/nas/frigate via `tools/mount-nas-frigate.sh` (cifs, root-only creds file at
  /etc/cifs-credentials/frigate, fstab `_netdev,nofail,vers=3.1.1,uid=0,gid=0`), bound into the
  container as /media/frigate. 8 TB free. Retention now **24/7 CONTINUOUS 15 days** + alerts/
  detections 30 days (~130 GB/day for these 2 cameras -> ~2 TB/15d). Local test footage cleared,
  reclaimed ~35 GB on the root vg. CAVEAT: this is a host bind-mount of a network share -- if the
  NAS is DOWN at boot, Docker could start Frigate against an empty local /mnt/nas/frigate and write
  to root-disk. Harden later with a docker cifs named-volume (Docker owns the mount, won't start the
  container without it) or fstab `x-systemd.automount`. Normal boot (NAS up) re-mounts fine.
- FRIGATE 0.17 GOTCHAS (cost two restarts): (1) OpenVINO needs an EXPLICIT `model:` block with
  path /openvino-model/ssdlite_mobilenet_v2.xml -- omitting it crashes the detector with
  `stat: path ... NoneType`. (2) `detect.enabled` now defaults to FALSE -- must be set true per
  camera or the detector idles (det_fps 0).
- render GID confirmed 993 (`getent group render`); /dev/dri/renderD128 passed through; iHD driver.
- SECURITY: Frigate's first-run generated admin password was exposed in a log grep and ROTATED
  (user table in /config/frigate.db cleared -> regenerated). Password reset again 2026-07-29 and is
  now USER-SET (not a generated value). UI on :8971 (LAN only, no port-forward). TLS DISABLED
  2026-07-29 (`tls.enabled: false`) -> plain HTTP on :8971, to drop the self-signed-cert
  "Not Secure"/strikethrough warning. Acceptable on the trusted, VLAN-isolated LAN (Frigate login
  is then cleartext, but LAN-only). For a real padlock, front Frigate with a reverse proxy + cert.

RICH HA ENTITIES -- DONE (2026-07-28): frigate-hass-integration v5.15.4 installed DIRECTLY (not via
HACS -- avoids the GitHub-OAuth device flow) into config/custom_components/frigate, HA restarted,
config entry added pointing at http://127.0.0.1:5000. Gave HA 65 entities: proxy camera.driveway /
camera.front_door (clips/recordings in the HA media browser), person/motion/all occupancy binary
sensors, last-person image, object-count + fps + cpu sensors, detect/recordings/snapshots/motion
switches, detector inference-speed. To reach the unauthenticated Frigate API from host-mode HA
without exposing it, port 5000 is published 127.0.0.1-ONLY (8971 stays the LAN-facing authed UI).
NOTE: config/custom_components is masn-only (config/ is gitignored like .env) -- reinstall from the
v5.15.4 zipball if rebuilding; not reproducible from the repo. HACS is an optional future add (for
update management + the frigate-hass-card Lovelace card).

DASHBOARD CARD -- DONE (2026-07-29): advanced-camera-card v7.27.4 (the renamed frigate-hass-card)
installed DIRECTLY (not HACS). The 52-file chunked bundle lives in config/www/advanced-camera-card/
(masn-only -- www is under gitignored config/), registered as a Lovelace module resource
(/local/advanced-camera-card/advanced-camera-card.js). westacott.json (in repo) gained a 2nd view
"Cameras" (panel) with a custom:advanced-camera-card for all 5 Frigate proxy cameras ->
live + Ring-style timeline scrub + clips, using the family's existing HA login (no separate Frigate
UI). SMOOTH SCRUB (2026-07-29): Frigate auto-generates low-res h264 PREVIEWS (record.preview.quality
raised medium->high) that power fast timeline scrubbing even for the H.265 cameras -- this is the
Ring smooth-scrub equivalent (drag = previews; play = full recording). Card shows an always-on
ribbon mini-timeline under live (`live.controls.timeline: {mode: below, style: ribbon}`). Rebuild note: re-download the bundle + re-register the resource (config/ is not in the repo);
a HARD browser refresh is required after first install or the tab shows "custom element doesn't exist".

REVIEW TAB (2026-07-30): the card's scrubbing/clip-opening is sluggish because it fetches all media
THROUGH HA's proxy (hass-web-proxy-lib); native Frigate is far faster (direct). Added a 3rd view
"Review" = an `iframe` card embedding the native Frigate UI (http://192.168.50.50:8971 -- Frigate sets
no X-Frame-Options, so it embeds) -> native speed inside HA, no proxy hop. Cameras tab stays for
low-latency LIVE; Review tab for fast scrubbing. CAVEATS: first load shows Frigate login (cookie then
persists); works only via the internal HTTP URL on the LAN (https/Nabu-Casa remote = mixed-content +
LAN-IP unreachable). To drop the login prompt, could set Frigate `auth.enabled: false` (LAN-only).

ZONES + ZONE-GATED NOTIFICATIONS (2026-07-30): the user (correctly, the canonical way) replaced the
motion masks with a property ZONE per camera (driveway=front_area, front_door=front_zone,
west_gate=west_side_, east_gate=east_side, backyard=backyard_zone) + `review.alerts.required_zones`.
Those were drawn in the Frigate UI (live config only) -- PULLED back into repo config.yml (they were
at risk from repo deploys; this is the recurring UI-vs-repo sync gotcha -- always pull masn first).
KEY FIX: the person notification was firing for out-of-zone people because it triggered on RAW
`frigate/events`, which ignore zones -- `required_zones` only affects Frigate's *alert severity*, not
raw events. AND Frigate's alert severity turned out UNreliable (some alerts fired with zones=[]), so
the automation now gates directly on `entered_zones`: fire only when a person's event transitions from
no-zones to in-a-zone (before empty -> after non-empty). Verified both ways (in-zone fires, out-of-zone
silent). CONSEQUENCE: with zones + this gate, the per-camera OBJECT MASKS are redundant for alerting
(decoys outside zones never notify anyway); they were kept only to keep known decoys out of the event
list -- removable. Object-mask history below for reference.

OBJECT MASK (2026-07-30): west_gate got repeated NIGHT "person" hits at 0.7-0.85 -- diagnosed by
pulling event snapshots: 2 of 3 were the NEIGHBOUR'S GAS METER (fixed decoy, same top-centre spot,
misclassified in grainy ColorX night video), the 3rd a real person on our side (a keeper). Fix =
`objects.filters.person.mask` (NOT motion mask / not threshold -- scores were high, detections real
where they were): west_gate person mask 0.42,0.02,0.68,0.02,0.68,0.30,0.42,0.30. Works because the
filter tests the box's FEET: meter's feet ~y0.22 (inside mask) vs a standing person's feet ~y0.40
(below it) -> meter suppressed, real side-yard people still alert. The object filter mask is the tool
for ANY stationary false positive (statue, reflection, meter). front_door hit the SAME class of bug
(2026-07-30): a fixed object ACROSS THE STREET (right side) that the MORNING SUN (~8am) lit up -> ~20
false person hits (0.7-0.85) in ~18 min, same spot each time. Fix: front_door person mask
0.70,0.24,0.97,0.24,0.97,0.58,0.70,0.58 (across-street area, off the walkway -> real visitors safe).
So the trigger can be NIGHT NOISE (west_gate) or LOW-SUN GLARE (front_door), but the fix is the same
object filter mask. Watch east_gate/backyard for the same.

MASKS + NOTIFICATIONS -- DONE (2026-07-29): motion masks on all 5 cameras (driveway street band,
front_door road+houses, west/east gate neighbour+hedge, backyard above-fence foliage) -- drawn in the
Frigate UI mask editor by the user, coords pulled back into this repo's config.yml. Push notifications
live (packages/person_notifications.yaml): (1) `automation.frigate_person_detected` is EVENT-DRIVEN
(trigger = MQTT frigate/events, type=new, label=person -- NOT the occupancy sensor; the events topic is
what carries the event id) -> image = the detection snapshot, TAP opens THAT event's clip
(clickAction /api/frigate/notifications/<id>/<cam>/clip.mp4; snapshot + clip endpoints verified 200) ->
to naseer (`mna`) only during tuning. (2) `automation.doorbell_pressed` = Reolink visitor sensor ->
whole household (mna + Sara + son's pixel_8_pro), tap = live Cameras view (see who's there now).
RECIPIENT GOTCHA (fixed 2026-07-30): notifications first went to pixel_8_pro = the SON's phone; naseer's
phone is `mna`. MOBILE PUSH != sensor connection: FCM push can fail while the app's sensor link works.
NOTE: the Frigate UI config-save PRESERVES comments but normalizes quotes/braces and appends `version:`,
and can shuffle a comment's position -- after any UI mask edit, pull masn's config.yml back into the repo.

TELE LENS -- DONE (2026-07-29): TrackMix TELE (ch02, h264Preview_02, 1080p h264 -- NOT hevc, so it
scrubs fine) added as `driveway_tele` -- 6th stream. RECORD-ONLY + EVENT-BASED: `detect.enabled: false`
(no object detection -- moving auto-track frame would break detection/masks + waste inference; verified
det_fps=0, zero extra iGPU load), `record.continuous.days: 0` + `motion.days: 14` so it captures the
auto-tracked close-ups only when the lens swings (motion-gated). Object detection stays on the WIDE
lens (ch01/driveway). TRACKMIX TRACKING CONFIG: user disabled DIGITAL tracking (was digitally
pan/zooming the wide ch01 stream Frigate records -> caused a moving recording) but kept PAN/TILT
tracking (physically moves the tele ch02) -- so wide = fixed detection stream, tele = moving close-up
capture. (User to confirm the wide stays fixed on the next driveway subject.)

TODO next (not done): (a) doorbell person-detect -> backyard/porch light + WiiM chime automations;
(b) extend person alerts to Sara/mna phones once tuning settles; (c) hardening: move the NAS mount to a
docker cifs named-volume or x-systemd.automount (see STORAGE caveat); optionally grant PERFMON cap to
restore the Intel GPU-utilization stat (cosmetic); (d) optional: add driveway_tele to the dashboard card.

---

## 7. Cable-Pull List (during drywall)

Pull more than you think you need. Cat6 to:

- Each exterior camera location (4) -> PoE switch
- Doorbell location (1) -> PoE switch
- Each U7 Pro AP location (2: basement ceiling + main-floor wall) -> Cat6 PoE drop (wired backhaul).
  Floor 2's AP has NO Cat6 path -- it's backhauled over COAX/MoCA instead (see 5). Also relocate the
  cable modem down to the basement demarc so the gateway + modem live in the rack.
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
    +-- frigate           (OpenVINO on /dev/dri iGPU; active cache local, continuous recordings -> NAS via SMB)
    +-- mosquitto         (MQTT broker; shared by Z2M + HA)
    +-- zigbee2mqtt       (connects to the SLZB-06 over TCP; bridges Zigbee -> MQTT -> HA)
    +-- postgres          (HA recorder DB)
    (snapserver DROPPED -- audio is the NuTone IM-3303 fed by a standalone WiiM at the AUX, see 6.5)
|
+-- ZBT-2 (USB on masn) -> Thread Border Router (OTBR/HA)
+-- SLZB-06 (network, central floor 1) -> Zigbee coordinator (Z2M over TCP)

(Network management UI runs on the UniFi UCG-Fiber, not masn -- no controller container.)

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
  "Matter over Thread" needs a Thread Border Router (a ZBT-2) -- NOT part of the initial build.
- INITIAL BUILD = ONE radio: the SLZB-06 Zigbee coordinator. Everything planned is Zigbee (lighting,
  sensors, garage, thermostat), so no Thread BR is required now.
- ZBT-2 "supports both" = Zigbee OR Thread, NOT both at once (HA found MultiPAN unreliable and
  won't implement it -- dedicated device per protocol). Since the build is Zigbee-only, keep the
  purpose-built network-attached SLZB-06 and skip the ZBT-2 until a Thread-only device appears.
- Mains-powered Matter-over-Thread devices WOULD act as Thread routers -- but the owned TP-Link
  switches are Matter-over-WI-FI (not Thread), so they never densified Thread. Lighting moved to
  Zigbee (Sinopé dimmers), so the Thread mesh is now empty/optional; no BR needed for the initial build.
- Matter devices are multi-admin: can appear in BOTH Home Assistant and the Google Home
  app simultaneously.
- Cameras do NOT run on Thread (bandwidth). Matter 1.4 added a camera spec but adoption
  is near-zero in 2026 -> cameras stay PoE/Wi-Fi.

Zigbee vs Thread (battery + coexistence):
- Same radio (802.15.4, 2.4 GHz). Battery difference = protocol overhead: Thread is IPv6
  (6LoWPAN) + Matter adds another layer -> more bytes/wake -> more drain. Zigbee is leaner +
  15 yrs of optimization, so battery sensors last longer on Zigbee today (gap shrinking).
- FINAL strategy (see "Protocol assignment" below): ZIGBEE-PRIMARY -- lighting (12 mains dimmers) +
  all battery sensors + garage, all on the SLZB-06/Z2M. The "9 Thread switches" were actually Wi-Fi
  (KS205 -> returned). Thermostat (Aqara W200) is on MATTER. The Thread mesh is empty/optional (the
  W200's built-in BR covers any future Thread device).
- Run BOTH via TWO dedicated radios (SLZB-06 for Zigbee + ZBT-2 for Thread BR), not one
  multiprotocol chip -> avoids single-radio time-share contention; lets each use its own channel.
- 2.4 GHz channel planning is the real reliability factor: bias Wi-Fi to 5/6 GHz on the U7 Pro
  APs (and pin 2.4 GHz to ch 1/6/11), then separate Zigbee (e.g. ch 15) and Thread (e.g. ch 25),
  both away from Wi-Fi 2.4 GHz channels. Get this right = solid meshes; ignore it = "device
  dropped" flakiness.

Coordinator install (SLZB-06, network-attached -- NOT a USB dongle in the rack):
- The SLZB-06 is the ONE coordinator (ZBT-2 returned; Zigbee-only build). It connects by ETHERNET
  and Z2M reaches it over TCP -- so it lives CENTRAL on floor 1, in open air, nowhere near the rack
  or USB 3.0 noise. That placement (not a basement USB dongle) is the whole point of choosing it.
- Z2M config points at the SLZB-06's IP:port (TCP), not a `/dev/serial/by-id` USB path.
- If a Thread device is ever added later, add a ZBT-2 THEN as a dedicated Thread BR (USB on masn,
  on a 1-2 m extension out of the rack) -- not needed for the initial build.
- Coordinator placement is somewhat forgiving since mains Thread/Zigbee devices extend the
  mesh -- but out-of-the-rack, open-air placement still helps initial coverage.

Coordinator placement (basement rack) + scaling -- IMPORTANT:
- The rack is in the BASEMENT. A single radio there will NOT blanket basement + 2 floors + garage:
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

Protocol assignment (which mesh carries what) -- REVISED (2026-07): ZIGBEE-PRIMARY.
- CORRECTION that drove this: the 9 owned TP-Link switches are Matter-over-WI-FI (Kasa KS205), NOT
  Thread -- so they never routed the Thread mesh, and 9 (soon 21) Wi-Fi switches would congest 2.4 GHz
  Wi-Fi (bad, alongside the Wi-Fi cameras). Returned them; lighting goes Zigbee.
- ZIGBEE = everything now: 12 Sinopé DM2500ZB mains dimmers (LIGHTING + the router BACKBONE) + all
  battery sensors + the garage (Aqara T2) + any router plugs (the Aqara W200 thermostat is on MATTER,
  not this Zigbee mesh -- see 6.4). Deeper/
  cheaper 2026 catalog, fully local via Z2M, and it OFFLOADS lighting from Wi-Fi.
- Router seeding is now SOLVED by the 12 mains Sinopé dimmers spread through the house (mains
  Zigbee routers) -- the earlier "router-poor basement coordinator" worry is gone. The ~4 extra
  Zigbee plugs are now optional top-ups, not essential.
- THREAD = empty for now. The ZBT-2 BR is optional future-proofing (a Thread-only Matter device, or
  the lock's Thread module). Add it only when such a device appears; not needed for the initial build.
- Dimming requirement (all 12 spots) is why lighting is Zigbee, not Thread: the only real Matter-
  over-Thread wall switch (Eve) is ON/OFF ONLY. The Sinopé DM2500ZB (Zigbee) dims + does 3-way.

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
- CORRECTION (2026-07): Path A is NOT available here. Google Home refuses to commission any
  Matter device without a Nest/Google hub, and none is owned. Everything reaches Google via
  Path B (Nabu Casa) instead. Do not buy a Nest hub just for this -- Path B already covers it.

#### RULE: exactly ONE publisher to Google Home

Google Home must receive each device from a single source, and that source is **Nabu Casa**.
Anything else double-publishes and Google shows the same physical device twice.

Diagnosed 2026-07: the Google Home app showed duplicate Library Lights, Master Bedroom
Lights and Outside Potlights, while Kitchen and Office appeared once. Cause: the Google
account was ALSO linked to **TP-Link Kasa**, so Kasa's cloud published the same switches in
parallel with HA. The duplicated ones were exactly those commissioned through the Kasa app;
Kitchen and Office (commissioned directly) were clean. Tell-tale sign: the same device
appearing once as a bulb (HA `light`, dimmable) and once as a switch (Kasa on/off trait),
and the Kasa-side name differing slightly ("Family Room Switch" vs "Family Room Lights").

FIX: Google Home app -> Settings -> Works with Google / Linked services -> TP-Link Kasa ->
Unlink. This is only a cloud-to-cloud account link: it does NOT touch the Matter fabric on
the switches and does NOT affect HA. It is unrelated to removing a device inside the Kasa
app (which is what evicts TP-Link's admin fabric -- see the KS225 cloud-exit note in 6.4).

Keep this rule in mind for future vendor apps (Aqara, Reolink, etc.): pair to HA, and do NOT
also link that vendor's account to Google Home.

#### Exposure policy: turn OFF "expose new entities"

HA Cloud defaults to `expose_new: true` with `google_default_expose` covering climate,
cover, fan, humidifier, light, lock, scene, script, sensor, switch, vacuum, water_heater.
Harmless at 6 lights, but this build lands ~35 devices -- contact/leak/tilt/temp sensors
that are useless as Google voice targets and would bury the real controls.

Do this BEFORE the Zigbee sensor rollout (far easier than un-exposing 35 entities after):
Settings -> Voice assistants -> Google Assistant -> turn OFF "Expose new entities", then
expose deliberately: lights, locks, thermostat, garage, key scenes.

#### TRAP: exposure is frozen per-entity, and `expose_new` does NOT fix existing entities

The single most important thing to know about HA -> Google exposure:

`async_should_expose()` (homeassistant/exposed_entities.py) checks
`registry_entry.options["cloud.google_assistant"]["should_expose"]` FIRST and returns
immediately if it is set. The default rules (`_is_default_exposed`: skip anything with an
`entity_category`, then a domain allowlist) run **only the first time an entity is ever
seen**, and the result is then FROZEN into `core.entity_registry`.

Consequences:
- Turning off `expose_new` affects only entities created AFTER the change. It does nothing
  to entities already carrying a stored `should_expose: true`.
- The `entity_category` rule is NOT a permanent guard. Config/diagnostic entities that got
  exposed once stay exposed forever until explicitly un-exposed.
- Do NOT diagnose exposure by reading `.storage/homeassistant.exposed_entities` -- that is
  the LEGACY store and is nearly empty on a modern install (here: 8 stale media_player
  entries, one of which said `should_expose: false` for a TV that WAS in fact exposed).
  The live decisions are in `.storage/core.entity_registry` under
  `options["cloud.google_assistant"]`. Reading the wrong file gives a confidently wrong answer.

Found 2026-07: 51 entities were being published to Google -- 26 `number`, 5 `update`,
4 `button`, 2 `select` (all `entity_category: config`/`diagnostic`) alongside the 6 real
lights. That is where the "Kitchen Lights Power-on behavior" cards came from; the card title
is just the wrapped friendly name of `select.*_power_on_behavior`, whose entity name is unset
so it inherits the device name.

Trimmed to 8: the 6 lights, `climate.thermostat_hub_w200`, `todo.shopping_list`.
Script: `masn-stack/tools/trim-google-exposure.py` (run with HA stopped; backs up first).
After any change, force a re-sync ("Hey Google, sync my devices") -- Google caches the old
device list and orphaned cards persist until it re-fetches.

#### Matter dimmer entities: what each KS225 actually creates

HA's Matter integration creates ~10 entities per KS225; only ONE is user-facing.

| Entity | Category | Purpose |
|--------|----------|---------|
| `light.*` | (none) | The actual control. The only one exposed to Google |
| `select.*_power_on_behavior` | config | Matter `StartUpOnOff`: state after mains power returns (On / Off / Previous) |
| `number.*_power_on_level` | config | Brightness it returns to on power restore |
| `number.*_on_level` | config | Default brightness when turned on |
| `number.*_on_transition_time` / `*_off_transition_time` | config | Fade in/out timing |
| `update.*_firmware` | config | Matter OTA firmware updates |
| `sensor.*_reboot_count` / `*_uptime` / `*_boot_reason` | diagnostic | Auto-disabled by default |

ACTION: set `power_on_behavior` deliberately on every dimmer. Ajax storms/outages are
common; a dimmer left on "On" blazes the whole house awake at 3am at whatever
`power_on_level` says. "Previous" is the sane default. Outside Potlights is the plausible
exception (returning to On after an outage may be wanted for security lighting).

---

## 14. Implementation Phases

- [x] Phase 0a (prereq): RAM to 32 GB -- DONE (verified healthy).
- [ ] Phase 0b (prereq): stand up the NAS FIRST (it is the backup target). Assemble the 18U
      rack (3 vented shelves, PDU, patch panel, 1500VA UPS at bottom); rack masn, UGREEN NAS,
      the USW-Pro-Max-16-PoE switch + UCG-Fiber gateway + relocated modem; all on the one basement UPS. Configure NAS
      2x14 TB mirror (4-bay, 2 bays free); export SMB shares (backups, recordings, media).
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
      is on the UCG-Fiber); migrate Jellyfin
      onto the NAS (`/dev/dri` Quick Sync); point Frigate recordings at the NAS, cache local.
      Set HA `restart: unless-stopped`. See the Phase 0 Runbook (section 17).
- [ ] Phase 2 (during construction): pull Cat6 (incl. 2 AP drops: basement + floor 1) -- NO speaker
      home-runs (NuTone reused); relocate the modem to the basement; install UCG-Fiber (basement) +
      USW-Pro-Max-16-PoE + 3x U7 Pro APs (floor-2 AP over MoCA/coax);
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

- [x] **DONE (2026-07-30): UniFi Network integration added to HA.** `unifi` entry, site "Default",
      loaded, host 192.168.50.1:443, local admin, SSL-verify off. Client tracking turned OFF via the
      options flow (track_clients + more_options.track_wired_clients = false; track_devices kept ON)
      -> client device_trackers dropped 14 -> 7 and won't grow as devices join. Got ~61 enabled
      entities: AP/switch/gateway devices, PoE-port switches, restart buttons, firmware `update`s,
      per-device sensors. NOTE: the AP(s) + switch come IN with this integration -- do NOT add them
      separately. Separately, an `upnp` entry ("UniFi Dream Machine", from SSDP) provides basic WAN
      throughput/external-IP sensors -- kept for internet monitoring; it is NOT the UniFi integration.
      (original task text below.)
      Gateway confirmed as
      UniFi OS at 192.168.50.1 (UCG-Fiber), https/443.
      1. FIRST create a LOCAL UniFi account -- NOT the ui.com cloud account. UniFi -> Settings ->
         Admins & Users -> Add Admin -> "Restrict to Local Access Only". A cloud account breaks
         when 2FA is on, stops working when the internet is down (exactly when local monitoring
         matters most), and grants far more access than HA needs. Give it full site management if
         HA should CONTROL things (block clients, cycle PoE); view-only is enough for sensors alone.
      2. HA -> Settings -> Devices & Services -> Add Integration -> "UniFi Network".
         Host 192.168.50.1, port 443, site `default`, **Verify SSL OFF** (self-signed cert).
      3. IMMEDIATELY open the integration's Configure options and turn OFF "track clients" --
         the default creates a `device_tracker` for EVERY client on the network (dozens of
         entities), and that is precisely the UniFi-Wi-Fi presence mechanism deliberately deferred
         above. Revisit only when presence is taken up.
      WHAT IT BUYS: WAN status/throughput sensors; firmware `update` entities for UniFi gear;
      PoE port switches + power-cycle buttons (valuable once cameras/APs are on the
      USW-Pro-Max-16-PoE -- a wedged camera can be power-cycled from an automation instead of a
      trip to the rack); and client block/unblock switches, which is the better way to do the
      SCHEDULED DEVICE BLOCK originally wanted -- an HA automation gives far richer scheduling
      (conditions, calendars, per-person logic) than UniFi's built-in scheduler.
      NOTE: the config flow needs the local account password, so this step is done in the UI by
      hand rather than scripted.
- [ ] DEFERRED 2026-07-21 -- PRESENCE / location tracking. NOT being set up yet; do not re-propose.
      Current state: the Companion app device_trackers exist but report `unknown` with no
      coordinates (location reporting off), so all 3 `person` entities are `unknown` and the Map
      dashboard is empty. CONSEQUENCE: do NOT write presence-based automations yet (arrive-home
      lighting, HVAC away-mode, camera arm/disarm) -- they would silently never fire, which is
      painful to debug later. When it IS taken up, the two options are Companion-app GPS (real
      zones + "approaching home", some battery cost) and UniFi Wi-Fi association (local, zero
      battery, but binary and broken by MAC randomization -- needs "private address: off" per
      family phone). Using BOTH is more robust than either. Map dashboard stays in the sidebar
      meanwhile; note it is visible to ALL users, so agree it as a family before enabling GPS.
- [ ] **TASK (queued 2026-07-21): pair the GARAGE relay + tilt sensor.** Devices in hand: Aqara Dual
      Relay T2 (DCM-K01) + ThirdReality tilt sensor (3RDTS01056Z). Full wiring detail is in the
      "Garage door note" under 6.4 -- read it before starting.
      ORDER MATTERS -- relay FIRST, sensor SECOND: the T2 is mains-powered so it becomes the
      GARAGE'S OWN ZIGBEE ROUTER; the tilt sensor is a battery END DEVICE that picks its parent at
      join time and clings to it. Pair the sensor first and it binds to a distant router it can
      barely hear, then sits on a weak link (sleepy end devices re-parent slowly). The garage is
      normally the weakest corner of the mesh: far from the centrally-placed coordinator, often
      behind a fire-rated wall.
      PRE-CHECK: confirm a mains router is reachable from the garage (the 4 plugs are Living Room /
      Dining Room / Family Room / Hallway -- is Hallway near the garage door?). If not, place a
      spare plug on the garage path FIRST or the relay may not join from its final location.
      SAFETY (critical): kill the breaker feeding the ceiling outlet. **REMOVE THE RED JUMPER**
      between LIN and LOUT -- that jumper makes the output LIVE, and leaving it in injects 120 V
      into the opener's low-voltage control board (destroys it; shock/fire hazard). Prefer the plug
      pigtail + outlet splitter into the existing opener outlet so there is no hardwiring at all.
      STEPS: 1) paperclip-short the opener's two wall-button terminals to confirm the right pair.
      2) Wire the T2 (LIN<-live, N<-neutral, jumper OUT, opener COM->LOUT, opener trigger->L1).
      3) permit_join ON, pair the relay (expect Z2M model `LLKZMK12LM`). 4) Pair the tilt sensor
      IN THE GARAGE near its mount point so it binds to the relay. 5) permit_join OFF, rename both,
      and check Z2M -> Map that the sensor's parent is the RELAY, not something across the house.
      THEN: make the relay MOMENTARY (relay ON -> wait ~0.8 s -> OFF) and build the HA template
      cover tying relay + sensor into one garage entity. Keep auto-close conservative (UL325).
- [ ] ASSESS the old ADT box + Cat5 drops (potential FREE AP backhaul, see 5 item 0): confirm
      real Cat5/5e UTP (not alarm wire); find the central termination panel; map each drop's far
      end; test continuity + 1GbE link + PoE. Confirm ADT is dead. Could solve the AP-backhaul
      problem outright and add spare wired drops. LOCATION = BASEMENT near the electric panel (same
      level as the rack) -> drops home-run there = short patch to the switch (or a patch panel at
      the box + uplink to the main switch). EMI: keep network gear/cabling off the electrical panel,
      separated from mains, cross at 90. A central floor-1 drop could also feed the SLZB-06.
- [x] Floor-2 (top-floor) AP backhaul = MoCA/coax (DECIDED: no ceiling access on floors 1 & 2; no
      easy Cat6 path to floor 2). Buy the MoCA kit (see 6.2); confirm a usable coax jack at the AP spot.
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
- [x] Storage approach: UGREEN NAS (DXP4800 Pro, 4-bay, start 2x14 TB mirror, no drive lock) for
      continuous recordings + media + family Photos/Drive + backups + Jellyfin; existing SSD in masn for OS + Frigate
      cache. Continuous recording via dual-stream + tiered retention. Grow by adding a 2nd 2x14
      pair (-> 28 TB) when needed. Keep Frigate cache local; export NFS/SMB. UGOS now / TrueNAS later.
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
2. Disks. TARGET = 2x14 TB MIRROR (Toshiba N300 HDWG21E). CHOSEN PLAN: start with 1x14 TB now,
   add the 2nd (also 14 TB) in a few months once stable. Same 14 TB usable meanwhile; NO
   redundancy until then.
   !! BUILD STATUS 2026-06-29: NAS arrived, but the 1st IronWolf Pro 12 TB was DOA (clicking =
      mechanical failure) on first power-up. Returned/RMA'd. BUILD BLOCKED until a working disk
      is in hand. Caught at burn-in on an empty array (the system worked as intended). Do NOT wipe
      masn -- it still holds the only copy of the 382 GB media library; no valid NAS target yet.
      Burn-in the replacement (SMART long + surface scan) before trusting it.
   - FILE SYSTEM = BTRFS (UGOS offers ext4 or btrfs -- pick BTRFS). It gives checksumming/bit-rot
     detection + snapshots (ext4 has neither) and in-place single->RAID1 conversion later. (btrfs is
     the UGOS stand-in for the ZFS we'd have used on TrueNAS.) AVOID btrfs RAID5/6; RAID1 is the target.
   - Adding the mirror later (no re-copy): add the 2nd 14 TB, convert the pool to RAID1 in place
     (`btrfs device add` + balance-convert; UGOS wraps this as add-drive -> RAID1). Confirm UGOS
     does the Basic->RAID1 migration in place; if not, rebuild as RAID1 later (Google is off-site copy).
   - SMART short test + health check the disk before trusting it (full surface scan can run after).
   - Schedule MONTHLY btrfs SCRUBS: single-disk can't self-heal, but scrubs still DETECT bit-rot
     (once mirrored, RAID1 auto-repairs from the good copy).
   - SINGLE-DISK SAFETY RULES (until the mirror exists):
     * Nothing IRREPLACEABLE may live on the NAS alone. Keep GOOGLE PRIMARY; do NOT run the
       "drop Google" migration yet. Recordings/media/masn-backups are re-creatable -> OK to risk.
     * masn wipe (Phase 0d): the NAS is your only backup copy, so KEEP masn's ORIGINAL SSD intact
       as the 2nd copy through the migration. Clean-install onto the new disk/NVMe, run the new
       stack ~1-2 weeks to verify, and only THEN wipe/reuse the original SSD.
   4-bay: leave 2 bays empty now; grow later by adding a 2nd 2x14 mirror pair (-> 28 TB usable).
3. Create shares + users per the access-control design (see 6.8): `backups`, `recordings`
   (Frigate svc + admin only), `media` (Jellyfin svc), `family-shared` (group `family`),
   per-member private folders, and a PASSPHRASE-encrypted `sensitive-docs` folder. No guest
   access anywhere. All shares over SMB (UGOS default); masn mounts them via `cifs` + a
   credentials file (chmod 600). Scope share access to masn's account + the Trusted VLAN. Keep encryption per-folder (not whole-pool) so reboots don't block the
   stack; ensure Tailscale lives on the unencrypted system area so you can unlock from your phone.
4. Wire the UPS USB to the NAS; enable graceful shutdown on battery.
5. Mount-test from masn (SMB): `sudo mount -t cifs //<nas>/backups /mnt/nas-backups -o
   credentials=/etc/samba/creds-nas,uid=$(id -u),gid=$(id -g),vers=3.1.1` and write a test file.
   Confirm read-back. (setup-masn.sh writes the creds file + fstab lines automatically.)

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
4a. (clean install only) BIOS: set SATA Operation RAID On -> AHCI. NOW REQUIRED to see the NEW
    NVMe (RAID/VMD mode hides NVMe from the installer). Also removes the initramfs-RAID dependency.
4a1. Install the NEW 1TB NVMe in the free M.2 slot (the old SATA SSD is worn out -- keep it
     connected ONLY until the media copy finishes, then remove it).
4b. Clean-install Ubuntu Server 24.04 LTS (headless) on the NEW NVMe; attach Ubuntu Pro (free,
    personal) for ESM to 2034. Static IP/DHCP reservation matching the old one. In the installer,
    SKIP all "Featured Server Snaps" (esp. the Docker snap -- confined, breaks /dev/dri + bind
    mounts). Install from APT/.deb ONLY: openssh-server; docker-ce + compose plugin from the
    OFFICIAL docker.com apt repo (NOT the docker snap, NOT Ubuntu's docker.io); NoMachine (.deb,
    on-demand GUI); cifs-utils (SMB client). No snaps are needed on this box; optionally purge
    snapd for a leaner apt-only server.
4c. Re-mount the NAS shares via `/etc/fstab` (recordings + media + backups).
4d. Rebuild the container stack from compose: home-assistant (`restart: unless-stopped`),
    frigate (OpenVINO `/dev/dri`, cache local, recordings -> NAS), mosquitto, zigbee2mqtt,
    postgres (restore the dump). NO Snapcast (audio = NuTone + WiiM), NO Jellyfin on masn,
    NO Omada/UniFi controller (UniFi runs on the UCG-Fiber).
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
  # No network-controller container: UniFi controller runs on the UCG-Fiber gateway.

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
