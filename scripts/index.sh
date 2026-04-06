#!/bin/bash
# shellcheck disable=SC2086 # we want word splitting for 'COMPOSE_FILES'

set -euo pipefail

source ./utils.sh

# --- Function definitions (testable via Include) ---

function check_docker() {
    qecho -n "Checking docker is running... "
    if ! docker info > /dev/null 2>&1; then
        if [ "${1:-}" != "" ]; then
            qecho "$1"
        else
            qecho "NOT running."
        fi
        return 1
    fi
    qecho "confirmed."
    return 0
}

function download_tool() {
    local url=$1
    local file=$2
    if [ ! -f "${TOOL_CACHE_DIR}/${file}" ]; then
        qecho "Downloading ${file}..."
        if [ ${QUIET} -eq 0 ]; then
            curl -f -SL "${url}" -o "${TOOL_CACHE_DIR}"/"${file}"
        else
            curl --progress-bar -f -SL "${url}" -o "${TOOL_CACHE_DIR}"/"${file}"
        fi
    else
        qecho "${file} already exists, skipping download"
    fi
}

function start_shell() {
    docker compose ${COMPOSE_FILES} exec -u "${HOST_USER}" ai-sandbox bash -c \
        "if [ -d \"${START_DIR}\" ]; then cd \"${START_DIR}\" && exec zsh; else exec zsh; fi"
}

function do_build() {
    docker compose ${COMPOSE_FILES} build --ssh "default=${SSH_AUTH_SOCK}"
}

function ensure_image() {
    if [ -z "$(docker compose ${COMPOSE_FILES} images -q ai-sandbox 2>/dev/null)" ]; then
        qecho "Image not found, building..."
        do_build
    fi
}

function cleanup_stale_container() {
    local state
    state=$(docker inspect -f '{{.State.Status}}' ai-sandbox 2>/dev/null) || return 0
    if [ "$state" = "running" ]; then
        return 0
    fi
    qecho "Cleaning up stale container (state: ${state})..."
    docker compose ${COMPOSE_FILES} down 2>/dev/null || docker rm -f ai-sandbox 2>/dev/null || true
}

${__SOURCED__:+return}

CMD=""

# Parse --no-chromium flag
NO_CHROMIUM=false
ARGS=()
for arg in "$@"; do
  if [ "$arg" == "--no-chromium" ]; then
    NO_CHROMIUM=true
  elif [ "$arg" == "--quiet" ] || [ "$arg" == "-q" ]; then
    QUIET=0
  elif [ -z "${CMD}" ]; then
    CMD=${arg:-"enter"}
  else
    ARGS+=("$arg")
  fi
done

CMD=${CMD:-"enter"}

if [ -z "${QUIET}" ]; then
    if [ "${CMD}" == "status" ]; then
        QUIET=0 # bash true
    else
        QUIET=1 # bash false
    fi
fi
export QUIET

# --- Execution code ---

if [ "${CMD}" != "check-settings" ] && ! check_docker "starting..."; then
    docker desktop start
    check_docker "bailing out." || exit 1
fi

# Resolve symlinks to find the actual script directory
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    # If SOURCE was a relative symlink, resolve it relative to the symlink's directory
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

# Ensure claude-mem is configured for container access
if [ -z "${CMD}" ] || [ "${CMD}" == "start" ] || [ "${CMD}" == "build" ]; then
    check_settings
fi

# Check if claude-mem is running on the host (would cause database corruption if container also runs it)
if { [ -z "${CMD}" ] || [ "${CMD}" == "start" ]; } && claude-mem status 2>/dev/null | grep -q "is running"; then
    echo ""
    echo "WARNING: claude-mem is currently running on the host."
    echo "Running claude-mem in both the host and container can cause database corruption."
    echo ""
    echo "Please:"
    echo "  1. Exit any Claude Code sessions on the host"
    echo "  2. Run 'claude-mem stop' to stop the host instance"
    echo "  3. Then run this script again"
    echo ""
    exit 1
fi

# Validate --no-chromium only used with commands that may build
if [ "$NO_CHROMIUM" = "true" ] && [ -n "$CMD" ] && [ "$CMD" != "build" ]; then
  echo "Error: --no-chromium can only be used with 'build' command" 1>&2
  exit 1
