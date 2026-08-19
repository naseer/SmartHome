#!/usr/bin/env python3
"""Lower every camera's SUB-STREAM frame rate to what Frigate actually consumes.

WHY: Frigate samples sub-streams at `detect.fps` (5 here). A camera pushing 15-20 fps therefore
makes the Orin decode -- and the wall display Pi decode again -- three to four times more frames
than anything uses. Decode cost scales with frames x pixels, so halving the frame rate is worth as
much as halving the resolution, and costs no image quality per frame at all.

RESOLUTION IS USUALLY NOT ADJUSTABLE. Reolink reports the allowed sub-stream `size` as a single
fixed value rather than a list (checked per camera below), so frames are the only lever.

RECORDING IS NOT AFFECTED. Only the sub-stream is touched; recording uses the main stream.

THE API IS HTTPS-ONLY -- plain http 302-redirects and the response will not parse. That one detail
blocked camera automation here for a week.

    ./tune-substreams.py --dry-run      show what would change
    ./tune-substreams.py                apply
    ./tune-substreams.py --fps 7        target a different rate

AFTER APPLYING, RESTART FRIGATE. Changing encoder parameters leaves go2rtc serving the old stream
description, so ffmpeg fails with "Invalid data found when processing input" and cameras
crash-loop -- including ones you did not touch. `docker restart frigate` on the Orin clears it.
"""
import argparse
import json
import os
import ssl
import sys
import urllib.request

CAMERAS = {
    "driveway":   "192.168.50.86",
    "front_door": "192.168.50.151",
    "west_gate":  "192.168.50.22",
    "east_gate":  "192.168.50.130",
    "backyard":   "192.168.50.217",
}

# Frigate's detect.fps is 5. Ten leaves comfortable headroom for it to pick frames without the
# camera sending three times more than anyone reads.
DEFAULT_FPS = 10
MIN_USABLE_FPS = 7          # never drop to where Frigate's 5 fps detect could starve

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def api(ip, cmd, payload, token=None):
    url = f"https://{ip}/cgi-bin/api.cgi?cmd={cmd}" + (f"&token={token}" if token else "")
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=20, context=CTX) as r:
        return json.loads(r.read().decode())


def login(ip, pw):
    r = api(ip, "Login", [{"cmd": "Login", "action": 0,
                           "param": {"User": {"Version": "0", "userName": "admin", "password": pw}}}])
    return r[0]["value"]["Token"]["name"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--fps", type=int, default=DEFAULT_FPS)
    ap.add_argument("--only", help="comma-separated camera names")
    ap.add_argument("--max-bitrate", action="store_true",
                    help="also raise each sub-stream to the highest bitrate the camera allows")
    args = ap.parse_args()

    pw = os.environ["FRIGATE_RTSP_PASSWORD"]
    names = args.only.split(",") if args.only else list(CAMERAS)
    changed = 0

    for name in names:
        ip = CAMERAS[name]
        try:
            tok = login(ip, pw)
            cur = api(ip, "GetEnc", [{"cmd": "GetEnc", "action": 0, "param": {"channel": 0}}],
                      tok)[0]["value"]["Enc"]["subStream"]
            rng = api(ip, "GetEnc", [{"cmd": "GetEnc", "action": 1, "param": {"channel": 0}}],
                      tok)[0]["range"]["Enc"]
            rng = (rng[0] if isinstance(rng, list) else rng)["subStream"]
        except Exception as e:
            print(f"  {name:11s} !! {e}")
            continue

        allowed = rng.get("frameRate") or []
        size_opts = rng.get("size")
        # Pick the closest allowed rate at or above the target, else the highest that is still
        # usable. Never go below MIN_USABLE_FPS -- Frigate's detect would start starving.
        candidates = sorted(x for x in allowed if x >= MIN_USABLE_FPS)
        target = min(candidates, key=lambda x: abs(x - args.fps)) if candidates else cur["frameRate"]

        note = ""
        if not isinstance(size_opts, list):
            note = f"  (size fixed at {size_opts})"

        if cur["frameRate"] == target and cur.get("gop") == 1:
            print(f"  {name:11s} already {cur['size']} @ {target}fps gop1 -- nothing to do{note}")
            continue

        print(f"  {name:11s} {cur['size']} {cur['frameRate']}fps gop{cur.get('gop')} "
              f"-> {target}fps gop1  (allowed {allowed}){note}")
        if args.dry_run:
            continue

        body = {k: cur[k] for k in ("bitRate", "profile", "size", "vType") if k in cur}
        # Bitrate matters more than it looks. front_door shipped at 256 kbps for a 640x480 frame --
        # 33% more pixels than the 640x360 gates on the SAME budget -- and looked visibly broken
        # while they looked fine. The allowed ceiling differs per model (512 on the gates and
        # front_door, 1228 on driveway, 2048 on backyard), so take each camera's own maximum.
        if args.max_bitrate and isinstance(rng.get("bitRate"), list) and rng["bitRate"]:
            body["bitRate"] = max(rng["bitRate"])
        body["frameRate"] = target
        body["gop"] = 1          # 1s keyframes: MSE can only start/recover on a keyframe
        r = api(ip, "SetEnc",
                [{"cmd": "SetEnc", "action": 0,
                  "param": {"Enc": {"channel": 0, "subStream": body}}}], tok)
        code = r[0].get("value", {}).get("rspCode") or r[0].get("error")
        back = api(ip, "GetEnc", [{"cmd": "GetEnc", "action": 0, "param": {"channel": 0}}],
                   tok)[0]["value"]["Enc"]["subStream"]
        ok = back["frameRate"] == target and back.get("gop") == 1
        print(f"              rsp={code}  read-back {back['frameRate']}fps gop{back.get('gop')} "
              f"{'OK' if ok else '!! MISMATCH'}")
        changed += ok

    if changed and not args.dry_run:
        print(f"\n>> {changed} camera(s) changed. NOW RESTART FRIGATE on the Orin:")
        print("     ssh nvidia@orin.internal 'docker restart frigate'")
        print("   go2rtc otherwise keeps serving the old stream description and cameras crash-loop.")
    return 0


sys.exit(main())
