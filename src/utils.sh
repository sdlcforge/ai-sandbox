# shellcheck shell=bash
# shellcheck disable=SC2086 # we want word splitting for 'COMPOSE_FILES'

export QUIET=1 # default — overridden by parse_options

function qecho() {
    if [ ${QUIET} -eq 0 ]; then echo "$@"; fi
}

# Returns the container name for the current SANDBOX_NAME.
# All docker inspect / docker rm -f calls that target the running container
# must use this helper rather than the literal string 'ai-sandbox'.
function sandbox_container_name() {
    printf 'ai-sandbox-%s\n' "${SANDBOX_NAME}"
}

# Return 0 if a sandbox instance container (running or stopped) already exists
# for name $1, 1 if the docker query succeeded but found no such container,
# 2 if the docker query itself failed (e.g. daemon not running/reachable).
# Factored out of src/create.sh's do_create(), which had this query inlined,
# so both the create-collision check and resolve_name_kind()
# (phase-02-profiles-resource task 002) can reuse it.
#
# The 1-vs-2 distinction matters: callers that only care about "does an
# instance definitely exist" can keep treating this as boolean (both 1 and 2
# are falsy in an `if instance_exists ...` test), but resolve_name_kind()
# needs to tell "definitely no such container" apart from "couldn't ask
# docker" so it doesn't misclassify a Docker-unreachable name as "unknown"
# (see Bug 1 in the phase-02-profiles-resource follow-up review). Unlike the
# prior `2>/dev/null || true` form, a failed `docker ps` now propagates its
# real exit status via `||` rather than being swallowed.
function instance_exists() {
    local name="${1:-}"
    local existing
    existing="$(docker ps -a \
        --filter "name=^ai-sandbox-${name}$" \
        --format '{{.Names}}' 2>/dev/null)" || return 2
    [ -n "${existing}" ]
}

function check_docker() {
    qecho -n "Checking docker is running... "
    if ! docker info > /dev/null 2>&1; then
        if [ "${1:-}" != "" ]; then
            qecho "$1"
        else
            qecho "NOT running."
        fi
        return 1
    fi
    qecho "confirmed."
    return 0
}

function download_tool() {
    local url=$1
    local file=$2
    if [ ! -f "${TOOL_CACHE_DIR}/${file}" ]; then
        qecho "Downloading ${file}..."
        if [ ${QUIET} -eq 0 ]; then
            curl -f -SL "${url}" -o "${TOOL_CACHE_DIR}"/"${file}"
        else
            curl --progress-bar -f -SL "${url}" -o "${TOOL_CACHE_DIR}"/"${file}"
        fi
    else
        qecho "${file} already exists, skipping download"
    fi
}

function start_shell() {
    # Warn the user when they're entering a container with host-Docker access
    # enabled. DOCKER_HOST is only set inside the container when the proxy
    # overlay is in play (see docker-compose.proxy.yaml), so it doubles as a
    # runtime detector.
    # shellcheck disable=SC2016 # ${DOCKER_HOST} must be expanded by the in-container shell, not the host
    local banner='if [ -n "${DOCKER_HOST:-}" ]; then printf "\033[1;33m%s\033[0m\n" "WARNING: This container is running with docker support activated. This gives the container access to docker on the host and it may be possible for the AI or another program to breakout of the container via this access." >&2; fi; '
    # 'ai-sandbox' here is the compose service name, not the container name.
    # -p "${COMPOSE_PROJECT}" scopes the exec to this instance's compose
    # project, matching every other compose invocation in the codebase
    # (e.g. src/create.sh, src/index.sh) -- without it, exec resolves against
    # the wrong default project scope for named instances and fails with
    # "service \"ai-sandbox\" is not running".
    docker compose -p "${COMPOSE_PROJECT}" ${COMPOSE_FILES} exec -u ${HOST_USER} ai-sandbox bash -c \
        "${banner}if [ -d \"${START_DIR}\" ]; then cd \"${START_DIR}\" && exec zsh; else exec zsh; fi"
}

# Enter the just-started/updated container's shell when CMD is "enter" (a
# bare `start` leaves the container running without attaching). Extracted
# from the start/enter dispatch branch in src/index.sh so start_shell's exit
# code can be exercised directly by unit tests: a start_shell failure must
# propagate through this function rather than being swallowed.
function run_enter_shell_if_requested() {
    if [ "${CMD}" == "enter" ]; then
        start_shell
    fi
}

# Return 0 if the ai-sandbox container exists (running or stopped), 1 otherwise.
function is_container_running_or_stopped() {
    docker inspect "$(sandbox_container_name)" >/dev/null 2>&1
}

# Return 0 if the ai-sandbox container is currently in `running` state, 1 otherwise.
function is_container_running() {
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$(sandbox_container_name)" 2>/dev/null) || return 1
    [ "${state}" = "running" ]
}

# Return 0 if the current SANDBOX_NAME's container has a persisted
# ai.sandbox.docker-proxy label (docker/docker-compose.yaml) of "true", 1
# otherwise (label absent/false, or no container exists yet). Single-field
# docker inspect -- the inspect itself fails when no container exists for
# SANDBOX_NAME, and that failure is treated as "false" via `|| return 1`, so
# this is naturally scoped to "a container already exists" (mirroring
# is_container_running_or_stopped()'s guard semantics) without a second,
# separate existence-check round trip.
#
# Used as an authoritative fallback for EFFECTIVE_PROXY (src/index.sh) when
# this invocation's profile resolution would otherwise say the docker
# capability is absent, even though the instance was actually created with
# it -- see that call site's comment for the full rationale.
function is_docker_proxy_label_true() {
    local label
    label="$(docker inspect -f \
        '{{index .Config.Labels "ai.sandbox.docker-proxy"}}' \
        "$(sandbox_container_name)" 2>/dev/null)" || return 1
    [ "${label}" = "true" ]
}

# Return 0 if the named capability is present in PROFILE_CAPABILITIES (a
# space-separated list), 1 otherwise. Matches whole tokens, not substrings.
# $1 — capability name to test for.
function profile_has_capability() {
    local want="$1" cap
    for cap in ${PROFILE_CAPABILITIES:-}; do
        [ "${cap}" = "${want}" ] && return 0
    done
    return 1
}

# Return 0 (true) if src/index.sh's restore call site should attempt
# restore_saved_config() for the given CMD, 1 (false) otherwise.
#
# Every per-instance CMD value reachable at that call site --
# PER_INSTANCE_COMMANDS (src/options.sh) minus `create`, plus any arbitrary
# word forwarded to the docker-compose passthrough branch (src/index.sh's
# final dispatch `else`) -- operates on an already-created instance, so its
# compose-file assembly (and in particular EFFECTIVE_PROXY / the docker
# capability, which gates whether docker-compose.proxy.yaml's sidecar and
# network are included) must reflect that instance's actual persisted
# composition rather than just whatever --profile flags (usually none) this
# particular invocation passed. Without this, running e.g. `delete`/`clean`/
# `stop`/`fix-ssh` with no --profile flag on a docker-capable instance
# silently drops the docker capability for that invocation's compose-file
# list, leaving the docker-socket-proxy sidecar container/network orphaned
# (stop) or only partially torn down (delete/clean), or the recreated
# container missing DOCKER_HOST (fix-ssh).
#
# restore_saved_config()'s own internal guard (CONFIG_FLAGS_PROVIDED /
# is_container_running_or_stopped) already makes it safe to call
# unconditionally for all of those CMD values, so this predicate only needs
# to exclude `create`: it deliberately provisions fresh state and already
# rejects name collisions in do_create() (src/create.sh) before a restored
# value would ever be consulted -- calling restore_saved_config() ahead of
# that check would be a harmless but pointless `docker inspect`.
# $1 -- the CMD value to test.
function should_restore_config() {
    [ "${1:-}" != "create" ]
}

