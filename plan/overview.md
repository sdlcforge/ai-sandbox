# Static Playground Overlay

## Purpose and scope

Add an opt-in `--static-playground` flag to the `ai-sandbox` CLI. When set, the
container gets a copy-on-write overlayfs view of the host's `~/playground`
directory: every real file is visible with no upfront copy, but any write from
inside the container is isolated to the container and never touches the host.

Today `docker/docker-compose.yaml` unconditionally bind-mounts `~/playground`
read-write into the container, so any in-container write — including from a
compromised or misbehaving agent — lands on the host's real files. This feature
extends the existing, on-by-default `~/.config` isolation mechanism
(`docker-compose.isolate-config.yaml` + `02-overlay-config` cont-init + the
generic `sandbox-volumes` registry tool) to `~/playground`, gated behind a new
opt-in flag.

The flag is **opt-in** (default OFF), unlike config isolation (on-by-default,
opt-out via `--no-isolate-config`), because it changes a path users currently
rely on being always host-writable.

The design was fully investigated and user-approved in a prior planning session.
It is captured self-contained in
[static-playground design note](./notes/static-playground-design.md), which is
the authoritative reference for every task below. Its three empirically-verified
findings (Compose same-target replacement, duplicate `security_opt` validation
error, and shared-registry idempotency) drive several non-obvious design choices
and required edits to existing working files; read that note before implementing.

### What must change

- A new boolean CLI flag `--static-playground` (default off), parsed, exported,
  and round-tripped through the persisted `ai.sandbox.config` label like every
  other config-changing flag.
- A new shared compose fragment (`docker-compose.overlay-privileges.yaml`) that
  extracts the `CAP_SYS_ADMIN` / `apparmor=unconfined` block out of the existing
  `docker-compose.isolate-config.yaml`, included at most once whenever either
  overlay is active.
- A new playground overlay compose file (`docker-compose.static-playground.yaml`)
  using a Compose-scoped named volume (`playground-overlay`) for the overlay
  upper+work layers and re-declaring the base `~/playground` mount as read-only.
- A new cont-init stage (`06-overlay-playground`) that performs the overlay
  mount, plus a companion idempotency fix to the existing `02-overlay-config`
  registry write.
- Launcher wiring in `src/index.sh` (compose-file assembly regardless of mode,
  config-JSON 9th field, label, and targeted named-volume cleanup on
  `delete`/`clean`), `src/options.sh` (flag), and `src/utils.sh` (restore +
  running-config-match for the new dimension).
- A required bug fix in `src/volume-override.sh`: the existing
  `~/playground` double-mount skip-guard covers only the marketplace-mount path,
  not the earlier user-declared volume-maps loop — a real gap the new overlay
  would silently trigger.
- Unit and integration test coverage mirroring existing patterns.
- User-facing documentation (`README.md`) and architecture documentation
  (`docs/architecture.md`, via the doc-updates phase).

### What must NOT change

- Config isolation (`~/.config`) behavior and its default-on posture must be
  preserved exactly — the privileges-fragment extraction is a refactor with no
  behavior change for the config overlay.
- The `firewall-handshake` named volume must not be affected by the new
  delete/clean cleanup (no blanket `down -v`).
- The strict, non-substring plugin/path matching conventions elsewhere in the
  codebase are out of scope and untouched.
- `sandbox-volumes` itself is not modified — it is already generic and
  registry-driven.
- No `docker/Dockerfile*` changes are needed (the `/var/lib/ai-sandbox-rw`
  parent hardening already covers the new sibling subdir).

### Success criteria

- `ai-sandbox instances create <name> --static-playground` boots a container
  where `~/playground` is an overlayfs mount: host content is visible
  read-through with no upfront copy, and a container-side write is invisible on
  the host.
- The default configuration (mirror mode + config isolation, no
  `--static-playground`) is unchanged and all existing tests still pass.
