# shellcheck shell=bash
# shellcheck disable=SC2086 # we want word splitting for 'COMPOSE_FILES'

# Provision a new named sandbox instance.
#
# Called from index.sh after profile resolution and compose-file assembly have
# already run, so PROFILE_* env vars, AI_SANDBOX_IMAGE_TAG, and COMPOSE_FILES
# are available.
function do_create() {
    # --- 1. Validate sandbox name ---
    if [ -z "${SANDBOX_NAME}" ]; then
        echo "Error: sandbox name is required for 'create'" >&2
        return 1
    fi
    if ! printf '%s' "${SANDBOX_NAME}" | grep -qE '^[a-zA-Z0-9_-]+$'; then
        echo "Error: sandbox name '${SANDBOX_NAME}' is invalid. Only alphanumeric characters, hyphens, and underscores are allowed." >&2
        return 1
    fi
    if [ "${#SANDBOX_NAME}" -gt 40 ]; then
        echo "Error: sandbox name '${SANDBOX_NAME}' exceeds 40 characters." >&2
        return 1
    fi

    # --- 2. Check for name collision ---
    # A create-collision check must reject a name colliding with any of: an
    # existing instance, an existing profile, or a reserved word -- regardless
    # of which noun (instances create / profiles create) is being used, since
    # a name can't be both an instance and a profile (see
    # plan/phase-02-profiles-resource/001-build-profiles-module.md
    # Requirements item 5). Reserved-word collisions are already rejected
    # upstream in src/options.sh's dispatch layer via check_reserved_name.
    if instance_exists "${SANDBOX_NAME}"; then
        echo "Error: sandbox '${SANDBOX_NAME}' already exists. Use 'ai-sandbox ${SANDBOX_NAME} start' to start it." >&2
        return 1
    fi
    if profile_exists "${SANDBOX_NAME}"; then
        echo "Error: '${SANDBOX_NAME}' already exists as a profile. Choose a different sandbox name." >&2
        return 1
    fi

    # --- 3. Ensure image is built and up-to-date ---
    ensure_image

    # --- 4. Start the container with the full label set ---
    docker compose -p "${COMPOSE_PROJECT}" ${COMPOSE_FILES} up -d

    # --- 5. Warn if SSH mount is stale ---
    warn_if_ssh_mount_stale

    # --- 6. Optionally enter an interactive shell ---
    if [ "${ENTER_AFTER_CREATE}" = "true" ]; then
        start_shell
    fi

    # --- 7. Confirm success ---
    qecho "Sandbox '${SANDBOX_NAME}' created and started."
}
