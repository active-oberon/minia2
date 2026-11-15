# A2 core, target profiles, and native package management: implementation plan

Status: proposed, 2026-11-15. This document authorizes no implementation, repository creation, publication, or deployment. The requested deliverable is the plan.

Source baseline: MiniA2 `3b473d6dfc21bb701f7eab7682faf7ba0afc20d6`; reference branch `clean-data` at `72bc99768c3c449545751420be50e5dae70703ac`; historical A2 reference `a2oberon` at `b8037a8761feca83f2bf61f0a62227fb1f2f309f`.

Proposed direction: make `minia2` the canonical A2 system repository and retain `a2oberon` as a frozen historical reference and porting source. Preserve its history and useful platform work, then develop migrated code only in its new owner. Avoid permanent bidirectional synchronization between two A2 forks. Freezing or archiving the remote repository is a later explicit action; this plan does not perform it.

The installed product will be a usable A2 Desktop with essential tools and native package management. Installing, updating, removing, inspecting, building, and packaging applications must be possible through A2 itself. Console commands and graphical windows must call the same implementation.

No installed workflow may require Python, Git, curl, wget, a host shell, Docker, an external archive program, or spawning the SDK's `ob` executable. Calls to operating-system APIs and platform libraries inside the A2 process are allowed; any additional library dependency must be declared and delivered with the target profile. Restarting an A2 executable is an A2 lifecycle operation, not an external helper. Existing host build scripts may remain development tools during migration, but cannot be dependencies of the installed product.

The first complete implementation targets hosted Win64 and Linux64. The wider goal includes maintained hosted and bare-metal targets in the same A2 repository, using the same SDK interfaces and declared build profiles. Existing AArch64 and 32-bit targets must not be silently dropped: changed module lists and shared code must still be checked for every affected target, while untested runtime behavior is identified explicitly. Bare-metal work is a staged part of this plan, not a claim that the current MiniA2 tree already builds or boots every historical A2 target.

1. **Establish the boundaries and the baseline.**

   Define the product and distribution owners, retaining the existing registry:

   - `ao-sdk`: Fox, the linker, portable AO runtime, standard library, host bindings, compiler bootstraps, `ob`, language/debug services, compiler backends including the C transpiler, and SDK distribution tooling. Android/Termux SDK packaging belongs here.
   - `minia2`: the canonical A2 system, startup and lifecycle, window system, GUI framework, platform/board integration, bootloaders and drivers, essential desktop tools, native package management, minimal system resources, and target/profile build definitions. The Android A2 application/display/input integration belongs to this product; it must not be confused with the Android SDK distribution.
   - `a2-applications`: optional programs, their resources, manifests, development-environment integration, and reproducible package builds. Shared libraries have one owner and are dependencies, rather than copied into every application.
   - `a2-docker` (provisional name): Docker recipes and container-specific integration consuming pinned SDK and A2 releases. It may automate target/profile builds, but does not own another compiler, runtime, application tree, or independent A2 build definition.
   - `a2-registry`: the catalogue of available packages and their immutable release references. It indexes package sources and artifacts; it is not another copy of the application or runtime sources.

   Assign common runtime modules to `ao-sdk` and A2-specific integration to `minia2`. Give each shared implementation of Machine/Heaps/Modules/Objects one owner; target-specific implementations are explicit target inputs, not independently edited copies of the same runtime. The SDK can compile/link against A2-provided board modules without requiring the MiniA2 checkout to build the SDK or ordinary AO programs. A2 may use the compiler as an optional development package, without owning another compiler implementation.

   Before freezing the reference, inventory `a2oberon`-only fixes, boot recipes, tests, drivers, applications, and notices. Compare differing shared modules before porting; neither filename equality nor replacing the MiniA2 tree with the older tree establishes compatibility. Record each retained change and its new owner. Synchronization is a selective migration into the canonical owners, followed by one development line.

   Inventory the complete boot and desktop dependency closure, including configuration commands, dynamically loaded modules, fonts, icons, archives, and filename-based resource lookup. Do not decide ownership from filename prefixes or the old broad `apps/desktop` bucket alone.

   Read `clean-data` as a reference; port selected changes onto current main. Its minimal image opens PET and contains the compiler, which differs from the default profile proposed here. Its external Python installer is a behavioral prototype, not the installed implementation to retain. Preserve current source fixes and bootstraps when moving files.

   Define `minimal` and `full` as package/resource profiles over one core and one toolchain. `minimal` provides the essential A2 desktop and native package manager. `full` adds the declared maintained application set compatible with that target, including the development set where supported. It does not mean restoring every historical subsystem or forcing unsupported applications onto every board. Keep a separately selectable development package set; do not create another source fork for it.

   Drive builds from target plus profile. A target identifies CPU, OS/ABI or bare-metal board, boot method, runtime/scheduler/GC configuration, and required capabilities; an architecture name alone is insufficient. Lock the A2 revision, SDK/runtime revision and hashes, catalogue revision, and exact package set for each image. Record build, emulator boot, native launch, and hardware verification separately. An absent tool or untested board is a skip/unverified result, never a successful target. Keep historical targets visible as planned or unsupported until their acceptance checks pass.

   Acceptance: a reviewed ownership/migration list, explicit minimal/full package and boot/resource lists, a target support register, baseline Win64/Linux64 builds and launches, and a record of existing unrelated failures. Estimate subsequent work only after checking the HTTPS and storage gaps below.

