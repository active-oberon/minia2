# Nordic skin

A2 skin (theme) for minia2, inspired by the popular **Nordic** GTK theme
(gnome-look.org, by EliverLara), built on the **Nord** color palette.

Full window chrome: a gradient dark-slate titlebar with a frost accent line and
rounded top corners, matching side/bottom borders with proper inactive
variants, and traffic-light `close`/`minimize`/`maximize` buttons in Nord
Aurora colours (red / yellow / green; glyph shown on hover).

- `make_nordic.py` — the palette + style config; regenerates `data/nordic.skin`
  and refreshes `skin.bsl` here. Uses the shared `../skinkit.py` builder.
- `skin.bsl` — the generated Bluebottle Skin Language definition (kept in-tree
  for reference; the tar inside `nordic.skin` carries its own copy).

Regenerate: `python3 themes/nordic/make_nordic.py` (needs Python + Pillow;
reuses cursor PNGs extracted to `/tmp/skinbuild/cursors/images`). A `preview.png`
is written next to the build output for eyeballing.

Installed as `data/nordic.skin`, registered in `data/SkinList.XML`, packaged in
`data/Release.Tool`, and set as the default look via the Autostart section of
`data/Configuration.XML` (`SkinEngine.Load nordic.skin`). Switch looks at runtime
via **Looks → Skin Loader**.
