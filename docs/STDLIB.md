# A compact std for Active Oberon — a draft layout

The rule this applies, in one line: **`std` holds what other packages talk to each
other through, plus what those types are built from. Everything else is `ob get`.**

Three filters, in order. A shared *type*, not a shared *usefulness* — two registry
packages that each ship their own `Reader` never interoperate, so `Streams` is std
forever, while two MP3 decoders bother nobody. True on every host — bare metal,
Linux, Windows, Android, A64 — which is what puts FAT and ISO out. And not
deliverable by `ob get`: we have a registry, so `std` is not obliged to be
batteries-included.

The border is Rust's, because Rust is the one modern standard library designed
*after* its package manager existed, which is our situation with `ob get`. The
per-package API to copy is Go's — those are the best available specifications.
The size to aim for is Oberon's own.

## Status — steps 1a and 1b are done, `task registry` is green (2026-08-27)

`std` is now **12 packages, 144 modules**, and the SDK payload went from **340 to 140**.
What left is in `packages/lib/` (380 modules, the library that `ob get` will deliver)
and `packages/apps/`. Sources have not moved: only the classification did.

| std package | tier | modules |
|---|---|---|
| `std/runtime` | 0 | 15 |
| `std/base` | 1 | 13 |
| `std/text` | 1 | 6 |
| `std/system` | 2 | 25 |
| `std/process` | 2 | 2 |
| `std/encoding` | 3 | 3 |
| `std/math` | 3 | 9 |
| `std/time` | 3 | 5 |
| `std/terminal` | 3 | 3 |
| `std/net` | 7 | 6 |
| `std/compiler` | 7 | 56 |
| `std/data` | 8 | 2 |

Three packages are new: `std/text`, `std/time`, `std/encoding`, assembled out of modules
filed by history rather than by subject — the string family out of `std/base`, the
Unicode database out of **`std/ime`**, `JSON` out of `std/web`, the clocks out of
`std/system`.

### What the gate taught, which the layout could not have

- **`Options` and `TFClasses` import `Strings`.** Leaving them in `std/base` once the
  strings moved would have made `base` and `text` a cross-package cycle. `Options` went
  to `std/system`, `TFClasses` to `lib/data-legacy`. `RealConversions` did not move with
  the strings either: `Streams` imports it, so the edge runs `text -> base` and only that way.
- **`Texts` is headless and I said it was not.** The gate: `std/text: Texts is in
  'graphical' but reaches no window system module`. It is `Codecs`, not `Texts`, that
  takes `UnicodeProperties` and `UnicodeBidirectionality` to the window system.
- **Fan-in beat taste on the one real cycle.** Holding `CSV` and `XML` in `std/encoding`
  made it and `std/system` import each other. Nothing in the tree imports `CSV`, and std
  reached `Configuration` only through `FSTools`, `FileHandlers` and `Localization` —
  which nothing imports either. Three commands moved to `apps/system-tools`, and five
  modules left the payload with them.
- **`ob test` drags the rich-text model into a headless SDK.** `FoxTest` imports
  `CompilerInterface`, which imports `Texts`, which reaches `WMEvents` and `FP1616`.
  Cutting that one import is the cheapest three modules the payload will ever lose — and
  it is a code fix, not a manifest one.

### Still open

**Step 4 started 2026-09-03 with the duplicates, and one of the three decisions was wrong.**
`MD5` is gone: `HTTPSession` and `SVNUtil` were its only callers and they now use `CryptoMD5`
with `CryptoUtils.Bin2Hex`, which does not terminate the string the way `MD5.ToString` did --
there is a test case that says so. `Base64` and `CryptoBase64` are one module: the 27.08 note
that nothing imported either was wrong, and the one with no callers at all was the one std had
kept. `Base64` is now the implementation `WebSockets`, `CryptoRSA` and `CryptoDSA` were already
using, under the name std filed it as. `DES` and `CryptoDES` both stay, as decided.

`std/data` is two modules (`GenericCollections`, `GenericSort`) and has no `Map` or
`Set`. `std/text` has no UCD tables — the Unicode database is in
`lib/texts` because this implementation of it reads through the rich-text model. That,
plus monotonic time and modern crypto, is what is left of step 4.

**Regex landed 2026-09-03** (`source/Regex.Mod`, `tests/Regex.Test`). It is Thompson's
construction — the pattern becomes a program and every thread advances one character at a
time — so the cost is O(pattern × input) and no pattern a caller writes can make it worse.
That is the property a standard library needs and a backtracking matcher cannot promise; the
price is no back references, which is the feature that makes backtracking exponential in the
first place. The syntax is the common subset: `. * + ? | ( ) (?: ) [ ] ^ $`, lazy variants,
`\d \w \s` and their negations, nine capturing groups. Not there: counted repetition
`{m,n}`, and characters — a pattern matches UTF-8 literally but `.` counts one byte, which is
the same UCD hole as above and closes with it.

