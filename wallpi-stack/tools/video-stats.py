#!/usr/bin/env python3
"""Ask Chromium what its video elements are actually doing.

The OSD-clock sampler only ticks once a second, so it cannot see sub-second stutter, dropped frames
or short rebuffers. This attaches to the kiosk over the DevTools protocol and counts the events the
browser itself fires -- `waiting` and `stalled` -- plus dropped-vs-total frames and readyState,
which is the ground truth for "is it buffering".
"""
import asyncio, json, sys, urllib.request
import websockets

SECONDS = int(sys.argv[1]) if len(sys.argv) > 1 else 60

INSTALL = r"""
(() => {

const allVideos = (root, out) => {
  out = out || [];
  (root.querySelectorAll ? root.querySelectorAll('*') : []).forEach(el => {
    if (el.tagName === 'VIDEO') out.push(el);
    if (el.shadowRoot) allVideos(el.shadowRoot, out);
  });
  return out;
};
  const vids = allVideos(document);
  // always re-register: a previous run may have created an empty stats object before
  // the video elements existed, leaving no listeners attached
  {
    window.__wallstats = {};
    vids.forEach((v, i) => {
      window.__wallstats[i] = {waiting: 0, stalled: 0, emptied: 0, suspend: 0};
      v.addEventListener('waiting',  () => window.__wallstats[i].waiting++);
      v.addEventListener('stalled',  () => window.__wallstats[i].stalled++);
      v.addEventListener('emptied',  () => window.__wallstats[i].emptied++);
      v.addEventListener('suspend',  () => window.__wallstats[i].suspend++);
    });
  }
  return vids.length;
})()
"""

SAMPLE = r"""
(() => {

const allVideos = (root, out) => {
  out = out || [];
  (root.querySelectorAll ? root.querySelectorAll('*') : []).forEach(el => {
    if (el.tagName === 'VIDEO') out.push(el);
    if (el.shadowRoot) allVideos(el.shadowRoot, out);
  });
  return out;
};
  const vids = allVideos(document);
  return JSON.stringify(vids.map((v, i) => {
    const q = v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality() : {};
    let ahead = null;
    if (v.buffered.length) ahead = v.buffered.end(v.buffered.length - 1) - v.currentTime;
    const s = (window.__wallstats && window.__wallstats[i]) || {};
    return {i, w: v.videoWidth, h: v.videoHeight, rs: v.readyState, ct: v.currentTime,
            total: q.totalVideoFrames, dropped: q.droppedVideoFrames, ahead: ahead,
            waiting: s.waiting || 0, stalled: s.stalled || 0, emptied: s.emptied || 0};
  }));
})()
"""


async def main():
    tgts = json.load(urllib.request.urlopen("http://127.0.0.1:9223/json", timeout=10))
    page = next(t for t in tgts if t.get("type") == "page")
    ws_url = page["webSocketDebuggerUrl"]

    async with websockets.connect(ws_url, max_size=16 * 1024 * 1024) as ws:
        mid = 0
        async def ev(expr):
            nonlocal mid
            mid += 1
            await ws.send(json.dumps({"id": mid, "method": "Runtime.evaluate",
                                      "params": {"expression": expr, "returnByValue": True}}))
            while True:
                r = json.loads(await ws.recv())
                if r.get("id") == mid:
                    return r.get("result", {}).get("result", {}).get("value")

        n = await ev(INSTALL)
        print(f"  attached to {n} video elements; sampling {SECONDS}s")
        first = json.loads(await ev(SAMPLE))
        await asyncio.sleep(SECONDS)
        last = json.loads(await ev(SAMPLE))

        # each camera has a distinct sub-stream size, so dimensions name the tile
        NAMES = {(896, 512): "driveway", (640, 480): "front_door",
                 (1536, 576): "backyard", (640, 360): "gate(w/e)"}
        print(f"  {'tile':<12}{'frames':>9}{'dropped':>9}{'drop%':>7}{'waiting':>9}{'stalled':>9}{'rs':>4}{'ahead':>8}")
        for a, b in zip(first, last):
            name = NAMES.get((b["w"], b["h"]), f'{b["w"]}x{b["h"]}')
            df = (b["dropped"] or 0) - (a["dropped"] or 0)
            tf = (b["total"] or 0) - (a["total"] or 0)
            pct = (100.0 * df / tf) if tf else 0.0
            print(f"  {name:<12}{tf:>9}{df:>9}{pct:>6.1f}%{(b['waiting'] or 0)-(a['waiting'] or 0):>9}"
                  f"{(b['stalled'] or 0)-(a['stalled'] or 0):>9}{b['rs']:>4}"
                  f"{(b['ahead'] or 0):>7.1f}s")
        print("\n  rs: 4=HAVE_ENOUGH_DATA (healthy). waiting/stalled counts are visible rebuffers.")
        print(f"  expected frames in {SECONDS}s at 10fps: ~{SECONDS*10}")

asyncio.run(main())
