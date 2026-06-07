# Overview: Profiles Feature Implementation

## Purpose and scope

Implement the ai-sandbox **profiles** feature specified in
[`docs/ai-sandbox-profiles-spec.md`](../docs/ai-sandbox-profiles-spec.md). The
prior round (Phase 01) produced the spec and reference docs; this round writes
the code: bundled profile YAML, the `profile-installer.js` Node boundary, a
decomposed Dockerfile with capability fragments, CLI wiring for `--profile` /
`--mode` (and removal of `--docker` / `--no-docker` / `--no-chromium`),
composition-hash image tagging, the `create-profile` command, and the test
updates that lock it all in.

Constraints carried through every task:
- Edit `src/` modules only; `make build` rolls them into `bin/ai-sandbox.sh`
  (never hand-edit the rollup). Preserve the `${__SOURCED__:+return}` guard.
- `shellcheck` (`make lint`) must pass on all `src/`, `docker/`, `test/` files;
  any `# shellcheck disable` needs an inline reason.
- `js-yaml` is the YAML library (added in Task 001).
- User is the sole user — removed flags become hard errors pointing at the
  profile equivalent; no deprecation shims.
- `make lint` + `make test` must pass at the plan's end.

## Current status

Phase 04 complete: all three CLI integration tasks (004, 005, 006) merged. --profile/--mode flags, profile resolution phase, enhanced is_build_stale() with profile hash + file mtime checks, --hash support in assemble-dockerfile.sh, create-profile command. Unit suite 58/58. Phase 05 (Task 007: tests and QA gate) is next.

## Overview

Four implementation phases plus a verification phase, seven tasks total.

### Dependency table

| # | Task | Phase | Tier | Depends on | Parallel-eligible with |
|---|------|-------|------|------------|------------------------|
| 001 | Bundled profile YAML + js-yaml dep | 02 Foundation | `sonnet-high` | — | 003 |
| 002 | `bin/profile-installer.js` | 02 Foundation | `opus-medium` | 001 | 003 |
| 003 | Dockerfile decomposition + assembly | 03 Decomposition | `sonnet-high` | — | 001, 002 |
| 004 | CLI: options.sh + index.sh wiring | 04 CLI | `opus-medium` | 002, 003 | — |
| 005 | Image tagging by hash (utils.sh) | 04 CLI | `sonnet-high` | 002 | 006 |
| 006 | `create-profile` command | 04 CLI | `sonnet-high` | 002 | 005 |
| 007 | Test updates + build/lint/test gate | 05 Verification | `opus-medium` | 001–006 | — |

### Parallel-eligible groups

- **Group A (start immediately, in parallel):** Task 001 and Task 003. Task 003
  touches only `docker/`; Task 001 touches `profiles/` + `package.json`. No file
  overlap.
- **Group B (after 002):** Task 005 and Task 006 are parallel-eligible with each
  other. 005 edits `src/utils.sh`; 006 adds `src/create-profile.sh` + a small
  `src/index.sh` dispatch branch. Note: Task 004 also edits `src/index.sh`
  heavily — sequence 004 before/with care relative to 006's `index.sh` dispatch
  add to avoid merge conflicts, OR have 006 limit its `index.sh` footprint to a
  single dispatch branch + source line and rebase on 004. Recommended ordering:
  004 first, then 005 + 006 in parallel.

### Critical path

`001 → 002 → 004 → 007`

Task 002 is the load-bearing interface; Task 004 is the heaviest integration
(both `opus-medium`). Task 003 runs alongside the 001→002 chain and rejoins at
004. Tasks 005 and 006 fan out after 002 and rejoin at 007.

### Phase summary

- **Phase 02 — Foundation:** bundled profiles + the Node installer that parses,
  composes, validates, and emits the bash-consumable output blocks.
- **Phase 03 — Dockerfile Decomposition:** base fragment + capability fragments
  + assembly script (parallel with Phase 02).
- **Phase 04 — CLI Integration:** flag changes, installer invocation, capability
  → overlay/assembly wiring, hash-based image tagging, `create-profile`.
- **Phase 05 — Verification:** test updates and the full build/lint/test gate.
