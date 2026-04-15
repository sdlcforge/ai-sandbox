#!/bin/bash
# shellcheck disable=SC2086 # we want word splitting for 'COMPOSE_FILES'

set -euo pipefail

source ./utils.sh
source ./plugin-conflicts.sh
source ./volume-override.sh
source ./tool-versions.sh
source ./xquartz.sh
source ./options.sh
source ./help.sh
source ./kill-local.sh

${__SOURCED__:+return}

# --- Phase: parse options ---
parse_options "$@"

# --- Phase: help short-circuit ---
if [ "${CMD}" == "help" ]; then
    print_help
    exit 0
fi

# --- Phase: kill-local-ai short-circuit (no docker needed) ---
if [ "${CMD}" == "kill-local-ai" ]; then
    kill_local_ai || exit 1
    exit 0
fi

# --- Phase: docker pre-flight ---
if ! check_docker "starting..."; then
    docker desktop start
    check_docker "bailing out." || exit 1
fi

# --- Phase: resolve script dir / project root (follows symlinks) ---
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
PROJECT_ROOT="$(cd -P "${SCRIPT_DIR}/.." && pwd)"

# --- Phase: plugin-conflict pre-flight (start/enter/up only) ---
if [ "${CMD}" == "start" ] || [ "${CMD}" == "enter" ] || [ "${CMD}" == "up" ]; then
    check_host_plugin_conflicts || exit 1
fi

# --- Phase: flag validation ---
if [ "$NO_CHROMIUM" = "true" ] && [ -n "$CMD" ] && [ "$CMD" != "build" ]; then
  echo "Error: --no-chromium can only be used with 'build' command" 1>&2
  exit 1
fi

# --no-docker is only meaningful when we're about to build the image or start
# the container. Reject it on pass-through / management commands so users don't
# get the false impression it did something.
case "${CMD}" in
  build|start|enter|"") ;;
  *)
    if [ "$NO_DOCKER" = "true" ]; then
      echo "Error: --no-docker only applies to 'build', 'start', or 'enter'" 1>&2
      exit 1
    fi
    ;;
esac

if [ "$NO_DOCKER" = "true" ] && [ "$ENABLE_DOCKER_PROXY" = "true" ]; then
  echo "Error: --no-docker and --docker are mutually exclusive" 1>&2
  exit 1
fi

# --no-docker modifies how the container is built/started. If a container is
# already running, the flag would silently do nothing — fail loudly instead.
if [ "$NO_DOCKER" = "true" ] && [ "${CMD}" != "build" ]; then
  running_state="$(docker inspect -f '{{.State.Running}}' ai-sandbox 2>/dev/null || true)"
  if [ "${running_state}" = "true" ]; then
    echo "Error: --no-docker cannot be applied while the ai-sandbox container is running." 1>&2
    echo "       Stop it first with 'ai-sandbox stop'." 1>&2
    exit 1
  fi
fi

# If --docker was requested but the existing image was built without the Docker
# CLI, the proxy overlay will mount but 'docker' won't exist in the container.
# Refuse early and tell the user to rebuild.
if [ "$ENABLE_DOCKER_PROXY" = "true" ] && [ "${CMD}" != "build" ]; then
  docker_label="$(image_label ai.sandbox.docker-enabled)"
  if [ "${docker_label}" = "false" ]; then
    echo "Error: image was built with --no-docker; rebuild without it to use --docker." 1>&2
    echo "       Run 'ai-sandbox build' to rebuild." 1>&2
    exit 1
  fi
fi

# Export build-time ARG values consumed by docker/docker-compose.yaml.
if [ "$NO_DOCKER" = "true" ]; then
  export INSTALL_DOCKER_CLI=false
else
  export INSTALL_DOCKER_CLI=true
fi

# --- Phase: assemble docker-compose file list ---
GENERATED_COMPOSE="${XDG_CACHE_HOME:-$HOME/.cache}/ai-sandbox/docker-compose.generated.yaml"
mkdir -p "$(dirname "${GENERATED_COMPOSE}")"
generate_volume_override "${GENERATED_COMPOSE}"

