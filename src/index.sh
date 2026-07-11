#!/bin/bash
# shellcheck disable=SC2086 # we want word splitting for 'COMPOSE_FILES'

set -euo pipefail

source ./utils.sh
source ./plugin-conflicts.sh
source ./volume-override.sh
source ./tool-versions.sh
source ./xquartz.sh
source ./credentials.sh
source ./options.sh
source ./help.sh
source ./kill-local.sh
source ./status.sh
source ./profiles.sh
source ./create.sh
source ./list.sh

${__SOURCED__:+return}

# --- Phase: parse options ---
parse_options "$@"

# Export SANDBOX_NAME early so all sourced modules can consume it.
export SANDBOX_NAME

# --- Phase: profile-kind short-circuit (no docker needed) ---
# A name that resolves to a profile only supports detail/delete
# (src/options.sh's parse_options() already verb-gated CMD to one of those
# two before returning). Dispatch here, before the Docker pre-flight and
# before profile-installer.js resolution below -- a bare YAML file
# lookup/deletion must not require Docker to be running or the
# profile-composition machinery to execute. Consumes SANDBOX_NAME_KIND,
# already computed once by parse_options() and exported above, rather than
# calling resolve_name_kind() again here -- a second call would re-run
# instance_exists()'s `docker ps -a` query on every per-name invocation for
# no benefit (see Bug 2 in the phase-02-profiles-resource follow-up review).
# SANDBOX_NAME_KIND is only ever set for the flat per-name dispatch path, so
# it's empty (falsy against "profile") for every other shape (global/noun
# commands, `create`), making this a no-op for those regardless.
if [ -n "${SANDBOX_NAME}" ] && [ "${SANDBOX_NAME_KIND:-}" = "profile" ]; then
    case "${CMD}" in
        detail)
            do_profiles_detail "${SANDBOX_NAME}"
            exit $?
            ;;
        delete)
            profiles_delete "${SANDBOX_NAME}"
            exit $?
            ;;
        *)
            # Unreachable in practice: parse_options()'s verb-gating already
            # rejects any CMD other than detail/delete for a profile-kind
            # name before parse_options() ever returns. Defensive fallback
            # only.
            echo "Error: '${SANDBOX_NAME}' is a profile, not an instance — 'ai-sandbox ${SANDBOX_NAME} ${CMD}' is not supported for profiles; only detail/delete are allowed" 1>&2
            exit 1
            ;;
    esac
fi

# --- Phase: global command short-circuits (no docker needed) ---

# Bare `ls` shows the grouped Instances:/Profiles: listing; `instances ls`
# shows instances only. Bare invocation (no words at all) now defaults to
# `enter` (see options.sh), not `ls`. Both short-circuit before the Docker
# pre-flight so `ls` works even when the Docker daemon is down (do_list /
# do_profiles_list handle empty output gracefully).
if [ "${CMD}" = "ls" ] && [ -z "${SANDBOX_NAME}" ]; then
    do_list_all
    exit 0
fi

if [ "${CMD}" = "instances-ls" ]; then
    do_list
    exit 0
fi

if [ "${CMD}" = "help" ]; then
    print_help
    exit 0
fi

if [ "${CMD}" = "kill-local-ai" ]; then
    kill_local_ai || exit 1
    exit 0
fi

if [ "${CMD}" = "profiles-ls" ]; then
    do_profiles_list
    exit 0
fi

if [ "${CMD}" = "profiles-create" ]; then
    # MODE_OVERRIDE is Phase 3's parsed --mode value (src/options.sh's shared
    # flag parser intercepts --mode before profiles_create() ever sees ARGS),
    # so it's reconstructed as a --mode flag here for profiles_create()'s own
    # (unchanged-in-substance) --mode/--output/--plugins parsing. --output and
    # --plugins aren't intercepted by src/options.sh and pass through in ARGS
    # unmodified.
    PROFILES_CREATE_ARGS=("${SANDBOX_NAME}")
    if [ -n "${MODE_OVERRIDE}" ]; then
        PROFILES_CREATE_ARGS+=(--mode "${MODE_OVERRIDE}")
    fi
    profiles_create "${PROFILES_CREATE_ARGS[@]}" "${ARGS[@]+"${ARGS[@]}"}" || exit 1
    exit 0
