# Next Steps: MCP Service Manager

## Status: Deferred

The implementation of the MCP Service Manager is deferred pending:

1. **Claude Configuration Library** - A library that handles discovery of:
   - Enabled plugins from `~/.claude/settings.json`
   - Installed plugin paths from `~/.claude/plugins/installed_plugins.json`
   - MCP server configurations from `.mcp.json` files
   - Skills, commands, hooks, and other plugin components

2. **Additional Development Tools** - To be installed before implementation begins

## Plan Reference

Full implementation plan: `~/.claude/plans/adaptive-tickling-pascal.md`

### Key Points from Plan

**Goal**: Replace hardcoded claude-mem handling with dynamic MCP service discovery

**What the library should provide**:
- `scanPlugins()` - List enabled plugins
- `getPluginPaths()` - Get install paths for each plugin
- `extractMCPConfig(pluginPath)` - Parse MCP server definitions
- Variable expansion for `${CLAUDE_PLUGIN_ROOT}` and environment variables

**What this project will implement** (once library is ready):
- `lib/mcp-manager/` - CommonJS module for container integration
- XDG path handling (`$XDG_DATA_HOME/ai-sandbox`, `$XDG_CACHE_HOME/ai-sandbox`)
- Generators for Docker Compose overlays, firewall rules, shutdown hooks
- CLI interface for scan, generate, preflight-check, migrate commands
- Integration with `ai-container.sh`

**Configuration files the library needs to read**:
```
~/.claude/settings.json                    # enabledPlugins object
~/.claude/plugins/installed_plugins.json   # installPath, version, etc.
{installPath}/.mcp.json                    # mcpServers definitions
{installPath}/plugin.json                  # Alternative mcpServers location
```

**Example MCP config** (from claude-mem):
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

## Resume Instructions

When ready to continue:

1. Install the claude configuration library
2. Review and update the plan at `~/.claude/plans/adaptive-tickling-pascal.md`
3. Adapt Phase 2 (Discovery System) to use the library instead of custom implementation
4. Proceed with implementation
