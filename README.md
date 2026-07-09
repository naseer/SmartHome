# SmartHome

Home-server + smart-home build for `masn` (Dell OptiPlex 5050 SFF) and a 3-floor / 3200 sqft
house. Local-first, no-cloud-by-default, security-first. Reproducible infra in `masn-stack/`.

- **Decisions + BoM (~$4,960):** [`home-server-smart-home-plan.md`](home-server-smart-home-plan.md)
- **Agent/session orientation + Phase 0 runbook:** [`AGENTS.md`](AGENTS.md)

## Infrastructure layout

```
   BASEMENT RACK (one UPS):  Coax demarc -> Cable modem   [later: 3 Gbps fiber ONT -> 10G SFP+ WAN]
                                 | Ethernet WAN
                       [ UniFi UCG-Fiber ]          router + firewall/IDS + controller (10G SFP+ WAN, 5G IDS)
                                 | 10G SFP+ DAC
                  [ UniFi USW-Pro-Max-16-PoE ]      VLANs + PoE  (2.5G ports + 10G SFP+)
   ______________________________|________________________________________________
  |          |          |            |           |              |                   |
 masn       NAS      Pi kiosk     2x PoE     front Wi-Fi:   3x U7 Pro AP         SLZB-06
(server)  (storage)              cameras   2 cams+doorbell (one per level;      (Zigbee coord,
  |          |                                              floor 2 via MoCA)    central floor 1)
  |          |                                                                    |
  +-- (Thread BR: none now -- ZBT-2 returned)                        Zigbee mesh (Z2M over TCP)
  +-- HD 630 iGPU (Frigate/OpenVINO detect)                          12 Sinopé mains dimmers route
  +-- Docker: HA, Mosquitto, Postgres, (Frigate, Z2M)                  mains switches (routers)
```

Wi-Fi is served by 3 U7 Pro APs, one per level (basement ceiling + floors 1/2 wall; floor 2 over MoCA), NOT the rack. ASUS BT10 retired (sold).

## Core components

| Component | Role | Location |
|-----------|------|----------|
| **masn** — OptiPlex 5050 SFF (i7-7700, 32 GB) | App server: Home Assistant, Frigate, MQTT, Postgres | Basement rack |
| **NuTone IM-3303** + WiiM streamer | Whole-house audio (reused as-is; WiiM feeds its AUX; casting + HA) | Existing house wiring |
| **NAS** — UGREEN DXP4800 Pro (ZFS) | Bulk storage: recordings, media, family Photos/Drive, backups; runs Jellyfin + Immich/Nextcloud | Basement rack |
| **UCG-Fiber** | Router + firewall/IDS + UniFi controller (10G SFP+ WAN, 5 Gbps IDS) | Basement rack |
| **USW-Pro-Max-16-PoE** | Switching, VLANs, PoE (cameras + APs); 2.5G + 10G SFP+; 10G DAC to gateway | Basement rack |
| **3× U7 Pro APs** | Wi-Fi 7; one per level (floor 2 over MoCA) | Basement ceiling + floors 1/2 wall |
| **SLZB-06** | Zigbee coordinator (sole radio; Z2M over TCP) | Central, floor 1 |
| **1500VA pure-sine UPS** | Powers everything incl. PoE (cameras/APs/internet ride outages) | Basement rack |

## Networks (VLANs)

| VLAN | Members | Internet | Reaches NAS? |
|------|---------|----------|--------------|
| Trusted | Workstations, phones, masn | Yes | Yes (then NAS user/ACL applies) |
| Cameras | PoE + front Wi-Fi cameras + doorbell | Blocked | No (firewalled) |
| IoT | Matter/Wi-Fi + smart devices | Restricted | No (firewalled) |

## Radio mesh (Zigbee-primary)

- **Zigbee** (SLZB-06 coordinator + Zigbee2MQTT): **12 Sinopé DM2500ZB dimmers** (house lighting + the
  router backbone) + battery sensors + garage (Aqara T2 + tilt sensor) + thermostat.
- **Thread** (ZBT-2 border router): **optional/future** — nothing load-bearing yet (the 9 TP-Link
  switches were Matter-over-Wi-Fi, not Thread → returned; lighting moved to Zigbee).

## Data flows

- **Camera recordings:** cameras → Frigate (detect on iGPU, cache on masn SSD) → finished
  segments to the NAS over SMB (15-day continuous retention).
- **Media:** library on the NAS; Jellyfin runs on the NAS (Quick Sync transcode).
- **Family photos/files:** Immich + Nextcloud on the NAS; **Google stays primary** (off-site copy).
- **Remote access:** Home Assistant via **Nabu Casa**; Jellyfin + admin via **Tailscale per-host**
  (no port-forwarding, no whole-subnet route — VLAN segmentation preserved).
- **Audio:** cast/AirPlay/Spotify → **WiiM** → NuTone IM-3303 **AUX** → whole-house speakers
  (existing wiring, mono, lo-fi by choice). No multi-zone amp or Snapcast.

## Repo layout

```
home-server-smart-home-plan.md   master plan: decisions, BoM, runbook
AGENTS.md                        orientation for agents/sessions
README.md                        this file
masn-stack/                      reproducible Docker stack + Phase 0 scripts
  docker-compose.yml             HA+Mosquitto+Postgres active; Frigate/Z2M staged
  .env.example                   copy -> .env (gitignored), fill, chmod 600
  copy-media.sh                  media -> NAS + verify (run before the wipe)
  setup-masn.sh                  Docker + /opt/stack + NAS mounts + compose up
  mosquitto/ zigbee2mqtt/ frigate/ homeassistant/   service configs
```

## Status (2026-06-25)

NAS arrives 2026-06-26 → Phase 0 (bring masn online). Greenfield clean install; storage starts
single 12 TB, mirror added in a few months. See `AGENTS.md` for the step-by-step runbook.
