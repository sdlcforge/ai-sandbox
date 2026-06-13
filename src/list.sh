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
