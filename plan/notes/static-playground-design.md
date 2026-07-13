# `--static-playground` design (authoritative)

## Purpose and scope

Self-contained record of the user-approved investigation-and-design pass for the
`--static-playground` feature, ported into the plan so task agents have the full
design without needing the external planning-session file. The original write-up
lives at `~/.claude/plans/would-it-be-possible-iterative-turtle.md` (host-only,
outside this repo). This note is the authoritative reference for every task in
the `playground-isolation` phase.

All file paths are relative to the repo root
(`/Users/zane/playground/ai-sandbox`). Line-number pointers were verified
against the plan-worktree checkout and are approximate anchors, not exact
addresses — implementers should locate by surrounding context.

## Goal

Add an opt-in `--static-playground` flag. When set, the container gets a
copy-on-write overlayfs view of the host's `~/playground`: every real file is
visible with no upfront copy, but any write from inside the container is
isolated to the container and never touches the host. This mirrors the existing,
on-by-default `~/.config` isolation mechanism
(`docker/docker-compose.isolate-config.yaml` +
`docker/rootfs/etc/cont-init.d/02-overlay-config` + the already-generic
`sandbox-volumes` registry tool). It is **opt-in** (default OFF), unlike config
isolation, because it changes a path users currently rely on being
host-writable.

Today `docker/docker-compose.yaml` (line ~98) unconditionally bind-mounts
`${HOST_HOME}/playground:${HOST_HOME}/playground` read-write, regardless of
mode. `--static-playground` replaces that mount with an overlay whenever the flag
is active.

## Three empirically-verified findings that shape the design

These were verified against this repo (not assumed) and change the design from a
naive copy of the config mechanism:

1. **Compose replaces same-target volume entries; last `-f` file wins.** Verified
   via `docker compose config`. The new overlay compose file must itself
   re-declare `${HOST_HOME}/playground` as a `:ro` bind, or the base's RW bind
   stays live underneath. Overriding with `:ro` at the same target fully
   replaces the base RW bind. This also yields a *safe failure mode*: if the
   overlay `mount` fails, the container degrades to read-only rather than to the
   base's live RW host passthrough — a write-isolation feature must never
   silently degrade to full host write access.

2. **Duplicate `security_opt` across merged compose files is a hard
   `docker compose config` validation error** (`services.ai-sandbox.security_opt
   items at 0 and 1 are equal`), unlike `cap_add`, which de-dupes cleanly.
   Mirror-mode's default config isolation and the new playground isolation both
   need `cap_add: [SYS_ADMIN]` + `security_opt: [apparmor=unconfined]`, and both
   can be active at once. They must therefore share one fragment file included at
   most once. Copying the block into a second file verbatim would break
   `ai-sandbox start --static-playground` in the default (mirror + isolate-config)
   configuration.

3. **The registry write in `02-overlay-config` truncates and overwrites the whole
   file** (`/etc/ai-sandbox/overlay-volumes.conf`, see script lines ~55-66).
   Harmless with one overlay; with two, whichever cont-init runs later wins and
   silently erases the other's row, and naive appending would duplicate rows
   across restarts (the writable layer persists across `stop`/`start`). Both
   scripts need an idempotent "strip my own row, ensure header, then append"
   pattern.

## Design (nine parts)

### 1. `docker/docker-compose.overlay-privileges.yaml` (new)

Extract the `cap_add: [SYS_ADMIN]` / `security_opt: [apparmor=unconfined]` block
currently inline in `docker/docker-compose.isolate-config.yaml` (lines ~8-15)
into its own fragment. Included at most once whenever *either* overlay (config or
playground) is active. **Required edit to an existing working file**: delete that
block from `docker-compose.isolate-config.yaml`, leaving a comment pointing at
the new fragment. Mechanically forced by finding #2.

### 2. `docker/docker-compose.static-playground.yaml` (new)

Mirrors `docker-compose.isolate-config.yaml`'s shape, with two deliberate
deviations:

