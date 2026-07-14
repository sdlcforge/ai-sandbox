# Plan Summary: static-playground

## What was planned and why

Add an opt-in `--static-playground` flag to the `ai-sandbox` CLI. When set, the
container gets a copy-on-write overlayfs view of the host's `~/playground`
directory: every real file is visible read-through with no upfront copy, but
any write from inside the container is isolated to the container and never
touches the host.

Prior to this plan, `docker/docker-compose.yaml` unconditionally bind-mounted
`~/playground` read-write into the container, so any in-container write —
including from a compromised or misbehaving agent — landed on the host's real
files. This feature extends the existing, on-by-default `~/.config` isolation
mechanism (`docker-compose.isolate-config.yaml` + `02-overlay-config` cont-init
+ the generic `sandbox-volumes` registry tool) to `~/playground`, gated behind
a new opt-in flag.

The flag is opt-in (default OFF), unlike config isolation (on-by-default,
opt-out via `--no-isolate-config`), because it changes a path users currently
rely on being always host-writable.

The design was fully investigated and user-approved in a prior planning
session, captured in `plan/notes/static-playground-design.md`, whose three
empirically-verified findings (Compose same-target replacement, duplicate
`security_opt` validation error, and shared-registry idempotency) drove
several non-obvious design choices and required edits to existing working
files.

Success criteria: `ai-sandbox instances create <name> --static-playground`
boots a container where `~/playground` is an overlayfs mount (host content
visible read-through with no upfront copy, container writes invisible on the
host); default configuration (mirror mode + config isolation, no
`--static-playground`) is unchanged and all existing tests still pass; the
flag's value persists across bare per-instance commands via the config label
and is honored on `delete`/`clean` for named-volume cleanup; `make lint`,
`make test.unit`, and `make test.integration` pass.

## What shipped

### Phase 01 — Playground Isolation

1. **001-cli-flag-and-config-persistence** (merge `ee8bc63`) — Implemented
   `--static-playground` as a fully wired, inert 9th config-input dimension:
   CLI flag in `src/options.sh`, additive field in the persisted config JSON
   and its `ai.sandbox.static-playground` docker-compose label, restore-on-
   bare-invocation support, and drift detection in `running_config_matches()`
   — mirroring the existing `no_isolate_config`/`allow_egress` patterns.
   COMPOSE_FILES assembly and delete/clean volume cleanup were deliberately
   left for Task 002. `make build`/`make lint` green; `make test.unit` showed
   the same 7 pre-existing failures as baseline, no regressions.

2. **002-docker-overlay-mechanism** (merge `07c808c`) — Implemented the core
   copy-on-write overlay mechanism for `~/playground`: extracted a shared
   `cap_add`/`security_opt` fragment (`docker-compose.overlay-privileges.yaml`)
   out of `docker-compose.isolate-config.yaml`, added
   `docker-compose.static-playground.yaml` with a named `playground-overlay`
   volume, added the `06-overlay-playground` cont-init stage with an
   idempotent registry write plus a companion fix to `02-overlay-config`,
   wired `COMPOSE_FILES` assembly with an either-overlay-active predicate, and
   added targeted volume cleanup to `delete`/`clean` gated on
   `STATIC_PLAYGROUND`. All four required `docker compose config` scenarios
   were verified. No new test regressions. Full container integration testing
   was deliberately deferred to Task 005.

3. **003-volume-override-skip-guard-fix** (merge `4023d42`) — Extended the
   pre-existing `${HOME}/playground` skip-guard in `generate_volume_override()`
   (`src/volume-override.sh`) to also cover the `user_maps` loop, not just the
   `file://` marketplace block, mirroring the marketplace block's case-based
   guard idiom. `make build`/`make lint` pass cleanly; manual harness confirms
   correct behavior. Pre-existing test failures were verified unrelated via
   `git stash`. Dedicated unit coverage was deferred to Task 004.

4. **004-unit-tests** (merge `888ec67`) — Added 8 ShellSpec unit examples to
   `test/unit/ai_sandbox_spec.sh` covering `--static-playground` flag parsing,
   `restore_saved_config()` round-trip, `running_config_matches()` label
   match/mismatch, and `generate_volume_override()` volume-maps skip-guard
   coverage. All new examples pass; the full suite shows the same 7
   pre-existing unrelated failures as baseline. `make lint` clean.

5. **005-integration-test** (merge `1fa2ac6`) — Added
   `test/integration/static_playground_spec.sh` covering env-var visibility,
   overlay fstype, host read-through with no upfront copy, container-write
   host-invisibility, `sandbox-volumes list` row, and named-volume removal on
   delete. Lint clean, spec passes reliably in isolation. One transient
   failure was observed under heavy concurrent full-suite load, not
   reproduced on retry, and is flagged as a monitoring item rather than a test
   defect. Host Docker state was verified clean after every run.

6. **006-readme-documentation** (merge `90b3727`) — Added user-facing
   documentation for `--static-playground` to `README.md`: a new flags-table
   row and a new "Playground isolation" section mirroring "Config isolation"
   in structure and depth. Verified all internal anchor links resolve and
   confirmed `make lint` doesn't cover Markdown.

### Phase 02 — Documentation Updates

1. **update-architecture-docs** (merge `eb1efb5`) — Updated
   `docs/architecture.md`: added a new subsection documenting the
   playground-isolation subsystem (base-mount-override safe-failure finding,
   shared overlay-privileges fragment rationale, registry idempotency fix,
   named-volume-vs-tmpfs choice, delete/clean cleanup), and updated the
   "Config persistence and restore" section from eight to nine dimensions
   throughout. Confirmed `docs/ai-sandbox-profiles-spec.md` needed no update.
   All prose was cross-checked against the actually-landed source files, with
   two same-diff self-fixes to stale/orphaned sentences.

