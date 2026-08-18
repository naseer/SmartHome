#!/usr/bin/env python3
"""Rebuild the wall-display 'cameras' view as an explicit 3x3 grid with an info panel.

WHY layout-card: advanced-camera-card's own `display.mode: grid` is a MASONRY. Masonry always
leaves a ragged bottom, which is where the empty cell came from -- and a card cannot place anything
in its own empty cell. HA natively has no full-bleed layout engine with unequal columns
(horizontal-stack splits evenly, the classic grid card has no spans, sections cap their own width),
so the tiles are placed here by CSS grid-template-areas instead.

    drive drive front
    drive drive west
    back  east  info

On the 3840x2160 panel every cell is 1280x720 and driveway spans 2x2 = 2560x1440 = 1.78, which is
almost exactly its stream's 1.75 -- the hero tile shows its full scene with no crop worth seeing.
"""
import json, sys

# name, entity, stream, grid-area, fit, optional crop anchor
CAMERAS = [
    ("driveway",   "camera.driveway",   "driveway_sub",   "drive", "cover"),
    # front_door is 640x480 (4:3) in a 16:9 cell, so it cannot both fill the cell and show its
    # whole frame. `contain` keeps the whole porch view AND its OSD clock (so tile-watchdog can see
    # this tile), at the cost of pillarbox bars -- which the wallpi-black theme paints black, so
    # they read as part of the surround rather than as missing video.
    ("front_door", "camera.front_door", "front_door_sub", "front", "contain"),
    ("west_gate",  "camera.west_gate",  "west_gate_sub",  "west",  "cover"),
    ("east_gate",  "camera.east_gate",  "east_gate_sub",  "east",  "cover"),
    # 1536x576 (2.67:1) into a 1.78 cell: `cover` crops the sides. Change this one to "contain" to
    # see the whole patio with letterbox bars instead.
    ("backyard",   "camera.backyard",   "backyard_sub",   "back",  "cover"),
]


def camera_card(name, entity, stream, area, fit, position=None):
    return {
        "type": "custom:advanced-camera-card",
        "cameras": [{
            "camera_entity": entity,
            "live_provider": "go2rtc",
            # mse only -- webrtc in this list caused constant renegotiation churn (2026-08-11).
            "go2rtc": {"modes": ["mse"], "stream": stream},
            # The video element's object-fit comes from the CAMERA's dimensions.layout, not from
            # live.layout -- setting it on `live` left every tile letterboxed.
            "dimensions": {"layout": dict({"fit": fit}, **({"position": position} if position else {}))},
        }],
        "live": {
            "lazy_load": False,
            # fetches a still per camera while the stream starts; this is what made the wall look
            # like "a bunch of videos buffering", and drove the latest.jpg polling.
            "show_image_during_load": False,
            "controls": {"thumbnails": {"mode": "none"}},
        },
        "menu": {"style": "none"},
        # Fill the grid cell rather than imposing the stream's aspect ratio and leaving a gap.
        "dimensions": {"aspect_ratio_mode": "unconstrained", "height": "100%"},
        "performance": {"features": {
            "animated_progress_indicator": False,
            "card_loading_effects": False,
        }},
        # HA cards are white in the light theme, so anything the video does not cover shows as a
        # WHITE bar -- most visibly the pillarbox either side of front_door, which is `contain`.
        # Black reads as the frame of a video wall instead of a missing tile.
        "card_mod": {"style": """
  ha-card {
    background: #000 !important;
    border: none !important;
    box-shadow: none !important;
    border-radius: 0 !important;
  }
"""},
        "view_layout": {"grid-area": area},
    }


# Styled with card-mod because the stock cards render as a BRIGHT WHITE BLOCK with ~8px text on a
# 4K panel -- glaring next to five dark video tiles, and unreadable from across a room, which is the
# only distance this screen is ever viewed from. Dark translucent background + much larger type.
INFO_STYLE = """
  ha-card {
    background: rgba(0, 0, 0, 0.72) !important;
    color: #f0f0f0 !important;
    border: none !important;
    box-shadow: none !important;
    border-radius: 0 !important;
  }
  ha-card * { color: #f0f0f0 !important; }
  /* a scrollbar on a wall display is just visual noise -- nobody can scroll it */
  * { overflow: hidden !important; scrollbar-width: none !important; }
  *::-webkit-scrollbar { display: none !important; }
"""

