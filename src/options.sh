# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are consumed by index.sh after sourcing

# Parse CLI flags and the command word. Sets globals consumed by index.sh:
#   SANDBOX_NAME  — empty for global commands; instance name for per-instance commands
#   SANDBOX_PROFILES — comma-joined list of --profile values from a `create` invocation
#   CMD           — subcommand (e.g. "create", "list", "enter", "stop").
#                   "detail" is accepted as a per-instance command word (bare
#                   or after a sandbox name) and normalized to CMD="status"
#                   during parsing — it is a pure alias, not a distinct value.
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
#   CLI_MARKETPLACES — array of --add-marketplace refs (https:// or file://)
#   CLI_PLUGINS   — array of --enable-plugin names
#   CLI_ENABLE_ALL — "true" if --enable-all was passed
#   CLEAN_SLATE   — "true" if --clean was passed (no host ~/.claude or plugin mounts)
# Also exports AI_SANDBOX_SKIP_PLUGIN_CHECK when --force is passed.

# Validate a sandbox name against Docker Compose's project-name constraint.
# Compose derives the container/network/volume namespace from -p <name>,
# which only accepts lowercase letters, digits, hyphens, and underscores,
# starting with a letter or digit. Reject invalid names here so the error
# is clear, instead of surfacing later as a confusing failure deep inside
# `docker compose -p ai-sandbox-<name>`.
function validate_sandbox_name() {
    local name="$1"
    if [[ ! "${name}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "Error: sandbox name '${name}' is invalid — must start with a lowercase letter or digit and contain only lowercase letters, digits, hyphens, and underscores" 1>&2
        exit 1
    fi
}

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
    CLI_MARKETPLACES=()
    CLI_PLUGINS=()
    CLI_ENABLE_ALL=false
    CLEAN_SLATE=false

    # Global command words — first non-flag arg matching one of these is a global command.
    local -r GLOBAL_COMMANDS="create list help kill-local-ai new-profile"
    # Reserved names — may not be used as sandbox instance names.
    local -r RESERVED_NAMES="create list help kill-local-ai new-profile status detail"

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
               STATUS_JSON STATUS_TEST_CHECK QUIET \
               CLI_MARKETPLACES CLI_PLUGINS CLI_ENABLE_ALL CLEAN_SLATE
        if [ -z "${QUIET}" ]; then
            QUIET=1
        fi
        export QUIET
        return 0
    fi

    # --- Phase 2: determine whether first positional arg is a global command or sandbox name ---
    local remaining=("${positional[@]+"${positional[@]}"}")
    local n_remaining="${#remaining[@]}"
    # Set true only when CMD is assigned its Phase-2 fallback value ("enter")
    # because no bare command word was found immediately after the sandbox
    # name (either a flag came next, or nothing did). Phase 3 uses this to
    # recognize that a later bare word may be the per-instance command word
    # that got pushed past leading flags (e.g. `mybox --profile x start`),
    # rather than a passthrough arg. Left false whenever CMD is assigned
    # explicitly (global command, bare per-instance command, or an explicit
    # `<name> <cmd>` word), so promotion never fires in those cases.
    local cmd_defaulted=false

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

        # Per-instance command words that may appear without a sandbox-name prefix.
        # When the first positional arg matches one of these, route to CMD with an
        # empty (default) SANDBOX_NAME instead of treating the word as a sandbox
        # name.  Without this, `ai-sandbox clean` parses as SANDBOX_NAME=clean /
        # CMD=enter, which triggers the plugin-conflict check and enters the wrong
        # sandbox.
        local -r PER_INSTANCE_COMMANDS="start enter attach connect fix-ssh build user-exec root-exec status detail stop delete clean up"
        local is_per_instance_cmd=false
        local pic
        for pic in ${PER_INSTANCE_COMMANDS}; do
            if [ "${first_arg}" = "${pic}" ]; then
                is_per_instance_cmd=true
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
                validate_sandbox_name "${SANDBOX_NAME}"
                remaining=("${remaining[@]:1}")
            fi
        elif [ "${is_per_instance_cmd}" = "true" ]; then
            # Command word used without a sandbox-name prefix; apply to the
            # default (empty-name) sandbox.
            SANDBOX_NAME=""
            CMD="${first_arg}"
            remaining=("${remaining[@]:1}")
        else
            # Per-instance: first arg is sandbox name
            SANDBOX_NAME="${first_arg}"
            validate_sandbox_name "${SANDBOX_NAME}"

            # Validate: reserved name check
            local rn
            for rn in ${RESERVED_NAMES}; do
                if [ "${SANDBOX_NAME}" = "${rn}" ]; then
                    echo "Error: '${SANDBOX_NAME}' is a reserved name and cannot be used as a sandbox name" 1>&2
                    exit 1
                fi
            done

            remaining=("${remaining[@]:1}")
            # Second positional arg is the per-instance command; default to "enter".
            # If the next token looks like a flag (e.g. --add-marketplace, --clean) rather
            # than a command word, leave it for Phase 3's flag parser instead of
            # swallowing it as CMD.
            if [ "${#remaining[@]}" -gt 0 ] && [[ "${remaining[0]}" != -* ]]; then
                CMD="${remaining[0]}"
                remaining=("${remaining[@]:1}")
            else
                CMD="enter"
                cmd_defaulted=true
            fi
        fi
    fi

    # "detail" is a pure alias for "status" -- normalize immediately after
    # Phase 2's CMD assignment (covers both the bare `detail` form and the
    # `<name> detail` form, since both branches above funnel through this one
    # point before Phase 3) so every downstream `[ "${CMD}" = "status" ]`
    # check, including the QUIET default below and src/index.sh's dispatch
    # branch, keeps working unmodified.
    if [ "${CMD}" = "detail" ]; then
        CMD="status"
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
            --add-marketplace)
                i=$(( i + 1 ))
                if [ "${i}" -ge "${#all_remaining[@]}" ]; then
                    echo "Error: --add-marketplace requires a ref (https:// or file://)" 1>&2
                    exit 1
                fi
                _ref="${all_remaining[${i}]}"
                case "${_ref}" in
                    https://*|file://*) ;;
                    *)
                        echo "Error: --add-marketplace ref must start with https:// or file:// (got '${_ref}')" 1>&2
                        exit 1
                        ;;
                esac
                CLI_MARKETPLACES+=("${_ref}")
                CONFIG_FLAGS_PROVIDED=true
                ;;
            --enable-plugin)
                i=$(( i + 1 ))
                if [ "${i}" -ge "${#all_remaining[@]}" ]; then
                    echo "Error: --enable-plugin requires a plugin name" 1>&2
                    exit 1
                fi
                CLI_PLUGINS+=("${all_remaining[${i}]}")
                CONFIG_FLAGS_PROVIDED=true
                ;;
            --enable-all)
                CLI_ENABLE_ALL=true
                CONFIG_FLAGS_PROVIDED=true
                ;;
            --clean)
                CLEAN_SLATE=true
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
                # If a flag (or flag+value pair) preceded the per-instance
                # command word, Phase 2 couldn't see the command word and
                # fell back to CMD="enter" (cmd_defaulted=true). The first
                # bare, non-flag token here that matches PER_INSTANCE_COMMANDS
                # is that command word — promote it to CMD instead of the
                # passthrough ARGS array. Once promoted, cmd_defaulted is
                # cleared so any further bare words (a second command-like
                # word, or genuine docker-compose passthrough args) fall
                # through to ARGS as before.
                local promoted_cmd=false
                if [ "${cmd_defaulted}" = "true" ] && [[ "${rarg}" != -* ]]; then
                    local pic2
                    for pic2 in ${PER_INSTANCE_COMMANDS}; do
                        if [ "${rarg}" = "${pic2}" ]; then
                            promoted_cmd=true
                            break
                        fi
                    done
                fi
                if [ "${promoted_cmd}" = "true" ]; then
                    # Mirror the detail->status normalization applied right
                    # after Phase 2, since a promoted "detail" word bypasses
                    # that earlier normalization point.
                    if [ "${rarg}" = "detail" ]; then
                        CMD="status"
                    else
                        CMD="${rarg}"
                    fi
                    cmd_defaulted=false
                else
                    ARGS+=("${rarg}")
                fi
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

    # Note: CLI_MARKETPLACES and CLI_PLUGINS are bash arrays; bash cannot export
    # arrays across process boundaries. They are consumed within the same shell
    # session by index.sh before any subprocess boundary is crossed — same
    # pattern as PROFILES.
    export SANDBOX_NAME SANDBOX_PROFILES CMD ARGS PROFILES MODE_OVERRIDE \
           NO_ISOLATE_CONFIG CONFIG_FLAGS_PROVIDED AUTO_YES ENTER_AFTER_CREATE \
           STATUS_JSON STATUS_TEST_CHECK QUIET \
           CLI_MARKETPLACES CLI_PLUGINS CLI_ENABLE_ALL CLEAN_SLATE
}
