# Nordic skin

A2 skin (theme) for minia2, inspired by the popular **Nordic** GTK theme
(gnome-look.org, by EliverLara), built on the **Nord** color palette.

- `skin.bsl` — the Bluebottle Skin Language definition (colors + window chrome refs)
- `make_nordic.py` — regenerates `data/nordic.skin` (Nord-palette PNG chrome tiles +
  `skin.bsl`, packaged as a tar). Needs Python + Pillow; reuses cursor PNGs from an
  existing skin.

Installed as `data/nordic.skin`, registered in `data/SkinList.XML`, and set as the
default look via the Autostart section of `data/Configuration.XML`
(`SkinEngine.Load nordic.skin` after the desktop restore). Switch looks at runtime
via **Looks → Skin Loader**.
