# create-profile Command — src/create-profile.sh

## Purpose and scope

Add the `create-profile` subcommand: it scaffolds a profile YAML file by
auto-discovering skills, hooks, and agents from the standard `~/.claude/` and
`./.claude/` locations and accepting flags for the remaining configuration. New
bash module `src/create-profile.sh`, sourced and dispatched from `src/index.sh`.

This task depends on Task 002 only insofar as it must write YAML that
`profile-installer.js` can later load (same schema, same local-detection rule).
It can run in parallel with Task 005. Edits `src/` modules only; `make build`
rolls up to `bin/ai-sandbox.sh`.

The canonical source of truth is
[`docs/ai-sandbox-profiles-spec.md`](../../docs/ai-sandbox-profiles-spec.md),
section "The `create-profile` command".

## Requirements

### New module `src/create-profile.sh`

- `# shellcheck shell=bash` header. Define `function create_profile() { ... }`.
- Parse flags from the forwarded `ARGS` (or accept them as positional args from
  `index.sh`):
  - `--name <name>` (required). Used as filename and `metadata.name`. Validate it
    is a valid POSIX filename component (no `/`); error nonzero otherwise.
  - `--mode <mirror|static>` (default `mirror`). Validate; written to the `mode`
    field and reflected as appropriate in metadata.
  - `--output <path>` (default `./profiles/<name>.yaml`). Create the parent
    directory if it does not exist.
  - `--plugins <name,...>` (repeatable; comma-separated). Accumulate into a
    plugin list. When not provided, the spec allows interactive prompting —
    interactive prompting is optional in V1; if a TTY is absent, default to an
    empty plugin list. Document the V1 behavior chosen.
- **Auto-discovery** (in order, both locations per category):
  - Skills: `~/.claude/skills/` then `./.claude/skills/`.
  - Hooks: `~/.claude/hooks/` then `./.claude/hooks/`.
  - Agents: `~/.claude/agents/` then `./.claude/agents/`.
  - For each discovered entry, add a `{src, dst}` to the matching list with
    `src` = absolute resolved path and `dst` = the in-container path under
    `/home/<user>/.claude/<category>/<basename>` (use `${HOST_USER:-$USER}` /
    `${HOST_HOME:-$HOME}` to form the destination, consistent with how the
    Dockerfile/compose form container home paths).
  - Skip categories whose directories do not exist (no error).
- **Local detection**: if any discovered `src` path is outside
  `${XDG_CONFIG_HOME:-$HOME/.config}/ai-sandbox/`, set `local: true` in the
  written YAML (matching the installer's auto-detection rule).
- **Write the YAML**: emit a valid profile document with `metadata`
  (`name`, `version: "1.0.0"`, `local` when applicable), `mode`, and the
  discovered `skills`/`hooks`/`agents` lists and `plugins`. Prefer generating
  the YAML via a small `node -e` using `js-yaml.dump` (guarantees valid YAML and
  proper quoting) over hand-rolled bash string concatenation — this avoids
  quoting/escaping bugs and keeps output schema-faithful. Document the approach.
- On success, print exactly `Created profile: <output-path>` to stdout (spec
  format) and exit 0.

### `src/index.sh` dispatch

- `source ./create-profile.sh` alongside the other module sources at the top.
- Add a dispatch branch: `elif [ "${CMD}" == "create-profile" ]; then
  create_profile "${ARGS[@]}"`. `create-profile` does NOT require docker — place
  the branch (or a short-circuit like the existing `kill-local-ai` one) so it
  runs without a docker preflight. Mirror the `kill-local-ai` short-circuit
  pattern near the top of the dispatch flow to skip the docker check.
- Ensure `parse_options` forwards `--name` / `--mode` / `--output` / `--plugins`
  into `ARGS` when `CMD=create-profile` (note: Task 004 adds `--mode` as a
  global; `create-profile` also uses `--mode`. Decide precedence — for the
  `create-profile` command, `--mode` should configure the written profile, not a
  runtime override. Simplest: `create_profile` reads its own flags from `ARGS`;
  ensure Task 004's global `--mode` parsing does not swallow it for this command,
  OR have `create_profile` read the `MODE_OVERRIDE` global. Coordinate with Task
  004 and document the resolution).
- Add a `help.sh` entry for `create-profile` (optional but encouraged) — if
  touched, keep it consistent with existing help formatting.

### shellcheck

- `src/create-profile.sh` and any edits to `src/index.sh` must pass `make lint`.
  Add inline reasons for any `# shellcheck disable` directives.

### Integration points

- **Task 002**: written YAML must load cleanly through `profile-installer.js`
  (same schema + local rule).
- **Task 004**: shares `--mode` flag namespace and the `ARGS` forwarding; agree
  on how `--mode` is routed for the `create-profile` command vs. runtime
  override.

## Validation

- `make build` succeeds; `make lint` passes.
- `bash bin/ai-sandbox.sh create-profile --name testprof --output /tmp/testprof.yaml`
  (with no docker running) exits 0, prints `Created profile: /tmp/testprof.yaml`,
  and the file exists.
- The written file loads via the installer:
  copy it to `./profiles/testprof.yaml` (or point discovery at it) and
  `node bin/profile-installer.js testprof` exits 0.
- The written file parses as valid YAML and has `metadata.name == testprof` and
  `mode == mirror` (default):
  `node -e "const y=require('js-yaml'),fs=require('fs');const d=y.load(fs.readFileSync('/tmp/testprof.yaml','utf8'));process.exit(d.metadata.name==='testprof'&&d.mode==='mirror'?0:1)"`.
- Local detection: create a `~/.claude/skills/foo.md`, run create-profile, and
  confirm the output sets `local: true`.
- Missing `--name` exits nonzero with a clear message.

## Assumptions

- Interactive plugin prompting is optional in V1; non-TTY runs default to an
  empty plugin list.
- YAML emission uses `js-yaml.dump` via `node -e` for correctness.
- The container home path for `dst` is derived from `HOST_USER`/`HOST_HOME`
  consistent with the Dockerfile.

## References

- [`docs/ai-sandbox-profiles-spec.md`](../../docs/ai-sandbox-profiles-spec.md) —
  "The `create-profile` command", "Local vs. shareable profiles".
- `src/kill-local.sh` + `src/index.sh` — pattern for a docker-free subcommand
  short-circuit.