fi

# --- Phase: docker pre-flight ---
# `detail` tolerates docker being down; it will just report the container as
# stopped and no images. Anything else requires a running daemon.
if [ "${CMD}" != "detail" ]; then
    if ! check_docker "starting..."; then
        docker desktop start
        check_docker "bailing out." || exit 1
    fi
fi

# --- Phase: resolve script dir / project root (follows symlinks) ---
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
PROJECT_ROOT="$(cd -P "${SCRIPT_DIR}/.." && pwd)"

# --- Phase: restore saved config for every per-instance command except create (no config flags) ---
# When any per-instance command other than `create` is called without any
# config-changing flags, read the profiles/mode/clean-slate settings that
# were saved at `create` time so this invocation's compose-file assembly
# reflects the instance's actual persisted composition (e.g. the `docker`
# capability / proxy sidecar) instead of just whatever --profile flags
# (usually none) this particular invocation passed. should_restore_config()
# excludes only `create`, which provisions fresh state and has no prior
# config to restore. See should_restore_config()'s doc comment (src/utils.sh)
# for the full rationale.
if should_restore_config "${CMD}"; then
    restore_saved_config
fi

# --- Phase: resolve profiles ---
# Run profile-installer.js to compose the requested (or default) profiles and
# emit the resolved env block. Source PROFILE_* from it, assemble the effective
# Dockerfile, and derive the image tag. Drives compose-overlay selection below.
PROFILE_INSTALLER="${PROJECT_ROOT}/bin/profile-installer.js"
PROFILE_INSTALLER_ARGS=()
if [ "${#PROFILES[@]}" -gt 0 ]; then
  PROFILE_INSTALLER_ARGS+=("${PROFILES[@]}")
fi
if [ -n "${MODE_OVERRIDE}" ]; then
  PROFILE_INSTALLER_ARGS+=(--mode "${MODE_OVERRIDE}")
fi

PROFILE_INSTALLER_OUTPUT="$(node "${PROFILE_INSTALLER}" "${PROFILE_INSTALLER_ARGS[@]+"${PROFILE_INSTALLER_ARGS[@]}"}")" || exit $?

# Source only the KEY=VALUE env lines (between the ENV sentinel and the first
# subsequent '###' sentinel). awk emits them; eval sets PROFILE_* in this scope.
PROFILE_ENV_BLOCK="$(printf '%s\n' "${PROFILE_INSTALLER_OUTPUT}" \
  | awk '/^### PROFILE_ENV ###$/{f=1;next} /^###/{f=0} f && /^[A-Z_]+=/{print}')"
eval "${PROFILE_ENV_BLOCK}"
export PROFILE_MODE PROFILE_CAPABILITIES PROFILE_IMAGE_TAG \
  PROFILE_COMPOSITION_HASH PROFILE_ASSEMBLED_DOCKERFILE

# Extract the JSON blob for downstream structured-data access (plugin config,
# capability list, network allow). Merged with CLI-supplied flags below.
PROFILE_JSON="$(printf '%s\n' "${PROFILE_INSTALLER_OUTPUT}" \
  | awk '/^### PROFILE_JSON ###$/{f=1;next} /^###/{f=0} f{print}')"

# Merge CLI-supplied marketplace/plugin values into the JSON blob.
# CLI values union with profile-declared values; enable_all_plugins ORs.
# _cli_marketplaces_json/_cli_plugins_json/_cli_enable_all_json are computed
# unconditionally (not just under the guard below) because the later
# config-persistence block (assembling AI_SANDBOX_CONFIG_JSON) reuses these
# same array->JSON conversions for the same CLI_MARKETPLACES/CLI_PLUGINS
# arrays -- see followup 85Na. Only the merge-into-PROFILE_JSON step itself
# needs the guard, since an empty/false CLI delta is a no-op merge.
if [ "${#CLI_MARKETPLACES[@]}" -gt 0 ]; then
  _cli_marketplaces_json="$(printf '%s\n' "${CLI_MARKETPLACES[@]}" | jq -R . | jq -s .)"
