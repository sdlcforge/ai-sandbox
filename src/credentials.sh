# shellcheck shell=bash

# ensure_clean_slate_credentials: Export AI_SANDBOX_CREDENTIALS_JSON_B64 with the
# current OAuth credentials so the container init script (04-write-credentials) can
# write them directly, bypassing virtiofs keep_cache.
#
# On macOS the Keychain is tried first because Claude Code refreshes it on every
# token renewal, guaranteeing the most current credentials regardless of whether
# ~/.claude/.credentials.json has been updated. The file is used as a fallback.
# On Linux ~/.claude/.credentials.json is the only credential store.
function ensure_clean_slate_credentials() {
    local creds_file="${HOME}/.claude/.credentials.json"
    local json=''

    if [ "$(uname)" = "Darwin" ]; then
        local hex_json
        if hex_json=$(security find-generic-password \
                -s "Claude Code-credentials" -a "${USER}" -w 2>/dev/null); then
            # The Keychain value is hex-encoded JSON. Try to decode it; fall back to
            # treating it as plain JSON in case a future version changes the encoding.
            local decoded
            if decoded=$(printf '%s' "${hex_json}" | xxd -r -p 2>/dev/null) && \
               printf '%s' "${decoded}" | jq -e '.claudeAiOauth' >/dev/null 2>&1; then
                json="${decoded}"
            elif printf '%s' "${hex_json}" | jq -e '.claudeAiOauth' >/dev/null 2>&1; then
                json="${hex_json}"
            fi
        fi

        # Fallback: use the on-disk file if Keychain didn't yield valid credentials.
        if [ -z "${json}" ] && [ -f "${creds_file}" ]; then
            local file_json
            if file_json=$(cat "${creds_file}") && \
               printf '%s' "${file_json}" | jq -e '.claudeAiOauth' >/dev/null 2>&1; then
                json="${file_json}"
            fi
        fi

        if [ -z "${json}" ]; then
            echo "warn: Claude Code credentials not found in Keychain or credentials file; container may fail to authenticate." >&2
            return 0
        fi
    else
        # Linux: .credentials.json is the only credential store.
        if [ ! -f "${creds_file}" ]; then
            echo "warn: ${creds_file} not found; container may fail to authenticate." >&2
            return 0
        fi
        json=$(cat "${creds_file}")
        if ! printf '%s' "${json}" | jq -e '.claudeAiOauth' >/dev/null 2>&1; then
            echo "warn: ${creds_file} is invalid; container may fail to authenticate." >&2
            return 0
        fi
    fi

    # Warn if accessToken is expired; refreshToken should still renew it.
    local expires_at now_ms
    expires_at=$(printf '%s' "${json}" | jq -r '.claudeAiOauth.expiresAt // 0' 2>/dev/null || echo 0)
    now_ms=$(( $(date +%s) * 1000 ))
    if [ "${expires_at:-0}" -gt 0 ] && [ "${expires_at}" -lt "${now_ms}" ]; then
        qecho "Note: OAuth accessToken is expired; the container will refresh it automatically."
    fi

    # Pass credentials to the container via environment variable so the init
    # script can write them directly, bypassing virtiofs keep_cache entirely.
    AI_SANDBOX_CREDENTIALS_JSON_B64=$(printf '%s' "${json}" | base64)
    export AI_SANDBOX_CREDENTIALS_JSON_B64
}