# Return 0 (true) if src/index.sh's EFFECTIVE_PROXY label-fallback block
# (the container's persisted ai.sandbox.docker-proxy label overriding this
# invocation's profile-resolved EFFECTIVE_PROXY from false to true) should
# apply for the given CMD and CONFIG_FLAGS_PROVIDED, 1 (false) otherwise.
#
# The orphaned-sidecar bug that fallback protects against (phase-01/003) only
# ever manifests on the four commands that can act on an *existing* instance
# without necessarily re-specifying its original composition: stop/delete/
# clean (whose `docker compose ... stop`/`down` calls silently drop the proxy
# sidecar/network from their compose-file list when EFFECTIVE_PROXY
# incorrectly resolves false) and fix-ssh (whose --force-recreate would drop
# DOCKER_HOST from the recreated container). stop/delete/clean apply the
# fallback unconditionally: these commands tear down (or pause) whatever
# composition *actually exists*, so there is no legitimate "explicit
# invocation" story for them to override the instance's persisted label.
#
# fix-ssh/start/enter/up, by contrast, can recompose the container (fix-ssh
# and start/enter force-recreate it; up drives the compose file list
# directly), so whether *this invocation* is the one deciding composition
# turns on CONFIG_FLAGS_PROVIDED (src/options.sh), not on which of these four
# CMD values was typed: when CONFIG_FLAGS_PROVIDED is "true" (this run itself
# passed a composition-changing flag such as --profile/--mode/etc.), that
# explicit, confirmed choice must win -- including deliberately dropping the
# docker capability (docs/architecture.md's "Matches" subsection, "explicit
# invocation always wins") -- so the fallback must NOT apply, or an explicit
# `start --profile <non-docker>` / `fix-ssh --profile <non-docker>` on a
# docker-capable instance would have the label fallback silently re-grant
# network access to the docker-socket-proxy sidecar (a documented
# container-escape vector, docker/docker-compose.proxy.yaml) against the
# user's explicit intent. When CONFIG_FLAGS_PROVIDED is not "true" (a bare
# restore/resume -- restore_saved_config() decided composition, not the
# user), the fallback DOES apply: otherwise a bare `start`/`enter` against an
# instance whose persisted docker-granting profile has since become
# unresolvable would silently lose the capability again (the same
# orphaned-sidecar bug class, reintroduced for this path).
#
# Every other per-instance CMD -- create/detail/build/user-exec/root-exec/
# attach -- must NOT apply the fallback regardless of CONFIG_FLAGS_PROVIDED:
# create is excluded because it provisions fresh state (no prior container to
# read a label from -- is_docker_proxy_label_true() would always return false
# there anyway, via its own container-existence guard); detail is excluded
# because do_status() never consumes EFFECTIVE_PROXY; the rest never touch
# composition. Neither exclusion changes behavior; both just skip a provably-
# wasted docker inspect call.
# $1 -- the CMD value to test.
# $2 -- this invocation's CONFIG_FLAGS_PROVIDED value ("true" or "false");
#       only consulted for fix-ssh/start/enter/up.
function should_force_proxy_label_fallback() {
    case "${1:-}" in
        stop|delete|clean) return 0 ;;
        fix-ssh|start|enter|up) [ "${2:-}" != "true" ] ;;
        *) return 1 ;;
    esac
}

# Return 0 if $1 is a valid dotted-decimal octet (0-255, no leading zero),
# 1 otherwise. Used by netmask_to_prefix()/network_address() below to
# validate each octet before handing it to bash arithmetic ($(( ))).
# Rejecting a leading zero isn't just canonical-form pedantry: bash
# arithmetic parses a leading-zero numeral (e.g. "008") as octal, and an
# invalid octal digit (8 or 9) aborts with "value too great for base" --
# this guard keeps that string from ever reaching `$(( ))` in the first
# place, so a malformed octet fails the clean "return 1" path uniformly
# instead of also leaking a bash-internal error to stderr.
function is_octet() {
    local octet="$1"
    case "${octet}" in
        ''|*[!0-9]*) return 1 ;;
        0) return 0 ;;
        0*) return 1 ;;
    esac
    [ "${octet}" -le 255 ]
}

# Count the set bits across a dotted-decimal netmask's four octets to derive
# its CIDR prefix length (e.g. "255.255.255.0" -> "24"). Echoes the prefix
# length and returns 0 on success; returns 1 (nothing echoed) if $1 is not
# exactly four dot-separated valid octets (see is_octet() above) -- callers
# (see compute_lan_cidr() below) treat that as "detection failed", not a
# crash. Bit-counted per octet rather than looked up from a fixed table so
# any octet value 0-255 is handled uniformly (including non-contiguous
# inputs; garbage in still yields a deterministic bit count rather than an
# error).
function netmask_to_prefix() {
    local netmask="$1"
    local -a octets
    IFS='.' read -ra octets <<< "${netmask}"
    [ "${#octets[@]}" -eq 4 ] || return 1
    local octet n bits prefix=0
    for octet in "${octets[@]}"; do
        is_octet "${octet}" || return 1
        n=${octet}
        bits=0
        while [ "${n}" -gt 0 ]; do
            bits=$((bits + (n & 1)))
            n=$((n >> 1))
        done
        prefix=$((prefix + bits))
    done
    printf '%s' "${prefix}"
}

# Bitwise-AND a dotted-decimal IP address with a dotted-decimal netmask,
# octet by octet, to derive the network address (e.g. "192.168.1.42" +
# "255.255.255.0" -> "192.168.1.0"). Echoes the network address and returns
# 0 on success; returns 1 (nothing echoed) if either $1 or $2 is not exactly
# four dot-separated valid octets (see is_octet() above).
function network_address() {
    local ip="$1" netmask="$2"
    local -a ip_octets mask_octets
    IFS='.' read -ra ip_octets <<< "${ip}"
    IFS='.' read -ra mask_octets <<< "${netmask}"
    [ "${#ip_octets[@]}" -eq 4 ] && [ "${#mask_octets[@]}" -eq 4 ] || return 1
    local i octet_val mask_val
    local -a result=()
    for i in 0 1 2 3; do
        octet_val="${ip_octets[$i]}"
        mask_val="${mask_octets[$i]}"
        is_octet "${octet_val}" || return 1
        is_octet "${mask_val}" || return 1
        result+=( "$(( octet_val & mask_val ))" )
    done
    printf '%s.%s.%s.%s' "${result[0]}" "${result[1]}" "${result[2]}" "${result[3]}"
}

