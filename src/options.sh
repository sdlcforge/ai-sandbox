# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are consumed by index.sh after sourcing

# Parse CLI flags and the command word. Sets globals consumed by index.sh:
#   CMD          — subcommand (defaults to "enter")
#   ARGS         — array of remaining args forwarded to the subcommand
#   NO_CHROMIUM  — "true" if --no-chromium was passed
#   QUIET        — 0 (verbose) or 1 (quiet); defaults to 0 for `status`, 1 otherwise
# Also exports AI_SANDBOX_SKIP_PLUGIN_CHECK when --force is passed.
function parse_options() {
    CMD=""
    NO_CHROMIUM=false
    ARGS=()
    for arg in "$@"; do
        if [ "$arg" == "--no-chromium" ]; then
            NO_CHROMIUM=true
        elif [ "$arg" == "--force" ]; then
            export AI_SANDBOX_SKIP_PLUGIN_CHECK=1
        elif [ "$arg" == "--quiet" ] || [ "$arg" == "-q" ]; then
            QUIET=0
        elif [ "$arg" == "--help" ] || [ "$arg" == "-h" ]; then
            CMD="help"
        elif [ -z "${CMD}" ]; then
            CMD=${arg:-"enter"}
        else
            ARGS+=("$arg")
        fi
    done

    CMD=${CMD:-"enter"}

    if [ -z "${QUIET}" ]; then
        if [ "${CMD}" == "status" ]; then
            QUIET=0
        else
            QUIET=1
        fi
    fi
    export QUIET
}
