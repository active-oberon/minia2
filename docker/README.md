# The SDK as a container image

This directory is the image and nothing else: `Dockerfile`, its ignore file, and what publishes
the description to Docker Hub (`DOCKERHUB.md`, `hub-description.sh`).

**The manual is [`../docs/SDK.md`](../docs/SDK.md).** It covers the `ob` verbs, the three tarball
hosts, the language server and the limitations — the image is one of four ways to have that same
payload, so its documentation lives with the SDK rather than here.

```sh
task sdk                      # build the image (IMAGE=… TAG=… to name it)
docker run --rm -v "$PWD:/work" minia2-sdk run Hello.Mod
bash docker/hub-description.sh   # push the Hub description, made out of docs/SDK.md
```

What used to be here and where it went, 2026-08-24: `examples/` (the tarballs ship them, so they
are `../examples/`), `headless-core*.txt` (the SDK payload list, so `../configs/`),
`gen-headless-core.sh` (its generator, beside the AArch64 one in `../tests/`), and `README.md`
itself (`../docs/SDK.md`).