2. **Fix the package, catalogue, and storage contracts before moving repositories.**

   Use a ZIP archive with `a2pkg.json` and declared `bin/`, `data/`, and optional `source/` content. Reuse the existing SDK manifest's identity/dependency fields and extend them for installable artifacts; do not preserve two competing permanent formats named `a2pkg.json` and `a2app.json`. Repack the small `clean-data` prototype catalogue into the selected format.

   Specify: format version, package name, immutable package version and source revision, package kind, exact dependency versions, provided modules, target platform, required AO runtime/base compatibility, file sizes and SHA-256 hashes, descriptions, and declared launch commands. Distinguish a source package from a ready-to-install binary artifact. A target includes the operating-system ABI, not just its CPU architecture; Linux/glibc and Android/Bionic are separate targets.

   For version one, resolve a deterministic dependency graph with exact versions and explicit conflicts. The catalogue names the recommended compatible release. Reject dependency cycles, missing dependencies, incompatible base/runtime/target requirements, and conflicting module providers. Do not build a general constraint solver or permit two active versions of the same module name/context.

   Keep existing base `bin/` and `data/` paths where practical. Add `apps/<name>/<version>/` for immutable package payloads, `user/` for documents and settings, and `var/` for the package database, transaction journal, cache, and logs. Retained old payloads are not active search paths. Development symbols and source files are installed by development packages when required.

   The package database owns active/next versions, dependency receipts, module and resource ownership, origin, hashes, and operation status. Startup search paths and menu entries are derived from that database. Generated `apps.cfg` files are not a second authoritative database.

   Acceptance: a versioned format document, equivalent local/network package fixtures, compatibility examples, and validation cases for real prototype applications. A package cannot impersonate or overwrite the protected base image or package manager.

3. **Build the native offline engine and native A2 lifecycle.**

   Start with one headless AO module, provisionally `A2Packages`, over the existing Files, Streams, JSON, ZIP/archive, hashing, Commands, and module facilities. Split implementation files only when their responsibilities require it. Keep GUI dependencies out of this engine. Reuse existing helpers and fix missing shared behavior at its owner.

   Implement inspection, installation from a local ZIP, dependency planning, installed-package listing, update, removal, verification, and native packing. The pack command creates the same archive and manifest used by installation; Python and external ZIP tools are not production packers. Treat a folder as a package staging/source input, not as permission to copy arbitrary files into the system.

   Validate before writing: archive paths and types, duplicate/case-colliding names, platform-specific invalid names, compressed/uncompressed size and file-count bounds, hashes, declared files, dependencies, module ownership, and protected system paths. No install-time scripts or automatic execution of downloaded modules. Launch commands are metadata for later explicit use, not actions executed by installation.

   Use one writer per installed image, including competing A2 processes. Stage and verify all required packages before committing the transaction. Preserve user documents and settings; removing a program does not purge them. Refuse removal of a dependency that is still required. Detect local modifications to managed payloads instead of overwriting them silently.

   Journal prepare/commit/recovery, keep the previous committed generation, and make startup recover a complete old or new state. Test the actual Files/WinFS/UnixFiles flush and replacement behavior: rename alone is not proof of atomicity or durability, particularly across filesystems. Stage on the destination filesystem and add the smallest required in-process platform primitive if the portable API is insufficient.

   Version one activates package changes on restart of A2. The running session keeps its old paths and payloads; the UI reports pending activation. Do not force-unload live modules or delete their files. Collect obsolete payloads only after the new session is known to work.

   Provide a native desktop entrypoint (`a2`/`a2.exe`) and restart path on Win64/Linux64. Normal startup enters A2 directly rather than the compiler's interactive command-line shell. Remove the installed requirement for the current `a2.bat`/`a2.sh` restart loops and their host-shell/FIFO helpers. Use platform APIs from A2, retaining a recovery route that works without the optional applications. This must be ready before restart becomes the only package activation path.

   Acceptance: from A2's own command interface, pack, inspect, install, restart, run, update, verify, remove, and recover the clock package without launching any host helper. Repeat with the desktop prototype's clock/calendar/diff dependencies and with networking disabled.

