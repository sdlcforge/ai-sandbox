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

# Echoes a stable key identifying the current build-option combination. Used as
# the Docker image tag so each distinct option set gets its own image. Reads
# NO_CHROMIUM / NO_DOCKER from caller scope.
function variant_key() {
    local parts=""
    [ "${NO_CHROMIUM:-false}" = "true" ] && parts="${parts}${parts:+-}no-chromium"
    [ "${NO_DOCKER:-false}" = "true" ] && parts="${parts}${parts:+-}no-docker"
    printf '%s\n' "${parts:-full}"
}

function variant_image_tag() {
    printf 'ai-sandbox:%s\n' "$(variant_key)"
}

# Return 0 (stale) if the variant image is missing or any file under docker/ is
# newer than its creation timestamp. Return 1 (fresh) otherwise.
function is_build_stale() {
    local tag created tmp newer
    tag="$(variant_image_tag)"
    created="$(docker image inspect --format='{{.Created}}' "${tag}" 2>/dev/null)" || return 0
    tmp="$(mktemp)"
    # touch -d accepts ISO 8601 on macOS (BSD) and Linux (GNU). On failure,
    # treat as stale to force a rebuild rather than silently skipping.
    if ! touch -d "${created}" "${tmp}" 2>/dev/null; then
        rm -f "${tmp}"
        return 0
    fi
    newer="$(find "${PROJECT_ROOT}/docker" -type f -newer "${tmp}" -print -quit 2>/dev/null)"
    rm -f "${tmp}"
    [ -n "${newer}" ]
}

function ensure_image() {
    if ! docker image inspect "$(variant_image_tag)" >/dev/null 2>&1; then
        qecho "Image not found, building..."
        do_build
    elif is_build_stale; then
        qecho "Build inputs changed since last build, rebuilding..."
        do_build
    fi
}

function do_build() {
    docker image rm -f "$(variant_image_tag)" >/dev/null 2>&1 || true
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
