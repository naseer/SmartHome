#!/usr/bin/env python3
"""Rebuild the wall-display 'cameras' view as an explicit 3x3 grid with an info panel.

FONT SIZES ARE IN vh, NOT px. They were originally tuned in pixels against a 3840x2160 panel; when
the monitor was swapped for a 2560x1440 one on 2026-08-18 every size was suddenly 1.5x too large for
its cell and the status tiles overflowed into the camera tile below. vh scales with the display, so
this survives a monitor change. Anything sized in px here will break the next time one is swapped.

WHY layout-card: advanced-camera-card's own `display.mode: grid` is a MASONRY. Masonry always
leaves a ragged bottom, which is where the empty cell came from -- and a card cannot place anything
in its own empty cell. HA natively has no full-bleed layout engine with unequal columns
(horizontal-stack splits evenly, the classic grid card has no spans, sections cap their own width),
so the tiles are placed here by CSS grid-template-areas instead.

    drive drive info
    drive drive west
    back  east  front

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
  /* Hide scrollbars -- nobody can scroll a wall. NOTE: do NOT use `overflow: hidden` on * to do
     this. It also clips elements that overflow on purpose, which silently ate the "degC" the
     weather card renders as a superscript beside the temperature. Hiding the scrollbar itself is
     enough. */
  * { scrollbar-width: none !important; }
  *::-webkit-scrollbar { display: none !important; }
"""

