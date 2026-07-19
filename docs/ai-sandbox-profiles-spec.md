# AI Sandbox Profiles Spec

## Purpose and scope

This document is the canonical specification for the ai-sandbox **profiles** feature. It is the source of truth for all implementation work, review, and user documentation relating to profiles.

A profile is the unit of environment configuration for ai-sandbox. Profiles replace ad-hoc CLI flags — `--docker`, `--no-chromium`, etc. — with reusable, composable YAML files that fully describe what an ai-sandbox container contains and how it is started. This document specifies the YAML schema, the composition rules, the storage and discovery order, the `profile-installer.js` interface, the `profiles create` command, and how profiles integrate with the existing CLI.

## Profile concept

A **profile** is a YAML file that defines a reproducible ai-sandbox environment. A profile names the apt packages to install, the Claude Code plugins to enable, the skill/hook/agent files to copy in, the network allow-list additions, and the container mode (`mirror` vs. `static`). Profiles can be composed: running `ai-sandbox start --profile base --profile docker` merges both profiles before building or starting.

Profiles replace ad-hoc CLI flags for configuring the container's contents. They are the primary interface for customizing the environment and for sharing a reproducible setup with teammates or across projects.

## YAML schema

### Annotated example

```yaml
metadata:
  name: my-project
  version: "1.0.0"
  description: "Go + Docker access for the widget-fetcher project"
  author: "zane@example.com"
  requires: ">=0.5.0"
  # local is auto-set by profile-installer when local paths are detected;
  # marks the profile as containing paths that may not resolve on other machines.
  local: false

# "mirror" mirrors host identity (SSH keys, git config, ~/.claude, ~/.config)
# and applies profile additions on top. "static" is self-contained with no
# host identity mirroring, suitable for CI/CD and shared deployments.
mode: mirror

# Optional list of capabilities to include in the image.
# Currently supported: "docker", "chromium", "web-search", "host-access",
# "lan-access". The last three are runtime-only (no build-time effect) --
# see "Capabilities reference" below.
# Absent or empty means a lean image with no Docker CLI, no proxy sidecar,
# and no Chromium. Order does not matter.
capabilities: [docker]

# apt packages installed at image build time.
packages:
  - ripgrep
  - fd-find

# Path to a script run at image build time after packages are installed.
# Resolved relative to the profile file.
setup_script: scripts/setup.sh

# Claude Code plugin names to install and enable.
plugins:
  - claude-mem

# Skill files or directories to copy into the container.
# src is resolved relative to the profile file; dst is the in-container path.
skills:
  - src: skills/my-skill.md
    dst: /home/user/.claude/skills/my-skill.md

# Hook files to copy in. Same resolution rules as skills.
hooks:
  - src: hooks/post-tool.sh
    dst: /home/user/.claude/hooks/post-tool.sh

# Agent definition files to copy in.
agents:
  - src: agents/planner.md
    dst: /home/user/.claude/agents/planner.md

# Environment variable names the profile requires.
# profile-installer validates these are set on the host before building.
required_env:
  - WIDGET_API_KEY

# Environment variable names the profile may use; absence is not an error.
optional_env:
  - WIDGET_STAGING_URL

network:
  # Hostnames or CIDRs to add to the iptables allow-list.
  # Extends the default allow-list (GitHub + Anthropic). V1 is additive only.
  allow:
    - api.example.com
    - 10.0.0.0/8
  # preset: reserved for a future "default no network" direction.
  # Not yet implemented; document the field for forward-compatibility.
  # preset: default   # "default" = GitHub + Anthropic (current behavior)
  #                   # "none"    = outbound blocked; explicit allow only
```

### Field reference

All top-level keys are optional unless noted. Unknown keys produce a warning from `profile-installer.js` and are ignored.

#### `metadata` (object)