else
  _cli_marketplaces_json='[]'
fi
if [ "${#CLI_PLUGINS[@]}" -gt 0 ]; then
  _cli_plugins_json="$(printf '%s\n' "${CLI_PLUGINS[@]}" | jq -R . | jq -s .)"
else
  _cli_plugins_json='[]'
fi
_cli_enable_all_json=false
[ "${CLI_ENABLE_ALL}" = "true" ] && _cli_enable_all_json=true
if [ "${#CLI_MARKETPLACES[@]}" -gt 0 ] || [ "${#CLI_PLUGINS[@]}" -gt 0 ] || [ "${CLI_ENABLE_ALL}" = "true" ]; then
  PROFILE_JSON="$(printf '%s\n' "${PROFILE_JSON}" | jq \
      --argjson cm "${_cli_marketplaces_json}" \
      --argjson cp "${_cli_plugins_json}" \
      --argjson ea "${_cli_enable_all_json}" \
      '.marketplaces = ((.marketplaces // []) + $cm | unique) |
       .plugins      = ((.plugins      // []) + $cp | unique) |
       .enable_all_plugins = ((.enable_all_plugins // false) or $ea)')"
fi
export PROFILE_JSON

# --- Phase: assemble the full config-input record for persistence ---
# Capture all seven config-input dimensions (see
# plan/notes/config-persistence-design.md) as a single JSON record, then
# base64-encode it single-line -- mirroring src/credentials.sh's
# AI_SANDBOX_CREDENTIALS_JSON_B64 pattern -- for safe embedding in the
# ai.sandbox.config Docker label (docker/docker-compose.yaml).
# restore_saved_config() decodes this label to rehydrate all seven inputs on
# every per-instance command except create (see should_restore_config(), src/utils.sh). Persist CLI_MARKETPLACES/CLI_PLUGINS/CLI_ENABLE_ALL (the
# CLI deltas), not the profile-merged PROFILE_JSON set: profile-contributed
# entries are reproduced for free by re-running profile-installer.js on
# restore, so only the CLI additions need to round-trip through the label.
# Reuses _cli_marketplaces_json/_cli_plugins_json/_cli_enable_all_json
# computed by the CLI-merge block above (same CLI_MARKETPLACES/CLI_PLUGINS
# arrays) instead of recomputing the same jq -R . | jq -s . conversion a
# second time -- see followup 85Na.
if [ "${#PROFILES[@]}" -gt 0 ]; then
  _config_profiles_json="$(printf '%s\n' "${PROFILES[@]}" | jq -R . | jq -s .)"
else
  _config_profiles_json='[]'
fi
_config_no_isolate_json=false
[ "${NO_ISOLATE_CONFIG}" = "true" ] && _config_no_isolate_json=true
_config_clean_slate_json=false
[ "${CLEAN_SLATE:-false}" = "true" ] && _config_clean_slate_json=true

AI_SANDBOX_CONFIG_JSON="$(jq -n \
    --argjson profiles "${_config_profiles_json}" \
    --arg mode "${MODE_OVERRIDE}" \
    --argjson no_isolate_config "${_config_no_isolate_json}" \
    --argjson clean_slate "${_config_clean_slate_json}" \
    --argjson marketplaces "${_cli_marketplaces_json}" \
    --argjson plugins "${_cli_plugins_json}" \
    --argjson enable_all_plugins "${_cli_enable_all_json}" \
    '{version: 1, profiles: $profiles, mode: $mode,
      no_isolate_config: $no_isolate_config, clean_slate: $clean_slate,
      marketplaces: $marketplaces, plugins: $plugins,
      enable_all_plugins: $enable_all_plugins}')"
# macOS base64 may line-wrap; tr -d '\n' guarantees a single-line label value.
AI_SANDBOX_CONFIG_B64="$(printf '%s' "${AI_SANDBOX_CONFIG_JSON}" | base64 | tr -d '\n')"
export AI_SANDBOX_CONFIG_B64

# MODE_OVERRIDE wins; else the profile's mode; else mirror (legacy default).
# --clean always forces static mode regardless of MODE_OVERRIDE or profile mode.
if [ "${CLEAN_SLATE:-false}" = "true" ]; then
  EFFECTIVE_MODE=static
elif [ -n "${MODE_OVERRIDE}" ]; then
  EFFECTIVE_MODE="${MODE_OVERRIDE}"
else
  EFFECTIVE_MODE="${PROFILE_MODE:-mirror}"
fi
export EFFECTIVE_MODE

# --- Phase: plugin-conflict pre-flight (start/enter/up, mirror mode only) ---
# Static mode doesn't mount ~/.claude from the host, so there's no shared SQLite
# state that could be corrupted by concurrent host processes.
if { [ "${CMD}" == "start" ] || [ "${CMD}" == "enter" ] || [ "${CMD}" == "up" ]; } \
        && [ "${EFFECTIVE_MODE}" = "mirror" ]; then
    check_host_plugin_conflicts || exit 1
fi

AI_SANDBOX_CLEAN_SLATE="${CLEAN_SLATE:-false}"
export AI_SANDBOX_CLEAN_SLATE

# Per-composition image tag consumed by docker/docker-compose.yaml.
# profile_image_suffix() reads PROFILE_COMPOSITION_HASH set above from the
# installer output. Using the function keeps utils.sh as the single source of
# truth for the tag-suffix derivation.
AI_SANDBOX_IMAGE_TAG="ai-sandbox:$(profile_image_suffix)"
export AI_SANDBOX_IMAGE_TAG

# Capability-derived proxy state. The proxy sidecar overlay and the
# ai.sandbox.docker-proxy label are keyed off this.
if profile_has_capability docker; then
  EFFECTIVE_PROXY=true
else
  EFFECTIVE_PROXY=false
fi

# Fallback: the computation above only reflects *this invocation's* profile
# resolution, which can drift from the instance's actual persisted
# composition -- e.g. restore_saved_config() (src/utils.sh) drops a restored
# profile name that no longer resolves (task 002's graceful-degradation
# fix), or a directly-provided --profile flag names a profile that has since
# lost the docker capability it once had. When that drift silently flips a
# docker-capable instance's EFFECTIVE_PROXY to false, COMPOSE_FILES below
# omits docker-compose.proxy.yaml and delete/stop/clean leave the
# docker-socket-proxy sidecar orphaned (or, for stop, left running) -- the
# exact orphaned-sidecar bug this codebase exists to prevent, reintroduced in
# a narrower scenario. Use the container's own persisted
# ai.sandbox.docker-proxy label (docker/docker-compose.yaml) as an
# authoritative fallback, independent of profile resolution:
# is_docker_proxy_label_true() (src/utils.sh) is naturally scoped to "a
# container already exists" (its docker inspect fails, and so it returns
# false, when SANDBOX_NAME has no container yet -- e.g. `create`), so no
# separate existence guard is needed here. Only the "label true, current
# false" direction is forced: the reverse (label false, current resolution
# true) is not a regression risk -- an invocation that correctly resolves the
# docker capability today should get it.
#
# should_force_proxy_label_fallback() (src/utils.sh) scopes this to
# stop/delete/clean unconditionally (teardown/preserve commands with no
# legitimate "explicit invocation" story to override the label), and to
# fix-ssh/start/enter/up only when this invocation's CONFIG_FLAGS_PROVIDED is
# not "true" -- i.e. a bare restore/resume, not this run's own explicit
# composition choice. create/detail/build/user-exec/root-exec/attach are
# never in scope. When CONFIG_FLAGS_PROVIDED is "true" for fix-ssh/start/
# enter/up, an explicit, confirmed invocation (docs/architecture.md's
# "Matches" subsection, "explicit invocation always wins") must be allowed to
# actually change the composition, including deliberately dropping the docker
# capability -- applying the fallback there would silently re-grant network
# access to the docker-socket-proxy sidecar (a documented container-escape
# vector) against the user's explicit intent (phase-01/004, refined by
# phase-01/005 to gate on CONFIG_FLAGS_PROVIDED rather than CMD alone).
if should_force_proxy_label_fallback "${CMD}" "${CONFIG_FLAGS_PROVIDED}" \
    && [ "${EFFECTIVE_PROXY}" != "true" ] && is_docker_proxy_label_true; then
  echo "Warning: honoring the persisted ai.sandbox.docker-proxy label (true) for '${SANDBOX_NAME}' over this invocation's resolved profile composition (false) -- '${CMD}' did not explicitly change this instance's composition this run, so the instance's actual persisted composition is used instead of what this run's profile resolution would otherwise produce." 1>&2
  EFFECTIVE_PROXY=true
fi
export EFFECTIVE_PROXY NO_ISOLATE_CONFIG

# Extract plugin-marketplace configuration for container passthrough.
# When phase-02 is present, PROFILE_JSON is already set by the CLI merge block;
# otherwise extract it here from the raw installer output.
if [ -z "${PROFILE_JSON:-}" ]; then
  PROFILE_JSON="$(printf '%s\n' "${PROFILE_INSTALLER_OUTPUT}" \
    | awk '/^### PROFILE_JSON ###$/{f=1;next} /^###/{f=0} f{print}')"
  export PROFILE_JSON
fi
# Join arrays with | (not :) so URLs containing colons pass through correctly.
AI_SANDBOX_MARKETPLACES="$(printf '%s\n' "${PROFILE_JSON}" \
  | jq -r '(.marketplaces // []) | join("|")')"
AI_SANDBOX_PLUGINS="$(printf '%s\n' "${PROFILE_JSON}" \
  | jq -r '(.plugins // []) | join("|")')"
AI_SANDBOX_ENABLE_ALL_PLUGINS="$(printf '%s\n' "${PROFILE_JSON}" \
  | jq -r '.enable_all_plugins // false')"
export AI_SANDBOX_MARKETPLACES AI_SANDBOX_PLUGINS AI_SANDBOX_ENABLE_ALL_PLUGINS

# Assemble the effective Dockerfile from the resolved capabilities and point the
# compose build at it (docker-compose.yaml reads ${AI_SANDBOX_DOCKERFILE}).
# --hash embeds the composition hash as a LABEL so is_build_stale() can detect
# composition changes by inspecting the built image without re-running the installer.
"${PROJECT_ROOT}/docker/scripts/assemble-dockerfile.sh" \
  --hash "${PROFILE_COMPOSITION_HASH}" \
  "${PROFILE_CAPABILITIES}" "${PROFILE_ASSEMBLED_DOCKERFILE}" >/dev/null
export AI_SANDBOX_DOCKERFILE="${PROFILE_ASSEMBLED_DOCKERFILE}"

# --- Phase: credential snapshot (clean-slate mode, start/enter/create/up/fix-ssh only) ---
# Export AI_SANDBOX_CREDENTIALS_JSON_B64 before compose assembly so the claude-auth
# compose file is included only when credentials are actually available.
#
# fix-ssh is included alongside start/enter/create/up (regression fix): once
# should_restore_config() (src/utils.sh) started restoring CLEAN_SLATE for
# every per-instance CMD except create, a bare `fix-ssh` on a --clean-created
# instance now correctly restores CLEAN_SLATE=true, which routes the
# COMPOSE_FILES assembly below into the AI_SANDBOX_CREDENTIALS_JSON_B64-gated
# docker-compose.claude-auth.yaml branch instead of docker-compose.mirror-
# claude.yaml. fix_ssh() (src/utils.sh) then runs `docker compose ... up -d
# --force-recreate --no-deps ai-sandbox` using COMPOSE_FILES as already
# assembled below -- by the time fix_ssh() itself runs (command-dispatch
# phase, well after COMPOSE_FILES is fixed), it is too late for fix_ssh() to
# populate credentials itself, since that decision has already been baked
# into COMPOSE_FILES. Without this guard here, the credentials would never
# have been captured, so neither compose overlay would apply them, and
# --force-recreate would destroy the previous container's writable-layer
# credentials with nothing to replace them (clean-slate mode never bind-
# mounts host ~/.claude). Populating the snapshot here, before COMPOSE_FILES
# assembly, is the only point in the pipeline where it can still affect
# which overlay gets selected.
if [ "${CLEAN_SLATE:-false}" = "true" ] && \
   { [ "${CMD}" = "start" ] || [ "${CMD}" = "enter" ] || \
     [ "${CMD}" = "create" ] || [ "${CMD}" = "up" ] || \
     [ "${CMD}" = "fix-ssh" ]; }; then
    ensure_clean_slate_credentials
fi

# --- Phase: assemble docker-compose file list ---
# Each instance has its own generated compose file to avoid cross-instance collisions.
GENERATED_COMPOSE="${XDG_CACHE_HOME:-$HOME/.cache}/ai-sandbox/${SANDBOX_NAME}/docker-compose.generated.yaml"
mkdir -p "$(dirname "${GENERATED_COMPOSE}")"
generate_volume_override "${GENERATED_COMPOSE}"

COMPOSE_FILES="-f ${PROJECT_ROOT}/docker/docker-compose.yaml"
if profile_has_capability chromium; then
  COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_ROOT}/docker/docker-compose.chromium.yaml"
fi

# ~/.claude mount: applied in all non-clean-slate invocations regardless of mode.
# In clean-slate mode the container gets a fresh empty ~/.claude directory, but
# credentials are injected via AI_SANDBOX_CREDENTIALS_JSON_B64 (env var passthrough)
# so the container init script can write them directly, bypassing virtiofs caching.
if [ "${CLEAN_SLATE:-false}" != "true" ]; then
  COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_ROOT}/docker/docker-compose.mirror-claude.yaml"
elif [ -n "${AI_SANDBOX_CREDENTIALS_JSON_B64:-}" ]; then
  COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_ROOT}/docker/docker-compose.claude-auth.yaml"
