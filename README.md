# ai-sandbox

`ai-sandbox` is a macOS-first CLI that runs Claude Code (and other agents) inside an isolated Ubuntu container. It mirrors your host identity — SSH keys, git config, `~/.claude`, `~/.config` — into the container and enforces an iptables allow-list that restricts outbound traffic to GitHub and Anthropic APIs by default.

**Limitations:** This project is still in early stages and has not been tested against a wide range of plugins and MCPs. See [current limitations and goals](#current-limitations-and-goals) for details.

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- macOS (Linux untested, but planned)
- An active [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installation on the host

Optional:
- [XQuartz](https://www.xquartz.org/) for GUI app support (Chromium)
- [claude-mem](https://github.com/anthropics/claude-code/tree/main/packages/claude-mem) plugin for persistent memory

## Install

```bash
npm install -g ai-sandbox
```

## Quick start

```bash
# Enter the sandbox (builds image if needed, starts container, connects)
ai-sandbox

# Pass any docker compose command through
ai-sandbox down
ai-sandbox logs -f
```

## CLI reference

| Command | Description |
|---------|-------------|
| *(no args)* | Build if needed, start if stopped, then connect |
| `build` | Build the Docker image |
| `start` | Start the container and open a shell |
| `attach` / `connect` | Connect to an already-running container |
| `new-profile` | Scaffold a new profile YAML file by auto-discovering skills, hooks, and agents |
| `fix-ssh` | Recreate the container with the host's current `SSH_AUTH_SOCK` bind-mounted. Run this after a host logout / ssh-agent restart if `git push` inside the container fails — see [SSH agent forwarding](#ssh-agent-forwarding). |
| `<any>` | Passed through to `docker compose` |

The image is rebuilt automatically when any file under `docker/` (Dockerfile, compose configs, entrypoint scripts, etc.) or any active profile YAML is newer than the image's build timestamp — you do not need to run `ai-sandbox build` or delete the image manually after pulling changes.

### Flags

| Flag | Description |
|------|-------------|
| `--profile <name>` | Activate a named profile (repeatable; profiles are merged left to right). See [Profiles](#profiles). |
| `--mode <mirror\|static>` | Override the container identity mode for this run only, without changing the profile file. |
| `--force` | Bypass the host plugin-conflict pre-flight check (same as `AI_SANDBOX_SKIP_PLUGIN_CHECK=1`) |
| `--no-isolate-config` | Share `~/.config` read-write with the host (opt out of the default copy-on-write overlay). See [Config isolation](#config-isolation). |

## Profiles

A **profile** is a YAML file that describes a reproducible ai-sandbox environment — packages to install, plugins to enable, skills/hooks/agents to copy in, network allow-list additions, and an optional `capabilities` list that selects named feature layers (e.g. `[docker, chromium]`). Profiles replace the former ad-hoc `--docker`, `--no-docker`, and `--no-chromium` flags with reusable, composable configuration files.

```bash
# Use the base runtime profile with Docker access
ai-sandbox start --profile base --profile docker

# Override the identity mode for one run
ai-sandbox start --profile base --mode static
```

Multiple `--profile` flags are merged left to right. Scalar conflicts (e.g. two profiles both setting `mode` to different values) are an error — resolve them by using only one, or override with `--mode`. You can set a `default_profiles` list in `~/.config/ai-sandbox/config.yaml` so you don't need to pass `--profile` on every invocation.

See [`docs/ai-sandbox-profiles-spec.md`](docs/ai-sandbox-profiles-spec.md) for the full schema, composition rules, storage and discovery order, and the `profile-installer.js` interface.

## What's inside

The `base` standard profile (and the default pre-profile image) includes:

- **Languages**: Go, Node.js (via nvm), Bun
- **Shell**: Zsh with Oh My Zsh
- **Tools**: git, git-delta, jq, curl, build-essential
- **Init system**: s6-overlay for process supervision
- **Firewall**: iptables rules restricting outbound to GitHub + Anthropic
- **Optional**: Chromium browser with X11 forwarding (via `--profile chromium`)

## Plugin support

The sandbox shares your host `~/.claude` directory, so every plugin you've
installed on the host is already visible inside the VM and will self-install
its hooks when `claude` runs there. The remaining question for each plugin is
where its state/config lives on disk and whether that location is mounted.

### Auto-detected locations

These are mounted into the container with no configuration needed:

- `~/.config/<anything>` — covered by the `~/.config` mount. Picks up any
  plugin that follows the XDG Base Directory layout.
- `~/.<plugin-name>` — for each plugin listed in
  `~/.claude/plugins/installed_plugins.json`, if a matching dot-dir exists
  in your home directory it is mounted at the same path in the container.
  This covers `claude-mem` (`~/.claude-mem`) and similarly-conventioned plugins.

### Declaring additional mounts

Plugins that store state outside both of the above locations (e.g. under
`~/.local/share/<name>`, `~/.cache/<name>`, or somewhere bespoke) must be
declared in `~/.config/ai-sandbox/volume-maps`. Format:

```
# One mount per line. Lines starting with '#' and blank lines are ignored.
# Absolute path -> identity mount (same path on host and container).
$HOME/.local/share/weird-plugin

# src:dst form for non-identity mappings.
$HOME/.custom-state:/opt/custom-state
```

`$HOME` and other environment variables in the file are expanded by the
pre-flight script.

### Config isolation

By default, `~/.config` is mounted **copy-on-write**: the container sees the
host's current config as a read-only lower layer, and any writes inside the
container land on a tmpfs upper layer that's discarded with the container.
Host `~/.config` is never modified by the sandbox. Mechanics:

- Host `~/.config` → bind-mounted read-only at `/mnt/ai-sandbox/host-config`.
- A tmpfs at `/run/ai-sandbox/config-overlay` holds the `upper/` and `work/` dirs.
- `docker/rootfs/etc/cont-init.d/02-overlay-config` mounts an overlayfs at
  `${HOME}/.config` inside the container during s6 startup.
- Reads pass through to the host for files the container hasn't touched, so
  host edits during a session are still visible for untouched files.

To opt out and restore the old shared-passthrough behavior (e.g. when a
plugin writes state under `~/.config` that you want back on the host):

```sh
ai-sandbox --no-isolate-config
```

Note that plugins following the `~/.<plugin-name>` convention (like
`claude-mem` at `~/.claude-mem`) are auto-mounted separately and are
**unaffected** by this flag. Isolation only covers `~/.config`.

#### Inspecting and syncing overlay volumes: `sandbox-volumes`

The container ships a helper at `/usr/local/bin/sandbox-volumes` that
inspects copy-on-write overlays and — when you want — pushes changes back
to the host. Run it inside the sandbox:

```sh
sandbox-volumes list                              # registered overlays
sandbox-volumes status                            # drift for all overlays
sandbox-volumes status ~/.config/gh               # drift for one subpath
sandbox-volumes diff ~/.config/gh                 # unified diff, container vs host
sandbox-volumes diff ~/.config -- --brief        # diff args after '--'

# Copy host → container (resets container-side changes in the overlay upper)
sandbox-volumes sync --match-host ~/.config/gh
sandbox-volumes sync --match-host --delete --dry-run ~/.config/gh

# Copy container → host (uses passwordless sudo to reach the root-only RW mount)
sandbox-volumes sync --match-container ~/.config/gh
sandbox-volumes sync --match-container --delete --dry-run ~/.config/gh
```

There is no default bidirectional sync — you always pick a direction.
`--delete` is opt-in: without it, `sync` only copies files and doesn't
remove anything on the destination.

All paths can be a subpath within an overlay (not just the mount root), so
you can scope operations tightly. Invalid paths (not under any registered
volume) are rejected with a clear error.

From the host you can reach the same tool through the launcher:

```sh
ai-sandbox user-exec sandbox-volumes status
ai-sandbox user-exec sandbox-volumes diff \$HOME/.config
```

Under the hood: the host's `~/.config` is also bind-mounted read-write at
`/var/lib/ai-sandbox-rw/config` inside the container. The parent dir is
chmod 0700 root so non-root processes can't traverse into the writable
view; `sandbox-volumes sync --match-container` uses `sudo rsync` to write
there. Passwordless sudo is already granted in the image, so the UX is
smooth without weakening accident-protection: you can't hurt the host by
accident, only by asking the tool to do it.

Requirements: the container is granted `CAP_SYS_ADMIN` and
`apparmor=unconfined` while in isolate-config mode so it can call `mount()`.
`CAP_SYS_ADMIN` is a real privilege grant — in this project's threat model
the firewall is the primary boundary and the cap set is intentionally
permissive, but if that trade-off doesn't fit your use case, `--no-isolate-config`
drops both.

### Concurrency invariant

**Do not run `claude` or any claude plugin on the host while the ai-sandbox
container is running, or vice versa.** Plugins with persistent workers (most
notably `claude-mem`, which writes to a shared SQLite database in
`~/.claude-mem`) can corrupt their own state if host and container both run
instances concurrently.

The pre-flight refuses to start the container when it detects host-side
`claude` or plugin-worker processes. MCP workers can outlive the `claude`
process that started them, so if you recently exited claude on the host and
the pre-flight still complains, kill the worker PID it reports. Use `--force`
or `AI_SANDBOX_SKIP_PLUGIN_CHECK=1` to bypass after confirming the match is
a false positive.

The inverse direction (launching host `claude` while the container is
running) is not currently enforced — rely on user discipline. See
[`docs/next-steps.md`](docs/next-steps.md) for the planned lockfile-based
symmetric enforcement.

## SSH agent forwarding

The container reuses the host's `ssh-agent` so `git push`, `ssh`, and any
tooling that needs your keys works inside the sandbox the same way it does on
the host. The host's current `SSH_AUTH_SOCK` is bind-mounted to a stable
in-container path, `/run/ai-sandbox/ssh-auth.sock`.

### When `git push` suddenly stops working

The most common cause is that the host's ssh-agent socket path changed since
the container was created — a logout/login, a reboot, a fresh
`eval $(ssh-agent)`, or a Docker Desktop restart will all produce a new
launchd socket path, leaving the running container with a stale mount.

On `start` / `enter` / `attach`, ai-sandbox compares the current host path
to the one recorded on the container (as the `ai.sandbox.ssh-auth-sock-host`
label) and warns when they disagree. The repair is:

```sh
ai-sandbox fix-ssh
```

This recreates the container (only the `ai-sandbox` service) with the
current `SSH_AUTH_SOCK` mounted. It is deliberately *not* automatic —
recreating tears down anything running inside, including attached shells
and long-running Claude sessions, so you get to decide when that's safe.

### Troubleshooting

From inside the container (`ai-sandbox user-exec zsh`):

```sh
echo $SSH_AUTH_SOCK          # should print /run/ai-sandbox/ssh-auth.sock
ssh-add -l                   # should list your host keys
ssh -T git@github.com        # should reply "Hi <user>! You've successfully authenticated"
```

If `ssh-add -l` reports "Could not open a connection to your authentication
agent", the mount is stale — run `ai-sandbox fix-ssh`. If it fails from the
host too, start an agent there first (`eval $(ssh-agent) && ssh-add`).

## Docker access

Some agents need to pull images, build, or run throwaway containers from
inside the sandbox. Docker access is enabled by setting `capabilities: [docker]`
in a profile (the bundled `docker` profile does this). Direct `docker.sock`
mounting would give the container root on the host (trivially escapable via
`docker run --privileged`), and Docker-in-Docker is heavy. Instead, the `docker`
capability starts a [`tecnativa/docker-socket-proxy`](https://github.com/Tecnativa/docker-socket-proxy)
sidecar on a private Compose network that exposes a **whitelisted** subset
of the host Docker API over TCP. The sandbox reaches it at
`DOCKER_HOST=tcp://docker-socket-proxy:2375`, which the standard `docker`
CLI picks up automatically — no other configuration required.

```sh
ai-sandbox start --profile base --profile docker
# inside the container:
docker pull hello-world
docker run --rm hello-world
docker search nginx
```

Enabled endpoints: `images`, `containers`, `build`, `networks`, `volumes`,
`exec`, `info`, `ping`, `version` (plus `POST` so writes/builds work).
Explicitly **denied**: swarm, nodes, services, secrets, configs, plugins,
system. See [`docker/docker-compose.proxy.yaml`](docker/docker-compose.proxy.yaml).

**Image search** goes through the daemon (`docker search …`), but nothing
stops the agent from hitting Docker Hub directly if that's more ergonomic:

```sh
curl -s 'https://hub.docker.com/v2/search/repositories/?query=nginx&page_size=3' | jq
```

### Security caveat

The proxy is a **mitigation, not a security boundary**. With `CONTAINERS=1`
and `POST=1` a hostile workload inside the sandbox can still escape via e.g.
`docker run -v /:/host alpine chroot /host ...`. Enable the `docker` capability
(`capabilities: [docker]` in a profile, or `--profile docker`) only when you
actually need Docker access and trust the workload.

## Current limitations and goals

- *OS support*: `ai-sandbox` is currently developed and tested on macOS. It may work on Linux, but this is untested. Full support for both Linux and Windows is planned.
- *Plugin binaries*: architecture-specific plugin binaries (e.g. Mach-O on
  macOS host, ELF on Linux in the container) are not handled. Most plugins
  drive behavior through scripts under `~/.claude/plugins/cache/...` which
  work on both sides, but a plugin shipping a native compiled hook would
  need explicit Linux-side handling.
- *Symmetric mutual exclusion*: see the concurrency invariant note above.
- *Profiles*: the profiles feature is specified but not yet implemented. The `--profile`, `--mode`, and `new-profile` surface described above reflects the planned interface.

## Further reading

- [`docs/architecture.md`](docs/architecture.md) — how the CLI is structured,
  the phased command flow, and the design decisions behind per-variant image
  tagging, plugin mount generation, mutual exclusion, and the Docker proxy.
- [`docs/ai-sandbox-profiles-spec.md`](docs/ai-sandbox-profiles-spec.md) — full profiles specification: YAML schema, composition rules, storage and discovery, `profile-installer.js` interface, and the `new-profile` command.
- [`docs/next-steps.md`](docs/next-steps.md) — deferred features and known
  gaps (symmetric mutual exclusion, MCP service manager, plugin-binary
  architecture mismatch).

## License

[Apache-2.0](LICENSE)
