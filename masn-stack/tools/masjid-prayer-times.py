#!/usr/bin/env python3
"""Scrape Iqamah times from ajaxmasjid.ca and publish them to Home Assistant.

Feeds the "Prayer Times - Masjid Quba" table on the wall display.

THE PAGE IS SERVER-RENDERED (WordPress), so no browser is needed -- the times are in the raw HTML:

    <ul class="sunrise-row">
      <li class="pry-tim-hed"><span>Salah</span><span>Start</span><span>Azan</span><span>Iqamah</span></li>
      <li><span class="thm-clr">Fajr</span>
          <span class="start-time">4:57 am</span>
          <span class="end-time">05:30 AM</span>     <- Azan
          <span class="end-time">05:45 AM</span></li> <- Iqamah

DO NOT KEY ON class="end-time". Maghrib's row omits the class entirely and uses bare <span>s --
presumably because its Azan/Iqamah are computed offsets from sunset rather than fixed times:

      <li><span class="thm-clr">Maghrib</span>
          <span class=" start-time">8:15 PM</span>
          <span>08:16 PM</span>
          <span>08:18 PM</span></li>

Keying on the class silently dropped Maghrib. Instead every span in the row is read and the LAST
one that looks like a time is taken as Iqamah, which holds for both shapes. Sunrise has only a
start time and so is skipped by the "needs at least two times" rule.

Publishes sensor.masjid_quba_prayers with a `prayers` attribute:
    [{"name": "Fajr", "iqamah": "05:45 AM", "t24": "05:45"}, ...]

t24 is included so the card can work out the next prayer with a plain string comparison instead of
parsing 12-hour times in Jinja.

CACHING, AND WHY THIS RUNS HOURLY WHILE ONLY FETCHING ONCE A DAY:
Home Assistant FORGETS states set through the REST API when it restarts. A strictly daily job would
therefore leave the wall blank for up to 24 hours after any HA restart. So this runs hourly and
re-publishes from a local cache, only going to the network when the cache is not from today --
roughly one request per day to the mosque's site, with hourly resilience.

IF THE SITE IS UNREACHABLE the cached times are published anyway and the run still succeeds; the
card shows `last_updated_local` so stale times are visibly stale rather than silently wrong. Only a
failure with no cache at all is fatal. A mosque's website being down must not empty the board.
"""
import json
import os
import re
import sys
import urllib.request
from datetime import datetime

URL = os.environ.get("MASJID_URL", "https://www.ajaxmasjid.ca/")
# Under /opt/stack, not /var/lib: masn requires a password for sudo, so this is
# installed and scheduled entirely as the login user (see setup-masjid-times.sh).
CACHE = os.environ.get("MASJID_CACHE", "/opt/stack/state/masjid-prayer-times.json")
FRESH_HOURS = float(os.environ.get("MASJID_FRESH_HOURS", "6"))
HA = os.environ.get("HA_URL", "http://192.168.50.50:8123")
ENTITY = os.environ.get("MASJID_ENTITY", "sensor.masjid_quba_prayers")
# Sunrise appears in the same list but has no Iqamah, and is not a prayer -- excluded.
WANTED = ["Fajr", "Zuhr", "Asr", "Maghrib", "Isha"]

LI_RE = re.compile(r"<li[^>]*>(.*?)</li>", re.S | re.I)
NAME_RE = re.compile(r'<span[^>]*class="[^"]*thm-clr[^"]*"[^>]*>(.*?)</span>', re.S | re.I)
SPAN_RE = re.compile(r"<span[^>]*>(.*?)</span>", re.S | re.I)
TIME_RE = re.compile(r"^\d{1,2}:\d{2}\s*[AaPp][Mm]$")
TAG_RE = re.compile(r"<[^>]+>")


def text(s):
    return re.sub(r"\s+", " ", TAG_RE.sub("", s)).strip()


def to_24h(t):
    m = re.match(r"(\d{1,2}):(\d{2})\s*([AaPp])[Mm]", t.strip())
    if not m:
        return None
    h, mi, ap = int(m.group(1)), m.group(2), m.group(3).lower()
    if ap == "p" and h != 12:
        h += 12
    if ap == "a" and h == 12:
        h = 0
    return f"{h:02d}:{mi}"


