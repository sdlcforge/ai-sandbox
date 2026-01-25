#!/bin/sh
# Set the correct ownership for the volume mount path
echo -n "Setting ownership for ${SSH_AUTH_SOCK} to ${HOST_USER}:${HOST_USER}: "
chown ${HOST_USER}:${HOST_USER} ${SSH_AUTH_SOCK} && echo "success" || echo "failed"
# Execute the command passed to the container (e.g., starting your web server)
exec "$@"
