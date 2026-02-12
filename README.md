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

## What's inside

The container includes:

- **Languages**: Go, Node.js (via nvm), Bun
- **Shell**: Zsh with Oh My Zsh
- **Tools**: git, git-delta, jq, curl, build-essential
- **Init system**: s6-overlay for process supervision
- **Firewall**: iptables rules restricting outbound to GitHub + Anthropic
- **Optional**: Chromium browser with X11 forwarding

## Current limitations and goals

- *OS support*: `ai-sandbox` is currently developed and tested on macOS. It may work on Linux, but this is untested. Full support for both Linux and Windows is planned.
- *Plugin and MCP support*: `claude-mem` is specifically supported. While other plugins/MCPs may work, consider the following:
  - configuration, cache, and data folders may not be mapped into the container,
  - if a MCP server is already running on the host, the container Claude may try to start its own process which can lead to various errors, including possible MCP file/data corruption,
  - acess to any user visible endpoints provided by the MCP may require opening additional ports, and
  - because of limited testing, there may be other issues specific to any particular MCP.

## License

[Apache-2.0](LICENSE)
