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

# Produces /src/target/Linux64/{oberon, bin/, data/, ...} — the self-contained
# runtime plus 700+ precompiled stdlib .SymUu/.GofUu files.
RUN task Linux64

# ---------------------------------------------------------------------------
# Stage 2 — the SDK image: runtime + stdlib + `ob` wrapper on a slim base.
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS sdk

# No apt install needed: the A2 runtime is a dynamically-linked glibc ELF
# (libc.so.6 + libdl.so.2 + ld-linux), all already present in the base image.
# The desktop `data/` tree (fonts, wallpapers, skins) is deliberately NOT copied
# — headless compile/run never touches it, and it was ~48MB of the image.

ENV A2SDK=/opt/a2sdk \
    A2_PLATFORM=Unix64 \
    TMPDIR=/tmp

# Runtime binary + runtime config (config only matters for `ob repl`).
COPY --from=builder /src/target/Linux64/oberon     ${A2SDK}/oberon
COPY --from=builder /src/target/Linux64/oberon.cfg ${A2SDK}/oberon.cfg
# The precompiled standard library (symbol + object files) lives under lib/.
COPY --from=builder /src/target/Linux64/bin        ${A2SDK}/lib

COPY docker/ob /usr/local/bin/ob
RUN chmod +x ${A2SDK}/oberon /usr/local/bin/ob

# Unprivileged user; /work is the bind-mount point for user sources.
RUN useradd -m -u 1000 oberon && mkdir -p /work && chown oberon:oberon /work
USER oberon
WORKDIR /work

ENTRYPOINT ["ob"]
CMD ["version"]