fi

# Host-identity / config overlays only apply in mirror mode. static mode is
# self-contained: no ~/.config overlay is applied (see decisions in task report
# for the V1 scope of static-mode mount suppression).
if [ "${EFFECTIVE_MODE}" = "mirror" ]; then
  # ~/.config handling: either overlay (default, isolates container writes) or
  # passthrough. Kept as separate overlay files so the base compose doesn't
  # have to know about either form and the active choice is obvious from
  # `docker compose config`.
  if [ "$NO_ISOLATE_CONFIG" = "true" ]; then
    COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_ROOT}/docker/docker-compose.shared-config.yaml"
  else
    COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_ROOT}/docker/docker-compose.isolate-config.yaml"
  fi
fi

COMPOSE_FILES="${COMPOSE_FILES} -f ${GENERATED_COMPOSE}"

if [ "${EFFECTIVE_PROXY}" = "true" ]; then
  COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_ROOT}/docker/docker-compose.proxy.yaml"
fi

# Compose project name scopes all containers to this sandbox instance.
COMPOSE_PROJECT="ai-sandbox-${SANDBOX_NAME}"
export COMPOSE_PROJECT

# --- Phase: XQuartz setup (macOS, chromium capability, start/enter only) ---
if { [ "${CMD}" = "start" ] || [ "${CMD}" = "enter" ]; } && [ "$(uname)" = "Darwin" ] && profile_has_capability chromium; then
    ensure_xquartz
