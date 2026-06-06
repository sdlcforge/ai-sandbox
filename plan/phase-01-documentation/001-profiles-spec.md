# Write Profiles Spec

## Purpose and scope

Write `docs/ai-sandbox-profiles-spec.md` — the canonical specification for the ai-sandbox profiles feature. This is a new file; no existing spec exists. The spec will serve as the source of truth for all subsequent implementation work and for the reference doc updates in Task 002.

## Requirements

### Profile concept

A **profile** is a YAML file that defines a reproducible ai-sandbox environment. Profiles replace ad-hoc CLI flags for configuring what's inside the container. ai-sandbox ships with bundled standard profiles; users create their own.

### Profile YAML schema

Document the full schema with an annotated example. Required top-level keys:

**`metadata`** (object) — ignored during profile composition merges:
- `name` (string, required)
- `version` (string, required — semver)
- `description` (string)
- `author` (string)
- `requires` (string — minimum ai-sandbox version, semver range)
- `local` (boolean — auto-set by profile-installer when local paths detected; marks profile as not generally shareable)

**`mode`** (string) — `mirror` or `static`:
- `mirror`: container mirrors host identity (SSH keys, git config, `~/.claude`, `~/.config`) and applies profile additions on top. Default behavior today.
- `static`: self-contained environment; no host identity mirroring. Suitable for CI/CD and shared deployments.
- Can be overridden at invocation time: `ai-sandbox start --mode static` overrides the profile value.

**`docker`** (boolean) — whether to attach the docker-socket-proxy sidecar. Replaces the `--docker` CLI flag.

**`packages`** (list of strings) — apt packages to install at image build time.

**`setup_script`** (string, path) — path to a script run at image build time after packages are installed. Resolved relative to the profile file.

**`plugins`** (list of strings) — Claude Code plugin names to install and enable.

**`skills`** (list of objects: `{src, dst}`) — skill files/dirs to copy into the container. `src` is resolved relative to the profile file; `dst` is the in-container destination path.

**`hooks`** (list of objects: `{src, dst}`) — hook files to copy in. Same resolution rules as `skills`.

**`agents`** (list of objects: `{src, dst}`) — agent definition files to copy in.

**`required_env`** (list of strings) — env var names the profile requires. profile-installer validates these are set on the host before building.

**`optional_env`** (list of strings) — env var names the profile may use, but absence is not an error.

**`network`** (object):
- `allow` (list of strings) — hostnames or CIDRs to add to the iptables allow-list. Extends the default (GitHub + Anthropic). V1 is additive only.
- Schema supports future `preset: none | default` for "default no network" direction — document the field and note it is not yet implemented.

### Profile composition

Document how multiple profiles are merged:
- **Lists** (`packages`, `plugins`, `skills`, `hooks`, `agents`, `network.allow`, `required_env`, `optional_env`): union.
- **Scalars** (`mode`, `docker`, `setup_script`): error on conflict — if two composed profiles both set the same scalar to different values, profile-installer exits nonzero with a clear error naming the conflicting profiles and field.
- **`metadata`** block: ignored entirely during merge. The composed result has no `metadata`.

### Profile storage and discovery

Priority-ordered search for `<name>`:
1. `./profiles/<name>.yaml` (project-local)
2. `$XDG_CONFIG_HOME/ai-sandbox/profiles/<name>.yaml` (default: `~/.config/ai-sandbox/profiles/<name>.yaml`)
3. Bundled profiles shipped with ai-sandbox (in the install tree)

### Local vs. shareable profiles

- profile-installer auto-detects local profiles: if any `src` path in `skills`, `hooks`, or `agents` resolves to a path outside the profile file's directory and outside `$XDG_CONFIG_HOME/ai-sandbox/`, it sets `local: true` on the loaded profile object and emits a warning.
- `create-profile` sets `local: true` in the written YAML when it auto-discovers paths from `~/.claude` or `./.claude/`.
- Local profiles are not inherently unshareable, but their paths may not resolve on other machines. Document this explicitly.

### Standard profiles (bundled)

ai-sandbox ships these bundled profiles:
- `base` — Go, Node.js (nvm), Bun, zsh + Oh My Zsh, git-delta, jq, build-essential. Extracted from the current Dockerfile.
- `docker` — Enables the docker-socket-proxy sidecar (`docker: true`).
- `chromium` — Chromium + X11 forwarding layer.
- `mirror` — Sets `mode: mirror`. Compose with others.
- `static` — Sets `mode: static`.

### Default profiles

Configured in `~/.config/ai-sandbox/config.yaml` under `default_profiles` (list of profile names). Applies when `ai-sandbox start` is called with no `--profile` flags. Ships pre-populated with `[base, mirror]`.

