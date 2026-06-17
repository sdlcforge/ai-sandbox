# shellcheck shell=bash

# ensure_clean_slate_credentials: Export AI_SANDBOX_CREDENTIALS_JSON_B64 so the
# container init script (04-write-credentials) can inject the current OAuth
# credentials without relying on a virtiofs bind mount (which Docker Desktop's
# keep_cache can serve stale).
#
# Primary source is ~/.claude/.credentials.json on both platforms — Claude Code
# keeps this file current. On macOS, if the file is missing or unparseable, we
# fall back to Keychain extraction as a rescue path.
function ensure_clean_slate_credentials() {
    local creds_file="${HOME}/.claude/.credentials.json"
    local json

    # Try reading the credentials file directly first (works on both platforms).
    if [ -f "${creds_file}" ] && \
       json=$(cat "${creds_file}") && \
       printf '%s' "${json}" | jq -e '.claudeAiOauth' >/dev/null 2>&1; then
        : # file is valid
    elif [ "$(uname)" = "Darwin" ]; then
        # macOS fallback: extract from Keychain when file is missing or invalid.
        local hex_json
        if ! hex_json=$(security find-generic-password \
                -s "Claude Code-credentials" -a "${USER}" -w 2>/dev/null); then
            echo "warn: Claude Code credentials not found in file or Keychain; container may fail to authenticate." >&2
            return 0
        fi

        # The Keychain value is hex-encoded JSON. Try to decode it; fall back to
        # treating it as plain JSON in case a future version changes the encoding.
        if json=$(printf '%s' "${hex_json}" | xxd -r -p 2>/dev/null) && \
           printf '%s' "${json}" | jq -e '.claudeAiOauth' >/dev/null 2>&1; then
            : # hex decode succeeded
        elif printf '%s' "${hex_json}" | jq -e '.claudeAiOauth' >/dev/null 2>&1; then
            json="${hex_json}"
        else
            echo "warn: Could not parse Claude Code credentials from Keychain; container may fail to authenticate." >&2
            return 0
        fi

        mkdir -p "${HOME}/.claude"
        printf '%s\n' "${json}" > "${creds_file}"
        chmod 0600 "${creds_file}"
        qecho "Wrote ~/.claude/.credentials.json from Keychain for clean-slate container."
    else
        # Linux: .credentials.json is the only credential store.
        echo "warn: ${creds_file} not found or invalid; container may fail to authenticate." >&2
        return 0
    fi

    # Warn if accessToken is expired; refreshToken should still renew it.
    local expires_at now_ms
    expires_at=$(jq -r '.claudeAiOauth.expiresAt // 0' "${creds_file}" 2>/dev/null || echo 0)
    now_ms=$(( $(date +%s) * 1000 ))
    if [ "${expires_at:-0}" -gt 0 ] && [ "${expires_at}" -lt "${now_ms}" ]; then
        qecho "Note: OAuth accessToken is expired; the container will refresh it automatically."
    fi

    # Pass credentials to the container via environment variable so the init
    # script can write them directly, bypassing virtiofs keep_cache entirely.
    AI_SANDBOX_CREDENTIALS_JSON_B64=$(printf '%s' "${json}" | base64)
    export AI_SANDBOX_CREDENTIALS_JSON_B64
}
