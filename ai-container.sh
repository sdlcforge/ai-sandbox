#!/bin/bash

set -euo pipefail

function check_docker() {
    echo -n "Checking docker is running... "
    if ! docker info > /dev/null 2>&1; then
        echo "NOT running; bailing out."
        return 1
    fi
    echo "confirmed."
    return 0
}

if ! check_docker; then
    docker desktop start
    check_docker || exit 1
fi

# Ensure claude-mem is configured for container access
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/scripts/check-claude-mem-settings.sh"

CMD=${1:-start}

# XQuartz setup for macOS (required for GUI apps in container)
if [ "$(uname)" = "Darwin" ]; then
    if ! pgrep -xi "XQuartz" > /dev/null; then
        if [ -d "/Applications/Utilities/XQuartz.app" ]; then
            echo "XQuartz is installed but not running."
            read -p "Start XQuartz now? (y/n): " start_xquartz
            if [ "$start_xquartz" = "y" ]; then
                open -a XQuartz
                echo "Waiting for XQuartz to start..."
                sleep 3
                xhost +localhost 2>/dev/null || echo "Run 'xhost +localhost' after XQuartz fully loads"
            fi
        else
            echo "XQuartz is not installed. GUI apps require XQuartz on macOS."
            read -p "Install XQuartz via Homebrew? (y/n): " install_xquartz
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

export TOOL_CACHE_DIR=./.tool-cache
mkdir -p ${TOOL_CACHE_DIR}

export HOST_ARCH=$(uname -m)
export HOST_HOME=${HOME}
export HOST_TZ=$(date +%Z)
export HOST_USER=${USER}

export GIT_USER_NAME="$(git config --global user.name)"
export GIT_USER_EMAIL="$(git config --global user.email)"

# The dynamic queries can fail due to rate limiting, network issues, etc.; if so, then we defealut to the most recent
#cached version.
# Note, many of he cut fields uisng '-' are offset by 1 because of the '-' in the '.tool-cache' directory name.
export BUN_VERSION=$(curl -fsL https://api.github.com/repos/oven-sh/bun/releases/latest | jq -r .name | cut -d' ' -f2 || \
    basename $(ls -1 .tool-cache/bun-install-*.sh | sort -V | tail -n1 | cut -d'-' -f4) '.sh')
export GIT_DELTA_VERSION=$(curl -fsL https://api.github.com/repos/dandavison/delta/releases/latest | jq -r .name || \
    ls -1 .tool-cache/git-delta_*_${HOST_ARCH}.deb | sort -V | tail -n1 | cut -d'_' -f2)
export GO_VERSION=$(curl -fsL https://go.dev/dl/?mode=json | jq -r '.[0].version' || \
    basename $(ls -1 .tool-cache/go*.linux-${HOST_ARCH}.tar.gz | sort -V | tail -n1 | cut -d'-' -f2) '.linux')
export NVM_VERSION=$(curl -fsL https://api.github.com/repos/nvm-sh/nvm/releases/latest | jq -r .name || \
    basename $(ls -1 .tool-cache/nvm-install-*.sh | sort -V | tail -n1 | cut -d'-' -f4) '.sh')
export ZSH_IN_DOCKER_VERSION=$(curl -fsL https://api.github.com/repos/deluan/zsh-in-docker/releases/latest | jq -r .name || \
    basename $(ls -1 .tool-cache/zsh-in-docker-*.sh | sort -V | tail -n1 | cut -d'-' -f5) '.sh')

# Download tools; for some reason this can be really slow when run from the Dockerfile, so we do it here; this also
# caches the files, which is useful for development and other edge cases
export GO_TAR=${GO_VERSION}.linux-${HOST_ARCH}.tar.gz
export GIT_DELTA_DEB=git-delta_${GIT_DELTA_VERSION}_${HOST_ARCH}.deb
export NVM_INSTALL_SH=nvm-install-${NVM_VERSION}.sh
export BUN_INSTALL_SH=bun-install-${BUN_VERSION}.sh
export ZSH_IN_DOCKER_SH=zsh-in-docker-${ZSH_IN_DOCKER_VERSION}.sh

export DOCKER_DEFAULT_PLATFORM=linux/${HOST_ARCH}

function download_tool() {
    local url=$1
    local file=$2
    if [ ! -f "${TOOL_CACHE_DIR}/${file}" ]; then
        echo "Downloading ${file}..."
        curl --progress-bar -f -SL ${url} -o ${TOOL_CACHE_DIR}/${file}
    else
        echo "${file} already exists, skipping download"
    fi
}

if [ "${CMD}" == "up" ] || [ "${CMD}" == "start" ] || [ "${CMD}" == "build" ]; then
    download_tool "https://go.dev/dl/${GO_TAR}" "${GO_TAR}"
    download_tool "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/${GIT_DELTA_DEB}" "${GIT_DELTA_DEB}"
    download_tool "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" "${NVM_INSTALL_SH}"
    download_tool "https://bun.com/install" "${BUN_INSTALL_SH}"
    download_tool "https://github.com/deluan/zsh-in-docker/releases/download/${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh" "${ZSH_IN_DOCKER_SH}"

    # Copy .claude.json into build context (Docker COPY can't access files outside context)
    cp ${HOST_HOME}/.claude.json ${TOOL_CACHE_DIR}/.claude.json

    # ALPHABET="abcdefghijklmnopqrstuvwxyz"
    # ID_LEN=4
    #CONTAINER_ID=""
    #
    # for i in $(seq 1 ${ID_LEN}); do
    #     CHAR="${ALPHABET:$(( RANDOM % ${#ALPHABET} )):1}"
    #     CONTAINER_ID="${CONTAINER_ID}${CHAR}"
    # done

    # docker compose --project-name ai-sandbox-${CONTAINER_ID} up
fi

if [ "${CMD}" == "start" ]; then
    docker compose up -d
    docker compose exec ai-sandbox zsh
elif [ "${CMD}" == "attach" ] || [ "${CMD}" == "connect" ]; then
    docker compose exec ai-sandbox zsh
elif [ "${CMD}" == "build" ]; then
    docker compose build --ssh default=${SSH_AUTH_SOCK}
else
    docker compose "$@"
fi
