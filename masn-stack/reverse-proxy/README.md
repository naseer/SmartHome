# https://ha.naseer.dev -- a TLS front door so Cast stays on the LAN

## The problem this solves

Home Assistant Cast picks its own URL:

    hass_url = get_url(hass, require_ssl=True, prefer_external=True)

https is REQUIRED and external is PREFERRED. So `http://192.168.50.50:8123` is skipped, and with
`external_url` being the Nabu Casa address the Cast device fetched the dashboard and all five camera
streams from the cloud. Measured on masn 2026-09-21 while the TV was showing the wall:

    upload to Nabu Casa    3,516,838 bytes / 10 s   = ~2.8 Mbit/s
    download                       98 bytes / 10 s
    send-queue backlog          7,525 bytes         <- the uplink could not keep up

That backlog was the buffering on the TV. Note it is a NETWORK round trip, and NOT the same fault as
the wall Pi's buffering, which is renderer-thread frame drops with the box 39% idle. Same symptom,
unrelated cause; do not apply one fix to the other.

Because `prefer_external=True`, adding an https INTERNAL url does not help -- Nabu Casa still wins.
The LAN address has to BE `external_url`.

## Why the pieces are shaped this way

- **A public name for a private address.** `ha.naseer.dev` resolves publicly to `192.168.50.50`.
  Chromecasts are documented to ignore DHCP-supplied DNS and query Google's resolvers, so a
  split-horizon override on the UniFi would never reach the TV. Cost: it publishes where HA lives,
  and the name is useless outside the house. Both acceptable; Nabu Casa still covers remote.
- **DNS-01, not HTTP-01.** HTTP-01 and TLS-ALPN-01 need inbound 80/443, i.e. port-forwarding, which
  this project does not do. DNS-01 opens nothing.
- **Challenge delegated to deSEC.** Squarespace hosts this zone and has no API, so renewals cannot be
  automated against it. `_acme-challenge.ha.naseer.dev` is a CNAME into a free deSEC zone, which does
  have one. Two one-time records in Squarespace and it is never touched again -- crucially, Google
  Workspace mail, DKIM, the apex site and the GitHub Pages www record all stay exactly where they are.
  Migrating the whole zone was the alternative and was rejected: DKIM failures are silent, and a zone
  cannot be enumerated from outside, so any subdomain not guessed would have been dropped.
- **A proxy, not TLS inside HA.** About a dozen things speak plain http to `:8123` -- the wall Pi
  kiosk URL, `masjid-prayer-times.py`, `apply-dashboard.sh`, `ha-reload.sh`, every diagnostic here.
  Enabling HA's own `ssl_certificate` breaks all of them at once. HA stays http; nginx sits beside it.
- **A separate compose project (`-p tls`).** The main stack runs the things the house depends on.
  A TLS tweak must never be able to recreate the container the door locks talk through.

## Setup

1. deSEC: free account, choose the **dynDNS / free domain** option and register `<name>.dedyn.io`,
   then create an API token. Do NOT use deSEC's "own domain" option -- that delegates `naseer.dev`'s
   nameservers to deSEC, which is the full-zone migration this design exists to avoid.
   acme.sh is invoked with `--challenge-alias <name>.dedyn.io`; without that flag it tries to write
   the TXT into Squarespace, which has no API, and issuance fails.
2. Squarespace, once:

       ha                  A      192.168.50.50
       _acme-challenge.ha  CNAME  _acme-challenge.<name>.dedyn.io

3. On masn: `./setup-tls.sh <name>` -- it verifies both records BEFORE issuing (Let's Encrypt
   rate-limits repeated failures), prompts for the token on stdin, issues, and starts nginx.
4. Add the `http:` and `homeassistant:` blocks it prints, then RESTART HA -- a new `http:` block is
   not reloadable.

## Renewal, and what breaks if it fails

acme.sh runs in daemon mode and renews at ~60 days against a 90-day certificate, so there is a month
of headroom. If renewal fails anyway: **`.dev` is HSTS-preloaded, so there is no http fallback** --
browsers refuse the name outright. The wall Pi is unaffected (it uses the plain LAN URL), but casting
breaks and `external_url` goes dead. Worth an alert; there is a working notify path already.
