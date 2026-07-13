# Docker Overlay Mechanism

## Purpose and scope

Implement the core copy-on-write overlay for `~/playground`: the shared
overlay-privileges compose fragment, the playground overlay compose file, the
cont-init mount stage (plus a companion idempotency fix to the existing config
overlay), the `COMPOSE_FILES` assembly wiring, and the targeted named-volume
cleanup on `delete`/`clean`. After this task, `ai-sandbox ... --static-playground`
produces a container whose `~/playground` is an overlayfs mount with
container-local writes, while the default config isolation continues to work
unchanged.

Depends on Task 001 (the `STATIC_PLAYGROUND` global and its restored value).

Files: new `docker/docker-compose.overlay-privileges.yaml`, edited
`docker/docker-compose.isolate-config.yaml`, new
`docker/docker-compose.static-playground.yaml`, new
`docker/rootfs/etc/cont-init.d/06-overlay-playground`, edited
`docker/rootfs/etc/cont-init.d/02-overlay-config`, edited `src/index.sh`. No
standard skill; follow the design note and mirror the existing config-overlay
mechanism. Run `make build` after editing `src/`.

## Requirements

Implement parts 1, 2, 3, and the `COMPOSE_FILES` + `delete`/`clean` portions of
part 5 of the [design note](../notes/static-playground-design.md). The three
empirically-verified findings in that note are load-bearing — read them first.

1. **`docker/docker-compose.overlay-privileges.yaml` (new)** — extract the
   `cap_add: [SYS_ADMIN]` and `security_opt: [apparmor=unconfined]` block from
   `docker-compose.isolate-config.yaml` into this shared fragment under
   `services: ai-sandbox:`. Carry over the explanatory comments.

2. **`docker/docker-compose.isolate-config.yaml` (edit)** — remove the
   `cap_add`/`security_opt` block (now in the fragment), leaving a comment
   pointing at `docker-compose.overlay-privileges.yaml`. **This is a required
   edit to an existing working file, mechanically forced by finding #2 (duplicate
   `security_opt` across merged compose files is a hard validation error). Flag
   it explicitly in the task report.** No other change to this file.

