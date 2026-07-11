# Architecture

High-level view of how `ai-sandbox` is organized, how a command flows through the
code, and the non-obvious design decisions that shape it.

## What it is

A single bash CLI (`bin/ai-sandbox.sh`) that orchestrates `docker compose` to run
an Ubuntu container configured to look, from the inside, like an extension of the
user's macOS workstation — same user, same SSH agent, same git config, same
`~/.claude` state. The container's outbound network is clamped via `iptables` to
the handful of hosts an agent actually needs (GitHub, Anthropic API).

The product surface is small; the interesting engineering is in *what the host
launcher does before and around* `docker compose up`.

## Source structure and build pipeline

Sources live in `src/` as small, single-purpose modules. `src/index.sh` is the
entry point; it `source`s the other modules and then drives the command flow.
`@liquid-labs/bash-rollup` bundles these into a single distributable
`bin/ai-sandbox.sh`. **Never edit the rollup output directly** — it's a
generated artifact.

The `__SOURCED__` sentinel (just after the module `source`s) lets tests include
the rolled-up script as a library, exposing functions without running the main
script:

```bash
${__SOURCED__:+return}
```

Makefiles under `make/` are themselves **generated** by `@sdlcforge/gen-make`
(each file carries a "Do not edit manually" header). They accumulate
`BUILD_TARGETS` / `TEST_TARGETS` / `LINT_TARGETS` across fragment files and are
stitched together by `95-final-targets.mk`. In-tree edits happen when strictly
needed, but the expectation is that `gen-make` is the source of truth.

## Command flow

Running `ai-sandbox <cmd>` is a deterministic sequence of phases. Each phase is
a clearly commented block in `src/index.sh` and only runs when it applies:

1. **Parse options** (`options.sh`) — populate `CMD`, `ARGS`, and flag globals
   (`NO_CHROMIUM`, `NO_DOCKER`, `ENABLE_DOCKER_PROXY`, `STATUS_JSON`,
   `STATUS_TEST_CHECK`, `QUIET`).
2. **Short-circuits** — a name that resolves to a profile short-circuits
   immediately to `detail`/`delete` (the only profile-appropriate verbs, gated
   by the per-name resolve-then-verb-gate mechanism described in step 11
   below); `profiles ls`, `profiles create`, `help`, and `kill-local-ai` never
   touch Docker or the rest of the pipeline; `ls` and `instances ls` also
   short-circuit here but call `docker ps -a` (with stderr suppressed so they
   degrade gracefully rather than requiring the `check_docker` preflight in
   step 3 below).
3. **Docker preflight** — `check_docker` pokes `docker info`; on failure it
   tries `docker desktop start` once before giving up. `detail` is exempt so
   it can describe a down daemon instead of fighting it. Profile-kind dispatch
   (a name that resolves to an existing profile) is exempt entirely — it
   short-circuits in step 2 above, before this phase ever runs, rather than
   merely tolerating a down daemon like `detail` does.
4. **Resolve PROJECT_ROOT** — follow symlinks out to the real script location.
5. **Plugin-conflict preflight** (`plugin-conflicts.sh`) — only runs for
   `start` / `enter` / `up`. See *Concurrency invariant* below.
6. **Flag validation** — reject flag/command combinations that don't make
   sense (e.g. `--no-chromium` on anything but `build`, `--no-docker` while the
   container is running, `--docker` + `--no-docker`).
7. **Compose file assembly** — always `docker/docker-compose.yaml` plus a
   dynamically-generated volume-override file (`volume-override.sh`) plus
   optional chromium and proxy overlays.
8. **XQuartz** (`xquartz.sh`) — macOS only, only when Chromium is enabled.
9. **Export host-derived env vars** — `HOST_USER`, `HOST_UID`, `HOST_GID`,
   `HOST_TZ`, `HOST_ARCH`, git user identity, `AI_SANDBOX_IMAGE_TAG`. These
   feed `docker/docker-compose.yaml`'s `${VAR}` expansions.
10. **Tool downloads** (`tool-versions.sh`) — only for build-related commands;
    resolves language runtime versions and caches tarballs the Dockerfile
    `COPY`s in.
