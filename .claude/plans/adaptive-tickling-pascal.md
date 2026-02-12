# MCP Service Manager Implementation Plan

## Overview

Create a CommonJS module (`lib/mcp-manager/`) that automatically detects MCP servers from Claude Code plugin configurations and generates container overlay files. Replace hardcoded claude-mem handling with dynamic service discovery.

## Key Files to Create

```
lib/mcp-manager/
├── index.cjs           # Main entry, exports API
├── cli.cjs             # CLI interface (executable)
├── paths.cjs           # XDG path resolution
├── discovery.cjs       # Plugin scanning & MCP extraction
├── generators.cjs      # Docker Compose, firewall, shutdown hooks
├── known-services.cjs  # Service-specific metadata (claude-mem port, etc.)
└── package.json        # Module dependencies
```

## Key Files to Modify

- `ai-sandbox.sh` - Replace hardcoded claude-mem checks with mcp-manager calls
- `docker-compose.yaml` - Remove hardcoded port 37777, reference generated overlay
- `init-firewall.sh` - Source generated firewall rules
- `scripts/check-claude-mem-settings.sh` - Remove (replaced by mcp-manager)
- `rootfs/etc/cont-finish.d/01-claude-mem-stop` - Remove (generated dynamically)
- `package.json` - Add lib/mcp-manager as workspace

## Implementation Steps

### Phase 1: Core Module Setup

1. **Create `lib/mcp-manager/package.json`**
   - CommonJS module (`"type": "commonjs"`)
   - Dependencies: `js-yaml` for YAML generation
   - Bin entry: `"mcp-manager": "./cli.cjs"`
   - Run: `cd lib/mcp-manager && bun install`

2. **Create `lib/mcp-manager/paths.cjs`**
   - XDG path functions with fallbacks:
     - `getDataDir()` → `$XDG_DATA_HOME/ai-sandbox` or `~/.local/share/ai-sandbox`
     - `getCacheDir()` → `$XDG_CACHE_HOME/ai-sandbox` or `~/.cache/ai-sandbox`
     - `getToolCacheDir()` → `getCacheDir()/tool-cache`
   - Migration function from old `.tool-cache` location

### Phase 2: Discovery System

3. **Create `lib/mcp-manager/discovery.cjs`**
   - `scanPlugins()`: Read `~/.claude/settings.json` for enabled plugins
   - `getPluginPaths()`: Read `~/.claude/plugins/installed_plugins.json` for install paths
   - `extractMCPConfig(pluginPath)`: Parse `.mcp.json` or `plugin.json` mcpServers field
   - `expandVariables(config, context)`: Resolve `${CLAUDE_PLUGIN_ROOT}`, `${VAR_NAME}`

4. **Create `lib/mcp-manager/known-services.cjs`**
   - Service metadata for special cases that can't be auto-detected:
   ```javascript
   const KNOWN_SERVICES = {
     'claude-mem': {
       settingsPath: '~/.claude-mem/settings.json',
       portKey: 'CLAUDE_MEM_WORKER_PORT',
       defaultPort: 37777,
       dataDir: '~/.claude-mem',
       statusCommand: 'claude-mem status',
       stopCommand: 'claude-mem stop',
       hostBindingKey: 'CLAUDE_MEM_WORKER_HOST',
       requiredBinding: '0.0.0.0'
     }
   };
   ```

### Phase 3: Generators

5. **Create `lib/mcp-manager/generators.cjs`**
   - `generateDockerCompose(services)`: Create `docker-compose.mcp.yaml`
     - Port mappings, volume mounts, environment variables
   - `generateFirewallRules(services)`: Create `mcp-firewall-rules.sh`
     - iptables rules for each service port
   - `generateShutdownHooks(services)`: Create `cont-finish.d/` scripts
     - s6-overlay format with `#!/command/with-contenv bash`
   - All outputs go to `$XDG_DATA_HOME/ai-sandbox/`

### Phase 4: CLI Interface

6. **Create `lib/mcp-manager/cli.cjs`**
   ```
   Commands:
     scan              Discover MCP services from plugins
     generate          Generate all overlay files
     preflight-check   Verify no conflicts before container start
     configure         Modify service settings for container access
     migrate           Move .tool-cache to XDG location
     status            Show discovered services

   Options:
     --dry-run         Preview without writing
     --verbose         Detailed output
   ```

7. **Create `lib/mcp-manager/index.cjs`**
   - Export API for programmatic use
   - Main `run(command, options)` function

### Phase 5: Integration

8. **Modify `ai-sandbox.sh`**
   - Replace claude-mem specific checks with:
   ```bash
   # Generate MCP overlays
   "${SCRIPT_DIR}/lib/mcp-manager/cli.cjs" generate

   # Pre-flight check
   "${SCRIPT_DIR}/lib/mcp-manager/cli.cjs" preflight-check || exit 1

   # Configure settings
   "${SCRIPT_DIR}/lib/mcp-manager/cli.cjs" configure

   # Add generated overlay to compose
   MCP_OVERLAY="${XDG_DATA_HOME:-$HOME/.local/share}/ai-sandbox/docker-compose.mcp.yaml"
   if [ -f "$MCP_OVERLAY" ]; then
     COMPOSE_FILES="$COMPOSE_FILES -f $MCP_OVERLAY"
   fi
   ```

9. **Update tool cache paths**
   - Change `TOOL_CACHE_DIR` to use XDG path
   - Add migration on first run

10. **Remove hardcoded files**
    - Delete `scripts/check-claude-mem-settings.sh`
    - Delete `rootfs/etc/cont-finish.d/01-claude-mem-stop`
    - Remove port 37777 from `docker-compose.yaml`

### Phase 6: Root package.json

11. **Update root `package.json`**
    - Add workspace reference or postinstall script
    - Ensure `bun install` in lib/mcp-manager runs

## Generated Output Files

Location: `$XDG_DATA_HOME/ai-sandbox/` (default: `~/.local/share/ai-sandbox/`)

1. **`docker-compose.mcp.yaml`** - Port/volume overlay
2. **`mcp-firewall-rules.sh`** - Firewall additions
3. **`cont-finish.d/`** - Shutdown hook scripts
4. **`mcp-registry.json`** - Discovered services cache

## Configuration Discovery Flow

```
~/.claude/settings.json (enabledPlugins)
         ↓
~/.claude/plugins/installed_plugins.json (installPath)
         ↓
{installPath}/.mcp.json or plugin.json (mcpServers)
         ↓
known-services.cjs (port, dataDir, commands)
         ↓
Generated overlay files
```

## Verification

1. Run `bun lib/mcp-manager/cli.cjs scan` - should list claude-mem
2. Run `bun lib/mcp-manager/cli.cjs generate --dry-run` - preview outputs
3. Run `bun lib/mcp-manager/cli.cjs generate` - create files
4. Verify files exist in `~/.local/share/ai-sandbox/`
5. Run `./ai-sandbox.sh build` - should use generated overlay
6. Run `./ai-sandbox.sh start` - should start with claude-mem port exposed
7. Stop container - verify claude-mem stops gracefully
