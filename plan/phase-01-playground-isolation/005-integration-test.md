# Integration Test

## Purpose and scope

Add a new ShellSpec integration spec, `test/integration/static_playground_spec.sh`,
that drives a real `docker compose` named instance with `--static-playground` and
verifies end-to-end write isolation: host content visible read-through with no
upfront copy, container-side writes invisible on the host, the overlay fstype,
the `sandbox-volumes` registry row, and named-volume cleanup on delete.

Depends on Task 002 (the overlay mechanism). Must use its own named instance
(not the shared default container), mirroring
`test/integration/named_instance_enter_spec.sh`'s create/delete lifecycle and
`test/integration/container_spec.sh`'s config-isolation assertions.

Single new file: `test/integration/static_playground_spec.sh`. No standard skill;
follow the design note and the existing integration-spec conventions
(`test/spec_helper.sh`'s `container_exec`, the `integration` tag, and the
`detail --test-check` gate).

## Requirements

Implement the **Integration** portion of part 8 of the
[design note](../notes/static-playground-design.md). The spec must create a
dedicated named instance with `--static-playground`, run the assertions below,
and delete it (with cleanup in an `AfterAll`/teardown so a failed run does not
leave a stray instance or volume):

1. `AI_SANDBOX_STATIC_PLAYGROUND=1` is visible in-container (env check).
2. `findmnt -o FSTYPE <playground path>` reports `overlay`.
3. Real host content (e.g. this repo's own `README.md` under
   `~/playground/ai-sandbox/`) is visible read-through from inside the container,
   confirming no upfront copy is required.
4. A container-side write under a **disposable probe subdirectory** succeeds
   in-container and is confirmed **absent** on the host afterward (the core
   write-isolation assertion).
5. `sandbox-volumes list` output includes a `playground` row.
6. After `delete`, `docker volume inspect ai-sandbox-<name>_playground-overlay`
   fails (the named volume was actually removed).

Test hygiene (required):
- Scope every drift/read/write check to a small probe subpath, **never** the
  whole `~/playground` root (per the performance risk in the design note).
- The container-side write must target a path the test creates and removes; it
  must never write into real host repos.
- Tag the spec `integration` so it participates in the tiered filter.

## Validation

- `make test.integration` runs the new spec against a live Docker Desktop
  instance and passes (the harness gates on `detail --test-check`; clear host
  claude/plugin processes or set `AI_SANDBOX_SKIP_PLUGIN_CHECK=1` as documented
  in `CLAUDE.md`).
- The spec cleans up its named instance and the `playground-overlay` volume even
  on failure (verify no `ai-sandbox-<name>` container or
  `..._playground-overlay` volume remains after a run: `docker ps -a` and
  `docker volume ls` are clean of the test instance).
- `make lint` passes for the new spec file.
- The write-isolation assertion (#4) genuinely fails if the overlay is not in
  effect (e.g. against a container created without the flag) — reason through
  this when authoring so the test cannot pass vacuously.

## Assumptions

- Task 002 has landed and `--static-playground` produces a working overlay.
- A real Docker Desktop instance is available; this spec is skipped by the
  `!integration` filter in unit-only runs.
- `~/playground/ai-sandbox/README.md` exists on the host (this repo lives under
  `~/playground`); if the read-through probe path must differ on the runner,
  choose any known-existing host file under `~/playground` and note it.

## References

- [static-playground design note](../notes/static-playground-design.md) — part 8
  (Integration) and the open risks (probe-subpath hygiene).
- `test/integration/container_spec.sh` — config-isolation assertion block to
  mirror.
- `test/integration/named_instance_enter_spec.sh` — named-instance create/delete
  lifecycle to mirror.
- `test/spec_helper.sh` — `container_exec` and shared helpers.
</content>
