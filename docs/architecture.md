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
2. **Short-circuits** — `help` and `kill-local-ai` run without touching Docker
   or the rest of the pipeline.
3. **Docker preflight** — `check_docker` pokes `docker info`; on failure it
   tries `docker desktop start` once before giving up. `status` is exempt so it
   can describe a down daemon instead of fighting it.
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
11. **Dispatch** — `start`/`enter`/`attach`/`build`/`user-exec`/`root-exec`/
    `status`/`stop`/`clean`; any other word is forwarded to
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

### Status as both human and machine interface

`ai-sandbox status` has three modes driven by flags, all fed by a single
gather pass (`src/status.sh`):

- default → human-readable text
- `--json` → `jq`-constructed JSON
- `--test-check` → silent, exits 0 if the preflight would pass, 1 otherwise

The `--test-check` mode is specifically designed as a gate for test harnesses
(`make test.integration` calls it before running ShellSpec), so it stays
silent and honors `AI_SANDBOX_SKIP_PLUGIN_CHECK` / `--force`.

## Test strategy

ShellSpec with two tiers:

- `test/unit/` — loads `bin/ai-sandbox.sh` with `__SOURCED__=1` and exercises
  individual functions. Fast, no Docker needed.
- `test/integration/` — gated by `status --test-check`; drives real
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
