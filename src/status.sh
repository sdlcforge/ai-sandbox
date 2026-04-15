# shellcheck shell=bash
# shellcheck disable=SC2155 # short-lived locals; split decl/assign is noisy here

STATUS_JSON=${STATUS_JSON:-false}
STATUS_TEST_CHECK=${STATUS_TEST_CHECK:-false}

# Map docker container state → one of: stopped | starting | running | stopping
function _status_container_state() {
    local raw
    raw="$(docker inspect -f '{{.State.Status}}' ai-sandbox 2>/dev/null || true)"
    case "${raw}" in
        running) echo "running" ;;
        restarting) echo "starting" ;;
        removing) echo "stopping" ;;
        *) echo "stopped" ;;
    esac
}

# Return 0 if any file under docker/ is newer than the image's Created time.
function _image_is_stale() {
    local img="$1" created tmp newer
    created="$(docker image inspect --format='{{.Created}}' "${img}" 2>/dev/null)" || return 0
    tmp="$(mktemp)"
    if ! touch -d "${created}" "${tmp}" 2>/dev/null; then
        rm -f "${tmp}"; return 0
    fi
    newer="$(find "${PROJECT_ROOT}/docker" -type f -newer "${tmp}" -print -quit 2>/dev/null)"
    rm -f "${tmp}"
    [ -n "${newer}" ]
}

# Emit tab-separated rows describing each built ai-sandbox image:
#   tag<TAB>created<TAB>chromium<TAB>docker<TAB>stale
# Empty output means no built images.
function _status_gather_images() {
    local tag id created chromium docker_en stale
    while IFS=$'\t' read -r tag id created; do
        [ -z "${tag}" ] && continue
        chromium="$(docker inspect --format='{{index .Config.Labels "ai.sandbox.chromium-enabled"}}' "${id}" 2>/dev/null || echo '')"
        docker_en="$(docker inspect --format='{{index .Config.Labels "ai.sandbox.docker-enabled"}}' "${id}" 2>/dev/null || echo '')"
        if _image_is_stale "${id}"; then stale=true; else stale=false; fi
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "${tag}" "${created}" "${chromium:-unknown}" "${docker_en:-unknown}" "${stale}"
    done < <(docker images ai-sandbox --format '{{.Repository}}:{{.Tag}}	{{.ID}}	{{.CreatedAt}}' 2>/dev/null)
}

function _render_status_human() {
    local state="$1" images="$2" conflicts_claude="$3" conflicts_workers="$4"

    echo "Container: ${state}"
    echo

    if [ -z "${images}" ]; then
        echo "Images: none"
    else
        echo "Images:"
        local tag created chromium docker_en stale fresh
        while IFS=$'\t' read -r tag created chromium docker_en stale; do
            [ "${stale}" = "true" ] && fresh="stale" || fresh="up-to-date"
            echo "  ${tag}"
            echo "    built:    ${created}"
            echo "    chromium: ${chromium}"
            echo "    docker:   ${docker_en}"
            echo "    status:   ${fresh}"
        done <<< "${images}"
    fi

    if [ "${state}" = "stopped" ]; then
        echo
        if [ -z "${conflicts_claude}" ] && [ -z "${conflicts_workers}" ]; then
            echo "Runnable: yes"
        else
            echo "Runnable: no — blocking host processes:"
            [ -n "${conflicts_claude}" ] && {
                echo "  claude processes:"
                while IFS= read -r line; do
                    [ -n "${line}" ] && echo "    ${line}"
                done <<< "${conflicts_claude}"
            }
            [ -n "${conflicts_workers}" ] && {
                echo "  plugin worker processes:"
                while IFS= read -r line; do
                    [ -n "${line}" ] && echo "    ${line}"
                done <<< "${conflicts_workers}"
            }
        fi
    fi
}

function _render_status_json() {
    local state="$1" images="$2" conflicts_claude="$3" conflicts_workers="$4"

    local images_json='[]'
    if [ -n "${images}" ]; then
        images_json=$(while IFS=$'\t' read -r tag created chromium docker_en stale; do
            [ -z "${tag}" ] && continue
            jq -n \
                --arg tag "${tag}" \
                --arg built "${created}" \
                --arg chromium "${chromium}" \
                --arg docker "${docker_en}" \
                --argjson stale "${stale}" \
                '{tag:$tag, built:$built, chromium:$chromium, docker:$docker, stale:$stale}'
        done <<< "${images}" | jq -s '.')
    fi

    local blockers_json='[]'
    local combined
    combined="$(printf '%s\n%s\n' "${conflicts_claude}" "${conflicts_workers}" | grep -v '^$' || true)"
    if [ -n "${combined}" ]; then
        blockers_json=$(while IFS= read -r line; do
            [ -z "${line}" ] && continue
            local pid="${line%% *}" cmd="${line#* }"
            jq -n --argjson pid "${pid}" --arg cmd "${cmd}" '{pid:$pid, cmd:$cmd}'
        done <<< "${combined}" | jq -s '.')
    fi

    local runnable='null'
    if [ "${state}" = "stopped" ]; then
        [ -z "${combined}" ] && runnable=true || runnable=false
    fi

    jq -n \
        --arg state "${state}" \
        --argjson images "${images_json}" \
        --argjson runnable "${runnable}" \
        --argjson blockers "${blockers_json}" \
        '{container:{state:$state}, images:$images, runnable:$runnable, blockers:$blockers}'
}

# Main entry point for `ai-sandbox status`.
function do_status() {
    local state images
    state="$(_status_container_state)"
    images="$(_status_gather_images)"

    # Populate _PLUGIN_CONFLICTS_* unless explicitly skipped.
    if [ "${AI_SANDBOX_SKIP_PLUGIN_CHECK:-0}" = "1" ]; then
        _PLUGIN_CONFLICTS_CLAUDE=""
        _PLUGIN_CONFLICTS_WORKERS=""
    else
        gather_plugin_conflicts
    fi
    local c_claude="${_PLUGIN_CONFLICTS_CLAUDE:-}"
    local c_workers="${_PLUGIN_CONFLICTS_WORKERS:-}"

    if [ "${STATUS_TEST_CHECK}" = "true" ]; then
        has_plugin_conflicts && return 1 || return 0
    fi

    if [ "${STATUS_JSON}" = "true" ]; then
        _render_status_json "${state}" "${images}" "${c_claude}" "${c_workers}"
    else
        _render_status_human "${state}" "${images}" "${c_claude}" "${c_workers}"
    fi
}
