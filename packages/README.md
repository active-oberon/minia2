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
| 0 | `std/runtime` — sealed kernel/GC/modules/loader/files/streams/shell | baked into the image, read-only | nothing |
| 1 | base stdlib: `std/math`, `std/compress`, `std/text`, … | shipped in the image | tier 0 (+ tier 1) |
| 2 | higher stdlib: `std/net`, `std/web`, `std/crypto`, `std/data`, `std/gfx`, … | shipped in the image | tiers 0–1 (+ tier 2) |
| 3 | top: `std/compiler`, `std/wm` (GUI, not in the headless image) | shipped / optional | tiers 0–2 |
| ext | third-party packages | fetched to `/work/.a2pkg/` | any std tier + other ext |

`std/runtime` is proven import-closed: the 38 modules import nothing outside the set
(verified over the full 730-module graph). It is the only package currently locked
as `stable`; the rest are `draft` with an explicit `residual` list of edges to close
during the `misc` triage.

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