11. **Dispatch** — noun words are parsed first: `ls` for the bare grouped
    `Instances:`/`Profiles:` listing, and `instances ls`/`profiles
    ls`/`profiles create <name>` short-circuit ahead of the Docker pre-flight
    (step 3 above), same as step 2 above. `instances create <name>` does
    *not* short-circuit — it runs the full pipeline, including the Docker
    preflight, profile-installer resolution, and tool downloads, before
    reaching its dispatch arm. Otherwise a bare `<name>` argument is resolved
    to `instance`/`profile`/`unknown` (`resolve_name_kind()`); an unknown
    name errors immediately, and a profile-kind name is gated to
    `detail`/`delete` only, while an instance-kind name accepts the per-name
    word list (`PER_INSTANCE_COMMANDS` in `src/options.sh`):
    `start`/`enter`/`attach`/`fix-ssh`/`build`/`user-exec`/`root-exec`/
    `detail`/`stop`/`delete`/`clean`/`up`; any other word is forwarded to
    `docker compose <word>`.

Keeping each concern in its own phase is what makes the otherwise large script
tractable: you can reason about each phase without tracing control flow across
the file.

## Key design decisions

### Per-variant image tagging

Each combination of build-affecting flags (`--no-chromium`, `--no-docker`)
produces a distinct image tagged `ai-sandbox:<variant>` (derived in
`utils.sh:variant_key`). Switching flags selects a different tag rather than
invalidating the previously built image. `is_build_stale` compares the image's
`docker image inspect .Created` timestamp against the newest file under
`docker/` — no marker file to get out of sync.

Trade-off: more disk usage vs. cheap mode switching. Since variants are small
in number (chromium × docker = 4 possible), it's worth it.

### Plugin mount generation

The container inherits the host's `~/.claude` directory, so plugins installed
on the host are already "installed" inside the VM. The open question is where
each plugin keeps its *state* and whether that path is mounted.

Three layers, in order:

1. `~/.config` is mounted wholesale — covers any plugin that follows XDG.
2. For each entry in `~/.claude/plugins/installed_plugins.json`, if a
   matching `~/.<plugin-name>` exists, it's auto-mounted at the same path
   inside the container. This catches conventions like `~/.claude-mem`.
3. Escape hatch: `~/.config/ai-sandbox/volume-maps` lets the user declare
   arbitrary mounts (`$HOME`/env vars expanded by the launcher).

The generator emits a `docker-compose.generated.yaml` overlay each run — no
baked-in plugin list.

### Concurrency invariant (why plugin detection is strict about matching)

Plugins with persistent workers — most visibly `claude-mem`, which keeps a
SQLite database in `~/.claude-mem` — corrupt their own state if both the host
and the container have live writers. The preflight in
`plugin-conflicts.sh:check_host_plugin_conflicts` refuses to start the
container when it detects host-side `claude` or plugin-worker processes.

Matching precision matters. Earlier versions used loose substring matching and
flagged unrelated processes — most memorably `CURSOR_WORKSPACE_LABEL=
github-toolkit` being flagged as a `github` plugin worker. The current form
requires plugin names to appear as path components or standalone argv tokens
(`(^|/)(name)( |$|/)`), which removed every false positive observed in
testing.

Only one direction is currently enforced: host claude already running blocks
the container from starting. The reverse (launching host `claude` while the
container is live) is on the user. The lockfile-based symmetric enforcement
is planned — see `next-steps.md`.

### Docker access: proxy, not socket or DinD

Agents sometimes need Docker from inside the sandbox. Mounting `docker.sock`
would give the container root on the host (trivially escapable via
`docker run --privileged`). Docker-in-Docker is heavy and fragile.

Instead, `--docker` attaches a `tecnativa/docker-socket-proxy` sidecar on a
private Compose network and points the sandbox at
`DOCKER_HOST=tcp://docker-socket-proxy:2375`. The proxy exposes a whitelisted
subset of the Docker API. `docker/docker-compose.proxy.yaml` is the source of
truth for which endpoints are enabled.

This is framed in `README.md` as a mitigation, not a security boundary — with
`CONTAINERS=1` + `POST=1` a hostile workload inside can still escape via e.g.
`docker run -v /:/host`. Enable only when the workload is trusted.

