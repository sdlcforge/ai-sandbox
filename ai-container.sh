#!/bin/bash

set -euo pipefail

CMD=${1:-start}

export TOOL_CACHE_DIR=./.tool-cache
mkdir -p ${TOOL_CACHE_DIR}

export HOST_ARCH=$(uname -m)
export HOST_HOME=${HOME}
export HOST_TZ=$(date +%Z)
export HOST_USER=${USER}

export BUN_VERSION=$(curl -sL https://api.github.com/repos/oven-sh/bun/releases/latest | jq -r .name | cut -d' ' -f2)
export GIT_DELTA_VERSION=$(curl -sL https://api.github.com/repos/dandavison/delta/releases/latest | jq -r .name)
export GO_VERSION=$(curl -sL https://go.dev/dl/?mode=json | jq -r '.[0].version')
export NVM_VERSION=$(curl -sL https://api.github.com/repos/nvm-sh/nvm/releases/latest | jq -r .name)
export ZSH_IN_DOCKER_VERSION=$(curl -sL https://api.github.com/repos/deluan/zsh-in-docker/releases/latest | jq -r .name)

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
else
    docker compose "$@"
fi