### Image tagging by profile

Profile images are tagged `ai-sandbox:profile-<composition-hash>` where the hash is derived from the ordered, resolved set of composed profile names. `is_build_stale` checks profile file mtimes in addition to the `docker/` directory mtime. Document the naming scheme.

### The `profile-installer.js` Node script

`bin/profile-installer.js` is the boundary between YAML and bash. Responsibilities:
- Parse and validate profile YAML (schema validation, unknown-key warnings).
- Resolve profile composition: load all named profiles in order, apply merge rules, error on scalar conflicts.
- Resolve paths: `src` fields relative to profile file; validate resolved paths exist.
- Detect local paths and set `local: true`.
- Validate `required_env` vars are present in the host environment.
- Output to stdout in three formats consumed by bash callers:
  - Shell-sourceable `KEY=VALUE` block for scalars (`MODE`, `DOCKER_ENABLED`, `IMAGE_TAG`, etc.).
  - Newline-delimited absolute paths for file-copy operations (skills, hooks, agents).
  - JSON blob (read via `jq`) for structured data (packages list, network rules, plugins list).

### The `create-profile` command

New ai-sandbox command. Behavior:
- Accepts `--name <name>`, `--mode <mirror|static>`, `--output <path>` flags.
- Discovers skills from `~/.claude/skills/` and `./.claude/skills/` (CWD).
- Discovers hooks from `~/.claude/hooks/` and `./.claude/hooks/`.
- Discovers agents from `~/.claude/agents/` and `./.claude/agents/`.
- Prompts or accepts `--plugins` flag for plugin list.
- Auto-sets `local: true` if any discovered path is outside `$XDG_CONFIG_HOME/ai-sandbox/`.
- Writes profile YAML to `--output` (default: `./profiles/<name>.yaml`).
- Outputs generated profile path on success.

### Invocation changes

Document how profiles are passed to commands:
- `ai-sandbox start --profile base --profile docker` — compose multiple profiles.
- `ai-sandbox start --mode static` — override mode from profile.
- `--docker`/`--no-docker` CLI flags are removed; use `--profile docker` or set `docker: false` in your profile.
- `--no-chromium` CLI flag is removed; chromium is opt-in via `--profile chromium`.

## Assumptions

- The spec documents designed behavior, not yet-implemented behavior. Implementation follows in a separate round.
- The Node.js `profile-installer.js` uses a YAML parsing library (e.g. `js-yaml`); the spec does not need to specify the library, only the interface.
- `create-profile` auto-discovery follows glob patterns; exact glob syntax is an implementation detail.

## References

- Conversation where spec was designed (June 2026)
- `docs/architecture.md` — existing architecture context
- `README.md` — existing CLI surface

## Validation

- `docs/ai-sandbox-profiles-spec.md` exists.
- Spec contains all required sections: concept overview, full YAML schema with annotated example, composition rules, storage/discovery order, local vs. shareable distinction, bundled standard profiles list, default profiles config, image tagging scheme, profile-installer interface, create-profile command, invocation changes.
- An annotated YAML example in the spec is syntactically valid.
- Spec is internally consistent: no contradictions between sections.
- Prose is clear and at the level of a developer picking up the spec cold.

## Status

**outcome**: succeeded
**date**: 2026-06-06
**validation summary**:
- `docs/ai-sandbox-profiles-spec.md` created.
- All required sections present: concept overview, full YAML schema with annotated example, composition rules, storage/discovery order, local vs. shareable distinction, bundled standard profiles list, default profiles config, image tagging scheme, profile-installer interface, create-profile command, invocation changes.
- Annotated YAML example validated syntactically valid (python3 `yaml.safe_load`).
- Spec internally consistent; no contradictions found across sections.

**files affected**:
- `docs/ai-sandbox-profiles-spec.md` (created)
- `plan/phase-01-documentation/001-profiles-spec.md` (this file, status added)

**decisions made**:
- `network.preset` field is documented as reserved/not-yet-implemented per the task requirement to "document the field and note it is not yet implemented."
- Object list deduplication rule (`skills`, `hooks`, `agents`) specifies no deduplication of identical `{src, dst}` pairs, since the task did not specify and removing a duplicate entry is harmless while keeping them is safe; flagged for planner review if a different rule is wanted.
- Table format used for the bundled profiles list and field reference tables for readability.

**assumptions applied**:
- Spec documents designed (not yet implemented) behavior per the Assumptions section.
- `profile-installer.js` YAML library choice is left to the implementer; spec specifies the interface only.