Ignored entirely during profile composition merges. The composed result has no `metadata` block.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Human-readable profile name. |
| `version` | string | yes | Profile version; semver. |
| `description` | string | no | Short description of the profile's purpose. |
| `author` | string | no | Profile author (name or email). |
| `requires` | string | no | Minimum ai-sandbox version required to use this profile; semver range (e.g. `>=0.5.0`). |
| `local` | boolean | no | Auto-set by `profile-installer` when any `src` path in `skills`, `hooks`, or `agents` resolves outside the profile file's directory and outside `$XDG_CONFIG_HOME/ai-sandbox/`. Marks the profile as containing paths that may not resolve on other machines. Can also be set manually. |

#### `mode` (string)

Container identity mode. One of:

- `mirror` — the container mirrors the host's identity: SSH keys, git config, `~/.claude`, and `~/.config` are mounted and visible inside. Profile additions are applied on top. This is the current default behavior.
- `static` — self-contained environment; no host identity mirroring. The container's home directory is clean. Suitable for CI/CD pipelines, shared team deployments, or any scenario where reproducing the container on another machine is required.

Can be overridden at invocation time: `ai-sandbox start --mode static` overrides the profile value for that run without changing the profile file.

When no profile sets `mode`, the launcher behaves as if `mode: mirror` were set (preserving backward compatibility with pre-profile behavior).

#### `capabilities` (list of strings)

An optional list of named capabilities to include when building the image. Absent or empty means a lean image with no additional capability layers. The order of entries does not affect the result. Currently supported values:

