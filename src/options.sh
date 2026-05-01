# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are consumed by index.sh after sourcing

# Parse CLI flags and the command word. Sets globals consumed by index.sh:
#   CMD          — subcommand (defaults to "enter")
#   CMD_EXPLICIT — "true" if the user supplied a command word
#   ARGS         — array of remaining args forwarded to the subcommand
#   NO_CHROMIUM  — "true" if --no-chromium was passed
#   NO_DOCKER    — "true" if --no-docker / -D was passed
#   ENABLE_DOCKER_PROXY — "true" if --docker was passed
#   CONFIG_FLAGS_PROVIDED — "true" if any flag changing container config was passed
#   AUTO_YES     — "true" if --yes / -y was passed (skip confirmation prompts)
#   QUIET        — 0 (verbose) or 1 (quiet); defaults to 0 for `status`, 1 otherwise
# Also exports AI_SANDBOX_SKIP_PLUGIN_CHECK when --force is passed.
function parse_options() {
    CMD=""
    CMD_EXPLICIT=false
    NO_CHROMIUM=false
    NO_DOCKER=false
    NO_ISOLATE_CONFIG=false
    ENABLE_DOCKER_PROXY=false
    CONFIG_FLAGS_PROVIDED=false
    AUTO_YES=false
    STATUS_JSON=false
    STATUS_TEST_CHECK=false
    ARGS=()
    for arg in "$@"; do
        if [ "$arg" == "--no-chromium" ]; then
            NO_CHROMIUM=true
            CONFIG_FLAGS_PROVIDED=true
        elif [ "$arg" == "--no-docker" ] || [ "$arg" == "-D" ]; then
            NO_DOCKER=true
            CONFIG_FLAGS_PROVIDED=true
        elif [ "$arg" == "--no-isolate-config" ]; then
            NO_ISOLATE_CONFIG=true
            CONFIG_FLAGS_PROVIDED=true
        elif [ "$arg" == "--docker" ]; then
            ENABLE_DOCKER_PROXY=true
            CONFIG_FLAGS_PROVIDED=true
        elif [ "$arg" == "--force" ]; then
            export AI_SANDBOX_SKIP_PLUGIN_CHECK=1
        elif [ "$arg" == "--yes" ] || [ "$arg" == "-y" ]; then
            AUTO_YES=true
        elif [ "$arg" == "--json" ]; then
            STATUS_JSON=true
        elif [ "$arg" == "--test-check" ]; then
            STATUS_TEST_CHECK=true
        elif [ "$arg" == "--quiet" ] || [ "$arg" == "-q" ]; then
            QUIET=0
        elif [ "$arg" == "--help" ] || [ "$arg" == "-h" ]; then
            CMD="help"
            CMD_EXPLICIT=true
        elif [ -z "${CMD}" ]; then
            CMD=${arg:-"enter"}
            CMD_EXPLICIT=true
        else
            ARGS+=("$arg")
        fi
    done

    # AI_SANDBOX_ENABLE_DOCKER_PROXY env var is an implicit --docker, so treat it
    # like a config flag too — bare `ai-sandbox` invocations should still pick
    # up its effect.
    if [ -n "${AI_SANDBOX_ENABLE_DOCKER_PROXY:-}" ] && [ "${NO_DOCKER}" != "true" ]; then
        CONFIG_FLAGS_PROVIDED=true
    fi
    export CMD_EXPLICIT CONFIG_FLAGS_PROVIDED AUTO_YES

    if { [ "${STATUS_JSON}" = "true" ] || [ "${STATUS_TEST_CHECK}" = "true" ]; } \
        && [ "${CMD}" != "status" ]; then
        echo "Error: --json and --test-check only apply to 'status'" 1>&2
        exit 1
    fi
    export STATUS_JSON STATUS_TEST_CHECK

    CMD=${CMD:-"enter"}

    if [ -z "${QUIET}" ]; then
        if [ "${CMD}" == "status" ] \
            && [ "${STATUS_JSON}" != "true" ] \
            && [ "${STATUS_TEST_CHECK}" != "true" ]; then
            QUIET=0
        else
            QUIET=1
        fi
    fi
    export QUIET
}
