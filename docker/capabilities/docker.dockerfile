# === CAPABILITY: docker ===
# Docker CLI (client only; talks to host daemon via socket proxy when --docker is used).
# This fragment is appended by docker/scripts/assemble-dockerfile.sh when the
# "docker" capability is selected by a profile. Install is unconditional here —
# fragment inclusion is the gate, not a build ARG.
USER root
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin docker-compose-plugin \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
