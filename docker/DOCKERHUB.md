# minia2 — Active Oberon SDK

A Go-style toolchain for **A2 / Active Oberon**, packaged as one image. Compile and
**build standalone native executables** with the A2 runtime baked in — the output
runs on any glibc Linux box (or Windows, cross-built) with no A2 install.

> Image is **linux/amd64** only (the compiler/runtime is an x86-64 binary). On
> Apple Silicon it runs under emulation.

## Quick start

```sh
# a tiny module
cat > Hello.Mod <<'EOF'
MODULE Hello;
IMPORT KernelLog;
	PROCEDURE Do*;
	BEGIN KernelLog.String("Hello from A2!"); KernelLog.Ln
	END Do;
END Hello.
EOF

# compile + run (like `go run`)
docker run --rm -v "$PWD:/work" puhachenko/minia2-sdk run Hello.Mod

# build a standalone Linux binary (like `go build`) — auto-runs, no A2 needed
docker run --rm -v "$PWD:/work" puhachenko/minia2-sdk build Hello.Mod -o hello
./hello                                   # -> Hello from A2!

# cross-build a Windows .exe from the same image
docker run --rm -v "$PWD:/work" puhachenko/minia2-sdk build Hello.Mod -t win64 -o hello.exe
```

Handy alias:

```sh
alias ob='docker run --rm -v "$PWD:/work" puhachenko/minia2-sdk'
ob build Hello.Mod -o hello && ./hello
```

## The `ob` CLI

| Verb | Does |
|------|------|
| `ob run <File.Mod> [Proc]` | compile + execute (`go run` model) |
| `ob build <File.Mod> [-o name] [-t linux64\|win64] [Proc]` | standalone executable (`go build` model) |
| `ob compile <File.Mod> [-o dir]` | just the `.GofUu` object file |
| `ob repl` / `ob version` | interactive shell / SDK banner |

## What you can build

Headless console & server programs from a 384-module standard library: files, streams,
strings, arbitrary-precision math, **crypto** (AES/RSA/SHA/DSA), compression (zlib/zip),
XML, JSON, and **networking** (TCP/UDP/DNS, HTTP client & server). GUI apps are out of scope
(no window manager in the headless core).

## Notes

- Standalone binaries embed the full A2 runtime (kernel + GC + scheduler), so hello-world
  is ≈1.3 MB. Dead-code elimination is module-granular.
- Windows `.exe` is a PE64 console image (confirmed under Wine).

## License & source

A2 is **BSD-3-Clause** © ETH Zürich (bundled at `/opt/a2sdk/LICENSE.txt`).
Source & Dockerfile: https://gitlab.com/a25665725/minia2 (`docker/`).
