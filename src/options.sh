# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are consumed by index.sh after sourcing

# Parse CLI flags and the command word, per the noun-based dispatch grammar:
#   ai-sandbox                          -> enter the default/unnamed instance
#   ai-sandbox ls                       -> grouped Instances:/Profiles: listing
#   ai-sandbox instances ls             -> list instances only
#   ai-sandbox instances create <name>  -> create instance <name>
#   ai-sandbox profiles ls              -> list profiles only
#   ai-sandbox profiles create <name>   -> scaffold profile <name>
#   ai-sandbox <name> [<verb>]          -> per-instance/per-profile dispatch,
#                                          resolved by resolve_name_kind() and
#                                          verb-gated against the resolved
#                                          kind's allowed-verb set; default
#                                          verb "enter" (instance kind only --
#                                          a bare `<profile-name>` with no
#                                          verb is rejected, since "enter"
#                                          isn't a profile-appropriate verb)
#   ai-sandbox help | kill-local-ai
# Sets globals consumed by index.sh:
#   SANDBOX_NAME  — empty for global/noun commands; instance name for per-instance commands
#   SANDBOX_NAME_KIND — resolve_name_kind()'s result ("instance"/"profile"/"unknown")
#                   for the flat per-name dispatch path; empty for every other
#                   dispatch shape (ls / instances / profiles noun / global /
#                   bare per-instance command word / create). Computed once
#                   here and exported so src/index.sh's profile-kind
#                   short-circuit can reuse it instead of re-resolving (which
#                   would double the docker ps -a round trip on every
#                   per-name invocation).
#   SANDBOX_PROFILES — comma-joined list of --profile values from a `create` invocation
#   CMD           — subcommand (e.g. "create", "ls", "enter", "detail", "stop").
#                   "detail" is the sole spelling for the status-report verb —
#                   there is no remaining alias or normalization step.
#   ARGS          — array of remaining args forwarded to the subcommand
#   PROFILES      — array of --profile names, in invocation order (current run's profile resolution)
#   MODE_OVERRIDE — "mirror" / "static" from --mode, or "" if not given
#   NO_ISOLATE_CONFIG — "true" if --no-isolate-config was passed
#   STATIC_PLAYGROUND — "true" if --static-playground was passed
#   CONFIG_FLAGS_PROVIDED — "true" if any flag changing container config was passed
#   AUTO_YES      — "true" if --yes / -y was passed (skip confirmation prompts)
#   ENTER_AFTER_CREATE — "true" if --enter was passed to `create`
#   STATUS_JSON   — "true" if --json was passed (per-instance commands only)
#   STATUS_TEST_CHECK — "true" if --test-check was passed (per-instance commands only)
#   QUIET         — 0 (verbose) or 1 (quiet); defaults to 0 for `detail`, 1 otherwise
#   CLI_MARKETPLACES — array of --add-marketplace refs (https:// or file://)
#   CLI_PLUGINS   — array of --enable-plugin names
#   CLI_ENABLE_ALL — "true" if --enable-all was passed
#   CLEAN_SLATE   — "true" if --clean was passed (no host ~/.claude or plugin mounts)
#   CLI_ALLOW_EGRESS — array of --allow-egress specs
#                   (<host-or-ip-or-cidr>:<port>), syntactically validated at
#                   parse time (see the --allow-egress case below, which calls
#                   src/utils.sh's is_valid_egress_host()/is_valid_egress_port()
#                   directly for per-failure-mode error messages). CLI-only --
#                   there is no profile-level equivalent to merge, unlike
#                   CLI_MARKETPLACES/CLI_PLUGINS.
#   CLI_ADD_HOST  — array of --add-host specs (<name>:<ip>), syntactically
#                   validated at parse time (see the --add-host case below,
#                   which calls src/utils.sh's
#                   is_valid_egress_hostname()/is_valid_ipv4_literal()
#                   directly for per-failure-mode error messages, plus
#                   is_reserved_add_host_name() to reject the reserved name
#                   "host.docker.internal"). CLI-only --
#                   there is no profile-level equivalent to merge, matching
#                   CLI_ALLOW_EGRESS. Like the other CLI_* arrays, it is a
#                   bash array serialized across the sourced-options boundary
#                   the same way CLI_ALLOW_EGRESS is (see the comment near the
#                   final export statement below).
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

