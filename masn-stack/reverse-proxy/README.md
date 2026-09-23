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
- **Challenge delegated to DuckDNS.** Squarespace hosts this zone and has no API, so renewals cannot
  be automated against it. `_acme-challenge.ha.naseer.dev` is a CNAME into a free DuckDNS domain,
  which does have one. Two one-time records in Squarespace and it is never touched again -- Google
  Workspace mail, DKIM, the apex site and the www GitHub Pages record all stay where they are.
  Migrating the whole zone was the alternative and was rejected: DKIM failures are silent, and a zone
  cannot be enumerated from outside, so any subdomain not guessed would have been dropped.
  deSEC was the first choice; **dedyn.io registration is suspended (2026-09-23)**. If it reopens,
  deSEC is the better host -- a proper REST API and real RRset support rather than one TXT slot.
  NOTE: deSEC's "own domain" option is NOT the answer either, since it delegates naseer.dev's
  nameservers to deSEC, which is the migration being avoided.

  Two DuckDNS quirks are load-bearing:
    1. **The TXT lives at the APEX of `<name>.duckdns.org`**, not under an `_acme-challenge` label,
       so the CNAME target carries NO `_acme-challenge` prefix. Pointing at
       `_acme-challenge.<name>.duckdns.org` resolves to nothing and issuance fails.
    2. **One TXT per DuckDNS domain**, so one certificate NAME per DuckDNS domain. A multi-name (SAN)
       certificate must satisfy every challenge at once and the second value would overwrite the
       first. A second name needs a second DuckDNS domain with its own CNAME.
- **A proxy, not TLS inside HA.** About a dozen things speak plain http to `:8123` -- the wall Pi
  kiosk URL, `masjid-prayer-times.py`, `apply-dashboard.sh`, `ha-reload.sh`, every diagnostic here.
  Enabling HA's own `ssl_certificate` breaks all of them at once. HA stays http; nginx sits beside it.
- **A separate compose project (`-p tls`).** The main stack runs the things the house depends on.
  A TLS tweak must never be able to recreate the container the door locks talk through.

## Setup

1. DuckDNS: sign in, register a domain `<name>.duckdns.org`, copy the account token.
   acme.sh is invoked with `--challenge-alias <name>.duckdns.org`; without that flag it tries to
   write the TXT into Squarespace, which has no API, and issuance fails.
2. Squarespace, once:

       ha                  A      192.168.50.50
       _acme-challenge.ha  CNAME  <name>.duckdns.org      # NO _acme-challenge prefix on the target

3. On masn: `./setup-tls.sh <name>` -- it verifies both records BEFORE issuing (Let's Encrypt
   rate-limits repeated failures), prompts for the token on stdin, issues, and starts nginx.
4. Add the `http:` and `homeassistant:` blocks it prints, then RESTART HA -- a new `http:` block is
   not reloadable.

## Renewal, and what breaks if it fails

acme.sh runs in daemon mode and renews at ~60 days against a 90-day certificate, so there is a month
of headroom. If renewal fails anyway: **`.dev` is HSTS-preloaded, so there is no http fallback** --
browsers refuse the name outright. The wall Pi is unaffected (it uses the plain LAN URL), but casting
breaks and `external_url` goes dead. Worth an alert; there is a working notify path already.
