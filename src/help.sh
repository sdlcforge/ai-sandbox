# shellcheck shell=bash

function print_help() {
    cat <<'EOF'
ai-sandbox — run a disposable, containerized AI dev environment.

Usage:
  ai-sandbox [options] [command] [args...]

If no command is given and a sandbox is already running, `ai-sandbox` (with no
config-changing flags) acts as `connect` — it will not stop the running
container. Otherwise `enter` is assumed.

Commands:
  enter              Start the container (if needed) and drop into a shell. (default)
  start              Start the container in the background; do not attach.
  attach, connect    Attach a shell to an already-running container.
  build              Build the container image for the resolved profile
                     composition. Each unique composition (profiles +
                     capabilities) produces its own image, tagged
                     ai-sandbox:profile-<hash>; rebuilding only replaces the
                     matching composition.
  status             Show container state, built images, and (when stopped)
                     whether the container is currently runnable. See `--json`
                     and `--test-check` options below.
  stop               Stop and remove the container.
  clean              Stop, remove the container, and delete all ai-sandbox:*
                     images.
  user-exec <cmd>    Run <cmd> inside the container as the host user.
  root-exec <cmd>    Run <cmd> inside the container as root.
  kill-local-ai      Kill host claude/plugin processes that conflict with the VM.
                     Retries up to 4 times; warns if any survive.
  new-profile        Scaffold a profile YAML by auto-discovering skills, hooks,
                     and agents from ~/.claude/ and ./.claude/. Requires --name.
                     Options: --name <name> (required), --mode <mirror|static>,
                     --output <path>, --plugins <name,...>.
  fix-ssh            Recreate the container so the host's current SSH_AUTH_SOCK
                     is bind-mounted. Use after a host logout / ssh-agent
                     restart when `git push` inside the container fails.
  help, -h, --help   Show this message.

Any other command is forwarded to `docker compose` with the assembled compose files,
so e.g. `ai-sandbox logs -f` works.

Options:
  --profile <name>   Compose the named profile into this invocation. Repeatable;
                     profiles merge left to right. When omitted, the
                     default_profiles from config.yaml are used (falling back to
                     'base mirror'). Capabilities like 'docker' (host Docker
                     access via a socket-proxy sidecar) and 'chromium' (X11
                     browser support) are opt-in via profiles such as
                     '--profile docker' / '--profile chromium'.
  --mode <mode>      Override the container mode for this run: 'mirror' mirrors
                     host identity (SSH keys, git config, ~/.claude, ~/.config);
                     'static' is self-contained with no host-identity mounts.
                     Overrides any mode set by the composed profiles.
  --force            Bypass host plugin-conflict pre-flight checks.
                     Equivalent to AI_SANDBOX_SKIP_PLUGIN_CHECK=1.
  -y, --yes          Skip the confirmation prompt that fires before commands
                     would stop a running sandbox container. Implied when stdin
                     is not a TTY (scripts/tests proceed without prompting).
  --no-isolate-config
                     Share the host's ~/.config with the container (read-write
                     passthrough). Default is to mount it copy-on-write so
                     writes from inside the container stay container-local.
                     Pass this when a plugin needs to round-trip state in
                     ~/.config back to the host.
  -q, --quiet        Quieter output (default for most commands; `status` is verbose).
  --json             (status only) Emit machine-readable JSON instead of text.
  --test-check       (status only) Run the pre-flight checks silently. Exits 0
                     if the container could be started, 1 otherwise. Prints
                     nothing. Intended for use as a gate in test harnesses.

Environment:
  AI_SANDBOX_SKIP_PLUGIN_CHECK=1       Same as --force.
EOF
}
