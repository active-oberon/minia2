# MiniA2 work state — 2026-10-06

## Goal
MiniA2 should boot with the base system, compiler, and PET. Application programs and optional data belong under `applications/` and can be installed later from ZIP files or direct HTTPS URLs.

## Implemented
- `data/` contains 95 core files, selected by `configs/minimal-data.txt`. The other 570 data files are under `applications/assets/data/`.
- Application modules moved from `source/` to `applications/{core,desktop,perfmon,system-tools}/source/`. The core group contains modules required by WindowManager and PET.
- `Taskfile.yml` stages a full tree for normal development builds. `task minimal PLATFORM=Win64` builds a separate minimal image and platform-specific application ZIPs.
- `applications/manage.py` supports `build`, `pack`, `install`, `remove`, and `list`. Built-in packages: `clock`, `calendar`, `diff`, `desktop`, `perfmon`, `system-tools`. `desktop` installs the first three as dependencies.
- Minimal startup opens PET. Installed packages live in `apps/<name>/`; `apps.cfg` adds their directories to the A2 search path.
- README and affected scripts updated for the split layout.

## Verification
- Clean Win64 full build passed in `target/fresh/Win64`.
- Minimal Win64 image built in `target/fresh/Win64-minimal-final2` with 95 data files and booted successfully through `a2.cfg`.
- Installed `clock` and ran `WMClock.Open`; installed `desktop` with dependencies and ran `StartMenu.Open`.
- `python -m unittest applications/test_manage.py`: 3 passed.
- `git diff --check`: passed. `task --list`: parsed the task file.

## Limits and next work
- No public application catalog is hosted. HTTPS installation accepts a direct ZIP URL.
- Linux minimal images and packages have not been run on this Windows host.
- Generated `applications/packages/` and `target/` outputs are ignored. `target.old/` was already present and must be left alone.
