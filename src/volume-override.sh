# shellcheck shell=bash

# Generate a docker compose override adding volume mounts for:
#   - each installed plugin whose ${HOME}/.<plugin-name> dir exists on host
#   - each entry in ${HOME}/.config/ai-sandbox/volume-maps (see README)
# Writes a valid override to $1 even when nothing additional needs mounting.
#
# The output path ($1) is set by index.sh as:
#   ${XDG_CACHE_HOME:-$HOME/.cache}/ai-sandbox/${SANDBOX_NAME}/docker-compose.generated.yaml
# This scoping (per-instance subdirectory) was established in Phase 1 (index.sh).
# index.sh also runs `mkdir -p "$(dirname "${GENERATED_COMPOSE}")"` before calling
# this function, so the per-instance subdirectory always exists. No path logic
# needs to live here.
function generate_volume_override() {
    local out="$1"
    local user_maps="${HOME}/.config/ai-sandbox/volume-maps"
    local -a mounts=()
    local plugin name line src dst

    # Skip host plugin directory mounts in clean-slate mode.
    if [ "${AI_SANDBOX_CLEAN_SLATE:-false}" != "true" ]; then
        while IFS= read -r plugin; do
            [ -z "${plugin}" ] && continue
            name=".${plugin}"
            if [ -d "${HOME}/${name}" ]; then
                mounts+=("${HOME}/${name}:${HOME}/${name}")
            fi
        done < <(list_installed_plugins)
    fi

    if [ -f "${user_maps}" ]; then
        while IFS= read -r line || [ -n "${line}" ]; do
            line="${line%%#*}"
            # shellcheck disable=SC2001 # sed is clearer than a pure-bash trim here
            line="$(printf '%s' "${line}" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
            [ -z "${line}" ] && continue
            # Expand $HOME and similar in user-owned input. Safe: file is user-local.
            line="$(eval "printf '%s' \"${line}\"")"
            if [[ "${line}" == *:* ]]; then
                src="${line%%:*}"; dst="${line#*:}"
            else
                src="${line}"; dst="${line}"
            fi
            mounts+=("${src}:${dst}")
        done < "${user_maps}"
    fi

    # Add read-only bind mounts for file:// marketplace paths so they resolve
    # identically inside the container (source == target path).
    if [ -n "${AI_SANDBOX_MARKETPLACES:-}" ]; then
        local _mp _host_path
        local _mktplaces_copy="${AI_SANDBOX_MARKETPLACES}"
        while [ -n "${_mktplaces_copy}" ]; do
            _mp="${_mktplaces_copy%%|*}"
            if [ "${_mp}" = "${_mktplaces_copy}" ]; then
                _mktplaces_copy=""
            else
                _mktplaces_copy="${_mktplaces_copy#*|}"
            fi
            [ -z "${_mp}" ] && continue
            case "${_mp}" in
                file://*)
                    _host_path="${_mp#file://}"
                    mounts+=("${_host_path}:${_host_path}:ro")
                    ;;
            esac
        done
    fi

    {
        printf 'services:\n'
        printf '  ai-sandbox:\n'
        if [ "${#mounts[@]}" -eq 0 ]; then
            printf '    volumes: []\n'
        else
            printf '    volumes:\n'
            local m
            for m in "${mounts[@]}"; do
                printf '      - %s\n' "${m}"
            done
        fi
    } > "${out}"
}
