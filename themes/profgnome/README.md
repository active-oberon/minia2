# ProfGnome skin

A2 skin (theme) for minia2, inspired by the **Prof-Gnome** GTK theme
(gnome-look.org/p/1334194, by Paulxfce) — a clean, old-school, *professional*
**light** theme. Reproduces the Prof-Gnome-Light palette as an A2 skin.

Full window chrome: a near-white gradient titlebar with a thin grey separator
and lightly rounded corners, light-grey borders with inactive variants, and
flat professional window controls (line glyphs; `close` hovers red `#cc0000`,
`minimize`/`maximize` hover blue `#3584e4`). Selection/accent is the Adwaita
blue `#3584e4`.

- `make_profgnome.py` — the palette + style config; regenerates
  `data/profgnome.skin` and refreshes `skin.bsl` here. Uses the shared
  `../skinkit.py` builder.
- `skin.bsl` — the generated Bluebottle Skin Language definition (kept in-tree
  for reference; the tar inside `profgnome.skin` carries its own copy).

Regenerate: `python3 themes/profgnome/make_profgnome.py` (needs Python + Pillow;
reuses cursor PNGs extracted to `/tmp/skinbuild/cursors/images`). A `preview.png`
is written next to the build output for eyeballing.

Installed as `data/profgnome.skin`, registered in `data/SkinList.XML`, and
packaged in `data/Release.Tool`. Select it at runtime via **Looks → Skin
Loader** (or `SkinEngine.Load profgnome.skin`).