if [ "$NO_CHROMIUM" = "true" ]; then
  COMPOSE_FILES="-f ${PROJECT_ROOT}/docker/docker-compose.yaml -f ${GENERATED_COMPOSE}"
else
  COMPOSE_FILES="-f ${PROJECT_ROOT}/docker/docker-compose.yaml -f ${PROJECT_ROOT}/docker/docker-compose.chromium.yaml -f ${GENERATED_COMPOSE}"
fi

if [ "$NO_DOCKER" != "true" ] && { [ "$ENABLE_DOCKER_PROXY" = "true" ] || [ -n "${AI_SANDBOX_ENABLE_DOCKER_PROXY:-}" ]; }; then
  COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_ROOT}/docker/docker-compose.proxy.yaml"
fi

# --- Phase: XQuartz setup (macOS, start/empty cmd only) ---
if { [ -z "${CMD}" ] || [ "${CMD}" == "start" ]; } && [ "$(uname)" = "Darwin" ]; then
    ensure_xquartz
fi

# --- Phase: export host-derived env vars consumed by docker compose ---
export HOST_USER=${USER}
export START_DIR="${PWD}"
HOST_ARCH=$(uname -m)
export HOST_ARCH
export HOST_HOME=${HOME}
HOST_TZ=$(date +%Z)
export HOST_TZ
HOST_UID=$(id -u)
export HOST_UID
HOST_GID=$(id -g)
export HOST_GID
GIT_USER_NAME="$(git config --global user.name || true)"
export GIT_USER_NAME
GIT_USER_EMAIL="$(git config --global user.email || true)"
export GIT_USER_EMAIL
export DOCKER_DEFAULT_PLATFORM=linux/${HOST_ARCH}
export TOOL_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ai-sandbox"
mkdir -p "${TOOL_CACHE_DIR}"

# --- Phase: tool-version resolution + downloads (build-related commands) ---
if [ -z "${CMD}" ] || [ "${CMD}" == "enter" ] || [ "${CMD}" == "start" ] || [ "${CMD}" == "up" ] || [ "${CMD}" == "build" ]; then
    resolve_and_download_tools
fi

# --- Phase: command dispatch ---
if [ "${CMD}" == "start" ] || [ "${CMD}" == "enter" ]; then
    ensure_image
    cleanup_stale_container
    docker compose ${COMPOSE_FILES} up -d

    if [ "${CMD}" == "enter" ]; then
        start_shell
    fi || true
elif [ "${CMD}" == "attach" ] || [ "${CMD}" == "connect" ]; then
    start_shell
elif [ "${CMD}" == "build" ]; then
    do_build
elif [ "${CMD}" == "user-exec" ]; then
    docker compose ${COMPOSE_FILES} exec -u "${HOST_USER}" ai-sandbox "${ARGS[@]}"
elif [ "${CMD}" == "root-exec" ]; then
    docker compose ${COMPOSE_FILES} exec -u root ai-sandbox "${ARGS[@]}"
elif [ "${CMD}" == "status" ]; then
    if [ "$(docker ps -q | wc -l | tr -d ' ')" == 0 ]; then
        echo "nonexistant"
    else
        docker inspect --format='{{.State.Status}}' ai-sandbox
    fi
elif [ "${CMD}" == "stop" ] || [ "${CMD}" == "clean" ]; then
    docker compose ${COMPOSE_FILES} down
    if [ "${CMD}" == "clean" ]; then
        OUTPUT=$(docker rm -f ai-sandbox || true)
        if [ $QUIET -ne 0 ] && [ "${OUTPUT}" == "ai-sandbox" ]; then
            echo "deleted '${OUTPUT}'"
        fi
    fi
else
    docker compose ${COMPOSE_FILES} "${ARGS[@]}"
fi
