# shellcheck shell=bash

# Display a formatted table of all managed sandbox instances.
#
# Called from index.sh as a short-circuit before the Docker pre-flight, so it
# must tolerate the Docker daemon being down: list_instances() uses `docker ps`
# which will fail gracefully — we catch the empty output and print a friendly
# message.
function do_list() {
    local rows
    rows="$(list_instances)"

    if [ -z "${rows}" ]; then
        echo "No sandboxes found."
        return 0
    fi

    # Header
    printf '%-20s  %-10s  %s\n' "NAME" "STATE" "PROFILES"
    # Rows
    while IFS=$'\t' read -r name state profiles; do
        [ -z "${name}" ] && continue
        printf '%-20s  %-10s  %s\n' "${name}" "${state}" "${profiles:-<none>}"
    done <<< "${rows}"
}

# Combined "Instances:" / "Profiles:" listing for the bare `ls` word only --
# not `instances ls` (instances-only) and not `profiles ls` (profiles-only);
# see
# plan/phase-02-profiles-resource/002-complete-name-resolution-and-verb-gating.md
# Requirement 6. Reuses do_list()/do_profiles_list() verbatim (including
# their own "No X found." fallback lines) rather than re-implementing table
# rendering, so each section stays visually consistent with its noun-scoped
# counterpart by construction. do_profiles_list() is defined in
# src/profiles.sh, sourced before src/list.sh in src/index.sh.
function do_list_all() {
    echo "Instances:"
    do_list
    echo
    echo "Profiles:"
    do_profiles_list
}
