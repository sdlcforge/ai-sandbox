#!/bin/bash
# Creates a user matching the host UID/GID inside the container.
# Handles GID conflicts by relocating existing groups to a free GID.
set -euo pipefail

HOST_USER="$1"
HOST_HOME="$2"
HOST_UID="$3"
HOST_GID="$4"

# Relocate a conflicting group if HOST_GID is already taken
existing_group=$(getent group "$HOST_GID" | cut -d: -f1 || true)
if [ -n "$existing_group" ] && [ "$existing_group" != "$HOST_USER" ]; then
    dest_gid=39999
    while getent group "$dest_gid" >/dev/null 2>&1; do
        dest_gid=$((dest_gid - 1))
    done
    groupmod -g "$dest_gid" "$existing_group"
fi

# Relocate a conflicting user if HOST_UID is already taken
existing_user=$(getent passwd "$HOST_UID" | cut -d: -f1 || true)
if [ -n "$existing_user" ] && [ "$existing_user" != "$HOST_USER" ]; then
    dest_uid=39999
    while getent passwd "$dest_uid" >/dev/null 2>&1; do
        dest_uid=$((dest_uid - 1))
    done
    usermod -u "$dest_uid" "$existing_user"
fi

groupadd -g "$HOST_GID" "$HOST_USER" 2>/dev/null || true
useradd -u "$HOST_UID" -g "$HOST_GID" -d "$HOST_HOME" -m -s /bin/zsh "$HOST_USER"