4. **Add the graphical package manager over that engine.**

   Implement a normal A2 window, provisionally `WMPackageManager`, using existing WM components and localization. Provide catalogue/search, installed programs, available updates, installation from a file, configured sources, operation progress, and readable errors/history.

   Before an operation, show the affected programs, added/removed dependencies, download/disk requirements, and restart requirement. Keep downloads and file operations off the UI event path. Cancellation before commit leaves the previous state; after commit, report that activation/recovery is finishing rather than abandoning half a transaction.

   Integrate installed entrypoints and icons with the launcher and register a file-manager action for opening a package for inspection. Do not execute commands just because an archive was opened. Console and GUI produce the same plan, transaction result, ownership records, and errors.

   Assemble an isolated minimal test image from the declared base closure while the source files can still remain in the current repository layout. Include essential tools and the native manager; supply optional applications only as package archives. This proves the clean installed product before the later physical repository moves.

   Acceptance: a user can install, update, and remove a local application without leaving A2, opening a host terminal, or editing configuration files. The base desktop includes the manager and remains usable when no optional applications are installed.

5. **Implement trusted network catalogues inside A2.**

   Use the same install pipeline for downloaded and local packages. A Git repository is a publication/source location: A2 retrieves a catalogue and platform archives over HTTPS at immutable revisions/releases. It does not clone repositories, implement the Git protocol, or invoke Git. `a2-applications` produces artifacts; `a2-registry` indexes them without becoming their source owner.

   Validate the network foundation before enabling this path. `NewHTTPClient` currently opens TCP directly, while `TLS.ReceiveCertificate` copies certificate bytes and advances the handshake without calling certificate validation there. Existing TLS/HTTP module names are not evidence of a verified HTTPS client. Establish and test hostname/chain/date validation, the actual catalogue host handshake, redirects, timeouts, cancellation, and bounded streaming. Use existing verified components or an in-process platform TLS binding; never fall back to HTTP or disable verification to make a download succeed.

   Ship one configured official catalogue. Authenticate catalogue metadata with a trusted signing key, and bind each archive to its digest, size, target, and immutable source revision. Audit/select an existing tested signature implementation before finalizing the signature format; a hash supplied by an unauthenticated manifest does not establish the publisher. Keep private publication keys off installed systems. A selected local development package is identified as local and does not acquire official provenance from its own hashes.

   Support native catalogue refresh, cached/offline browsing, source configuration, installation, and updates. A catalogue/download failure preserves the usable cached catalogue and installed state. An offline bundle must include the dependency closure; cache misses produce a clear error before changing anything.

   Acceptance: install and update a real published package from A2 with no Git/curl/Python; reject a bad catalogue signature, wrong archive hash, expired/untrusted/wrong-host certificate, truncated response, and HTTPS-to-HTTP redirect. No insecure network mode is shipped as the workaround for an unfinished transport.

6. **Produce the clean default A2 Desktop and migrate optional applications.**

   The default profile contains the AO runtime/A2 platform integration, filesystem and network facilities, window system, essential fonts/resources, launcher, file manager, simple editor, command console, settings, diagnostics, and package management. Determine exact modules from the dependency/resource inventory, not from a hand-picked filename count.

   Keep PET, the compiler/development environment, advanced monitors, DTP, media players, demonstrations, games, and servers out of the mandatory boot profile. A development package set restores programming tools; `full` preinstalls the declared compatible application sets. Both images use the same protected base and package database. A minimal installation can reach the equivalent full state through A2's package manager. A browser or other large application is not implicitly part of the base.

   Port the resource separation, application directories, package declarations, and minimal-image idea from `clean-data`. Preserve current bootstraps and fixes; do not switch the project back to that older branch. Audit runtime-loaded plugins and resource references when moving each application. Use existing archives and package-owned resource names instead of recreating a shared dumping ground in data/.

   Migrate one complete application first: source, assets, dependencies, commands, packaging, installation, update, and removal. Then migrate the remaining applications in small groups, with an installable artifact before removing its old in-tree copy. Move optional application sources to `a2-applications` after this path works; do not keep independently editable copies in both repositories.

   Acceptance: a clean base image boots without the applications checkout and without the compiler/PET. Installing the development set restores compilation and editing inside A2. Installing and removing optional applications leaves the base and user files intact. Minimal/full builds share core artifact hashes for the same target/runtime configuration, and installing the locked full package set into minimal produces the same managed application state. Both new and migrated installations have a native A2 startup path.