INFO_CARD = {
    "type": "vertical-stack",
    # Fills the cell and paints it black, so the panel reads as part of the wall rather than as a
    # floating white card with a gap under it.
    "card_mod": {"style": {".":
        # A vertical-stack sizes each child to its content, so the last card stopped short and left
        # a white strip. Flex column + flex:1 on the last child stretches it to the cell floor.
        ":host { height: 100%; }"
        " #root { height: 100%; display: flex; flex-direction: column; background: #000; }"
        " #root > *:last-child { flex: 1 1 auto; }"}},
    "cards": [
        {
            # A wall display should answer "what time is it" without anyone walking up to it.
            # now() re-renders every minute, so no automation or sensor is needed.
            "type": "markdown",
            "content": "# {{ now().strftime('%-I:%M') }}\n### {{ now().strftime('%A, %-d %B') }}",
            "card_mod": {"style": {
                "ha-markdown $": """
  h1 { font-size: 92px !important; line-height: 1 !important; margin: 0 !important;
       font-weight: 300 !important; letter-spacing: -3px !important; color: #ffffff !important; }
  h3 { font-size: 27px !important; margin: 4px 0 0 0 !important; font-weight: 400 !important;
       color: #b0b0b0 !important; }
""",
                ".": INFO_STYLE + "  ha-card { padding: 10px 16px 6px 16px !important; }",
            }},
        },
        {
            "type": "weather-forecast",
            "entity": "weather.forecast_home",
            "forecast_type": "daily",
            "show_current": True,
            "show_forecast": True,
            "card_mod": {"style": INFO_STYLE + """
  .content, .forecast { font-size: 21px !important; }
  .temp { font-size: 32px !important; }
  ha-card { padding: 8px 12px 2px 12px !important; }
"""},
        },
        {
            "type": "entities",
            "show_header_toggle": False,
            "entities": [
                {"entity": "binary_sensor.garage_door_sensor_contact", "name": "Garage"},
                {"entity": "lock.aqara_smart_lock_u200_us", "name": "Front door"},
                {"entity": "sensor.thermostat_hub_w200_temperature", "name": "Indoor"},
                {"entity": "sensor.dining_room_thermostat_hub_w200_humidity", "name": "Humidity"},
            ],
            "card_mod": {"style": INFO_STYLE + """
  #states { padding: 0 !important; }
  .card-content { font-size: 25px !important; padding: 4px 12px !important; }
  state-badge { width: 34px !important; height: 34px !important; }
"""},
        },
    ],
    "view_layout": {"grid-area": "info"},
}


def main():
    cfg = json.load(open(sys.argv[1]))
    view = {
        "title": "Cameras",
        "path": "cameras",
        "icon": "mdi:cctv",
        "type": "custom:grid-layout",
        # Scoped to THIS view: the family's phones keep the normal light theme.
        "theme": "wallpi-black",
        "layout": {
            "grid-template-columns": "repeat(3, minmax(0, 1fr))",
            "grid-template-rows": "repeat(3, minmax(0, 1fr))",
            "grid-template-areas": '"drive drive front" "drive drive west" "back east info"',
            # Fill the panel exactly. Without an explicit height the 1fr rows collapse to content
            # height and the wall floats in the top of the screen.
            "height": "100vh",
            "margin": "0",
            "padding": "0",
            # NO GAP. A gap shows the grid container's background between tiles, and that background
            # renders WHITE -- setting `background` here, the view's background, and the HA theme
            # variables all failed to colour it, the same dead end as the pillarbox bars. Zero gap
            # means there is nothing to colour: the tiles butt together as one continuous surface,
            # which is what a video wall should look like anyway.
            # BOTH SPELLINGS: `grid-gap` alone was ignored and left an 8px gap that nobody asked
            # for, showing HA's #fafafa page background between the tiles as white seams.
            "grid-gap": "0",
            "gap": "0",
            "--masonry-view-card-margin": "0",
            "background": "#000000",
        },
        "cards": [camera_card(*c) for c in CAMERAS] + [INFO_CARD],
    }
    cfg["views"] = [view] + [v for v in cfg["views"] if v.get("path") != "cameras"]
    json.dump(cfg, open(sys.argv[2], "w"), indent=2)
    print(f"  wrote {len(view['cards'])} cards into a 3x3 grid; views="
          f"{[v['path'] for v in cfg['views']]}")


main()
