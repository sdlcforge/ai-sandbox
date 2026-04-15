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
  build              Build the container image for the current option set. Each
                     unique combination of --no-chromium / --no-docker produces
                     its own image (tagged ai-sandbox:<variant>); rebuilding
                     only replaces the matching variant.
  status             Print the container's state (or "nonexistant").
  stop               Stop and remove the container.
  clean              Stop, remove the container, and delete all ai-sandbox:*
                     images.
  user-exec <cmd>    Run <cmd> inside the container as the host user.
  root-exec <cmd>    Run <cmd> inside the container as root.
  kill-local-ai      Kill host claude/plugin processes that conflict with the VM.
                     Retries up to 4 times; warns if any survive.
  help, -h, --help   Show this message.

Any other command is forwarded to `docker compose` with the assembled compose files,
so e.g. `ai-sandbox logs -f` works.

Options:
  --no-chromium      (build only) Build the image without Chromium.
  -D, --no-docker    (build/start only) Build/start without the Docker CLI
                     inside the container. Produces a smaller image. Cannot
                     be combined with --docker. If the container is already
                     running, stop it before applying this flag. Selects a
                     distinct image variant — switching flags picks a
                     different variant without rebuilding the others.
  --docker           Give the container gated access to the host Docker daemon
                     via a tecnativa/docker-socket-proxy sidecar. Enables
                     image pull/search/build and container run/exec inside the
                     sandbox. This is a mitigation, not a security boundary —
                     only enable when you actually need it.
  --force            Bypass host plugin-conflict pre-flight checks.
                     Equivalent to AI_SANDBOX_SKIP_PLUGIN_CHECK=1.
  -q, --quiet        Quieter output (default for most commands; `status` is verbose).

Environment:
  AI_SANDBOX_SKIP_PLUGIN_CHECK=1       Same as --force.
  AI_SANDBOX_ENABLE_DOCKER_PROXY=1     Same as --docker.
EOF
}