# --- --allow-egress spec validation -------------------------------------
# Shared by src/options.sh's --allow-egress flag parser (fresh CLI input,
# per-failure-mode error messages) and restore_saved_config() below
# (restored ai.sandbox.config docker-label input, generic warn-and-drop) so
# both sites apply byte-for-byte the same rules. Factored into functions
# rather than duplicated inline the way --add-marketplace's simple scheme
# check is duplicated (see restore_saved_config()'s saved_marketplaces
# handling) because this check is materially more involved (colon-count +
# port-range + three-way host-format check) -- two independently
# hand-maintained copies of that would risk silently drifting apart, and a
# diverging restore-time check would let an invalid egress spec reach Task
# 002's container-init-time firewall-rule application.

# Return 0 if $1 is a syntactically valid dotted-decimal IPv4 address (four
# dot-separated valid octets -- see is_octet() above), 1 otherwise.
function is_valid_ipv4_literal() {
    local addr="$1"
    # Anchor-match the whole string against a strict 4-octet shape first.
    # Bash's `read -a` silently drops a single trailing empty field (e.g.
    # IFS='.' read -ra octets <<< "1.2.3.4." yields 4 elements, not 5), so a
    # naive split-and-count on a string with a trailing dot would incorrectly
    # pass. This regex anchor rejects that (and any other non-4-octet shape)
    # up front before the per-octet range checks below ever run.
    [[ "${addr}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local -a octets
    IFS='.' read -ra octets <<< "${addr}"
    [ "${#octets[@]}" -eq 4 ] || return 1
    local octet
    for octet in "${octets[@]}"; do
        is_octet "${octet}" || return 1
    done
    return 0
}

# Return 0 if $1 is a syntactically valid IPv4 CIDR (a.b.c.d/n -- exactly one
# '/', a valid IPv4 literal address part, and a prefix length 0-32), 1
# otherwise.
function is_valid_ipv4_cidr() {
    local cidr="$1" slash_count addr prefix
    slash_count="$(grep -o '/' <<< "${cidr}" | wc -l | tr -d ' ')"
    [ "${slash_count}" -eq 1 ] || return 1
    addr="${cidr%%/*}"
    prefix="${cidr##*/}"
    is_valid_ipv4_literal "${addr}" || return 1
    [[ "${prefix}" =~ ^[0-9]{1,2}$ ]] || return 1
    [ "${prefix}" -le 32 ]
}

# Return 0 if $1 matches the --allow-egress task doc's "basic hostname
# regex" (letters, digits, hyphens, and dots only; non-empty; no spaces or
# other characters). Deliberately shallow -- no RFC 1123 label structure, no
# leading/trailing-dot rejection, no DNS resolution -- Task 002
# (002-wire-allow-egress-into-firewall.md) is responsible for any deeper
# validation, at container-init time.
function is_valid_egress_hostname() {
    local host="$1"
    [[ "${host}" =~ ^[A-Za-z0-9.-]+$ ]]
}

# Return 0 if $1 is a valid --allow-egress host-part: an IPv4 literal, an
# IPv4 CIDR, or a basic hostname (checked in that order -- a bare IPv4
# literal also matches the loose hostname regex above, so IPv4/CIDR are
# tried first to classify it correctly). A dotted-quad-shaped string (four
# dot-separated all-digit groups, e.g. "999.1.1.1", optionally with one
# trailing dot, e.g. "1.2.3.4.") that fails strict IPv4 validation is
# rejected outright rather than falling through to the loose hostname regex,
# which would otherwise silently accept an out-of-range octet -- or a
# malformed trailing-dot literal, which the loose hostname charset check
# alone can't distinguish from a genuine (if unusual) hostname -- as an
# opaque "hostname". Both are almost certainly a typo'd IP literal, not a
# genuine hostname.
function is_valid_egress_host() {
    local host="$1"
    is_valid_ipv4_literal "${host}" && return 0
    is_valid_ipv4_cidr "${host}" && return 0
    if [[ "${host}" =~ ^[0-9]+(\.[0-9]+){3}\.?$ ]]; then
        return 1
    fi
    is_valid_egress_hostname "${host}"
}

# Return 0 if $1 is a valid --allow-egress port -- an integer 1-65535. The
# {1,5} digit bound keeps an absurdly long digit string from ever reaching
# the `[ -le ]` numeric comparison below, where bash's test builtin would
# abort with an "integer expected" error rather than a clean validation
# failure (65535 is 5 digits, so 5 is the natural bound).
function is_valid_egress_port() {
    local port="$1"
    [[ "${port}" =~ ^[0-9]{1,5}$ ]] || return 1
    [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ]
}

# Return 0 if $1 is a fully valid --allow-egress spec
# (<host-or-ip-or-cidr>:<port>): exactly one ':' separating a valid host part
# (is_valid_egress_host()) from a valid port part (is_valid_egress_port()).
# Used by restore_saved_config() below to re-validate a restored spec as a
# single pass/fail check (see the file header comment on this block).
function is_valid_allow_egress_spec() {
    local spec="$1" colon_count host port
    colon_count="$(grep -o ':' <<< "${spec}" | wc -l | tr -d ' ')"
    [ "${colon_count}" -eq 1 ] || return 1
    host="${spec%%:*}"
    port="${spec##*:}"
    is_valid_egress_port "${port}" || return 1
    is_valid_egress_host "${host}"
}

# --- --add-host spec validation ------------------------------------------
# Shared by src/options.sh's --add-host flag parser (fresh CLI input,
# per-failure-mode error messages) and restore_saved_config()'s
# defense-in-depth re-validation of a restored ai.sandbox.config label (task
# 003) so both sites apply byte-for-byte the same rules -- same sharing
# pattern as the --allow-egress block above.

# Return 0 if $1 (a --add-host name part, already syntactically validated by
# is_valid_egress_hostname()) is the reserved name "host.docker.internal",
# case-insensitively (DNS names are case-insensitive, and the collision this
# guards against is resolver-level, not string-level).
#
# docker/docker-compose.yaml's base file already statically maps this exact
# name to the container's host-gateway IP via its own
# `extra_hosts: - "host.docker.internal:host-gateway"` entry. A caller
# supplying `--add-host host.docker.internal:<ip>` would land as a *second*,
# conflicting /etc/hosts line for the same name once merged with the
# generated override -- Compose's extra_hosts lists APPEND across `-f` files
# rather than replace (empirically confirmed -- see src/volume-override.sh's
# file-header comment), and which line a given resolver treats as primary is
# not reliably controlled (observed /etc/hosts ordering did not match simple
# base-then-override concatenation order). Worse, the host-access
# capability's firewall ACCEPT-chain (docker/init-firewall.sh) is built by
# resolving that exact same name (`getent ahostsv4 host.docker.internal`, in
# the shared network namespace with this container's firewall-init sidecar),
# so the collision can indeterminately retarget which IP host-access's
# firewall rule opens. Rejected outright at parse/restore time (see callers)
# rather than accepted-then-warned, since there is no safe way to reconcile
# the collision after the fact.
#
# `tr` rather than bash 4's `${var,,}` lowercasing -- this project targets
# macOS's stock bash 3.2 (see CLAUDE.md: "macOS-first bash CLI").
function is_reserved_add_host_name() {
    local name_lc
    name_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    [ "${name_lc}" = "host.docker.internal" ]
}

# Return 0 if $1 is a fully valid --add-host spec (<name>:<ip>): exactly one
# ':' separating a valid hostname (is_valid_egress_hostname()) that is not
# the reserved name (is_reserved_add_host_name()) from a valid IPv4 literal
# (is_valid_ipv4_literal()). Unlike --allow-egress's host part, --add-host's
# ip part must be a bare IPv4 literal specifically -- no CIDR, no hostname --
# since it is placed verbatim into the container's /etc/hosts (or
# equivalent), so is_valid_ipv4_literal() is used directly rather than the
# more permissive is_valid_egress_host().
function is_valid_add_host_spec() {
    local spec="$1" colon_count name ip
    colon_count="$(grep -o ':' <<< "${spec}" | wc -l | tr -d ' ')"
    [ "${colon_count}" -eq 1 ] || return 1
    name="${spec%%:*}"
    ip="${spec##*:}"
    is_valid_egress_hostname "${name}" || return 1
    is_reserved_add_host_name "${name}" && return 1
    is_valid_ipv4_literal "${ip}"
}

# Compute the host's primary LAN CIDR on macOS: the default-route
# interface's IP/netmask (via `route get default` + `ipconfig`), converted
# to network/prefixlen notation (e.g. "192.168.1.0/24"). Echoes the CIDR on
# success. Only meant to be called when the lan-access capability is active
# (see src/index.sh) -- avoids the route/ipconfig cost on every invocation,
# same rationale as the sibling host-access capability's lsof avoidance.
#
# Fails soft by design (plan/phase-02-network-capabilities/005-*.md
# Requirement 1): every failure path (no default route, VPN-only interface,
# unresolvable IP/netmask, unrecognized netmask, non-macOS host) logs a
# warning to stderr and echoes nothing, returning 0 -- a missing LAN CIDR
# must not block container start. Callers treat an empty result as "no rule
# to add", not an error.
#
# macOS-only: `route get default` / `ipconfig` have no portable Linux
# equivalent (`ip route` / `ip addr` would be the Linux analog) -- flagged
# explicitly here per Requirement 4 rather than silently producing an empty
# result with no explanation on Linux.
function compute_lan_cidr() {
    if [ "$(uname)" != "Darwin" ]; then
        echo "Warning: lan-access: host-side LAN CIDR detection (route get default / ipconfig) is macOS-only; AI_SANDBOX_LAN_CIDR left empty on this platform" >&2
        return 0
    fi

    local iface ip_addr netmask prefix network
    iface="$(route get default 2>/dev/null | awk '/interface:/{print $2}')" || true
    if [ -z "${iface}" ]; then
        echo "Warning: lan-access: could not determine the host's default-route interface (no default route? VPN-only?); AI_SANDBOX_LAN_CIDR left empty" >&2
        return 0
    fi

    ip_addr="$(ipconfig getifaddr "${iface}" 2>/dev/null)" || true
    netmask="$(ipconfig getoption "${iface}" subnet_mask 2>/dev/null)" || true
    if [ -z "${ip_addr}" ] || [ -z "${netmask}" ]; then
        echo "Warning: lan-access: could not determine IP address/subnet mask for interface '${iface}'; AI_SANDBOX_LAN_CIDR left empty" >&2
        return 0
    fi

    prefix="$(netmask_to_prefix "${netmask}")" || true
    if [ -z "${prefix}" ]; then
        echo "Warning: lan-access: unrecognized subnet mask '${netmask}' for interface '${iface}'; AI_SANDBOX_LAN_CIDR left empty" >&2
        return 0
    fi

    network="$(network_address "${ip_addr}" "${netmask}")" || true
    if [ -z "${network}" ]; then
        echo "Warning: lan-access: could not compute a network address from '${ip_addr}'/'${netmask}'; AI_SANDBOX_LAN_CIDR left empty" >&2
        return 0
    fi

    printf '%s/%s\n' "${network}" "${prefix}"
}

# Restore PROFILES / MODE_OVERRIDE / NO_ISOLATE_CONFIG / CLEAN_SLATE /
# CLI_MARKETPLACES / CLI_PLUGINS / CLI_ENABLE_ALL / CLI_ALLOW_EGRESS /
# STATIC_PLAYGROUND / CLI_ADD_HOST -- the complete ten-dimension config-input
# record (see plan/notes/config-persistence-design.md; allow_egress is the
# eighth dimension, added alongside the original seven, static_playground is
# the ninth, and add_host is the tenth) -- from the single ai.sandbox.config
# label saved on the container at `create` time, when the current invocation
# didn't pass any config-changing flags itself. Called for every CMD except
# `create` (see should_restore_config()) -- broadened from the original
# bare-`start`/`enter`-only trigger, since every other per-instance command
# (`stop`, `delete`, `clean`, `fix-ssh`, `build`, `user-exec`, `root-exec`,
# `attach`, `detail`, `up`, and the docker-compose passthrough) also acts on
# an already-created instance and needs its compose-file assembly to reflect
# that instance's actual persisted composition, not just whatever flags
# (usually none) this particular invocation passed. When
# CONFIG_FLAGS_PROVIDED is "true" (i.e.
# --profile/--mode/--no-isolate-config/--add-marketplace/--enable-plugin/
# --enable-all/--clean/--allow-egress/--static-playground/--add-host was
# explicitly passed this run) or no container exists yet, returns
# immediately without touching any of the ten globals, so the explicit flags
# on the current invocation always win.
#
# No fallback of any kind: only the single ai.sandbox.config label is read.
# When the label is absent or empty -- including on any container created
# before this label existed -- the function does nothing further. This is an
# explicit product decision (design note Sec 2.5/2.6: no external users yet, a
# single label-based config regime is preferred over supporting two), not a
# gap to guard against.
# shellcheck disable=SC2034 # PROFILES/MODE_OVERRIDE/NO_ISOLATE_CONFIG/CLEAN_SLATE/CLI_MARKETPLACES/CLI_PLUGINS/CLI_ENABLE_ALL/CLI_ALLOW_EGRESS/STATIC_PLAYGROUND/CLI_ADD_HOST are globals consumed downstream by src/index.sh (profile-resolution, EFFECTIVE_MODE, and CLI-merge phases), not local to this function
function restore_saved_config() {
    if [ "${CONFIG_FLAGS_PROVIDED}" != "true" ] && is_container_running_or_stopped; then
        local ctr_name saved_config_b64 saved_config_json
        local saved_profiles saved_mode saved_no_isolate saved_clean
        local saved_marketplaces saved_plugins saved_enable_all saved_allow_egress
        local saved_static_playground saved_add_host
        ctr_name="$(sandbox_container_name)"
        saved_config_b64="$(docker inspect -f \
            '{{index .Config.Labels "ai.sandbox.config"}}' \
            "${ctr_name}" 2>/dev/null || true)"
        [ -n "${saved_config_b64}" ] || return 0

        # Defense-in-depth size bound (followup qVbA): the label is only
        # writable at container-create time by the host process itself, so
        # the practical risk here is low, but bound it anyway before
        # base64-decoding/jq-parsing. 16KB is generously larger than any real
        # ten-field config record (profiles/mode/marketplaces/plugins/
        # allow_egress/static_playground/add_host are short strings/lists/
        # booleans) could ever produce. An oversized value is treated the
        # same as an absent label -- nothing to restore -- rather than
        # erroring.
        local max_config_b64_len=16384
        [ "${#saved_config_b64}" -le "${max_config_b64_len}" ] || return 0

        saved_config_json="$(printf '%s' "${saved_config_b64}" | base64 -d 2>/dev/null || true)"
        [ -n "${saved_config_json}" ] || return 0

        # Extract each field with its own jq call (one per input dimension) so
        # every value is independently guarded rather than packed into a
        # delimited line -- packing risks a delimiter collision (and, with
        # whitespace-class separators like tab, bash `read`'s IFS collapses
        # leading/trailing empty fields, silently shifting values). Lists are
        # joined with '|' (not ',') so entries such as marketplace URLs that
        # may contain a comma pass through correctly -- same convention as
        # AI_SANDBOX_MARKETPLACES in src/index.sh. Booleans are tested against
        # `null` explicitly (rather than jq's `//` operator) because `//`
        # treats a `false` value itself as absent, which would otherwise make
        # an explicitly-saved `false` indistinguishable from a missing field.
        saved_profiles="$(printf '%s' "${saved_config_json}" | jq -r '(.profiles // []) | join("|")' 2>/dev/null || true)"
        saved_mode="$(printf '%s' "${saved_config_json}" | jq -r '.mode // ""' 2>/dev/null || true)"
        saved_no_isolate="$(printf '%s' "${saved_config_json}" | jq -r 'if .no_isolate_config == null then "" else (.no_isolate_config | tostring) end' 2>/dev/null || true)"
        saved_clean="$(printf '%s' "${saved_config_json}" | jq -r 'if .clean_slate == null then "" else (.clean_slate | tostring) end' 2>/dev/null || true)"
        saved_marketplaces="$(printf '%s' "${saved_config_json}" | jq -r '(.marketplaces // []) | join("|")' 2>/dev/null || true)"
        saved_plugins="$(printf '%s' "${saved_config_json}" | jq -r '(.plugins // []) | join("|")' 2>/dev/null || true)"
        saved_enable_all="$(printf '%s' "${saved_config_json}" | jq -r 'if .enable_all_plugins == null then "" else (.enable_all_plugins | tostring) end' 2>/dev/null || true)"
        saved_allow_egress="$(printf '%s' "${saved_config_json}" | jq -r '(.allow_egress // []) | join("|")' 2>/dev/null || true)"
        saved_static_playground="$(printf '%s' "${saved_config_json}" | jq -r 'if .static_playground == null then "" else (.static_playground | tostring) end' 2>/dev/null || true)"
        saved_add_host="$(printf '%s' "${saved_config_json}" | jq -r '(.add_host // []) | join("|")' 2>/dev/null || true)"

        if [ -n "${saved_profiles}" ]; then
            # Re-validate that each restored profile name still resolves via
            # the same three discovery locations profile-installer.js's
            # findProfile() checks (profile_exists(), src/profiles.sh) --
            # mirrors the marketplace-scheme re-validation a few lines below.
            # A profile that resolved fine at `create` time can go stale
            # later (deleted, renamed, or a project-local profile only
            # resolvable relative to the create-time CWD). Without this
            # check, restoring an unresolvable name verbatim makes
            # bin/profile-installer.js's loadProfile() call die() ->
            # process.exit(1), and src/index.sh's
            # `PROFILE_INSTALLER_OUTPUT="$(node ...)" || exit $?` propagates
            # that failure, hard-aborting the whole invocation before CMD
            # dispatch is ever reached -- including delete/clean/stop, the
            # exact commands a user needs when an instance is broken. Drop
            # (with a warning) any entry that doesn't resolve, rather than
            # restoring it verbatim; when every restored name is dropped,
            # PROFILES stays unset and profile-installer.js falls back to its
            # own default-profile resolution (config.yaml, else [base,
            # mirror]) instead of failing.
            #
            # Note: profile_exists() deliberately rejects symlinked profile
            # files (src/profiles.sh) as a security guard, while
            # bin/profile-installer.js's findProfile() follows symlinks and
            # would load the same path -- so a restored name that only
            # resolves via a symlink is spuriously dropped here even though
            # profile-installer.js would have loaded it fine. Safe direction
            # (over-conservative fallback, not a crash); left as-is.
            local _restored_profiles _validated_profiles=() _prof
            IFS='|' read -ra _restored_profiles <<< "${saved_profiles}"
            for _prof in "${_restored_profiles[@]}"; do
                if profile_exists "${_prof}"; then
                    _validated_profiles+=("${_prof}")
                else
                    echo "Warning: dropping restored profile '${_prof}' -- no longer found in any search location (./profiles, \${XDG_CONFIG_HOME:-\$HOME/.config}/ai-sandbox/profiles, or the bundled profiles/ dir); falling back to default profile resolution" 1>&2
                fi
            done
            if [ "${#_validated_profiles[@]}" -gt 0 ]; then
                PROFILES=("${_validated_profiles[@]}")
            fi
        fi
        if [ -n "${saved_mode}" ]; then
            MODE_OVERRIDE="${saved_mode}"
        fi
        if [ -n "${saved_no_isolate}" ]; then
            NO_ISOLATE_CONFIG="${saved_no_isolate}"
        fi
        if [ -n "${saved_clean}" ]; then
            CLEAN_SLATE="${saved_clean}"
        fi
        if [ -n "${saved_marketplaces}" ]; then
            # Re-validate the https://|file:// scheme constraint here too --
            # src/options.sh's --add-marketplace parser enforces it on
            # freshly-typed input, but a restored value comes from a
            # persisted docker label rather than this run's CLI args, so it
            # must be independently checked before being trusted. Drop (with
            # a warning) any entry that doesn't match, rather than restoring
            # it verbatim.
            local _restored_mp _validated_marketplaces=() _mp
            IFS='|' read -ra _restored_mp <<< "${saved_marketplaces}"
            for _mp in "${_restored_mp[@]}"; do
                case "${_mp}" in
                    https://*|file://*)
                        _validated_marketplaces+=("${_mp}")
                        ;;
                    *)
                        echo "Warning: dropping restored marketplace ref with invalid scheme (must be https:// or file://): '${_mp}'" 1>&2
                        ;;
                esac
            done
            if [ "${#_validated_marketplaces[@]}" -gt 0 ]; then
                CLI_MARKETPLACES=("${_validated_marketplaces[@]}")
            fi
        fi
        if [ -n "${saved_plugins}" ]; then
            IFS='|' read -ra CLI_PLUGINS <<< "${saved_plugins}"
        fi
        if [ -n "${saved_enable_all}" ]; then
            CLI_ENABLE_ALL="${saved_enable_all}"
        fi
        if [ -n "${saved_allow_egress}" ]; then
            # Re-validate each restored spec against
            # is_valid_allow_egress_spec() (same rationale as
            # saved_marketplaces above: a restored value comes from a
            # persisted docker label rather than this run's CLI args, so it
            # must be independently checked before being trusted). Drop
            # (with a warning) any entry that doesn't validate, rather than
            # restoring it verbatim.
            local _restored_ae _validated_allow_egress=() _ae
            IFS='|' read -ra _restored_ae <<< "${saved_allow_egress}"
            for _ae in "${_restored_ae[@]}"; do
                if is_valid_allow_egress_spec "${_ae}"; then
                    _validated_allow_egress+=("${_ae}")
                else
                    echo "Warning: dropping restored --allow-egress spec that failed validation: '${_ae}'" 1>&2
                fi
            done
            if [ "${#_validated_allow_egress[@]}" -gt 0 ]; then
                CLI_ALLOW_EGRESS=("${_validated_allow_egress[@]}")
            fi
        fi
        if [ -n "${saved_static_playground}" ]; then
            STATIC_PLAYGROUND="${saved_static_playground}"
        fi
        if [ -n "${saved_add_host}" ]; then
            # Re-validate each restored spec against is_valid_add_host_spec()
            # (same rationale as saved_allow_egress above: a restored value
            # comes from a persisted docker label rather than this run's CLI
            # args, so it must be independently checked before being
            # trusted). Drop (with a warning) any entry that doesn't
            # validate, rather than restoring it verbatim.
            local _restored_ah _validated_add_host=() _ah
            IFS='|' read -ra _restored_ah <<< "${saved_add_host}"
            for _ah in "${_restored_ah[@]}"; do
                if is_valid_add_host_spec "${_ah}"; then
                    _validated_add_host+=("${_ah}")
                else
                    echo "Warning: dropping restored --add-host spec that failed validation: '${_ah}'" 1>&2
                fi
            done
            if [ "${#_validated_add_host[@]}" -gt 0 ]; then
                CLI_ADD_HOST=("${_validated_add_host[@]}")
            fi
        fi
    fi
}

# Return 0 if the running container's image + config-relevant labels match the
# current invocation's composition, 1 if they differ, 2 if no container is
# running. Reads AI_SANDBOX_IMAGE_TAG / PROFILE_COMPOSITION_HASH / EFFECTIVE_MODE
# / NO_ISOLATE_CONFIG / EFFECTIVE_PROXY / AI_SANDBOX_CLEAN_SLATE /
# AI_SANDBOX_MARKETPLACES / AI_SANDBOX_PLUGINS / AI_SANDBOX_ENABLE_ALL_PLUGINS /
# AI_SANDBOX_ALLOW_EGRESS / STATIC_PLAYGROUND / AI_SANDBOX_ADD_HOST /
# AI_SANDBOX_LAN_CIDR / AI_SANDBOX_HOST_LISTEN_PORTS from caller scope. The
# allow-egress-through-add-host group completes the derived-value comparison
# to the full effective-config dimension set (design note
# plan/notes/config-persistence-design.md Sec 2.3/2.6): an explicit
# invocation that changes
# marketplaces/plugins/enable-all/allow-egress/static-playground/add-host
# (e.g. `enter --add-marketplace NEW`, `enter --allow-egress 1.2.3.4:443`,
# `enter --static-playground` on a container created without it, or `enter
# --add-host myhost:10.0.0.5`) must be detected as a config change so it
# prompts a recreate rather than silently never applying. `:-` defaults on
# both sides of each comparison mean a container missing these labels
# (created before this label existed) compares equal to an empty/default
# current invocation rather than false-positiving. AI_SANDBOX_ALLOW_EGRESS
# and AI_SANDBOX_ADD_HOST are simply the CLI_ALLOW_EGRESS/CLI_ADD_HOST arrays
# joined with '|' (src/index.sh) -- unlike marketplaces/plugins/enable-all,
# there is no profile-level equivalent to merge in, since --allow-egress and
# --add-host are both CLI-only (see the task doc's Requirement 4, and
# phase-01/003's Requirement 1 for --add-host). STATIC_PLAYGROUND is compared
# directly (no derived AI_SANDBOX_* value -- it has no profile-level or
# CLI-merge step of its own, just the plain boolean global set by
# src/options.sh / restored by restore_saved_config()).
#
# AI_SANDBOX_LAN_CIDR / AI_SANDBOX_HOST_LISTEN_PORTS are different in kind
# from every comparison above: they are not CLI inputs at all, but host-
# detected state recomputed from live host state on every invocation
# (src/index.sh) -- they have no config-input JSON record entry and are
# never rehydrated by restore_saved_config(). Comparing them here is
# intentional (phase-01/003, closing followup yS0R): when host state drifts
# between two `start` invocations of a lan-access/host-access container (a
# WiFi switch, a background process opening a port), the freshly recomputed
# value differs from the label captured at create/start time, so this
# comparison returns 1 and the caller's existing consent prompt fires before
# recreating -- upholding "no silent recreate without consent" for
# host-detected state, not just CLI-provided state. This is NOT a bug: an
# instance recreate here is the intended outcome of host-state drift, not an
# accidental one. Both values are empty when the corresponding capability is
# inactive, so the comparison is then a no-op `"" = ""`.
function running_config_matches() {
    is_container_running || return 2
    local cur_image cur_hash cur_mode cur_no_isolate cur_proxy cur_clean ctr_name
    local cur_marketplaces cur_plugins cur_enable_all cur_allow_egress cur_static_playground
    local cur_add_host cur_lan_cidr cur_host_ports sep fmt line
    ctr_name="$(sandbox_container_name)"

    # Single multi-field `docker inspect` call replaces what used to be 9
    # separate single-field calls (one subprocess spawn + Docker API round
    # trip each) -- see followup 4DzF. Fields are joined with the ASCII Unit
    # Separator (0x1F), not a tab: bash `read` classifies tab as
    # IFS-whitespace and collapses/strips consecutive or leading/trailing
    # empty fields (several of these labels, e.g. marketplaces/plugins/
    # allow-egress, are legitimately empty) -- the same footgun
    # restore_saved_config()'s comment above already calls out for this very
    # label set. A pipe is out too: marketplace/plugin/allow-egress/add-host
    # label values already use '|' as their own internal join delimiter (see
    # AI_SANDBOX_MARKETPLACES in src/index.sh).
    sep=$'\x1f'
    fmt="{{.Config.Image}}${sep}{{index .Config.Labels \"ai.sandbox.profile-hash\"}}${sep}{{index .Config.Labels \"ai.sandbox.mode\"}}${sep}{{index .Config.Labels \"ai.sandbox.no-isolate-config\"}}${sep}{{index .Config.Labels \"ai.sandbox.docker-proxy\"}}${sep}{{index .Config.Labels \"ai.sandbox.clean-slate\"}}${sep}{{index .Config.Labels \"ai.sandbox.marketplaces\"}}${sep}{{index .Config.Labels \"ai.sandbox.plugins\"}}${sep}{{index .Config.Labels \"ai.sandbox.enable-all-plugins\"}}${sep}{{index .Config.Labels \"ai.sandbox.allow-egress\"}}${sep}{{index .Config.Labels \"ai.sandbox.static-playground\"}}${sep}{{index .Config.Labels \"ai.sandbox.add-host\"}}${sep}{{index .Config.Labels \"ai.sandbox.lan-cidr\"}}${sep}{{index .Config.Labels \"ai.sandbox.host-listen-ports\"}}"
    line="$(docker inspect -f "${fmt}" "${ctr_name}" 2>/dev/null || true)"
    IFS="${sep}" read -r cur_image cur_hash cur_mode cur_no_isolate cur_proxy \
        cur_clean cur_marketplaces cur_plugins cur_enable_all cur_allow_egress \
        cur_static_playground cur_add_host cur_lan_cidr cur_host_ports <<< "${line}"

    [ "${cur_image}" = "${AI_SANDBOX_IMAGE_TAG:-}" ] || return 1
    [ "${cur_hash}" = "${PROFILE_COMPOSITION_HASH:-}" ] || return 1
    [ "${cur_mode:-mirror}" = "${EFFECTIVE_MODE:-mirror}" ] || return 1
    [ "${cur_no_isolate:-false}" = "${NO_ISOLATE_CONFIG:-false}" ] || return 1
    [ "${cur_proxy:-false}" = "${EFFECTIVE_PROXY:-false}" ] || return 1
    [ "${cur_clean:-false}" = "${AI_SANDBOX_CLEAN_SLATE:-false}" ] || return 1
    [ "${cur_marketplaces:-}" = "${AI_SANDBOX_MARKETPLACES:-}" ] || return 1
    [ "${cur_plugins:-}" = "${AI_SANDBOX_PLUGINS:-}" ] || return 1
    [ "${cur_enable_all:-false}" = "${AI_SANDBOX_ENABLE_ALL_PLUGINS:-false}" ] || return 1
    [ "${cur_allow_egress:-}" = "${AI_SANDBOX_ALLOW_EGRESS:-}" ] || return 1
    [ "${cur_static_playground:-false}" = "${STATIC_PLAYGROUND:-false}" ] || return 1
    [ "${cur_add_host:-}" = "${AI_SANDBOX_ADD_HOST:-}" ] || return 1
    # Host-detected-state drift comparisons (followup yS0R) -- see the
    # function header comment above for why an intended-recreate here is not
    # a bug.
    [ "${cur_lan_cidr:-}" = "${AI_SANDBOX_LAN_CIDR:-}" ] || return 1
    [ "${cur_host_ports:-}" = "${AI_SANDBOX_HOST_LISTEN_PORTS:-}" ] || return 1
    return 0
}

# Prompt the user to confirm a destructive action that would stop the running
# container. Returns 0 on confirmation, 1 on rejection. Auto-confirms when
# AUTO_YES is set or when stdin is not a TTY (scripted/test environments).
# $1 — short reason shown in the prompt, e.g. "stopping the running sandbox"
function confirm_stop_running() {
    local reason="${1:-stopping the running sandbox}"
    if [ "${AUTO_YES:-false}" = "true" ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        return 0
    fi
    local answer
    printf 'About to %s. Continue? [y/N] ' "${reason}" >&2
    read -r answer || answer=""
    case "${answer}" in
        y|Y|yes|YES) return 0 ;;
        *) echo "Aborted." >&2; return 1 ;;
    esac
}

