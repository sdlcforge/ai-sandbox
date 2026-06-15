# shellcheck shell=bash
# shellcheck disable=SC2086 # we want word splitting for 'COMPOSE_FILES'

export QUIET=1 # default — overridden by parse_options

function qecho() {
    if [ ${QUIET} -ne 0 ]; then echo "$@"; fi
}

# Returns the container name for the current SANDBOX_NAME.
# All docker inspect / docker rm -f calls that target the running container
# must use this helper rather than the literal string 'ai-sandbox'.
function sandbox_container_name() {
    printf 'ai-sandbox-%s\n' "${SANDBOX_NAME}"
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
    # Warn the user when they're entering a container with host-Docker access
    # enabled. DOCKER_HOST is only set inside the container when the proxy
    # overlay is in play (see docker-compose.proxy.yaml), so it doubles as a
    # runtime detector.
    # shellcheck disable=SC2016 # ${DOCKER_HOST} must be expanded by the in-container shell, not the host
    local banner='if [ -n "${DOCKER_HOST:-}" ]; then printf "\033[1;33m%s\033[0m\n" "WARNING: This container is running with docker support activated. This gives the container access to docker on the host and it may be possible for the AI or another program to breakout of the container via this access." >&2; fi; '
    # 'ai-sandbox' here is the compose service name, not the container name.
    docker compose ${COMPOSE_FILES} exec -u ${HOST_USER} ai-sandbox bash -c \
        "${banner}if [ -d \"${START_DIR}\" ]; then cd \"${START_DIR}\" && exec zsh; else exec zsh; fi"
}

# Return 0 if the ai-sandbox container exists (running or stopped), 1 otherwise.
function is_container_running_or_stopped() {
    docker inspect "$(sandbox_container_name)" >/dev/null 2>&1
}

# Return 0 if the ai-sandbox container is currently in `running` state, 1 otherwise.
function is_container_running() {
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$(sandbox_container_name)" 2>/dev/null) || return 1
    [ "${state}" = "running" ]
}

# Return 0 if the named capability is present in PROFILE_CAPABILITIES (a
# space-separated list), 1 otherwise. Matches whole tokens, not substrings.
# $1 — capability name to test for.
function profile_has_capability() {
    local want="$1" cap
    for cap in ${PROFILE_CAPABILITIES:-}; do
        [ "${cap}" = "${want}" ] && return 0
    done
    return 1
}

# Return 0 if the running container's image + config-relevant labels match the
# current invocation's composition, 1 if they differ, 2 if no container is
# running. Reads AI_SANDBOX_IMAGE_TAG / PROFILE_COMPOSITION_HASH / EFFECTIVE_MODE
# / NO_ISOLATE_CONFIG / EFFECTIVE_PROXY from caller scope.
function running_config_matches() {
    is_container_running || return 2
    local cur_image cur_hash cur_mode cur_no_isolate cur_proxy ctr_name
    ctr_name="$(sandbox_container_name)"
    cur_image=$(docker inspect -f '{{.Config.Image}}' "${ctr_name}" 2>/dev/null || true)
    cur_hash=$(docker inspect -f '{{index .Config.Labels "ai.sandbox.profile-hash"}}' "${ctr_name}" 2>/dev/null || true)
    cur_mode=$(docker inspect -f '{{index .Config.Labels "ai.sandbox.mode"}}' "${ctr_name}" 2>/dev/null || true)
    cur_no_isolate=$(docker inspect -f '{{index .Config.Labels "ai.sandbox.no-isolate-config"}}' "${ctr_name}" 2>/dev/null || true)
    cur_proxy=$(docker inspect -f '{{index .Config.Labels "ai.sandbox.docker-proxy"}}' "${ctr_name}" 2>/dev/null || true)
    cur_clean=$(docker inspect -f '{{index .Config.Labels "ai.sandbox.clean-slate"}}' "${ctr_name}" 2>/dev/null || true)
    [ "${cur_image}" = "${AI_SANDBOX_IMAGE_TAG:-}" ] || return 1
    [ "${cur_hash}" = "${PROFILE_COMPOSITION_HASH:-}" ] || return 1
    [ "${cur_mode:-mirror}" = "${EFFECTIVE_MODE:-mirror}" ] || return 1
    [ "${cur_no_isolate:-false}" = "${NO_ISOLATE_CONFIG:-false}" ] || return 1
    [ "${cur_proxy:-false}" = "${EFFECTIVE_PROXY:-false}" ] || return 1
    [ "${cur_clean:-false}" = "${AI_SANDBOX_CLEAN_SLATE:-false}" ] || return 1
    return 0
}

