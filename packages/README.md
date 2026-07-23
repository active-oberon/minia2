# minia2 packages — layering model and manifest format

This directory declares the **layered decomposition** of the A2 module world that
the minia2 SDK ships and that the future package manager (`ob get`) resolves against.
It is the authoritative statement of *which module belongs to which package* and
*who is allowed to depend on whom*.

Manifests here declare packages by the module names they **provide**; the source
files are not (yet) physically moved. A manifest is a plain `a2pkg.json`.

## Tiers

Dependencies may only point **downward** (same tier or lower). An upward edge is a
hard error, checked by the layer-lint (below).

| Tier | What | Origin | May depend on |
|------|------|--------|----------------|
| 0 | `std/runtime` — sealed kernel/GC/modules/loader/files/streams/shell + shared primitives | baked into the image, read-only | nothing |
| 1 | base stdlib: `std/base`, `std/math`, `std/compress`, `std/text`, … | shipped in the image | tier 0 (+ tier 1) |
| 2 | higher stdlib: `std/numerics`, `std/archive`, `std/net`, `std/web`, `std/crypto`, `std/data`, `std/gfx`, … | shipped in the image | tiers 0–1 (+ tier 2) |
| 3 | top: `std/compiler`, `std/wm` (GUI, not in the headless image) | shipped / optional | tiers 0–2 |
| ext | third-party packages | fetched to `/work/.a2pkg/` | any std tier + other ext |

`std/runtime` is proven import-closed: **41 modules** (the 38-module boot-closure plus
`BIT`, `Locks`, `Debugging` — shared primitives that were mis-filed in the misc pile
but verified sealed) import nothing outside the set, over the full 730-module graph.

## misc triage — findings

The 338-module `misc` pile is **not one problem but three**, and has **zero internal
dependency cycles** (Tarjan SCC), so it decomposes topologically:

1. **~135 zero-fan-in sinks split ~half/half.** About half are genuine applications and
   tools that leave the standard library entirely (`PET`, `WindowManager`, `VNC`,
   `SambaServer`, `LSP`, media players); the other half is **mis-filed library code** to
   be re-homed, not discarded — 8 Fox code-generator backends (`AMD64Decoder`,
   `I386Decoder`, `PCG386`, `PCGAMD64`, `PCGARM`, `PCA386`, `PCOFPE`, `ARMDecoder`) →
   `std/compiler`; media codecs → `std/media`; protocol clients (`SMTPClient`, `LPR`,
   `XModem`) → `std/net`; small utilities (`Base64`, `CSV`, `In`, `Out`) → `std/base`.
2. **Shared foundation** sunk to low tiers — but note **high fan-in ≠ low tier**. A true
   foundation module has high fan-in *and* low fan-out. Widely-imported HUBS that also
   fan out (`Configuration`→XML, `Codecs`→Raster, `Repositories`→XML+WMEvents,
   `Models`→XML) are mid-tier, not base, and were kept out of `std/base`.
3. **Small domain families** → `std/drivers` (`Display*`, `Serials`, `Beep`), `std/disk`,
   `std/fonts` (`OpenType*`), `std/audio` (`OpenAL*`), etc.

Packages are `draft` with a `residual` list until every edge is either resolved by
re-homing a module (manifest surgery) or by a flagged code edit. Stable so far:
`std/runtime`, `std/crypto`, `std/math`, `std/compress`.

**Split-to-clean pattern.** Two packages reached `stable` by splitting a tier-1 core
from a tier-2 layer rather than editing source: `std/math` (core number types) vs
`std/numerics` (advanced/special functions that share `DataErrors`); `std/compress`
(zlib/gzip primitives) vs `std/archive` (ZIP containers that pull XML config). The one
genuinely code-level tail is documented, not silently patched: `DataErrors` beeps on
error via `Beep`, which on Unix drags X11 — cutting that audible warning is a
behavioral edit to vendored source and is left as a `std/numerics` blocker for the
maintainer to decide.

## Manifest format (`a2pkg.json`)

```json
{
  "name": "std/crypto",           // package id; "std/*" reserved for the SDK
  "tier": 2,                       // 0..3, or omitted for external
  "context": "A2",                 // Fox module context; "A2" is the default/unprefixed
  "status": "stable | draft",
  "description": "one line",
  "provides": ["ModuleA", "ModuleB"],   // flat A2 module identifiers this package owns
  "requires": { "std/runtime": "*", "std/math": "*" },  // pkg -> version constraint
  "residual": ["...notes on edges not yet clean..."]     // draft only; empty when stable
}
```

Chosen format is **JSON**: the `ob` CLI is bash, JSON parses with `jq` (already in the
image), and the tree has `JSON.Mod` if we ever want to read manifests from A2 itself.
No new dependency.

### Namespacing

A2 module identifiers are **flat within a context** (`CryptoDES`, not `Crypto.DES`).
Packaging respects this: a package's identity is `name` + optional `context` + the
`provides` list. Two mechanisms coexist:

- **In-identifier prefix** (default, what the community already uses): `CryptoDES`,
  `NbrInt`. No source changes; collisions across packages are possible and the
  resolver detects and errors on them.
- **Fox context** (opt-in, `"context": "..."`): `MODULE X IN Crypto` compiles to the
  object section `Crypto.X` and coexists natively with any other `X`. True
  compiler-level isolation, one level deep. Costs source edits + import rewrites;
  reserved for packages that need hard isolation.

## Populator + layer-lint (design)

**Populator.** Each `ob` invocation builds in a private scratch dir (the compiler
resolves imports from the cwd). The populator symlinks in tier order — 0, then 1, 2,
3, then `ext` — so resolution precedence is deterministic and the sealed base is never
shadowed by a higher tier. A name already provided by a lower tier is not overridden
(collision → clear error naming both packages).

**Layer-lint.** Reuses the import graph the LSP already builds. For every module,
each import must resolve to a package in the same or a lower tier. An upward edge
(e.g. `std/math` importing an `ext` module, or `std/runtime` importing anything)
fails the lint with the offending `module -> import` edge. Run at `publish` time for
external packages and in CI for the std packages.