# Echoes the image-tag suffix for the current profile composition. Used as the
# Docker image tag suffix so each distinct profile composition gets its own
# image. Reads PROFILE_COMPOSITION_HASH from caller scope (set by
# profile-installer.js via Task 004's profile resolution phase).
# The hash is owned by profile-installer.js — do NOT recompute it here.
function profile_image_suffix() {
    printf 'profile-%s\n' "${PROFILE_COMPOSITION_HASH:-default}"
}

function variant_image_tag() {
    printf 'ai-sandbox:%s\n' "$(profile_image_suffix)"
}

# Return 0 (stale) if the variant image is missing, its stored profile hash
# label differs from the current PROFILE_COMPOSITION_HASH, or any input file
# (docker/ tree, assembled Dockerfile, or profile input files) is newer than
# the image's creation timestamp. Return 1 (fresh) otherwise.
#
# Profile-hash label check: the label ai.sandbox.profile-hash is written into
# the assembled Dockerfile by assemble-dockerfile.sh at build time. If the hash
# stored in the image does not match the current PROFILE_COMPOSITION_HASH the
# image was built from a different composition and must be rebuilt.
#
# PROFILE_INPUT_FILES contract (set by Task 004's profile resolution phase):
#   A newline-delimited list of absolute paths to profile YAML files and the src
#   files referenced by skills/hooks/agents/setup_script in the merged profile.
#   When unset, only docker/ files are checked (non-profile / legacy path).
#
# PROFILE_ASSEMBLED_DOCKERFILE contract (set by profile-installer.js output,
#   sourced in Task 004): absolute path to the assembled Dockerfile. Checked in
#   addition to docker/ when set and the path is outside docker/.
function is_build_stale() {
    local tag created tmp newer
    tag="${AI_SANDBOX_IMAGE_TAG}"
    created="$(docker image inspect --format='{{.Created}}' "${tag}" 2>/dev/null)" || return 0

    # If a composition hash is known, verify the image was built from the same
    # composition. A hash mismatch means the image is stale regardless of mtimes.
    if [[ -n "${PROFILE_COMPOSITION_HASH:-}" ]]; then
        local stored_hash
        stored_hash="$(docker image inspect \
            --format '{{index .Config.Labels "ai.sandbox.profile-hash"}}' \
            "${tag}" 2>/dev/null)" || true
        if [[ "${stored_hash}" != "${PROFILE_COMPOSITION_HASH}" ]]; then
            return 0  # stale: composition changed
        fi
    fi

    tmp="$(mktemp)"
    # touch -d accepts ISO 8601 on macOS (BSD) and Linux (GNU). On failure,
    # treat as stale to force a rebuild rather than silently skipping.
    if ! touch -d "${created}" "${tmp}" 2>/dev/null; then
        rm -f "${tmp}"
        return 0
    fi

    # Check docker/ tree (existing behavior).
    newer="$(find "${PROJECT_ROOT}/docker" -type f -newer "${tmp}" -print -quit 2>/dev/null)"
    if [[ -n "${newer}" ]]; then
        rm -f "${tmp}"
        return 0  # stale: docker/ file changed
    fi

    # Check the assembled Dockerfile when it lives outside docker/ (it may be in
    # the XDG cache dir). PROFILE_ASSEMBLED_DOCKERFILE is set by profile-installer
    # output sourced in Task 004's profile resolution phase.
    if [[ -n "${PROFILE_ASSEMBLED_DOCKERFILE:-}" && -f "${PROFILE_ASSEMBLED_DOCKERFILE}" ]]; then
        newer="$(find "${PROFILE_ASSEMBLED_DOCKERFILE}" -newer "${tmp}" -print -quit 2>/dev/null)"
        if [[ -n "${newer}" ]]; then
            rm -f "${tmp}"
            return 0  # stale: assembled Dockerfile changed
        fi
    fi

    # Check profile YAML files and their referenced src files. PROFILE_INPUT_FILES
    # is a newline-delimited list of absolute paths exported by Task 004 from the
    # installer's paths block output. When unset, skip (non-profile / legacy path).
    if [[ -n "${PROFILE_INPUT_FILES:-}" ]]; then
        while IFS= read -r input_file; do
            [[ -z "${input_file}" ]] && continue
            [[ ! -f "${input_file}" ]] && continue
            newer="$(find "${input_file}" -newer "${tmp}" -print -quit 2>/dev/null)"
            if [[ -n "${newer}" ]]; then
                rm -f "${tmp}"
                return 0  # stale: a profile input file changed
            fi
        done <<< "${PROFILE_INPUT_FILES}"
    fi

    rm -f "${tmp}"
    return 1  # fresh
}

