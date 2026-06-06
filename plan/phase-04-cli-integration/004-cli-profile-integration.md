# CLI Integration — options.sh + index.sh Profile Wiring

## Purpose and scope

Wire the profiles feature into the bash CLI. Add `--profile` (repeatable) and
`--mode` flags, remove the `--docker` / `--no-docker` / `-D` / `--no-chromium`
flags, invoke `bin/profile-installer.js`, source its output, assemble the
effective Dockerfile (via Task 003's assembly script), and select the proxy
overlay from the resolved capabilities instead of legacy flags.

This task depends on Task 002 (the installer interface) and Task 003 (the
assembly script + fragments). It edits `src/` modules only — `make build` rolls
`src/*.sh` into `bin/ai-sandbox.sh`; never edit `bin/ai-sandbox.sh` directly.

The canonical source of truth is
[`docs/ai-sandbox-profiles-spec.md`](../../docs/ai-sandbox-profiles-spec.md),
sections "Invocation changes", "Default profiles", "Capabilities reference".

## Requirements

### `src/options.sh`

- Add `--profile <name>` parsing: repeatable. Accumulate into a `PROFILES`
  array global (declared/reset at the top of `parse_options`). Because the
  current loop is a simple `for arg in "$@"`, convert to an index/`while` loop
  or a `shift`-based loop so `--profile` can consume the following arg as its
  value. Preserve all existing flag handling during the refactor.
- Add `--mode <mirror|static>` parsing into a `MODE_OVERRIDE` global. Validate
  the value is `mirror` or `static`; error nonzero otherwise.
- Remove parsing of `--no-chromium`, `--no-docker` / `-D`, and `--docker`. Their
  globals (`NO_CHROMIUM`, `NO_DOCKER`, `ENABLE_DOCKER_PROXY`) and the
  `AI_SANDBOX_ENABLE_DOCKER_PROXY` env handling tied to them are removed.
- For each removed flag, add an explicit branch that prints a clear error to
  stderr directing the user to the replacement (per the spec "Removed flags"
  table) and exits nonzero. The user is the sole user; no soft deprecation —
  a hard error pointing to `--profile docker` / `--profile chromium` is correct.
- Keep `CONFIG_FLAGS_PROVIDED` semantics: set it true when `--profile` or
  `--mode` is supplied (these change container config), so the bare-invocation
  auto-`connect` promotion in `index.sh` still behaves.
- Update the function's header comment block (the documented globals list) to
  reflect `PROFILES`, `MODE_OVERRIDE`, and the removals.
- Keep the `# shellcheck disable=SC2034` rationale comment accurate.

### `src/index.sh`

- Remove the flag-validation phases for `--no-chromium` and `--no-docker`
  (current lines validating those flags, the mutual-exclusion check, the
  "running container" guard tied to `--no-docker`, and the
  `INSTALL_DOCKER_CLI` / `EFFECTIVE_PROXY`-from-flags derivation).
- Add a **profile resolution phase** (after script-dir/project-root resolution,
  before compose-file assembly) that runs for build/start/enter/up and bare
  invocations:
  1. If `PROFILES` is empty, load `default_profiles` from
     `${XDG_CONFIG_HOME:-$HOME/.config}/ai-sandbox/config.yaml`. If that file or
     key is absent, fall back to `base mirror`. (Reading the YAML list can be
     done by piping the config through `bin/profile-installer.js`-adjacent logic
     OR a minimal `node -e`/`js-yaml` read — keep it simple; a small `node -e`
     reader is acceptable and avoids reimplementing YAML in bash. Document the
     choice.)
  2. Invoke `node "${PROJECT_ROOT}/bin/profile-installer.js" "${PROFILES[@]}"`.
     On nonzero exit, propagate the installer's stderr and exit nonzero.
  3. Source the `KEY=VALUE` block (extract it between sentinels and `eval` it, or
     `eval "$(... | sed -n '/sentinel/,/sentinel/p')"`). This sets
     `PROFILE_MODE`, `PROFILE_CAPABILITIES`, `PROFILE_IMAGE_TAG`,
     `PROFILE_LOCAL`, `PROFILE_COMPOSITION_HASH`, `PROFILE_SETUP_SCRIPT`.
  4. Apply `MODE_OVERRIDE`: if set, it wins over `PROFILE_MODE`. If neither is
     set, default to `mirror`. Export the resolved `EFFECTIVE_MODE`.
  5. Parse the file-copy path block and copy each listed `src` into the build
     context (or a staging dir referenced by the assembled Dockerfile). Parse
     the JSON block with `jq` for `packages` / `plugins` / `network_allow` as
     needed downstream.
- **Capabilities → proxy overlay + Dockerfile assembly**:
  - Replace the `EFFECTIVE_PROXY`-from-flags logic with: `EFFECTIVE_PROXY=true`
    iff `docker` is in `PROFILE_CAPABILITIES`. Keep the proxy compose overlay
    selection (`docker-compose.proxy.yaml`) driven by `EFFECTIVE_PROXY`.
  - Replace `--no-chromium` overlay gating: include
    `docker-compose.chromium.yaml` iff `chromium` is in `PROFILE_CAPABILITIES`.
    Remove the `INSTALL_CHROMIUM` build arg reliance — Dockerfile assembly now
    handles chromium install (Task 003).
  - Call Task 003's `docker/scripts/assemble-dockerfile.sh "${PROFILE_CAPABILITIES}"
    "<assembled-path>"` and point the compose build at the assembled Dockerfile.
    The assembled-path contract (e.g.
    `${XDG_CACHE_HOME:-$HOME/.cache}/ai-sandbox/Dockerfile.${PROFILE_COMPOSITION_HASH}`)
    must match Task 003. The compose build references it — either by exporting a
    var consumed in `docker-compose.yaml`'s `build.dockerfile`, or by generating
    a small compose overlay setting `build.dockerfile`. Choose the approach that
    keeps `docker-compose.yaml` parameterized via an env var (preferred:
    `dockerfile: ${AI_SANDBOX_DOCKERFILE:-Dockerfile}` — see Task 005 note on
    compose edits).
- **Image tag**: set `AI_SANDBOX_IMAGE_TAG` from the installer's
  `PROFILE_IMAGE_TAG` (i.e. `ai-sandbox:${PROFILE_IMAGE_TAG}`) — see Task 005,
  which owns `variant_key`/`variant_image_tag`/`is_build_stale`. Coordinate so
  exactly one task sets `AI_SANDBOX_IMAGE_TAG`; this task calls the Task-005
  function rather than recomputing.
- **Compose labels**: update `docker/docker-compose.yaml` labels — replace
  `ai.sandbox.no-isolate-config` / `ai.sandbox.docker-proxy` handling as needed
  and add a label recording the composition (e.g.
  `ai.sandbox.profile-hash: "${PROFILE_COMPOSITION_HASH}"` and
  `ai.sandbox.mode: "${EFFECTIVE_MODE}"`) so `running_config_matches` (Task 005)
  can detect drift. Keep `ai.sandbox.docker-proxy` keyed off `EFFECTIVE_PROXY`.
- **`mode: static`**: when `EFFECTIVE_MODE=static`, the host-identity mounts
  (`~/.claude`, git config, SSH, `~/.config` overlays) should not be applied.
  V1 minimum: gate the isolate-config / shared-config overlay selection and the
  identity mounts behind `EFFECTIVE_MODE=mirror`. If full static-mode mount
  suppression is larger than this task's scope, implement the mode plumbing
  (resolve + export + label + overlay selection for `mirror`) and FLAG the
  remaining static-mode mount-suppression details for the manager rather than
  half-implementing. State clearly in the task outcome what static does in V1.
- Preserve the `${__SOURCED__:+return}` guard and the phase-comment structure.

### shellcheck

- All edited `src/*.sh` must pass `make lint`. Preserve existing
  `# shellcheck disable=...` rationale comments; add new ones only with an inline
  reason (per repo convention).

### Integration points

- **Task 002**: parses the three output blocks; sentinel strings must match.
- **Task 003**: calls `assemble-dockerfile.sh`; path contract must match.
- **Task 005**: image tag + staleness + config-match functions are consumed
  here, defined there. Do not duplicate hash logic.

## Validation

- `make build` succeeds (rolls `src/` into `bin/ai-sandbox.sh`).
- `make lint` passes.
- `grep -- '--no-chromium\|--no-docker\|--docker' src/options.sh` shows only the
  removed-flag error branches, not active parsing.
- `grep -- '--profile' src/options.sh` and `grep -- '--mode' src/options.sh`
  succeed.
- Sourced-as-library smoke test: `__SOURCED__=1 bash bin/ai-sandbox.sh` returns
  0 and defines `parse_options`.
- A unit test (added in Task 007) drives `parse_options --profile base
  --profile docker` and asserts `PROFILES` contains both names and
  `CONFIG_FLAGS_PROVIDED=true`.
- Removed-flag errors: `bash bin/ai-sandbox.sh build --docker` exits nonzero and
  stderr mentions `--profile docker`.

## Assumptions

- Reading the single `default_profiles` list from `config.yaml` via a minimal
  `node -e` reader is acceptable rather than a full bash YAML parser.
- `static` mode in V1 at minimum: resolves, exports, labels, and selects the
  lean overlay set; full identity-mount suppression may be flagged if it grows
  beyond this task.

## References

- [`docs/ai-sandbox-profiles-spec.md`](../../docs/ai-sandbox-profiles-spec.md) —
  "Invocation changes", "Default profiles", "Backward compatibility".
- `src/options.sh`, `src/index.sh`, `docker/docker-compose.yaml`.
