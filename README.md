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
- [`yq`](https://github.com/kislyuk/yq) (the Python `kislyuk/yq` wrapper — **not** `mikefarah/yq`, an incompatible tool that shares the same binary name) for readable YAML rendering of the `detail` command's `Configuration:` section. Without it, the section degrades gracefully to pretty-printed JSON.

## Install

```bash
npm install -g ai-sandbox
```

## Quick start

```bash
# Enter the sandbox (builds image if needed, starts container, connects)
ai-sandbox

# Pass any docker compose command through, scoped to a named instance
ai-sandbox mybox down
ai-sandbox mybox logs -f
```

## CLI reference

| Command | Description |
|---------|-------------|
| *(no args)* | Build if needed, start if stopped, then connect to the default (unnamed) instance. Use `ls` to list instances and profiles instead. |
| `ls` | List all instances and profiles, grouped as `Instances:` / `Profiles:` |
| `instances ls` | List instances only |
| `instances create <name> [options]` | Create and start a new instance named `<name>` |
| `profiles ls` | List profiles only |
| `profiles create <name> [options]` | Scaffold a new profile YAML file named `<name>` by auto-discovering skills, hooks, and agents |
| `build` | Build the Docker image |
| `start` | Start the container and open a shell |
| `attach` | Connect to an already-running container |
| `<name> delete` | Delete `<name>` — works for both instances (removes the container) and profiles (removes the profile file). There is no separate `profiles delete <name>` form; deletion is always addressed by name. |
| `fix-ssh` | Recreate the container with the host's current `SSH_AUTH_SOCK` bind-mounted. Run this after a host logout / ssh-agent restart if `git push` inside the container fails — see [SSH agent forwarding](#ssh-agent-forwarding). |
| `detail` | Show container/image state, blocking-process conflicts, and (when present) the persisted configuration. |
| `<any>` | Passed through to `docker compose` |

The image is rebuilt automatically when any file under `docker/` (Dockerfile, compose configs, entrypoint scripts, etc.) or any active profile YAML is newer than the image's build timestamp — you do not need to run `ai-sandbox build` or delete the image manually after pulling changes.

### Flags

| Flag | Description |
|------|-------------|
| `--profile <name>` | Activate a named profile (repeatable; profiles are merged left to right). See [Profiles](#profiles). |
| `--mode <mirror\|static>` | Override the container identity mode for this run only, without changing the profile file. |
| `--force` | Bypass the host plugin-conflict pre-flight check (same as `AI_SANDBOX_SKIP_PLUGIN_CHECK=1`) |
| `--no-isolate-config` | Share `~/.config` read-write with the host (opt out of the default copy-on-write overlay). See [Config isolation](#config-isolation). |
| `--static-playground` | Give `~/playground` a copy-on-write overlay: writes stay container-local and the host copy is never modified. Opt-in (default off). Unrelated to `--mode static` despite the shared word — see [Playground isolation](#playground-isolation). |

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
- **Firewall**: default-deny outbound, explicit allow-list for GitHub + Anthropic (enforced by a privilege-isolated firewall-init sidecar — see [Network access](#network-access))
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

### Playground isolation

By default, `~/playground` is bind-mounted read-write regardless of mode.
Pass `--static-playground` to give it the same copy-on-write treatment as
`~/.config`: the container sees the host's current `~/playground` as a
read-only lower layer, and any writes inside the container land on an
overlay upper layer that's discarded with the container. Host
`~/playground` is never modified while the flag is active. Mechanics:

- Host `~/playground` → bind-mounted read-only at
  `/mnt/ai-sandbox/host-playground`.
- A Docker **named volume**, `playground-overlay` — not tmpfs, because
  `~/playground` is large (often 19GB+) and a RAM-backed upper layer would be
  the wrong trade-off — holds the `upper/` and `work/` dirs.
- `docker/rootfs/etc/cont-init.d/06-overlay-playground` mounts an overlayfs
  at `${HOME}/playground` inside the container during s6 startup.
- Reads pass through to the host for files the container hasn't touched, so
  host edits during a session are still visible for untouched files.

```sh
ai-sandbox --static-playground
```

**Not related to `--mode static`.** Despite the shared word, `--static-playground`
and [`--mode <mirror|static>`](#profiles) are unrelated features:
`--static-playground` only controls whether writes under `~/playground` are
visible on the host, while `--mode static` controls container identity
(whether SSH keys, git config, `~/.claude`, and `~/.config` are mirrored
from the host at all). Either mode value can be combined with either
setting of `--static-playground`.

Unlike config isolation, playground isolation is **opt-in** (default off).
`~/.config` isolation is safe to force on for everyone because config
directories are small and rarely relied on as host-writable state; the
`~/playground` tree is exactly the kind of path many users already expect
to keep writing to on the host, so the write-isolation behavior only
applies when you explicitly ask for it.

Use [`sandbox-volumes`](#inspecting-and-syncing-overlay-volumes-sandbox-volumes)
to inspect drift and sync changes — the same tool used for config
isolation works against any registered overlay, including the `playground`
one it registers once the flag is active. **Performance caveat:** always
scope `sandbox-volumes status`/`diff`/`sync` to a subpath (e.g.
`sandbox-volumes diff ~/playground/some-repo`), never the whole tree — an
unscoped recursive diff across a large, multi-repo `~/playground` can take
many minutes, unlike the near-instant diff against `~/.config`.

Requirements: same as [config isolation](#config-isolation) — the container
is granted `CAP_SYS_ADMIN` and `apparmor=unconfined` while either overlay is
active, so it can call `mount()`; the two overlays share this grant rather
than requesting it twice. `CAP_SYS_ADMIN` is a real privilege grant — in
this project's threat model the firewall is the primary boundary and the
cap set is intentionally permissive, but since `--static-playground` is
opt-in and off by default, you only take on the grant on its account if you
ask for it.

`delete`/`clean` remove the `playground-overlay` volume along with the
container, discarding any container-local writes that were never synced
back to the host. There is no separate confirmation for this — it matches
plain `docker compose down` expectations.

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

## Network access

By default the sandbox can only reach GitHub and the Anthropic API — every
other destination is dropped. Three capabilities extend that allow-list for
specific use cases, and a CLI flag extends it for anything else. All of these
are runtime-only: they change which egress rules the firewall applies at
container start, not what's baked into the image.

```sh
# Let the agent hit any public search/API endpoint over HTTPS
ai-sandbox start --profile web-search

# Let the agent reach services listening on the host (e.g. a local dev server)
ai-sandbox start --profile host-access

# Let the agent reach other devices on your LAN
ai-sandbox start --profile lan-access

# Allow one more specific destination without a named capability
ai-sandbox start --allow-egress 10.0.0.5:8080 --allow-egress registry.example.com:443
```

- **`web-search`** (`capabilities: [web-search]`) — allow egress to any
  public (non-private) IPv4 host on port 443. RFC 1918/link-local/loopback/
  CGNAT/multicast/reserved ranges are excluded, so this does not also grant
  LAN access.
- **`host-access`** (`capabilities: [host-access]`) — allow egress to any TCP
  port currently listening on the host, reached via `host.docker.internal`.
  The listening-port set is snapshotted once, from the host, when the
  container starts (macOS only — `lsof -iTCP -sTCP:LISTEN`); a host service
  started afterward isn't reachable until the container is recreated.
- **`lan-access`** (`capabilities: [lan-access]`) — allow egress to any IP
  address and TCP port on the host's LAN (local subnet). The LAN CIDR is
  detected once from the host at container-start time (macOS only); if
  detection fails (no default route, VPN-only interface, unrecognized
  netmask) the capability is a no-op rather than an error.
- **`--allow-egress <host-or-ip-or-cidr>:<port>`** — repeatable CLI flag that
  allow-lists one more host/IP/CIDR on one port, without needing a named
  capability or profile. Hostname entries are DNS-resolved once at
  container-init time and never refreshed (same one-shot-resolution behavior
  the built-in GitHub/Anthropic rules already have). Participates in
  [config persistence](docs/architecture.md#config-persistence-and-restore)
  like every other config-changing flag.

### Security caveat

`host-access` and `lan-access` meaningfully broaden the attack surface
available to a compromised agent: `host-access` reaches whatever is
listening on your machine (a local database, an internal admin UI, a dev
server with no auth because it "only listens on localhost"), and
`lan-access` reaches every device and port on your local network. Enable
either only when you need it and trust the workload; `web-search` is
comparatively narrow (a single port, and no private-network destinations
at all). `--allow-egress` is a single port too, but its CIDR form has **no
minimum-prefix restriction** — the firewall accepts and applies whatever
prefix width you give it, down to `0.0.0.0/0`, and unlike `web-search` it
doesn't exclude private/reserved ranges. A CIDR that broad allow-lists
every IPv4 destination on that port. Prefer a single host/IP or the
narrowest CIDR that covers your actual destination; the flag will not
narrow it for you.

## Current limitations and goals

- *OS support*: `ai-sandbox` is currently developed and tested on macOS. It may work on Linux, but this is untested. Full support for both Linux and Windows is planned.
- *Plugin binaries*: architecture-specific plugin binaries (e.g. Mach-O on
  macOS host, ELF on Linux in the container) are not handled. Most plugins
  drive behavior through scripts under `~/.claude/plugins/cache/...` which
  work on both sides, but a plugin shipping a native compiled hook would
  need explicit Linux-side handling.
- *Symmetric mutual exclusion*: see the concurrency invariant note above.
- *Profiles*: the profiles feature is implemented. The `--profile`, `--mode`, and `profiles create` surface described above is the current interface.

## Further reading

- [`docs/architecture.md`](docs/architecture.md) — how the CLI is structured,
  the phased command flow, and the design decisions behind per-variant image
  tagging, plugin mount generation, mutual exclusion, and the Docker proxy.
- [`docs/ai-sandbox-profiles-spec.md`](docs/ai-sandbox-profiles-spec.md) — full profiles specification: YAML schema, composition rules, storage and discovery, `profile-installer.js` interface, and the `profiles create` command.
- [`docs/next-steps.md`](docs/next-steps.md) — deferred features and known
  gaps (symmetric mutual exclusion, MCP service manager, plugin-binary
  architecture mismatch).

## License

[Apache-2.0](LICENSE)