function ensure_image() {
    if ! docker image inspect "${AI_SANDBOX_IMAGE_TAG}" >/dev/null 2>&1; then
        qecho "Image not found, building..."
        do_build
    elif is_build_stale; then
        qecho "Build inputs changed since last build, rebuilding..."
        do_build
    fi
}

function do_build() {
    docker image rm -f "${AI_SANDBOX_IMAGE_TAG}" >/dev/null 2>&1 || true
    # -p "${COMPOSE_PROJECT}" scopes the build to this instance's compose
    # project, matching every other compose invocation in the codebase (e.g.
    # start_shell() above, src/index.sh, src/create.sh) -- without it, this
    # resolves against Compose's default project-name derivation instead of
    # the named instance's actual project scope.
    docker compose -p "${COMPOSE_PROJECT}" ${COMPOSE_FILES} build --ssh "default=${SSH_AUTH_SOCK}"
}

# Remove all ai-sandbox:* variant images from the local daemon.
# Images are shared across instances (keyed by composition hash), so this
# sweeps every variant rather than just the one for the current sandbox.
function do_clean_images() {
    local IMAGES
    IMAGES=$(docker images --format '{{.Repository}}:{{.Tag}}' \
        | awk -F: '$1 == "ai-sandbox" {print}' || true)
    if [ -n "${IMAGES}" ]; then
        # shellcheck disable=SC2086 # intentional word-splitting across image tags
        docker image rm -f ${IMAGES} >/dev/null 2>&1 || true
        if [ "${QUIET}" -ne 0 ]; then
            echo "deleted images:"
            # shellcheck disable=SC2086 # same as above
            printf '  %s\n' ${IMAGES}
        fi
    fi
}

