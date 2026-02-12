#!/bin/bash
set -euo pipefail

SETTINGS_FILE="${HOME}/.claude-mem/settings.json"

if [ ! -f "$SETTINGS_FILE" ]; then
    echo "claude-mem settings file not found at $SETTINGS_FILE"
    echo "Skipping claude-mem configuration check."
    exit 0
fi

# Extract the current CLAUDE_MEM_WORKER_HOST value
CURRENT_HOST=$(jq -r '.CLAUDE_MEM_WORKER_HOST // empty' "$SETTINGS_FILE")

if [ -z "$CURRENT_HOST" ]; then
    echo "CLAUDE_MEM_WORKER_HOST not set in settings.json"
    echo "Adding CLAUDE_MEM_WORKER_HOST=0.0.0.0 for ai-sandbox compatibility..."
    jq '. + {"CLAUDE_MEM_WORKER_HOST": "0.0.0.0"}' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"
    mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    echo "Done."
elif [ "$CURRENT_HOST" = "0.0.0.0" ]; then
    echo "claude-mem is already configured for ai-sandbox (CLAUDE_MEM_WORKER_HOST=0.0.0.0)"
elif [ "$CURRENT_HOST" = "127.0.0.1" ]; then
    echo "Updating CLAUDE_MEM_WORKER_HOST from 127.0.0.1 to 0.0.0.0 for ai-sandbox compatibility..."
    jq '.CLAUDE_MEM_WORKER_HOST = "0.0.0.0"' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"
    mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    echo "Done. You may need to restart claude-mem for changes to take effect."
else
    echo "WARNING: CLAUDE_MEM_WORKER_HOST is set to '$CURRENT_HOST'"
    echo "Expected '127.0.0.1' or '0.0.0.0'. Refusing to modify unexpected value."
    echo "Please manually update $SETTINGS_FILE if needed."
    exit 1
fi
