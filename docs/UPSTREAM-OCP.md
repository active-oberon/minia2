# A2DB and MD2AO from ETH Oberon

MiniA2 imports Bohdan Troshchynskyi's A2DB and MD2AO sources from
[ETH Oberon master](https://gitlab.inf.ethz.ch/felixf/oberon/-/tree/1be2fd50b4f5ab98302d5294ab5d5d7e51c0356c/ocp).
The upstream revision was checked again on 2026-10-14. All 24 modules and the
viewer resources retain their original bytes, formatting and authorship.

- A2DB: commit `aeddc96d4`, 2026-07-09, `ocp/A2DB`; 11 modules under `source/`.
- MD2AO: commit `1be2fd50b`, 2026-10-09, `ocp/MD4AO`; 13 modules under `source/`.
- `MDStyles.XML`, `MD4AO.tool` and `MD2AO-demo.zip` remain under `data/`.
- The corresponding registry packages are `community/a2db` and `community/md4ao`.

## What the SDK includes

`lib/a2db` provides paged storage, slotted records, a string B+Tree, key/value
operations and a small SQL scanner, parser and executor. Its 11 modules are in
the headless SDK lists for Linux64/i386, Windows, ARM32 and AArch64.

`lib/md4ao` contributes five headless modules: `MDTree`, `MDScanner`, `MDInline`,
`MDParser` and `MDHighlight`. The eight remaining modules implement the desktop
viewer, layout, math rendering, configuration, clipboard and search. They compile
with the full A2 graphics and window-manager libraries; the small `ob --gui`
payload does not include the complete desktop. The registry therefore retains
`pending-gui` for the complete viewer package.

`configs/moduleListLinux.txt`, `configs/moduleListWin.txt` and
`configs/moduleListAndroidApp.txt` describe startup images. These new libraries
are loaded separately, so their addition changes the SDK payload lists and
`configs/moduleListA64.txt`, rather than the startup images.

## Tests

`tests/A2DB.Test` checks binary page records, deletion and compaction, capacity,
pager reads/writes, key/value persistence, SQL diagnostics and parameterized CRUD.
`tests/MD4AO.Test` checks block scanning, tree links and anchors, inline markup,
document parsing, tables, math and nested source comments. These are focused
regressions, not a claim of complete public-API coverage.

```sh
tests/gen-a64-stdlib.sh
task Linux64
tests/bundle.sh --full --no-tar -o target/fullsdk target/Linux64
A2SDK="$PWD/target/fullsdk" target/fullsdk/ob test tests/A2DB.Test tests/MD4AO.Test
```

On 2026-10-13 both suites pass 11/11 on Linux64, AArch64 under QEMU and native
i386. Fresh MiniA2 builds pass on Linux64, Linux32, LinuxARM and Win64; the A64
library build passes 396/396. A consumer also installs `community/a2db` from the
local registry and runs against an older SDK that contains no A2DB objects.
Detailed logs and JSON reports are in `target/upstream-sync-build/`.

On 2026-10-14 a freshly assembled SDK repeats the Linux64 checks at 11/11.
The A64 module list regenerates identically. Registry validation passes against
the previously rebuilt target directories, whose source files still match the
current tree byte for byte. Existing default build directories can be older;
use `task registry BUILD_DIR=<verified-build-root>` when validating an isolated build.

## Prototype limits

A2DB is an upstream prototype. Its page header and slots use native `SIZE`
fields, so a database must stay on the same word width. The SQL implementation
does not implement `CREATE TABLE`, transactions or general relational queries.
Record lengths, damaged pages and failed I/O are not fully validated. Use
disposable database files; opening a file with an invalid superblock can
initialize its metadata. Multi-page growth, crash recovery and concurrent
writers are outside these tests. The imported source remains unchanged.

The desktop viewer was compiled, but no window, rendering, clipboard or user
interaction was exercised during this import.
