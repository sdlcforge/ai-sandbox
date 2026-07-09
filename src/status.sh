# shellcheck shell=bash
# shellcheck disable=SC2155 # short-lived locals; split decl/assign is noisy here

STATUS_JSON=${STATUS_JSON:-false}
STATUS_TEST_CHECK=${STATUS_TEST_CHECK:-false}

# Map docker container state → one of: stopped | starting | running | stopping
function _status_container_state() {
    local raw
    raw="$(docker inspect -f '{{.State.Status}}' "$(sandbox_container_name)" 2>/dev/null || true)"
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

# Decode the ai.sandbox.config label (base64 -> JSON) for the current
# sandbox's container, matching the read pattern restore_saved_config() (see
# src/utils.sh) uses for the same label. `docker inspect` works on stopped
# containers too, so this works regardless of container state, not just
# running. Prints the decoded JSON on stdout; prints nothing (and returns 0)
# when the label is absent, empty, or not valid JSON -- no container, a
# label-less/pre-existing container, and a corrupt label are all treated the
# same: the Configuration section is simply omitted, not an error.
function _status_gather_config() {
    local ctr_name label_b64 config_json max_config_b64_len
    ctr_name="$(sandbox_container_name)"
    label_b64="$(docker inspect --format='{{index .Config.Labels "ai.sandbox.config"}}' "${ctr_name}" 2>/dev/null || true)"
    [ -n "${label_b64}" ] || return 0

    # Defense-in-depth size bound (followup qVbA), mirroring
    # restore_saved_config() in src/utils.sh: 16KB is generously larger than
    # any real seven-field config record could ever be. An oversized value is
    # treated the same as an absent label (nothing to display) rather than
    # erroring.
    max_config_b64_len=16384
    [ "${#label_b64}" -le "${max_config_b64_len}" ] || return 0

    config_json="$(printf '%s' "${label_b64}" | base64 -d 2>/dev/null || true)"
    [ -n "${config_json}" ] || return 0

    # Validate it decodes to actual JSON before treating it as present, so a
    # corrupt/malformed label degrades to "no config section" rather than
    # propagating garbage to the caller.
    printf '%s' "${config_json}" | jq -e . >/dev/null 2>&1 || return 0

    printf '%s' "${config_json}"
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
    # 'ai-sandbox' here is the image name prefix, not the container name.
    # All sandbox images are tagged ai-sandbox:<variant>, so this query is
    # intentionally left as the literal prefix rather than using sandbox_container_name().
    done < <(docker images ai-sandbox --format '{{.Repository}}:{{.Tag}}	{{.ID}}	{{.CreatedAt}}' 2>/dev/null)
}

# Render the decoded ai.sandbox.config JSON as a "Configuration:" section,
# preferring YAML (via the Python kislyuk/yq wrapper's `yq -y .` -- NOT
# mikefarah/yq's `yq eval` syntax, an incompatible tool sharing the same
# binary name) for readability, and falling back to pretty-printed JSON via
# `jq .` with no error when yq is absent or the wrong variant. Mirrors
# src/xquartz.sh's pattern of degrading gracefully when an optional host tool
# is unavailable. $1 -- decoded config JSON; caller only invokes this when
# non-empty, so no section is emitted (not even a placeholder) when the label
# is absent.
function _render_config_section() {
    local config_json="$1" rendered

    echo
    echo "Configuration:"
    if command -v yq >/dev/null 2>&1 \
        && rendered="$(printf '%s' "${config_json}" | yq -y . 2>/dev/null)" \
        && [ -n "${rendered}" ]; then
        : # rendered as YAML above
    else
        rendered="$(printf '%s' "${config_json}" | jq .)"
    fi
    while IFS= read -r line; do
        echo "  ${line}"
    done <<< "${rendered}"
}

function _render_status_human() {
    local state="$1" images="$2" conflicts_claude="$3" conflicts_workers="$4" config_json="$5"

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

    # Omit the Configuration section entirely (not an error, no placeholder)
    # when the label is absent -- expected for any container with no
    # ai.sandbox.config label. Uses an if/fi (not `[ ... ] && ...`) so the
    # function's own exit status stays 0 when the label is absent, rather
    # than leaking the false test result as this function's (and do_status's)
    # return code.
    if [ -n "${config_json}" ]; then
        _render_config_section "${config_json}"
    fi
}

function _render_status_json() {
    local state="$1" images="$2" conflicts_claude="$3" conflicts_workers="$4" config_json="$5"

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

    # config_json is already-decoded JSON (no yq needed since the target
    # format is JSON); null when the ai.sandbox.config label is absent.
    local config_arg='null'
    [ -n "${config_json}" ] && config_arg="${config_json}"

    jq -n \
        --arg state "${state}" \
        --argjson images "${images_json}" \
        --argjson runnable "${runnable}" \
        --argjson blockers "${blockers_json}" \
        --argjson config "${config_arg}" \
        '{container:{state:$state}, images:$images, runnable:$runnable, blockers:$blockers, config:$config}'
}

# Main entry point for `ai-sandbox detail` (the CLI-facing command word; this
# file/function name is unchanged from when the word was called `status`).
function do_status() {
    local state images config_json
    state="$(_status_container_state)"
    images="$(_status_gather_images)"
    config_json="$(_status_gather_config)"

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
        _render_status_json "${state}" "${images}" "${c_claude}" "${c_workers}" "${config_json}"
    else
        echo "Sandbox: ${SANDBOX_NAME}"
        _render_status_human "${state}" "${images}" "${c_claude}" "${c_workers}" "${config_json}"
    fi
}
