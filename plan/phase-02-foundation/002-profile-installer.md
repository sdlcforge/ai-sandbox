# bin/profile-installer.js — YAML Parse, Compose, Validate, Emit

## Purpose and scope

Implement `bin/profile-installer.js`, the Node.js boundary between profile YAML
and the bash launcher. It accepts one or more profile names, resolves them
through the discovery order, composes them per the merge rules, validates
paths/env/capabilities, computes the composition hash, and writes three
sentinel-delimited output blocks to stdout for the bash caller to consume.

This is the load-bearing implementation task. The CLI integration (Task 004),
image tagging (Task 005), and create-profile (Task 006) all depend on the exact
interface defined here. Implement the interface precisely as the spec describes
it.

The canonical source of truth is
[`docs/ai-sandbox-profiles-spec.md`](../../docs/ai-sandbox-profiles-spec.md),
section "The `profile-installer.js` Node script". Read it before starting.

## Requirements

### File and invocation

- Create `bin/profile-installer.js`. Add a `#!/usr/bin/env node` shebang and make
  it executable (`chmod +x`).
- Use `require('js-yaml')` for YAML parsing (added in Task 001). Use only Node
  built-ins otherwise (`fs`, `path`, `crypto`, `process`).
- Invocation form: `profile-installer.js <name> [<name> ...]`. Each positional
  arg is a profile name, composed left to right. Reject any name containing a
  path separator (`/`) with a nonzero exit and a clear stderr message.
- The script runs in the host Node environment, NOT inside the container.

### Profile discovery

For each requested `<name>`, search in priority order, first match wins:

1. `./profiles/<name>.yaml` (relative to `process.cwd()`).
2. `${XDG_CONFIG_HOME:-$HOME/.config}/ai-sandbox/profiles/<name>.yaml`.
3. Bundled profiles: resolve relative to the installer script's own directory
   (`path.join(__dirname, '..', 'profiles', '<name>.yaml')`), so it finds the
   `profiles/` dir created in Task 001 regardless of CWD.

Exit nonzero (code 1) with a descriptive stderr message if a name is not found
in any location.

### Parse and schema validation

- Parse each found YAML file with `js-yaml`.
- Unknown top-level keys: emit a `warning:` to stderr and ignore the key (NOT an
  error).
- Type mismatches (e.g. `packages` is not a list, `mode` is not a string): exit
  nonzero (code 1) with a stderr message naming the field and the offending
  profile.
- Recognized top-level keys: `metadata`, `mode`, `capabilities`, `packages`,
  `setup_script`, `plugins`, `skills`, `hooks`, `agents`, `required_env`,
  `optional_env`, `network`.

### Composition / merge rules

Merge the loaded profiles left to right into a single in-memory object:

- **List fields** — `packages`, `plugins`, `capabilities`, `skills`, `hooks`,
  `agents`, `network.allow`, `required_env`, `optional_env`: union.
  - Simple string lists: deduplicate by exact equality, preserving
    first-occurrence order across the composition.
  - Object lists (`skills`, `hooks`, `agents`): deduplicate identical
    `{src, dst}` pairs (a pair is identical when both fields match after path
    resolution); otherwise keep all.
- **Scalar fields** — `mode`, `setup_script`: error on conflict. If two
  profiles set the same scalar to different values, exit nonzero (code 1) with a
  message naming both profiles and the field, matching the spec's "Scalar
  conflict example" format (field name, each profile and its value, resolution
  hint). If only one profile sets it, use that value. If none set it, the field
  is absent in the merged result.
- **`metadata`** — ignored entirely. The merged object has no `metadata`.

### Capability → Dockerfile fragment resolution

