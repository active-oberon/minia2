# Wallpapers

Desktop backdrops for minia2. Two sources:

## 1. Procedural — `nebula_nord.png` (the startup default)

Synthesised with numpy + Pillow — no external assets, no licences. A blue
deep-space nebula (spectral 1/f^β fractal-noise gas clouds + a power-law
starfield + soft galaxy glow + vignette), palette tuned to Nord to match the
default skin.

Regenerate: `python3 themes/wallpapers/make_wallpapers.py` — it also emits
ember / deep-field / aurora / silk variants and a `montage.png` contact sheet to
`/tmp/skinbuild/wallpapers` for review; only `nebula_nord.png` is installed by
default. Tweak palettes / seeds in the config functions to taste.

## 2. gnome-look wallpapers — `wp_*.jpg`

16 wallpapers pulled from gnome-look.org (highest-res non-watermarked image per
product), resized to 2560px wide, saved as JPEG q90. Provenance (source page +
picked file per image) is in `gnome_look.txt`. These are third-party,
user-uploaded artworks — each keeps its uploader's gnome-look licence; bundled
for a personal desktop build.

## Wiring

Master resolution 2560×1440 (16:9). A2's backdrop `Draw` auto-scales the image
to the screen (`source/WMBackdrop.Mod`), so keep new art at the screen aspect
ratio to avoid stretching.

Installed into `data/`, registered in `data/BackdropList.XML` (curated menu:
Nebula + the 16), packaged in `data/Release.Tool`. Startup backdrop is the
Autostart line of `data/Configuration.XML`
(`WMBackdrop.SetBackdropImage nebula_nord.png ? ? ? ?`), and that line is also where
a pick is remembered: switching at runtime via the desktop right-click **Backdrops**
menu replaces the backdrop and writes the new line, so the choice survives a restart.
`WMBackdrop.AddBackdropImage` still adds one without replacing or remembering -- that
is the one to use for tiling several across a wide screen.

Stock A2 backdrops (`mars.png`, `BluebottlePic0.png`, `SaasFee.jpg`, `*.jp2`)
remain in `data/` but are de-listed from the menu; re-add `<Look>` lines to
`BackdropList.XML` to bring them back.