fi

# Set compose files (Chromium is included by default)
if [ "$NO_CHROMIUM" = "true" ]; then
  COMPOSE_FILES="-f ${SCRIPT_DIR}/docker/docker-compose.yaml"
else
  COMPOSE_FILES="-f ${SCRIPT_DIR}/docker/docker-compose.yaml -f ${SCRIPT_DIR}/docker/docker-compose.chromium.yaml"
fi

# XQuartz setup for macOS (required for GUI apps in container)
if { [ -z "${CMD}" ] || [ "${CMD}" == "start" ]; } && [ "$(uname)" = "Darwin" ]; then
    if ! pgrep -xi "XQuartz" > /dev/null; then
        if [ -d "/Applications/Utilities/XQuartz.app" ]; then
            qecho "XQuartz is installed but not running."
            read -rp "Start XQuartz now? (y/n): " start_xquartz
            if [ "$start_xquartz" = "y" ]; then
                open -a XQuartz
                qecho "Waiting for XQuartz to start..."
                sleep 3
                xhost +localhost 2>/dev/null || echo "Run 'xhost +localhost' manually after XQuartz fully loads" 1>&2
            fi
        else
            echo "XQuartz is not installed. GUI apps require XQuartz on macOS."
            read -rp "Install XQuartz via Homebrew? (y/n): " install_xquartz
            if [ "$install_xquartz" = "y" ]; then
                brew install --cask xquartz
                echo "XQuartz installed. Please:"
                echo "  1. Open XQuartz"
                echo "  2. Go to Preferences > Security"
                echo "  3. Enable 'Allow connections from network clients'"
                echo "  4. Restart XQuartz"
                echo "  5. Run this script again"
                exit 0
            fi
        fi
    else
        # XQuartz is running, ensure xhost is configured
        xhost +localhost 2>/dev/null
    fi
fi

# define easy/quick vars
export HOST_USER=${USER}

# Capture current directory for use when starting shell in container
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