- For each capability in the merged `capabilities` list, verify a fragment
  exists at `docker/capabilities/<capability>.dockerfile` (resolve relative to
  the installer's repo root, i.e. `path.join(__dirname, '..', 'docker',
  'capabilities', ...)`). Exit nonzero if a declared capability has no fragment.
- The assembled effective Dockerfile is produced by the assembly script from
  Task 003; this task only validates that fragments exist and emits the
  capability list. Do NOT assemble the Dockerfile here — that is Task 003's job.
  (Coordinate interface: emit `PROFILE_CAPABILITIES` as a space-separated,
  sorted list so the assembly step and the hash are deterministic.)

### Path resolution and existence

- For each `src` in `skills`, `hooks`, `agents`, and for `setup_script`, resolve
  the path relative to the directory of the profile file that declared it (not
  CWD).
- Validate each resolved path exists on disk. Exit nonzero (code 1) on any
  missing path, naming the path and the declaring profile.

### Local-path detection

- A profile is local when any resolved `src` path in `skills`, `hooks`, or
  `agents` is outside BOTH the profile file's own directory AND
  `${XDG_CONFIG_HOME:-$HOME/.config}/ai-sandbox/`.
- When detected, set `local: true` on the merged object and emit the warning
  from the spec's "Local vs. shareable profiles" section to stderr.
- The emitted `PROFILE_LOCAL` is `true` if any composed profile is local, else
  `false`.

### required_env validation

- For each name in merged `required_env`, check `process.env`. Exit nonzero
  (code 1) with a message naming the missing variable and the profile that
  declared it. `optional_env` is documented only — never an error.

### Composition hash

- Compute `<composition-hash>`: a short hex hash (e.g. first 8 chars of a
  SHA-256) over a deterministic string built from (a) the ordered, deduplicated
  resolved profile-name list and (b) the sorted merged `capabilities` list.
  Capabilities MUST be part of the hash input (per spec: same names, different
  capabilities ⇒ different tag). The hash must be stable across runs/machines —
  no wall-clock, no absolute paths in the hash input.
- This hash function's exact input ordering is the contract Task 005's bash
  `variant_key` must NOT duplicate — Task 005 sources `PROFILE_IMAGE_TAG` /
  `PROFILE_COMPOSITION_HASH` from this script rather than recomputing. State the
  hash recipe in a code comment so Task 005 can rely on it.

### Output (stdout, three sentinel-delimited blocks)

Write exactly these three blocks to stdout, each preceded by a distinct sentinel
comment line so the bash caller can extract each independently:

1. **Shell-sourceable `KEY=VALUE` block.** Lines safe for `eval`/source. Quote
   values. Emit at least:
   ```
   PROFILE_MODE=mirror            # or "static" or "" when unset
   PROFILE_CAPABILITIES="docker"  # space-separated sorted names, or ""
   PROFILE_IMAGE_TAG=profile-a1b2c3d4   # the tag suffix (no "ai-sandbox:" prefix)
   PROFILE_LOCAL=false
   PROFILE_COMPOSITION_HASH=a1b2c3d4
   PROFILE_SETUP_SCRIPT=/abs/path/to/setup.sh   # or "" when unset
   ```
   Keep `PROFILE_IMAGE_TAG` as just the suffix (`profile-<hash>`); the bash
   caller prepends `ai-sandbox:`. Document this in the block's comment.
2. **File-copy path block.** Three sub-sections (skills, hooks, agents), each
   preceded by its own sentinel comment, one line per copy op formatted
   `<absolute-src>\t<dst>`.
3. **JSON blob** on a single line, e.g.:
   ```json
   {"packages":[...],"plugins":[...],"network_allow":[...],"required_env":[...],"optional_env":[...]}
   ```
   The bash caller reads this with `jq`.

Define the sentinel strings as constants and document them at the top of the
file; Task 004 must match them exactly when parsing.

### Exit codes

- `0` success (three blocks on stdout).
- `1` any input error (not found, type mismatch, missing src, scalar conflict,
  missing required env, missing capability fragment, name with `/`). Human-
  readable error on stderr.

## Integration points

- **Task 001** provides the bundled `profiles/` + `js-yaml`.
- **Task 003** provides `docker/capabilities/*.dockerfile`; capability validation
  here checks they exist.
- **Task 004** invokes this script and sources/parses all three blocks.
- **Task 005** consumes `PROFILE_IMAGE_TAG` / `PROFILE_COMPOSITION_HASH` and
  must NOT recompute the hash.

## Validation

- `node bin/profile-installer.js base mirror` exits 0 and prints a
  `PROFILE_MODE=mirror` line, `PROFILE_CAPABILITIES=` (empty), and a
  `PROFILE_IMAGE_TAG=profile-<hash>` line.
- `node bin/profile-installer.js base docker` exits 0 and prints
  `PROFILE_CAPABILITIES="docker"` (or `=docker`) and a different
  `PROFILE_COMPOSITION_HASH` than `base mirror`.
- `node bin/profile-installer.js mirror static` exits nonzero and stderr
  mentions a scalar conflict on `mode`.
- `node bin/profile-installer.js no-such-profile` exits nonzero with a
  not-found message.
- `node bin/profile-installer.js bad/name` exits nonzero (path separator).
- Hash stability: two runs of `node bin/profile-installer.js base docker | grep
  PROFILE_COMPOSITION_HASH` produce identical output.
- A required_env probe: a temp profile with `required_env: [DEFINITELY_UNSET]`
  exits nonzero naming the variable.
- The JSON block parses: `node bin/profile-installer.js base docker | tail -1 |
  node -e "JSON.parse(require('fs').readFileSync(0,'utf8'))"` (adjust to extract
  the JSON line) succeeds.

## Assumptions

- `bin/profile-installer.js` is a standalone Node script, not bundled by
  bash-rollup (rollup only handles `src/*.sh`). It ships as-is in `bin/`.
- The exact short-hash length (8) and algorithm (SHA-256 prefix) are an
  implementation detail as long as it is deterministic and documented.

## References

- [`docs/ai-sandbox-profiles-spec.md`](../../docs/ai-sandbox-profiles-spec.md) —
  "The `profile-installer.js` Node script", "Profile composition", "Profile
  storage and discovery", "Local vs. shareable profiles", "Image tagging by
  profile".
- `plan/next-steps.md` follow-ups on hash determinism and
  `PROFILE_CAPABILITIES` encoding.
