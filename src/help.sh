# shellcheck shell=bash

function print_help() {
    cat <<'EOF'
ai-sandbox — run a disposable, containerized AI dev environment.

Usage:
  ai-sandbox [options] [command] [args...]

If no command is given, `enter` is assumed.

Commands:
  enter              Start the container (if needed) and drop into a shell. (default)
  start              Start the container in the background; do not attach.
  attach, connect    Attach a shell to an already-running container.
  build              Build the container image. Use with --no-chromium to skip Chromium.
  status             Print the container's state (or "nonexistant").
  stop               Stop and remove the container.
  clean              Stop, remove the container, and delete the `ai-sandbox` container.
  user-exec <cmd>    Run <cmd> inside the container as the host user.
  root-exec <cmd>    Run <cmd> inside the container as root.
  kill-local-ai      Kill host claude/plugin processes that conflict with the VM.
                     Retries up to 4 times; warns if any survive.
  help, -h, --help   Show this message.

Any other command is forwarded to `docker compose` with the assembled compose files,
so e.g. `ai-sandbox logs -f` works.

Options:
  --no-chromium      (build only) Build the image without Chromium.
  --force            Bypass host plugin-conflict pre-flight checks.
                     Equivalent to AI_SANDBOX_SKIP_PLUGIN_CHECK=1.
  -q, --quiet        Quieter output (default for most commands; `status` is verbose).

Environment:
  AI_SANDBOX_SKIP_PLUGIN_CHECK=1   Same as --force.
EOF
}
