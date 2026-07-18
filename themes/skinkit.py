#!/usr/bin/env python3
"""Shared toolkit for generating A2 skins from a palette/style config.

Used by themes/<name>/make_<name>.py. Produces the Bluebottle window chrome
tiles (top/bottom/left/right borders, close/minimize/maximize buttons in
active/inactive/hover states), writes skin.bsl, packages a .skin tar, and
renders a preview PNG so the look can be eyeballed without booting A2.

Needs Python + Pillow. Cursor PNGs are reused from an existing skin (extracted
to CURSORS by the caller / build step).
"""
import os, shutil, tarfile
from PIL import Image, ImageDraw

A = 255
CURSORS = "/tmp/skinbuild/cursors/images"   # arrow.png, move.png


# ---------- low-level image helpers ----------
def hx(rgb, a=A):
    """A2 BSL color literal: 0RRGGBBAA."""
    return "0%02X%02X%02X%02X" % (rgb[0], rgb[1], rgb[2], a)


def solid(w, h, rgb, a=A):
    return Image.new("RGBA", (w, h), tuple(rgb) + (a,))


def _lerp(c0, c1, t):
    return tuple(int(round(c0[i] + (c1[i] - c0[i]) * t)) for i in range(3))


def vgrad(w, h, top, bot, a=A):
    """Vertical gradient top->bottom."""
    im = Image.new("RGBA", (w, h))
    px = im.load()
    for y in range(h):
        c = _lerp(top, bot, y / max(1, h - 1)) + (a,)
        for x in range(w):
            px[x, y] = c
    return im


def hline(im, y, rgb, a=A, x0=0, x1=None):
    px = im.load()
    if x1 is None:
        x1 = im.size[0]
    for x in range(x0, x1):
        px[x, y] = tuple(rgb) + (a,)


def round_corner(im, corner, r):
    """Punch a transparent quarter-circle at one corner: 'tl','tr','bl','br'."""
    if r <= 0:
        return im
    w, h = im.size
    px = im.load()
    cx = r if "l" in corner else w - 1 - r
    cy = r if "t" in corner else h - 1 - r
    for y in range(h):
        for x in range(w):
            inside_x = (x <= cx) if "l" in corner else (x >= cx)
            inside_y = (y <= cy) if "t" in corner else (y >= cy)
            if inside_x and inside_y:
                if (x - cx) ** 2 + (y - cy) ** 2 > r * r:
                    px[x, y] = (0, 0, 0, 0)
    return im


