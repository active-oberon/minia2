#!/usr/bin/env python3
"""Generate procedural wallpapers for minia2 (space / sci-fi + abstract).

Everything is synthesised with numpy + Pillow — no external assets, no licences.
Nebulae use spectral (1/f^beta) fractal noise; abstracts use domain-warped
gradients. Palettes lean on Nord to match the default skins.

Outputs full-res PNGs into OUT, plus a montage.png contact sheet for review.
Master resolution is 2560x1440 (16:9); the A2 backdrop auto-scales to screen.
"""
import os, numpy as np
from PIL import Image, ImageFilter

W, H = 2560, 1440
OUT = "/tmp/skinbuild/wallpapers"
os.makedirs(OUT, exist_ok=True)


def fractal(h, w, beta, seed):
    """Spectral fractal noise field in [0,1] (1/f^beta)."""
    rng = np.random.default_rng(seed)
    white = rng.standard_normal((h, w))
    F = np.fft.fftshift(np.fft.fft2(white))
    fy = np.fft.fftshift(np.fft.fftfreq(h))[:, None]
    fx = np.fft.fftshift(np.fft.fftfreq(w))[None, :]
    r = np.sqrt(fx * fx + fy * fy)
    r[r == 0] = 1e-6
    F = F / (r ** (beta / 2.0))
    img = np.fft.ifft2(np.fft.ifftshift(F)).real
    img -= img.min(); img /= (img.max() + 1e-9)
    return img


def ramp(t, stops):
    """Map t in [0,1] (H,W) through colour stops -> (H,W,3) float 0..255.
    stops: list of (pos, (r,g,b))."""
    pos = np.array([s[0] for s in stops])
    cols = np.array([s[1] for s in stops], dtype=float)
    out = np.empty(t.shape + (3,), dtype=float)
    for c in range(3):
        out[..., c] = np.interp(t, pos, cols[:, c])
    return out


def stars(rgb, density, seed, bright=0.0018, flares=14):
    h, w, _ = rgb.shape
    rng = np.random.default_rng(seed)
    n = int(h * w * density)
    ys = rng.integers(0, h, n); xs = rng.integers(0, w, n)
    mag = rng.power(0.4, n)              # many faint, few bright
    col = 200 + 55 * rng.random(n)
    for y, x, m, c in zip(ys, xs, mag, col):
        v = c * m
        rgb[y, x] = np.minimum(255, rgb[y, x] + v)
    # a few bright stars with a soft glow + cross flare
    nb = int(h * w * bright)
    for _ in range(nb):
        y = rng.integers(20, h - 20); x = rng.integers(20, w - 20)
        tint = np.array([255, 250, 240]) if rng.random() < 0.7 else np.array([210, 225, 255])
        for r in range(6, 0, -1):
            a = 0.10 * (7 - r)
            y0, y1, x0, x1 = y - r, y + r + 1, x - r, x + r + 1
            rgb[y0:y1, x0:x1] = np.minimum(255, rgb[y0:y1, x0:x1] + tint * a * 0.15)
        rgb[y, x] = tint
    for _ in range(flares):
        y = rng.integers(40, h - 40); x = rng.integers(40, w - 40)
        L = int(rng.integers(30, 90))
        tint = np.array([200, 220, 255])
        for d in range(-L, L):
            fade = (1 - abs(d) / L) * 0.5
            xh = min(w - 1, max(0, x + d))
            yv = min(h - 1, max(0, y + d))
            rgb[y, xh] = np.minimum(255, rgb[y, xh] + tint * fade)
            rgb[yv, x] = np.minimum(255, rgb[yv, x] + tint * fade)
    return rgb


def vignette(rgb, strength=0.55):
    h, w, _ = rgb.shape
    yy = (np.linspace(-1, 1, h)[:, None]) ** 2
    xx = (np.linspace(-1, 1, w)[None, :]) ** 2
    d = np.sqrt(xx + yy) / np.sqrt(2)
    v = 1 - strength * (d ** 2)
    return rgb * v[..., None]


def blob(rgb, cx, cy, rx, ry, color, intensity, rot=0.0):
    """Add a soft elliptical galaxy/glow."""
    h, w, _ = rgb.shape
    yy, xx = np.mgrid[0:h, 0:w]
    xr = (xx - cx) * np.cos(rot) + (yy - cy) * np.sin(rot)
    yr = -(xx - cx) * np.sin(rot) + (yy - cy) * np.cos(rot)
    g = np.exp(-((xr / rx) ** 2 + (yr / ry) ** 2))
    rgb += np.array(color) * (g * intensity)[..., None]
    return rgb


def finish(rgb, name, blur=0.0):
    rgb = np.clip(rgb, 0, 255).astype(np.uint8)
    im = Image.fromarray(rgb, "RGB")
    if blur:
        im = im.filter(ImageFilter.GaussianBlur(blur))
    im.save(os.path.join(OUT, name))
    return im


