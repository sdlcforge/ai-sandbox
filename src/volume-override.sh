# shellcheck shell=bash

# Generate a docker compose override adding volume mounts for:
#   - each installed plugin whose ${HOME}/.<plugin-name> dir exists on host
#   - each entry in ${HOME}/.config/ai-sandbox/volume-maps (see README)
# Writes a valid override to $1 even when nothing additional needs mounting.
function generate_volume_override() {
    local out="$1"
    local user_maps="${HOME}/.config/ai-sandbox/volume-maps"
    local -a mounts=()
    local plugin name line src dst

    while IFS= read -r plugin; do
        [ -z "${plugin}" ] && continue
        name=".${plugin}"
        if [ -d "${HOME}/${name}" ]; then
            mounts+=("${HOME}/${name}:${HOME}/${name}")
        fi
    done < <(list_installed_plugins)

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