function cleanup_stale_container() {
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$(sandbox_container_name)" 2>/dev/null) || return 0
    case "$state" in
        running|exited|paused)
            # Healthy states — let `docker compose up -d` handle the transition
            # (it will start a stopped/exited container without recreating it when
            # the config matches, and restart/recreate as needed otherwise).
            return 0
            ;;
        *)
            qecho "Cleaning up stale container (state: ${state})..."
            docker compose -p "ai-sandbox-${SANDBOX_NAME}" ${COMPOSE_FILES} down 2>/dev/null \
                || docker rm -f "$(sandbox_container_name)" 2>/dev/null || true
            ;;
    esac
}

# SSH agent forwarding helpers.
#
# The container uses a stable internal socket path (/run/ai-sandbox/ssh-auth.sock)
# set in the Dockerfile. docker-compose.yaml bind-mounts the host's current
# SSH_AUTH_SOCK to that path and records the host value in the
# ai.sandbox.ssh-auth-sock-host label. When the host agent restarts (logout,
# reboot, new `eval $(ssh-agent)`), the label will no longer match the current
# host env — the container's mount is stale and SSH inside the container will
# fail. We detect this and tell the user to run `ai-sandbox fix-ssh`.

# Return 0 if the running container's recorded host SSH_AUTH_SOCK matches the
# current host env. Return 1 if it has drifted. Return 2 if there's no container
# (or no label), so callers can distinguish "no-op" from "stale".
function _ssh_mount_is_fresh() {
    local recorded
    recorded=$(docker inspect -f \
        '{{index .Config.Labels "ai.sandbox.ssh-auth-sock-host"}}' \
        "$(sandbox_container_name)" 2>/dev/null) || return 2
    [ -z "${recorded}" ] && return 2
    [ "${recorded}" = "${SSH_AUTH_SOCK:-}" ]
}

