# shellcheck shell=bash
# profiles.sh — profile scaffolding (profiles_create), listing (do_profiles_list),
# and existence-checking (profile_exists).
#
# Renamed/restructured from new-profile.sh (phase-02-profiles-resource task 001):
# profiles_create() preserves the auto-discovery logic new_profile() had in
# substance, just taking <name> positionally (symmetric with `instances create
# <name>`) instead of via --name. `new-profile`/`new_profile` are dropped
# entirely, not aliased, per this plan's no-backward-compatibility stance.
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

# Resolve the project root the same way index.sh does (BASH_SOURCE[0], symlinks
# followed, one directory up from bin/). Self-contained (not reused from
# index.sh's PROJECT_ROOT global) because profiles_create()/do_profiles_list()
# are invoked from index.sh's early short-circuit block, before PROJECT_ROOT is
# computed there -- mirrors the pre-existing node_modules resolution pattern
# below in profiles_create().
function _profiles_project_root() {
    local src="${BASH_SOURCE[0]}"
    local dir
    while [ -L "${src}" ]; do
        dir="$(cd -P "$(dirname "${src}")" && pwd)"
        src="$(readlink "${src}")"
        [[ ${src} != /* ]] && src="${dir}/${src}"
    done
    dir="$(cd -P "$(dirname "${src}")" && pwd)"
    (cd -P "${dir}/.." && pwd)
}

# Return 0 if a profile named $1 exists at any of the three discovery
# locations from docs/ai-sandbox-profiles-spec.md's "Profile storage and
# discovery" section (project-local, user-global, bundled), 1 otherwise.
# Does not distinguish which location matched -- callers needing that
# (e.g. phase-02 task 002's deletion logic) re-derive it.
function profile_exists() {
    local name="${1:-}"
    local xdg_config="${XDG_CONFIG_HOME:-${HOME}/.config}"
    [ -f "./profiles/${name}.yaml" ] && return 0
    [ -f "${xdg_config}/ai-sandbox/profiles/${name}.yaml" ] && return 0
    [ -f "$(_profiles_project_root)/profiles/${name}.yaml" ] && return 0
    return 1
}

# Resolve which of the three discovery-priority locations
# (project-local/user-global/bundled -- same order as profile_exists() and
# docs/ai-sandbox-profiles-spec.md's "Profile storage and discovery")
# owns a profile named $1. Echoes "<path><TAB><source-label>" for the first
# match and returns 0; returns 1 with no output when no location has it.
# Callers needing to know *which* location matched (do_profiles_detail(),
# profiles_delete()) use this instead of profile_exists(), which only
# reports existence.
function _profile_resolve_location() {
    local name="${1:-}"
    local xdg_config="${XDG_CONFIG_HOME:-${HOME}/.config}"
    local project_path="./profiles/${name}.yaml"
    local user_path="${xdg_config}/ai-sandbox/profiles/${name}.yaml"
    local bundled_path
    bundled_path="$(_profiles_project_root)/profiles/${name}.yaml"

    if [ -f "${project_path}" ]; then
        printf '%s\t%s\n' "${project_path}" "project-local"
        return 0
    fi
    if [ -f "${user_path}" ]; then
        printf '%s\t%s\n' "${user_path}" "user-global"
        return 0
    fi
    if [ -f "${bundled_path}" ]; then
        printf '%s\t%s\n' "${bundled_path}" "bundled"
        return 0
    fi
    return 1
}

# Print a profile's raw YAML content -- the "detail" verb for a name that
# resolves to a profile (src/options.sh's verb-gating). Raw file contents is
# sufficient for V1: "composed" output (profile-installer.js's merge logic)
# has nothing to compose against for a single named profile. $1 is the
# profile name.
function do_profiles_detail() {
    local name="${1:-}"
    local location path
    location="$(_profile_resolve_location "${name}")" || {
        echo "Error: profile '${name}' not found" >&2
        return 1
    }
    path="${location%%$'\t'*}"
    cat "${path}"
}

# Delete a profile's YAML file -- the "delete" verb for a name that resolves
# to a profile (src/options.sh's verb-gating). Refuses to delete a bundled
# profile (ships with the ai-sandbox install tree, not a per-user file),
# naming the bundled path in the error. No confirmation prompt: unlike
# instance deletion, profile deletion has no running-container state to
# protect (see
# plan/phase-02-profiles-resource/002-complete-name-resolution-and-verb-gating.md
# Requirement 3). $1 is the profile name.
function profiles_delete() {
    local name="${1:-}"
    local location path source_label
    location="$(_profile_resolve_location "${name}")" || {
        echo "Error: profile '${name}' not found" >&2
        return 1
    }
    path="${location%%$'\t'*}"
    source_label="${location##*$'\t'}"

    if [ "${source_label}" = "bundled" ]; then
        echo "Error: '${name}' is a bundled profile (${path}) and cannot be deleted -- bundled profiles ship with the ai-sandbox install tree, not as a per-user file." >&2
        return 1
    fi

    rm -f "${path}"
    echo "Deleted profile: ${path}"
}

# Display a formatted table of all discoverable profiles (project-local,
# user-global, bundled), deduplicated by discovery priority so a name shadowed
# at a higher-priority location is listed once, from that location.
function do_profiles_list() {
    local xdg_config="${XDG_CONFIG_HOME:-${HOME}/.config}"
    local project_dir="./profiles"
    local user_dir="${xdg_config}/ai-sandbox/profiles"
    local bundled_dir
    bundled_dir="$(_profiles_project_root)/profiles"

    local -a names=()
    local -a sources=()
    local -a files=()

    # Read a top-level `mode:` scalar directly from a profile YAML file via a
    # fast grep-based skim rather than invoking profile-installer.js/node for
    # every listed profile -- profiles ls only needs a cheap best-effort hint,
    # not a fully composed/validated result, and this keeps `profiles ls` from
    # requiring Node on every call. Handles a bare or single/double-quoted
    # scalar value; leaves MODE blank (rendered as "-") for anything else
    # (e.g. absent, or a value profile-installer.js would need to validate).
    _profiles_mode_skim() {
        local file="$1" line
        line="$(grep -m1 -E '^mode:[[:space:]]*' "${file}" 2>/dev/null || true)"
        line="${line#mode:}"
        line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace
        line="${line%"${line##*[![:space:]]}"}"   # trim trailing whitespace
        line="${line%\"}"; line="${line#\"}"
        line="${line%\'}"; line="${line#\'}"
        printf '%s' "${line}"
    }

    # Record <name> once, from the highest-priority location that provides it.
    # $1 - directory to scan  $2 - source label
    _profiles_collect_dir() {
        local dir="$1" source_label="$2" f base name existing
        [ -d "${dir}" ] || return 0
        for f in "${dir}"/*.yaml; do
            [ -e "${f}" ] || continue
            base="$(basename "${f}")"
            name="${base%.yaml}"
            local seen=false
            for existing in "${names[@]+"${names[@]}"}"; do
                if [ "${existing}" = "${name}" ]; then
                    seen=true
                    break
                fi
            done
            [ "${seen}" = "true" ] && continue
            names+=("${name}")
            sources+=("${source_label}")
            files+=("${f}")
        done
    }

    _profiles_collect_dir "${project_dir}" "project-local"
    _profiles_collect_dir "${user_dir}" "user-global"
    _profiles_collect_dir "${bundled_dir}" "bundled"

    if [ "${#names[@]}" -eq 0 ]; then
        echo "No profiles found."
        return 0
    fi

    # Sort by name, keeping the parallel arrays aligned. Built with a plain
    # while-read loop (not `mapfile`/`readarray`) since those are bash-4+
    # builtins and this script's shebang (#!/bin/bash) resolves to macOS's
    # bundled bash 3.2 when run as an installed executable.
    local -a order=()
    local order_line
    while IFS= read -r order_line; do
        order+=("${order_line}")
    done < <(
        local i
        for i in "${!names[@]}"; do printf '%s\t%d\n' "${names[$i]}" "$i"; done \
            | sort -k1,1
    )

    printf '%-20s  %-14s  %s\n' "NAME" "SOURCE" "MODE"
    local entry idx mode
    for entry in "${order[@]}"; do
        idx="${entry##*$'\t'}"
        mode="$(_profiles_mode_skim "${files[$idx]}")"
        printf '%-20s  %-14s  %s\n' "${names[$idx]}" "${sources[$idx]}" "${mode:--}"
    done
}

# Scaffold a profile YAML by auto-discovering skills/hooks/agents. $1 is the
# profile name (positional, symmetric with `instances create <name>`); the
# collision check (name vs. existing instance/profile) runs here so it applies
# regardless of which noun word (`instances create` / `profiles create`) is
# in play, and regardless of --output overriding the write destination -- the
# check is about the *name*, not the file path (see
# plan/phase-02-profiles-resource/001-build-profiles-module.md Requirements
# item 5). Reserved-word collisions are already rejected earlier, at the
# src/options.sh dispatch layer, before this function is ever called.
function profiles_create() {
    local name="${1:-}"
    shift || true
    local mode="mirror" output="" plugins_raw=""
    local -a plugins=()
    local args=("$@")

    # --- Parse flags ---
    local i=0
    while [ $i -lt ${#args[@]} ]; do
        local arg="${args[$i]}"
        case "${arg}" in
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
                echo "Error: unknown option '${arg}' for 'profiles create'" >&2
                return 1
                ;;
        esac
        i=$(( i + 1 ))
    done

    # --- Validate name (required positional; must be a valid POSIX filename component) ---
    if [ -z "${name}" ]; then
        echo "Error: a profile name is required for 'profiles create'" >&2
        return 1
    fi
    if [[ "${name}" == */* ]]; then
        echo "Error: profile name must be a valid POSIX filename component (no '/' allowed)" >&2
        return 1
    fi

    # --- Collision check: an existing instance, an existing profile (any of
    # the three locations), or a reserved word (already rejected upstream in
    # src/options.sh's dispatch layer via check_reserved_name). ---
    if instance_exists "${name}"; then
        echo "Error: '${name}' already exists as a sandbox instance. Choose a different profile name." >&2
        return 1
    fi
    if profile_exists "${name}"; then
        echo "Error: profile '${name}' already exists. Choose a different name or remove the existing profile first." >&2
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