# Reject a sandbox name that collides with a reserved command word (a member
# of RESERVED_NAMES). Shared by both the `create <name>` path and the
# implicit `<name> [<cmd>]` per-instance path, so the same words are rejected
# consistently regardless of how the sandbox name was supplied.
function check_reserved_name() {
    local name="$1"
    local reserved_names="$2"
    local rn
    for rn in ${reserved_names}; do
        if [ "${name}" = "${rn}" ]; then
            echo "Error: '${name}' is a reserved name and cannot be used as a sandbox name" 1>&2
            exit 1
        fi
    done
}

# Derive the reserved-name set from the live command tables instead of a
# hand-maintained literal, so a future addition to any table is automatically
# reserved without a second edit.
#   $1 - global command words (space-separated)
#   $2 - per-instance command words (space-separated)
#   $3 - noun words (space-separated)
#   $4 - extra words that are recognized during parsing but aren't part of any
#        of the tables above (e.g. "create"/"ls", which are only reachable as
#        a noun sub-verb / standalone bare word — see Phase 2)
function compute_reserved_names() {
    echo "$1 $2 $3 $4"
}

# resolve_name_kind <name>
# Echoes one of: instance | profile | unknown
# Consults instance_exists() (src/utils.sh) and profile_exists()
# (src/profiles.sh). Both are function definitions registered by the time
# this is ever called at runtime -- src/index.sh sources utils.sh/profiles.sh
# before invoking parse_options(), even though profiles.sh is sourced after
# options.sh in that file's source list; only the *order functions are
# called in* matters, not the order the files defining them were sourced in.
# An existing instance always wins over a same-named profile: the
# create-collision checks in profiles_create()/do_create() (phase-02 task
# 001) already prevent a name from being both, so this branch order is
# defensive, not load-bearing, in case that invariant is ever violated by
# pre-existing state.
#
# instance_exists() returns 2 (rather than the falsy 1) when the underlying
# `docker ps` query itself failed -- i.e. Docker is unreachable, not "no such
# container". When that happens we cannot tell instance from unknown, so we
# do NOT fall through to profile_exists()/"unknown": doing so would let a
# perfectly ordinary instance name get hard-rejected by parse_options()'s
# Phase 3.5 verb-gating before the pre-existing Docker-preflight/auto-start
# logic in src/index.sh (or `detail`'s documented tolerance of a down daemon)
# ever gets a chance to run. Instead, treat the name as a plausible instance
# -- matching this function's pre-verb-gating behavior, where any name was
# simply assumed to be an instance and let downstream Docker calls sort it
# out. See Bug 1 in the phase-02-profiles-resource follow-up review.
function resolve_name_kind() {
    local name="${1:-}"
    local instance_rc
    instance_exists "${name}"
    instance_rc=$?
    if [ "${instance_rc}" -eq 0 ]; then
        echo "instance"
        return 0
    fi
    if [ "${instance_rc}" -eq 2 ]; then
        echo "instance"
        return 0
    fi
    if profile_exists "${name}"; then
        echo "profile"
        return 0
    fi
    echo "unknown"
}