# Prompt the user to confirm a destructive action that would stop the running
# container. Returns 0 on confirmation, 1 on rejection. Auto-confirms when
# AUTO_YES is set or when stdin is not a TTY (scripted/test environments).
# $1 — short reason shown in the prompt, e.g. "stopping the running sandbox"
function confirm_stop_running() {
    local reason="${1:-stopping the running sandbox}"
    if [ "${AUTO_YES:-false}" = "true" ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        return 0
    fi
    local answer
    printf 'About to %s. Continue? [y/N] ' "${reason}" >&2
    read -r answer || answer=""
    case "${answer}" in
        y|Y|yes|YES) return 0 ;;
        *) echo "Aborted." >&2; return 1 ;;
    esac
}

# Echoes the image-tag suffix for the current profile composition. Used as the
# Docker image tag suffix so each distinct profile composition gets its own
# image. Reads PROFILE_COMPOSITION_HASH from caller scope (set by
# profile-installer.js via Task 004's profile resolution phase).
# The hash is owned by profile-installer.js — do NOT recompute it here.
function profile_image_suffix() {
    printf 'profile-%s\n' "${PROFILE_COMPOSITION_HASH:-default}"
}

function variant_image_tag() {
    printf 'ai-sandbox:%s\n' "$(profile_image_suffix)"
}

# Return 0 (stale) if the variant image is missing, its stored profile hash
# label differs from the current PROFILE_COMPOSITION_HASH, or any input file
# (docker/ tree, assembled Dockerfile, or profile input files) is newer than
# the image's creation timestamp. Return 1 (fresh) otherwise.
#
# Profile-hash label check: the label ai.sandbox.profile-hash is written into
# the assembled Dockerfile by assemble-dockerfile.sh at build time. If the hash
# stored in the image does not match the current PROFILE_COMPOSITION_HASH the
# image was built from a different composition and must be rebuilt.
#
# PROFILE_INPUT_FILES contract (set by Task 004's profile resolution phase):
#   A newline-delimited list of absolute paths to profile YAML files and the src
#   files referenced by skills/hooks/agents/setup_script in the merged profile.
#   When unset, only docker/ files are checked (non-profile / legacy path).
#
# PROFILE_ASSEMBLED_DOCKERFILE contract (set by profile-installer.js output,
#   sourced in Task 004): absolute path to the assembled Dockerfile. Checked in
#   addition to docker/ when set and the path is outside docker/.
function is_build_stale() {
    local tag created tmp newer
    tag="${AI_SANDBOX_IMAGE_TAG}"
    created="$(docker image inspect --format='{{.Created}}' "${tag}" 2>/dev/null)" || return 0

    # If a composition hash is known, verify the image was built from the same
    # composition. A hash mismatch means the image is stale regardless of mtimes.
    if [[ -n "${PROFILE_COMPOSITION_HASH:-}" ]]; then
        local stored_hash
        stored_hash="$(docker image inspect \
            --format '{{index .Config.Labels "ai.sandbox.profile-hash"}}' \
            "${tag}" 2>/dev/null)" || true
        if [[ "${stored_hash}" != "${PROFILE_COMPOSITION_HASH}" ]]; then
            return 0  # stale: composition changed
        fi
    fi

    tmp="$(mktemp)"
    # touch -d accepts ISO 8601 on macOS (BSD) and Linux (GNU). On failure,
    # treat as stale to force a rebuild rather than silently skipping.
    if ! touch -d "${created}" "${tmp}" 2>/dev/null; then
        rm -f "${tmp}"
        return 0
    fi

    # Check docker/ tree (existing behavior).
    newer="$(find "${PROJECT_ROOT}/docker" -type f -newer "${tmp}" -print -quit 2>/dev/null)"
    if [[ -n "${newer}" ]]; then
        rm -f "${tmp}"
        return 0  # stale: docker/ file changed
    fi

    # Check the assembled Dockerfile when it lives outside docker/ (it may be in
    # the XDG cache dir). PROFILE_ASSEMBLED_DOCKERFILE is set by profile-installer
    # output sourced in Task 004's profile resolution phase.
    if [[ -n "${PROFILE_ASSEMBLED_DOCKERFILE:-}" && -f "${PROFILE_ASSEMBLED_DOCKERFILE}" ]]; then
        newer="$(find "${PROFILE_ASSEMBLED_DOCKERFILE}" -newer "${tmp}" -print -quit 2>/dev/null)"
        if [[ -n "${newer}" ]]; then
            rm -f "${tmp}"
            return 0  # stale: assembled Dockerfile changed
        fi
    fi

    # Check profile YAML files and their referenced src files. PROFILE_INPUT_FILES
    # is a newline-delimited list of absolute paths exported by Task 004 from the
    # installer's paths block output. When unset, skip (non-profile / legacy path).
    if [[ -n "${PROFILE_INPUT_FILES:-}" ]]; then
        while IFS= read -r input_file; do
            [[ -z "${input_file}" ]] && continue
            [[ ! -f "${input_file}" ]] && continue
            newer="$(find "${input_file}" -newer "${tmp}" -print -quit 2>/dev/null)"
            if [[ -n "${newer}" ]]; then
                rm -f "${tmp}"
                return 0  # stale: a profile input file changed
            fi
        done <<< "${PROFILE_INPUT_FILES}"
    fi

    rm -f "${tmp}"
    return 1  # fresh
}

