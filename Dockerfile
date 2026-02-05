FROM ubuntu:latest

# === LAYER 1: Base packages (no ARGs, most stable) ===
RUN apt-get update && apt-get install -y --no-install-recommends \
  aggregate \
  ca-certificates \
  curl \
  dnsutils \
  fzf \
  gh \
  git \
  gnupg2 \
  iproute2 \
  ipset \
  iptables \
  jq \
  less \
  make \
  man-db \
  procps \
  python3 \
  ssh \
  sudo \
  unzip \
  vim \
  xz-utils \
  zsh \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# === LAYER 1b: s6-overlay (init system for graceful shutdown) ===
ARG TOOL_CACHE_DIR
ARG S6_NOARCH_TAR
ARG S6_ARCH_TAR
COPY ${TOOL_CACHE_DIR}/${S6_NOARCH_TAR} /root/${S6_NOARCH_TAR}
COPY ${TOOL_CACHE_DIR}/${S6_ARCH_TAR} /root/${S6_ARCH_TAR}
RUN tar -xf /root/${S6_NOARCH_TAR} -C /
RUN tar -C / -xf /root/${S6_ARCH_TAR}
RUN rm /root/${S6_NOARCH_TAR} /root/${S6_ARCH_TAR}

# === LAYER 2: Timezone (rarely changes) ===
ARG HOST_TZ
ENV TZ="$HOST_TZ"
ARG SSH_AUTH_SOCK
ENV SSH_AUTH_SOCK="$SSH_AUTH_SOCK"

WORKDIR /root

# === LAYER 3: Go installation ===
ARG GO_TAR
COPY ${TOOL_CACHE_DIR}/${GO_TAR} /root/${GO_TAR}
RUN tar -xf ${GO_TAR} -C /usr/local && rm ${GO_TAR}
RUN ln -s /usr/local/go/bin/go /usr/local/bin/go

# === LAYER 4: Git Delta ===
ARG GIT_DELTA_DEB
COPY ${TOOL_CACHE_DIR}/${GIT_DELTA_DEB} /root/${GIT_DELTA_DEB}
RUN dpkg -i ${GIT_DELTA_DEB} && rm ${GIT_DELTA_DEB}

# === LAYER 5: Zsh-in-docker (root setup) ===
ARG ZSH_IN_DOCKER_SH
COPY ${TOOL_CACHE_DIR}/${ZSH_IN_DOCKER_SH} /root/${ZSH_IN_DOCKER_SH}
RUN bash ${ZSH_IN_DOCKER_SH} -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

# === LAYER 6: User creation (changes per machine) ===
ARG HOST_USER
ENV HOST_USER=${HOST_USER}
ARG HOST_HOME
ARG HOST_UID
ARG HOST_GID
COPY scripts/create-user.sh /tmp/create-user.sh
RUN chmod +x /tmp/create-user.sh && \
    /tmp/create-user.sh "${HOST_USER}" "${HOST_HOME}" "${HOST_UID}" "${HOST_GID}" && \
    rm /tmp/create-user.sh
RUN mkdir -p /commandhistory && chown -R ${HOST_USER}:${HOST_USER} /commandhistory
RUN touch /commandhistory/.bash_history && chown -R ${HOST_USER} /commandhistory

USER ${HOST_USER}
WORKDIR ${HOST_HOME}

# === LAYER 7: NVM + Node ===
ARG NVM_INSTALL_SH
COPY ${TOOL_CACHE_DIR}/${NVM_INSTALL_SH} ${HOST_HOME}/${NVM_INSTALL_SH}
RUN bash ${NVM_INSTALL_SH} && rm ${NVM_INSTALL_SH}
RUN bash -c "source ${HOST_HOME}/.nvm/nvm.sh && nvm install --lts"

# === LAYER 8: Bun ===
ARG BUN_INSTALL_SH
COPY ${TOOL_CACHE_DIR}/${BUN_INSTALL_SH} ${HOST_HOME}/${BUN_INSTALL_SH}
RUN bash ${BUN_INSTALL_SH} && rm ${BUN_INSTALL_SH}

# === LAYER 9: Workspace & environment setup ===
RUN mkdir -p ${HOST_HOME}/playground
ENV DEVCONTAINER=true
ENV SHELL=/bin/zsh
ENV EDITOR=vim
ENV VISUAL=vim