function parse_options() {
    SANDBOX_NAME=""
    SANDBOX_NAME_KIND=""
    SANDBOX_PROFILES=""
    CMD=""
    PROFILES=()
    MODE_OVERRIDE=""
    NO_ISOLATE_CONFIG=false
    STATIC_PLAYGROUND=false
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
    CLI_ALLOW_EGRESS=()
    CLI_ADD_HOST=()

    # Global command words — first non-flag arg matching one of these is a global command.
    # "create" and "list" are no longer free-standing global words: they are
    # only reachable as sub-verbs of the "instances" noun (or, for "ls", also
    # as a standalone bare word — see Phase 2). "new-profile" is dropped
    # entirely (not aliased) as of phase-02-profiles-resource; scaffolding a
    # profile is now "profiles create <name>" below.
    local -r GLOBAL_COMMANDS="help kill-local-ai"
    # Noun words — first non-flag arg matching one of these introduces a
    # noun-scoped sub-verb (see the "instances"/"profiles" handling in Phase 2).
    local -r NOUN_WORDS="instances profiles"
    # Per-instance command words that may appear without a sandbox-name prefix
    # (see Phase 2) or after one. Declared here (rather than only where first
    # used) so RESERVED_NAMES below can derive from it.
    local -r PER_INSTANCE_COMMANDS="start enter attach fix-ssh build user-exec root-exec detail stop delete clean up"
    # Verb-gating allow-list for a name that resolves to a profile (see the
    # Phase 3.5 check below). Every PER_INSTANCE_COMMANDS word, plus the
    # passthrough fallback, remains available unrestricted when the name
    # resolves to an instance instead -- no allow-list needed for that case.
    local -r PROFILE_COMMANDS="detail delete"
    # Words recognized during parsing that aren't part of any table above:
    # "create" only appears as "instances create", and "ls" is a standalone
    # bare word (see Phase 2) — neither is a GLOBAL_COMMANDS/PER_INSTANCE_COMMANDS
    # entry, but both must still be reserved.
    local -r EXTRA_RESERVED_WORDS="create ls"
    # Reserved names — may not be used as sandbox instance names. Derived from
    # the tables above so a future addition to any of them is automatically
    # reserved without a second, hand-maintained edit.
    local -r RESERVED_NAMES="$(compute_reserved_names "${GLOBAL_COMMANDS}" "${PER_INSTANCE_COMMANDS}" "${NOUN_WORDS}" "${EXTRA_RESERVED_WORDS}")"

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
        export SANDBOX_NAME SANDBOX_NAME_KIND SANDBOX_PROFILES CMD ARGS PROFILES MODE_OVERRIDE \
               NO_ISOLATE_CONFIG STATIC_PLAYGROUND CONFIG_FLAGS_PROVIDED AUTO_YES ENTER_AFTER_CREATE \
               STATUS_JSON STATUS_TEST_CHECK QUIET \
               CLI_MARKETPLACES CLI_PLUGINS CLI_ENABLE_ALL CLEAN_SLATE CLI_ALLOW_EGRESS CLI_ADD_HOST
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
    # SANDBOX_NAME_KIND holds resolve_name_kind()'s result for the flat
    # per-name dispatch path (Phase 2's per-name else branch below) --
    # "instance" | "profile" | "unknown". It's initialized to "" at the top
    # of this function (so it's always defined under `set -u` for Phase 3.5's
    # verb-gating check below, and for the export list, regardless of which
    # dispatch shape this invocation took) and stays "" for every shape that
    # never resolves a name (ls / instances / profiles noun / global / bare
    # per-instance command word / create). It's a function-global (not
    # `local`) so it can be exported below for src/index.sh's profile-kind
    # short-circuit to reuse, avoiding a second resolve_name_kind() call and
    # its docker ps -a round trip (see Bug 2 in the phase-02-profiles-resource
    # follow-up review).
    if [ "${n_remaining}" -eq 0 ]; then
        # Bare invocation → enter the default/unnamed instance (matches the
        # "name given, no verb → enter" default already established below for
        # named instances). The old bare-invocation listing behavior now
        # requires the explicit "ls" word.
        CMD="enter"
    else
        local first_arg="${remaining[0]}"

        if [ "${first_arg}" = "ls" ]; then
            # Standalone bare word, not a per-instance verb — "ls" never takes
            # a sandbox-name prefix (an instance's own `<name> ls` isn't a
            # thing), so it's checked before the per-instance-command-word
            # loop below rather than living in PER_INSTANCE_COMMANDS.
            SANDBOX_NAME=""
            CMD="ls"
            remaining=("${remaining[@]:1}")
        elif [ "${first_arg}" = "instances" ]; then
            # Noun word supporting exactly two sub-verbs: ls and create.
            # "instances ls" is namespaced to CMD="instances-ls" (distinct
            # from bare CMD="ls" above) so src/index.sh can dispatch it to an
            # instances-only listing, while bare `ls` produces the grouped
            # Instances:/Profiles: view -- see
            # plan/phase-02-profiles-resource/002-complete-name-resolution-and-verb-gating.md
            # Requirement 6.
            remaining=("${remaining[@]:1}")
            if [ "${#remaining[@]}" -eq 0 ]; then
                echo "Error: 'instances' requires a sub-verb (ls or create)" 1>&2
                exit 1
            fi
            local instances_verb="${remaining[0]}"
            remaining=("${remaining[@]:1}")
            case "${instances_verb}" in
                ls)
                    SANDBOX_NAME=""
                    CMD="instances-ls"
                    ;;
                create)
                    CMD="create"
                    if [ "${#remaining[@]}" -eq 0 ]; then
                        echo "Error: 'instances create' requires a sandbox name" 1>&2
                        exit 1
                    fi
                    SANDBOX_NAME="${remaining[0]}"
                    validate_sandbox_name "${SANDBOX_NAME}"
                    check_reserved_name "${SANDBOX_NAME}" "${RESERVED_NAMES}"
                    remaining=("${remaining[@]:1}")
                    ;;
                *)
                    echo "Error: 'instances ${instances_verb}' is not a recognized command (expected ls or create)" 1>&2
                    exit 1
                    ;;
            esac
        elif [ "${first_arg}" = "profiles" ]; then
            # Noun word supporting exactly two sub-verbs: ls and create.
            # Profile deletion is deliberately NOT a third verb here — per the
            # resolved plan/notes/profiles-delete-ambiguity.md, deletion is
            # exclusively "ai-sandbox <name> delete" via the shared
            # flat-namespace per-name dispatch (completed in
            # phase-02-profiles-resource task 002), symmetric with how
            # instances are deleted. CMD values are namespaced
            # ("profiles-ls"/"profiles-create", not "ls"/"create") because
            # those bare CMD values are already contractually tied to
            # do_list()/do_create() in src/index.sh's dispatch.
            remaining=("${remaining[@]:1}")
            if [ "${#remaining[@]}" -eq 0 ]; then
                echo "Error: 'profiles' requires a sub-verb (ls or create)" 1>&2
                exit 1
            fi
            local profiles_verb="${remaining[0]}"
            remaining=("${remaining[@]:1}")
            case "${profiles_verb}" in
                ls)
                    SANDBOX_NAME=""
                    CMD="profiles-ls"
                    ;;
                create)
                    CMD="profiles-create"
                    if [ "${#remaining[@]}" -eq 0 ]; then
                        echo "Error: 'profiles create' requires a profile name" 1>&2
                        exit 1
                    fi
                    SANDBOX_NAME="${remaining[0]}"
                    validate_sandbox_name "${SANDBOX_NAME}"
                    check_reserved_name "${SANDBOX_NAME}" "${RESERVED_NAMES}"
                    remaining=("${remaining[@]:1}")
                    ;;
                *)
                    echo "Error: 'profiles ${profiles_verb}' is not a recognized command (expected ls or create)" 1>&2
                    exit 1
                    ;;
            esac
        else
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
                remaining=("${remaining[@]:1}")
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
                check_reserved_name "${SANDBOX_NAME}" "${RESERVED_NAMES}"

                # Resolve whether SANDBOX_NAME is an existing instance,
                # existing profile, or neither. Phase 3.5 below gates CMD
                # against the resolved kind's allowed-verb set once CMD's
                # final value (after any Phase 3 promotion) is known.
                SANDBOX_NAME_KIND="$(resolve_name_kind "${SANDBOX_NAME}")"

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
            --static-playground)
                STATIC_PLAYGROUND=true
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
            --allow-egress)
                i=$(( i + 1 ))
                if [ "${i}" -ge "${#all_remaining[@]}" ]; then
                    echo "Error: --allow-egress requires a spec (<host-or-ip-or-cidr>:<port>)" 1>&2
                    exit 1
                fi
                _spec="${all_remaining[${i}]}"
                # Reject anything but exactly one ':' up front -- this also
                # rejects an unbracketed IPv6 literal (out of scope; see the
                # task doc's Assumptions) before it ever reaches the
                # host/port split below.
                _colon_count="$(grep -o ':' <<< "${_spec}" | wc -l | tr -d ' ')"
                if [ "${_colon_count}" -ne 1 ]; then
                    echo "Error: --allow-egress spec must contain exactly one ':' separating host from port (got '${_spec}')" 1>&2
                    exit 1
                fi
                _egress_host="${_spec%%:*}"
                _egress_port="${_spec##*:}"
                # is_valid_egress_port()/is_valid_egress_host() (src/utils.sh)
                # are the single source of truth for these checks -- also
                # reused by restore_saved_config()'s defense-in-depth
                # re-validation of a restored ai.sandbox.config label, so both
                # sites apply byte-for-byte the same rules.
                if ! is_valid_egress_port "${_egress_port}"; then
                    echo "Error: --allow-egress port must be an integer 1-65535 (got '${_egress_port}' in '${_spec}')" 1>&2
                    exit 1
                fi
                if ! is_valid_egress_host "${_egress_host}"; then
                    echo "Error: --allow-egress host part must be an IPv4 address, IPv4 CIDR, or hostname (got '${_egress_host}' in '${_spec}')" 1>&2
                    exit 1
                fi
                CLI_ALLOW_EGRESS+=("${_spec}")
                CONFIG_FLAGS_PROVIDED=true
                ;;
            --add-host)
                i=$(( i + 1 ))
                if [ "${i}" -ge "${#all_remaining[@]}" ]; then
                    echo "Error: --add-host requires a spec (<name>:<ip>)" 1>&2
                    exit 1
                fi
                _spec="${all_remaining[${i}]}"
                # Reject anything but exactly one ':' up front, matching the
                # --allow-egress colon-count guard above.
                _colon_count="$(grep -o ':' <<< "${_spec}" | wc -l | tr -d ' ')"
                if [ "${_colon_count}" -ne 1 ]; then
                    echo "Error: --add-host spec must contain exactly one ':' separating name from ip (got '${_spec}')" 1>&2
                    exit 1
                fi
                _add_host_name="${_spec%%:*}"
                _add_host_ip="${_spec##*:}"
                # is_valid_egress_hostname()/is_valid_ipv4_literal()
                # (src/utils.sh) are the single source of truth for these
                # checks -- also reused by is_valid_add_host_spec(), which
                # restore_saved_config()'s defense-in-depth re-validation of a
                # restored ai.sandbox.config label (task 003) calls, so both
                # sites apply byte-for-byte the same rules.
                if ! is_valid_egress_hostname "${_add_host_name}"; then
                    echo "Error: --add-host name part must be a valid hostname (got '${_add_host_name}' in '${_spec}')" 1>&2
                    exit 1
                fi
                # host.docker.internal is reserved: it is already the
                # container's static host-gateway alias
                # (docker/docker-compose.yaml's extra_hosts entry), and
                # Compose's extra_hosts lists APPEND rather than replace
                # across -f files, so a caller-supplied mapping for this
                # exact name would collide with it (nondeterministic
                # /etc/hosts resolution order) and could indeterminately
                # retarget which IP the host-access capability's firewall
                # rule opens (docker/init-firewall.sh resolves this same
                # name). See is_reserved_add_host_name() (src/utils.sh) for
                # the full rationale; also enforced on restore of a
                # previously-saved config via is_valid_add_host_spec().
                if is_reserved_add_host_name "${_add_host_name}"; then
                    echo "Error: --add-host name part 'host.docker.internal' is reserved -- it is already the container's static host-gateway alias and cannot be overridden via --add-host (got '${_spec}')" 1>&2
                    exit 1
                fi
                if ! is_valid_ipv4_literal "${_add_host_ip}"; then
                    echo "Error: --add-host ip part must be an IPv4 address (got '${_add_host_ip}' in '${_spec}')" 1>&2
                    exit 1
                fi
                CLI_ADD_HOST+=("${_spec}")
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
                    CMD="${rarg}"
                    cmd_defaulted=false
                else
                    ARGS+=("${rarg}")
                fi
                ;;
        esac
        i=$(( i + 1 ))
    done

    # --- Phase 3.5: verb-gating for the flat per-name dispatch path ---
    # SANDBOX_NAME_KIND is only ever non-empty when SANDBOX_NAME was resolved
    # from a bare name in Phase 2's per-name else branch above, so this is a
    # no-op for every other dispatch shape (ls / instances / profiles noun /
    # global / bare per-instance command word). Runs after Phase 3 so CMD
    # reflects any promotion of a command word pushed past a leading flag.
    #
    # Note: SANDBOX_NAME_KIND = "instance" here also covers the "Docker was
    # unreachable" case (resolve_name_kind() falls back to "instance" rather
    # than "unknown" when it can't ask docker -- see Bug 1 in the
    # phase-02-profiles-resource follow-up review), so no special-casing is
    # needed in this gate: an unreachable-docker name is simply allowed
    # through unrestricted, same as a confirmed instance, and the downstream
    # Docker-preflight/auto-start logic in src/index.sh decides what happens
    # next.
    if [ -n "${SANDBOX_NAME_KIND}" ]; then
        if [ "${SANDBOX_NAME_KIND}" = "unknown" ]; then
            echo "Error: '${SANDBOX_NAME}' is not a known instance or profile" 1>&2
            exit 1
        elif [ "${SANDBOX_NAME_KIND}" = "profile" ]; then
            local profile_verb_ok=false pc
            for pc in ${PROFILE_COMMANDS}; do
                if [ "${CMD}" = "${pc}" ]; then
                    profile_verb_ok=true
                    break
                fi
            done
            if [ "${profile_verb_ok}" != "true" ]; then
                echo "Error: '${SANDBOX_NAME}' is a profile, not an instance — 'ai-sandbox ${SANDBOX_NAME} ${CMD}' is not supported for profiles; only detail/delete are allowed" 1>&2
                exit 1
            fi
        fi
        # SANDBOX_NAME_KIND = "instance": every PER_INSTANCE_COMMANDS word,
        # plus the passthrough fallback, is allowed unrestricted -- matches
        # today's existing, unchanged per-instance dispatch (no allow-list
        # needed).
    fi

    # --- Phase 4: build SANDBOX_PROFILES from PROFILES (for `create`) ---
    if [ "${CMD}" = "create" ] && [ "${#PROFILES[@]}" -gt 0 ]; then
        local IFS=,
        SANDBOX_PROFILES="${PROFILES[*]}"
    fi

    # --- Phase 5: QUIET default ---
    if [ -z "${QUIET}" ]; then
        if [ "${CMD}" = "detail" ] \
            && [ "${STATUS_JSON}" != "true" ] \
            && [ "${STATUS_TEST_CHECK}" != "true" ]; then
            QUIET=0
        else
            QUIET=1
        fi
    fi

    # Note: CLI_MARKETPLACES, CLI_PLUGINS, CLI_ALLOW_EGRESS, and CLI_ADD_HOST
    # are bash arrays; bash cannot export arrays across process boundaries.
    # They are consumed within the same shell session by index.sh before any
    # subprocess boundary is crossed — same pattern as PROFILES.
    export SANDBOX_NAME SANDBOX_NAME_KIND SANDBOX_PROFILES CMD ARGS PROFILES MODE_OVERRIDE \
           NO_ISOLATE_CONFIG STATIC_PLAYGROUND CONFIG_FLAGS_PROVIDED AUTO_YES ENTER_AFTER_CREATE \
           STATUS_JSON STATUS_TEST_CHECK QUIET \
           CLI_MARKETPLACES CLI_PLUGINS CLI_ENABLE_ALL CLEAN_SLATE CLI_ALLOW_EGRESS CLI_ADD_HOST
}