---

Counts below are the ones measured before step 1a, kept because the reasoning is:
 **527 provides in 22
packages today, 194 in 14 here, of which the compiler is 56 — so the library
proper is 138 modules.**


## std/runtime — 15

`Builtins`, `Clock`, `Glue`, `Heaps`, `Kernel`, `Kernel32`, `KernelLog`, `Machine`, `Modules`, `Objects`, `Reals`, `Trace`, `Unix`, `User32`, `WSock32`

## std/base — 13

`BIT`, `BitSets`, `BitStreams`, `Channels`, `Diagnostics`, `Events`, `Locks`, `Options`, `Pipes`, `ReleaseThreadPool`, `StreamUtilities`, `Streams`, `TFClasses`

## std/system — 25

`Commands`, `Debugging`, `Errors`, `FSTools`, `FileHandlers`, `Files`, `GenericLinker`, `HostLibs`, `In`, `Info`, `Loader`, `Localization`, `ObjectFile`, `Out`, `Reflection`, `Shell`, `ShellCommands`, `StdIO`, `StdIOShell`, `System`, `SystemVersion`, `TaskScheduler`, `TrapWriters`, `Traps`, `UnixFiles`

## std/process — 2

`LocalSockets`, `Processes`

## std/text — 11

`DynamicStrings`, `NbrStrings`, `RealConversions`, `Regex`, `StringPool`, `Strings`, `TFStringPool`, `Texts`, `UTF8Strings`, `UnicodeBidirectionality`, `UnicodeProperties`

Missing, worth adding: **UCD tables**. `Regex` arrived 2026-09-03.

## std/time — 5

`ActiveTimers`, `Dates`, `PrecisionTimer`, `Stopwatch`, `UpTime`

Missing, worth adding: **monotonic, tz database**. `Clock` stays in std/runtime — the
kernel needs it before any library does.

## std/data — 2

`GenericCollections`, `GenericSort`

Missing, worth adding: **Map, Set**.

## std/encoding — 9

`Base64`, `CRC`, `CSV`, `Checksum`, `JSON`, `XML`, `XMLObjects`, `XMLParser`, `XMLScanner`

## std/math — 10

`ComplexNumbers`, `Drand48`, `FoxArrayBase`, `FoxArrayBaseOptimized`, `Math`, `Math32`, `Math64`, `MathL`, `Random`, `Shortreal`

## std/net — 10

`DNS`, `IP`, `Network`, `Sockets`, `TCP`, `TLS`, `UDP`, `WebHTTP`, `WebHTTPClient`, `WebHTTPServer`

## std/crypto — 22

`ASN1`, `CryptoAES`, `CryptoBigNumbers`, `CryptoCSPRNG`, `CryptoCiphers`, `CryptoDSA`, `CryptoDiffieHellman`, `CryptoFortuna`, `CryptoFortunaRng`, `CryptoHMAC`, `CryptoHashes`, `CryptoKeccakF1600`, `CryptoKeccakSponge`, `CryptoMD5`, `CryptoPrimes`, `CryptoRSA`, `CryptoSHA1`, `CryptoSHA256`, `CryptoSHA3`, `CryptoStreams`, `CryptoUtils`, `X509`

Missing, worth adding: **Ed25519, X25519, ChaCha20-Poly1305, HKDF**.

## std/archive — 13

`Archives`, `GZip`, `Inflate`, `Tar`, `Unzip`, `Zip`, `ZipFS`, `Zlib`, `ZlibBuffers`, `ZlibDeflate`, `ZlibInflate`, `ZlibReaders`, `ZlibWriters`

## std/terminal — 3

`Frames`, `Terminal`, `TerminalCodes`

## std/compiler — 56

