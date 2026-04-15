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

### Flags

| Flag | Description |
|------|-------------|
| `--no-chromium` | Skip Chromium/X11 layer (only valid with `build`) |
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
[`docs/future-work.md`](docs/future-work.md) for the planned lockfile-based
symmetric enforcement.

## Current limitations and goals

- *OS support*: `ai-sandbox` is currently developed and tested on macOS. It may work on Linux, but this is untested. Full support for both Linux and Windows is planned.
- *Plugin binaries*: architecture-specific plugin binaries (e.g. Mach-O on
  macOS host, ELF on Linux in the container) are not handled. Most plugins
  drive behavior through scripts under `~/.claude/plugins/cache/...` which
  work on both sides, but a plugin shipping a native compiled hook would
  need explicit Linux-side handling.
- *Symmetric mutual exclusion*: see the concurrency invariant note above.

## License

[Apache-2.0](LICENSE)
