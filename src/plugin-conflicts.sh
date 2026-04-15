# shellcheck shell=bash

# Check for host-side processes that would conflict with plugins running inside
# the container. Exits nonzero (with PIDs + suggested `kill` commands) on conflict.
# Bypass with AI_SANDBOX_SKIP_PLUGIN_CHECK=1.
function check_host_plugin_conflicts() {
    if [ "${AI_SANDBOX_SKIP_PLUGIN_CHECK:-0}" = "1" ]; then
        qecho "Skipping host plugin-conflict check (AI_SANDBOX_SKIP_PLUGIN_CHECK=1)."
        return 0
    fi

    local plugin_cache="${HOME}/.claude/plugins/cache"
    local self_pid=$$
    local ppid_val=$PPID

    # Claude processes: match `claude` as a path component, not a substring (so we
    # don't flag claude-mem, this script, etc.). Exclude our own PID and parent.
    local claude_pids
    claude_pids=$(pgrep -fl '(^|/)claude( |$)' 2>/dev/null \
        | awk -v s="${self_pid}" -v p="${ppid_val}" '$1 != s && $1 != p {print}' || true)

    # Plugin worker processes: command line mentions any installed plugin name, or
    # any path under the plugins cache dir.
    local plugin_names
    plugin_names=$(list_installed_plugins | tr '\n' '|' | sed 's/|$//')
    local plugin_pids=""
    if [ -n "${plugin_names}" ]; then
        # Match plugin name as a path component or standalone arg token, not as a
        # substring of arbitrary env vars (avoids matching `CURSOR_WORKSPACE_LABEL=
        # github-toolkit` when 'github' is an installed plugin name).
        plugin_pids=$(pgrep -fl "(^|/)(${plugin_names})( |$|/)" 2>/dev/null \
            | awk -v s="${self_pid}" -v p="${ppid_val}" '$1 != s && $1 != p {print}' || true)
    fi
    local cache_pids
    cache_pids=$(pgrep -fl "${plugin_cache}" 2>/dev/null \
        | awk -v s="${self_pid}" -v p="${ppid_val}" '$1 != s && $1 != p {print}' || true)
    local worker_pids
    worker_pids=$(printf '%s\n%s\n' "${plugin_pids}" "${cache_pids}" \
        | grep -v '^$' | sort -u || true)

    if [ -z "${claude_pids}" ] && [ -z "${worker_pids}" ]; then
        return 0
    fi

    printf '\n'
    printf 'ERROR: host processes would conflict with plugins running in the VM.\n'
    printf 'Running claude or claude plugins on both host and VM can corrupt shared\n'
    printf 'SQLite state (e.g. ~/.claude-mem). The container will not be started.\n\n'
    [ -n "${claude_pids}" ] && printf 'Host claude processes:\n%s\n\n' "${claude_pids}"
    [ -n "${worker_pids}" ] && printf 'Plugin worker processes:\n%s\n\n' "${worker_pids}"

    local all_pids
    all_pids=$(printf '%s\n%s\n' "${claude_pids}" "${worker_pids}" \
        | awk 'NF {print $1}' | sort -un | tr '\n' ' ')
    if [ -n "${all_pids}" ]; then
        printf 'To resolve, stop the offending processes. For example:\n'
        printf '  kill %s\n\n' "${all_pids}"
        printf 'Or bypass with AI_SANDBOX_SKIP_PLUGIN_CHECK=1 if you know the\n'
        printf 'matches are false positives (e.g. a shell with claude in its history).\n\n'
    fi
    return 1
}
