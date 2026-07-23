# syntax=docker/dockerfile:1
#
# minia2 — Active Oberon SDK as a Docker image (Go-style toolchain).
#
# Build from the repository root:
#     docker build -f docker/Dockerfile -t minia2-sdk .
#
# Then compile/run Active Oberon straight from the shell:
#     docker run --rm -v "$PWD:/work" minia2-sdk run Hello.Mod
#     docker run --rm -v "$PWD:/work" minia2-sdk compile Hello.Mod -o out
#
# Two stages: (1) build the A2 runtime + stdlib from source with the repo's own
# self-hosting toolchain (`task Linux64`); (2) ship only the runtime + the
# precompiled standard library + the `ob` wrapper on a slim glibc base.

# ---------------------------------------------------------------------------
# Stage 1 — build the Linux64 runtime and standard library from source.
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git wget \
    && rm -rf /var/lib/apt/lists/*

# go-task (build orchestrator) + yq (parses configs/env.yml).
RUN curl -sL https://taskfile.dev/install.sh | sh -s -- -d -b /usr/local/bin \
    && wget -qO /usr/local/bin/yq \
        https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
    && chmod +x /usr/local/bin/yq \
    && task --version && yq --version

WORKDIR /src
COPY . /src

# Produces target/Linux64 (Unix64 stdlib .SymUu/.GofUu) and target/Win64 (Win64
# stdlib .SymWw/.GofWw) — both cross-built from the same Linux host toolchain.
RUN task Linux64 && task Win64

# Assemble the SDK payload: the Linux runtime + headless-core stdlib for both
# targets (see docker/headless-core.txt — everything whose import closure never
# reaches the window manager / display / raster). The Win64 lib enables
# `ob build -t win64` (cross-compiled .exe); the win-specific boot modules
# (Kernel32, WinFS) come from configs/moduleListWin.txt.
RUN set -eu; \
    mkdir -p /opt/a2sdk/lib /opt/a2sdk/lib-win64 /opt/a2sdk/lib-sym; \
    cp target/Linux64/oberon      /opt/a2sdk/oberon; \
    cp target/Linux64/oberon.cfg  /opt/a2sdk/oberon.cfg; \
    cp configs/moduleListLinux.txt /opt/a2sdk/boot-modules.txt; \
    cp configs/moduleListWin.txt   /opt/a2sdk/boot-modules-win64.txt; \
    while read -r m; do \
        for e in SymUu GofUu; do \
            [ -f "target/Linux64/bin/$m.$e" ] && \
                cp "target/Linux64/bin/$m.$e" /opt/a2sdk/lib/ || true; \
        done; \
    done < docker/headless-core.txt; \
    cp target/Linux64/bin/*.SymUu /opt/a2sdk/lib-sym/; \
    { cat docker/headless-core.txt configs/moduleListWin.txt; } | sort -u | \
    while read -r m; do \
        for e in SymWw GofWw; do \
            [ -f "target/Win64/bin/$m.$e" ] && \
                cp "target/Win64/bin/$m.$e" /opt/a2sdk/lib-win64/ || true; \
        done; \
    done; \
    echo "SDK lib (linux64): $(ls /opt/a2sdk/lib/*.SymUu | wc -l) modules, $(du -sh /opt/a2sdk/lib | cut -f1)"; \
    echo "SDK lib (win64):   $(ls /opt/a2sdk/lib-win64/*.SymWw | wc -l) modules, $(du -sh /opt/a2sdk/lib-win64 | cut -f1)"; \
    echo "SDK lib-sym (LSP): $(ls /opt/a2sdk/lib-sym/*.SymUu | wc -l) symbols, $(du -sh /opt/a2sdk/lib-sym | cut -f1)"

# ---------------------------------------------------------------------------
# Stage 2 — the SDK image: runtime + stdlib + `ob` wrapper on a slim base.
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS sdk

# The A2 runtime itself needs no apt packages (dynamically-linked glibc ELF —
# libc.so.6 + libdl.so.2 + ld-linux, all in the base). The desktop `data/` tree
# (fonts, wallpapers, skins) is deliberately NOT copied — headless compile/run
# never touches it, and it was ~48MB.
#
# `git`, `jq` and `ca-certificates` are added only for the package manager
# (`ob get` clones package repos; `ob get`/`ob lint` read a2pkg.json via jq). The
# `ob` script guards both with `have` and degrades gracefully, so a size-minimal
# variant image can drop this layer if it does not need `ob get`.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git jq ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV A2SDK=/opt/a2sdk \
    A2_PLATFORM=Unix64 \
    TMPDIR=/tmp

# The whole SDK payload (runtime + oberon.cfg + headless-core lib/) was
# assembled at /opt/a2sdk in the builder stage.
COPY --from=builder /opt/a2sdk ${A2SDK}

# A2 is BSD-3-Clause (ETH Zurich); binary redistribution requires reproducing the
# copyright notice + disclaimer with the distribution. Bundle it in the image.
COPY license.txt /opt/a2sdk/LICENSE.txt

# Std package manifests (the layered decomposition) so `ob lint` has the
# module->tier map and `ob get` can satisfy std/* requirements from the image.
COPY packages ${A2SDK}/packages

COPY docker/ob /usr/local/bin/ob
RUN chmod +x ${A2SDK}/oberon /usr/local/bin/ob

# Unprivileged user; /work is the bind-mount point for user sources.
RUN useradd -m -u 1000 oberon && mkdir -p /work && chown oberon:oberon /work
USER oberon
WORKDIR /work

ENTRYPOINT ["ob"]
CMD ["version"]
