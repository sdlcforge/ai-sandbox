# Fix Orphaned Docker-Proxy Sidecar And Network On Instance Teardown

## Purpose and scope

`ai-sandbox <name> delete` (and, as this plan's investigation found, several
sibling per-instance commands) can silently leave Docker resources behind when
the instance was built with the `docker` capability — the
`tecnativa/docker-socket-proxy` sidecar plus its private `docker-proxy` Compose
network, both defined in `docker/docker-compose.proxy.yaml` (see
`docs/architecture.md`'s "Docker access: proxy, not socket or DinD" section and
`docs/ai-sandbox-profiles-spec.md`'s `docker` capability entry).

### Root cause

`delete` already uses the architecturally-correct `docker compose down` (full
project teardown, not a single-service `rm`/`stop`) at `src/index.sh:434` — the
hypothesis floated in the original bug report (that `delete` needs
`--remove-orphans` or full-project scoping instead of a single-service
stop/rm) is **not** what's wrong. The actual defect is upstream: the **set of
`-f` compose files** passed to that otherwise-correct `down` invocation is
derived from the *current invocation's* profile flags, not from the
container's actual persisted composition.

- `EFFECTIVE_PROXY` (`src/index.sh:270-274`) — which decides whether
  `docker/docker-compose.proxy.yaml` (the sole definition of the
  `docker-socket-proxy` service and the `docker-proxy` network) is added to
  `COMPOSE_FILES` (`src/index.sh:350-352`) — is derived from
  `profile_has_capability docker`, which reads `PROFILE_CAPABILITIES` as
  resolved by `bin/profile-installer.js` from the current invocation's
  `PROFILES` array (`src/index.sh:143-158`).
- `PROFILES` is empty unless `--profile` is passed on *this* invocation, or
  unless `restore_saved_config()` (`src/utils.sh:139-226`) has rehydrated it
  from the container's persisted `ai.sandbox.config` Docker label (written at
  `create`/`start`/`enter` time — see `docs/architecture.md`'s "Config
  persistence and restore" section).
- `restore_saved_config()` is currently invoked **only** when `CMD` is `start`
  or `enter` (`src/index.sh:135-137`). Every other per-instance command that
  acts on an *already-created* container — `stop`, `delete`, `clean`, `build`,
  `fix-ssh`, `user-exec`, `root-exec`, `up`, and the general docker-compose
  passthrough (`src/index.sh:446`) — skips it. A user who created an instance
  with `--profile docker` and later runs a bare `ai-sandbox <name> delete` (no
  reason to re-type `--profile docker` on a teardown command) gets
  `PROFILES=()` → default composition (no `docker` capability) →
  `EFFECTIVE_PROXY=false` → `COMPOSE_FILES` omits
  `docker-compose.proxy.yaml` → `docker compose ... down` has no knowledge of
  the sidecar service/network and cannot remove them. Result: `ai-sandbox
  <name> delete` reports success while the docker-socket-proxy container and
  the project's `docker-proxy` network remain on the host, invisible to
  `ai-sandbox ls`.

The same root cause reaches beyond `delete`:

- **`stop`** — the sidecar is not stopped when the main container is stopped
  (it has `restart: unless-stopped`), an inconsistent partial teardown.
- **`clean`** — same `down`-scope omission as `delete`; the explicit
  `docker rm -f "$(sandbox_container_name)"` (`src/index.sh:443`) only targets
  the main container by name, not the sidecar.
- **`fix-ssh`** (`fix_ssh()`, `src/utils.sh:495-505`) — recreates only the
  `ai-sandbox` service (`--no-deps`) using the same possibly-incomplete
  `COMPOSE_FILES`. On a docker-capable container, a bare `fix-ssh` (no
  `--profile docker`) silently drops the `docker-proxy` network attachment and
  `DOCKER_HOST` env var from the recreated container. The sidecar itself
  survives (protected by `--no-deps`), but the main container permanently
  loses Docker access until the user notices and manually recreates with
  `--profile docker` again — arguably a worse symptom (silent capability loss)
  than the resource-orphan case, but the same root cause.
- **`build`** (`do_build()`, `src/utils.sh:400-403`) — the Dockerfile-assembly
  step (`src/index.sh:294-301`) runs before dispatch using the same
  un-restored `PROFILE_CAPABILITIES`. A bare `ai-sandbox <name> build` (no
  `--profile docker`) rebuilds the image from a Dockerfile assembled *without*
  the `docker` capability fragment.
- **`user-exec`/`root-exec`/`attach`** — exec into the already-running
  container by service name; the `COMPOSE_FILES` omission has no destructive
  effect here (nothing is created/recreated), so these are lower-priority /
  informational findings from the audit, not fix targets.

Also discovered during the audit of these same commands (a related but
distinct defect): `do_build()` and `fix_ssh()` are the only two
`docker compose` call sites in the codebase that omit
`-p "${COMPOSE_PROJECT}"` — every other call site (`src/index.sh`,
`src/create.sh`, `start_shell()`) passes it. Without `-p`, these two commands
resolve against Compose's default project-name derivation instead of the
named instance's actual project — the same class of bug the existing
`start_shell()` regression test (`test/unit/ai_sandbox_spec.sh:181-193`)
already caught and fixed for `exec`.

**Explicitly not in scope:** the previously-fixed, unrelated "ARGS unbound
variable" bug affecting `down` vs `delete` (a shell-nounset issue) — do not
conflate it with this compose-file-scope defect.

## Current status

No code changes have been made yet. This plan has one implementation phase
(the fix plus regression tests) followed by a documentation-update phase,
triggered because the fix changes behavior that `docs/architecture.md`'s
"Config persistence and restore" section explicitly documents as scoped to "a
bare `start`/`enter`". Phase 1, Task 1 is the entry point; Phase 2 depends on
Phase 1 landing.

## Overview

### Phase 1 — Fix Orphaned Sidecar Teardown

Single task (no internal parallelism — the root-cause fix is one conditional
change in `src/index.sh` that every regression scenario below exercises):

- **Task 1 — Restore Config For Teardown Commands.** Broadens
  `restore_saved_config()`'s trigger from `start`/`enter` only to every
  per-instance command that can act on an existing container (i.e. every
  `CMD` except `create`), recommended via an extracted, unit-testable
  predicate (e.g. `should_restore_config()`) since the current call site is
  top-level `src/index.sh` code past the `__SOURCED__` return guard and
  therefore invisible to `test/unit/` specs that `Include` the rolled-up
  script. Also fixes the missing `-p "${COMPOSE_PROJECT}"` flag on
  `do_build()`/`fix_ssh()`. Adds integration regression tests (live Docker)
  reproducing the orphaned sidecar container/network on `delete`/`clean`, the
  not-fully-stopped sidecar on `stop`, and the silently-dropped Docker
  capability on `fix-ssh`; adds unit regression tests for the extracted
  predicate and the `-p` flag fix.

### Phase 2 — Documentation Updates

- **Task 1 — Update Architecture Docs.** Reviews and updates
  `docs/architecture.md`'s "Config persistence and restore" section (and the
  related "Docker access" callout) to reflect the broadened restore scope, and
  reviews `docs/ai-sandbox-profiles-spec.md` for any needed touch-ups (none
  expected, but the `docs/*-spec.md` glob resolves to exactly this one file).
  Depends on Phase 1 Task 1 being complete — it documents the shipped
  behavior, not the plan.