7. **Extract the independent AO SDK and reconnect the build boundaries.**

   Move the compiler, linker, portable runtime/stdlib, SDK command line and tooling, C transpiler/backend, and Android/Termux SDK pieces into `ao-sdk`. Move container recipes into the thin Docker repository after their release inputs are defined. Keep A2-specific graphical compiler/editor adapters with the A2 development applications. Inventory the Android image loader separately from the A2 NativeActivity/display/input shell so shared bootstrap code has one owner.

   Give the SDK its own minimal bootstrap, source/module lists, self-host build, tests, artifacts, and releases. Its build must not require MiniA2's desktop Release.Build closure, window system, data tree, or repository checkout. Preserve notices and history/provenance when moving source. Keep compiler-as-library entrypoints available.

   Pin the SDK/runtime release and its artifact hashes in MiniA2's build inputs. A normal A2 build uses that toolchain without embedding another stale, independently maintained compiler. Runtime compatibility is recorded in both the base image and application artifacts. Keep AO compiler backends and portable ABI contracts in the SDK; A2 owns board startup, interrupt/controller/device integration, linker layout inputs, and system image assembly. A cross compiler does not make a board supported without those pieces. Update registry generation so manifests come from their owning repositories, rather than assuming everything still belongs to MiniA2.

   The optional A2 development package loads compiler/linker modules inside A2. It must not launch `ob` or another external compiler to implement Build, Run, Debug, or Pack. Reuse Compiler.Modules and Linker.Link. The SDK's standalone command line remains useful for external development hosts and CI without becoming a dependency of installed A2 workflows.

   Acceptance: a clean `ao-sdk` checkout builds and compiles a program without MiniA2; MiniA2 builds against a pinned SDK without application sources; an application package builds against the declared SDK/A2 interfaces. Recheck self-contained bootstraps as well as SDK examples, so a fix cannot again miss the ordinary A2 build route.

8. **Complete native base installation, base updates, and recovery.**

   Deliver the base image with an A2-native installation/first-run path. Selecting the destination, setting up user storage, and registering the initial package state cannot require running a host installer script. Existing partition/MBR installation facilities are not reused blindly for a hosted installation.

   Base updates are a separate operation from application-file installation. Stage a complete versioned base image and a compatible package set, verify them, and activate on restart. On Windows, do not attempt to overwrite the running executable. Select the new image through an A2-owned native launch/lifecycle component and platform APIs; do not delegate replacement to a batch file, shell script, PowerShell, or a downloaded helper.

   Record successful startup and retain the last working generation. Provide an A2 recovery mode that disables optional application paths/autostart, shows the operation log, and restores the previous base/package set without needing the optional compiler or a network connection. Bound failed-start retries instead of creating a restart loop.

   Acceptance: initial setup, application management, base update, failed-start rollback, and recovery are all reachable through A2 itself on Win64/Linux64. Tests include a failed write, disk-full/read-only destination, interrupted unpacking, interruption before/after registry commit, interrupted activation, two competing sessions, and an incompatible package set. User documents/settings survive every case.

