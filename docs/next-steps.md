# Next Steps

Deferred features and known gaps, recorded while the context is fresh so the
next person to pick them up isn't starting from zero.

## Symmetric host↔VM claude mutual exclusion via lockfile

### Problem

The preflight in `src/plugin-conflicts.sh` (called from `src/index.sh`) only
prevents the container from starting when host-side claude or plugin workers
are already running. It does **not** prevent the user from launching host-side
claude while the ai-sandbox container is already running. In that case both
sides can race on shared SQLite state (e.g. `~/.claude-mem`) and corrupt it.

### Current mitigation

A documented invariant — "don't run claude on both sides simultaneously" —
published in `README.md` under *Plugin support → Concurrency invariant*.
Relies on user discipline.

### Proposed solution

At container start, write a lockfile at `~/.claude/.ai-sandbox.lock`
containing the container's name/PID and a timestamp. Clean it up on container
stop and via `trap EXIT` in the start script.

Provide a small host-side `claude` wrapper (e.g. shadowing the native binary
at `~/.local/bin/claude`, or as a `claude-safe` command on `PATH` ahead of the
real one) that refuses to start if the lockfile is held and its recorded
container is still running. On host-side `claude` startup:

1. Check for `~/.claude/.ai-sandbox.lock`.
2. If present, verify the referenced container is actually running
   (`docker inspect`) — stale locks (e.g. after a machine crash) must not
   block the user forever.
3. If the container is live, print the reverse of the preflight error message
   (naming the container, suggesting `ai-sandbox stop`) and exit nonzero.
4. Otherwise proceed; clean the stale lock opportunistically.

This makes exclusion symmetric without requiring port coordination or IPC.
Defer until the documented invariant proves insufficient in practice.

## Architecture mismatch in plugin binaries

### Problem

The current design assumes plugin hooks execute via scripts (JS, Python, bash)
inside `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`, which are
portable across macOS host and Linux container. If a future plugin ships a
natively compiled hook binary (e.g. a Go or Rust executable), its Mach-O
build on the macOS host would fail to execute inside the Linux VM with
`exec format error` — the same class of bug that originally motivated
dropping the `~/.local` bind mount.

### Proposed solution

Have the preflight walk each plugin's `installPath` from
`installed_plugins.json`, run `file(1)` against executables found there, and
warn when Mach-O content is detected under a plugin that claims to run
cross-platform. The long-term fix would require a per-plugin install strategy
in `~/.config/ai-sandbox/volume-maps` (or an adjacent `plugin-catalog.yml`)
where the user can declare "run this command inside the container to install
the Linux build of plugin X."

Not urgent — no known claude plugins ship native binaries today.

## MCP Service Manager

### Status: Deferred

The implementation of a generalized MCP Service Manager is deferred pending:

1. **Claude Configuration Library** — a library that handles discovery of:
   - Enabled plugins from `~/.claude/settings.json`
   - Installed plugin paths from `~/.claude/plugins/installed_plugins.json`
   - MCP server configurations from `.mcp.json` files
   - Skills, commands, hooks, and other plugin components
2. **Additional development tools** — to be installed before implementation
   begins.

### Goal

Replace hardcoded per-plugin handling (the original `claude-mem` special
case, superseded by the generic dot-dir auto-mount but still not a real MCP
orchestrator) with dynamic MCP service discovery.

### What the library should provide

- `scanPlugins()` — list enabled plugins.
- `getPluginPaths()` — get install paths for each plugin.
- `extractMCPConfig(pluginPath)` — parse MCP server definitions.
- Variable expansion for `${CLAUDE_PLUGIN_ROOT}` and environment variables.

### What this project will implement (once the library is ready)

- `lib/mcp-manager/` — CommonJS module for container integration.
- XDG path handling (`$XDG_DATA_HOME/ai-sandbox`,
  `$XDG_CACHE_HOME/ai-sandbox`).
- Generators for Docker Compose overlays, firewall rules, shutdown hooks.
- CLI interface for `scan`, `generate`, `preflight-check`, `migrate`
  commands.
- Integration with `bin/ai-sandbox.sh`.

### Configuration files the library needs to read

```
~/.claude/settings.json                    # enabledPlugins object
~/.claude/plugins/installed_plugins.json   # installPath, version, etc.
{installPath}/.mcp.json                    # mcpServers definitions
{installPath}/plugin.json                  # alternative mcpServers location
```

### Example MCP config (from claude-mem)

```json
{
  "mcpServers": {
    "mcp-search": {
      "type": "stdio",
      "command": "${CLAUDE_PLUGIN_ROOT}/scripts/mcp-server.cjs"
    }
  }
}
```

### Plan reference

Full implementation plan: `.claude/plans/adaptive-tickling-pascal.md`.

### Resume instructions

1. Install the claude configuration library.
2. Review and update the plan at `.claude/plans/adaptive-tickling-pascal.md`.
3. Adapt Phase 2 (Discovery System) to use the library instead of a custom
   implementation.
4. Proceed with implementation.
