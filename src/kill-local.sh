# shellcheck shell=bash

# Kill host-side claude and claude-plugin processes that would conflict with
# plugins running inside the container. Retries up to 4 times, waiting 1s more
# on each attempt. Exits nonzero with a warning listing survivors if any
# processes are still running after the final attempt.
function kill_local_ai() {
    local plugin_cache="${HOME}/.claude/plugins/cache"
    local self_pid=$$
    local ppid_val=$PPID
    local plugin_names
    plugin_names=$(list_installed_plugins | tr '\n' '|' | sed 's/|$//')

    _list_host_ai_pids() {
        local claude_pids worker_pids cache_pids
        claude_pids=$(pgrep -f '(^|/)claude( |$)' 2>/dev/null \
            | awk -v s="${self_pid}" -v p="${ppid_val}" '$1 != s && $1 != p {print $1}' || true)
        if [ -n "${plugin_names}" ]; then
            worker_pids=$(pgrep -f "(^|/)(${plugin_names})( |$|/)" 2>/dev/null \
                | awk -v s="${self_pid}" -v p="${ppid_val}" '$1 != s && $1 != p {print $1}' || true)
        fi
        cache_pids=$(pgrep -f "${plugin_cache}" 2>/dev/null \
            | awk -v s="${self_pid}" -v p="${ppid_val}" '$1 != s && $1 != p {print $1}' || true)
        printf '%s\n%s\n%s\n' "${claude_pids}" "${worker_pids}" "${cache_pids}" \
            | grep -v '^$' | sort -un
    }

    local pids
    pids=$(_list_host_ai_pids)
    if [ -z "${pids}" ]; then
        qecho "No host claude or plugin processes running."
        return 0
    fi

    local attempt
    for attempt in 1 2 3 4; do
        qecho "Attempt ${attempt}/4: killing host AI processes (${pids//$'\n'/ })..."
        # shellcheck disable=SC2086 # intentional word splitting across PIDs
        kill ${pids} 2>/dev/null || true
        sleep "${attempt}"
        pids=$(_list_host_ai_pids)
        if [ -z "${pids}" ]; then
            qecho "All host AI processes stopped."
            return 0
        fi
    done

    printf 'WARNING: failed to stop host AI processes after 4 attempts.\n' >&2
    printf 'Still running:\n' >&2
    # shellcheck disable=SC2086 # intentional word splitting across PIDs
    ps -o pid=,command= -p ${pids} 2>/dev/null >&2 \
        || printf '%s\n' "${pids}" >&2
    return 1
}
