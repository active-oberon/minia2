# apps — programs, not library

These modules are **applications and interactive tools**, not reusable library code:
zero fan-in (nobody imports them) and/or they export a `Commands.Context` command and
pull the GUI/desktop stack. They are catalogued here so every module in the tree has a
home, but they are **not** part of the tiered standard library and are **not** in the
headless SDK image. Each is a candidate to become its own installable package (or to
live in an `apps/` distribution).

## GUI applications (need std/gui)

PET, TFPET, PETModuleTree, PETReleaseTree, PETXMLTree (the classic editors);
WindowManager, StartMenu, MenuPages, MainMenu, WMBuilder, WMFileManager, WMCharMap,
WMCalendar, WMColorPicker, WMDesktops, WMDiff, WMFTPClient, SkinEditor, ComponentViewer,
Presentation, CharacterLineup, ModuleTrees, ReleaseVisualizer, DebugLog, HotKeys;
media players — MP3Player, WAVRecorder, MediaPlayer, MPEGVideoDecoder (viewer),
AnimationCodec (viewer); mail — BimboMail; PartitionEditor(+Components/Table);
DTPEditor/DTPText/DTPImage/DTPRect (desktop publishing); SynergyClient, VNC.

## CLI tools / commands (need std/net, std/disk, std/compiler, …)

LSP (our language server), SVN, SambaServer, SambaClient, TFWebForum, TFXRef,
DependencyWalker, FSTools, IsoImages, VirtualDisks, Info, SearchTools, Visualizer,
Reboot, BootManager, CPUID, Checksum, Bin2Hex, BinToCode, PrettyPrint, OZip3,
StreamUtilities, ShellSerial, V24Tracer, RFC865Client, TestServer, AlmSmtpReceiver.

## Specialty families (own packages, likely optional/external)

- **`sr*`** (~25+ modules: srBase fan-in 23, srMath, srE, srVoxel, srM5Space, srM6Space,
  srRender, srRotaVox, srImage, srThermoCell) — a community 3D / voxel engine. A
  self-contained subsystem; belongs as its own external package `sr` (uses std/gui).
- **`Od*` / `SVN*`** (OdVCSBase, OdSvn, OdXml, OdUtil, OdAuth/Base, OdCond, SVN, SVNUtil,
  SVNOutput, SVNAdmin) — an Oberon-documents / Subversion client suite.
- **`TF*`** framework (TFTypeSys, TFScopeTools, TFPET, TFWebForum, TFXRef) — a
  type-system/tooling framework layered on the compiler.
- **host bindings** (Kernel32, User32, GDI32, Shell32, WSock32, HostLibs, X11, XDisplay,
  HostClipboard) — Windows/X11 platform glue; belong in the platform layer, not stdlib.

## Small utilities to promote back into the library

Some zero-fan-in modules are genuinely reusable and should be **kept**, not treated as
apps — pending a home decision (likely std/base or a std/util):
`In`, `Out`, `CommandLine`, `Stopwatch`, `Base64`, `Checksum`, `Drand48`, `JSON`,
`DiffLib`, `MoveToFront`, `BitStreams`, `RAWPrinter`, `Localization`.

## 2026-08-24: this list is now backed by manifests

Every module of `source/` is claimed by a package as of 2026-08-24 (745 of 745, checked by
`docker/gen-headless-core.sh --check`), and the applications listed below are claimed too:
`apps/perfmon` took the performance monitor and its plugins, `apps/desktop` took the rest. This file
stays as the reading of *why* they are applications; the manifests are what the check reads. A
program that earns its own package moves out of `apps/desktop`, the way perfmon did.