# Warn (non-fatal) if the running container's SSH socket mount is stale.
function warn_if_ssh_mount_stale() {
    _ssh_mount_is_fresh
    case $? in
        0|2) return 0 ;;
        1)
            echo "warn: host SSH_AUTH_SOCK has changed since the container was created." >&2
            echo "      SSH-backed operations (e.g. git push) will fail inside the container." >&2
            echo "      Run 'ai-sandbox ${SANDBOX_NAME} fix-ssh' to refresh the socket mount." >&2
            return 0
            ;;
    esac
}

# Verify the host SSH agent is reachable. Non-fatal; returns 1 if not.
# ssh-add -l exits 0 with identities, 1 with no identities, 2 if it can't
# contact the agent.
function ssh_preflight() {
    if [ -z "${SSH_AUTH_SOCK:-}" ] || [ ! -S "${SSH_AUTH_SOCK}" ]; then
        qecho "warn: host SSH_AUTH_SOCK (${SSH_AUTH_SOCK:-unset}) is not a live socket"
        return 1
    fi
    local rc
    ssh-add -l >/dev/null 2>&1
    rc=$?
    if [ $rc -eq 2 ]; then
        qecho "warn: cannot contact ssh-agent at ${SSH_AUTH_SOCK}"
        return 1
    fi
    return 0
}