- `docker` — installs the Docker CLI inside the container and attaches the `tecnativa/docker-socket-proxy` sidecar, exposed as `DOCKER_HOST=tcp://docker-socket-proxy:2375`. Replaces the former `--docker` / `--no-docker` CLI flags.
- `chromium` — installs Chromium and the X11 forwarding layer. Replaces the former `--no-chromium` CLI flag.
- `web-search` — allow-lists egress to any public (non-private) IPv4 host on port 443. Runtime-only; see [Capabilities reference](#capabilities-reference) below.
- `host-access` — allow-lists egress to any TCP port currently listening on the host, via `host.docker.internal`. Runtime-only.
- `lan-access` — allow-lists egress to any IP address and TCP port on the host's LAN (local subnet). Runtime-only.

Future ai-sandbox-defined capabilities can be added to this list without schema changes.

#### `packages` (list of strings)

apt package names to install at image build time, after the base image layers. Packages are installed in the order produced by the merge (see [Profile composition](#profile-composition)). Duplicates are deduplicated before the install command is built.

#### `setup_script` (string — path)

Path to a shell script run at image build time after all `packages` have been installed. Resolved relative to the profile file. The script runs as root inside the build container. When multiple composed profiles each specify a `setup_script`, `profile-installer` exits nonzero — this is a scalar conflict (see [Profile composition](#profile-composition)).

#### `plugins` (list of strings)

Claude Code plugin names to install and enable when the image is built. Plugin names are matched exactly — no substring matching — consistent with the existing plugin-conflict preflight.

> **Note:** Plugin names listed here are enabled individually. To register the marketplace that provides them, use the `marketplaces` field.

#### `marketplaces` (list of strings)

Marketplace sources to register inside the container at init time via `claude plugins marketplace add <ref>`. Each entry must start with `https://` or `file://`.

```yaml
marketplaces:
  - https://registry.example.com/plugins
  - file:///home/user/my-local-plugin
```

| Attribute | Value |
|-----------|-------|
| Type | `[string]` |
| Default | `[]` |
| Composition | union — entries from all composed profiles are merged, duplicates removed, original order preserved |

#### `enable_all_plugins` (boolean)

When `true`, enables all plugins from the last registered marketplace.

```yaml
enable_all_plugins: true
```

| Attribute | Value |
|-----------|-------|
| Type | `bool` |
| Default | `false` |
| Composition | OR — `true` if any composed profile or CLI flag sets it to `true` |

#### `skills` (list of objects)

Files or directories to copy into the container at image build time.

| Field | Type | Description |
|-------|------|-------------|
| `src` | string | Source path. Resolved relative to the profile file. Must exist at build time. |
| `dst` | string | Destination path inside the container (absolute). |

#### `hooks` (list of objects)

Hook files to copy into the container. Same `{src, dst}` structure and resolution rules as `skills`.

#### `agents` (list of objects)

Agent definition files to copy into the container. Same `{src, dst}` structure and resolution rules as `skills`.

#### `required_env` (list of strings)

Environment variable names the profile requires. `profile-installer` validates that each named variable is present in the host environment before proceeding with a build. Missing required variables cause `profile-installer` to exit nonzero with a message naming the missing variable and the profile that declared it.

#### `optional_env` (list of strings)

Environment variable names the profile may use. Their absence is not an error. Documented so that users know what variables influence the container's behavior.

#### `network` (object)

| Field | Type | Description |
|-------|------|-------------|
| `allow` | list of strings | Hostnames or CIDRs to add to the iptables allow-list. Extends the default (GitHub + Anthropic). V1 is additive only — there is no mechanism to remove defaults. Every entry — hostname or CIDR — is allow-listed on **port 443 only**; there is no per-entry port override and no all-ports carve-out for CIDR entries. `docker/init-firewall.sh` applies `iptables -d <entry> --dport 443 -j ACCEPT` verbatim for each entry, which accepts both hostnames and CIDRs natively. Marketplace hosts (from `marketplaces:` / `--add-marketplace`) get the same port-443-only treatment. |
| `preset` | string | Reserved for a future "default no network" direction (`default` or `none`). Field is parsed and stored but has no effect in V1. Do not set this field in V1 profiles. |

## Capabilities reference

Capabilities are named features that extend the base image. They are declared in the `capabilities` list field of a profile and are implemented by assembling per-capability Dockerfile fragments at build time. The base image layer (`docker/capabilities/base.dockerfile`) is always included; each declared capability appends its own fragment (`docker/capabilities/<capability>.dockerfile`). An empty or absent `capabilities` list produces a lean image containing only the base layer — no Docker CLI, no socket proxy, no Chromium.

`web-search`, `host-access`, and `lan-access` are the first capabilities with no build-time effect: each one only extends the container's runtime egress-firewall allow-list (see `docker/init-firewall.sh`'s capability-dispatch block), so their Dockerfile fragments are intentionally empty (no-op) rather than absent — the fragment still has to exist to satisfy `docker/scripts/assemble-dockerfile.sh`'s validation that every named capability has a matching fragment file.

### `docker`

**What it installs:** The Docker CLI binary inside the container.

**What it enables:** The `tecnativa/docker-socket-proxy` sidecar is attached on a private Compose network and exposed as `DOCKER_HOST=tcp://docker-socket-proxy:2375` inside the container. The standard `docker` CLI picks up `DOCKER_HOST` automatically — no additional configuration required.

**Absence:** When `docker` is not in `capabilities`, no Docker CLI is installed and no proxy sidecar is started. The container cannot issue Docker API calls to the host daemon.

**Previously controlled by:** `--docker` / `--no-docker` CLI flags and the former `docker: boolean` profile field (both removed).

**Dockerfile fragment:** `docker/capabilities/docker.dockerfile`

### `chromium`

**What it installs:** The Chromium browser and the X11 forwarding layer (XQuartz integration on macOS).

**What it enables:** GUI-based browser automation or manual browsing from inside the container, forwarded to the host display via X11. On macOS, XQuartz is started automatically by the launcher when this capability is active.

**Absence:** When `chromium` is not in `capabilities`, no Chromium or X11 packages are installed. The container is headless.

**Previously controlled by:** `--no-chromium` CLI flag (removed; Chromium is now opt-in).

**Dockerfile fragment:** `docker/capabilities/chromium.dockerfile`

### `web-search`

**What it installs:** Nothing — this capability has no build-time effect (see the note above).

**What it enables:** Egress to any public (non-private) IPv4 destination on port 443. RFC 1918 private ranges, loopback, link-local, CGNAT, multicast, and other reserved ranges are excluded via dedicated `iptables` `RETURN` rules ahead of the `ACCEPT`, so this capability does not also grant LAN or host access.

**Absence:** When `web-search` is not in `capabilities`, egress remains restricted to the default allow-list (GitHub, Anthropic, plus any other active capability/`network.allow`/`--allow-egress` entries).

**Dockerfile fragment:** `docker/capabilities/web-search.dockerfile` (no-op)

### `host-access`

**What it installs:** Nothing — this capability has no build-time effect (see the note above).

**What it enables:** Egress to any TCP port currently listening on the host, reached via `host.docker.internal`. The listening-port set is enumerated host-side (`lsof -iTCP -sTCP:LISTEN`, macOS only) once, at container-start time; a host service started after the container is already running is not covered until the container is recreated.

**Absence:** When `host-access` is not in `capabilities`, the container cannot reach any host-side listening port beyond what the default allow-list or another active capability already permits.

**Resolution-failure visibility.** `host-access` resolves `host.docker.internal` itself (via `getent ahostsv4`, in the firewall-init sidecar) to build its allow-list rule. If that resolution yields no IPv4 address, the capability fails soft — it logs and skips, the container still starts, but no host ports get allow-listed. This failure is durably surfaced rather than left as a container-init log line: `ai-sandbox detail` shows a `Warnings:` line (`host-access: host.docker.internal did not resolve to an IPv4 address; no host ports allow-listed`) and `--json` output carries a `host_access.resolved: false` field with a `reason`, whenever the container is running and the failure occurred on its current lifecycle. Absent a failure, `--json` reports `host_access.resolved: true` and human output shows no warning. A subsequent successful resolution (e.g. after recreating the container) clears the signal. See [`docs/architecture.md`'s "host-access resolution-failure visibility"](architecture.md#capability-driven-dynamic-firewall-rules) for the marker mechanism.

**Dockerfile fragment:** `docker/capabilities/host-access.dockerfile` (no-op)

### `lan-access`

**What it installs:** Nothing — this capability has no build-time effect (see the note above).

**What it enables:** Egress to any IP address and TCP port on the host's LAN (local subnet). The LAN CIDR is detected host-side (`route get default` + `ipconfig`, macOS only) once, at container-start time; detection failure (no default route, VPN-only interface, unrecognized netmask, non-macOS host) fails soft — the capability becomes a no-op rather than an error.

**Absence:** When `lan-access` is not in `capabilities`, the container cannot reach LAN hosts beyond what the default allow-list or another active capability already permits.

**Dockerfile fragment:** `docker/capabilities/lan-access.dockerfile` (no-op)

## Profile composition

Multiple profiles are composed when `ai-sandbox start --profile a --profile b` is invoked. Profiles are merged left to right in the order they appear on the command line (or in `default_profiles`; see [Default profiles](#default-profiles)).

### Merge rules by field type

| Category | Fields | Rule |
|----------|--------|------|
| Lists | `packages`, `plugins`, `marketplaces`, `capabilities`, `skills`, `hooks`, `agents`, `network.allow`, `required_env`, `optional_env` | Union. Items from each profile are concatenated; duplicates are deduplicated (for simple string lists). Object lists (`skills`, `hooks`, `agents`) are not deduplicated — identical `{src, dst}` pairs from multiple profiles are kept once. |
| Scalars | `mode`, `setup_script` | Error on conflict. If two composed profiles both set the same scalar to different values, `profile-installer` exits nonzero with a message naming the conflicting profiles and the field. If only one profile sets a scalar, that value is used. If no profile sets a scalar, the field is absent in the merged result and the launcher applies its built-in default. |
| Boolean OR | `enable_all_plugins` | `true` if any composed profile sets it to `true`; `false` otherwise. |
| `metadata` | entire block | Ignored. The merged result has no `metadata` block. |

#### Field-level composition summary

| Field | Type | Composition |
|-------|------|-------------|
| `marketplaces` | `[string]` | union |
| `enable_all_plugins` | `bool` | OR |
| `plugins` | `[string]` | union |

### Scalar conflict example

Composing `mirror` (which sets `mode: mirror`) with `static` (which sets `mode: static`) is an error:

```
profile-installer: scalar conflict on field "mode":
  profile "mirror" sets mode=mirror
  profile "static" sets mode=static
Resolve by using only one of these profiles, or override with --mode at invocation time.
```

### List deduplication

String lists are deduplicated by exact equality. Order among surviving elements follows first-occurrence order across the composed profiles (the element from the leftmost profile that introduced it is kept in position; later duplicates are dropped).

## Profile storage and discovery

When a profile name `<name>` is requested, `profile-installer` searches the following locations in priority order, using the first match:

1. `./profiles/<name>.yaml` — project-local profile, relative to the current working directory.
2. `$XDG_CONFIG_HOME/ai-sandbox/profiles/<name>.yaml` — user global profile. `$XDG_CONFIG_HOME` defaults to `~/.config` when unset, making the effective path `~/.config/ai-sandbox/profiles/<name>.yaml`.
3. Bundled profiles shipped with ai-sandbox in its install tree.

Profile names must be valid POSIX filename components (no path separators). Requesting a name with a `/` in it is an error.

## Local vs. shareable profiles

A profile is **local** when any `src` path in its `skills`, `hooks`, or `agents` blocks resolves to a path that is:

- outside the profile file's own directory, **and**
- outside `$XDG_CONFIG_HOME/ai-sandbox/` (the user's global ai-sandbox config dir).

Profiles installed from `~/.claude/skills/` or `./.claude/skills/` and similar are common examples. `profile-installer` auto-detects this condition when loading a profile and sets `local: true` on the in-memory profile object, emitting a warning:

```
warning: profile "my-project" references paths outside its directory and outside
$XDG_CONFIG_HOME/ai-sandbox/. Setting local=true. This profile may not be usable
on other machines.
```

`profiles create` sets `local: true` in the written YAML when it auto-discovers paths from `~/.claude` or `./.claude/`.

Local profiles are not inherently unshareable — the profile file itself can be committed to source control and used by a team — but their `src` paths are absolute or relative to the current machine's filesystem layout and may not resolve on another machine. Teammates who clone the profile must update `src` values to match their own filesystem.

## Standard profiles (bundled)

ai-sandbox ships the following profiles in its install tree. They are always available by name without any per-user or per-project configuration.

| Name | Description |
|------|-------------|
| `base` | Go, Node.js (nvm), Bun, zsh + Oh My Zsh, git-delta, jq, build-essential. Extracted from the current Dockerfile. This is the fully-featured default runtime. |
| `docker` | Sets `capabilities: [docker]`. Compose with `base` or any other profile to add Docker CLI and socket-proxy access inside the container. |
| `chromium` | Sets `capabilities: [chromium]`. Adds Chromium browser and X11 forwarding layer. |
| `web-search` | Sets `capabilities: [web-search]`. Allow-lists egress to any public (non-private) IPv4 host on port 443. |
| `host-access` | Sets `capabilities: [host-access]`. Allow-lists egress to any TCP port currently listening on the host, via `host.docker.internal`. |
| `lan-access` | Sets `capabilities: [lan-access]`. Allow-lists egress to any IP address and TCP port on the host's LAN. |
| `mirror` | Sets `mode: mirror`. No other effect. Compose with any other profile to explicitly select mirror mode. |
| `static` | Sets `mode: static`. No other effect. Compose with any other profile to select self-contained mode for CI/CD use. |

## Default profiles

`~/.config/ai-sandbox/config.yaml` contains a `default_profiles` list:

```yaml
default_profiles:
  - base
  - mirror
```

When `ai-sandbox start` is called with no `--profile` flags, the `default_profiles` list is used as if the user had passed `--profile base --profile mirror`. The pre-populated default is `[base, mirror]`, which reproduces the behavior of a pre-profile ai-sandbox invocation.

Users can change the defaults by editing this file. `profiles create` does not modify `default_profiles` — users add their own profiles to the list manually.

## Image tagging by profile

Profile-based images are tagged `ai-sandbox:profile-<composition-hash>`.

The `<composition-hash>` is a short hash derived from the ordered, resolved list of composed profile names after deduplication and default expansion (e.g. `base+mirror` or `base+mirror+docker`), along with the resolved `capabilities` list from the merged profile. Because capabilities determine which Dockerfile fragments are assembled, they must be part of the hash input — two compositions that resolve to the same profile names but different capability sets produce different images and therefore different tags. The hash is stable: the same combination of profile names and capabilities always produces the same tag, regardless of wall-clock time or machine.

`is_build_stale` determines whether a rebuild is needed. For profile-based builds it checks:

1. The `docker/` directory mtime (existing behavior).
2. The mtime of each resolved profile YAML file in the composition.
3. The mtime of each `src` file referenced by `skills`, `hooks`, `agents`, and `setup_script` in the merged profile.

If any of these files is newer than the image's `docker image inspect .Created` timestamp, the image is considered stale and is rebuilt before starting.

The previous variant-key scheme (`ai-sandbox:<variant>` derived from `--no-chromium`/`--no-docker` flags) is superseded by the profile hash scheme. Images built against specific flag combinations will remain on disk but the launcher will no longer generate them for new invocations.

## The `profile-installer.js` Node script

`bin/profile-installer.js` is the boundary between profile YAML and bash. It is invoked by the bash launcher (`src/index.sh` and related modules) and consumes one or more profile names. It runs in the host Node.js environment (not inside the container).

### Responsibilities

1. **Parse and validate profile YAML.** Uses a YAML parsing library (e.g. `js-yaml`). Emits schema-validation errors on unknown keys (warning, not error) and on type mismatches (error, exits nonzero).
2. **Resolve profile discovery.** For each named profile, search the three locations in [Profile storage and discovery](#profile-storage-and-discovery) order. Exit nonzero if a profile is not found.
3. **Apply composition rules.** Load all named profiles in order, apply the merge rules in [Profile composition](#profile-composition), and exit nonzero on scalar conflicts. The output is a single merged profile object.
4. **Resolve capabilities to Dockerfile fragments.** For each capability named in the merged `capabilities` list, locate the corresponding Dockerfile fragment (`docker/capabilities/<capability>.dockerfile`). Assemble these fragments — along with the base image fragment (`docker/capabilities/base.dockerfile`) — into the effective Dockerfile used for the image build. This replaces the previous ARG/variant approach and scales to future capabilities without schema changes.
5. **Resolve paths.** For each `src` in `skills`, `hooks`, `agents`, and for `setup_script`, resolve the path relative to the profile file that declared it. Validate that each resolved path exists. Exit nonzero on missing paths.
6. **Detect local paths.** Implement the auto-detection rule from [Local vs. shareable profiles](#local-vs-shareable-profiles). Set `local: true` on the in-memory merged object and emit a warning when detected.
7. **Validate `required_env`.** For each name in the merged `required_env` list, check that the variable is present in `process.env`. Exit nonzero with a descriptive error message naming the missing variable and the profile that declared it.
8. **Compute the composition hash.** Derive `<composition-hash>` from the ordered list of resolved profile names. The resolved `capabilities` list is included as an input to this hash. Output the hash as part of the shell-sourceable block.
9. **Output to stdout** in the three formats described below.

### Output formats

The script writes to stdout in three blocks, separated by sentinel lines so the bash caller can extract each block:

**Shell-sourceable `KEY=VALUE` block** — consumed via `eval "$(profile-installer.js ...)"` or sourced into a subshell. Variables exported:

```bash
PROFILE_MODE=mirror          # or "static", or "" if no profile set it
PROFILE_CAPABILITIES=docker  # space-separated capability names, or "" if none
PROFILE_IMAGE_TAG=profile-a1b2c3d4   # ai-sandbox:profile-<hash>
PROFILE_LOCAL=false          # "true" if any composed profile is local
PROFILE_COMPOSITION_HASH=a1b2c3d4
```

**Newline-delimited absolute-path pairs** — one line per file-copy operation, in the form `<absolute-src-path>\t<dst-path>`. Three separate sections, each preceded by a sentinel comment, cover skills, hooks, and agents respectively. The bash caller iterates these lines to copy files into the build context.

**JSON blob** — a single JSON object on one line, read via `jq` by the bash caller for structured data:

```json
{
  "packages": ["ripgrep", "fd-find"],
  "plugins": ["claude-mem"],
  "marketplaces": ["https://registry.example.com/plugins"],
  "enable_all_plugins": false,
  "network_allow": ["api.example.com", "10.0.0.0/8"],
  "required_env": ["WIDGET_API_KEY"],
  "optional_env": ["WIDGET_STAGING_URL"]
}
```

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success. Stdout contains the three output blocks. |
| 1 | Input error: profile not found, unknown key (only for strict-mode callers), type mismatch, missing `src` path, scalar conflict, or missing required env var. Stderr contains a human-readable error. |

## The `profiles create` command

`ai-sandbox profiles create <name>` scaffolds a profile YAML file by auto-discovering skills, hooks, and agents from the standard locations and prompting the user for any remaining configuration.

Profile listing (`ai-sandbox profiles ls`) and deletion (`ai-sandbox <name> delete`) are documented in `README.md`'s [CLI reference](../README.md#cli-reference) rather than duplicated here — this section covers only `profiles create`'s own flags and auto-discovery behavior, not the general CLI grammar.

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `<name>` | required | Positional argument (not a flag). Profile name, used as the filename (`<name>.yaml`) and the `metadata.name` value. |
| `--mode <mirror\|static>` | `mirror` | Container mode. Written to `metadata` and the `mode` field. |
| `--output <path>` | `./profiles/<name>.yaml` | Destination path for the written YAML file. |
| `--plugins <name,...>` | (empty) | Comma-separated list of plugin names to include. Can be specified multiple times. Also accepted interactively when not given. |

### Auto-discovery

`profiles create` discovers source files from the following locations, in order:

- Skills: `~/.claude/skills/` and `./.claude/skills/` (current working directory).
- Hooks: `~/.claude/hooks/` and `./.claude/hooks/`.
- Agents: `~/.claude/agents/` and `./.claude/agents/`.

Each discovered path is added to the appropriate list in the generated YAML with `src` set to the absolute resolved path and `dst` set to the corresponding in-container path under `/home/<user>/.claude/`.

If any discovered path is outside `$XDG_CONFIG_HOME/ai-sandbox/`, `profiles create` sets `local: true` in the written YAML (matching the `profile-installer` auto-detection rule).

### Output

On success, `profiles create` writes the profile YAML to `--output` and prints the generated file path to stdout:

```
Created profile: ./profiles/my-project.yaml
```

The `--output` parent directory is created if it does not exist.

## Invocation changes

### Passing profiles to commands

Profiles are composed by passing `--profile` once per profile, in order:

```sh
ai-sandbox start --profile base --profile docker
```

Multiple `--profile` flags are merged left to right according to the composition rules.

### Overriding mode at invocation time

`--mode <mirror|static>` overrides the `mode` value from the composed profile for that run only. It does not modify the profile file.

```sh
ai-sandbox start --profile base --mode static
```

### `--add-host`: pinning a stable host IPv4

```sh
ai-sandbox start --add-host myhost:192.168.65.254
```

`--add-host <name>:<ip>` is a repeatable, public CLI flag — independent of
the profile system — that pins a caller-supplied hostname to a literal IPv4
address inside the container's `/etc/hosts`. It exists because Docker
Desktop's `host.docker.internal` resolution has proven not to be uniformly
IPv4 across otherwise-identical installs; rather than have ai-sandbox try to
detect or resolve a host IPv4 itself, the caller supplies the IP it wants and
ai-sandbox threads it into the container verbatim. Repeat the flag to pin
multiple entries in one invocation.

**Validation contract.**

| Part | Rule |
|------|------|
| `<name>` | Must be a valid hostname. Cannot be `host.docker.internal` — that name is reserved (see below). |
| `<ip>` | Must be a bare IPv4 literal (e.g. `192.168.65.254`). No CIDR and no hostname form — unlike `--allow-egress`'s host part, which accepts either. |

A spec with anything other than exactly one `:` separating `<name>` from
`<ip>`, or that fails either check above, is rejected at parse time with a
distinct error message per failure mode and a nonzero exit; nothing partial
is applied.

**`host.docker.internal` is reserved.** ai-sandbox already statically maps
this exact name to the container's host-gateway IP. Supplying
`--add-host host.docker.internal:<ip>` is rejected outright — both at parse
time and when restoring a previously-saved value — rather than
accepted-then-warned: it would create a second, conflicting `/etc/hosts`
entry for the same name with no reliably-controllable resolution precedence,
and could indeterminately retarget which IP the `host-access` capability's
firewall rule (which resolves that same name) actually allow-lists. See
[`docs/architecture.md`'s "Caller-pinned host reachability: `--add-host`"](architecture.md#caller-pinned-host-reachability---add-host)
for the full mechanism.

**Persistence.** `--add-host` is CLI-only — there is no profile-level
equivalent to compose it with — so, like `--allow-egress`, its full
effective value is persisted verbatim across `start`/restore and compared on
every explicit invocation, prompting for consent before a value change would
otherwise silently recreate a running container. See
[`docs/architecture.md`'s "Config persistence and restore"](architecture.md#config-persistence-and-restore).

#### Downstream-automation-consumer contract

`--add-host` is the stable, documented mechanism for an automation caller to
pin a host-side service's IPv4 for a container created via
`ai-sandbox instances create` (or the normal `create`/`start` path
generally), independent of Docker Desktop's variable `host.docker.internal`
resolution. The motivating consumer is Flow's flow-run-optimizer, which
needs its in-container process to report OpenTelemetry data to a host-side
collector.

**Pinning a name only makes it *resolvable* — reaching it under the
default-deny firewall additionally requires an egress allowance.** The two
composition paths:

- **`host.docker.internal` itself is not pinnable via `--add-host`** (it is
  reserved — see above). Reaching it stays governed entirely by the
  `host-access` capability (`capabilities: [host-access]`; see
  [Capabilities reference](#capabilities-reference) above): `host-access`
  independently resolves `host.docker.internal` and allow-lists its IPv4 on
  the host's currently-LISTENing TCP ports, with a resolution-failure signal
  now surfaced in `ai-sandbox detail`/`--json` output if that resolution
  fails (see the [`host-access`](#host-access) entry above). A caller whose
  host reliably resolves `host.docker.internal` needs nothing from
  `--add-host` for this case.
- **Any other name is the `--add-host` path.** A caller that cannot rely on
  `host.docker.internal` resolving as expected — or that simply wants a
  stable, self-controlled endpoint entirely immune to Docker Desktop's
  resolution variance — pins a name it chooses (e.g. `otel-collector`) to a
  host IPv4 it has determined by its own means (ai-sandbox does not detect
  or validate host-side reachability of the pinned IP; that determination is
  the caller's responsibility): `--add-host otel-collector:192.168.65.254`.
  This makes the name *resolvable* inside the container. To make it
  *reachable*, the caller must also pass
  `--allow-egress 192.168.65.254:4318` (the pinned IP and target port) —
  `host-access`'s firewall rule is hardcoded to `host.docker.internal` and
  does not cover any other name. The caller's application then targets the
  pinned name (`otel-collector:4318`), not `host.docker.internal`,
  sidestepping the resolution question entirely.

`--add-host` does not fix `host.docker.internal` resolution itself — no
host-side IPv4 auto-detection ships in ai-sandbox. It gives a caller a
name/IP mapping it fully controls, composed with an explicit egress grant,
as the documented alternative to depending on Docker Desktop's resolution
behavior.

### Removed flags

The following CLI flags are removed in the profiles release:

| Removed flag | Replacement |
|---|---|
| `--docker` | `--profile docker` or `capabilities: [docker]` in a profile |
| `--no-docker` / `-D` | Omit the `docker` profile and omit `docker` from any `capabilities` list in composed profiles |
| `--no-chromium` | Omit the `chromium` profile (Chromium is opt-in via `--profile chromium` or `capabilities: [chromium]`) |

Callers using the removed flags receive a clear error message directing them to the profile-based equivalent.

### Backward compatibility

When `ai-sandbox start` is invoked with no `--profile` flags and no `default_profiles` override, the launcher uses `[base, mirror]` as the default composition. This reproduces pre-profile behavior for users who have not opted into profiles yet.