GRID_CARD = {
    "type": "custom:advanced-camera-card",
    "cameras": [{
        # engine MUST be explicit. With no camera_entity there is nothing for the card to infer
        # from, and it fails with "Could not determine suitable engine for camera".
        # engine `frigate`, NOT `generic`: that makes the card build its MSE URL through Home
        # Assistant's existing Frigate proxy (/api/frigate/<client_id>/mse/...), which already
        # reaches the Orin's go2rtc. `generic` would need go2rtc's port 1984 published on the LAN,
        # and that port is an UNAUTHENTICATED admin API -- exactly what the :5000 lockdown exists to
        # prevent. This keeps the browser talking only to HA.
        "engine": "frigate",
        "frigate": {"client_id": "frigate"},
        # id MUST be explicit too: with no camera_entity the card cannot derive one and fails with
        # "Could not determine camera id ... may need to set 'id' parameter manually".
        "id": "wall_grid",
        "live_provider": "go2rtc",
        # mse only -- webrtc in this list caused constant renegotiation churn (2026-08-11)
        "go2rtc": {"modes": ["mse"], "stream": "wall_grid"},
    }],
    "live": {"lazy_load": False, "show_image_during_load": False,
             "controls": {"thumbnails": {"mode": "none"}}},
    "menu": {"style": "none"},
    "dimensions": {"aspect_ratio_mode": "unconstrained", "height": "100%"},
    "performance": {"features": {"animated_progress_indicator": False,
                                 "card_loading_effects": False}},
    # row-start / col-start / row-end / col-end -- spans the whole 3x3
    "view_layout": {"grid-area": "1 / 1 / 4 / 4"},
}

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
            # Clock and weather share one row: the clock is the thing you read from the doorway,
            # the weather is a glance, and the prayer table below needs the vertical space.
            "type": "horizontal-stack",
            "cards": [
                {
                    # now() re-renders every minute, so no automation or sensor is needed.
                    "type": "markdown",
                    "content": "# {{ now().strftime('%-I:%M') }}<small>{{ now().strftime('%p') | lower }}</small>\n### {{ now().strftime('%A, %-d %B') }}",
                    "card_mod": {"style": {
                        "ha-markdown $": """
  h1 { font-size: 3.5vh !important; line-height: 1 !important; margin: 0 !important;
       font-weight: 300 !important; letter-spacing: -3px !important; color: #ffffff !important; }
  /* am/pm rides at the end of the clock, much smaller so it does not compete with the digits */
  h1 small { font-size: 1.2vh !important; font-weight: 400 !important; letter-spacing: 0 !important;
             color: #b0b0b0 !important; margin-left: 6px !important; }
  h3 { font-size: 1.0vh !important; margin: 2px 0 0 0 !important; font-weight: 400 !important;
       color: #b0b0b0 !important; }
""",
                        ".": INFO_STYLE + "  ha-card { padding: 8px 4px 4px 16px !important; }",
                    }},
                },
                {
                    # A MARKDOWN CARD, NOT weather-forecast. The stock card lays out icon,
                    # condition and temperature as one horizontal strip, which put "Cloudy" on the
                    # temperature's baseline with a gap beside it -- and every attempt to move it
                    # meant fighting that card's internal CSS (it had already clipped the degree
                    # symbol once). Rendering the same three values as Markdown gives the exact
                    # shape of the clock opposite it: big number, small line beneath. Symmetric,
                    # and nothing to fight.
                    "type": "markdown",
                    "content": (
                        "{% set w = 'weather.forecast_home' %}"
                        "{% set t = state_attr(w,'temperature') %}"
                        "{% set h = state_attr(w,'humidity') %}"
                        # Stands in for the weather icon lost when this stopped being a
                        # weather-forecast card. Covers every state HA can report, so an unusual
                        # one never renders as a blank. NEEDS fonts-noto-color-emoji ON THE PI --
                        # without it the fallback is DejaVu Sans, which has flat outlines for one
                        # or two of these and TOFU BOXES for the rest.
                        "{% set icons = {"
                        "'clear-night':'\U0001F319','cloudy':'\u2601\uFE0F',"
                        "'exceptional':'\u26A0\uFE0F','fog':'\U0001F32B\uFE0F',"
                        "'hail':'\U0001F9CA','lightning':'\u26A1',"
                        "'lightning-rainy':'\u26C8\uFE0F','partlycloudy':'\u26C5',"
                        "'pouring':'\U0001F327\uFE0F','rainy':'\U0001F326\uFE0F',"
                        "'snowy':'\u2744\uFE0F','snowy-rainy':'\U0001F328\uFE0F',"
                        "'sunny':'\u2600\uFE0F','windy':'\U0001F4A8','windy-variant':'\U0001F4A8'"
                        "} %}"
                        "{% set e = icons.get(states(w), '') %}"
                        # states() gives the raw slug (partlycloudy); this is the human form
                        "{% set c = states(w) | replace('-',' ') | replace('partlycloudy','partly cloudy') | title %}"
                        "{% if t is not none %}"
                        "# {{ t | round(1) }}\u00b0\n"
                        "### {{ e }} {{ c }}{% if h is not none %} \u00b7 {{ h | round(0) }}%{% endif %}"
                        "{% else %}# --\n### Weather unavailable{% endif %}"
                    ),
                    "card_mod": {"style": {
                        "ha-markdown $": """
  /* Mirrors the clock's type exactly, right-aligned. */
  h1 { font-size: 3.5vh !important; line-height: 1 !important; margin: 0 !important;
       font-weight: 300 !important; letter-spacing: -3px !important; color: #ffffff !important;
       text-align: right !important; }
  h3 { font-size: 1.0vh !important; margin: 2px 0 0 0 !important; font-weight: 400 !important;
       color: #b0b0b0 !important; text-align: right !important; }
""",
                        ".": INFO_STYLE + "  ha-card { padding: 8px 16px 4px 4px !important; }",
                    }},
                },
            ],
        },
        {
            # Iqamah times scraped from ajaxmasjid.ca once a day by masn-stack/tools/
            # masjid-prayer-times.py. If the site is unreachable the last known times stay up and
            # the "updated" line below reveals they are stale -- a blank board would be worse.
            "type": "markdown",
            "content": (
                "#### Prayer Times &nbsp;·&nbsp; Masjid Quba\n"
                "{% set ps = state_attr('sensor.masjid_quba_prayers','prayers') %}"
                "{% if ps %}"
                "{% set t = now().strftime('%H:%M') %}"
                "{% set later = ps | selectattr('t24','gt',t) | list %}"
                # after Isha there is no "next" today, so fall back to tomorrow's Fajr
                "{% set nxt = (later | first).name if later else ps[0].name %}"
                # RAW HTML TABLE, not Markdown. A Markdown table REQUIRES a header row, and the
                # only way to have no visible header was `| | |` hidden with CSS -- which showed up
                # as a PHANTOM EMPTY ROW on any client where card-mod had not loaded. HTML needs no
                # header, so this now looks right even unstyled.
                "\n<table>"
                "{% for p in ps %}"
                "<tr><td>{% if p.name == nxt %}<strong>{{ p.name }}</strong>"
                "{% else %}{{ p.name }}{% endif %}</td>"
                "<td class='t'>{% if p.name == nxt %}<strong>{{ p.iqamah }}</strong>"
                "{% else %}{{ p.iqamah }}{% endif %}</td></tr>"
                "{% endfor %}"
                "</table>"
                "\n<small>updated {{ state_attr('sensor.masjid_quba_prayers','last_updated_local') }}</small>"
                "{% else %}\n_Prayer times unavailable_{% endif %}"
            ),
            "card_mod": {"style": {
                "ha-markdown $": """
  h4 { font-size: 0.9vh !important; margin: 0 0 4px 0 !important; font-weight: 500 !important;
       color: #7fd1b9 !important; letter-spacing: .4px !important; }
  /* HA's own markdown table rules outrank a bare `table` selector, which left the table narrow
     with default cell borders. Qualify with the wrapper so these actually win. */
  table, .content table, ha-markdown table {
      width: 100% !important; min-width: 100% !important;
      border-collapse: collapse !important; border: none !important; }
  /* the header is `| | |` -- two empty cells purely to make Markdown emit a table. HA's default
     styling still draws it, leaving a stray rule above Fajr. */
  thead, .content thead { display: none !important; }
  th, td, .content th, .content td { border: none !important; background: none !important; }
  td, .content td { font-size: 1.05vh !important; padding: 0.25vh 2px !important;
       border-bottom: 1px solid #202020 !important; color: #e8e8e8 !important; }
  td.t, .content td.t, td:last-child { text-align: right !important; }
  /* the next prayer is bolded by the template; make it unmistakable from across the room */
  td strong, .content td strong { color: #7fd1b9 !important; font-weight: 600 !important; }
  small { font-size: 0.62vh !important; color: #6e6e6e !important;
          display: block !important; margin-top: 0.2vh !important; }
""",
                ".": INFO_STYLE + "  ha-card { padding: 6px 16px 4px 16px !important; }",
            }},
        },
        {
            # TILES, NOT AN ENTITIES LIST. An entities card renders a `lock` as an ACTION BUTTON
            # showing the action available, so a LOCKED door displayed the word "Unlock" -- which
            # reads as the state, and reads exactly backwards, which is the worst thing a status
            # panel can do. Tiles show the STATE ("Locked").
            #
            # tap_action none on every tile: this is a wall panel in a hallway. It should never be
            # able to unlock the front door, and today it only cannot because the monitor happens to
            # have no touch input. Not relying on that.
            # ONE ROW OF FOUR, not 2x2. Two rows of tiles did not fit the cell on a 1440p display
            # and drew over the camera tile below; trimming padding got close but never all the way.
            # A single row halves the height they need, with margin to spare.
            "type": "grid",
            "columns": 4,
            "square": False,
            "cards": [
                {"type": "tile", "entity": "binary_sensor.garage_door_sensor_contact",
                 "name": "Garage", "tap_action": {"action": "none"},
                 "icon_tap_action": {"action": "none"}},
                {"type": "tile", "entity": "lock.aqara_smart_lock_u200_us",
                 "name": "Front door", "tap_action": {"action": "none"},
                 "icon_tap_action": {"action": "none"}},
                {"type": "tile", "entity": "sensor.thermostat_hub_w200_temperature",
                 "name": "Indoor", "tap_action": {"action": "none"},
                 "icon_tap_action": {"action": "none"}},
                {"type": "tile", "entity": "sensor.dining_room_thermostat_hub_w200_humidity",
                 "name": "Humidity", "tap_action": {"action": "none"},
                 "icon_tap_action": {"action": "none"}},
            ],
            # Tile cards carry an intrinsic minimum height that vh font sizes do not affect, so on
            # a shorter display they overflowed the cell and drew over the camera tile below.
            # min-height:0 plus tightened padding lets them shrink with everything else.
            "card_mod": {"style": {
                "hui-tile-card $": """
  ha-card { background: rgba(255,255,255,0.06) !important; border: none !important;
            box-shadow: none !important; border-radius: 6px !important;
            min-height: 0 !important; }
  .content { padding: 0.5vh 0.8vh !important; min-height: 0 !important; }
  ha-tile-icon { --tile-icon-size: 2.2vh !important; }
  .primary { font-size: 0.85vh !important; line-height: 1.2 !important; }
  .secondary { font-size: 0.75vh !important; line-height: 1.2 !important; }
""",
                ".": """
  #root { gap: 0.4vh !important; }
""",
            }},
        },
    ],
    # top-right cell, drawn OVER the video's black corner
    "view_layout": {"grid-area": "1 / 3 / 2 / 4"},
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
            "grid-template-areas": '"drive drive info" "drive drive west" "back east front"',
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
        # ONE video layer, not five. The grid is composited on the Orin (orin-stack/wall-grid),
        # which took the Pi's renderer from painting five live videos to painting one. Line-based
        # grid-area lets the two cards OVERLAP: the video covers all 9 cells, and the info panel
        # sits on top of the black cell the compositor deliberately leaves at the top right.
        "cards": [GRID_CARD, INFO_CARD],
    }
    cfg["views"] = [view] + [v for v in cfg["views"] if v.get("path") != "cameras"]
    json.dump(cfg, open(sys.argv[2], "w"), indent=2)
    print(f"  wrote {len(view['cards'])} cards into a 3x3 grid; views="
          f"{[v['path'] for v in cfg['views']]}")


main()
