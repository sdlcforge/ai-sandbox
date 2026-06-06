# Bundled Profile YAML Files + js-yaml Dependency

## Purpose and scope

Create the `profiles/` directory of bundled standard profiles that ship with
ai-sandbox, and add the `js-yaml` runtime dependency that
`bin/profile-installer.js` (Task 002) will consume. This task produces only
data files plus a dependency declaration — no executable logic. It is the root
of the dependency graph: Task 002 parses these YAML files and relies on
`js-yaml` being installed.

The canonical source of truth for the YAML schema and the bundled profile set
is [`docs/ai-sandbox-profiles-spec.md`](../../docs/ai-sandbox-profiles-spec.md).
Read it before starting; this task implements the "Standard profiles (bundled)"
and "YAML schema" sections.

## Requirements

### Add the `js-yaml` dependency

- Edit `package.json`. Add a `dependencies` block (it does not exist yet — the
  file currently has only `devDependencies`) containing `js-yaml` at a current
  stable major (`^4.1.0`).
- Run `npm install js-yaml` (or equivalent) so `package-lock.json` and
  `node_modules/` reflect the new dependency. The installed module must be
  `require`-able from `bin/profile-installer.js` at the repo root.
- Do not remove or alter the existing `devDependencies`.

### Create the bundled profiles directory

Create a top-level `profiles/` directory containing the five bundled standard
profiles. Each file is a valid YAML document conforming to the schema in the
spec. Every profile MUST include a `metadata` block with at minimum `name` and
`version` (both required by the schema).

This `profiles/` directory is the bundled / install-tree profile location
(discovery priority 3 in the spec). It must NOT be confused with a project-local
`./profiles/` directory in a consuming repo — Task 002 resolves the bundled
location by an absolute path relative to the installer script, not by CWD.

#### `profiles/base.yaml`

The fully-featured default runtime extracted from the current Dockerfile. It
represents the toolchain currently baked into the base image (Go, Node via nvm,
Bun, zsh + Oh My Zsh, git-delta, jq, build-essential, etc.).

- `metadata`: `name: base`, `version: "1.0.0"`, a `description` summarizing the
  toolchain.
- It does NOT set `mode` (mode selection is the job of the `mirror` / `static`
  profiles).
- It does NOT set `capabilities` (lean by default; docker/chromium are opt-in
  via their own profiles).
- The toolchain that lives in the base Dockerfile fragment (Task 003) is built
  in unconditionally; `base.yaml` therefore does not need a `packages` list
  duplicating those build-time tools. Keep `base.yaml` minimal — it primarily
  exists so `[base, mirror]` is a nameable default composition. Add a comment in
  the YAML noting that the base toolchain is provided by
  `docker/capabilities/base.dockerfile`, not by this profile's `packages`.

#### `profiles/docker.yaml`

- `metadata`: `name: docker`, `version: "1.0.0"`, description noting it adds
  Docker CLI + socket-proxy access.
- `capabilities: [docker]`. No other effect.

#### `profiles/chromium.yaml`

- `metadata`: `name: chromium`, `version: "1.0.0"`, description noting it adds
  Chromium + X11 forwarding.
- `capabilities: [chromium]`. No other effect.

#### `profiles/mirror.yaml`

- `metadata`: `name: mirror`, `version: "1.0.0"`, description noting it selects
  host-identity mirroring.
- `mode: mirror`. No other effect.

#### `profiles/static.yaml`

- `metadata`: `name: static`, `version: "1.0.0"`, description noting it selects
  the self-contained CI/CD mode.
- `mode: static`. No other effect.

### Integration points

- **Task 002 (`profile-installer.js`)** loads and parses these files. The
  `metadata` block of each must be present and valid; capability names
  (`docker`, `chromium`) must exactly match the Dockerfile fragment basenames
  Task 003 creates (`docker/capabilities/docker.dockerfile`,
  `docker/capabilities/chromium.dockerfile`).
- **Task 005 (image tagging)** hashes the resolved `capabilities` list. The
  capability strings here are part of that hash input, so they must be stable
  and lowercase.

## Validation

- `node -e "const y=require('js-yaml'); console.log(typeof y.load)"` prints
  `function` (confirms `js-yaml` is installed and resolvable).
- `grep -q '"js-yaml"' package.json` succeeds.
- All five files exist:
  `ls profiles/base.yaml profiles/docker.yaml profiles/chromium.yaml profiles/mirror.yaml profiles/static.yaml`.
- Each file parses as valid YAML and has a `metadata.name` + `metadata.version`:
  ```
  for f in profiles/*.yaml; do
    node -e "const y=require('js-yaml'),fs=require('fs');
      const d=y.load(fs.readFileSync('$f','utf8'));
      if(!d.metadata||!d.metadata.name||!d.metadata.version){console.error('bad: $f');process.exit(1)}"
  done
  ```
- `docker.yaml` has `capabilities: [docker]`, `chromium.yaml` has
  `capabilities: [chromium]`, `mirror.yaml` has `mode: mirror`, `static.yaml`
  has `mode: static`. Verify with `node -e` reads as above.
- `base.yaml` sets neither `mode` nor `capabilities`.

## References

- [`docs/ai-sandbox-profiles-spec.md`](../../docs/ai-sandbox-profiles-spec.md) —
  "YAML schema", "Standard profiles (bundled)", "Capabilities reference".
- `docker/Dockerfile` — the current toolchain that `base` represents.