def scrape(html):
    found = {}
    for li in LI_RE.findall(html):
        nm = NAME_RE.search(li)
        if not nm:
            continue
        name = text(nm.group(1))
        if name not in WANTED or name in found:
            continue
        times = [t for t in (text(sp) for sp in SPAN_RE.findall(li)) if TIME_RE.match(t)]
        # [start, azan, iqamah] -- Iqamah is the last. Sunrise has only a start, so it fails this
        # test and is skipped, which is what we want.
        if len(times) < 2:
            continue
        t24 = to_24h(times[-1])
        if not t24:
            continue
        found[name] = {"name": name, "iqamah": times[-1].upper(), "t24": t24}
    return [found[n] for n in WANTED if n in found]


def load_cache():
    try:
        with open(CACHE) as f:
            return json.load(f)
    except Exception:
        return None


def save_cache(prayers, day):
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    tmp = CACHE + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"day": day, "fetched": datetime.now().isoformat(timespec="seconds"),
                   "prayers": prayers}, f, indent=2)
    os.replace(tmp, CACHE)


def fetch():
    req = urllib.request.Request(URL, headers={
        "User-Agent": "SmartHome-wallpi/1.0 (home dashboard)"})
    with urllib.request.urlopen(req, timeout=30) as r:
        html = r.read().decode("utf-8", "replace")
    prayers = scrape(html)
    # All five or nothing: a partial scrape means the page changed, and half a board is worse than
    # yesterday's complete one.
    if len(prayers) != len(WANTED):
        got = [p["name"] for p in prayers]
        raise RuntimeError(f"scraped {len(prayers)}/{len(WANTED)} ({got}) -- page layout changed?")
    return prayers


def publish(prayers, fetched):
    if os.environ.get("DRY_RUN") == "1":
        print(json.dumps({"fetched": fetched, "prayers": prayers}, indent=2))
        return
    stamp = datetime.fromisoformat(fetched).strftime("%-d %b %H:%M")
    body = json.dumps({
        "state": prayers[0]["iqamah"],
        "attributes": {
            "friendly_name": "Masjid Quba Iqamah",
            "prayers": prayers,
            "source": URL,
            # The card shows this. If the site is unreachable the old times stay on the wall, and
            # this is the only thing that reveals they are stale rather than today's.
            "last_updated_local": stamp,
            "icon": "mdi:mosque",
        },
    }).encode()
    req = urllib.request.Request(
        f"{HA}/api/states/{ENTITY}", data=body, method="POST",
        headers={"Authorization": f"Bearer {os.environ['HA_TOKEN']}",
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        if r.status not in (200, 201):
            raise RuntimeError(f"HA returned {r.status}")


def main():
    today = datetime.now().strftime("%Y-%m-%d")
    cache = load_cache()
    # NOT "same calendar day". The mosque site rolls over to TOMORROW's times once Isha has passed,
    # so a day-keyed cache left the board showing times that had all already happened, from Isha
    # until midnight. Re-fetch if the cache is older than FRESH_HOURS -- about four network requests
    # a day, and the rollover is picked up within a couple of hours of it happening.
    fresh = False
    if cache:
        try:
            age = (datetime.now() - datetime.fromisoformat(cache["fetched"])).total_seconds() / 3600
            fresh = age < FRESH_HOURS and cache.get("day") == today
        except Exception:
            fresh = False

    if fresh and os.environ.get("FORCE") != "1":
        publish(cache["prayers"], cache["fetched"])
        print(f"republished today's cached times ({cache['fetched']})")
        return 0

    try:
        prayers = fetch()
    except Exception as e:
        if cache:
            # Exactly the requested behaviour: site down -> keep showing the last times we have.
            publish(cache["prayers"], cache["fetched"])
            print(f"!! fetch failed ({e}); republished cached times from {cache['fetched']}",
                  file=sys.stderr)
            return 0
        print(f"!! fetch failed ({e}) and no cache exists -- nothing to publish", file=sys.stderr)
        return 1

    fetched = datetime.now().isoformat(timespec="seconds")
    save_cache(prayers, today)
    publish(prayers, fetched)
    print("fetched and published: " + "  ".join(f"{p['name']} {p['iqamah']}" for p in prayers))
    return 0


sys.exit(main())
