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

## Editing

Either edit the JSON here and re-apply, or edit in the HA UI and pull the config back down
into these files so the repo stays authoritative.