# ---------------- 1. Nord nebula (blues / teal / violet) ----------------
def nord_nebula():
    dens = fractal(H, W, 3.0, 7)
    dens = dens ** 1.6
    hue = fractal(H, W, 2.4, 21)
    base = ramp(dens, [
        (0.00, (6, 9, 18)), (0.30, (24, 30, 54)), (0.55, (46, 74, 120)),
        (0.75, (94, 129, 172)), (0.90, (136, 192, 208)), (1.0, (216, 232, 240)),
    ])
    violet = ramp(hue, [(0.0, (0, 0, 0)), (0.5, (60, 40, 90)), (1.0, (180, 142, 173))])
    rgb = base + violet * (dens[..., None] * 0.5)
    rgb = blob(rgb, 1750, 560, 560, 340, (70, 100, 150), 0.35, rot=0.5)
    rgb = vignette(rgb, 0.5)
    rgb = stars(rgb, 0.010, 3)
    return finish(rgb, "nebula_nord.png")


# ---------------- 2. Ember nebula (warm magenta / gold) ----------------
def ember_nebula():
    dens = fractal(H, W, 3.2, 42) ** 1.7
    hue = fractal(H, W, 2.2, 99)
    base = ramp(dens, [
        (0.00, (10, 6, 12)), (0.28, (48, 18, 34)), (0.52, (122, 40, 66)),
        (0.72, (196, 76, 96)), (0.88, (224, 150, 96)), (1.0, (244, 214, 160)),
    ])
    gold = ramp(hue, [(0.0, (0, 0, 0)), (0.6, (80, 40, 20)), (1.0, (230, 180, 90))])
    rgb = base + gold * (dens[..., None] * 0.45)
    rgb = blob(rgb, 820, 800, 640, 380, (170, 70, 80), 0.32, rot=-0.4)
    rgb = vignette(rgb, 0.55)
    rgb = stars(rgb, 0.010, 8)
    return finish(rgb, "nebula_ember.png")


# ---------------- 3. Deep field (dark, elegant, galaxies) ----------------
def deep_field():
    dens = fractal(H, W, 3.6, 5) ** 2.2
    base = ramp(dens, [
        (0.0, (4, 5, 10)), (0.5, (10, 14, 26)), (0.8, (24, 34, 58)), (1.0, (70, 96, 140)),
    ])
    rgb = base
    rng = np.random.default_rng(123)
    for _ in range(6):
        cx = rng.integers(200, W - 200); cy = rng.integers(150, H - 150)
        rx = int(rng.integers(30, 90)); ry = int(rx * (0.4 + 0.5 * rng.random()))
        tint = [(120, 150, 210), (200, 170, 150), (150, 180, 200)][rng.integers(0, 3)]
        rgb = blob(rgb, cx, cy, rx, ry, tint, 0.5, rot=rng.random() * 3.14)
    rgb = vignette(rgb, 0.45)
    rgb = stars(rgb, 0.016, 77, bright=0.003, flares=22)
    return finish(rgb, "deep_field.png")


# ---------------- 4. Aurora (abstract flowing bands) ----------------
def aurora():
    yy, xx = np.mgrid[0:H, 0:W].astype(float)
    warp = fractal(H, W, 2.8, 314)
    phase = xx / W * 6.28 * 1.5 + warp * 6.0
    band = 0.5 + 0.5 * np.sin(phase + yy / H * 2.0)
    band = band ** 1.4
    height = np.clip(1.2 - yy / H, 0, 1)
    field = band * (0.4 + 0.9 * warp) * (0.5 + 0.7 * height)
    field = np.clip(field, 0, 1)
    base = ramp(field, [
        (0.00, (12, 16, 26)), (0.30, (30, 50, 70)), (0.55, (60, 140, 130)),
        (0.75, (120, 200, 160)), (0.90, (160, 200, 230)), (1.0, (200, 180, 220)),
    ])
    rgb = base
    rgb = stars(rgb, 0.004, 9, bright=0.0006, flares=4)
    return finish(rgb, "aurora.png", blur=1.2)


# ---------------- 5. Silk (domain-warped teal<->violet) ----------------
def silk():
    nx = fractal(H, W, 3.4, 11)
    ny = fractal(H, W, 3.4, 12)
    yy, xx = np.mgrid[0:H, 0:W].astype(float)
    u = xx / W + (nx - 0.5) * 0.6
    v = yy / H + (ny - 0.5) * 0.6
    t = 0.5 + 0.5 * np.sin(u * 6.28 * 2 + v * 6.28)
    t = (t * 0.6 + fractal(H, W, 3.0, 13) * 0.4)
    t = np.clip(t, 0, 1)
    base = ramp(t, [
        (0.00, (18, 22, 34)), (0.25, (36, 60, 92)), (0.5, (46, 130, 140)),
        (0.7, (94, 129, 172)), (0.85, (150, 120, 175)), (1.0, (224, 210, 230)),
    ])
    return finish(base, "silk.png", blur=0.8)


def montage(imgs):
    tw = 640; th = 360
    cols, rows = 3, 2
    sheet = Image.new("RGB", (tw * cols, th * rows), (0, 0, 0))
    for i, im in enumerate(imgs):
        t = im.resize((tw, th), Image.LANCZOS)
        sheet.paste(t, ((i % cols) * tw, (i // cols) * th))
    sheet.save(os.path.join(OUT, "montage.png"))
    print("montage:", os.path.join(OUT, "montage.png"))


if __name__ == "__main__":
    imgs = [nord_nebula(), ember_nebula(), deep_field(), aurora(), silk()]
    for n in ("nebula_nord", "nebula_ember", "deep_field", "aurora", "silk"):
        p = os.path.join(OUT, n + ".png")
        print(f"  {n:14} {os.path.getsize(p)//1024} KB")
    montage(imgs)