# Recreate the ai-sandbox container with the current host SSH_AUTH_SOCK mounted.
function fix_ssh() {
    if ! ssh_preflight; then
        echo "Host SSH agent is not reachable. Start one (e.g. 'eval \$(ssh-agent)') or" >&2
        echo "verify SSH_AUTH_SOCK points at a live socket, then retry." >&2
        return 1
    fi
    # 'ai-sandbox' / 'firewall-init' here are compose service names, not
    # container names. -p "${COMPOSE_PROJECT}" scopes the recreate to this
    # instance's compose project, matching every other compose invocation in
    # the codebase (e.g. start_shell() above, src/index.sh, src/create.sh) --
    # without it, this resolves against Compose's default project-name
    # derivation instead of the named instance's actual project scope.
    # firewall-init must be recreated alongside ai-sandbox: recreating
    # ai-sandbox gives it a fresh network namespace, and its 03-init-firewall
    # cont-init stage blocks until the firewall-init sidecar re-applies the
    # egress rules into that new namespace (the sidecar is a one-shot that
    # already exited, so it will not re-run on its own). --no-deps is kept so
    # this does not also recreate the long-lived docker-socket-proxy sidecar
    # under --profile docker.
    docker compose -p "${COMPOSE_PROJECT}" ${COMPOSE_FILES} up -d --force-recreate --no-deps ai-sandbox firewall-init
    qecho "Container recreated with SSH_AUTH_SOCK=${SSH_AUTH_SOCK}"
}

# Emit tab-separated rows for each managed ai-sandbox container:
#   name<TAB>state<TAB>profiles
# Sorted by container name. Uses docker ps -a with label filter.
# Requires Docker Engine 23+ for the .Label "..." format syntax
# (Docker Desktop on macOS satisfies this).
function list_instances() {
    docker ps -a \
        --filter "label=ai.sandbox.managed=true" \
        --format '{{.Label "ai.sandbox.instance"}}\t{{.State}}\t{{.Label "ai.sandbox.profiles"}}' \
        2>/dev/null \
    | sort
}

# List installed claude plugin names (without @marketplace suffix), one per line.
# Returns nothing if the installed_plugins.json manifest is missing.
function list_installed_plugins() {
    local manifest="${HOME}/.claude/plugins/installed_plugins.json"
    if [ ! -f "${manifest}" ]; then
        return 0
    fi
    jq -r '.plugins // {} | keys[]' "${manifest}" 2>/dev/null \
        | sed -E 's/@[^@]+$//' \
        | sort -u
}