- **Upper+work on a Docker named volume, not tmpfs.** Config's overlay uses a
  tmpfs upper (fine for a small dir); `~/playground` is 19GB+, so a RAM-backed
  tmpfs is the wrong tradeoff. Use a Compose-scoped named volume
  (`playground-overlay`, same bare-key idiom as the existing `firewall-handshake`
  volume — Compose auto-scopes it per instance, e.g.
  `ai-sandbox-<name>_playground-overlay`).
- **Must re-declare the base playground mount** (finding #1): a `:ro` bind at
  `${HOST_HOME}/playground` replaces the base RW bind and gives the safe
  read-only failure mode.

Volume entries (four total):
- `:ro` override at the real target `${HOST_HOME}/playground` (replaces base RW).
- `:ro` bind at `/mnt/ai-sandbox/host-playground` (the overlay lowerdir — must
  differ from the mountpoint).
- plain RW bind at `/var/lib/ai-sandbox-rw/playground` (for `sandbox-volumes sync
  --match-container`, reachable only via sudo; parent dir `/var/lib/ai-sandbox-rw`
  is already `chmod 0700 root` via the `02`/`06` cont-init hardening and the
  Dockerfile — no Dockerfile change needed for this sibling subdir).
- the named volume `playground-overlay` mounted at
  `/var/lib/ai-sandbox-overlay/playground`.

Plus env vars for the cont-init script: `AI_SANDBOX_STATIC_PLAYGROUND=1`,
host RO dir, overlay dir, RW dir, and host source paths (mirror the
`AI_SANDBOX_ISOLATE_CONFIG` / `AI_SANDBOX_HOST_CONFIG_*` set). Declare the
`playground-overlay` named volume in a top-level `volumes:` block, same idiom as
`firewall-handshake` in `docker/docker-compose.yaml` (lines ~220-242).

**No `cap_add`/`security_opt` here** — comes from fragment #1.

### 3. `docker/rootfs/etc/cont-init.d/06-overlay-playground` (new)

Mirrors `02-overlay-config`'s `mount -t overlay` + warn-and-continue-on-failure
behavior (the `:ro` fallback from #2 makes a hard failure unnecessary). Two
required deviations:

- **Idempotent registry row.** Instead of truncate-and-write, strip any existing
  `^playground\t` row from `/etc/ai-sandbox/overlay-volumes.conf`, ensure the
  header exists, then append — safe whether this is the only overlay active, both
  are active, or a restart of a previously-booted container.
- **Companion fix to `02-overlay-config`**: change its own registry write from
  unconditional truncate to the same strip-own-row-then-append pattern (keyed
  `^config\t`), so neither script can clobber the other's row regardless of
  execution order. Small, low-risk, but touches an existing working file — flag
  in review.

Numbered `06` (next free slot after `01/02/03/04/05/10`); no ordering dependency
since nothing else touches `~/playground`. Upper+work dirs live under the named
volume mount (`/var/lib/ai-sandbox-overlay/playground/{upper,work}`), created by
the script. Apply the same RW-bind parent hardening (`chmod 0700 root` on
`/var/lib/ai-sandbox-rw`) as `02-overlay-config` does.

### 4. `src/options.sh`

Add `--static-playground` as a plain boolean flag, identical shape to the
existing `--no-isolate-config` case (~line 466): sets `STATIC_PLAYGROUND=true`,
`CONFIG_FLAGS_PROVIDED=true`. Init `STATIC_PLAYGROUND=false` alongside
`NO_ISOLATE_CONFIG=false` (~line 152). Add `STATIC_PLAYGROUND` to both `export`
lists (~lines 235, 639) and the header globals doc comment (~line 37).

### 5. `src/index.sh`

- **Config-JSON assembly** (~lines 243-265): add `static_playground` as a 9th
  field (additive, `version` stays `1` — same precedent as `allow_egress`, the
  8th). Compute `_config_static_playground_json` (`true`/`false`) the same way as
  `_config_no_isolate_json`, and add `--argjson static_playground` + the
  `static_playground: $static_playground` key to the `jq` object.
- **`export`** (~line 347): add `STATIC_PLAYGROUND` to
  `export EFFECTIVE_PROXY NO_ISOLATE_CONFIG`.
- **`COMPOSE_FILES` assembly** (~lines 440-470): unlike the config overlay
  (mirror-mode-only, inside the `if [ "${EFFECTIVE_MODE}" = "mirror" ]` branch),
  the playground overlay applies **regardless of `EFFECTIVE_MODE`** — the base
  playground mount is unconditional on mode today, so the flag replacing it must
  be too. Compute a single "either overlay active" predicate (config-isolation is
  active when mirror-mode AND not `--no-isolate-config`; OR
  `STATIC_PLAYGROUND=true`) and include
  `docker-compose.overlay-privileges.yaml` at most once when it holds. Include
  `docker-compose.static-playground.yaml` whenever `STATIC_PLAYGROUND=true`,
  independent of the mirror/static branch. **Critical:** the existing
  isolate-config inclusion must stop carrying its own caps (moved to the
  privileges fragment), so the privileges fragment must be included wherever
  isolate-config is included — otherwise the default config isolation breaks.
- **Label** in `docker/docker-compose.yaml` (~line 59, alongside
  `ai.sandbox.no-isolate-config`): add
  `ai.sandbox.static-playground: "${STATIC_PLAYGROUND:-false}"`.
- **`delete`/`clean` handlers** (~lines 586-600): after
  `docker compose ... down`, when `STATIC_PLAYGROUND=true` (reflecting the
  *restored* value — see part 6), explicitly
  `docker volume rm "${COMPOSE_PROJECT}_playground-overlay" 2>/dev/null || true`.
  Deliberately **not** a blanket `down -v`, which would also delete the
  pre-existing `firewall-handshake` volume — an unrelated, out-of-scope behavior
  change. Per the product decision, this discards any unsynced container-side
  edits, matching plain `docker compose down` expectations.

### 6. `src/utils.sh`

- **`restore_saved_config()`** (~line 484): add `static_playground` extraction
  (same null-guarded boolean pattern as `no_isolate_config`, ~line 522) so a bare
  `<name> delete`/`start`/`enter` rehydrates `STATIC_PLAYGROUND` from the
  persisted label even when this invocation passes no flags — this is exactly why
  the delete-time volume cleanup works without requiring `delete` to repeat the
  flag.
- **`running_config_matches()`** (~line 652): add the `ai.sandbox.static-playground`
  label to the go-template `fmt` string (~line 670) and the comparison set (as a
  10th field), so an explicit invocation that flips the flag on an existing
  instance is detected as a config change and prompts a recreate — consistent
  with every other dimension.
- Update the "eight-dimension"/"eighth field" doc comments to nine throughout
  (~lines 459-460, 472-474, 499).

### 7. `src/volume-override.sh` — required fix

The existing skip-guard (lines ~80-92) that avoids double-mounting under
`${HOME}/playground` only covers the `file://` marketplace-mount block — it does
**not** cover the earlier `user_maps` loop
(`~/.config/ai-sandbox/volume-maps` entries, ~lines 31-46). Today a volume-map
entry under `~/playground` is a harmless redundant identity mount. Once
`--static-playground` is active, Docker mounts it at container start, then
`06-overlay-playground`'s `mount -t overlay` stacks a new mount *over*
`${HOME}/playground` afterward — silently shadowing the nested mount with no
error. Fix: extend the same `${HOME}/playground` skip-guard to the `user_maps`
loop (applied unconditionally — correct with or without the flag). Applies to the
resolved `dst` (target) path.

### 8. Tests

**Unit** (`test/unit/ai_sandbox_spec.sh`), mirroring existing patterns exactly:
- Flag parsing (alongside the `NO_ISOLATE_CONFIG` block, ~line 1507).
- `restore_saved_config()` round-trip + a dedicated regression test (mirroring
  the `NO_ISOLATE_CONFIG=true` case, ~line 792).
- `running_config_matches()` match/mismatch cases (mirroring `cur_no_isolate`,
  ~line 1116).
- `generate_volume_override()`: new coverage for both the pre-existing
  marketplace skip and the new volume-maps skip under `${HOME}/playground` (the
  part-7 fix) — this exact case isn't currently tested even for the marketplace
  path.
- `COMPOSE_FILES` assembly is inline top-level script (not an extracted
  function), same as the existing `~/.config` mode-branching — no unit seam
  exists, so cover that branch at the integration level instead, consistent with
  precedent.

**Integration** (new `test/integration/static_playground_spec.sh`), mirroring
`container_spec.sh`'s config-isolation block and `named_instance_enter_spec.sh`'s
named-instance create/delete pattern (must be its own named instance, not the
shared default container):
- `AI_SANDBOX_STATIC_PLAYGROUND=1` visible in-container.
- `findmnt -o FSTYPE ~/playground` reports `overlay`.
- Real host content (e.g. this repo's own `README.md` under
  `~/playground/ai-sandbox/`) visible read-through with no upfront copy.
- A container-side write under a disposable probe subdirectory succeeds
  in-container and is confirmed **absent** on the host afterward.
- `sandbox-volumes list` includes a `playground` row.
- After `delete`, `docker volume inspect
  ai-sandbox-<name>_playground-overlay` fails (volume actually removed).

Test hygiene: scope every drift check to a small probe subpath, never the whole
playground root (see risks).

### 9. Documentation

**`README.md`**: add `--static-playground` to the flags table, explicitly noting
it is unrelated to the pre-existing `--mode static` despite the shared word. New
`### Playground isolation` section mirroring `### Config isolation` (mechanics,
opt-in example, `sandbox-volumes` pointer, `CAP_SYS_ADMIN` cost note), plus: the
opt-in-vs-opt-out asymmetry vs. config isolation, a performance caveat (always
scope `sandbox-volumes diff`/`sync`/`status` to a subpath, never the whole
tree — see risks), and that `delete`/`clean` discards container-local overlay
writes with no separate confirmation.

**`docs/architecture.md`**: new subsection mirroring `### ~/.config is
copy-on-write by default`, covering the mechanism, the base-mount-override
subtlety (finding #1), the shared `docker-compose.overlay-privileges.yaml`
extraction and why (finding #2), and the registry idempotency fix (finding #3).
Update `### Config persistence and restore`'s "eight-dimension"/"eight input
globals" language to nine throughout, adding
`static_playground`/`ai.sandbox.static-playground` to the field lists. (Handled
by the `doc-updates` phase's `update-architecture-docs` task, not the feature
phase.)

## Open risks (documented, not solved by this plan)

- **`sandbox-volumes status`/`diff`/`sync` performance**: these do an unscoped
  recursive `diff -qr` — instant for `~/.config`, potentially many minutes across
  a 19GB multi-repo tree with `.git` internals and `node_modules`. Not modifying
  `sandbox-volumes` itself (already generic); mitigation is documentation only
  ("always scope to a subpath").
- **No disk-quota accounting** for the `playground-overlay` named volume — it
  lives inside Docker Desktop's VM disk with no quota enforcement and no
  host-side `du` visibility (only `docker system df -v`). Documented, not
  enforced, consistent with this project's "firewall is the boundary, not
  resource limits" posture.
- **Naming collision** between `--static-playground` and the pre-existing
  `--mode static` — unrelated features, shared word. Docs disambiguate
  explicitly.

## Verification (whole feature)

- `make build` (roll `src/` into `bin/ai-sandbox.sh`) then `make lint`
  (shellcheck across new/changed `src/`, `docker/` files).
- `make test.unit` — new and extended ShellSpec unit specs.
- `make test.integration` — new `static_playground_spec.sh`, run against a real
  Docker Desktop instance; confirms end-to-end write isolation (host file absence
  after a container-side write) and volume cleanup on delete.
</content>
</invoke>
