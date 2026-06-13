# shellcheck shell=bash

function print_help() {
    cat <<'EOF'
ai-sandbox — run isolated, containerized AI dev environments.

Usage:
  ai-sandbox <command> [args...]         Global command
  ai-sandbox <name> [command] [args...]  Per-instance command (default: enter)
  ai-sandbox                             List all sandboxes

Global commands:
  create <name> [options]  Create and start a new sandbox instance. Options:
                             --profile <name>   Compose a named profile. Repeatable.
                             --mode <mode>      Override mode: mirror or static.
                             --no-isolate-config  Share host ~/.config (read-write).
                             --enter            Open a shell after creating.
                             --add-marketplace <ref>  Register a plugin marketplace (https:// or
                                                file://). Repeatable; file:// paths are auto-
                                                mounted read-only into the container.
                             --enable-plugin <name>   Enable a named plugin from any registered
                                                marketplace. Repeatable.
                             --enable-all       Enable all plugins from the last marketplace.
  list                     List all managed sandbox instances.
  new-profile              Scaffold a profile YAML from local Claude assets.
                             Requires --name. Options: --name, --mode, --output, --plugins.
  kill-local-ai            Kill host claude/plugin processes that conflict with sandboxes.
  help, -h, --help         Show this message.

Per-instance commands (ai-sandbox <name> <command>):
  enter              Start the container (if needed) and open a shell. (default)
  start              Start in the background; do not attach.
  stop               Pause the container (preserves it and its labels).
  delete             Remove the container (docker compose down).
  attach, connect    Attach a shell to an already-running container.
  status             Show container state, built images, and runability.
  build              Build the image for the resolved profile composition.
  clean              Delete container and remove all ai-sandbox:* images.
  fix-ssh            Recreate the container with the current SSH_AUTH_SOCK mounted.
  user-exec <cmd>    Run <cmd> inside the container as the host user.
  root-exec <cmd>    Run <cmd> inside the container as root.
  <other>            Forwarded to docker compose (e.g. 'logs -f', 'exec').

Options (global):
  --force            Bypass host plugin-conflict pre-flight. Same as AI_SANDBOX_SKIP_PLUGIN_CHECK=1.
  -y, --yes          Skip confirmation prompts before stopping a container.
  -q, --quiet        Quieter output.

Options (status only):
  --json             Emit machine-readable JSON.
  --test-check       Silent pre-flight gate; exits 0 if startable, 1 otherwise.

Environment:
  AI_SANDBOX_SKIP_PLUGIN_CHECK=1       Same as --force.
EOF
}