`AMD64Decoder`, `Compiler`, `CompilerInterface`, `Decoder`, `FoxA2Interface`, `FoxA64Assembler`, `FoxA64Backend`, `FoxA64InstructionSet`, `FoxAMD64Assembler`, `FoxAMD64InstructionSet`, `FoxAMDBackend`, `FoxAssembler`, `FoxBackend`, `FoxBasic`, `FoxBinaryCode`, `FoxCodeGenerators`, `FoxDisassembler`, `FoxDocumentationBackend`, `FoxDocumentationHtml`, `FoxDocumentationParser`, `FoxDocumentationPrinter`, `FoxDocumentationScanner`, `FoxDocumentationTree`, `FoxFingerprinter`, `FoxFormats`, `FoxFrontend`, `FoxGenericObjectFile`, `FoxGlobal`, `FoxInterfaceComparison`, `FoxIntermediateAssembler`, `FoxIntermediateBackend`, `FoxIntermediateCode`, `FoxIntermediateLinker`, `FoxIntermediateObjectFile`, `FoxIntermediateParser`, `FoxOberonFrontend`, `FoxParser`, `FoxPrintout`, `FoxProfiler`, `FoxProgTools`, `FoxScanner`, `FoxSections`, `FoxSemanticChecker`, `FoxSyntaxTree`, `FoxTest`, `FoxTestBackend`, `FoxTextualSymbolFile`, `FoxTranspilerBackend`, `I386Decoder`, `LSP`, `Linker`, `ModuleParser`, `Release`, `TestSuite`, `UnixBinary`, `Versioning`


## What leaves, and why

- **archive** (1) — `ZipTool`
- **base** (4) — `WMEvents`, `Inputs`, `FP1616`, `Plugins` — the window manager's tail inside the package named "needs no host"
- **calc** (10) — quadrature and differentiation — a numerics package
- **compress** (3) — BWH, MoveToFront, OZip3
- **crypto** (8) — ARC4, Blowfish, CAST, IDEA, Twofish, DES, DES3 — kept for compatibility, not recommended in new code. `DES` duplicates `CryptoDES` and both stay: different APIs, each with its own callers. `CryptoBase64` left 2026-09-03 — it *was* `Base64`, see below
- **data** (13) — the second generation of containers (`DataLists`, `DataQueues`, `DataStacks`, `DataTrees`) plus `SQL`, `ODBC`, `PrevalenceSystem` — databases in a package named for data structures
- **disk** (28) — FAT, ISO, Oberon FS, partitions — one operating system, not a language
- **drivers** (19) — hardware, and half of it is already marked graphical
- **gui** (112) — the A2 window manager — one application, and a quarter of the whole library
- **ime** (14) — input methods — but `UnicodeProperties` and `UnicodeBidirectionality` come out of here into std/text, which is where they should have been
- **math** (11) — the `Nbr*` arbitrary-precision family — a numerics package, not the numeric core the compiler emits calls into
- **media** (14) — codecs are leaves; nobody interoperates through an MP3 decoder
- **net** (40) — FTP, SSH, Telnet, Samba, mail, chat, XModem — finished programs. `PKCS1` stays as a duplicate of std/crypto; `MD5` was deleted 2026-09-03, its two callers now use `CryptoMD5`
- **numerics** (10) — special functions — same
- **sound** (5) — a device and two players
- **system** (22) — diagnostics: five `Events*`, two `ProcessInfo`, two `HierarchicalProfiler`, `DependencyWalker`, `WinTrace`
- **web** (16) — the 2000s web framework — CGI, dynamic pages, plugins, CSS. XML and JSON move to std/encoding


## The three moves that cost nothing and buy the most

1. **std/text has to exist.** Today it is one module, `Texts`, and that one is
   marked graphical. The real text layer is scattered: `Strings`, `UTF8Strings`,
   `DynamicStrings`, `StringPool`, `RealConversions` sit in std/base, and
   `UnicodeProperties` / `UnicodeBidirectionality` sit in std/ime, of all places.
   For a language whose named sore point is `ARRAY OF CHAR`, this is the most
   expensive misfiling in the tree.
2. **Pick one generation of containers.** `GenericCollections` (parametric
   modules) gives `Stack`, `Queue`, `DEQue`, `Vector` and has no `Map` or `Set`;
   `DataLists`/`DataQueues`/`DataStacks`/`DataTrees` are an older answer to the
   same question. Two parallel sets never converge on their own.
3. **Pick one HTTP.** std/net carries three stacks: `HTTPSession`+`HTTPSupport`,
   `NewHTTPClient`, and `WebHTTPClient`+`WebHTTPServer`+`WebHTTPTools`.

None of the three is new code. That is the point: the library becomes explicable
before a line is written, and `ob get` finally means something.

## The one place principle and practice disagree

By the Rust border, TLS and HTTP belong in the registry, and `ob get` does not
need them — it fetches through external `git` (`sdk/Ob.Mod:1423`) and reads JSON.
TLS stays anyway, on a different argument: security by default cannot be an
optional dependency. HTTP is here only because something has to answer `TLS`; it
is the weakest entry in this layout and the first to reconsider.
