# Dockerfile Decomposition into Base + Capability Fragments

## Purpose and scope

Decompose the monolithic `docker/Dockerfile` into a always-included base
fragment plus per-capability fragments, and add an assembly step that
concatenates the base fragment with the fragments for the capabilities selected
by a profile composition. This replaces the `INSTALL_CHROMIUM` /
`INSTALL_DOCKER_CLI` ARG-gated conditional blocks with composable fragments.

This task is independent of the Node work (Tasks 001, 002) at the file level and
can be done in parallel — but the capability fragment basenames it produces
(`docker`, `chromium`) are the contract that Task 002's capability validation
and Task 001's `capabilities:` lists rely on. Use exactly those names.

The canonical source of truth is
[`docs/ai-sandbox-profiles-spec.md`](../../docs/ai-sandbox-profiles-spec.md),
sections "Capabilities reference" and the `profile-installer.js`
"Resolve capabilities to Dockerfile fragments" responsibility.

## Requirements

### Create the base fragment: `docker/Dockerfile.base`

Move all of the current `docker/Dockerfile` content into `docker/Dockerfile.base`
EXCEPT the two capability-gated blocks (see below). Specifically:

- Keep: `FROM ubuntu:latest`, LAYER 1a (core apt), LAYER 1c (developer apt),
  LAYER 1d (s6-overlay), LAYER 2 (timezone/ssh dir), LAYER 3/3b (Go,
  golangci-lint), LAYER 4 (git-delta), LAYER 5 (zsh-in-docker), LAYER 6 (user),
  LAYER 7 (nvm/node), LAYER 8 (bun), LAYER 9 (workspace env), LAYER 10 (Claude
  Code), LAYER 11/11.b (firewall + sudoers), LAYER 12 (shell config — see note),
  LAYER 12b (git config), LAYER 13 (claude.json), LAYER 14 (s6 scripts +
  sandbox-volumes), LAYER 15 labels (see note), and the `ENTRYPOINT ["/init"]`.
- The base fragment ends with the `ENTRYPOINT` line so it is the foundation onto
  which capability fragments are appended BEFORE the entrypoint, OR keep the
  entrypoint as the final line of the assembled Dockerfile. Decide one approach
  and apply consistently: **append capability fragments before `ENTRYPOINT`**.
  To make that mechanical, structure `Dockerfile.base` with a clearly marked
  split: everything up to (but not including) `ENTRYPOINT` in the main body, and
  emit the `ENTRYPOINT` line from the assembly script as the final appended line
  (see assembly below). Document this split with a comment.

Removals / adjustments in the base fragment:

- Remove LAYER 1b (Chromium block) entirely — moves to the chromium fragment.
- Remove LAYER 1c2 (Docker CLI block) entirely — moves to the docker fragment.
- Remove the `INSTALL_CHROMIUM` / `INSTALL_DOCKER_CLI` ARGs and the LAYER 15
  `ai.sandbox.chromium-enabled` / `ai.sandbox.docker-enabled` LABELs (capability
  state is now tracked by the image tag/hash, not ARG labels). If a label is
  still desired for `running_config_matches` purposes, that is handled via
  compose labels in Task 004, not build ARGs — do not reintroduce the ARGs here.
- Remove the chromium alias `RUN if [ "$INSTALL_CHROMIUM" = "true" ]...` from
  LAYER 12; the chromium alias moves into the chromium fragment.

### Create `docker/capabilities/docker.dockerfile`

- Contains the Docker CLI install block (former LAYER 1c2), with the
  `if [ "$INSTALL_DOCKER_CLI" = "true" ]` conditional removed — the fragment is
  only ever concatenated when the `docker` capability is selected, so install
  unconditionally.
- No `FROM` line (it is a fragment appended after the base body).

### Create `docker/capabilities/chromium.dockerfile`

- Contains the Chromium + X11 install block (former LAYER 1b), conditional
  removed (unconditional install).
