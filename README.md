# SmartHome

Home-server + smart-home build for `masn` (Dell OptiPlex 5050 SFF) and a 3-floor / 3200 sqft
house. Local-first, no-cloud-by-default, security-first. Reproducible infra in `masn-stack/`.

- **Decisions + BoM (~$4,960):** [`home-server-smart-home-plan.md`](home-server-smart-home-plan.md)
- **Agent/session orientation + Phase 0 runbook:** [`AGENTS.md`](AGENTS.md)

## Infrastructure layout

```
                        3 Gbps fiber ONT
                                 | (SFP+/10G handoff)
                       [ UniFi UCG-Fiber ]            router + firewall/IDS + controller (10G SFP+ WAN)
                                 | 10G SFP+ DAC
                  [ UniFi USW-Pro-Max-16-PoE ]      VLANs + PoE  (2.5G ports + 10G SFP+)
   ______________________________|________________________________________________
  |          |          |            |           |              |                   |
 masn       NAS      Pi kiosk     4x PoE       PoE          3x U7 Pro AP         SLZB-06
(server)  (storage)              cameras     doorbell      (Wi-Fi 7, 1/floor)   (Zigbee coord,
  |          |                                              wired PoE backhaul)  central floor 1)
  |          |                                                                    |
  +-- ZBT-2 (Thread Border Router, USB)                              Zigbee mesh (Z2M over TCP)
  +-- HD 630 iGPU (Frigate/OpenVINO detect)                          Thread mesh via 9 TP-Link
  +-- Docker: HA, Mosquitto, Postgres, (Frigate, Z2M)                  mains switches (routers)
```

Wi-Fi is served by the 3 ceiling APs (one per floor), NOT the rack. ASUS BT10 retired (sold).

## Core components

| Component | Role | Location |
|-----------|------|----------|
| **masn** — OptiPlex 5050 SFF (i7-7700, 32 GB) | App server: Home Assistant, Frigate, MQTT, Postgres | Basement rack |
| **NuTone IM-3303** + WiiM streamer | Whole-house audio (reused as-is; WiiM feeds its AUX; casting + HA) | Existing house wiring |
| **NAS** — UGREEN DXP4800 Pro (ZFS) | Bulk storage: recordings, media, family Photos/Drive, backups; runs Jellyfin + Immich/Nextcloud | Basement rack |
| **UCG-Fiber** | Router + firewall/IDS + UniFi controller | Basement rack |
| **USW-Pro-Max-16-PoE** | Switching, VLANs, PoE (cameras + APs); 2.5G + 10G SFP+ | Basement rack |
| **3× U7 Pro APs** | Wi-Fi 7, wired PoE backhaul | Ceiling, one per floor |
| **SLZB-06** | Zigbee coordinator (Zigbee2MQTT over TCP) | Central, floor 1 |
| **ZBT-2** | Thread Border Router (HA/OTBR) | masn USB, basement |
| **1500VA pure-sine UPS** | Powers everything incl. PoE (cameras/APs/internet ride outages) | Basement rack |

## Networks (VLANs)

| VLAN | Members | Internet | Reaches NAS? |
|------|---------|----------|--------------|
| Trusted | Workstations, phones, masn | Yes | Yes (then NAS user/ACL applies) |
| Cameras | PoE cameras + doorbell | Blocked | No (firewalled) |
| IoT | Matter/Wi-Fi + smart devices | Restricted | No (firewalled) |

## Radio meshes (two, dedicated)

- **Zigbee** (SLZB-06 coordinator + Zigbee2MQTT): battery sensors, garage (Aqara T2 + tilt sensor),
  thermostat, ~4 mains "router" plugs to seed the mesh.
- **Thread** (ZBT-2 border router): the 9 owned TP-Link mains lighting switches (dense routers).

## Data flows

- **Camera recordings:** cameras → Frigate (detect on iGPU, cache on masn SSD) → finished
  segments to the NAS over NFS (15-day continuous retention).
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
