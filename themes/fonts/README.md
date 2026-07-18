# Fonts (JetBrains Mono, Noto Sans, Noto Serif)

Extra TrueType families added to minia2, installed into `data/` with the A2
naming convention `<Family>.ttf` / `_bd` / `_i` / `_bi` (regular / bold /
italic / bold-italic — see `source/WMOTFonts.Mod`).

| Family         | Source                                   | Role in `Configuration.XML` |
|----------------|------------------------------------------|-----------------------------|
| JetBrains Mono | github.com/JetBrains/JetBrainsMono v2.304 | Monospace + Console; editor code (`SyntaxHighlighter.XML`) |
| Noto Sans      | github.com/notofonts (static hinted)      | Default + SansSerif; document text (`DefaultTextStyles.XML`) |
| Noto Serif     | github.com/notofonts (static hinted)      | Serif |

Only **static** instances are used — A2's `OpenType.Mod` has no variable-font
support.

## IMPORTANT: fonts must be de-hinted

A2's TrueType hinting-bytecode interpreter (`OpenTypeInt`) **traps** (Trap 5.7
index-out-of-range in `OpenTypeInt.RS`, via `OpenType.LoadSimpleOutline`) on the
hinting programs shipped in these fonts. Symptom: opening the IDE / GuiBuilder —
anything that rasterises certain glyphs at UI size — crashes into a red trap
window. The pre-existing Liberation / IBM Plex fonts happen not to hit the bug;
JetBrains Mono and Noto do.

Fix: strip all hinting from the TTFs before installing, so the interpreter is
never invoked (glyphs render as plain grayscale-AA outlines). `dehint.py` removes
per-glyph instructions and the `fpgm` / `prep` / `cvt ` / `gasp` tables and zeroes
the hinting-related `maxp` fields.

    python3 -m venv /tmp/fontvenv && /tmp/fontvenv/bin/pip install fonttools
    /tmp/fontvenv/bin/python themes/fonts/dehint.py data/JetBrainsMono*.ttf \
        data/NotoSans*.ttf data/NotoSerif*.ttf

Re-run this whenever these fonts are re-downloaded / updated. All 12 files in
`data/` are already de-hinted.

Packaged in the `TrueTypeFonts` archive (`data/Release.Tool`); OFL licences in
`data/JetBrainsMonoOFL.txt` and `data/NotoFontsOFL.txt`.
