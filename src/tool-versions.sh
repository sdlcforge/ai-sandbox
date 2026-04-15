# shellcheck shell=bash
# shellcheck disable=SC2012 # ls with sort -V is intentional for version-sorted cache lookups
# shellcheck disable=SC2086 # ${HOST_ARCH} word splitting is harmless and preserved from the original

# Resolve current upstream versions for each tool we install into the image, then
# download (and cache) the install scripts/tarballs. Each curl falls back to the
# most recent cached version on failure (rate-limit, offline, etc.). Exports the
# *_VERSION and *_TAR/*_DEB/*_SH names that the Dockerfile build expects.
function resolve_and_download_tools() {
    BUN_VERSION=$(curl -fsL https://api.github.com/repos/oven-sh/bun/releases/latest | jq -r .name | cut -d' ' -f2 || \
        basename "$(ls -1 "${TOOL_CACHE_DIR}"/bun-install-*.sh | sort -V | tail -n1)" .sh | sed 's/bun-install-//')
    export BUN_VERSION
    GIT_DELTA_VERSION=$(curl -fsL https://api.github.com/repos/dandavison/delta/releases/latest | jq -r .name || \
        basename "$(ls -1 "${TOOL_CACHE_DIR}"/git-delta_*_${HOST_ARCH}.deb | sort -V | tail -n1)" | cut -d'_' -f2)
    export GIT_DELTA_VERSION
    GO_VERSION=$(curl -fsL https://go.dev/dl/?mode=json | jq -r '.[0].version' || \
        basename "$(ls -1 "${TOOL_CACHE_DIR}"/go*.linux-${HOST_ARCH}.tar.gz | sort -V | tail -n1)" .linux-${HOST_ARCH}.tar.gz)
    export GO_VERSION
    NVM_VERSION=$(curl -fsL https://api.github.com/repos/nvm-sh/nvm/releases/latest | jq -r .name || \
        basename "$(ls -1 "${TOOL_CACHE_DIR}"/nvm-install-*.sh | sort -V | tail -n1)" .sh | sed 's/nvm-install-//')
    export NVM_VERSION
    ZSH_IN_DOCKER_VERSION=$(curl -fsL https://api.github.com/repos/deluan/zsh-in-docker/releases/latest | jq -r .name || \
        basename "$(ls -1 "${TOOL_CACHE_DIR}"/zsh-in-docker-*.sh | sort -V | tail -n1)" .sh | sed 's/zsh-in-docker-//')
    export ZSH_IN_DOCKER_VERSION
    GOLANGCI_LINT_VERSION=$(curl -fsL https://api.github.com/repos/golangci/golangci-lint/releases/latest | jq -r .name || \
        basename "$(ls -1 "${TOOL_CACHE_DIR}"/golangci-lint-install-*.sh | sort -V | tail -n1)" .sh | sed 's/golangci-lint-install-//')
    export GOLANGCI_LINT_VERSION
    S6_OVERLAY_VERSION=$(curl -fsL https://api.github.com/repos/just-containers/s6-overlay/releases/latest | jq -r .tag_name | sed 's/^v//' || \
        basename "$(ls -1 "${TOOL_CACHE_DIR}"/s6-overlay-noarch-*.tar.xz | sort -V | tail -n1)" | sed 's/s6-overlay-noarch-\(.*\)\.tar\.xz/\1/')
    export S6_OVERLAY_VERSION

    export S6_NOARCH_TAR=s6-overlay-noarch-${S6_OVERLAY_VERSION}.tar.xz
    # Map HOST_ARCH to s6-overlay naming convention (arm64 -> aarch64)
    S6_ARCH=$([[ "$HOST_ARCH" == "arm64" ]] && echo "aarch64" || echo "$HOST_ARCH")
    export S6_ARCH_TAR=s6-overlay-${S6_ARCH}-${S6_OVERLAY_VERSION}.tar.xz
    export GO_TAR=${GO_VERSION}.linux-${HOST_ARCH}.tar.gz
    export GIT_DELTA_DEB=git-delta_${GIT_DELTA_VERSION}_${HOST_ARCH}.deb
    export GOLANGCI_LINT_INSTALL_SH=golangci-lint-install-${GOLANGCI_LINT_VERSION}.sh
    export NVM_INSTALL_SH=nvm-install-${NVM_VERSION}.sh
    export BUN_INSTALL_SH=bun-install-${BUN_VERSION}.sh
    export ZSH_IN_DOCKER_SH=zsh-in-docker-${ZSH_IN_DOCKER_VERSION}.sh

    download_tool "https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh" "${GOLANGCI_LINT_INSTALL_SH}"
    download_tool "https://go.dev/dl/${GO_TAR}" "${GO_TAR}"
    download_tool "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/${GIT_DELTA_DEB}" "${GIT_DELTA_DEB}"
    download_tool "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" "${NVM_INSTALL_SH}"
    download_tool "https://bun.com/install" "${BUN_INSTALL_SH}"
    download_tool "https://github.com/deluan/zsh-in-docker/releases/download/${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh" "${ZSH_IN_DOCKER_SH}"
    download_tool "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" "${S6_NOARCH_TAR}"
    download_tool "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" "${S6_ARCH_TAR}"

    # Copy .claude.json into build context (Docker COPY can't access files outside context)
    cp ${HOST_HOME}/.claude.json ${TOOL_CACHE_DIR}/.claude.json
}