9. **Restore and maintain bare-metal targets in the canonical A2 tree.**

   Start with Bios32 as the first migration candidate. The inspected `a2oberon` revision contains image recipes and a release-job QEMU boot check; MiniA2's surviving Release.Tool target names alone do not provide its missing platform sources or boot pipeline. Bring over the required loader/assembler path, native runtime adaptations, drivers, image tools, resources, module lists, and boot checks as one dependency closure. Preserve applicable current MiniA2/compiler fixes rather than replacing shared modules wholesale.

   Establish a small diagnostic boot first, then the minimal desktop on a declared emulated machine, then its compatible full package image. Check module loading, allocation/GC, scheduler and interrupts, filesystem access, input/display, shutdown/restart, and the native offline package transaction path. Record emulator evidence separately from a boot on an identified physical machine. Reuse the same package formats and engine; add only the platform storage/lifecycle primitives required by the native target.

   Treat Bios64 as a separate porting/debugging milestone. The inspected reference release description says its loader does not reach long mode; its recipes also distinguish loader and GC configuration from Bios32. That recorded limitation has not been re-tested for this plan. Do not advertise a working Bios64 image merely because it links or shares the Bios32 image recipe.

   Inventory and schedule the remaining hosted 32-bit/ARM/AArch64 targets and bare-metal RPi/Zynq variants by dependency and available test hardware. Preserve the distinction between cooperative and other runtime profiles. CPU code generation, hosted ARM runtime support, and a particular bare-metal board are separate acceptance steps. Old release declarations are porting leads, not current support guarantees. Do not promise UEFI, AHCI, xHCI, modern PCs, or a new board until its required loader/drivers have been implemented and verified.

   For every candidate, declare display/input, writable storage, network, and boot/recovery capabilities. Offline packages are the first native installation path. Add authenticated networking when the target has the required transport and drivers; a local bundle still contains all dependencies. A diagnostic/headless kernel on a board without desktop capabilities is an intermediate result, not a completed minimal desktop or a silently reduced full image. Apply phase-eight recovery/update requirements to each promoted native target, including recovery when package or base activation is interrupted.

   Use one target/profile build entrypoint and shared image assembly rules with explicit platform inputs. Build minimal/full in isolated directories from their locked inputs. Publish a target/profile only after its required compilation, launch/boot, and package checks pass; identify the tested machine and any remaining hardware gaps. A full image includes optional packages offline, so initial use does not depend on working network drivers. Keep emulator jobs and hardware evidence distinct in continuous integration and release notes.

   Acceptance: Bios32 minimal and full images boot on the declared emulator, and minimal can install the full package set from disk inside A2. Hardware support is claimed only for an independently checked configuration. Each subsequent target passes its own declared checks before joining the supported set; failures or unavailable hardware remain visible. No release depends on checking out `a2oberon` after its required sources have migrated.

The first reviewable milestone is a hosted base A2 image with native startup, the offline engine, and its GUI installing the clock package from disk. The next milestone adds an authenticated remote catalogue and updates. Repository extraction follows working package boundaries; it is not used as a substitute for proving them. Target/profile contracts start with the baseline; existing target checks continue during extraction. Restore Bios32 before expanding the remaining native ports, and finish base-image recovery/update acceptance on each promoted platform. Hosted base self-update and the wider platform rollout need not delay the first offline demonstration.

Version-one limits are deliberate: ready-built platform packages, exact dependency versions, one active provider per module/context, restart-based activation, trusted repositories, no arbitrary installation scripts, no Git client, and no live patching/unloading. Package directories isolate ownership and updates; they do not sandbox executing native AO code. More advanced dependency solving or untrusted code execution needs a separate requirement.

Validation must use fresh build, SDK, image, cache, and temporary paths; compiling a later full library must not hide missing early-runtime dependencies. Check configs/moduleList*.txt, headless-core*.txt, gui-core*.txt, explicit test script lists, SDK payloads, and startup lists by their role. Regenerate the A64 module list before relevant builds. Record native, Wine, emulator, hardware, and network results separately.

Useful tests include: protected-core overwrite, duplicate module/resource owners, missing/cyclic/conflicting dependencies, wrong CPU/OS/runtime, path traversal and platform-specific filename aliases, archive/hash/size corruption, version-two selection over stale version-one objects, dependency removal refusal, user-settings preservation, registry recovery, and equivalent command/GUI outcomes. Reuse existing WM components, Files/archives, JSON, hashing, logging, and testing patterns. Add small targeted tests as each non-trivial behavior is implemented; do not build a parallel framework just for this plan.

Inspected source references: [package manifests](../packages/README.md), [optional application catalogue](../packages/apps/README.md), [current SDK Git fetching](../sdk/Ob.Mod#L1542), [compiler library entrypoint](../source/Compiler.Mod#L87), [linker](../source/Linker.Mod#L1874), [existing restart wrappers](../Taskfile.yml#L493), [HTTP client](../source/NewHTTPClient.Mod#L39), [certificate receive path](../source/TLS.Mod#L1615), [module ownership/loading](../source/Modules.Mod#L349), [clean-data prototype](https://github.com/active-oberon/minia2/blob/72bc99768c3c449545751420be50e5dae70703ac/applications/README.md), and the inspected sibling `a2oberon` checkout at the revision above (`Taskfile.yml`, BIOS recipes at lines 462-542; `.gitlab-ci.yml`, Bios32 boot job at lines 52-78 and native platform limitations at lines 151-166).

No implementation or runtime tests were performed for this plan. The existing main branch was inspected without switching branches. Other repositories and the Windows installation were not modified.
