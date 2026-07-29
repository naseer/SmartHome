# Home Assistant dashboards

Lovelace configs live in HA's `.storage/` (root-owned) and are NOT exposed over the REST
API, so they are neither in a normal config backup nor editable without sudo. These JSON
files are the version-controlled source of truth; apply them with
`../../tools/apply-dashboard.sh`, which drives HA's WebSocket API using the long-lived
token at `~/.ha_token` (no sudo required).

| File | Target `url_path` | Who sees it |
|------|-------------------|-------------|
| `westacott.json` | `-` (the built-in default **Overview**) | Everyone -- this is the family landing page |
| `westacott.json` | `dashboard-westacott` | Everyone -- named sidebar entry, same content |
| `all-entities.json` | `all-entities` | Admin only -- HA's auto-generated "everything" view |

```sh
./apply-dashboard.sh - ../homeassistant/dashboards/westacott.json          # default Overview
./apply-dashboard.sh dashboard-westacott ../homeassistant/dashboards/westacott.json
./apply-dashboard.sh all-entities ../homeassistant/dashboards/all-entities.json
```

`westacott.json` is applied to BOTH targets, so re-run both commands after editing it or the
two will drift. The named dashboard was briefly deleted 2026-07-21 and restored: the default
Overview panel can be hidden per-device in browser localStorage (invisible to any server-side
check), so a named sidebar entry is a reliable way in when Overview is not showing.

Add `--dry-run` to see the card counts without writing.

## Why the default Overview rather than a per-user setting

HA's "default dashboard" (`defaultPanel`) is stored **per user account**. The API can only
set it for the token's own user, so every family member -- and every future account --
would have to set it themselves. Writing the config into the built-in Overview instead
makes it the landing page for all users at once, with no per-user step.

Taking over the Overview replaces HA's auto-generated view, so `all-entities.json`
recreates that view (via the `original-states` strategy) as an admin-only dashboard.

### RESTART HA after taking over the default Overview (the gotcha)

Saving a config to the default dashboard is NOT enough on its own -- **you must restart Home
Assistant afterwards**, or every user keeps seeing the built-in auto-generated view.

Why: HA registers each dashboard PANEL at startup and stamps it with the mode it had at that
moment. If the default dashboard had no stored config when HA started, the `lovelace` panel is
registered with `config: null` (= auto-generate). The frontend reads that panel registration and
GENERATES the dashboard client-side -- it never asks the server for a stored config. So the saved
config sits on disk, `lovelace/config` returns it correctly, and nothing renders it.

Diagnose with the `get_panels` WS command and compare the `config` field:

    lovelace            -> null                 BROKEN (auto-generating, restart needed)
    lovelace            -> {"mode": "storage"}  correct
    dashboard-westacott -> {"mode": "storage"}  dashboards CREATED via the API get this at creation

This is why a freshly created dashboard works immediately but a taken-over Overview does not.
It looks exactly like a browser cache problem and is completely immune to cache clearing --
if it reproduces for OTHER user accounts, it is this, not cache.

## Custom cards (advanced-camera-card)

`westacott.json`'s **Cameras** view uses `custom:advanced-camera-card` (the renamed frigate-hass-card).
That card is NOT part of HA -- it is a Lovelace resource whose JS lives at
`config/www/advanced-camera-card/` on masn (masn-only; `config/` is gitignored) and is registered as a
module resource `/local/advanced-camera-card/advanced-camera-card.js`. If rebuilding masn: re-download
the v7.x bundle (all ~50 chunk files into that dir) and re-create the resource
(`lovelace/resources/create`, res_type `module`). After first install, HARD-refresh the browser or the
Cameras tab renders "custom element doesn't exist: advanced-camera-card".

## Editing

Either edit the JSON here and re-apply, or edit in the HA UI and pull the config back down
into these files so the repo stays authoritative.