fi

# --- Phase: export host-derived env vars consumed by docker compose ---
export HOST_USER=${USER}
export START_DIR="${PWD}"
HOST_ARCH=$(uname -m)
export HOST_ARCH
export HOST_HOME=${HOME}
HOST_TZ=$(date +%Z)
export HOST_TZ
HOST_UID=$(id -u)
export HOST_UID
HOST_GID=$(id -g)
export HOST_GID
GIT_USER_NAME="$(git config --global user.name || true)"
export GIT_USER_NAME
GIT_USER_EMAIL="$(git config --global user.email || true)"
export GIT_USER_EMAIL
export DOCKER_DEFAULT_PLATFORM=linux/${HOST_ARCH}
export TOOL_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ai-sandbox"
mkdir -p "${TOOL_CACHE_DIR}"

# --- Phase: tool-version resolution + downloads (build-related commands) ---
if [ "${CMD}" = "enter" ] || [ "${CMD}" = "start" ] || [ "${CMD}" = "up" ] || [ "${CMD}" = "build" ] || [ "${CMD}" = "create" ]; then
    resolve_and_download_tools
fi

# --- Phase: command dispatch ---

# For create: provision a new named sandbox instance and exit.
if [ "${CMD}" == "create" ]; then
    do_create || exit $?
    exit 0
