#!/usr/bin/env python3
"""Generate the A2 'ProfGnome' skin (light, Prof-Gnome GTK theme inspired).

Prof-Gnome by Paulxfce (gnome-look.org/p/1334194) is a clean, old-school,
professional *light* theme. This reproduces its Light variant palette as an A2
skin: near-white gradient titlebar with a thin grey separator and lightly
rounded corners, light-grey borders, and flat professional window controls
(line glyphs; close hovers red #cc0000, min/max hover blue #3584e4).
Rebuilds data/profgnome.skin. Needs Python + Pillow; reuses cursor PNGs.
"""
import os, sys, shutil
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import skinkit

# Prof-Gnome-Light palette (from gtk.css @define-color)
text=(37,37,37)          # #252525
fg=(54,54,54)            # #363636
bg=(230,230,230)         # #e6e6e6
base=(255,255,255)       # #ffffff
blue=(53,132,228)        # #3584e4  selection / accent
red=(204,0,0)            # #cc0000  error / close hover
borders=(205,205,205)    # #cdcdcd
ub=(213,208,204)         # #d5d0cc  unfocused borders
unfocused_fg=(146,149,149) # #929595
title_top=(250,250,250)
title_bot=(238,238,238)

CFG = {
    "name": "ProfGnome",
    "file": "profgnome.skin",
    "description": "Light Prof-Gnome inspired theme (professional, old-school)",
    "date": "2026-07-18",

    "barH": 26, "border": 2, "radius": 3, "capW": 10,
    "frame": borders, "inactiveFrame": ub,
    "titleGrad": (title_top, title_bot), "inactiveGrad": ((246,246,246), (240,240,240)),
    "accent": borders, "inactiveAccent": ub,
    "edge": base,
    "titleText": fg, "titleTextInactive": unfocused_fg,
    "leftMargin": 12, "topMargin": 17,

    "btnStyle": "flat", "btn": 26, "btnSpace": 6,
    "btnGlyph": (90,90,90), "btnHoverGlyph": base,
    "btnHoverBg": {"close": red, "other": blue},

    "previewBody": base,
    "desktop": {"color": blue, "bgColor": bg, "fgColor": text, "selectColor": blue},
    "component": {
        "button": {"default": bg, "hover": (216,216,216), "pressed": blue, "text": text},
        "scrollbar": {"default": (220,220,220), "hover": borders, "pressed": blue,
                       "btnDefault": (192,192,192), "btnHover": blue, "btnPressed": blue},
    },
}

if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    out = "/tmp/skinbuild/profgnome"
    skinpath = skinkit.build(CFG, out)
    shutil.copy(os.path.join(out, "skin.bsl"), os.path.join(here, "skin.bsl"))
    data = os.path.join(os.path.dirname(here), "..", "data", "profgnome.skin")
    shutil.copy(skinpath, os.path.abspath(data))
    print("built", skinpath, os.path.getsize(skinpath), "bytes ->", os.path.abspath(data))
    print("preview:", os.path.join(out, "preview.png"))
