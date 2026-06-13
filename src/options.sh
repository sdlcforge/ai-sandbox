# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are consumed by index.sh after sourcing

# Parse CLI flags and the command word. Sets globals consumed by index.sh:
#   SANDBOX_NAME  — empty for global commands; instance name for per-instance commands
#   SANDBOX_PROFILES — comma-joined list of --profile values from a `create` invocation
#   CMD           — subcommand (e.g. "create", "list", "enter", "stop")
#   ARGS          — array of remaining args forwarded to the subcommand
#   PROFILES      — array of --profile names, in invocation order (current run's profile resolution)
#   MODE_OVERRIDE — "mirror" / "static" from --mode, or "" if not given
#   NO_ISOLATE_CONFIG — "true" if --no-isolate-config was passed
#   CONFIG_FLAGS_PROVIDED — "true" if any flag changing container config was passed
#   AUTO_YES      — "true" if --yes / -y was passed (skip confirmation prompts)
#   ENTER_AFTER_CREATE — "true" if --enter was passed to `create`
#   STATUS_JSON   — "true" if --json was passed (per-instance commands only)
#   STATUS_TEST_CHECK — "true" if --test-check was passed (per-instance commands only)
#   QUIET         — 0 (verbose) or 1 (quiet); defaults to 0 for `status`, 1 otherwise
# Also exports AI_SANDBOX_SKIP_PLUGIN_CHECK when --force is passed.
function parse_options() {
    SANDBOX_NAME=""
    SANDBOX_PROFILES=""
    CMD=""
    PROFILES=()
    MODE_OVERRIDE=""
    NO_ISOLATE_CONFIG=false
    CONFIG_FLAGS_PROVIDED=false
    AUTO_YES=false
    ENTER_AFTER_CREATE=false
    STATUS_JSON=false
    STATUS_TEST_CHECK=false
    ARGS=()

    # Global command words — first non-flag arg matching one of these is a global command.
    local -r GLOBAL_COMMANDS="create list help kill-local-ai new-profile"
    # Reserved names — may not be used as sandbox instance names.
    local -r RESERVED_NAMES="create list help kill-local-ai new-profile status"

    # --- Phase 1: consume leading flags that apply before the command word ---
    # We collect remaining positional args here, then process them below.
    local positional=()
    while [ $# -gt 0 ]; do
        local arg="$1"
        case "${arg}" in
            --force)
                export AI_SANDBOX_SKIP_PLUGIN_CHECK=1
                ;;
            --yes|-y)
                AUTO_YES=true
                ;;
            --quiet|-q)
                QUIET=1
                ;;
            --help|-h)
                CMD="help"
                ;;
            --)
                # Everything after -- is positional
                shift
                while [ $# -gt 0 ]; do
                    positional+=("$1")
                    shift
                done
                break
                ;;
            -*)
                # Unknown leading flags are deferred to post-command parsing
                positional+=("${arg}")
                ;;
            *)
                positional+=("${arg}")
                ;;
        esac
        shift
    done

    # If --help/-h was already set via leading flag, nothing else to do for CMD
    if [ "${CMD}" = "help" ]; then
        export SANDBOX_NAME SANDBOX_PROFILES CMD ARGS PROFILES MODE_OVERRIDE \
               NO_ISOLATE_CONFIG CONFIG_FLAGS_PROVIDED AUTO_YES ENTER_AFTER_CREATE \
               STATUS_JSON STATUS_TEST_CHECK QUIET
        if [ -z "${QUIET}" ]; then
            QUIET=1
        fi
        export QUIET
        return 0
    fi

    # --- Phase 2: determine whether first positional arg is a global command or sandbox name ---
    local remaining=("${positional[@]+"${positional[@]}"}")
    local n_remaining="${#remaining[@]}"

    if [ "${n_remaining}" -eq 0 ]; then
        # Bare invocation → list
        CMD="list"
    else
        local first_arg="${remaining[0]}"
        # Check if first_arg is a global command word
        local is_global=false
        local gc
        for gc in ${GLOBAL_COMMANDS}; do
            if [ "${first_arg}" = "${gc}" ]; then
                is_global=true
                break
            fi
        done

        if [ "${is_global}" = "true" ]; then
            CMD="${first_arg}"
            # remaining args after the command word
            remaining=("${remaining[@]:1}")
            # For `create`, the next positional is the sandbox name
            if [ "${CMD}" = "create" ] && [ "${#remaining[@]}" -gt 0 ]; then
                SANDBOX_NAME="${remaining[0]}"
                remaining=("${remaining[@]:1}")
            fi
        else
            # Per-instance: first arg is sandbox name
            SANDBOX_NAME="${first_arg}"

            # Validate: reserved name check
            local rn
            for rn in ${RESERVED_NAMES}; do
                if [ "${SANDBOX_NAME}" = "${rn}" ]; then
                    echo "Error: '${SANDBOX_NAME}' is a reserved name and cannot be used as a sandbox name" 1>&2
                    exit 1
                fi
            done

            remaining=("${remaining[@]:1}")
            # Second positional arg is the per-instance command; default to "enter"
            if [ "${#remaining[@]}" -gt 0 ]; then
                CMD="${remaining[0]}"
                remaining=("${remaining[@]:1}")
            else
                CMD="enter"
            fi
        fi
    fi

    # --- Phase 3: parse remaining args as command-specific flags ---
    # Re-merge any flags that were deferred during leading-flag scan (those that
    # started with - but weren't global flags) with remaining positionals.
    local all_remaining=("${remaining[@]+"${remaining[@]}"}")
    local i=0
    while [ "${i}" -lt "${#all_remaining[@]}" ]; do
        local rarg="${all_remaining[${i}]}"
        case "${rarg}" in
            --profile)
                i=$(( i + 1 ))
                if [ "${i}" -ge "${#all_remaining[@]}" ]; then
                    echo "Error: --profile requires a profile name" 1>&2
                    exit 1
                fi
                PROFILES+=("${all_remaining[${i}]}")
                CONFIG_FLAGS_PROVIDED=true
                ;;
            --mode)
                i=$(( i + 1 ))
                if [ "${i}" -ge "${#all_remaining[@]}" ]; then
                    echo "Error: --mode requires a value (mirror or static)" 1>&2
                    exit 1
                fi
                MODE_OVERRIDE="${all_remaining[${i}]}"
                if [ "${MODE_OVERRIDE}" != "mirror" ] && [ "${MODE_OVERRIDE}" != "static" ]; then
                    echo "Error: --mode must be 'mirror' or 'static' (got '${MODE_OVERRIDE}')" 1>&2
                    exit 1
                fi
                CONFIG_FLAGS_PROVIDED=true
                ;;
            --no-chromium)
                echo "Error: --no-chromium has been removed. Chromium is opt-in via '--profile chromium'." 1>&2
                exit 1
                ;;
            --no-docker|-D)
                echo "Error: --no-docker/-D has been removed. The Docker CLI is opt-in via '--profile docker'." 1>&2
                exit 1
                ;;
            --docker)
                echo "Error: --docker has been removed. Use '--profile docker' instead." 1>&2
                exit 1
                ;;
            --no-isolate-config)
                NO_ISOLATE_CONFIG=true
                CONFIG_FLAGS_PROVIDED=true
                ;;
            --enter)
                # Only meaningful for `create`; silently accepted for other commands
                ENTER_AFTER_CREATE=true
                ;;
            --json)
                STATUS_JSON=true
                ;;
            --test-check)
                STATUS_TEST_CHECK=true
                ;;
            *)
                ARGS+=("${rarg}")
                ;;
        esac
        i=$(( i + 1 ))
    done

    # --- Phase 4: build SANDBOX_PROFILES from PROFILES (for `create`) ---
    if [ "${CMD}" = "create" ] && [ "${#PROFILES[@]}" -gt 0 ]; then
        local IFS=,
        SANDBOX_PROFILES="${PROFILES[*]}"
    fi

    # --- Phase 5: QUIET default ---
    if [ -z "${QUIET}" ]; then
        if [ "${CMD}" = "status" ] \
            && [ "${STATUS_JSON}" != "true" ] \
            && [ "${STATUS_TEST_CHECK}" != "true" ]; then
            QUIET=0
        else
            QUIET=1
        fi
    fi

    export SANDBOX_NAME SANDBOX_PROFILES CMD ARGS PROFILES MODE_OVERRIDE \
           NO_ISOLATE_CONFIG CONFIG_FLAGS_PROVIDED AUTO_YES ENTER_AFTER_CREATE \
           STATUS_JSON STATUS_TEST_CHECK QUIET
}