fi

if [ "${CMD}" == "start" ] || [ "${CMD}" == "enter" ]; then
    # If a container is already running but its config differs from what this
    # invocation would produce, `compose up -d` will silently recreate it. Ask
    # first so the user can bail or rerun without conflicting flags.
    if is_container_running && ! running_config_matches; then
        confirm_stop_running "stop the running sandbox and recreate it with the requested options" || exit 1
    fi
    ensure_image
    cleanup_stale_container
    docker compose -p "${COMPOSE_PROJECT}" ${COMPOSE_FILES} up -d
    warn_if_ssh_mount_stale

    run_enter_shell_if_requested
elif [ "${CMD}" == "attach" ]; then
    warn_if_ssh_mount_stale
    start_shell
elif [ "${CMD}" == "fix-ssh" ]; then
    fix_ssh || exit 1
elif [ "${CMD}" == "build" ]; then
    do_build
elif [ "${CMD}" == "user-exec" ]; then
    # Compose exec targets the service name (ai-sandbox), not the container name.
    docker compose -p "${COMPOSE_PROJECT}" ${COMPOSE_FILES} exec -u "${HOST_USER}" ai-sandbox "${ARGS[@]+"${ARGS[@]}"}"
elif [ "${CMD}" == "root-exec" ]; then
    docker compose -p "${COMPOSE_PROJECT}" ${COMPOSE_FILES} exec -u root ai-sandbox "${ARGS[@]+"${ARGS[@]}"}"
