# shellcheck shell=bash
# new-profile.sh — generate a profile YAML from local Claude assets.
#
# YAML emission strategy: we use `node -e` with js-yaml.dump to guarantee
# valid, correctly-quoted YAML output. Hand-rolled bash string concatenation
# is error-prone with special characters in filenames; js-yaml handles all
# quoting automatically. The node script receives all data as JSON via a
# single argument to avoid shell-injection from user-supplied paths.
# NODE_PATH is set to the project's node_modules directory (resolved relative
# to the script's own location) so js-yaml is found regardless of the caller's
# working directory.
#
# Plugins flag: --plugins accepts a comma-separated list and may be repeated.
# When no --plugins flag is given and stdin is not a TTY, the plugin list
# defaults to empty (no interactive prompting in V1 non-TTY mode).
# Interactive prompting in V1 is not implemented; documented for V2.

function new_profile() {
    local name="" mode="mirror" output="" plugins_raw=""
    local -a plugins=()
    local args=("$@")

    # --- Parse flags ---
    local i=0
    while [ $i -lt ${#args[@]} ]; do
        local arg="${args[$i]}"
        case "${arg}" in
            --name)
                i=$(( i + 1 ))
                name="${args[$i]}"
                ;;
            --mode)
                i=$(( i + 1 ))
                mode="${args[$i]}"
                ;;
            --output)
                i=$(( i + 1 ))
                output="${args[$i]}"
                ;;
            --plugins)
                i=$(( i + 1 ))
                plugins_raw="${args[$i]}"
                # Accumulate comma-separated names into plugins array
                IFS=',' read -ra _plug_batch <<< "${plugins_raw}"
                local _p
                for _p in "${_plug_batch[@]}"; do
                    _p="${_p// /}"  # strip surrounding spaces
                    [ -n "${_p}" ] && plugins+=("${_p}")
                done
                ;;
            *)
                echo "Error: unknown option '${arg}' for new-profile" >&2
                return 1
                ;;
        esac
        i=$(( i + 1 ))
    done

    # --- Validate --name (required; must be a valid POSIX filename component) ---
    if [ -z "${name}" ]; then
        echo "Error: --name is required for new-profile" >&2
        return 1
    fi
    if [[ "${name}" == */* ]]; then
        echo "Error: --name must be a valid POSIX filename component (no '/' allowed)" >&2
        return 1
    fi

    # --- Validate --mode ---
    case "${mode}" in
        mirror|static) ;;
        *)
            echo "Error: --mode must be 'mirror' or 'static' (got '${mode}')" >&2
            return 1
            ;;
    esac

    # --- Resolve output path ---
    if [ -z "${output}" ]; then
        output="./profiles/${name}.yaml"
    fi

    # --- Resolve project node_modules for js-yaml ---
    # BASH_SOURCE[0] points to this file (or the rolled-up bin/ai-sandbox.sh).
    # Walk up to find node_modules relative to the script's directory.
    local _cp_src="${BASH_SOURCE[0]}"
    local _cp_dir
    # Follow symlinks to get the real directory
    while [ -L "${_cp_src}" ]; do
        _cp_dir="$(cd -P "$(dirname "${_cp_src}")" && pwd)"
        _cp_src="$(readlink "${_cp_src}")"
        [[ ${_cp_src} != /* ]] && _cp_src="${_cp_dir}/${_cp_src}"
    done
    _cp_dir="$(cd -P "$(dirname "${_cp_src}")" && pwd)"
    # bin/ → project root; src/ → project root
    local _cp_node_modules="${_cp_dir}/../node_modules"
    if [ ! -d "${_cp_node_modules}" ]; then
        _cp_node_modules="${_cp_dir}/node_modules"
    fi
    _cp_node_modules="$(cd -P "${_cp_node_modules}" 2>/dev/null && pwd)" || {
        echo "Error: cannot locate node_modules (looked relative to '${_cp_dir}')" >&2
        return 1
    }

    # --- Auto-discovery ---
    # Discover skills, hooks, agents from ~/.claude/* and ./.claude/*
    # For each found file/dir, record {src: abs_path, dst: container_path}
    # dst mirrors src's position under $HOME → /home/<user>/.claude/<cat>/<basename>
    local ai_config_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/ai-sandbox"
    local host_user="${HOST_USER:-${USER}}"
    local container_home="/home/${host_user}"
    local is_local=false

    # Arrays of "abs_path<TAB>dst_path" entries per category
    local -a skill_entries=()
    local -a hook_entries=()
    local -a agent_entries=()

    # Scan a directory for files and populate the appropriate named-array variable.
    # Usage: _cp_scan_dir <dir> <category>
    _cp_scan_dir() {
        local dir="$1" category="$2"
        local abs_dir
        if [[ "${dir}" == /* ]]; then
            abs_dir="${dir}"
        else
            abs_dir="${PWD}/${dir}"
        fi
        [ -d "${abs_dir}" ] || return 0

        local f basename dst_path
        while IFS= read -r -d '' f; do
            basename="$(basename "${f}")"
            dst_path="${container_home}/.claude/${category}/${basename}"
            case "${category}" in
                skills) skill_entries+=("${f}"$'\t'"${dst_path}") ;;
                hooks)  hook_entries+=("${f}"$'\t'"${dst_path}") ;;
                agents) agent_entries+=("${f}"$'\t'"${dst_path}") ;;
            esac
            # Local detection: if src is outside the ai-sandbox config dir, mark local
            if [[ "${f}" != "${ai_config_dir}"* ]]; then
                is_local=true
            fi
        done < <(find "${abs_dir}" -maxdepth 1 -type f -print0 2>/dev/null)
    }

    # Skills
    _cp_scan_dir "${HOME}/.claude/skills"  "skills"
    _cp_scan_dir "./.claude/skills"        "skills"

    # Hooks
    _cp_scan_dir "${HOME}/.claude/hooks"   "hooks"
    _cp_scan_dir "./.claude/hooks"         "hooks"

    # Agents
    _cp_scan_dir "${HOME}/.claude/agents"  "agents"
    _cp_scan_dir "./.claude/agents"        "agents"

    # --- Create output directory ---
    local output_dir
    output_dir="$(dirname "${output}")"
    mkdir -p "${output_dir}"

    # --- Build JSON data structure passed to node / js-yaml ---
    # Helper: convert a nameref array of "src<TAB>dst" entries to a JSON array.
    _cp_entries_to_json() {
        local -n _arr=$1
        local json="["
        local first=true
        local entry src dst
        for entry in "${_arr[@]+"${_arr[@]}"}"; do
            src="${entry%%$'\t'*}"
            dst="${entry##*$'\t'}"
            if [ "${first}" = "true" ]; then
                first=false
            else
                json+=","
            fi
            # Escape backslashes and double-quotes for JSON embedding
            src="${src//\\/\\\\}"
            src="${src//\"/\\\"}"
            dst="${dst//\\/\\\\}"
            dst="${dst//\"/\\\"}"
            json+="{\"src\":\"${src}\",\"dst\":\"${dst}\"}"
        done
        json+="]"
        echo "${json}"
    }

    local skills_json hooks_json agents_json plugins_json
    skills_json="$(_cp_entries_to_json skill_entries)"
    hooks_json="$(_cp_entries_to_json hook_entries)"
    agents_json="$(_cp_entries_to_json agent_entries)"

    # Build plugins JSON array
    plugins_json="["
    local _pfirst=true
    local _p
    for _p in "${plugins[@]+"${plugins[@]}"}"; do
        if [ "${_pfirst}" = "true" ]; then
            _pfirst=false
        else
            plugins_json+=","
        fi
        _p="${_p//\\/\\\\}"
        _p="${_p//\"/\\\"}"
        plugins_json+="\"${_p}\""
    done
    plugins_json+="]"

    # Escape name and mode for safe JSON embedding (validated above, but be safe)
    local name_esc="${name//\"/\\\"}"
    local mode_esc="${mode//\"/\\\"}"

    local data_json
    data_json="{\"name\":\"${name_esc}\",\"version\":\"1.0.0\",\"local\":${is_local},\"mode\":\"${mode_esc}\",\"plugins\":${plugins_json},\"skills\":${skills_json},\"hooks\":${hooks_json},\"agents\":${agents_json}}"

    # --- Emit YAML via js-yaml ---
    # We pass NODE_PATH so require('js-yaml') resolves correctly regardless of CWD.
    # shellcheck disable=SC2016 # single-quotes intentional: $ inside JS, not bash
    local node_script='
const jsyaml = require("js-yaml");
const data = JSON.parse(process.argv[1]);

const doc = {};

// metadata block
doc.metadata = { name: data.name, version: data.version };
if (data.local) {
    doc.metadata.local = true;
}

// mode (always written; default is mirror)
doc.mode = data.mode;

// plugins (only when non-empty)
if (data.plugins && data.plugins.length > 0) {
    doc.plugins = data.plugins;
}

// skills/hooks/agents (only when non-empty)
if (data.skills && data.skills.length > 0) {
    doc.skills = data.skills;
}
if (data.hooks && data.hooks.length > 0) {
    doc.hooks = data.hooks;
}
if (data.agents && data.agents.length > 0) {
    doc.agents = data.agents;
}

process.stdout.write(jsyaml.dump(doc, { lineWidth: 120 }));
'

    local yaml_content
    if ! yaml_content="$(NODE_PATH="${_cp_node_modules}" node -e "${node_script}" "${data_json}" 2>&1)"; then
        echo "Error: failed to generate YAML: ${yaml_content}" >&2
        return 1
    fi

    # Write the file
    printf '%s' "${yaml_content}" > "${output}"

    echo "Created profile: ${output}"
}
