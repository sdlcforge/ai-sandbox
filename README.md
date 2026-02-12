# ai-sandbox

Replicates your local Claude Code setup in an isolated Docker container for convenience and safety.

ai-sandbox mirrors your host environment (SSH keys, git config, Claude credentials, plugins) into a sandboxed Ubuntu container with a firewall that only allows access to GitHub and Anthropic APIs. This lets AI agents work on your code without risking your host system.

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- macOS (Linux support planned)
- An active [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installation on the host

Optional:
- [XQuartz](https://www.xquartz.org/) for GUI app support (Chromium)
- [claude-mem](https://github.com/anthropics/claude-code/tree/main/packages/claude-mem) plugin for persistent memory

## Install

```bash
npm install -g ai-sandbox
```

Or clone and link directly:

```bash
git clone https://github.com/sdlcforge/ai-sandbox.git
cd ai-sandbox
npm link
```

## Usage

```bash
# Enter the sandbox (builds image if needed, starts container, connects)
ai-sandbox

# Build the container image
ai-sandbox build

# Build without Chromium/X11 support
ai-sandbox build --no-chromium

# Start the container and connect
ai-sandbox start

# Attach to an already-running container
ai-sandbox attach

# Pass any docker compose command through
ai-sandbox down
ai-sandbox logs -f
```

## CLI Reference

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

## What's Inside

The container includes:

- **Languages**: Go, Node.js (via nvm), Bun
- **Shell**: Zsh with Oh My Zsh
- **Tools**: git, git-delta, jq, curl, build-essential
- **Init system**: s6-overlay for process supervision
- **Firewall**: iptables rules restricting outbound to GitHub + Anthropic
- **Optional**: Chromium browser with X11 forwarding

## License

[Apache-2.0](LICENSE)
