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
| 2 | higher stdlib: `std/numerics`, `std/archive`, `std/net`, `std/web`, `std/media`, `std/crypto`, `std/data`, `std/gfx`, … | shipped in the image | tiers 0–1 (+ tier 2) |
| 3 | top: `std/compiler`, `std/wm` (GUI, not in the headless image) | shipped / optional | tiers 0–2 |

### Current roster (264 modules placed)

| package | tier | status | modules |
|---------|------|--------|---------|
| `std/runtime` | 0 | stable | 41 |
| `std/base` | 1 | draft | 6 |
| `std/math` | 1 | stable | 17 |
| `std/text` | 1 | draft | 3 |
| `std/compress` | 1 | stable | 8 |
| `std/crypto` | 2 | stable | 30 |
| `std/numerics` | 2 | stable | 10 |
| `std/web` | 2 | draft | 5 |
| `std/net` | 2 | draft | 40 |
| `std/media` | 2 | draft | 16 |
| `std/archive` | 2 | draft | 5 |
| `std/calc` | 2 | draft | 9 |
| `std/data` | 2 | draft | 17 |
| `std/drivers` | 1 | draft | 10 |
| `std/compiler` | 3 | draft | 91 |
| `std/gui` | 3 | draft | ~40 core (of 137 WM* + 39 gfx; rest are apps) |

Item-2 re-homing (mis-filed library recovered from the misc sinks): 8 code-gen/decoder
backends → `std/compiler`; protocol clients (SMTP/POP3/LPR/XModem/SSH) → `std/net`;
media codecs (MP3/DivX/MPEG/WAV/GIF) → `std/media`.

Item-3 domain families: `std/drivers` (tier 1, runtime-only core), `std/calc`,
`std/data`, and `std/gui`. Plus `packages/apps/` — a catalogue (not a package) of the
applications, CLI tools, specialty families (`sr*` voxel engine, `Od*`/`SVN*`, `TF*`),
and host bindings that are **not** stdlib.

### The upper-layer finding

The lower stdlib (tiers 0–2) decomposes into a clean **DAG** — every package's core
imports strictly downward, and five packages are provably `stable`. The **upper layer
does not**. Two structural facts set it apart:

1. **`std/gfx` and `std/wm` are an irreducible cycle** — graphics and the window manager
   import each other even at the library-core level. They cannot be separate tiered
   packages under the downward-only rule, so they are merged into one `std/gui` package
   (intra-package cycles are allowed; cross-package cycles are not).
2. **The GUI world is ~60% applications, not library.** Of 137 `WM*` modules only ~40 are
   framework; the rest are apps. Same for the driver/disk/media families. So item-3's
   work was as much *subtraction* (moving apps to `packages/apps/`) as packaging.

`std/gui` is the boundary of the headless SDK: everything tiers 0–2 ships headless; the
GUI unit is an optional install.
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
`std/runtime`, `std/crypto`, `std/math`, `std/compress`, `std/numerics`.

> **Follow-up (image rebuild):** the SDK image still ships stale prebuilt symbols
> `Beep.SymUu` and `DataErrors.SymUu` that reference the old Beep→Displays→X11
> interface and fail to load headless. Regenerate them on the next image build so
> the prebuilt `/psym` path matches the patched source.

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

## Tooling (implemented in `docker/ob`)

- **`ob get <host/user/repo>[@version] …`** — clones the package(s) into the project's
  `.a2pkg/` cache, records them in `a2pkg.json` (`requires`) and pins the exact commit
  in `a2pkg.lock`, then transitively fetches their external requirements (`std/*` is
  satisfied by the SDK image and never fetched). Needs `git` + `jq` in the image.
- **`ob lint`** — builds the module→tier map from the shipped `std/*` manifests plus any
  installed packages, walks the import graph of the project's `.Mod` files, and reports
  any **upward** edge (a module importing something in a higher tier). Exit non-zero on
  violations; run it in CI.
- **Populator** (`populate_packages` in `ob`) — each `ob` invocation builds in a private
  scratch dir (the compiler resolves imports from the cwd). Installed packages are
  symlinked in **tier order (0 first)**, so the sealed base is never shadowed and a name
  clash between two packages is a hard error naming both (flat A2 namespace). Wired into
  `build`/`run`/`compile` and `lsp`.

Project files created by `ob get`: **`a2pkg.json`** (the app's own manifest, same schema)
and **`a2pkg.lock`** (`{ "<repo>": {"version","commit"} }`).

> Verified so far: the tier map + lint logic are self-consistent over the current tree
> (362 resolved import-edges among the five stable packages, **0 upward edges**); the
> import extractor handles aliases (`X := Y`) and Fox contexts (`Y IN Ctx`). End-to-end
> `ob get` (network + git) needs an image rebuilt with the new `git`/`jq` layer.
