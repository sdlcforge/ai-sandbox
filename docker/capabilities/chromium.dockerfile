# === CAPABILITY: chromium ===
# Chromium browser + X11 forwarding layer.
# This fragment is appended by docker/scripts/assemble-dockerfile.sh when the
# "chromium" capability is selected by a profile. Install is unconditional here —
# fragment inclusion is the gate, not a build ARG.
#
# Ubuntu uses Snap for chromium-browser which doesn't work in containers.
# We install from the xtradeb PPA which provides native .deb packages.
#
# USER context: apt install runs as root; alias write runs as ${HOST_USER}.
# Explicit USER directives make this fragment self-contained regardless of the
# preceding base body's final USER state.
USER root
RUN apt-get update && \
    apt-get install -y software-properties-common && \
    add-apt-repository ppa:xtradeb/apps -y && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      libx11-6 libxcomposite1 libxdamage1 libxext6 libxfixes3 \
      libxrandr2 libxrender1 libxtst6 libxss1 libnss3 libatk1.0-0 \
      libatk-bridge2.0-0 libcups2 libdrm2 libgbm1 libasound2t64 \
      libpango-1.0-0 libcairo2 fonts-liberation chromium && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Add chromium alias for the host user (no-sandbox required inside container).
USER ${HOST_USER}
RUN echo "alias chromium='chromium --no-sandbox'" >> "${HOST_HOME}/.zshrc"
