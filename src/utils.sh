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

function build_marker_path() {
    printf '%s/.last-built\n' "${TOOL_CACHE_DIR}"
}

# Print the value of LABEL <key> on image ai-sandbox, or empty if the image or
# label is missing. Stderr is suppressed.
function image_label() {
    local key="$1"
    docker inspect --format="{{index .Config.Labels \"${key}\"}}" ai-sandbox 2>/dev/null || true
}

# Return 0 (changed) if the requested build-config flags (NO_CHROMIUM, NO_DOCKER)
# disagree with the corresponding labels on the existing ai-sandbox image.
# Returns 1 (unchanged) if the image is missing (nothing to compare) or all
# labels match. Uses NO_CHROMIUM / NO_DOCKER from caller scope.
function build_config_changed() {
    local chromium_label docker_label want_chromium want_docker
    chromium_label="$(image_label ai.sandbox.chromium-enabled)"
    docker_label="$(image_label ai.sandbox.docker-enabled)"
    # No labels at all → image doesn't exist or predates labeling; don't force
    # rebuild on that basis (the image-existence / mtime checks handle that).
    if [ -z "${chromium_label}" ] && [ -z "${docker_label}" ]; then
        return 1
    fi
    want_chromium=$([ "${NO_CHROMIUM:-false}" = "true" ] && echo false || echo true)
    want_docker=$([ "${NO_DOCKER:-false}" = "true" ] && echo false || echo true)
    if [ -n "${chromium_label}" ] && [ "${chromium_label}" != "${want_chromium}" ]; then
        return 0
    fi
    if [ -n "${docker_label}" ] && [ "${docker_label}" != "${want_docker}" ]; then
        return 0
    fi
    return 1
}

# Return 0 (stale) if any file under docker/ is newer than the marker, the
# marker is missing, or the image's build-config labels disagree with the
# current flag selection. Return 1 (fresh) otherwise.
function is_build_stale() {
    local marker newer
    marker="$(build_marker_path)"
    [ -f "${marker}" ] || return 0
    newer="$(find "${PROJECT_ROOT}/docker" -type f -newer "${marker}" -print -quit 2>/dev/null)"
    if [ -n "${newer}" ]; then
        return 0
    fi
    build_config_changed
}

function ensure_image() {
    if [ -z "$(docker compose ${COMPOSE_FILES} images -q ai-sandbox 2>/dev/null)" ]; then
        qecho "Image not found, building..."
        do_build
    elif is_build_stale; then
        qecho "Build inputs changed since last build, rebuilding..."
        do_build
    fi
}

function do_build() {
    docker compose ${COMPOSE_FILES} build --ssh "default=${SSH_AUTH_SOCK}"
    touch "$(build_marker_path)"
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
