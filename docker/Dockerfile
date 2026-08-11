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

# The AArch64 standard library: compiled by the same Linux host compiler with
# -p=UnixA64 into target/A64/bin. There is no `task A64` -- an A64 build cannot run
# its own compiler here -- so the modules are compiled straight from the list.
RUN tests/a64-runtime-check.sh target/Linux64 target/A64/bin \
    && tests/a64-stdlib-check.sh target/Linux64 target/A64/bin

# The SDK payload, by the same script that assembles the tarball release, so the image
# and the tarball are one SDK and cannot drift apart. --no-tar: the layer is the
# artefact. SDK_VERSION comes in as a build argument because .git is not in the build
# context (Dockerfile.dockerignore), so the payload cannot describe the tree itself.
ARG SDK_VERSION=docker
RUN A2_SDK_VERSION="$SDK_VERSION" tests/bundle.sh --no-tar -o /opt/a2sdk target/Linux64

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

# Runtime, the three lib/ trees, lib-sym/ for the language server, packages/, examples,
# suites, LICENSE.txt (BSD-3-Clause, ETH Zurich -- binary redistribution must carry the
# notice) and `ob`: all of it assembled at /opt/a2sdk by tests/bundle.sh in the builder.
COPY --from=builder /opt/a2sdk ${A2SDK}

# The same `ob` on the PATH, which is what the ENTRYPOINT runs; A2SDK is set, so it makes
# no difference which of the two copies is invoked.
COPY sdk/ob /usr/local/bin/ob
RUN chmod +x ${A2SDK}/oberon /usr/local/bin/ob

# Unprivileged user; /work is the bind-mount point for user sources.
RUN useradd -m -u 1000 oberon && mkdir -p /work && chown oberon:oberon /work
USER oberon
WORKDIR /work

ENTRYPOINT ["ob"]
CMD ["version"]