if [ -z "${CMD}" ] || [ "${CMD}" == "enter" ] || [ "${CMD}" == "start" ] || [ "${CMD}" == "up" ] || [ "${CMD}" == "build" ]; then
    # The dynamic queries can fail due to rate limiting, network issues, etc.; if so, then we default to the most recent
    # cached version. Fallbacks use basename to isolate the filename before parsing, so they work regardless of the cache path.
    # shellcheck disable=SC2012 # ls with sort -V is intentional for version-sorted cache lookups
    BUN_VERSION=$(curl -fsL https://api.github.com/repos/oven-sh/bun/releases/latest | jq -r .name | cut -d' ' -f2 || \
        basename "$(ls -1 "${TOOL_CACHE_DIR}"/bun-install-*.sh | sort -V | tail -n1)" .sh | sed 's/bun-install-//')
    export BUN_VERSION
    # shellcheck disable=SC2012 # ls with sort -V is intentional for version-sorted cache lookups
    GIT_DELTA_VERSION=$(curl -fsL https://api.github.com/repos/dandavison/delta/releases/latest | jq -r .name || \
        basename "$(ls -1 "${TOOL_CACHE_DIR}"/git-delta_*_${HOST_ARCH}.deb | sort -V | tail -n1)" | cut -d'_' -f2)
    export GIT_DELTA_VERSION
    # shellcheck disable=SC2012 # ls with sort -V is intentional for version-sorted cache lookups
    GO_VERSION=$(curl -fsL https://go.dev/dl/?mode=json | jq -r '.[0].version' || \
        basename "$(ls -1 "${TOOL_CACHE_DIR}"/go*.linux-${HOST_ARCH}.tar.gz | sort -V | tail -n1)" .linux-${HOST_ARCH}.tar.gz)
    export GO_VERSION
    # shellcheck disable=SC2012 # ls with sort -V is intentional for version-sorted cache lookups
    NVM_VERSION=$(curl -fsL https://api.github.com/repos/nvm-sh/nvm/releases/latest | jq -r .name || \
        basename "$(ls -1 "${TOOL_CACHE_DIR}"/nvm-install-*.sh | sort -V | tail -n1)" .sh | sed 's/nvm-install-//')
    export NVM_VERSION
    # shellcheck disable=SC2012 # ls with sort -V is intentional for version-sorted cache lookups
    ZSH_IN_DOCKER_VERSION=$(curl -fsL https://api.github.com/repos/deluan/zsh-in-docker/releases/latest | jq -r .name || \
        basename "$(ls -1 "${TOOL_CACHE_DIR}"/zsh-in-docker-*.sh | sort -V | tail -n1)" .sh | sed 's/zsh-in-docker-//')
    export ZSH_IN_DOCKER_VERSION
    # shellcheck disable=SC2012 # ls with sort -V is intentional for version-sorted cache lookups
    S6_OVERLAY_VERSION=$(curl -fsL https://api.github.com/repos/just-containers/s6-overlay/releases/latest | jq -r .tag_name | sed 's/^v//' || \
        basename "$(ls -1 "${TOOL_CACHE_DIR}"/s6-overlay-noarch-*.tar.xz | sort -V | tail -n1)" | sed 's/s6-overlay-noarch-\(.*\)\.tar\.xz/\1/')
    export S6_OVERLAY_VERSION

    # Download tools; for some reason this can be really slow when run from the Dockerfile, so we do it here; this also
    # caches the files, which is useful for development and other edge cases
    export S6_NOARCH_TAR=s6-overlay-noarch-${S6_OVERLAY_VERSION}.tar.xz
    # Map HOST_ARCH to s6-overlay naming convention (arm64 -> aarch64)
    S6_ARCH=$([[ "$HOST_ARCH" == "arm64" ]] && echo "aarch64" || echo "$HOST_ARCH")
    export S6_ARCH_TAR=s6-overlay-${S6_ARCH}-${S6_OVERLAY_VERSION}.tar.xz
    export GO_TAR=${GO_VERSION}.linux-${HOST_ARCH}.tar.gz
    export GIT_DELTA_DEB=git-delta_${GIT_DELTA_VERSION}_${HOST_ARCH}.deb
    export NVM_INSTALL_SH=nvm-install-${NVM_VERSION}.sh
    export BUN_INSTALL_SH=bun-install-${BUN_VERSION}.sh
    export ZSH_IN_DOCKER_SH=zsh-in-docker-${ZSH_IN_DOCKER_VERSION}.sh

    download_tool "https://go.dev/dl/${GO_TAR}" "${GO_TAR}"
    download_tool "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/${GIT_DELTA_DEB}" "${GIT_DELTA_DEB}"
    download_tool "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" "${NVM_INSTALL_SH}"
    download_tool "https://bun.com/install" "${BUN_INSTALL_SH}"
    download_tool "https://github.com/deluan/zsh-in-docker/releases/download/${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh" "${ZSH_IN_DOCKER_SH}"
    download_tool "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" "${S6_NOARCH_TAR}"
    download_tool "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" "${S6_ARCH_TAR}"

    # Copy .claude.json into build context (Docker COPY can't access files outside context)
    cp ${HOST_HOME}/.claude.json ${TOOL_CACHE_DIR}/.claude.json
fi

function start_shell() {
    docker compose ${COMPOSE_FILES} exec -u ${HOST_USER} ai-sandbox bash -c \
        "if [ -d \"${START_DIR}\" ]; then cd \"${START_DIR}\" && exec zsh; else exec zsh; fi"
}

function ensure_image() {
    if [ -z "$(docker compose ${COMPOSE_FILES} images -q ai-sandbox 2>/dev/null)" ]; then
        echo "Image not found, building..."
        docker compose ${COMPOSE_FILES} build --ssh default=${SSH_AUTH_SOCK}
    fi
}

function cleanup_stale_container() {
    local state
    state=$(docker inspect --format '{{.State.Status}}' ai-sandbox 2>/dev/null) || return 0
    if [ "$state" != "running" ]; then
        echo "Removing stale container (state: ${state})..."
        docker compose ${COMPOSE_FILES} down 2>/dev/null || docker rm -f ai-sandbox
    fi
}

# Default: enter the sandbox (build if needed, start if needed, connect)
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
elif [ "${CMD}" == "check-settings" ]; then
    check_settings
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
