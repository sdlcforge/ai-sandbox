# shellcheck shell=bash
# shellcheck disable=SC2086 # we want word splitting for 'COMPOSE_FILES'

export QUIET=1 # default — overridden by parse_options

function qecho() {
    if [ ${QUIET} -ne 0 ]; then echo "$@"; fi
}

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
    docker compose ${COMPOSE_FILES} exec -u ${HOST_USER} ai-sandbox bash -c \
        "if [ -d \"${START_DIR}\" ]; then cd \"${START_DIR}\" && exec zsh; else exec zsh; fi"
}

function ensure_image() {
    if [ -z "$(docker compose ${COMPOSE_FILES} images -q ai-sandbox 2>/dev/null)" ]; then
        qecho "Image not found, building..."
        do_build
    fi
}

function do_build() {
    docker compose ${COMPOSE_FILES} build --ssh "default=${SSH_AUTH_SOCK}"
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

# List installed claude plugin names (without @marketplace suffix), one per line.
# Returns nothing if the installed_plugins.json manifest is missing.
function list_installed_plugins() {
    local manifest="${HOME}/.claude/plugins/installed_plugins.json"
    if [ ! -f "${manifest}" ]; then
        return 0
    fi
    jq -r '.plugins // {} | keys[]' "${manifest}" 2>/dev/null \
        | sed -E 's/@[^@]+$//' \
        | sort -u
}
