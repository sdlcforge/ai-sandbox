# ai-sandbox

A CLI app enabling (more) safe unsupervised Claude Code development by replicating your local setup in an isolated Docker container.

`ai-sandbox` mirrors your host environment (SSH keys, git config, Claude credentials, etc.) into a sandboxed Ubuntu container with a firewall that only allows access to GitHub and Anthropic APIs by default. This lets AI agents work on your code without risking your host system.

**LIMITATIONS**: This product is still in early stages and has not been tested against a wide range of plug-ins, MCPs, etc. Refer to [current limitations and goals](#current-limitations-and-goals) for more.

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

## Usage

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
| `<any>` | Passed through to `docker compose` |

The image is rebuilt automatically when any file under `docker/` (Dockerfile, compose configs, entrypoint scripts, etc.) is newer than the image's build timestamp — you do not need to run `ai-sandbox build` or delete the image manually after pulling changes.

### Flags

| Flag | Description |
|------|-------------|
| `--no-chromium` | Skip Chromium/X11 layer (only valid with `build`) |
| `-D`, `--no-docker` | Build/start without the Docker CLI inside the container (valid on `build`, `start`, `enter`). Smaller image; mutually exclusive with `--docker`. Not allowed while the container is running — stop it first. |
| `--docker` | Enable gated Docker-daemon access via a socket-proxy sidecar (same as `AI_SANDBOX_ENABLE_DOCKER_PROXY=1`) — see [Docker access](#docker-access) |
| `--force` | Bypass the host plugin-conflict pre-flight check (same as `AI_SANDBOX_SKIP_PLUGIN_CHECK=1`) |

## What's inside

The container includes:

- **Languages**: Go, Node.js (via nvm), Bun
- **Shell**: Zsh with Oh My Zsh
- **Tools**: git, git-delta, jq, curl, build-essential
- **Init system**: s6-overlay for process supervision
- **Firewall**: iptables rules restricting outbound to GitHub + Anthropic
- **Optional**: Chromium browser with X11 forwarding

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

## Docker access

Some agents need to pull images, build, or run throwaway containers from
inside the sandbox. Direct `docker.sock` mounting would give the container
root on the host (trivially escapable via `docker run --privileged`), and
Docker-in-Docker is heavy. Instead, `--docker` starts a
[`tecnativa/docker-socket-proxy`](https://github.com/Tecnativa/docker-socket-proxy)
sidecar on a private Compose network that exposes a **whitelisted** subset
of the host Docker API over TCP. The sandbox reaches it at
`DOCKER_HOST=tcp://docker-socket-proxy:2375`, which the standard `docker`
CLI picks up automatically — no other configuration required.

```sh
ai-sandbox --docker
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

### Opting out entirely: `--no-docker`

If an agent doesn't need Docker at all, build with `-D` / `--no-docker` to
skip installing the Docker CLI inside the container. The resulting image is
smaller and the `LAYER 1c2` build step is skipped. The flag is recorded on
the image as the `ai.sandbox.docker-enabled=false` label, and the host
launcher automatically rebuilds when you switch between the two modes (so
`ai-sandbox build --no-docker` followed later by plain `ai-sandbox` triggers
a rebuild that reinstates the CLI). The same rebuild-on-flag-change behavior
applies to `--no-chromium`.

`--no-docker` and `--docker` are mutually exclusive, and `--no-docker` is
rejected while the container is already running (stop it first).

### Security caveat

The proxy is a **mitigation, not a security boundary**. With `CONTAINERS=1`
and `POST=1` a hostile workload inside the sandbox can still escape via e.g.
`docker run -v /:/host alpine chroot /host ...`. Enable `--docker` only when
you actually need Docker access and trust the workload.

## Current limitations and goals

- *OS support*: `ai-sandbox` is currently developed and tested on macOS. It may work on Linux, but this is untested. Full support for both Linux and Windows is planned.
- *Plugin binaries*: architecture-specific plugin binaries (e.g. Mach-O on
  macOS host, ELF on Linux in the container) are not handled. Most plugins
  drive behavior through scripts under `~/.claude/plugins/cache/...` which
  work on both sides, but a plugin shipping a native compiled hook would
  need explicit Linux-side handling.
- *Symmetric mutual exclusion*: see the concurrency invariant note above.

## Further reading

- [`docs/architecture.md`](docs/architecture.md) — how the CLI is structured,
  the phased command flow, and the design decisions behind per-variant image
  tagging, plugin mount generation, mutual exclusion, and the Docker proxy.
- [`docs/next-steps.md`](docs/next-steps.md) — deferred features and known
  gaps (symmetric mutual exclusion, MCP service manager, plugin-binary
  architecture mismatch).

## License

[Apache-2.0](LICENSE)
