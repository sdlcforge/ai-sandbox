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
source ./status.sh
source ./new-profile.sh
source ./create.sh
source ./list.sh

${__SOURCED__:+return}

# --- Phase: parse options ---
parse_options "$@"

# Export SANDBOX_NAME early so all sourced modules can consume it.
export SANDBOX_NAME

# --- Phase: global command short-circuits (no docker needed) ---

# Bare invocation and explicit `list` both show the instance list.
# Short-circuits before the Docker pre-flight so `list` works even when the
# Docker daemon is down (do_list handles empty output gracefully).
if [ "${CMD}" = "list" ]; then
    do_list
    exit 0
fi

if [ "${CMD}" = "help" ]; then
    print_help
    exit 0
fi

if [ "${CMD}" = "kill-local-ai" ]; then
    kill_local_ai || exit 1
    exit 0
fi

if [ "${CMD}" = "new-profile" ]; then
    new_profile "${ARGS[@]+"${ARGS[@]}"}" || exit 1
    exit 0
fi

# --- Phase: docker pre-flight ---
# `status` tolerates docker being down; it will just report the container as
# stopped and no images. Anything else requires a running daemon.
if [ "${CMD}" != "status" ]; then
    if ! check_docker "starting..."; then
        docker desktop start
        check_docker "bailing out." || exit 1
    fi
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

# --- Phase: restore saved profiles for start/enter (no config flags) ---
# When start/enter is called without any config-changing flags, read the
# profile list that was saved at `create` time so the container restarts with
# its original profile composition without requiring the user to re-specify
# --profile flags each time.
if [ "${CMD}" == "start" ] || [ "${CMD}" == "enter" ]; then
    if [ "${CONFIG_FLAGS_PROVIDED}" != "true" ] && is_container_running_or_stopped; then
        saved_profiles="$(docker inspect -f \
            '{{index .Config.Labels "ai.sandbox.profiles"}}' \
            "ai-sandbox-${SANDBOX_NAME}" 2>/dev/null || true)"
        if [ -n "${saved_profiles}" ]; then
            IFS=',' read -ra PROFILES <<< "${saved_profiles}"
        fi
    fi
fi

# --- Phase: resolve profiles ---
# Run profile-installer.js to compose the requested (or default) profiles and
# emit the resolved env block. Source PROFILE_* from it, assemble the effective
# Dockerfile, and derive the image tag. Drives compose-overlay selection below.
PROFILE_INSTALLER="${PROJECT_ROOT}/bin/profile-installer.js"
PROFILE_INSTALLER_ARGS=()
if [ "${#PROFILES[@]}" -gt 0 ]; then
  PROFILE_INSTALLER_ARGS+=("${PROFILES[@]}")
fi
if [ -n "${MODE_OVERRIDE}" ]; then
  PROFILE_INSTALLER_ARGS+=(--mode "${MODE_OVERRIDE}")
fi

PROFILE_INSTALLER_OUTPUT="$(node "${PROFILE_INSTALLER}" "${PROFILE_INSTALLER_ARGS[@]+"${PROFILE_INSTALLER_ARGS[@]}"}")" || exit $?

# Source only the KEY=VALUE env lines (between the ENV sentinel and the first
# subsequent '###' sentinel). awk emits them; eval sets PROFILE_* in this scope.
PROFILE_ENV_BLOCK="$(printf '%s\n' "${PROFILE_INSTALLER_OUTPUT}" \
  | awk '/^### PROFILE_ENV ###$/{f=1;next} /^###/{f=0} f && /^[A-Z_]+=/{print}')"
eval "${PROFILE_ENV_BLOCK}"
export PROFILE_MODE PROFILE_CAPABILITIES PROFILE_IMAGE_TAG \
  PROFILE_COMPOSITION_HASH PROFILE_ASSEMBLED_DOCKERFILE

# MODE_OVERRIDE wins; else the profile's mode; else mirror (legacy default).
if [ -n "${MODE_OVERRIDE}" ]; then
  EFFECTIVE_MODE="${MODE_OVERRIDE}"
else
  EFFECTIVE_MODE="${PROFILE_MODE:-mirror}"
fi
export EFFECTIVE_MODE

# Per-composition image tag consumed by docker/docker-compose.yaml.
# profile_image_suffix() reads PROFILE_COMPOSITION_HASH set above from the
# installer output. Using the function keeps utils.sh as the single source of
# truth for the tag-suffix derivation.
AI_SANDBOX_IMAGE_TAG="ai-sandbox:$(profile_image_suffix)"
export AI_SANDBOX_IMAGE_TAG

# Capability-derived proxy state. The proxy sidecar overlay and the
# ai.sandbox.docker-proxy label are keyed off this.
if profile_has_capability docker; then
  EFFECTIVE_PROXY=true
else
  EFFECTIVE_PROXY=false
fi
export EFFECTIVE_PROXY NO_ISOLATE_CONFIG

# Assemble the effective Dockerfile from the resolved capabilities and point the
# compose build at it (docker-compose.yaml reads ${AI_SANDBOX_DOCKERFILE}).
# --hash embeds the composition hash as a LABEL so is_build_stale() can detect
# composition changes by inspecting the built image without re-running the installer.
"${PROJECT_ROOT}/docker/scripts/assemble-dockerfile.sh" \
  --hash "${PROFILE_COMPOSITION_HASH}" \
  "${PROFILE_CAPABILITIES}" "${PROFILE_ASSEMBLED_DOCKERFILE}" >/dev/null
export AI_SANDBOX_DOCKERFILE="${PROFILE_ASSEMBLED_DOCKERFILE}"

