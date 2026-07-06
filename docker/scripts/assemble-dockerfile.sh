#!/usr/bin/env bash
# assemble-dockerfile.sh — Assemble the effective Dockerfile from base + capability fragments.
#
# Usage:
#   assemble-dockerfile.sh [--hash <composition-hash>] <capabilities> <output-path>
#
#   --hash <hash>   Optional. The 8-char profile composition hash from profile-installer.js.
#                   When supplied, a LABEL ai.sandbox.profile-hash=<hash> instruction is
#                   appended to the assembled Dockerfile so that is_build_stale() can detect
#                   composition changes without re-running the installer.
#                   The hash is owned by profile-installer.js — never compute it here.
#
#   <capabilities>  Space-separated list of capability names (e.g. "docker chromium"),
#                   or an empty string "" for a lean image with no capability layers.
#   <output-path>   Absolute path where the assembled Dockerfile is written.
#                   Task 004 passes a build-cache path such as:
#                     ${XDG_CACHE_HOME:-$HOME/.cache}/ai-sandbox/Dockerfile.<hash>
#                   This script does not compute the hash — the caller supplies the
#                   full output path. Task 004 owns this path contract.
#
# Output-path contract (shared with Task 004):
#   The caller is responsible for choosing the output path. The conventional path is:
#     ${XDG_CACHE_HOME:-$HOME/.cache}/ai-sandbox/Dockerfile.<composition-hash>
#   where <composition-hash> is computed by profile-installer.js. The compose build
#   must be invoked with `dockerfile: <output-path>` pointing at this assembled file.
#
# Examples:
#   assemble-dockerfile.sh "docker chromium" /tmp/Dockerfile.test
#   assemble-dockerfile.sh "" /tmp/Dockerfile.lean
#   assemble-dockerfile.sh "docker" "${HOME}/.cache/ai-sandbox/Dockerfile.abc123"
#   assemble-dockerfile.sh --hash a1b2c3d4 "docker" "${HOME}/.cache/ai-sandbox/Dockerfile.a1b2c3d4"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BASE_FILE="${DOCKER_DIR}/Dockerfile.base"
CAPABILITIES_DIR="${DOCKER_DIR}/capabilities"

# --- Argument parsing ---
PROFILE_HASH=""
while [[ $# -gt 0 && "$1" == --* ]]; do
  case "$1" in
    --hash)
      if [[ $# -lt 2 ]]; then
        printf 'error: --hash requires a value\n' >&2
        exit 1
      fi
      PROFILE_HASH="$2"
      shift 2
      ;;
    *)
      printf 'error: unknown option: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

if [[ $# -ne 2 ]]; then
  printf 'Usage: %s [--hash <hash>] <capabilities> <output-path>\n' "$(basename "${BASH_SOURCE[0]}")" >&2
  printf 'Example: %s "docker chromium" /tmp/Dockerfile.test\n' "$(basename "${BASH_SOURCE[0]}")" >&2
  exit 1
fi

CAPABILITIES_ARG="$1"
OUTPUT_PATH="$2"

# Validate base file exists.
if [[ ! -f "${BASE_FILE}" ]]; then
  printf 'error: base fragment not found: %s\n' "${BASE_FILE}" >&2
  exit 1
fi

# Ensure output directory exists.
OUTPUT_DIR="$(dirname "${OUTPUT_PATH}")"
if [[ ! -d "${OUTPUT_DIR}" ]]; then
  mkdir -p "${OUTPUT_DIR}"
fi

# Parse capabilities into a sorted array (sorted for hash stability).
declare -a capabilities=()
if [[ -n "${CAPABILITIES_ARG}" ]]; then
  # Read space-separated list into array, then sort for deterministic ordering.
  read -r -a raw_caps <<< "${CAPABILITIES_ARG}"
  # Sort capabilities so the assembled output is hash-stable regardless of
  # the order in which they appear in the profile's capabilities list.
  mapfile -t capabilities < <(printf '%s\n' "${raw_caps[@]}" | sort)
fi

# Validate all requested capability fragments exist before writing any output
# (defense in depth — profile-installer.js also validates, but the assembler
# must not produce a partial file on error).
for cap in "${capabilities[@]}"; do
  fragment="${CAPABILITIES_DIR}/${cap}.dockerfile"
  if [[ ! -f "${fragment}" ]]; then
    printf 'error: unknown capability "%s" — fragment not found: %s\n' "${cap}" "${fragment}" >&2
    exit 1
  fi
done

# --- Assemble ---
# Write base body (everything up to but not including ENTRYPOINT).
cat "${BASE_FILE}" > "${OUTPUT_PATH}"

# Append each capability fragment in sorted order.
for cap in "${capabilities[@]}"; do
  fragment="${CAPABILITIES_DIR}/${cap}.dockerfile"
  printf '\n' >> "${OUTPUT_PATH}"
  cat "${fragment}" >> "${OUTPUT_PATH}"
done

# Append the profile composition hash label when --hash was provided.
# This label is read by is_build_stale() to detect composition changes
# without re-running profile-installer.js. The hash is owned by
# profile-installer.js and passed through here verbatim.
if [[ -n "${PROFILE_HASH}" ]]; then
  printf '\n# === Profile composition label ===\n' >> "${OUTPUT_PATH}"
  printf 'LABEL ai.sandbox.profile-hash="%s"\n' "${PROFILE_HASH}" >> "${OUTPUT_PATH}"
fi

# Append the managed image label unconditionally.
{
  printf '\n# === Managed image label ===\n'
  printf 'LABEL ai.sandbox.managed="true"\n'
} >> "${OUTPUT_PATH}"

# Append the ENTRYPOINT as the final line.
printf '\nENTRYPOINT ["/init"]\n' >> "${OUTPUT_PATH}"
# With S6-overlay, use 'docker compose exec -u ${HOST_USER} zsh' to get a user shell;
# do not add 'USER ${HOST_USER}' before ENTRYPOINT or /init will run as that user.

printf 'Assembled Dockerfile written to: %s\n' "${OUTPUT_PATH}"