function ensure_image() {
    if ! docker image inspect "${AI_SANDBOX_IMAGE_TAG}" >/dev/null 2>&1; then
        qecho "Image not found, building..."
        do_build
    elif is_build_stale; then
        qecho "Build inputs changed since last build, rebuilding..."
        do_build
    fi
}

function do_build() {
    docker image rm -f "${AI_SANDBOX_IMAGE_TAG}" >/dev/null 2>&1 || true
    docker compose ${COMPOSE_FILES} build --ssh "default=${SSH_AUTH_SOCK}"
}

function cleanup_stale_container() {
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$(sandbox_container_name)" 2>/dev/null) || return 0
    case "$state" in
        running|exited|paused)
            # Healthy states — let `docker compose up -d` handle the transition
            # (it will start a stopped/exited container without recreating it when
            # the config matches, and restart/recreate as needed otherwise).
            return 0
            ;;
        *)
            qecho "Cleaning up stale container (state: ${state})..."
            docker compose -p "ai-sandbox-${SANDBOX_NAME}" ${COMPOSE_FILES} down 2>/dev/null \
                || docker rm -f "$(sandbox_container_name)" 2>/dev/null || true
            ;;
    esac
}

# SSH agent forwarding helpers.
#
# The container uses a stable internal socket path (/run/ai-sandbox/ssh-auth.sock)
# set in the Dockerfile. docker-compose.yaml bind-mounts the host's current
# SSH_AUTH_SOCK to that path and records the host value in the
# ai.sandbox.ssh-auth-sock-host label. When the host agent restarts (logout,
# reboot, new `eval $(ssh-agent)`), the label will no longer match the current
# host env — the container's mount is stale and SSH inside the container will
# fail. We detect this and tell the user to run `ai-sandbox fix-ssh`.

# Return 0 if the running container's recorded host SSH_AUTH_SOCK matches the
# current host env. Return 1 if it has drifted. Return 2 if there's no container
# (or no label), so callers can distinguish "no-op" from "stale".
function _ssh_mount_is_fresh() {
    local recorded
    recorded=$(docker inspect -f \
        '{{index .Config.Labels "ai.sandbox.ssh-auth-sock-host"}}' \
        "$(sandbox_container_name)" 2>/dev/null) || return 2
    [ -z "${recorded}" ] && return 2
    [ "${recorded}" = "${SSH_AUTH_SOCK:-}" ]
}

# Warn (non-fatal) if the running container's SSH socket mount is stale.
function warn_if_ssh_mount_stale() {
    _ssh_mount_is_fresh
    case $? in
        0|2) return 0 ;;
        1)
            echo "warn: host SSH_AUTH_SOCK has changed since the container was created." >&2
            echo "      SSH-backed operations (e.g. git push) will fail inside the container." >&2
            echo "      Run 'ai-sandbox ${SANDBOX_NAME} fix-ssh' to refresh the socket mount." >&2
            return 0
            ;;
    esac
}

# Verify the host SSH agent is reachable. Non-fatal; returns 1 if not.
# ssh-add -l exits 0 with identities, 1 with no identities, 2 if it can't
# contact the agent.
function ssh_preflight() {
    if [ -z "${SSH_AUTH_SOCK:-}" ] || [ ! -S "${SSH_AUTH_SOCK}" ]; then
        qecho "warn: host SSH_AUTH_SOCK (${SSH_AUTH_SOCK:-unset}) is not a live socket"
        return 1
    fi
    local rc
    ssh-add -l >/dev/null 2>&1
    rc=$?
    if [ $rc -eq 2 ]; then
        qecho "warn: cannot contact ssh-agent at ${SSH_AUTH_SOCK}"
        return 1
    fi
    return 0
}

# Recreate the ai-sandbox container with the current host SSH_AUTH_SOCK mounted.
function fix_ssh() {
    if ! ssh_preflight; then
        echo "Host SSH agent is not reachable. Start one (e.g. 'eval \$(ssh-agent)') or" >&2
        echo "verify SSH_AUTH_SOCK points at a live socket, then retry." >&2
        return 1
    fi
    # 'ai-sandbox' here is the compose service name, not the container name.
    docker compose ${COMPOSE_FILES} up -d --force-recreate --no-deps ai-sandbox
    qecho "Container recreated with SSH_AUTH_SOCK=${SSH_AUTH_SOCK}"
}

# Emit tab-separated rows for each managed ai-sandbox container:
#   name<TAB>state<TAB>profiles
# Sorted by container name. Uses docker ps -a with label filter.
# Requires Docker Engine 23+ for the .Label "..." format syntax
# (Docker Desktop on macOS satisfies this).
function list_instances() {
    docker ps -a \
        --filter "label=ai.sandbox.managed=true" \
        --format '{{.Label "ai.sandbox.instance"}}\t{{.State}}\t{{.Label "ai.sandbox.profiles"}}' \
        2>/dev/null \
    | sort
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
