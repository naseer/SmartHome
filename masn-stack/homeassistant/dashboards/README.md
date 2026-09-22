# Home Assistant dashboards

Lovelace configs live in HA's `.storage/` (root-owned) and are NOT exposed over the REST
API, so they are neither in a normal config backup nor editable without sudo. These JSON
files are the version-controlled source of truth; apply them with
`../../tools/apply-dashboard.sh`, which drives HA's WebSocket API using the long-lived
token at `~/.ha_token` (no sudo required).

| File | Target `url_path` | Who sees it |
|------|-------------------|-------------|
| `overview.json` | `-` (the built-in default **Overview**) | Everyone -- the single family landing page |
| `all-entities.json` | `all-entities` | Admin only -- HA's auto-generated "everything" view |
| `presence.json` | `dashboard-presence` | Everyone -- Zaid's floor + who's home. Floor buttons visible to Zaid's user only. Needs `packages/zaid_presence.yaml` |

```sh
./apply-dashboard.sh - ../homeassistant/dashboards/overview.json           # default Overview
./apply-dashboard.sh all-entities ../homeassistant/dashboards/all-entities.json
```

CONSOLIDATED 2026-08-02: there is now a SINGLE family dashboard -- the built-in default
**Overview**, fed from `overview.json`. The redundant named `dashboard-westacott` entry (a
byte-identical copy) was deleted: keeping two in sync kept causing drift (a change would land in
one but not the other). If you ever need a named-sidebar fallback again (the default Overview can
be hidden per-device in browser localStorage), re-create it and apply `overview.json` to it too --
but then you own the re-sync every edit.

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

`overview.json`'s **Cameras** view uses `custom:advanced-camera-card` (the renamed frigate-hass-card).
That card is NOT part of HA -- it is a Lovelace resource whose JS lives at
`config/www/advanced-camera-card/` on masn (masn-only; `config/` is gitignored) and is registered as a
module resource `/local/advanced-camera-card/advanced-camera-card.js`. If rebuilding masn: re-download
the v7.x bundle (all ~50 chunk files into that dir) and re-create the resource
(`lovelace/resources/create`, res_type `module`). After first install, HARD-refresh the browser or the
Cameras tab renders "custom element doesn't exist: advanced-camera-card".

GOTCHA (cost a restart): HA registers the `/local/` static route (-> `config/www`) at STARTUP. If the
`www` folder is created while HA is running (as it was here), `/local/...` 404s until HA is restarted,
and the card shows a generic "configuration error" (the JS never loads). Fix: create `www` FIRST, then
`docker compose restart homeassistant`, then register the resource.

## Editing

Either edit the JSON here and re-apply, or edit in the HA UI and pull the config back down
into these files so the repo stays authoritative.

## WARNING: overview.json has DRIFTED from live -- do not blind-apply it (found 2026-09-21)

`apply-dashboard.sh - overview.json` would make TWO changes nobody asked for:

| | live in HA | this repo file |
|---|---|---|
| views | Home, Cameras | Home, Cameras, **Review** |
| `cameras` view type | `masonry` | `panel` |

So applying it RE-ADDS a Review view that is not live any more, and flips Cameras from masonry to
panel. Neither is intended; both were discovered only because a dry run reported "current: 2 view(s)"
against "new: 3 view(s)". Always read that line before writing.

The `Wall display` section (cast buttons) was therefore applied SURGICALLY -- read the live config,
append the one section, save it back -- rather than by pushing this file. That kept both live views
and the masonry type intact.

UNRESOLVED: which side is authoritative. Either the Review view should come back (apply this file) or
it is gone deliberately (this file should drop it and set `cameras` to masonry). Decide before the
next dashboard change, because until then this file cannot safely be applied at all.