- The `--static-playground` value persists across bare per-instance commands via
  the config label and is honored on `delete`/`clean` for named-volume cleanup.
- `make lint`, `make test.unit`, and `make test.integration` pass.

## Current status

Not started. This is a single-phase feature plan plus a documentation-updates
phase added by the architectural-implications check. The `playground-isolation`
phase begins first; its `cli-flag-and-config-persistence` task is the entry
point (the docker-overlay-mechanism task depends on the `STATIC_PLAYGROUND`
global it introduces). The `doc-updates` phase runs last, after the feature's
implementation tasks have landed.

Pre-conditions: the plan worktree is on branch `plan/static-playground`. All
referenced source files, compose files, and cont-init scripts exist and their
design anchors were verified against this checkout. A stale
`plan/notes/investigation-findings.md` from an unrelated prior `lockdown-egress`
session is present in the worktree and is not part of this plan.

## Overview

Single feature phase followed by a documentation phase.

### Phase 01 — Playground Isolation

Implements the complete feature. Tasks, in dependency order:

1. **`001-cli-flag-and-config-persistence`** — introduce the `--static-playground`
   flag (`src/options.sh`), the `static_playground` 9th field in the persisted
   config JSON and the `ai.sandbox.static-playground` label (`src/index.sh`,
   `docker/docker-compose.yaml`), and restore/running-config-match handling for
   the new dimension (`src/utils.sh`). Makes the flag exist and round-trip; it is
   an inert no-op until the overlay mechanism lands. *Architectural impact:*
   extends the tracked config-persistence dimension set.

2. **`002-docker-overlay-mechanism`** — the core overlay: the shared
   `docker-compose.overlay-privileges.yaml` fragment (extracted from
   `docker-compose.isolate-config.yaml`), the `docker-compose.static-playground.yaml`
   overlay file with its named volume and read-only base-mount override, the
   `06-overlay-playground` cont-init stage plus the `02-overlay-config`
   idempotent-registry companion fix, the `COMPOSE_FILES` assembly wiring
   (mode-independent, privileges-fragment-once), and the targeted named-volume
   cleanup on `delete`/`clean` (`src/index.sh`). Depends on Task 001 for the
   `STATIC_PLAYGROUND` global. *Architectural impact:* new isolation subsystem,
   new compose topology, new tracked named volume.

3. **`003-volume-override-skip-guard-fix`** — extend the existing
   `~/playground` double-mount skip-guard in `src/volume-override.sh` to the
   user-declared volume-maps loop. Independent of Tasks 001/002; parallel-eligible.

4. **`004-unit-tests`** — ShellSpec unit coverage in
   `test/unit/ai_sandbox_spec.sh`: flag parsing, `restore_saved_config()`
   round-trip + regression, `running_config_matches()` match/mismatch, and
   `generate_volume_override()` skip-guard coverage. Depends on Tasks 001–003.

5. **`005-integration-test`** — new `test/integration/static_playground_spec.sh`
   named-instance spec covering env-var visibility, overlay fstype, read-through
   with no upfront copy, host-invisible container write, `sandbox-volumes list`
   row, and named-volume removal on delete. Depends on Task 002.

6. **`006-readme-documentation`** — `README.md` flags-table entry, new
   `### Playground isolation` section, `--mode static` disambiguation, and the
   documented open risks. Can be written from the design note; parallel-eligible.

**Parallelism:** Tasks 001, 003, and 006 can start concurrently. Task 002
depends on 001; Tasks 004 and 005 run after their dependencies land and are
mutually parallel (004 edits the unit spec; 005 creates a new integration spec —
no shared files).

### Phase 02 — Documentation Updates

Added by the architectural-implications check. A single
`update-architecture-docs` task revises `docs/architecture.md` to add the
playground-isolation subsystem subsection and update the config-persistence
"eight-dimension" language to nine. Runs after the Phase 01 implementation tasks
have landed.
</content>
