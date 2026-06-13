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

# --- Phase: create-profile short-circuit (no docker needed) ---
if [ "${CMD}" == "create-profile" ]; then
    create_profile "${ARGS[@]}" || exit 1
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

# --- Phase: auto-promote bare invocation to `connect` ---
# If the user invoked bare `ai-sandbox` (no command, no config-changing flags)
# and a container is already running, treat it as `connect` so we never stop a
# sandbox the user didn't explicitly target. This must run before the
# plugin-conflict preflight (which would otherwise fire on the default `enter`).
if [ "${CMD_EXPLICIT}" != "true" ] \
    && [ "${CONFIG_FLAGS_PROVIDED}" != "true" ] \
    && is_container_running; then
  CMD="connect"
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
GENERATED_COMPOSE="${XDG_CACHE_HOME:-$HOME/.cache}/ai-sandbox/docker-compose.generated.yaml"
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
    # If a container is already running but its config differs from what this
    # invocation would produce, `compose up -d` will silently recreate it. Ask
    # first so the user can bail or rerun without conflicting flags.
    if is_container_running && ! running_config_matches; then
        confirm_stop_running "stop the running sandbox and recreate it with the requested options" || exit 1
    fi
    ensure_image
    cleanup_stale_container
    docker compose ${COMPOSE_FILES} up -d
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
    docker compose ${COMPOSE_FILES} exec -u "${HOST_USER}" ai-sandbox "${ARGS[@]}"
elif [ "${CMD}" == "root-exec" ]; then
    docker compose ${COMPOSE_FILES} exec -u root ai-sandbox "${ARGS[@]}"
elif [ "${CMD}" == "status" ]; then
    do_status || exit $?
elif [ "${CMD}" == "stop" ] || [ "${CMD}" == "clean" ]; then
    if is_container_running; then
        confirm_stop_running "stop the running sandbox" || exit 1
    fi
    docker compose ${COMPOSE_FILES} down
    if [ "${CMD}" == "clean" ]; then
        OUTPUT=$(docker rm -f ai-sandbox || true)
        if [ $QUIET -ne 0 ] && [ "${OUTPUT}" == "ai-sandbox" ]; then
            echo "deleted '${OUTPUT}'"
        fi
        # Remove all ai-sandbox:* variant images.
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
    fi
else
    docker compose ${COMPOSE_FILES} "${ARGS[@]}"
fi
