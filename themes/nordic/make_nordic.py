#!/usr/bin/env python3
"""Generate the A2 'Nordic' skin (Nord palette, gnome-look Nordic inspired).

Full window chrome: gradient dark-slate titlebar with a frost accent line and
rounded top corners, matching side/bottom borders with inactive variants, and
traffic-light close/minimize/maximize buttons (Nord Aurora colours, glyph on
hover). Rebuilds data/nordic.skin. Needs Python + Pillow; reuses cursor PNGs.
"""
import os, sys, shutil
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import skinkit

# Nord palette
n0=(46,52,64); n1=(59,66,82); n2=(67,76,94); n3=(76,86,106)
n4=(216,222,233); n6=(236,239,244)
frost=(136,192,208)          # nord8
red=(191,97,106)             # nord11
yellow=(235,203,139)         # nord13
green=(163,190,140)          # nord14

CFG = {
    "name": "Nordic",
    "file": "nordic.skin",
    "description": "Nord-palette dark theme (gnome-look Nordic inspired)",
    "date": "2026-07-18",

    "barH": 26, "border": 3, "radius": 6, "capW": 12,
    "frame": n2, "inactiveFrame": n1,
    "titleGrad": (n2, n1), "inactiveGrad": (n1, n0),
    "accent": frost, "inactiveAccent": n3,
    "edge": n3,
    "titleText": n6, "titleTextInactive": n4,
    "leftMargin": 12, "topMargin": 17,

    "btnStyle": "circle", "btn": 26, "btnDiam": 14, "btnSpace": 8,
    "btnColors": {"close": red, "min": yellow, "max": green, "glyph": n0},

    "previewBody": n1,
    "desktop": {"color": frost, "bgColor": n0, "fgColor": n6, "selectColor": (94,129,172)},
    "component": {
        "button": {"default": (67,76,94), "hover": (76,86,106), "pressed": (94,129,172), "text": n6},
        "scrollbar": {"default": (59,66,82), "hover": (67,76,94), "pressed": (94,129,172),
                       "btnDefault": (76,86,106), "btnHover": frost, "btnPressed": (94,129,172)},
    },
}

if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    out = "/tmp/skinbuild/nordic"
    skinpath = skinkit.build(CFG, out)
    # copy generated artifacts back into the theme dir + data/
    shutil.copy(os.path.join(out, "skin.bsl"), os.path.join(here, "skin.bsl"))
    data = os.path.join(os.path.dirname(here), "..", "data", "nordic.skin")
    shutil.copy(skinpath, os.path.abspath(data))
    print("built", skinpath, os.path.getsize(skinpath), "bytes ->", os.path.abspath(data))
    print("preview:", os.path.join(out, "preview.png"))