- Contains the chromium alias line (`echo "alias chromium='chromium
  --no-sandbox'" >> .zshrc`) so the alias is present only when chromium is
  selected. Ensure the `USER` context is correct (the alias write runs as
  `${HOST_USER}`; the apt install runs as root — add explicit `USER root` /
  `USER ${HOST_USER}` directives within the fragment so it is self-contained
  regardless of the preceding base body's final USER).

### Add the assembly step

The effective Dockerfile is the base body + selected capability fragments +
`ENTRYPOINT`. Provide a small assembly script invoked at build time:

- Create `docker/scripts/assemble-dockerfile.sh` (bash). Inputs: a space-
  separated capability list (from `PROFILE_CAPABILITIES`) and an output path.
  It concatenates `docker/Dockerfile.base` (body), then for each capability (in
  sorted order to match the hash) `docker/capabilities/<cap>.dockerfile`, then
  the `ENTRYPOINT ["/init"]` line, into the output path.
- The script must `shellcheck` clean. Use a shebang `#!/usr/bin/env bash`,
  `set -euo pipefail`, and quote all expansions. If a requested capability
  fragment is missing, exit nonzero with a clear error (defense in depth — Task
  002 also validates).
- Output location: write the assembled file to a build-cache path the compose
  build can reference, e.g.
  `${XDG_CACHE_HOME:-$HOME/.cache}/ai-sandbox/Dockerfile.<hash>` (the bash
  launcher in Task 004 passes the hash + capability list). The exact path
  contract is shared with Task 004 — state it in a comment at the top of the
  script and reference it from this task doc.
- Integration with compose: `docker/docker-compose.yaml` currently hardcodes
  `dockerfile: Dockerfile`. Task 004 owns changing compose/launcher to point at
  the assembled file; THIS task only needs to (a) produce the fragments and (b)
  provide the assembly script with a documented CLI and output-path contract.
  Note this hand-off explicitly so Task 004 wires it.

### Makefile / lint considerations

- Makefiles under `make/` are generated by `@sdlcforge/gen-make` and carry a
  "Do not edit manually" header — do NOT hand-edit them. If the assembly script
  needs to be invoked by `make build`, that wiring belongs to the launcher
  (Task 004), not a hand-edited Makefile fragment. If a generated target is
  genuinely required, flag it for the manager rather than editing generated
  files.
- `make lint` runs shellcheck across `src/`, `docker/`, `test/`. The new
  `docker/scripts/assemble-dockerfile.sh` will be linted — ensure it passes.

### Integration points

- **Task 001** capability names must equal fragment basenames (`docker`,
  `chromium`).
- **Task 002** validates fragment existence at these paths.
- **Task 004** wires the assembly script + assembled-Dockerfile path into the
  compose build and removes the `INSTALL_CHROMIUM`/`INSTALL_DOCKER_CLI` build
  args from `docker-compose.yaml` / `docker-compose.chromium.yaml`.

## Validation

- `docker/Dockerfile.base`, `docker/capabilities/docker.dockerfile`,
  `docker/capabilities/chromium.dockerfile`,
  `docker/scripts/assemble-dockerfile.sh` all exist.
- `grep -L INSTALL_CHROMIUM docker/Dockerfile.base` confirms the ARG is gone from
  the base (i.e. grep finds no match). Same for `INSTALL_DOCKER_CLI`.
- `shellcheck docker/scripts/assemble-dockerfile.sh` passes (or `make lint`).
- Assembly smoke test:
  `bash docker/scripts/assemble-dockerfile.sh "docker chromium" /tmp/Dockerfile.test`
  produces a file that contains the base `FROM ubuntu`, the docker-ce-cli install,
  the chromium install, and ends with `ENTRYPOINT ["/init"]`.
- Assembly with empty capability list
  `bash docker/scripts/assemble-dockerfile.sh "" /tmp/Dockerfile.lean` produces a
  file with the base body + entrypoint and NO docker-ce-cli / chromium install.
- Requesting a missing capability
  `bash docker/scripts/assemble-dockerfile.sh "nope" /tmp/x` exits nonzero.

## Assumptions

- Capability fragments are concatenated as raw Dockerfile text; BuildKit accepts
  a multi-stage-free linear Dockerfile assembled this way. The existing single
  `FROM` lives in the base; fragments add only `RUN`/`USER`/`ENV` directives.
- The `tool-cache` additional build context and tool ARGs in the base remain
  unchanged; capability fragments do not need tool-cache COPYs.

## References

- [`docs/ai-sandbox-profiles-spec.md`](../../docs/ai-sandbox-profiles-spec.md) —
  "Capabilities reference".
- `docker/Dockerfile` — source of the LAYER 1b / 1c2 blocks being extracted.
- `docker/docker-compose.chromium.yaml`, `docker/docker-compose.proxy.yaml` —
  current overlay behavior that capabilities subsume.