# ---------- button builders ----------
def circle_button(size, diam, fill, glyph=None, glyph_color=(255, 255, 255),
                  ring=None):
    """Traffic-light style: filled circle centred in a size x size canvas.
    glyph: None | 'x' | '-' | '+'. ring: optional (rgb) outline for hollow look.
    """
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    m = (size - diam) // 2
    box = [m, m, m + diam - 1, m + diam - 1]
    if ring is not None:
        d.ellipse(box, outline=tuple(ring) + (A,), width=2)
    else:
        d.ellipse(box, fill=tuple(fill) + (A,))
    if glyph:
        c = tuple(glyph_color) + (A,)
        cx = size // 2
        cy = size // 2
        g = max(2, diam // 4)
        if glyph == "x":
            d.line([cx - g, cy - g, cx + g, cy + g], fill=c, width=2)
            d.line([cx + g, cy - g, cx - g, cy + g], fill=c, width=2)
        elif glyph == "-":
            d.line([cx - g, cy, cx + g, cy], fill=c, width=2)
        elif glyph == "+":
            d.line([cx - g, cy, cx + g, cy], fill=c, width=2)
            d.line([cx, cy - g, cx, cy + g], fill=c, width=2)
    return im


def flat_button(size, glyph, glyph_color, bg=None, radius=4):
    """Flat professional control: optional rounded-square bg + line glyph."""
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    if bg is not None:
        d.rounded_rectangle([2, 2, size - 3, size - 3], radius=radius,
                            fill=tuple(bg) + (A,))
    c = tuple(glyph_color) + (A,)
    cx = cy = size // 2
    g = max(3, size // 5)
    if glyph == "x":
        d.line([cx - g, cy - g, cx + g, cy + g], fill=c, width=2)
        d.line([cx + g, cy - g, cx - g, cy + g], fill=c, width=2)
    elif glyph == "-":
        d.line([cx - g, cy + g, cx + g, cy + g], fill=c, width=2)
    elif glyph == "[]":
        d.rectangle([cx - g, cy - g, cx + g, cy + g], outline=c, width=2)
    return im


# ---------- the main build ----------
def build(cfg, outdir):
    """cfg: dict describing the skin. Returns path to the built .skin."""
    img = os.path.join(outdir, "images")
    shutil.rmtree(outdir, ignore_errors=True)
    os.makedirs(img)

    H = cfg["barH"]          # titlebar height
    T = cfg["border"]        # side/bottom border thickness
    R = cfg["radius"]        # corner radius
    frame = cfg["frame"]     # border colour (side/bottom)
    tgrad = cfg["titleGrad"] # (top, bottom) rgb for active titlebar gradient
    igrad = cfg["inactiveGrad"]
    accent = cfg["accent"]   # bottom accent line under active titlebar
    edge = cfg.get("edge")   # optional 1px top inner highlight

    def save(im, name):
        im.save(os.path.join(img, name))

    # --- titlebar middle (tiled horizontally) ---
    tm = vgrad(8, H, *tgrad)
    if accent:
        hline(tm, H - 1, accent)
        hline(tm, H - 2, accent)
    if edge:
        hline(tm, 0, edge)
    save(tm, "atm.png")

    im = vgrad(8, H, *igrad)
    if accent:
        hline(im, H - 1, cfg["inactiveAccent"])
        hline(im, H - 2, cfg["inactiveAccent"])
    save(im, "itm.png")

    # --- titlebar caps (rounded top corners) ---
    W = cfg["capW"]
    for name, corner, grad, acc in (
        ("atl.png", "tl", tgrad, accent),
        ("atr.png", "tr", tgrad, accent),
        ("itl.png", "tl", igrad, cfg["inactiveAccent"]),
        ("itr.png", "tr", igrad, cfg["inactiveAccent"]),
    ):
        cap = vgrad(W, H, *grad)
        if acc:
            hline(cap, H - 1, acc)
            hline(cap, H - 2, acc)
        if edge:
            hline(cap, 0, edge)
        round_corner(cap, corner, R)
        save(cap, name)

    # --- side borders (tiled vertically) ---
    save(solid(T, 8, frame), "alm.png")
    save(solid(T, 8, frame), "arm.png")
    save(solid(T, 8, cfg["inactiveFrame"]), "ilm.png")
    save(solid(T, 8, cfg["inactiveFrame"]), "irm.png")

    # --- bottom border + rounded bottom caps ---
    save(solid(8, T, frame), "abm.png")
    save(solid(8, T, cfg["inactiveFrame"]), "ibm.png")
    for name, corner, col in (
        ("abl.png", "bl", frame), ("abr.png", "br", frame),
        ("ibl.png", "bl", cfg["inactiveFrame"]), ("ibr.png", "br", cfg["inactiveFrame"]),
    ):
        cap = solid(W, T + R, col)
        round_corner(cap, corner, R)
        save(cap, name)

    # --- window control buttons ---
    B = cfg["btn"]           # button canvas (square, == H looks best)
    style = cfg["btnStyle"]
    if style == "circle":
        d = cfg["btnDiam"]
        C = cfg["btnColors"]
        # active: solid dots, no glyph
        save(circle_button(B, d, C["close"]), "aclose.png")
        save(circle_button(B, d, C["min"]), "amin.png")
        save(circle_button(B, d, C["max"]), "amax.png")
        # hover: dot + glyph
        save(circle_button(B, d, C["close"], "x", C["glyph"]), "hclose.png")
        save(circle_button(B, d, C["min"], "-", C["glyph"]), "hmin.png")
        save(circle_button(B, d, C["max"], "+", C["glyph"]), "hmax.png")
        # inactive: hollow dim rings
        r = cfg["inactiveFrame"]
        save(circle_button(B, d, r, ring=r), "iclose.png")
        save(circle_button(B, d, r, ring=r), "imin.png")
        save(circle_button(B, d, r, ring=r), "imax.png")
    else:  # flat
        fg = cfg["btnGlyph"]
        hb = cfg["btnHoverBg"]     # {'close':..,'other':..}
        hg = cfg["btnHoverGlyph"]
        save(flat_button(B, "x", fg), "aclose.png")
        save(flat_button(B, "-", fg), "amin.png")
        save(flat_button(B, "[]", fg), "amax.png")
        save(flat_button(B, "x", hg, bg=hb["close"]), "hclose.png")
        save(flat_button(B, "-", hg, bg=hb["other"]), "hmin.png")
        save(flat_button(B, "[]", hg, bg=hb["other"]), "hmax.png")
        dim = cfg["inactiveFrame"]
        save(flat_button(B, "x", dim), "iclose.png")
        save(flat_button(B, "-", dim), "imin.png")
        save(flat_button(B, "[]", dim), "imax.png")

    # --- cursors (reused) ---
    for c in ("arrow.png", "move.png"):
        src = os.path.join(CURSORS, c)
        if os.path.exists(src):
            shutil.copy(src, os.path.join(img, c))

    # --- skin.bsl ---
    bsl = _bsl(cfg)
    with open(os.path.join(outdir, "skin.bsl"), "w") as f:
        f.write(bsl)

    # --- package tar ---
    skinpath = os.path.join(outdir, cfg["file"])
    with tarfile.open(skinpath, "w") as t:
        for f in sorted(os.listdir(img)):
            t.add(os.path.join(img, f), arcname="images/" + f)
        t.add(os.path.join(outdir, "skin.bsl"), arcname="skin.bsl")

    _preview(cfg, outdir)
    return skinpath


def _bsl(cfg):
    dt = cfg["desktop"]
    btn = cfg["component"]["button"]
    sb = cfg["component"]["scrollbar"]
    return f'''skin{{
	meta{{
		name : "{cfg['name']}";
		description : "{cfg['description']}";
		author : "minia2";
		date : "{cfg['date']}";
	}}
	window{{
		useBitmaps : true;
		title{{
			activeLeftMargin : {cfg['leftMargin']};
			activeTopMargin : {cfg['topMargin']};
			activeColor : {hx(cfg['titleText'])};
			activeCloseBitmap : "images/aclose.png";
			activeMinimizeBitmap : "images/amin.png";
			activeMaximizeBitmap : "images/amax.png";
			activeRestoreBitmap : "images/amax.png";
			hoverCloseBitmap : "images/hclose.png";
			hoverMinimizeBitmap : "images/hmin.png";
			hoverMaximizeBitmap : "images/hmax.png";
			inactiveLeftMargin : {cfg['leftMargin']};
			inactiveTopMargin : {cfg['topMargin']};
			inactiveColor : {hx(cfg['titleTextInactive'])};
			inactiveCloseBitmap : "images/iclose.png";
			inactiveMinimizeBitmap : "images/imin.png";
			inactiveMaximizeBitmap : "images/imax.png";
			inactiveRestoreBitmap : "images/imax.png";
			spaceBetweenButtons : {cfg['btnSpace']};
		}}
		top{{
			activeLeft : "images/atl.png";
			activeMiddle : "images/atm.png";
			activeRight : "images/atr.png";
			inactiveLeft : "images/itl.png";
			inactiveMiddle : "images/itm.png";
			inactiveRight : "images/itr.png";
		}}
		bottom{{
			activeLeft : "images/abl.png";
			activeMiddle : "images/abm.png";
			activeRight : "images/abr.png";
			inactiveLeft : "images/ibl.png";
			inactiveMiddle : "images/ibm.png";
			inactiveRight : "images/ibr.png";
		}}
		left{{ activeMiddle : "images/alm.png"; inactiveMiddle : "images/ilm.png"; }}
		right{{ activeMiddle : "images/arm.png"; inactiveMiddle : "images/irm.png"; }}
		desktop{{
			color : {hx(dt['color'])};
			bgColor : {hx(dt['bgColor'])};
			fgColor : {hx(dt['fgColor'])};
			selectColor : {hx(dt['selectColor'])};
		}}
	}}
	cursor{{
		default{{ bitmap : "images/arrow.png"; hotX : 0; hotY : 0; }}
		move{{ bitmap : "images/move.png"; hotX : 10; hotY : 10; }}
	}}
	component{{
		button{{
			bounds{{ height : 22; width : 64; }}
			clDefault : {hx(btn['default'])};
			clHover : {hx(btn['hover'])};
			clPressed : {hx(btn['pressed'])};
			clTextDefault : {hx(btn['text'])};
			clTextHover : {hx(btn['text'])};
			clTextPressed : {hx(btn['text'])};
			fontHeight : 12;
			effect3d : 0;
			useBgBitmaps : FALSE;
		}}
		scrollbar{{
			width : 14;
			minTrackerSize : 40;
			useTrackerBitmaps : FALSE;
			useArrowBitmaps : FALSE;
			useBackgroundBitmaps : FALSE;
			clDefault : {hx(sb['default'])};
			clHover : {hx(sb['hover'])};
			clPressed : {hx(sb['pressed'])};
			clBtnDefault : {hx(sb['btnDefault'])};
			clBtnHover : {hx(sb['btnHover'])};
			clBtnPressed : {hx(sb['btnPressed'])};
			effect3d : 0;
		}}
	}}
}}
'''


def _preview(cfg, outdir):
    """Render a mock active window over the desktop colour for eyeballing."""
    img = os.path.join(outdir, "images")

    def L(n):
        return Image.open(os.path.join(img, n)).convert("RGBA")

    H = cfg["barH"]
    T = cfg["border"]
    WIN_W, BODY_H = 340, 150
    dt = cfg["desktop"]
    canvas = Image.new("RGBA", (WIN_W + 40, H + BODY_H + T + 40), tuple(dt["bgColor"]) + (A,))

    x0, y0 = 20, 20
    atl, atm, atr = L("atl.png"), L("atm.png"), L("atr.png")
    capW = atl.size[0]
    # titlebar
    canvas.alpha_composite(atl, (x0, y0))
    x = x0 + capW
    while x < x0 + WIN_W - capW:
        canvas.alpha_composite(atm, (x, y0)); x += atm.size[0]
    canvas.alpha_composite(atr, (x0 + WIN_W - capW, y0))
    # body (base colour)
    body = solid(WIN_W - 2 * T, BODY_H, cfg["previewBody"])
    canvas.alpha_composite(body, (x0 + T, y0 + H))
    # side borders
    lm, rm = L("alm.png"), L("arm.png")
    yb = y0 + H
    while yb < y0 + H + BODY_H:
        canvas.alpha_composite(lm, (x0, yb)); canvas.alpha_composite(rm, (x0 + WIN_W - T, yb)); yb += lm.size[1]
    # bottom
    abl, abm, abr = L("abl.png"), L("abm.png"), L("abr.png")
    yB = y0 + H + BODY_H
    canvas.alpha_composite(abl, (x0, yB))
    x = x0 + abl.size[0]
    while x < x0 + WIN_W - abr.size[0]:
        canvas.alpha_composite(abm, (x, yB)); x += abm.size[0]
    canvas.alpha_composite(abr, (x0 + WIN_W - abr.size[0], yB))
    # buttons (right aligned)
    close, mn, mx = L("aclose.png"), L("amin.png"), L("amax.png")
    bx = x0 + WIN_W - capW - close.size[0] - 6
    for b in (close, mx, mn):
        canvas.alpha_composite(b, (bx, y0 + (H - b.size[1]) // 2)); bx -= b.size[0] + cfg["btnSpace"]
    # title text
    d = ImageDraw.Draw(canvas)
    d.text((x0 + cfg["leftMargin"], y0 + cfg["topMargin"] // 2 - 2),
           cfg["name"] + " — Active", fill=tuple(cfg["titleText"]) + (A,))
    canvas.convert("RGB").save(os.path.join(outdir, "preview.png"))