# --- Phase: assemble docker-compose file list ---
# Each instance has its own generated compose file to avoid cross-instance collisions.
GENERATED_COMPOSE="${XDG_CACHE_HOME:-$HOME/.cache}/ai-sandbox/${SANDBOX_NAME}/docker-compose.generated.yaml"
mkdir -p "$(dirname "${GENERATED_COMPOSE}")"
generate_volume_override "${GENERATED_COMPOSE}"

COMPOSE_FILES="-f ${PROJECT_ROOT}/docker/docker-compose.yaml"
if profile_has_capability chromium; then
  COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_ROOT}/docker/docker-compose.chromium.yaml"
fi

# Host-identity / config overlays only apply in mirror mode. static mode is
# self-contained: no ~/.config overlay is applied (see decisions in task report
# for the V1 scope of static-mode mount suppression).
if [ "${EFFECTIVE_MODE}" = "mirror" ]; then
  # ~/.config handling: either overlay (default, isolates container writes) or
  # passthrough. Kept as separate overlay files so the base compose doesn't
  # have to know about either form and the active choice is obvious from
  # `docker compose config`.
  if [ "$NO_ISOLATE_CONFIG" = "true" ]; then
    COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_ROOT}/docker/docker-compose.shared-config.yaml"
  else
    COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_ROOT}/docker/docker-compose.isolate-config.yaml"
  fi
fi

COMPOSE_FILES="${COMPOSE_FILES} -f ${GENERATED_COMPOSE}"

if [ "${EFFECTIVE_PROXY}" = "true" ]; then
  COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_ROOT}/docker/docker-compose.proxy.yaml"
fi

# Compose project name scopes all containers to this sandbox instance.
COMPOSE_PROJECT="ai-sandbox-${SANDBOX_NAME}"
export COMPOSE_PROJECT

# --- Phase: XQuartz setup (macOS, start/enter only) ---
if { [ "${CMD}" = "start" ] || [ "${CMD}" = "enter" ]; } && [ "$(uname)" = "Darwin" ]; then
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
if [ "${CMD}" = "enter" ] || [ "${CMD}" = "start" ] || [ "${CMD}" = "up" ] || [ "${CMD}" = "build" ] || [ "${CMD}" = "create" ]; then
    resolve_and_download_tools
fi

# --- Phase: command dispatch ---

# For create: provision a new named sandbox instance and exit.
if [ "${CMD}" == "create" ]; then
    do_create || exit $?
    exit 0
fi

if [ "${CMD}" == "start" ] || [ "${CMD}" == "enter" ]; then
    # If a container is already running but its config differs from what this
    # invocation would produce, `compose up -d` will silently recreate it. Ask
    # first so the user can bail or rerun without conflicting flags.
    if is_container_running && ! running_config_matches; then
        confirm_stop_running "stop the running sandbox and recreate it with the requested options" || exit 1
    fi
    ensure_image
    cleanup_stale_container
    docker compose -p "${COMPOSE_PROJECT}" ${COMPOSE_FILES} up -d
    warn_if_ssh_mount_stale

    if [ "${CMD}" == "enter" ]; then
        start_shell
    fi || true
elif [ "${CMD}" == "attach" ] || [ "${CMD}" == "connect" ]; then
    warn_if_ssh_mount_stale
    start_shell
elif [ "${CMD}" == "fix-ssh" ]; then
    fix_ssh || exit 1
elif [ "${CMD}" == "build" ]; then
    do_build
elif [ "${CMD}" == "user-exec" ]; then
    # Compose exec targets the service name (ai-sandbox), not the container name.
    docker compose -p "${COMPOSE_PROJECT}" ${COMPOSE_FILES} exec -u "${HOST_USER}" ai-sandbox "${ARGS[@]}"
elif [ "${CMD}" == "root-exec" ]; then
    docker compose -p "${COMPOSE_PROJECT}" ${COMPOSE_FILES} exec -u root ai-sandbox "${ARGS[@]}"
elif [ "${CMD}" == "status" ]; then
    do_status || exit $?
elif [ "${CMD}" == "stop" ]; then
    if is_container_running; then
        confirm_stop_running "stop the running sandbox" || exit 1
    fi
    docker compose -p "${COMPOSE_PROJECT}" ${COMPOSE_FILES} stop
    qecho "Sandbox '${SANDBOX_NAME}' stopped (container preserved)."

elif [ "${CMD}" == "delete" ]; then
    if is_container_running; then
        confirm_stop_running "stop and delete the running sandbox" || exit 1
    fi
    docker compose -p "${COMPOSE_PROJECT}" ${COMPOSE_FILES} down
    qecho "Sandbox '${SANDBOX_NAME}' deleted."

elif [ "${CMD}" == "clean" ]; then
    if is_container_running; then
        confirm_stop_running "stop and delete the running sandbox" || exit 1
    fi
    docker compose -p "${COMPOSE_PROJECT}" ${COMPOSE_FILES} down
    # Remove the container by its explicit name in case compose down left it.
    docker rm -f "$(sandbox_container_name)" 2>/dev/null || true
    # Remove all ai-sandbox:* variant images. Images are shared across instances
    # (keyed by composition hash), so all-images cleanup is intentional here.
    IMAGES=$(docker images --format '{{.Repository}}:{{.Tag}}' \
        | awk -F: '$1 == "ai-sandbox" {print}' || true)
    if [ -n "${IMAGES}" ]; then
        # shellcheck disable=SC2086 # intentional word-splitting across tags
        docker image rm -f ${IMAGES} >/dev/null 2>&1 || true
        if [ $QUIET -ne 0 ]; then
            echo "deleted images:"
            printf '  %s\n' ${IMAGES}
        fi
    fi
else
    docker compose -p "${COMPOSE_PROJECT}" ${COMPOSE_FILES} "${ARGS[@]}"
fi