WORKDIR ${HOST_HOME}/playground

# === LAYER 10: Claude Code (changes most frequently) ===
ARG CLAUDE_CODE_VERSION=latest
RUN ${HOST_HOME}/.bun/bin/bun install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# === LAYER 11: Firewall setup (root) ===
COPY init-firewall.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall

# === LAYER 11.b: Allow the user to sudo entrypoint script without a password ===
RUN usermod -aG sudo ${HOST_USER}
# RUN echo >> /etc/sudoers
# RUN echo '${HOST_USER} ALL=(ALL) NOPASSWD: /entrypoint.sh' >> /etc/sudoers
# DEBUG
RUN chmod a+r /etc/sudoers
# RUN echo "#includedir /etc/sudoers.d" >> /etc/sudoers
# RUN echo "${HOST_USER} ALL=(ALL) NOPASSWD: /entrypoint.sh" >> /etc/sudoers.d/entrypoint_script
RUN echo "${HOST_USER} ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/entrypoint_script
#RUN chmod 0440 /etc/sudoers.d/entrypoint_script

# === LAYER 11c: Optional Chromium (conditional, runs as root) ===
# Ubuntu uses Snap for chromium-browser which doesn't work in containers.
# When enabled, we install from the xtradeb PPA which provides native .deb packages.
ARG INSTALL_CHROMIUM=false
RUN if [ "$INSTALL_CHROMIUM" = "true" ]; then \
  apt-get update && \
  apt-get install -y software-properties-common && \
  add-apt-repository ppa:xtradeb/apps -y && \
  apt-get update && \
  apt-get install -y --no-install-recommends \
    libx11-6 libxcomposite1 libxdamage1 libxext6 libxfixes3 \
    libxrandr2 libxrender1 libxtst6 libxss1 libnss3 libatk1.0-0 \
    libatk-bridge2.0-0 libcups2 libdrm2 libgbm1 libasound2t64 \
    libpango-1.0-0 libcairo2 fonts-liberation chromium && \
  apt-get clean && rm -rf /var/lib/apt/lists/*; \
fi

# === LAYER 12: Shell config ===
USER ${HOST_USER}
RUN echo "export PATH=\$PATH:${HOST_HOME}/.bun/bin:${HOST_HOME}/.local/bin" >> ${HOST_HOME}/.zshenv
# Enable 'ctrl + a', 'ctrl + e', etc.
RUN echo "bindkey -e" >> ${HOST_HOME}/.zshrc
RUN echo "PROMPT='%F{red}%~%f %# '" >> ${HOST_HOME}/.zshrc
RUN echo "source ${HOST_HOME}/.nvm/nvm.sh" >> ${HOST_HOME}/.zshrc
RUN echo "alias claude-unchained='claude --dangerously-skip-permissions'" >> ${HOST_HOME}/.zshrc
# Chromium alias is only added when Chromium is installed
RUN if [ "$INSTALL_CHROMIUM" = "true" ]; then \
  echo "alias chromium='chromium --no-sandbox'" >> ${HOST_HOME}/.zshrc; \
fi

# === LAYER 12b: Git config ===
ARG GIT_USER_NAME
ARG GIT_USER_EMAIL
RUN git config --global user.name "${GIT_USER_NAME}" && \
    git config --global user.email "${GIT_USER_EMAIL}"

# === LAYER 13: Copy claude.json (may change often) ===
COPY ${TOOL_CACHE_DIR}/.claude.json ${HOST_HOME}/.claude.json

# === LAYER 14: s6-overlay scripts ===
USER root
COPY rootfs/ /
RUN chmod +x /etc/cont-init.d/* /etc/cont-finish.d/*

# s6-overlay environment configuration
ENV S6_CMD_USE_TERMINAL=1
ENV S6_KILL_FINISH_MAXTIME=10000

ENTRYPOINT ["/init"]
# With S6-overlay, it is important to use 'docker compose exec -u ${HOST_USER} zsh'; if we add 'USER ${HOST_USER}'
# here, then '/init' will run as that user, even if it appears after 'ENTRYPOINT ["/init"]'.