3. **`docker/docker-compose.static-playground.yaml` (new)** — mirror
   `docker-compose.isolate-config.yaml`'s shape with the two deviations from the
   design note:
   - Four volume entries: a `:ro` override at `${HOST_HOME}/playground` (replaces
     the base RW bind — finding #1), a `:ro` bind at
     `/mnt/ai-sandbox/host-playground` (overlay lowerdir), a plain RW bind at
     `/var/lib/ai-sandbox-rw/playground` (sudo-only, for `sandbox-volumes sync
     --match-container`), and the `playground-overlay` named volume at
     `/var/lib/ai-sandbox-overlay/playground`.
   - Environment: `AI_SANDBOX_STATIC_PLAYGROUND=1` plus host-RO / overlay / RW /
     host-source path vars mirroring the `AI_SANDBOX_HOST_CONFIG_*` set.
   - A top-level `volumes:` block declaring the `playground-overlay` named volume
     (bare-key idiom, same as `firewall-handshake` in `docker-compose.yaml`).
   - **No** `cap_add`/`security_opt` here (comes from the privileges fragment).

4. **`docker/rootfs/etc/cont-init.d/06-overlay-playground` (new)** — mirror
   `02-overlay-config`'s structure: guard on `AI_SANDBOX_STATIC_PLAYGROUND=1`,
   create `upper`/`work` dirs under the named-volume mount
   (`/var/lib/ai-sandbox-overlay/playground/{upper,work}`), `chown` the upper and
   target to `${HOST_USER}`, `mount -t overlay` the lower+upper+work over
   `${HOST_HOME}/playground`, and warn-and-continue on failure (the `:ro`
   fallback makes a hard failure unnecessary). Apply the same
   `/var/lib/ai-sandbox-rw` parent hardening (`chown root:root` + `chmod 0700`).
   Executable bit set (`chmod +x`), same shebang/`with-contenv` header as
   `02-overlay-config`. Write the registry row using the **idempotent** pattern
   (see #5 below), not truncate-and-write.

5. **`docker/rootfs/etc/cont-init.d/02-overlay-config` (edit) + registry
   idempotency** — change the config registry write (lines ~55-66) from
   unconditional truncate to a strip-own-row-then-append pattern keyed
   `^config\t`, and implement the same pattern keyed `^playground\t` in
   `06-overlay-playground`. Both must: ensure the two header comment lines exist,
   strip any pre-existing row for their own key, then append their current row —
   safe whether one or both overlays are active and idempotent across container
   restarts (the registry lives on the writable layer, which persists across
   `stop`/`start`). **The `02-overlay-config` edit touches an existing working
   file — flag it in the task report.**

6. **`src/index.sh` — `COMPOSE_FILES` assembly** (~lines 440-470): the playground
   overlay applies **regardless of `EFFECTIVE_MODE`** (the base playground mount
   is mode-independent today), so its inclusion must be outside the
   `if [ "${EFFECTIVE_MODE}" = "mirror" ]` branch. Compute a single "either
   overlay active" predicate — config-isolation active (mirror-mode AND not
   `--no-isolate-config`) OR `STATIC_PLAYGROUND=true` — and include
   `docker-compose.overlay-privileges.yaml` **at most once** when it holds.
   Include `docker-compose.static-playground.yaml` whenever
   `STATIC_PLAYGROUND=true`. **Critical correctness point:** because part 2 moved
   the caps out of `isolate-config.yaml`, the privileges fragment must be
   included wherever isolate-config is included, or the default config isolation
   loses its `CAP_SYS_ADMIN` and breaks. Verify `docker compose ... config`
   resolves cleanly (single `security_opt`, single `~/playground` mount) in each
   of: default (mirror + isolate-config, no flag), `--static-playground` only,
   `--static-playground` + `--no-isolate-config`, and `--mode static
   --static-playground`.

7. **`src/index.sh` — `delete`/`clean` handlers** (~lines 586-600): after
   `docker compose -p "${COMPOSE_PROJECT}" ${COMPOSE_FILES} down`, when
   `STATIC_PLAYGROUND=true` (this reflects the *restored* value from Task 001's
   `restore_saved_config`, since `delete`/`clean` trigger restore), run
   `docker volume rm "${COMPOSE_PROJECT}_playground-overlay" 2>/dev/null || true`.
   Apply to both the `delete` and `clean` arms. **Do not** use a blanket
   `down -v` — that would also delete the pre-existing `firewall-handshake`
   volume (out of scope). This discards unsynced container-side edits by design,
   matching plain `docker compose down` expectations.

Preserve exactly: the config-isolation (`~/.config`) behavior and its default-on
posture; the `firewall-handshake` volume lifecycle; the `sandbox-volumes` tool
(unmodified). No `docker/Dockerfile*` change is needed.

## Validation

- `make build` succeeds; `make lint` (shellcheck) passes for `src/index.sh`, the
  two cont-init scripts, and any shell in the compose files.
- The four `docker compose ... config` scenarios in Requirement 6 each resolve
  without error: exactly one `security_opt` entry, exactly one mount at
  `${HOST_HOME}/playground` (`:ro` when `--static-playground` is active, base RW
  otherwise), and the privileges fragment present whenever any overlay is active.
- File existence checks: `docker/docker-compose.overlay-privileges.yaml`,
  `docker/docker-compose.static-playground.yaml`, and
  `docker/rootfs/etc/cont-init.d/06-overlay-playground` (executable) all exist;
  `docker/docker-compose.isolate-config.yaml` no longer contains `cap_add` or
  `security_opt`.
- `grep -n 'cap_add\|security_opt' docker/docker-compose.isolate-config.yaml`
  returns nothing; the same tokens appear only in
  `docker-compose.overlay-privileges.yaml`.
- Registry idempotency: reason through (and, if practical, exercise) that
  running both cont-init scripts in either order, and re-running after a
  simulated restart, yields exactly one `^config\t` row and one `^playground\t`
  row with the two header lines intact.
- The `delete`/`clean` volume cleanup is targeted to
  `${COMPOSE_PROJECT}_playground-overlay` only; no `down -v` anywhere.
- End-to-end behavior is validated by Task 005 (integration). Existing unit and
  integration suites still pass for the default configuration (config isolation
  unchanged).

## Metadata

architectural_impact: true

## Assumptions

- Task 001 has landed, so `STATIC_PLAYGROUND` is defined, exported, restored by
  `restore_saved_config`, and compared by `running_config_matches`. If Task 001
  is not yet merged, the `COMPOSE_FILES` wiring must still use
  `${STATIC_PLAYGROUND:-false}` defensively so the default path is unaffected.
- cont-init.d scripts run as root under s6-overlay (confirmed by the existing
  `02-overlay-config` calling `mount`/`chown` without `sudo`).

## References

- [static-playground design note](../notes/static-playground-design.md) — parts
  1, 2, 3, 5; the three empirical findings; authoritative design.
- `docker/docker-compose.isolate-config.yaml`,
  `docker/rootfs/etc/cont-init.d/02-overlay-config` — the config-overlay
  mechanism to mirror.
- `docker/docker-compose.yaml` (~lines 90-106 base playground mount; ~220-242
  `firewall-handshake` named-volume declaration idiom).
- `docs/architecture.md` § "~/.config is copy-on-write by default" and §
  "sandbox-volumes: inspecting and syncing overlay state" — the registry format
  and the RO/RW/overlay three-path model.

## Checkpoint hints

- After the privileges fragment + `isolate-config.yaml` extraction (verify
  default config isolation still resolves once wiring lands).
- After `docker-compose.static-playground.yaml`.
- After `06-overlay-playground` + the `02-overlay-config` idempotency fix.
- After `src/index.sh` `COMPOSE_FILES` wiring + the four `config` scenarios.
- After `delete`/`clean` volume cleanup.
- After `make build` + `make lint`.
</content>