elif [ "${CMD}" == "detail" ]; then
    do_status || exit $?
elif [ "${CMD}" == "stop" ]; then
    if is_container_running; then
        confirm_stop_running "stop the running sandbox" || exit 1
    fi
    docker compose -p "${COMPOSE_PROJECT}" ${COMPOSE_FILES} stop
    qecho "Sandbox '${SANDBOX_NAME}' stopped (container preserved)."

elif [ "${CMD}" == "delete" ]; then
    if is_container_running; then
        confirm_stop_running "stop and delete the running sandbox" || exit 1
    fi
    docker compose -p "${COMPOSE_PROJECT}" ${COMPOSE_FILES} down
    qecho "Sandbox '${SANDBOX_NAME}' deleted."

elif [ "${CMD}" == "clean" ]; then
    if is_container_running; then
        confirm_stop_running "stop and delete the running sandbox" || exit 1
    fi
    docker compose -p "${COMPOSE_PROJECT}" ${COMPOSE_FILES} down
    # Remove the container by its explicit name in case compose down left it.
    docker rm -f "$(sandbox_container_name)" 2>/dev/null || true
    do_clean_images
else
    docker compose -p "${COMPOSE_PROJECT}" ${COMPOSE_FILES} "${ARGS[@]+"${ARGS[@]}"}"
fi