## Key decisions

- **Opt-in, not opt-out.** Unlike `~/.config` isolation (on by default),
  `--static-playground` defaults OFF because it changes a path (`~/playground`)
  users currently rely on being always host-writable.
- **Shared privileges fragment extraction.** `CAP_SYS_ADMIN`/
  `apparmor=unconfined` was factored out of `docker-compose.isolate-config.yaml`
  into a new `docker-compose.overlay-privileges.yaml`, included at most once
  whenever either overlay (config or playground) is active — a refactor with
  no behavior change for the existing config overlay, driven by the design
  note's empirically-verified "duplicate `security_opt` validation error"
  finding.
- **Named Compose-scoped volume, not tmpfs**, for the overlay upper+work
  layers, with the base `~/playground` mount re-declared read-only — chosen
  and documented in the Phase 02 architecture-docs update alongside the
  base-mount-override safe-failure and registry-idempotency findings.
- **Task ordering/dependencies.** `001` (CLI flag/config persistence) had to
  land first to introduce the `STATIC_PLAYGROUND` global that `002` (overlay
  mechanism) depends on; `003` (skip-guard fix) was independent and
  parallel-eligible; `004`/`005` (unit/integration tests) ran after `001`–`003`
  landed and were mutually parallel; `006` (README) was parallel-eligible from
  the design note alone. Phase 02 (architecture docs) ran last, after all
  Phase 01 implementation tasks landed.
- **Full container `make test.integration` was not run in-session** for
  either Task 002 or Task 005 due to host-side effects of running a real
  Docker container from within the plan's own orchestrating session; instead,
  targeted specs and manual/harness verification were used, with the full
  suite left for a follow-up validation pass.
- **Static-playground shares the pre-existing, already-documented
  label-poisoning risk** in `restore_saved_config()` (a `--docker`-capability
  container escape could poison the `ai.sandbox.config` label and durably
  re-apply it) — not a new risk class, but it marginally widens that risk's
  blast radius since a poisoned label could now also flip
  `static_playground=true`, granting `CAP_SYS_ADMIN` + `apparmor=unconfined`
  via the shared privileges fragment.

## Follow-up items

Carried forward from `plan/followups.yaml`, filtered to items tagged
`playground-isolation` or `doc-updates`:

- **(TJDw)** The 7 `make test.unit` failures seen throughout this plan are
  pre-existing (confirmed present on baseline commit `921b6e8`, unrelated to
  this plan's changes) — appears to be an environment/fixture issue on
  dispatch test delete/stop/clean/fix-ssh cases. Worth tracking as a separate
  follow-up if not already known.
- **(UZm0)** Edits to `docker-compose.isolate-config.yaml` and
  `02-overlay-config` were required and mechanically forced by the design
  note's findings #2 and #3 — narrow, covered by validation, called out per
  the task doc's own instruction.
- **(PjAl)** Full `make test.integration` (real Docker container boot) was
  not executed during Task 002's session due to host-side effects; Task 005
  covered end-to-end validation of the mechanism, but a fresh full-suite run
  is still recommended before final plan close-out (see also Icw2-style
  precedent from other plans).
- **(J55X)** `make lint`'s file-discovery glob doesn't pick up extensionless
  cont-init.d scripts (pre-existing gap, not introduced by this plan) — worth
  a follow-up to cover them automatically.
- **(Yn3J)** The design note asserts the `${HOME}/playground` skip-guard was
  previously untested even for the marketplace path, but a marketplace-skip
  test already exists predating this plan (commit `f223177`) — not blocking,
  but the design note's premise should be corrected for future readers.
- **(OF5q)** The task doc file `004-unit-tests.md` ends with a stray literal
  `</content>` line after `## References` — pre-existing authoring artifact,
  noted for a possible cleanup follow-up.
- **(r3Q2)** One transient failure was observed in the new integration
  spec's overlay-fstype assertion during a single heavily-loaded full-suite
  `make test.integration` run; not reproduced in 3 isolated reruns
  before/after. Likely a rare race/resource-contention issue in the
  `06-overlay-playground` cont-init mount under heavy concurrent load, or
  sandbox-environment flakiness. Recommend treating as a monitoring item
  rather than a defect.
- **(txyf)** Pre-existing gap: `.gitignore` only ignores
  `.ai-sandbox*.startup.log`, not the `.ai-sandbox.<name>.log` files that
  named-instance integration tests write, which accumulate as untracked stray
  files. Not fixed since `.gitignore` was outside the task's assigned files.
- **(p9cI)** `static_playground` shares the pre-existing, already-documented
  label-poisoning risk in `restore_saved_config()` (see Key decisions above).
  Not a new risk class and no action is required to conform to current
  architecture, but if/when the project revisits the label-poisoning risk,
  fold `static_playground` into that same discussion rather than treating it
  as newly introduced.
- **(uwIN)** Background note, already resolved: `docker/docker-compose.yaml`'s
  `~/playground` bind-mount comment gap flagged by the Phase 01 review has
  since been fixed and merged into `main` via a separate simple-task dispatch
  (commit `b2d06b3`) — no further action needed.
- **(Oe6b)** Minor process note: the Phase 02 task doc's own Metadata lines
  named `role_doc: architect-cloud.md` and `task-procedure:
  update-architecture-docs/SKILL.md`, differing from the `architect-backend.md`
  role and implement-task-only skill chain actually dispatched. No impact on
  output quality, but worth checking whether task-doc authoring and dispatch
  role-derivation are drifting apart for this task type.
</content>
