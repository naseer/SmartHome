# The wall Pi is pinned to one AP on purpose

`802-11-wireless.bssid = 58:D6:1F:41:2C:8B` (5 GHz, ch 100) on the `humans` connection.

## Why

Found 2026-08-30 while chasing "buffering" on the wall. The Pi had re-associated **14 times since
boot**, 11 of them inside one 36-minute window, on a metronome:

```
19:28:31  freq=5560
19:33:34  freq=5500
19:38:38  freq=5560
19:43:42  freq=5500
19:48:45  freq=5560
```

Every 5 minutes and 3 seconds, alternating between the two APs, and twice dropping to 2.4 GHz. Each
one is a full re-association PLUS `dhcp4: restarting`, i.e. several seconds where all five camera
streams stall at once.

Every single one is preceded by:

```
bgscan simple: Failed to enable signal strength monitoring
```

That is the cause. The Pi's brcmfmac driver cannot report signal strength to wpa_supplicant, so
`bgscan simple` -- which is supposed to scan only when the signal degrades -- falls back to scanning
on a fixed timer and roams every time. The two 5 GHz radios sit at signal 67 and 65, near enough
identical, so it ping-pongs forever. A wall display is bolted to a wall; it never needs to roam.

NetworkManager 1.52 exposes no `bgscan` property, so pinning the BSSID is the available lever: with
one candidate, there is nothing to roam to. Link rate went 65-90 -> 325 Mbit/s immediately.

## This is two separate problems, do not conflate them

Measured with `tools/video-stats.py` before and during the flapping:

```
                        after a kiosk restart      during the flapping
rebuffers (waiting)     0 on every tile            17 / 199 / 21 / 24 / 27
readyState              4 (healthy) everywhere     2 on four of five tiles
buffer ahead            ~1.0s                      0.2s on front_door
dropped frames          ~8%                        ~12%
```

- **Spinners and stalls** = the WiFi roaming. Fixed here.
- **The steady ~8-12% dropped frames** = Chromium's renderer thread, pegged at 92% of one core.
  A different problem with a different fix (see orin-stack/wall-grid/). Compositing addresses the
  dropped frames and does NOTHING for the stalls -- and would push 3 Mbps down this link in place of
  ~1 Mbps of sub-streams, so it must not be used as a fix for rebuffering.

## The trade-off this accepts

Pinning means NO FAILOVER. If that AP goes down the wall stays offline until it returns, rather than
moving to the other one. That is the right trade for a fixed display whose failure mode today is
"stalls every five minutes", but it is a real trade -- if that AP is ever retired, this must be
re-pointed or cleared with:

    sudo nmcli connection modify humans 802-11-wireless.bssid ""

Both 5 GHz radios are on DFS channels (100 and 112). BSSID pinning survives a radar-triggered
channel change, because the BSSID does not change with the channel -- so this does not make DFS
worse. Moving the APs to non-DFS channels would still be an improvement, separately.

## Ethernet would retire this whole file

`eth0` is down -- there is no cable at the wall. A wired drop removes roaming, DFS and bandwidth
questions in one go, and is the correct answer for a permanent installation.
