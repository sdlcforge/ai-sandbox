# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are consumed by index.sh after sourcing

# Parse CLI flags and the command word. Sets globals consumed by index.sh:
#   CMD          — subcommand (defaults to "enter")
#   CMD_EXPLICIT — "true" if the user supplied a command word
#   ARGS         — array of remaining args forwarded to the subcommand
#   PROFILES     — array of --profile names, in invocation order
#   MODE_OVERRIDE — "mirror" / "static" from --mode, or "" if not given
#   NO_ISOLATE_CONFIG — "true" if --no-isolate-config was passed
#   CONFIG_FLAGS_PROVIDED — "true" if any flag changing container config was passed
#   AUTO_YES     — "true" if --yes / -y was passed (skip confirmation prompts)
#   QUIET        — 0 (verbose) or 1 (quiet); defaults to 0 for `status`, 1 otherwise
# Also exports AI_SANDBOX_SKIP_PLUGIN_CHECK when --force is passed.
function parse_options() {
    CMD=""
    CMD_EXPLICIT=false
    PROFILES=()
    MODE_OVERRIDE=""
    NO_ISOLATE_CONFIG=false
    CONFIG_FLAGS_PROVIDED=false
    AUTO_YES=false
    STATUS_JSON=false
    STATUS_TEST_CHECK=false
    ARGS=()
    while [ $# -gt 0 ]; do
        arg="$1"
        if [ "$arg" == "--profile" ]; then
            if [ $# -lt 2 ]; then
                echo "Error: --profile requires a profile name" 1>&2
                exit 1
            fi
            PROFILES+=("$2")
            CONFIG_FLAGS_PROVIDED=true
            shift
        elif [ "$arg" == "--mode" ]; then
            if [ $# -lt 2 ]; then
                echo "Error: --mode requires a value (mirror or static)" 1>&2
                exit 1
            fi
            MODE_OVERRIDE="$2"
            if [ "${MODE_OVERRIDE}" != "mirror" ] && [ "${MODE_OVERRIDE}" != "static" ]; then
                echo "Error: --mode must be 'mirror' or 'static' (got '${MODE_OVERRIDE}')" 1>&2
                exit 1
            fi
            CONFIG_FLAGS_PROVIDED=true
            shift
        elif [ "$arg" == "--no-chromium" ]; then
            echo "Error: --no-chromium has been removed. Chromium is opt-in via '--profile chromium'." 1>&2
            exit 1
        elif [ "$arg" == "--no-docker" ] || [ "$arg" == "-D" ]; then
            echo "Error: --no-docker/-D has been removed. The Docker CLI is opt-in via '--profile docker'." 1>&2
            exit 1
        elif [ "$arg" == "--docker" ]; then
            echo "Error: --docker has been removed. Use '--profile docker' instead." 1>&2
            exit 1
        elif [ "$arg" == "--no-isolate-config" ]; then
            NO_ISOLATE_CONFIG=true
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
        shift
    done

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