Since the full-config-restore work, this escape has a durability consequence
worth calling out: Docker labels are fixed at container-create time, so a
workload that escapes this way has enough host Docker access to recreate the
container with a poisoned `ai.sandbox.config` label — and that label is now
durable, restored on every subsequent per-instance command via
`restore_saved_config` (see [Config persistence and restore](#config-persistence-and-restore)
below). What was previously a one-shot compromise becomes self-perpetuating
across future, otherwise-clean sessions. This is particularly relevant in the
default `mirror` mode, where `~/.claude` is bind-mounted read-write from the
host.

The persisted `ai.sandbox.docker-proxy` label has a second, independent
durability mechanism beyond config-label restore: `is_docker_proxy_label_true`
(`src/utils.sh`) reads that label directly and, when this invocation's own
profile resolution would otherwise compute `EFFECTIVE_PROXY=false` (e.g. a
docker-capability-granting profile has since become unresolvable, or a
directly-passed `--profile` no longer declares the capability), forces
`EFFECTIVE_PROXY` back to `true` — independent of whether `restore_saved_config`
itself ran or what it restored. This fallback is deliberately scoped by
`should_force_proxy_label_fallback` (`src/utils.sh`), gated on `CMD` and, for
four of those CMDs, on `CONFIG_FLAGS_PROVIDED`:

- `stop`, `delete`, `clean` — applied unconditionally. These commands tear
  down or pause whatever composition *actually exists*; there is no
  legitimate "explicit invocation" story for e.g. `delete` to act on a
  different composition than what was actually created, so the persisted
  label always wins.
- `fix-ssh`, `start`, `enter`, `up` — applied only when this invocation's
  `CONFIG_FLAGS_PROVIDED != "true"` (a bare restore/resume, not a
  composition change this run itself explicitly requested). When this
  invocation *does* pass an explicit composition-changing flag (e.g. `start
  --profile no-docker`), the fallback is skipped so the explicit choice —
  including deliberately dropping the `docker` capability — actually takes
  effect, per the "explicit invocation always wins" invariant described in
  the Matches part of [Config persistence and restore](#config-persistence-and-restore)
  below.
- Every other CMD (`create`, `detail`, `build`, `user-exec`, `root-exec`,
  `attach`) is outside the fallback's scope entirely — `create` has no prior
  container/label to consult, `detail` never consumes `EFFECTIVE_PROXY`, and
  the rest never touch composition.

See [Config persistence and restore](#config-persistence-and-restore) below
for the full label/restore contract.

### `~/.config` is copy-on-write by default

Writes under `~/.config` from inside the container are kept **container-local
by default** so a rogue or exploratory plugin run can't mutate your host's
configuration. The mechanism is overlayfs, not a copy-on-start snapshot:

- `docker/docker-compose.isolate-config.yaml` bind-mounts host `~/.config`
  read-only at `/mnt/ai-sandbox/host-config` and mounts a tmpfs at
  `/run/ai-sandbox/config-overlay` (one tmpfs hosting both `upper/` and
  `work/`, since overlayfs requires them on the same filesystem).
- `docker/rootfs/etc/cont-init.d/02-overlay-config` (s6 cont-init stage)
  calls `mount -t overlay` to stack the tmpfs over the read-only lower at
  `${HOST_HOME}/.config`.
- The service is granted `CAP_SYS_ADMIN` and `apparmor=unconfined` so the
  cont-init mount actually succeeds. Default Docker seccomp allows `mount()`
  once `CAP_SYS_ADMIN` is present, so we don't need `seccomp=unconfined`.

Passing `--no-isolate-config` swaps in `docker-compose.shared-config.yaml`,
which restores the original read-write passthrough. The two overlay files
are mutually exclusive — the launcher includes exactly one of them in the
assembled `-f` list so `docker compose config` shows a single, correct mount
for `${HOST_HOME}/.config` regardless of mode.

Trade-off: isolation breaks round-tripping of state written under `~/.config`
back to the host. Plugins that keep state there (tokens, SQLite, settings
the user expects to see both inside and outside the sandbox) need
`--no-isolate-config`. Plugins under `~/.<plugin-name>` (claude-mem et al.)
aren't affected since they're mounted separately by `volume-override.sh`.

The cap-set cost is real: `CAP_SYS_ADMIN` is broad. For this project it's
acceptable because the outbound-network firewall is the primary boundary,
not the capability set — a compromised agent can already run arbitrary code
inside the container. If that reasoning doesn't hold for a specific
workload, `--no-isolate-config` drops both the cap and the AppArmor opt-out.

#### `sandbox-volumes`: inspecting and syncing overlay state

Overlay isolation creates a need for tooling that makes drift visible and
lets the user selectively push container changes back to the host. That
tooling lives in the image at `/usr/local/bin/sandbox-volumes`
(`docker/rootfs/usr/local/bin/sandbox-volumes`). It reads a registry at
`/etc/ai-sandbox/overlay-volumes.conf` emitted by the `02-overlay-config`
cont-init and drives `diff` and `rsync` against the three paths each
overlay owns:

- **container view** — `${HOME}/.config`, the overlay mount point.
- **host RO mirror** — `/mnt/ai-sandbox/host-config`, the bind used as the
  overlay's lower layer. User-readable; the tool compares against it for
  `status` and `diff`.
- **host RW bind** — `/var/lib/ai-sandbox-rw/config`. Parent dir is 0700
  root, so non-root processes can't even `cd` into it; `sync
  --match-container` reaches it through `sudo rsync`. Passwordless sudo is
  already granted in the image, so the UX stays smooth without creating a
  second trust surface.

The registry is tab-separated on purpose: adding a second overlay later
(e.g. `~/.ssh`, `~/.aws`) is a matter of appending a row in the cont-init
and adding the matching mounts in the isolate-config compose file —
`sandbox-volumes` itself doesn't need changes.

Bidirectional "smart" sync is deliberately out of scope: without a baseline
snapshot at container start, "file missing on side X" is ambiguous
("deleted from X" vs "never on X"). The tool requires an explicit direction
(`--match-host` or `--match-container`) and an explicit `--delete` opt-in,
which matches what users actually want (restore from host, or promote from
container) without the correctness pitfalls of three-way merging.

### SSH agent forwarding is decoupled from the host path

The container needs the host's `ssh-agent` — without it, `git push` over SSH
fails inside the VM. The naïve approach (`- ${SSH_AUTH_SOCK}:${SSH_AUTH_SOCK}`
plus `ENV SSH_AUTH_SOCK=${SSH_AUTH_SOCK}` baked into the image) breaks any
time the host's `SSH_AUTH_SOCK` changes — logout/login, reboot, a fresh
`eval $(ssh-agent)`, a Docker Desktop update. macOS's launchd socket path
(`/private/tmp/com.apple.launchd.*/Listeners`) rotates whenever that happens.

The current design:

- The container always uses a **stable in-container path**,
  `/run/ai-sandbox/ssh-auth.sock`, baked into the image as `ENV SSH_AUTH_SOCK`.
- `docker/docker-compose.yaml` bind-mounts the host's current socket to that
  target, and records the host path in the
  `ai.sandbox.ssh-auth-sock-host` container label.
- On `start` / `enter` / `attach`, `warn_if_ssh_mount_stale`
  (`src/utils.sh`) compares the label to the current host `SSH_AUTH_SOCK`.
  When they disagree, the mount is stale and SSH inside the container will
  fail; the user sees a warning pointing at `ai-sandbox fix-ssh`.
- `ai-sandbox fix-ssh` re-creates only the `ai-sandbox` service with the
  current host path mounted. We deliberately *don't* auto-recreate — doing
  so would kill in-flight Claude sessions or long-running processes without
  consent.
- `docker/rootfs/etc/cont-init.d/01-setup-ssh` is best-effort: it warns on
  failure rather than `exit 1`, since the launchd socket chown often fails
  with EPERM while the mount is already user-accessible.

Troubleshooting pointer: `ai-sandbox user-exec zsh -c 'ssh-add -l'` inside
the container should list host keys; a real end-to-end check is `ssh -T
git@github.com` looking for `successfully authenticated`.

### Config persistence and restore

`docker/docker-compose.yaml` writes a single canonical label,
`ai.sandbox.config`, capturing every config-changing CLI input as
base64-encoded JSON: `profiles`, `mode`, `no_isolate_config`, `clean_slate`,
`marketplaces`, `plugins`, `enable_all_plugins`, plus a `version` field
(currently always `1`, present for future extensibility — no code branches on
it today). `src/index.sh` assembles this JSON after the CLI-merge phase (once
`PROFILES`/`MODE_OVERRIDE`/`NO_ISOLATE_CONFIG`/`CLEAN_SLATE`/
`CLI_MARKETPLACES`/`CLI_PLUGINS`/`CLI_ENABLE_ALL` are all final) and exports
it as `AI_SANDBOX_CONFIG_B64`, mirroring the `AI_SANDBOX_CREDENTIALS_JSON_B64`
pattern already used for clean-slate credentials (`src/credentials.sh`).
Marketplaces and plugins are persisted as the **CLI deltas**
(`CLI_MARKETPLACES`/`CLI_PLUGINS`), not the profile-merged effective set —
the profile-contributed entries are reproduced for free by re-running
`profile-installer.js` on restore, so only the CLI additions need to
round-trip through the label.

**Input vs. derived.** The launcher re-derives the entire effective
configuration from these inputs on every invocation — `profile-installer.js`
composition, the CLI merge, `EFFECTIVE_MODE`/`EFFECTIVE_PROXY`/
`AI_SANDBOX_IMAGE_TAG` (see [Profile system](#profile-system)) — so only the
raw *inputs* need to survive between invocations; everything else is safe to
recompute fresh every time and is never trusted across invocations.

**Restore (`restore_saved_config`, `src/utils.sh`).** Runs for every
per-instance `CMD` except `create` — broadened from the original bare-
`start`/`enter`-only trigger, since every other per-instance command (`stop`,
`delete`, `clean`, `fix-ssh`, `build`, `user-exec`, `root-exec`, `attach`,
`detail`, `up`, and the docker-compose passthrough) also acts on an
already-created instance and needs its compose-file assembly to reflect that
instance's actual persisted composition, not just whatever `--profile` flags
(usually none) this particular invocation passed. `create` is the sole
exception: it provisions fresh state and rejects name collisions in
`do_create` before a restored value would ever be consulted.
`should_restore_config` (`src/utils.sh`) is the extracted, unit-tested
predicate that decides this; `src/index.sh`'s call site reduces to `if
should_restore_config "${CMD}"; then restore_saved_config; fi`. The trigger's
own guard is unchanged from before the broadening: no config-changing flags
passed this invocation (the existing `CONFIG_FLAGS_PROVIDED != true` gate)
and a container (running or stopped) already exists for `SANDBOX_NAME`.

When triggered, this reads only the `ai.sandbox.config` label, base64-decodes
and extracts each field via `jq`, and rehydrates all seven input globals.
Each field is only assigned when present, so a missing or empty label is a
natural no-op. **There is no fallback of any kind** — a container with no
`ai.sandbox.config` label (including any container created before this label
existed) simply keeps today's un-configured default behavior (mirror mode, no
clean-slate, no profiles) for any command that would otherwise restore it.
This is a deliberate product decision (no external users of this tool yet; a
single label-based config regime is preferred over supporting a legacy
fallback in parallel), not a gap to be closed later. Restored marketplace
entries are re-validated against the `https://`/`file://` scheme constraint
before being trusted — a persisted label is not the same trust boundary as
freshly-typed `--add-marketplace` input — dropping (with a warning) any entry
that doesn't match rather than restoring it verbatim.

**Matches (`running_config_matches`, `src/utils.sh`).** Compares the running
container's labels against the current invocation's freshly-resolved
effective values across the full derived-config dimension set: image tag,
`ai.sandbox.profile-hash`, `ai.sandbox.mode`, `ai.sandbox.no-isolate-config`,
`ai.sandbox.docker-proxy`, `ai.sandbox.clean-slate`, and three additional
derived labels — `ai.sandbox.marketplaces`, `ai.sandbox.plugins`,
`ai.sandbox.enable-all-plugins` — populated from the effective
`AI_SANDBOX_MARKETPLACES`/`AI_SANDBOX_PLUGINS`/`AI_SANDBOX_ENABLE_ALL_PLUGINS`
env vars (the same values the container's `10-plugin-setup` init consumes).
An explicit invocation that changes any of these (e.g. `enter
--add-marketplace NEW` on a container created without it) is now correctly
detected as a config change and triggers the stop-and-recreate prompt instead
of silently never applying. This is the "explicit invocation always wins"
invariant: whatever this invocation itself explicitly asked for takes effect,
even over what's already persisted. The `EFFECTIVE_PROXY` label fallback
described under [Docker access: proxy, not socket or DinD](#docker-access-proxy-not-socket-or-dind)
above is a worked example of the same invariant applied in the opposite
direction — it deliberately stops short of overriding an explicit
`--profile`/`--mode`/etc. flag on `fix-ssh`/`start`/`enter`/`up`
(`CONFIG_FLAGS_PROVIDED == "true"`), so that an invocation which explicitly
changes composition, including dropping the `docker` capability, is never
silently reverted by the persisted `ai.sandbox.docker-proxy` label.

**Why restore and matches don't read the same labels.** They operate at
different pipeline stages, not out of inconsistency: restore runs *before*
`profile-installer.js` re-resolves anything, so it must seed the raw input
globals; matches runs *after* resolution, comparing the freshly re-derived
effective values against what's already baked into the running container.
The reconciliation that matters is that both sides now cover the complete
dimension set — restore reconstructs every input, so after a restore (any
per-instance `CMD` except `create` that triggers it, not just `start`/`enter`)
`running_config_matches` returns true by construction and never
false-prompts; matches compares every derived dimension an explicit
invocation could change, so a real config change is never silently dropped.
Future maintainers should not try to "unify" the two into reading one literal
label set — their differing pipeline stages make that impossible by design.

**Why base64.** Plain JSON in a label works technically (Compose interpolates
already-parsed YAML scalars), but a literal `$` in a value — a marketplace
URL — would be read as a Compose interpolation token, and `docker inspect`
Go-template quoting is fragile around embedded quotes. Base64 sidesteps both:
the label value is inert `[A-Za-z0-9+/=]`, safe from Compose and YAML alike.
The cost — opacity via a raw `docker inspect` — is mitigated by the retained
plain labels (`ai.sandbox.profiles`, `ai.sandbox.mode`, etc., used by `ls`
and by `matches`) and by `ai-sandbox detail`'s decoded
`Configuration:` display (see
[Status as both human and machine interface](#status-as-both-human-and-machine-interface)
below).

### Status as both human and machine interface

`ai-sandbox detail` has three modes driven by flags, all fed by a
single gather pass (`src/status.sh`):

- default → human-readable text
- `--json` → `jq`-constructed JSON
- `--test-check` → silent, exits 0 if the preflight would pass, 1 otherwise

The `--test-check` mode is specifically designed as a gate for test harnesses
(`make test.integration` calls it before running ShellSpec), so it stays
silent and honors `AI_SANDBOX_SKIP_PLUGIN_CHECK` / `--force`.

Since the full-config-restore work, both the default and `--json` modes also
decode and surface the persisted `ai.sandbox.config` label (when present) as a
fourth data source alongside container state, image list, and blocking-process
conflicts: a human-readable `Configuration:` section (rendered as YAML via the
Python `yq` wrapper, falling back to `jq .` when `yq` is unavailable or the
wrong variant) and a `config` JSON key in `--json` output. See
[Config persistence and restore](#config-persistence-and-restore) above for
what that label contains and how it is produced.

### Profile system

The profiles system replaces the former ad-hoc build flags (`--docker`, `--no-docker`, `--no-chromium`) with composable YAML files. The full schema, composition rules, and `profile-installer.js` interface are specified in [`docs/ai-sandbox-profiles-spec.md`](ai-sandbox-profiles-spec.md). This section covers the architectural decisions.

**What a profile is.** A profile is a YAML file that fully describes an ai-sandbox environment: apt packages, Claude Code plugins, skill/hook/agent files to copy in, network allow-list additions, and the container identity mode (`mirror` vs. `static`). Profiles are composable — `ai-sandbox start --profile base --profile docker` merges both before building or starting.

**Composition model.** Profiles are merged left to right in declaration order. List fields (`packages`, `plugins`, `capabilities`, `skills`, `hooks`, `agents`, `network.allow`) are unioned; scalar fields (`mode`, `setup_script`) error on conflict if two composed profiles set the same field to different values. Error-on-conflict rather than last-wins makes surprises explicit: a user composing `mirror` and `static` gets a clear error naming both profiles and the field, instead of a silently wrong container. Conflicts can always be resolved with a `--mode` override at invocation time.

**Storage and discovery.** `profile-installer.js` searches three locations in priority order: `./profiles/<name>.yaml` (project-local), `$XDG_CONFIG_HOME/ai-sandbox/profiles/<name>.yaml` (user global, defaulting to `~/.config/ai-sandbox/profiles/`), and bundled profiles shipped with ai-sandbox. `~/.config/ai-sandbox/config.yaml` holds a `default_profiles` list — when present, `ai-sandbox start` with no `--profile` flags behaves as if those profiles were passed, eliminating repetition for per-project or per-user defaults.

**The Node boundary.** `bin/profile-installer.js` sits between the YAML world and bash. It handles YAML parsing, profile discovery, composition, path resolution, `required_env` validation, and the composition-hash computation. It outputs three blocks to stdout: a shell-sourceable `KEY=VALUE` block (consumed via `eval`), newline-delimited `src\tdst` path pairs for file-copy operations, and a JSON blob for structured data consumed via `jq`. The boundary is Node because YAML parsing and structured merge logic are brittle in bash, and because the output formats are designed for easy consumption by a bash caller without a full-stack Node dependency on the hot path. The script runs on the host (not inside the container) and exits nonzero on any error, which halts the bash launcher cleanly.

**Image tagging by composition hash.** Profile-based images are tagged `ai-sandbox:profile-<hash>`, where `<hash>` is derived from the ordered, resolved list of composed profile names. The hash is stable — the same profile composition always produces the same tag. `is_build_stale` checks the `docker/` directory mtime (existing behavior) plus the mtime of each resolved profile YAML and each `src` file referenced by `skills`, `hooks`, `agents`, and `setup_script` in the merged profile. This extends the existing no-marker-file freshness check to cover profile content without adding new state files. Trade-off: disk usage scales with unique compositions, but the hash-based scheme avoids the combinatorial tag explosion that a flag-name scheme would produce for arbitrary profile combinations.

**Standard profiles and the Dockerfile.** The base Dockerfile becomes thinner: it carries the OS, core utilities, and the ai-sandbox toolchain, but not the language runtimes. The `base` standard profile carries Go, Node.js via nvm, Bun, and the developer tools previously baked into the Dockerfile. This separates "what the image needs to run" from "what an agent needs to work" — a team that doesn't use Go can compose a leaner image by omitting `base` and providing their own profile, without patching the Dockerfile.

**Capabilities and Dockerfile decomposition.** The former ARG/variant build approach (a single Dockerfile with conditional blocks keyed to `--no-chromium` / `--no-docker` flags) is replaced by a fragment-assembly model. The image is built from a `docker/capabilities/base.dockerfile` plus one fragment per declared capability (`docker/capabilities/docker.dockerfile`, `docker/capabilities/chromium.dockerfile`, etc.). `profile-installer.js` assembles these fragments into the effective Dockerfile for each build. The resolved `capabilities` list feeds into the composition hash, so different capability sets produce different image tags — the same guarantee as the old variant-key scheme, but without the hardcoded combinatorial enumeration. New capabilities can be introduced by adding a Dockerfile fragment and a capability name; no schema changes are required.

**Local vs. shareable profiles.** A profile is auto-flagged `local: true` by `profile-installer` when any `src` path in its `skills`, `hooks`, or `agents` blocks resolves outside the profile file's own directory and outside `$XDG_CONFIG_HOME/ai-sandbox/`. The flag is a signal, not a hard restriction — the profile still works, but the warning makes it explicit that the profile may not resolve on another machine. Enterprise setups with stable shared filesystem layouts are a valid use case for local profiles in source control.

## Test strategy

ShellSpec with two tiers:

- `test/unit/` — loads `bin/ai-sandbox.sh` with `__SOURCED__=1` and exercises
  individual functions. Fast, no Docker needed.
- `test/integration/` — gated by `detail --test-check`; drives real
  `docker compose` and pokes at the live container via `container_exec`
  (defined in `test/spec_helper.sh`).

Tags (`integration` marker, filter with `--tag integration` or `--tag
'!integration'`) separate the tiers inside ShellSpec itself.

## See also

- [`README.md`](../README.md) — user-facing CLI reference, plugin support,
  Docker access caveats.
- [`next-steps.md`](next-steps.md) — deferred features and known gaps.
- [`docker/docker-compose.proxy.yaml`](../docker/docker-compose.proxy.yaml) —
  the authoritative proxy whitelist.
