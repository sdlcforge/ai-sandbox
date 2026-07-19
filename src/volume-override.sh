# shellcheck shell=bash

# Generate a docker compose override adding volume mounts for:
#   - each installed plugin whose ${HOME}/.<plugin-name> dir exists on host
#   - each entry in ${HOME}/.config/ai-sandbox/volume-maps (see README)
# and an `extra_hosts` block for each caller-supplied `--add-host` spec
# (CLI_ADD_HOST, populated by src/options.sh's `--add-host` parsing).
# Writes a valid override to $1 even when nothing additional needs mounting.
#
# The output path ($1) is set by index.sh as:
#   ${XDG_CACHE_HOME:-$HOME/.cache}/ai-sandbox/${SANDBOX_NAME}/docker-compose.generated.yaml
# This scoping (per-instance subdirectory) was established in Phase 1 (index.sh).
# index.sh also runs `mkdir -p "$(dirname "${GENERATED_COMPOSE}")"` before calling
# this function, so the per-instance subdirectory always exists. No path logic
# needs to live here.
#
# CLI_ADD_HOST is a global array set by parse_options() (src/options.sh, always
# initialized to `()` even when no --add-host flags were given) and is visible
# here unmodified: this function runs in the same shell process/scope as
# index.sh, no subshell or export is involved. It is copied into a local
# below (nounset-safe, see that copy's own comment) rather than read
# directly, so this function also tolerates being called without
# parse_options() having run first (unit tests do this).
#
# extra_hosts merge semantics (empirically confirmed, load-bearing -- see
# phase-01 task 002): a second `-f` compose file's `extra_hosts` list APPENDS
# to the base file's list; it does not replace it. Confirmed two ways: (1)
# `docker compose -f docker-compose.yaml -f <override> config` shows both the
# base's `host.docker.internal:host-gateway` entry and the override's entries
# in the merged service; (2) starting a real container from the merged files
# and inspecting `/etc/hosts` inside it shows lines for both -- `docker
# compose ... config`'s displayed list order is not a reliable predictor of
# the actual /etc/hosts line order (observed to differ), but *presence* of
# both is consistent across both checks. This also holds when extra_hosts is
# written in mapping form (`name: ip`) instead of sequence form in either
# file: mapping form does not merge/override by key either, it still appends.
# Consequently this function emits *only* the caller-supplied entries below;
# the static `host.docker.internal:host-gateway` entry
# (docker/docker-compose.yaml) always survives unmodified from the base file
# and must not be re-emitted here.
#
# Duplicate-name caveat (historical -- now prevented at the source): a caller
# passing `--add-host host.docker.internal:<ip>` would have landed as a
# second /etc/hosts line for the same name as the base's static host-gateway
# mapping, with the effective precedence not reliably controlled by this
# override (observed /etc/hosts ordering did not match simple
# base-then-override file concatenation order) -- and, more seriously, could
# indeterminately retarget which IP the host-access capability's firewall
# rule opens, since docker/init-firewall.sh resolves that same name. This is
# now rejected outright at --add-host parse time
# (is_reserved_add_host_name(), src/utils.sh), so CLI_ADD_HOST can never
# contain an entry for this name by the time this function runs; this
# function does not re-check it.
function generate_volume_override() {
    local out="$1"
    local user_maps="${HOME}/.config/ai-sandbox/volume-maps"
    local -a mounts=()
    local plugin name line src dst
    # Defensive local copy of CLI_ADD_HOST (global array set by
    # parse_options(), src/options.sh, always to at least `()`): under
    # `set -u`, unit tests that call this function directly (bypassing
    # parse_options(), e.g. test/unit/plugin_preflight_spec.sh) would
    # otherwise hit "CLI_ADD_HOST: unbound variable" the moment the array is
    # referenced. The `${CLI_ADD_HOST[@]+"${CLI_ADD_HOST[@]}"}` expansion is
    # the standard nounset-safe idiom: it yields zero elements when
    # CLI_ADD_HOST is entirely unset, and preserves the array unchanged
    # (including a genuinely empty array) otherwise -- unlike
    # `${CLI_ADD_HOST[@]:-}`, which would collapse an unset array to a single
    # empty-string element and produce a spurious `extra_hosts:` entry below.
    local -a add_host_entries=("${CLI_ADD_HOST[@]+"${CLI_ADD_HOST[@]}"}")

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
            # Skip the mount entirely when it falls inside ${HOME}/playground:
            # docker-compose.yaml already bind-mounts that whole tree read-write
            # unconditionally (and, with --static-playground, an overlay mount is
            # stacked over it at container start), so a redundant mount here would
            # either be a no-op or get silently shadowed by the overlay with no error.
            case "${dst}" in
                "${HOME}/playground"/*|"${HOME}/playground")
                    ;;
                *)
                    mounts+=("${src}:${dst}")
                    ;;
            esac
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
                    # When the path points to a file (e.g. marketplace.json),
                    # mount a directory that covers its relative plugin sources.
                    # If the file lives inside .claude-plugin/, source paths in
                    # the manifest are relative to the project root (parent of
                    # .claude-plugin/), so mount that grandparent instead.
                    local _mount_path _parent
                    if [ -f "${_host_path}" ]; then
                        _parent="$(dirname "${_host_path}")"
                        if [ "$(basename "${_parent}")" = ".claude-plugin" ]; then
                            _mount_path="$(dirname "${_parent}")"
                        else
                            _mount_path="${_parent}"
                        fi
                    else
                        _mount_path="${_host_path}"
                    fi
                    # Skip the mount entirely when it falls inside ${HOME}/playground:
                    # docker-compose.yaml already bind-mounts that whole tree read-write
                    # unconditionally, and Docker applies nested bind mounts
                    # parent-before-child regardless of override ordering, so a redundant
                    # :ro mount here would silently downgrade an already-writable
                    # subdirectory to read-only inside the container.
                    case "${_mount_path}" in
                        "${HOME}/playground"/*|"${HOME}/playground")
                            ;;
                        *)
                            mounts+=("${_mount_path}:${_mount_path}:ro")
                            ;;
                    esac
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
        # Only the ai-sandbox service needs extra_hosts: firewall-init shares
        # ai-sandbox's network namespace (network_mode: "service:ai-sandbox",
        # docker/docker-compose.yaml) so it inherits /etc/hosts resolution.
        # Omit the key entirely when there are no caller entries -- an empty
        # `extra_hosts:` key is invalid compose YAML (docker compose config
        # rejects a sequence key with no items).
        if [ "${#add_host_entries[@]}" -gt 0 ]; then
            printf '    extra_hosts:\n'
            local h
            for h in "${add_host_entries[@]}"; do
                printf '      - %s\n' "${h}"
            done
        fi
    } > "${out}"
}
